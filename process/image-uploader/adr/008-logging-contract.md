# ADR-008: Структурный логгинг через `nestjs-pino` (`pino`) с `request_id` через `AsyncLocalStorage`

## Status

proposed

## Context

NFR-OBS-1 (расширено по объекции 4 ревью) — только структурные JSON-логи на stdout, никаких метрик/трейсов; зафиксирован обязательный набор полей: `ts`, `level`, `event`, `request_id`, `duration_ms`, `bytes_in`, `http_status`, `detected_format`, `storage_id`, `error_class`. `request_id` — из `X-Request-Id` входящего, иначе server-generated UUID v4, и **отдаётся** клиенту в `X-Request-Id` ответа. NFR-SEC-1c — UUID файла в публичных логах не обязателен и должен быть огорожен. SLO `NFR-LAT-1`/`NFR-AVL-1` верифицируются ВНЕ сервиса парсингом этих логов — нарушение контракта полей ломает observability.

- Drives: NFR-OBS-1, NFR-LAT-1 (verifiability), NFR-AVL-1 (verifiability), NFR-SEC-1c, FR-7

## Alternatives

### Alternative A: `nestjs-pino` (поверх `pino` v9) — структурный JSON-логгер с `AsyncLocalStorage`-инъекцией контекста + Fastify `genReqId` + reply hook для X-Request-Id

- **Cost**: транзитивно `pino`, `pino-http`, `nestjs-pino` ~250 KB на диске; runtime overhead ничтожен (Pino пишет JSON ~5x быстрее `winston`/`bunyan`).
- **Complexity**: один модуль `LoggerModule.forRoot(...)` в bootstrap; `Logger` инжектится в любой провайдер через DI; контекст `request_id` propagируется автоматически через `AsyncLocalStorage`, который `nestjs-pino` уже инкапсулирует. Не требуется ручная передача `request_id` в каждый log-call — вся обвязка под капотом.
- **Correctness**: JSON-форматирование `pino` гарантирует валидный JSON; обязательные имена полей контракта (`ts`, `event`, `error_class`, `detected_format`, `storage_id`, `duration_ms`, `bytes_in`, `http_status`, `request_id`, `level`) фиксируются единым helper'ом `LogTerminal(...)` в `libs/logging`, который требует все поля как параметры и проверяется golden-test'ом в CI.
- **Operability**: `pino` пишет на stdout без буфера в дефолте; transport'ы (`pino-pretty`, `pino-elasticsearch`) — внешние и в production отключены (NFR-OBS-1: «сборка/агрегация/ретенция логов — внешняя инфраструктура»). `AsyncLocalStorage` с Node 20+ имеет минимальный overhead; известные edge cases (отрыв контекста) обходятся фактом, что `nestjs-pino` правильно binds ALS на уровне Fastify request hook.
- **Verdict**: chosen — прямое 1:1 с NFR-OBS-1, минимальная сложность, идиоматично для NestJS.

### Alternative B: `winston` или `bunyan` (классические Node-логгеры)

- **Cost**: `winston` ~1 MB транзитивных, `bunyan` ~600 KB.
- **Complexity**: `winston` имеет богатый API (transports, formats), но это лишнее для NFR-OBS-1 (никаких histogram'ов, ротации, transport'ов в коде). `bunyan` проще, но менее активно поддерживается (last release 2022).
- **Correctness**: оба производят валидный JSON, но `winston` сериализация на 5–10x медленнее `pino` на одинаковом workload'е; для 200 RPS незначимо, но cost есть.
- **Operability**: `nestjs-winston` адаптер существует, но `AsyncLocalStorage` propagation `request_id` пишется руками (отдельный middleware + `runWith`); на одну зависимость больше работы.
- **Verdict**: rejected — менее производителен, требует больше boilerplate, не приносит ценности сверх Pino.

### Alternative C: NestJS встроенный `Logger` (`@nestjs/common`) с custom JSON formatter

- **Cost**: 0 зависимостей.
- **Complexity**: NestJS `Logger` — текстовый по дизайну; чтобы получить JSON, нужно реализовать `LoggerService` интерфейс целиком. ~150 строк кода + AsyncLocalStorage context.
- **Correctness**: высокий риск собственных ошибок сериализации (escape, циклические объекты, undefined-значения); `pino` уже решил все эти проблемы.
- **Operability**: производительность ниже `pino` в 3–5x (NestJS Logger использует `console.log` под капотом).
- **Verdict**: rejected — изобретение велосипеда.

### Alternative D: OpenTelemetry SDK с logs-exporter в JSON

- **Cost**: ~3 MB транзитивно (`@opentelemetry/sdk-logs`, `@opentelemetry/api`).
- **Complexity**: high — OTel ориентирован на трейсы и метрики, его logs API менее зрелый и требует отдельного configurable exporter.
- **Correctness**: можно настроить, но overkill для «JSON на stdout».
- **Operability**: добавляет операционные ручки, которые NFR-OBS-1 явно НЕ требует (трейсы выкинуты). Это будет соблазн «зайчуть» OTel позже.
- **Verdict**: rejected — несоразмерно требованию.

## Decision

Принят **`nestjs-pino` (`pino` v9) + Fastify `genReqId` + reply hook для X-Request-Id**.

Bootstrap (`main.ts`):

```ts
import { FastifyAdapter, NestFastifyApplication } from '@nestjs/platform-fastify';
import { Logger } from 'nestjs-pino';
import { randomUUID } from 'node:crypto';

const app = await NestFactory.create<NestFastifyApplication>(
  AppModule,
  new FastifyAdapter({
    // ... timeouts из ADR-005
    genReqId: (req) => {
      const incoming = req.headers['x-request-id'];
      if (typeof incoming === 'string' && isValidRequestId(incoming)) return incoming;
      return randomUUID();  // server-generated UUID v4
    },
  }),
  { bufferLogs: true },
);
app.useLogger(app.get(Logger));
```

`LoggerModule` (в `AppModule`):

```ts
LoggerModule.forRoot({
  pinoHttp: {
    level: process.env.LOG_LEVEL ?? 'info',
    // sync: true для прода — не теряем терминальные записи на SIGKILL/OOM.
    // arch-review #2: было `sync: false` (default), теперь явно `true`.
    stream: pino.destination({ dest: 1, sync: true }),
    timestamp: pino.stdTimeFunctions.isoTime,
    formatters: {
      level: (label) => ({ level: label }),       // строка вместо числа
      bindings: () => ({}),                        // убрать pid/hostname
      // arch-review #2: переименование `time` → `ts` для NFR-OBS-1 контракта.
      log: ({ time, ...rest }) => (time !== undefined ? { ts: time, ...rest } : rest),
    },
    messageKey: 'msg',
    customProps: (req) => ({
      request_id: req.id,                          // из genReqId
      // arch-review #2: client_ip нормализуется из X-Forwarded-For
      // (берём левый-самый = первый прокси-хоп клиента).
      client_ip: extractClientIp(req),
    }),
    customSuccessMessage: () => 'request_completed',
    customLogLevel: (req, res, err) =>
      err || res.statusCode >= 500 ? 'error'
      : res.statusCode >= 400 ? 'warn'
      : 'info',
    redact: {
      paths: ['req.headers.authorization', 'req.headers.cookie',
              'req.headers["x-image-id"]'],        // UUID не в публичные логи (NFR-SEC-1c)
      remove: true,
    },
  },
});

function extractClientIp(req: FastifyRequest): string | null {
  const xff = req.headers['x-forwarded-for'];
  if (typeof xff === 'string' && xff.length > 0) {
    return xff.split(',')[0].trim();
  }
  return req.ip ?? null;
}
```

Reply hook для X-Request-Id (плагин Fastify, регистрируется в `AppModule`):

```ts
app.getHttpAdapter().getInstance().addHook('onSend', (req, reply, payload, done) => {
  reply.header('X-Request-Id', req.id);          // NFR-OBS-1 контракт ответа
  done();
});
```

Терминальный helper `LogTerminal` (`libs/logging`):

```ts
// Контракт NFR-OBS-1 — все обязательные поля закреплены TypeScript-типом.
// Расширения arch-review #11: per-stage timings + file_id_fingerprint.
export type ImageFormat = 'jpeg' | 'png' | 'webp' | 'gif' | 'none';
export type ErrorClass =
  | 's3_put_failed' | 'db_insert_failed' | 'db_update_failed'   // arch-review #2: добавлен db_update_failed
  | 'magic_byte_rejected' | 'size_exceeded' | 'invalid_uuid'
  | 'conflict' | 'timeout' | 'too_many_in_flight' | 'internal_error';

export interface TerminalEvent {
  event: 'upload_completed' | 'upload_rejected' | 'upload_failed';
  duration_ms: number;                       // total request duration
  bytes_in: number;
  http_status: number;
  detected_format: ImageFormat;
  storage_id: number | null;                 // null до выбора storage
  error_class: ErrorClass | null;            // null для успеха

  // arch-review #11: per-stage timings — позволяют root-cause при NFR-LAT-1 regress
  // без необходимости трейсов (NFR-OBS-1 их запрещает). Каждое поле — длительность
  // соответствующего этапа в мс; null если этап не выполнился (например, db_commit_ms
  // null при failed pipeline-fail до шага 6).
  magic_byte_ms: number | null;              // ADR-007 peek + sniff
  db_pending_ms: number | null;              // ADR-004 шаг 4
  s3_upload_ms: number | null;               // ADR-006 pipeline + Upload.done
  db_commit_ms: number | null;               // ADR-004 шаг 6

  // arch-review #11: hash(UUID) как fingerprint — позволяет 3am correlation
  // («у клиента upload-ID такой-то») без exposure'а самого UUID в публичных логах
  // (NFR-SEC-1c). SHA-256 первые 16 символов hex = 64 бита — достаточно для
  // unique correlation в окне нескольких часов, не достаточно для перебора.
  file_id_fingerprint: string | null;        // null до известного UUID
}

@Injectable()
export class TerminalLogger {
  constructor(private readonly logger: PinoLogger) {}
  log(e: TerminalEvent): void {
    const level = e.error_class ? 'error' : 'info';
    this.logger[level](e, e.event);   // request_id, ts, client_ip добавит pino-http
  }
}

// Хелпер для file_id_fingerprint:
import { createHash } from 'node:crypto';
export function fingerprint(uuid: string): string {
  return createHash('sha256').update(uuid).digest('hex').slice(0, 16);
}
```

`error_class` маппинг (NFR-OBS-1):
- magic-byte fail → `magic_byte_rejected`
- 413 → `size_exceeded`
- 408 → `timeout`
- 400 invalid_uuid → `invalid_uuid`
- 409 conflict → `conflict`
- 503 too-many-in-flight (ADR-005 семафор) → `too_many_in_flight`
- S3 PutObject/Complete 5xx → `s3_put_failed`
- DB INSERT error → `db_insert_failed`
- DB UPDATE error (ADR-004 шаг 6) → `db_update_failed`
- иное 5xx → `internal_error`

UUID файла (`files.id`) **НЕ** логируется в публичные info/warn/error-записи (NFR-SEC-1c); если оператор включает `LOG_LEVEL=debug` (env override), UUID попадает в отдельные debug-записи через `this.logger.debug({ file_id: ... }, ...)`. Debug-записи не покрываются обязательным контрактом NFR-OBS-1 и не используются для SLO-верификации.

Контракт-тест: golden-file тест в CI берёт пример каждого `event`, прогоняет через `LogTerminal.log()`, перехватывает stdout pino-output (через `pino.destination(streamMock)`), парсит JSON и проверяет, что все обязательные поля присутствуют и имеют корректные типы.

## Consequences

### Positive

- Объекция 4 ревью закрыта: контракт полей зафиксирован в `TerminalEvent` TypeScript-интерфейсе + golden-test, парсинг p95/p99 `duration_ms` и `http_status`-долей внешним SLO-toolchain работает без ошибок.
- `X-Request-Id` пробрасывается обратно клиенту через `onSend`-hook → клиентская сторона может ссылаться на конкретный лог при support-запросе.
- `request_id` распространяется через `AsyncLocalStorage` под капотом `nestjs-pino` → все subsequent log-записи (S3 retry, DB error) автоматически получают его, без ручной передачи.
- `Pino` производит ~10x быстрее `winston`; на 200 RPS пика логирование не становится bottleneck'ом.
- UUID файла отделён от обязательного контракта → NFR-SEC-1c соблюдается без специальной фильтрации логов внешним пайплайном.
- DI NestJS (`Logger` в любом провайдере через constructor injection) — единая точка для тестовых mock'ов и audit'а usage'ей.

### Negative

- **`AsyncLocalStorage` отрыв контекста**: известный класс багов, когда async-граница (`setImmediate`, `process.nextTick` в недавнем edge-case с user-defined callbacks, или сторонняя библиотека, использующая старый API) теряет ALS-контекст. Митигация: запрет на собственные использования ALS в этом сервисе сверх того, что инкапсулирует `nestjs-pino`; запрет на `setImmediate(callback)` без обёртки `als.run`; ESLint-rule на проекте.
- **Stdout-only без буфера**: при бешеном burst'е (>10k events/sec) write на pipe может блокировать handler-горутину. Для 200 RPS с одной log-записью per request это незначимо (200 events/sec). Если когда-нибудь пиковая нагрузка вырастет в десятки раз — потребуется async-handler (`pino.transport`), это новая ADR.
- **Нет sampling**: каждое upload-событие → одна log-запись. При 200 RPS = 200 lines/s × ~500 байт = 100 KB/s = 8.6 GB/день логов с одного pod'а. Это операционная стоимость хранения логов, ложится на NFR-OBS-1 «внешняя инфраструктура».
- **Контракт обязательных полей зафиксирован TypeScript-типом + golden-test'ом**, но если разработчик добавит новый код-путь и забудет вызвать `LogTerminal.log()` — терминальная запись окажется неполной. Митигация: `LogTerminal.log(e)` принимает `TerminalEvent` с required-полями, TypeScript-компилятор не даст вызвать частично; глобальный `ExceptionFilter` (ADR-005) обязан вызывать `LogTerminal.log()` на любом code-path выхода → integration-test «каждый response пишет ровно одну терминальную запись».
- **`error_class` — фиксированный union в TypeScript**; добавление нового кода ошибки требует расширения union и golden-test'а. Это feature, не bug, но операционно — мелкий burden.
- **`pino.stdTimeFunctions.isoTime` пишет в поле `time`, не `ts`**, как требует контракт NFR-OBS-1. Митигация: настроить `customProps` или transformer для переименования (тривиально через `formatters.log`).

## Open questions

- Стоит ли всё же логировать UUID файла на info-уровне для успешных upload'ов? NFR-SEC-1c говорит «логируется только во внутреннем уровне детализации» — `file_id_fingerprint` (hash 16 chars) уже даёт correlation; полный UUID — только debug-level. Граница согласована.

## Response to arch-review

Disagree-flag arch-review (`time → ts`, sync writer, `client_ip`) — **принят**. Decision-блок выше теперь содержит:
- `formatters.log` переименовывает `time → ts` явно — golden-test в CI парсит JSON и asserts наличие именно `ts`.
- `pino.destination({ sync: true })` для prod — терминальные записи не теряются при SIGKILL/OOM (ADR-006 failure scenario).
- `client_ip` извлекается из `X-Forwarded-For` (левый-самый, нормализованный) и пишется в каждое событие через `customProps`.
- `error_class` enum расширен: `db_update_failed` (для ADR-004 шаг 6 ошибок UPDATE) и `too_many_in_flight` (для ADR-005 семафора).

Disagree-flag arch-review #11 (per-stage timings + UUID fingerprint) — **принят** в полном объёме. `TerminalEvent` расширен четырьмя per-stage timing полями (`magic_byte_ms`, `db_pending_ms`, `s3_upload_ms`, `db_commit_ms`) и `file_id_fingerprint` (SHA-256 hex first 16 chars). Внешний SLO-toolchain получает достаточно сигнала для root-cause при p95-regress'е на NFR-LAT-1a; oncall может коррелировать клиентский upload-ID без exposure'а UUID в публичных логах.
