# ADR-011: Миграции БД через TypeORM Migrations

## Status

proposed

## Context

ADR-003 определяет схему PostgreSQL (`storages`, `files` partitioned by month). Сама схема не материализуется без инструмента миграций — нужны процедуры (а) первоначального наката (`storages` + первая месячная партиция `files_YYYY_MM` + default-партиция + индексы + CHECK-constraints + FK), (б) ежемесячной pre-create партиции `files_YYYY_MM+1`, (в) накатки изменений схемы без downtime, (г) отката при failed-deploy. ADR-001 Open Q зафиксировал выбор ORM как открытый; arch-review #9 поднял отсутствие миграционного инструмента до блокера для первого деплоя. Стек ADR-001 — Node + NestJS, что задаёт орбиту канонических вариантов.

- Drives: ADR-003 (schema), arch-review follow-up #9, NFR-DEP-2 (deployable as one image)

## Alternatives

### Alternative A: TypeORM Migrations (`typeorm migration:generate / migration:run`)

- **Cost**: `typeorm` + `pg` уже нужны как DB-клиент в сервисе (см. ADR-009 `TypeOrmHealthIndicator`); миграционная инфраструктура — в той же библиотеке, без отдельной зависимости. Migrations кладутся в `apps/image-uploader/src/migrations/*.ts` как обычные TS-файлы с `up()` / `down()`.
- **Complexity**: один CLI-инструмент (`typeorm migration:run`) запускается как k8s `Job` перед deploy'ом сервиса (init-container или separate Job). Generate'ор миграций (`migration:generate`) умеет diff'ить entity-классы и схему БД, но для partitioned tables и custom CHECK-constraints (см. ADR-003) лучше писать миграции **руками** — generate использовать только как стартовую точку.
- **Correctness**: TypeORM поддерживает все нужные SQL-конструкции (PARTITION BY, CHECK, partial indexes — через `queryRunner.query()` raw SQL); миграции выполняются в одной транзакции по умолчанию (но `CREATE INDEX CONCURRENTLY` нужно вынести `transaction: false`). Migration history таблица `migrations` создаётся автоматически и обеспечивает idempotency накатки.
- **Operability**: integration с NestJS DataSource — единый `ormconfig` для приложения и миграций. Команда платформы уже использует TypeORM в других микросервисах монорепо (по утверждению разработчика в /review-arch follow-up).
- **Verdict**: chosen — выбор согласован с разработчиком; минимальная сложность инфраструктуры за счёт переиспользования уже-нужного TypeORM.

### Alternative B: Prisma Migrate

- **Cost**: добавляется отдельная библиотека `@prisma/client` + `prisma` CLI; Prisma schema (`schema.prisma`) — DSL отдельно от TS-кода; рантайм генерирует client, что добавляет build-step.
- **Complexity**: миграции декларативные (Prisma вычисляет diff schema vs DB), но Prisma НЕ поддерживает partitioned tables в schema-DSL (на момент 2026 — это limitation, требует raw SQL миграции для PARTITION BY).
- **Correctness**: для partitioned `files` всё равно пришлось бы писать raw SQL миграции — преимущество DSL-подхода частично теряется.
- **Operability**: собственная схема `_prisma_migrations`; парadigm shift с TypeORM (если другие микросервисы на TypeORM).
- **Verdict**: rejected — partitioned tables вырождают преимущество declarative DSL до raw SQL; добавляет вторую миграционную систему в монорепо.

### Alternative C: Drizzle Kit / Kysely-migrations

- **Cost**: lightweight ORM/SQL builder; миграционная инфраструктура отдельно (`drizzle-kit migrate`).
- **Complexity**: lower-level, чем TypeORM; больше control'а над raw SQL, но и больше кода для базовых операций (FK, CHECK).
- **Correctness**: эквивалентно Alternative A в полноте функций; partitioning через raw SQL.
- **Operability**: новый стек в монорепо без преимущества над TypeORM в этом проекте.
- **Verdict**: rejected — эквивалент TypeORM по результату при дополнительной operational сложности (вторая ORM/migration-стек в монорепо).

### Alternative D: Atlas (vendor-agnostic, Go-based)

- **Cost**: внешний binary (атлас написан на Go) + k8s Job для накатки.
- **Complexity**: schema-as-HCL или declarative SQL-файл; полный diff-движок.
- **Correctness**: первоклассная поддержка PostgreSQL partitioned tables и сложных DDL.
- **Operability**: ещё один artifact в supply-chain (Go-binary в Node-монорепо); team не использует.
- **Verdict**: rejected — operational mismatch с Node-монорепо ADR-001; преимущества Atlas (advanced diff, schema-as-code) не реализуются в проекте без других микросервисов на нём.

### Alternative E: Raw SQL с самописным runner'ом

- **Cost**: ноль зависимостей.
- **Complexity**: нужен свой migration tracking (state-таблица), idempotency, rollback.
- **Correctness**: легко допустить bug в собственном runner'е; типичные проблемы — race на multiple-pod startup, partial-failure recovery.
- **Operability**: изобретение велосипеда; off-the-shelf решения уже отлажены.
- **Verdict**: rejected — TypeORM Migrations покрывают всё, что нужно, бесплатно.

## Decision

Принят **TypeORM Migrations** для накатки схемы БД (ADR-003).

Структура файлов в монорепо:

```
apps/image-uploader/
├── src/
│   ├── migrations/
│   │   ├── 1714568400000-init-schema.ts        // CREATE storages, files (partitioned)
│   │   ├── 1714568500000-precreate-month-partitions.ts  // ежемесячные партиции
│   │   └── ...
│   ├── data-source.ts                          // DataSource для CLI миграций
│   └── ...
├── ormconfig.ts                                 // entity + migrations paths
└── package.json
```

Команды:

```jsonc
// apps/image-uploader/package.json
{
  "scripts": {
    "migration:generate": "typeorm-ts-node-commonjs migration:generate -d src/data-source.ts",
    "migration:run":      "typeorm-ts-node-commonjs migration:run     -d src/data-source.ts",
    "migration:revert":   "typeorm-ts-node-commonjs migration:revert  -d src/data-source.ts"
  }
}
```

Первая миграция (initial schema) — **руками** (raw SQL queries), потому что TypeORM `migration:generate` не поддерживает PARTITION BY:

```ts
// 1714568400000-init-schema.ts
export class InitSchema1714568400000 implements MigrationInterface {
  public async up(qr: QueryRunner): Promise<void> {
    await qr.query(`
      CREATE TABLE storages (
        id           SMALLSERIAL PRIMARY KEY,
        name         TEXT NOT NULL UNIQUE,
        kind         TEXT NOT NULL CHECK (kind IN ('local','s3')),
        config       JSONB NOT NULL,
        public_base  TEXT NOT NULL,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        is_active    BOOLEAN NOT NULL DEFAULT true
      );
    `);
    await qr.query(`
      CREATE TABLE files (
        id           UUID NOT NULL,
        storage_id   SMALLINT NOT NULL REFERENCES storages(id),
        object_key   TEXT NOT NULL,
        content_type TEXT NOT NULL,
        bytes        BIGINT CHECK (bytes IS NULL OR (bytes >= 0 AND bytes <= 104857600)),
        status       TEXT NOT NULL CHECK (status IN ('pending','committed')),
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (id, created_at),
        CONSTRAINT files_bytes_committed_chk
          CHECK (status = 'pending' OR bytes IS NOT NULL)
      ) PARTITION BY RANGE (created_at);
    `);
    await qr.query(`CREATE TABLE files_default PARTITION OF files DEFAULT;`);

    // Pre-create текущий месяц + 3 на запас
    const months = generateMonthlyRanges(new Date(), 4); // helper, см. ниже
    for (const { name, from, to } of months) {
      await qr.query(`
        CREATE TABLE ${name} PARTITION OF files
          FOR VALUES FROM ('${from}') TO ('${to}');
      `);
    }

    await qr.query(`
      CREATE INDEX files_pending_idx ON files (created_at) WHERE status = 'pending';
    `);
    await qr.query(`CREATE INDEX files_storage_id_idx ON files (storage_id);`);
  }

  public async down(qr: QueryRunner): Promise<void> {
    await qr.query(`DROP TABLE files CASCADE;`);
    await qr.query(`DROP TABLE storages CASCADE;`);
  }
}
```

**Pre-create ежемесячных партиций** (отдельная миграция, запускается планово через `@nestjs/schedule` cron в первое число каждого месяца — НЕ как обычная миграция, а как scheduled-task внутри сервиса; миграционная история не пухнет):

```ts
// libs/db/partition-rotator.service.ts
@Injectable()
export class PartitionRotator {
  constructor(@InjectDataSource() private readonly ds: DataSource) {}

  @Cron('0 1 1 * *')   // 01:00 первого числа месяца
  async ensureNextPartitions(): Promise<void> {
    const months = generateMonthlyRanges(new Date(), 3);  // следующие 3 месяца
    for (const { name, from, to } of months) {
      await this.ds.query(`
        CREATE TABLE IF NOT EXISTS ${name} PARTITION OF files
          FOR VALUES FROM ('${from}') TO ('${to}');
      `);
    }
  }
}
```

**Deployment ordering**: миграция запускается как k8s `Job` ПЕРЕД rolling-update сервиса:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: image-uploader-migrate-{{ .Values.version }}
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: image-uploader:{{ .Values.version }}
        command: ["pnpm", "--filter", "image-uploader", "migration:run"]
        envFrom: [...]   # DB credentials
```

Helm/Kustomize шаблон управляет ordering: миграция должна успешно завершиться **до** rolling-update. При failed-deploy: `migration:revert` откатывает последнюю migration; ручной запуск `migration:revert` оператором (документировать в runbook). Forward-compatibility гарантируется code-review-discipline'ом «нельзя удалять колонку в той же миграции, что переименовывать» — стандартный expand/contract паттерн.

## Consequences

### Positive

- Единая ORM/migration-инфраструктура с другими микросервисами монорепо — ноль когнитивного барьера для on-call.
- Migration files — обычный TS-код, code-review проходит как любой PR.
- `IF NOT EXISTS` в `CREATE TABLE` для месячных партиций делает PartitionRotator идемпотентным — безопасно при failed cron-tick + retry.
- Миграция как отдельный k8s Job отделяет schema-evolution от deploy сервиса; сбой миграции блокирует deploy fail-fast'ом (не запускает pod'ы с устаревшей schema).
- TypeORM Migration history таблица `migrations` — стандартный контракт для tooling вендоров (terraform, ArgoCD detects up-to-date).

### Negative

- `migration:generate` не работает для partitioned tables (TypeORM ограничение) — первая миграция и миграции, меняющие partition-key или partition-strategy, пишутся руками. Это операционная нагрузка на разработчика.
- Cross-pod race: если k8s Job не успел до старта первого pod'а (race в Helm post-install hook ordering), pod упадёт на FK error в `INSERT INTO files`. Митигация: readiness probe (ADR-009 `db.pingCheck`) проверяет таблицу `files` через `SELECT 1 FROM files WHERE false LIMIT 1` — если миграция не накатилась, readiness не пройдёт; dependent-Job ordering обязателен.
- TypeORM 0.3.x в монорепо может конфликтовать с другими микросервисами на 0.2.x (deprecation `getConnection()`); единое подтягивание версии — ответственность платформенной команды, выходит за scope этого ADR.
- Откат через `migration:revert` НЕ автоматизирован — оператор должен запустить вручную; runbook обязателен. Альтернатива (auto-revert по health-check fail) — более сложная инфраструктура, не вводится.
- PartitionRotator работает на каждом pod'е (cron в каждом инстансе); `IF NOT EXISTS` делает это безопасным, но создаёт повторяющиеся идемпотентные DDL-вызовы. Если когда-нибудь это станет проблемой — leader-election через advisory-lock (`pg_try_advisory_lock`) — тривиальное расширение.

## Open questions

- TypeORM 0.3.x наперёд: использовать `DataSource` (новый API) сразу, без миграционного периода через legacy `getConnection`. Закладывается с дня 1.
- `migration:generate` для не-partitioned-related изменений (например, добавление нового storage-кolumn) использовать или всегда писать руками? Скорее всего — generate с обязательным ручным review diff'а.
- Backfill-миграции (например, populate `bytes` для unfilled records, если такие появятся) — отдельный паттерн через batch-update в TypeScript (cursor pagination), не через single SQL UPDATE 200M строк. Закладывается в код-стиль, не в этот ADR.
