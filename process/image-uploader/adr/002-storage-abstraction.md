# ADR-002: Полиморфная Storage-абстракция через интерфейс `BlobStore`

## Status

proposed

## Context

FR-2 требует pluggable бэкенда: локальная ФС в dev/test, S3 в prod (FR-4). Выбор бэкенда — конфигурационный, не runtime per-request. FR-3a/b фиксирует, что в БД хранится **отдельная** запись storage и каждая запись file ссылается на storage; FR-3c — инвариант: file+storage ⇒ полный путь однозначно. FR-12 требует: PutObject/write и DELETE-компенсация; FR-12d требует: conditional create (без overwrite) для защиты от collision (объекция 5 ревью). NFR-DEP-1 vendor-agnostic — S3 API должен работать против AWS S3, MinIO, Ceph RGW и т.п.

- Drives: FR-2, FR-3a, FR-3b, FR-3c, FR-4, FR-12c, FR-12d, NFR-DEP-1a

## Alternatives

### Alternative A: Один интерфейс `BlobStore` с двумя реализациями (`LocalFsBlobStore`, `S3BlobStore`)

- **Cost**: ~500 строк TypeScript на оба бэкенда + интеграционные тесты; одна абстракция, регистрируется как `BLOB_STORE` provider в NestJS DI и подменяется фабрикой по `STORAGE_TYPE` env.
- **Complexity**: один TypeScript-интерфейс из 4 методов (`put`, `delete`, `url`, `healthCheck`), реализации — отдельные `@Injectable()` классы. Подмена через NestJS DI provider-фабрику без условных веток в бизнес-коде.
- **Correctness**: опция `ifNoneMatch: true` в `put` маппится на S3 `If-None-Match: *` (поддержано AWS S3 с 2024-11 и MinIO ≥ RELEASE.2024-09); для LocalFS — `fs.createWriteStream(path, { flags: 'wx' })` (write+exclusive create). Это даёт FR-12d на уровне storage. FR-3c — `url(key)` детерминирован от storage-сущности.
- **Operability**: `healthCheck` для LocalFS — `fs.promises.stat(basePath)` + проверка writable; для S3 — `HeadBucketCommand`; обе вызываются readiness-probe (NFR-DEP-3d, ADR-009 `S3HealthIndicator` / `LocalFsHealthIndicator`).
- **Verdict**: chosen — единственный способ удовлетворить FR-2 (pluggable) без условных веток в бизнес-коде upload-handler.

### Alternative B: Прямые вызовы S3 в коде, локальная ФС — только в тестах через `os.tmpdir()`

- **Cost**: меньше абстракции, на ~200 строк меньше.
- **Complexity**: бизнес-код знает про `S3Client` напрямую; в тестах — другой код-путь, тестируется не то, что в проде.
- **Correctness**: нарушает FR-2 (dev/test тоже должны использовать тот же контракт через локальную ФС, иначе debug-цикл «у меня на ноутбуке работает» ломает уверенность в storage-инварианте FR-3c).
- **Operability**: невозможно за 5 минут поднять dev-инстанс без MinIO/AWS — каждый разработчик должен иметь S3.
- **Verdict**: rejected — нарушает FR-2 буквально.

### Alternative C: Использовать `flydrive` или похожий npm-CDK для облачных провайдеров

- **Cost**: ~1 MB транзитивных зависимостей.
- **Complexity**: общий URL-схемный API (`s3`, `local`, `gcs`). Меньше своего кода.
- **Correctness**: на момент 2026 `flydrive` (и другие npm-CDK для blob storage — `@slynova/flydrive`, `nestjs-s3-aws`, `unstorage`) НЕ поддерживают `If-None-Match: *` для conditional create в S3 — это блокирует FR-12d. Workaround — `headObject`-проверка перед `putObject` — это race window.
- **Operability**: ещё одна зависимость в supply-chain; релизный цикл CDK не совпадает с AWS SDK; PRs на conditional-write фичу могут идти месяцами.
- **Verdict**: rejected — отсутствие conditional-create — блокер для FR-12d.

## Decision

Принят **`BlobStore` интерфейс с двумя реализациями `LocalFsBlobStore` и `S3BlobStore`**, регистрируемыми через NestJS DI factory по `STORAGE_TYPE` env (`s3` для prod, `local` для dev/test).

Контракт:

```ts
// libs/storage/blob-store.interface.ts
export interface PutOptions {
  ifNoneMatch?: boolean;            // FR-12d conditional create
  abortSignal?: AbortSignal;        // ADR-005 cancellation
}

export interface BlobStore {
  /** Writes body under key. If opts.ifNoneMatch && key exists → throws AlreadyExistsError. */
  put(key: string, body: Readable, contentType: string, opts?: PutOptions): Promise<void>;
  delete(key: string): Promise<void>;
  /** Deterministic public URL for key per FR-9d. */
  url(key: string): string;
  /** Used by readiness probe (NFR-DEP-3d, ADR-009). */
  healthCheck(timeoutMs?: number): Promise<void>;
}

export const BLOB_STORE = Symbol('BLOB_STORE');
```

`LocalFsBlobStore.put` использует `fs.createWriteStream(path, { flags: 'wx' })` для conditional create (`wx` = write+exclusive — `EEXIST` при существовании); `S3BlobStore.put` использует `@aws-sdk/lib-storage` `Upload` с `IfNoneMatch: '*'` (см. ADR-006). `url` берёт значения из storage-сущности (см. ADR-003): `LocalFsBlobStore` вернёт `<storage.public_base>/<key>` (где `public_base` — статический URL CDN/reverse-proxy перед dev-каталогом), `S3BlobStore` — `<storage.public_base>/<key>` (где `public_base` — endpoint бакета или CDN, см. ADR-010 про канонический URL). FR-3c удовлетворяется тем, что storage-сущность содержит **все** параметры, нужные для построения URL.

## Consequences

### Positive

- Один и тот же путь кода в dev (LocalFS) и prod (S3) — снижает «у меня работает» риск.
- Conditional create в обоих бэкендах закрывает race на client-supplied UUID (FR-12d, объекция 5 ревью) на уровне storage, не только БД.
- Простой контракт `HealthCheck` ложится на readiness-probe NFR-DEP-3d.
- Vendor-agnostic NFR-DEP-1a: достаточно подменить endpoint/credentials, чтобы перейти MinIO ↔ AWS S3 ↔ Yandex Object Storage.

### Negative

- Дублирование тестов: каждая реализация требует своего набора интеграционных тестов (testcontainers MinIO для S3, tmpdir для LocalFS) — это операционная стоимость CI.
- `S3.PutObject` с `IfNoneMatch: *` — относительно новая фича (AWS Nov 2024); если оператор разворачивается на S3-совместимом хранилище без её поддержки, FR-12d ломается. Это ограничение должно быть проверяемо в `HealthCheck` (см. ADR-009) или зафиксировано в operational README.
- `URL(key)` — детерминированная функция от `key` и storage-параметров; объекция 11 ревью (миграция между storage-сущностями ломает «вечный» URL FR-9a) была отклонена разработчиком, но физически проблема остаётся: если оператор сменит endpoint/bucket, ранее выданные URL будут другими. Это смягчается ADR-010 (канонический CDN-домен).
- LocalFS-реализация не должна попасть в prod — это NFR-DEP-2 риск; нужен явный config-валидатор, отказывающий старт сервиса с `storage.type=local` под `ENV=production`.

## Open questions

- Поддерживать ли третий бэкенд (например, GCS native API) в первой итерации? Спека требует только S3-совместимый — пока нет.
- Должен ли `BlobStore.put` возвращать ETag/version для будущей дедупликации (out-of-scope «Идемпотентность»)? Архитектурное ревью.

## Response to arch-review disagree-flag

Disagree-flag arch-review предлагает переименовать `put` с опцией `ifNoneMatch` в отдельный метод `putIfAbsent` для type-system enforcement FR-12d. **Решение разработчика — отклонить**.

Обоснование: type-system invariant против runtime-config knob — настоящее улучшение, но цена не нулевая. Раздельные `put` и `putIfAbsent` дублируют сигнатуру (та же body/contentType/abortSignal/...), удваивают surface поверхности тестирования, и сами по себе НЕ запрещают вызов «легаси» `put` из upload-handler — для этого всё равно нужна code-review-discipline или ESLint-rule, которые в равной мере решают проблему и для опционального флага. Защита FR-12d на сегодня обеспечивается **двумя слоями**: (1) unique-constraint в `files.id PRIMARY KEY` (ADR-003) — атомарная защита на уровне БД, не зависящая от storage-уровня; (2) `IfNoneMatch: '*'` на S3 multipart (ADR-006) — defense-in-depth. Оба слоя работают независимо от того, как реализована абстракция `BlobStore`.

Принимаемая остаточная слабость: `BlobStore.put({ ifNoneMatch: false })` физически возможен и не ловится компилятором. Митигация — единая code-review-rule «`ifNoneMatch` в upload-handler ОБЯЗАН быть `true`» + интеграционный тест на регрессию (специально сконструированный test, который пытается записать тот же UUID дважды без ifNoneMatch и ожидает, что unique-constraint в БД остановит вторую запись). Если когда-нибудь FR-12d захотят расширить (например, дедупликация по контенту), переход на `putIfAbsent` остаётся опцией без слома совместимости.

