# ADR-003: PostgreSQL 15 + двухтабличная схема `storages` / `files` с FK

## Status

proposed

## Context

NFR-DEP-1b — vendor-agnostic реляционная БД. FR-3 требует две сущности в БД (storage и file) с явной ссылкой file → storage и инвариантом FR-3c (file+storage ⇒ URL без иных источников). FR-12d требует unique constraint на UUID файла, чтобы предотвратить race на client-supplied UUID (объекция 5 ревью). NFR-CAP-1 — горизонт 50 TB / 24 мес и до 400 RPS пика; при равномерной нагрузке это до ~200 млн записей `files`. NFR-OBS-1 поле `storage_id` требует обратной ссылки file → storage по идентификатору. NFR-DEP-3d — readiness-probe должна успешно пинговать БД.

- Drives: FR-3a, FR-3b, FR-3c, FR-12d, NFR-DEP-1b, NFR-CAP-1, NFR-OBS-1, NFR-DEP-3d

## Alternatives

### Alternative A: PostgreSQL 15 + две таблицы `storages` и `files`, FK `files.storage_id → storages.id`

- **Cost**: managed PostgreSQL у любого облака; small (db.t4g.small или эквивалент) хватает на 50–200 RPS INSERT'ов; масштабирование read-replicas не требуется (LIST out-of-scope, см. spec); индекс по PK = UUID.
- **Complexity**: ровно две таблицы, один FK, один unique constraint. Миграции — конкретный инструмент привязан к выбору ORM/data-layer (см. ADR-001 Open Q): TypeORM migrations, Prisma Migrate, Drizzle Kit, либо vendor-agnostic Atlas. SQL-портируемость на MySQL/MariaDB сохраняется (FR/NFR vendor-agnostic — для последующего скачка между движками лишь типы UUID и timestamp потребуют ручной правки).
- **Correctness**: `files.id UUID PRIMARY KEY` — atomic unique constraint закрывает FR-12d (`INSERT ... ON CONFLICT DO NOTHING` или `UNIQUE_VIOLATION` → 409). FR-3c удовлетворяется тем, что `files` хранит `storage_id` + `object_key`, а `storages` хранит type/endpoint/bucket/base_path.
- **Operability**: pg_stat_activity, pg_stat_statements, стандартные алерты managed-сервисов; pg_dump для бэкапа метаданных; readiness-probe — `SELECT 1` через connection pool.
- **Verdict**: chosen — выполняет FR-3, FR-12d и NFR-DEP-1b при минимальной complexity.

### Alternative B: SQLite single-file БД

- **Cost**: нулевая — файл рядом с бинарём.
- **Complexity**: тривиально для одного pod'а.
- **Correctness**: SQLite нарушает NFR-DEP-2 (stateless). При горизонтальном масштабировании (100 RPS среднее → 2–4 pod'а минимум) каждый pod имел бы свой файл → отсутствие глобальной уникальности UUID — прямой провал FR-12d.
- **Operability**: нет managed-сервиса; бэкап = копирование файла; нет sharing между подами.
- **Verdict**: rejected — несовместим с NFR-DEP-2 (stateless + горизонтальное масштабирование).

### Alternative C: Документная БД (MongoDB / DynamoDB) — одна коллекция `files` с эмбеддом storage-параметров

- **Cost**: managed Mongo Atlas / DynamoDB — дороже Postgres small; запросов нет (LIST out-of-scope), но платится за storage и pay-per-request.
- **Complexity**: денормализация — параметры storage дублируются в каждой записи `files`. Это допустимо по FR-3d, но операционно: миграция S3-endpoint требует update всех N записей.
- **Correctness**: DynamoDB conditional `attribute_not_exists(id)` PutItem — выполняет FR-12d атомарно, это OK. Но FR-3 явно требует «отдельную сущность storage»; денормализация в одну коллекцию — формально граничный случай (FR-3d допускает «денормализация с дублированием параметров storage в записи file»), но логическое разделение становится менее проверяемым.
- **Operability**: vendor-lock-in (DynamoDB) или дополнительная зависимость supply-chain (Mongo); нарушает NFR-DEP-1b «vendor-agnostic реляционная БД».
- **Verdict**: rejected — NFR-DEP-1b явно требует **реляционную** БД.

## Decision

Принят **PostgreSQL 15+ с двумя таблицами**.

```sql
CREATE TABLE storages (
    id           SMALLSERIAL PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,         -- e.g. 'prod-eu-s3', 'dev-local'
    kind         TEXT NOT NULL CHECK (kind IN ('local','s3')),
    -- For 'local': base_path. For 's3': endpoint, bucket, region, credentials_ref.
    -- Stored as JSONB to avoid schema bloat for divergent backends.
    config       JSONB NOT NULL,
    public_base  TEXT NOT NULL,                -- canonical URL prefix (see ADR-010)
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active    BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE files (
    id           UUID PRIMARY KEY,             -- FR-7 UUID v4; unique constraint = FR-12d
    storage_id   SMALLINT NOT NULL REFERENCES storages(id),
    object_key   TEXT NOT NULL,                -- relative key/path within storage; FR-3b
    content_type TEXT NOT NULL,                -- 'image/jpeg' | 'image/png' | 'image/webp' | 'image/gif'
    bytes        BIGINT NOT NULL CHECK (bytes >= 0 AND bytes <= 104857600),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX files_storage_id_idx ON files(storage_id);
```

INSERT в `files` идёт через `INSERT ... ON CONFLICT (id) DO NOTHING RETURNING id` — атомарная защита от race на client-supplied UUID (FR-12d). Если RETURNING пустой → 409 Conflict (FR-8 `conflict`). См. ADR-004 про порядок INSERT vs PutObject.

`storages.config` — JSONB, потому что схема параметров расходится между local (`base_path`) и s3 (`endpoint`, `bucket`, `region`, `credentials_ref`); жёсткие колонки породили бы NULL'ы и CHECK-каскад. `public_base` отделён от `config` — это якорь для ADR-010 (канонический URL независим от endpoint, но привязан к storage-сущности FR-3a).

`storage_id` — `SMALLINT`: количество storage-сущностей измеряется единицами (dev/staging/prod-by-region), не миллионами; экономит 6 байт на запись в files (на 200 млн записей это ~1 GB).

## Consequences

### Positive

- Атомарность `INSERT ... ON CONFLICT DO NOTHING` — единая защита от FR-12d race без полагания на S3-conditional-write (defense in depth поверх ADR-002).
- FK + JSONB-config в `storages` — добавление нового бэкенда не требует ALTER TABLE.
- Standard SQL — миграция на MySQL/MariaDB при необходимости (NFR-DEP-1b vendor-agnostic) ограничена сменой `JSONB → JSON` и `UUID → BINARY(16)`.
- `storage_id` доступен прямо для NFR-OBS-1 поля `storage_id` лога без дополнительных запросов.

### Negative

- 200 млн записей `files` за 24 месяца (NFR-CAP-1) — таблица ~30 GB на диске + ~10 GB индекс PK. Для одного Postgres-инстанса это терпимо, но монотонный рост без удаления (out-of-scope «Удаление») потребует партиционирования по `created_at` к концу горизонта — отдельный operational ADR на горизонте 12+ месяцев.
- JSONB-config в `storages` снимает CHECK-валидацию полей на уровне БД — ответственность валидации формата config'а ложится на стартап-валидатор сервиса.
- UUID PRIMARY KEY → b-tree индекс не sequential → больше WAL и vacuum-нагрузки, чем у `BIGSERIAL`. Для 50–200 RPS это незначимо, но при росте к 400 RPS (NFR-CAP-1) надо мониторить bloat.
- Managed PostgreSQL — наименее экзотичный выбор, но всё ещё привязка: переключение между AWS RDS / GCP Cloud SQL / Yandex MDB требует пересоздания, не миграции in-place.

## Open questions

- Нужен ли индекс по `(storage_id, created_at)` для будущего operational LIST? LIST out-of-scope, но операторские SQL-запросы «сколько файлов в storage X за период Y» вероятны. Решение архитектурного ревью.
- Partitioning by `created_at` (monthly) — закладывать в первой миграции или вводить позже? Закладка дороже, поздняя миграция требует full-rewrite таблицы.

