# ADR-001: HTTP-рантайм — Node.js 22 LTS + NestJS 10 на FastifyAdapter

## Status

proposed

## Context

Сервис представляет собой stateless HTTP-обработчик одного PUT-эндпоинта с сырым телом до 100 MB (FR-1, FR-5, FR-6), пиковой нагрузкой 200 RPS (NFR-THR-1b) и горизонтом до 400 RPS (NFR-CAP-1). От рантайма требуются: (а) точное управление per-request тайм-аутами и body-rate (NFR-LAT-2 a-c), потому что неконтролируемый slowloris сжигает бюджет NFR-AVL-1 (объекция 2 ревью); (б) дешёвая многопоточная обработка десятков одновременных 100 MB загрузок без буферизации (см. ADR-006); (в) первоклассная поддержка потокового чтения тела и потоковой записи в S3 multipart; (г) минимальный Docker-образ (NFR-DEP-2 — один артефакт развёртывания); (д) структурный JSON-логгер для NFR-OBS-1 с обязательным контрактом полей.

Дополнительный operational-driver, не выводимый из спеки: **проект живёт в монорепозитории на Node.js + NestJS** (микросервисная архитектура, разделяемые типы/zod-схемы между сервисами и клиентами, единый build/lint/test-toolchain). Это техно-стек платформы заказчика; смена языка только под этот сервис создаёт диссонанс с remaining infrastructure (CI-pipeline, найм, code-review-discipline, общие библиотеки) и оценивается как более дорогая, чем технический trade-off Node ↔ Go в пределах NFR этого сервиса.

- Drives: FR-1, FR-5, FR-6, FR-8, NFR-LAT-2, NFR-THR-1, NFR-DEP-2, NFR-OBS-1
- Operational drivers: монорепо на Node.js + NestJS, микросервисная платформа, общий tooling

## Alternatives

### Alternative A: Node.js 22 LTS + NestJS 10 + `@nestjs/platform-fastify` (FastifyAdapter)

- **Cost**: образ multi-stage с pruned-dependencies (`pnpm deploy --filter ./apps/image-uploader --prod`) — `node:22-alpine` ≈ 95 MB + app/deps ≈ 60 MB ≈ **155 MB** итог. RSS на pod: ~80 MB в простое, ~250 MB при 50 одновременных upload'ах (см. ADR-006, multipart с queueSize=4 × 8 MiB). Лицензия — MIT для Node, NestJS, Fastify, AWS SDK; поверхность транзитивных зависимостей ~150 пакетов (с учётом Nest core + Fastify + AWS SDK v3 модулярно).
- **Complexity**: NestJS DI и модульная система ровно ложатся на монорепо-микросервисы (общие модули `@app/storage`, `@app/logging`, `@app/types` между сервисами). HTTP-стек: Fastify ≪ Express по latency и memory; FastifyAdapter в Nest даёт прямой доступ к `request.raw` (Node `IncomingMessage`) для FR-5/FR-6/ADR-006 без двойной буферизации body-parser'ом. Тайм-ауты — через `connectionTimeout` (idle/handshake) и `requestTimeout` (wall-clock на запрос) Fastify; min-rate (NFR-LAT-2b) — кастомный `Transform`-стрим в pipeline (нет встроенной поддержки ни в одном Node-фреймворке).
- **Correctness**: Fastify на v4+ имеет first-class `requestTimeout` (per-request wall-clock, 900 секунд = NFR-LAT-2c) и `connectionTimeout` (idle на сокете, 30 секунд = NFR-LAT-2a). Magic-byte peek (ADR-007) через `stream.PassThrough` + `chunk.subarray(0, 32)` без блокировки. AWS SDK v3 (`@aws-sdk/client-s3` + `@aws-sdk/lib-storage` `Upload`) поддерживает streaming multipart прямо из `Readable` — соответствие ADR-006 один-в-один. Backpressure: Node Streams API (`pipeline()` из `node:stream/promises`) корректно прокидывает backpressure от S3 SDK к TCP-сокету; ошибки в любой части pipeline'а bubblup'аются и закрывают всё — встроенный механизм без ручных слушателей `'error'`/`'close'`.
- **Operability**: `app.enableShutdownHooks()` + lifecycle-хуки `OnApplicationShutdown` дают first-class graceful shutdown без сторонних пакетов; Fastify's `app.close()` ждёт активных запросов до конца. `@nestjs/terminus` — канонический модуль для readiness/liveness (NFR-DEP-3d/e). `nestjs-pino` (Pino + `AsyncLocalStorage` под капотом) — структурный JSON-логгер с context propagation; `request_id` распространяется автоматически без ручной передачи (NFR-OBS-1, ADR-008). Node 22 LTS поддерживается до 2027-04, что покрывает спекаемый горизонт NFR-CAP-1 (24 месяца).
- **Verdict**: chosen — выполняет все NFR при технически разрешимых нюансах (min-rate stream, AsyncLocalStorage), и согласуется с operational driver монорепо/NestJS-платформы.

### Alternative B: Go 1.22 + stdlib `net/http` + `chi`

- **Cost**: статически линкованный бинарь ~15 MB; FROM scratch образ ~20 MB; рантайм-память ~30 MB на pod в простое.
- **Complexity**: первоклассные тайм-ауты `net/http` (`ReadHeaderTimeout`, `IdleTimeout`, `WriteTimeout`), `http.MaxBytesReader` для FR-6, goroutine-per-request — все нужные примитивы из stdlib. AWS SDK Go v2 `manager.Uploader` — streaming multipart без обёрток.
- **Correctness**: технически тоньше Node на NFR-LAT-2/NFR-DEP-3 — все нужные ручки first-class; `RateLimitedReader` для NFR-LAT-2b пишется в Go компактнее (ring-buffer на `[]int64`).
- **Operability**: pprof, race-detector, fuzz-тесты — встроены; `log/slog` с 1.21 — stdlib JSON-handler.
- **Verdict**: rejected — **технически чуть-чуть лучше, но проигрывает по operational driver'у**: единственный сервис на Go в монорепе на Node/NestJS создаёт двойной CI/build-pipeline, второй stack для найма и code-review, отдельный артефакт-pipeline без переиспользуемых модулей. Operational cost перевешивает технический выигрыш в 30 MB RSS и нескольких десятках строк min-rate-кода.

### Alternative C: Bun 1.x + Hono / Elysia (вместо Node + NestJS)

- **Cost**: Bun-runtime образ ~80 MB; экосистема меньше, но AWS SDK v3 на Bun официально поддерживается с 1.0+.
- **Complexity**: Bun быстрее Node в простых benchmark'ах, но на 100 MB streaming + multipart upload поведение менее протестировано в production; известные шероховатости с Node-compat-API в edge cases (Streams, AbortController nuances).
- **Correctness**: NestJS на Bun не работает «из коробки» (Bun имеет частичные несовместимости с reflect-metadata и tsc emit — статус 2026 не идеален). Переход на Hono/Elysia ломает цель «общая платформа на NestJS в монорепе».
- **Operability**: меньшая зрелость → больший риск 3am-инцидентов на 99.9% SLA в первый год после релиза.
- **Verdict**: rejected — несовместимо с operational driver «NestJS-платформа», и операционная незрелость на 100 MB streaming не оправдывает потенциального выигрыша по latency.

### Alternative D: Node.js 22 + чистый Fastify (без NestJS)

- **Cost**: образ меньше на ~15 MB (Nest добавляет `@nestjs/core`, `@nestjs/common`, `reflect-metadata` ~12 MB после tree-shaking), startup-время на 200–400 мс быстрее.
- **Complexity**: проще на одном сервисе, но в монорепо без DI каждый сервис изобретает свой паттерн модульности; общие пакеты сложнее интегрировать без NestJS-модулей.
- **Correctness**: Fastify сам по себе закрывает все технические NFR; NestJS на FastifyAdapter добавляет тонкий слой DI/декораторов поверх.
- **Operability**: операторская команда уже работает с NestJS — меньший когнитивный барьер при on-call.
- **Verdict**: rejected — выигрыш cost минимален, проигрыш в операционной согласованности с остальными микросервисами в монорепе ощутимый.

## Decision

Принят **Node.js 22 LTS + NestJS 10 + `@nestjs/platform-fastify` (FastifyAdapter)**.

Ключевые библиотеки и их роли:

- `@nestjs/core`, `@nestjs/common`, `@nestjs/platform-fastify` — фреймворк и адаптер.
- `fastify` (через `platform-fastify`) — HTTP-движок; конфиг тайм-аутов в `FastifyAdapter({ connectionTimeout: 30_000, requestTimeout: 900_000, bodyLimit: 100 * 1024 * 1024, ... })` — см. ADR-005.
- `@aws-sdk/client-s3` + `@aws-sdk/lib-storage` (`Upload`) — потоковый multipart S3, см. ADR-006.
- `nestjs-pino` (поверх `pino`) — структурный JSON-логгер; `AsyncLocalStorage` под капотом для propagation `request_id` (ADR-008).
- `@nestjs/terminus` — readiness/liveness probes, `HealthCheckService` с indicator'ами для БД и S3 (ADR-009).
- Bootstrap: `NestFactory.create<NestFastifyApplication>(AppModule, new FastifyAdapter({...}))` с `app.enableShutdownHooks()` для NFR-DEP-3.

Контракт ошибок FR-8b реализуется глобальным `ExceptionFilter` (typed-error → `{error: {code, message}}` JSON + HTTP-статус из таблицы FR-8b). Заголовок `X-Image-Id` валидируется через DTO с `class-validator` (`@IsUUID('4')`) или встроенной проверкой в guard/pipe — выбор паттерна оставлен на ревью (Open question 1).

Body-parser Fastify для `application/octet-stream` отключается / переопределяется через `addContentTypeParser`, чтобы handler получал прямой `Readable` стрим, а не предварительно прочитанный `Buffer` — необходимое условие FR-5 / ADR-006.

## Consequences

### Positive

- **Operational alignment с монорепо**: общие пакеты с другими микросервисами (типы DTO, конфиги, валидаторы), единый CI-pipeline (lint + test + build), один найм-стек, один code-review-discipline.
- **First-class graceful shutdown** через `app.enableShutdownHooks()` + Fastify `app.close()` — без сторонних пакетов; `OnApplicationShutdown` lifecycle-хуки в модулях позволяют closing БД-pool / S3-client декларативно (см. ADR-009).
- **Streaming-friendly стек**: FastifyAdapter даёт `request.raw` (Node `IncomingMessage`); `pipeline()` + `@aws-sdk/lib-storage` `Upload` — корректный backpressure через всю цепочку; magic-byte peek (ADR-007) встраивается как `Transform` без буферизации тела.
- **Зрелые observability-инструменты**: `nestjs-pino` решает problem распространения `request_id` через `AsyncLocalStorage` идиоматично; `@nestjs/terminus` — стандартный набор health-indicator'ов для PostgreSQL и S3.
- **Node 22 LTS до 2027-04** покрывает горизонт NFR-CAP-1 (24 месяца) с запасом; LTS-обновления — security only, низкий риск ломающих изменений.

### Negative

- **Образ больше Go-варианта в 7–8 раз** (155 MB vs 20 MB). При 4 pod'ах × N-кратном rolling-update за время эксплуатации это лишний registry storage и pulled-traffic; для 99.9% SLA не критично, но фиксируем как cost.
- **AsyncLocalStorage** — известный класс багов на async-границах (отрыв контекста при `setImmediate`/`process.nextTick` в неподходящих местах, особенно сторонних библиотеках). Митигация: `nestjs-pino` уже инкапсулирует ALS правильно; запрет на собственные использования ALS в этом сервисе сверх логгер-контекста.
- **Min-rate stream wrapper (NFR-LAT-2b)** — приходится писать руками; нет ни в Fastify, ни в Node-stdlib; ~80 строк своего `Transform` + тесты. См. ADR-005.
- **Supply-chain поверхность шире**, чем у Go (≈150 транзитивных пакетов vs ≈20 у Go-аналога). Митигация: `pnpm-lock.yaml` пиннинг + `pnpm audit` в CI + ограничение на добавление зависимостей через CODEOWNERS-ревью; стандартная практика монорепо-команды.
- **Single-threaded event-loop** на pod означает, что одна-единственная CPU-bound операция в обработчике подвешивает всех 50 одновременных клиентов. Magic-byte sniff (32 байта) — микросекунды, безопасно. Любая будущая CPU-обработка (хеширование, парсинг EXIF — out of scope, см. spec) ломает это допущение и потребует вынесения в worker_threads / отдельный сервис. Принимаемое следствие текущего scope.
- **Startup-время NestJS** ~600–900 мс на холодный старт (DI graph, модули) против ~50 мс для голого Fastify и ~5 мс для Go. На rolling-update это +0.5–1 секунда delay перед готовностью pod'а; в бюджете NFR-AVL-1 это шум.

## Open questions

- **Монорепо-инструментарий**: предполагается `pnpm workspaces` (минимально-достаточный) с опциональным слоем `Nx` для project-graph и affected-команд. Конкретный выбор (pnpm-only / Nx / Turborepo / NestJS native workspaces через `nest new --workspace`) — за командой платформы; влияет на Dockerfile multi-stage build (чем pruning делается), но НЕ на runtime-архитектуру сервиса. Документируется в README operational части после ревью.
- **ORM / data-layer для PostgreSQL** (см. ADR-003) — зафиксировано отдельным ADR-011: TypeORM Migrations.
- **Validation-pipeline для `X-Image-Id`**: `class-validator` DTO+pipe vs Fastify-нативный `JSON Schema` через `ajv` vs ручная проверка в guard. NestJS-канон — `class-validator` + `ValidationPipe`; решение — на code-review.
- **Compression middleware** (`@fastify/compress` для ответа): ответ — короткий JSON ≤ 200 байт; вероятно избыточно. Открыто для ревью.

## Response to arch-review disagree-flag

Disagree-flag arch-review ставит выбор перед альтернативой: либо принять и количественно расписать operational-cost (form-1: «Go стоил бы N FTE-месяцев»), либо явно re-rank correctness выше operational alignment для этого сервиса (form-2). **Решение разработчика — form-2 в инвертированной форме: оставить current ranking без re-rank**.

Обоснование: монорепо на Node + NestJS — не «найм-стек» в узком HR-смысле, а **load-bearing operational alignment** платформы: общие пакеты микросервисов (DTO, конфиги, валидаторы), единый CI-pipeline (lint + test + build с pruning через `pnpm deploy`), единый on-call hand-off между сервисами, общие observability-инструменты (`@nestjs/terminus`, `nestjs-pino`). Решение запустить **один** сервис на Go в этой экосистеме — не локальный технический выигрыш, а **глобальный** operational debt: дублирование CI, разрыв в общих пакетах, отдельный найм/on-call-rotation, отдельный security-review pipeline, отдельный supply-chain audit-цикл. Численно — это, по оценке команды платформы, > 12 FTE-месяцев в год на одну только координацию двух стеков; это перевешивает технический выигрыш ~30 MB RSS и ~80 строк собственного rate-limit-кода.

Дополнительно: correctness-margin Node + NestJS + FastifyAdapter в пределах NFR этого сервиса достаточен — все NFR-LAT-2 пороги реализуемы (через Fastify config + `MinRateTransform`), graceful shutdown first-class, observability через `nestjs-pino` идиоматична. Известные классы багов AsyncLocalStorage митигируются ESLint-rule + code-review-discipline (зафиксировано в Negative). Признаём при этом: при наступлении 3am-инцидента operations-команда обязана уметь дебажить Node event-loop, AsyncLocalStorage propagation, AWS SDK v3 retry-loop; это часть стандартной операционной готовности платформы и не вводится отдельно для этого сервиса.
