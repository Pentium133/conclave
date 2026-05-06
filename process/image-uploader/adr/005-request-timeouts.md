# ADR-005: HTTP-тайм-ауты и slowloris-защита через Fastify config + кастомный `MinRateTransform`

## Status

proposed

## Context

NFR-LAT-2 — обязательные верхние границы (накатано по объекции 2 ревью): (a) idle-timeout на чтение тела 30 секунд; (b) минимальная скорость передачи тела 1 Mbps в окне 30с после первого MB; (c) wall-clock 900 секунд на запрос; (d) код возврата `408 request_timeout`. Без этих контролей slowloris на body при 200 RPS пика (NFR-THR-1b) насыщает event-loop и keep-alive-пул за минуты и сжигает NFR-AVL-1 (43 мин/мес). Реализация на стеке ADR-001 (Node 22 LTS + NestJS 10 + FastifyAdapter).

- Drives: NFR-LAT-2a, NFR-LAT-2b, NFR-LAT-2c, NFR-LAT-2d, NFR-LAT-2e, NFR-AVL-1, NFR-THR-1, FR-8 (`request_timeout`)

## Alternatives

### Alternative A: Конфигурация `FastifyAdapter` (`connectionTimeout`, `requestTimeout`, `bodyLimit`) + кастомный `MinRateTransform` стрим в pipeline + AbortController per-request

- **Cost**: ~120 строк своего кода для `MinRateTransform` (Node `Transform` стрим со скользящим окном) + тесты.
- **Complexity**: тайм-ауты на сокете и запросе — конфигурационные ручки Fastify, single source. `MinRateTransform` — стандартный `Transform`-стрим со счётчиками bytes-per-second в ring-buffer'е (30 элементов = 30 секунд окно); встраивается в pipeline между `request.raw` и magic-byte peek (ADR-006/007).
- **Correctness**: 
  - `connectionTimeout: 30_000` (idle на сокете между приходящими байтами) → NFR-LAT-2a;
  - `requestTimeout: 900_000` (wall-clock на запрос целиком, начиная с первого байта заголовков) → NFR-LAT-2c;
  - `bodyLimit: 100 * 1024 * 1024` (104857600 байт) → FR-6;
  - `MinRateTransform({ minRateBps: 125_000, windowMs: 30_000, gracePrefixBytes: 1_048_576 })` в pipeline'е — NFR-LAT-2b. При нарушении окна стрим уничтожается через `transform.destroy(new RequestTimeoutError())`; `pipeline()` propagирует ошибку; ExceptionFilter мапит на 408.
  - Per-request `AbortController` создаётся в guard'е; `signal` пробрасывается через `request.raw['abortSignal']` в S3 SDK (`Upload({ abortController: ... })`) и в DB-клиент (для query cancellation). При срабатывании любого тайм-аута — `abortController.abort()` каскадно отменяет S3/DB и запускает компенсацию по ADR-004.
- **Operability**: ошибки `RequestTimeoutError` (от MinRateTransform), `FST_ERR_CONTENT_TYPE_BODY_TOO_LARGE` (Fastify, FR-6 → 413), `FST_ERR_CONNECTION_TIMEOUT` / `FST_ERR_REQUEST_TIMEOUT` (Fastify) — все ловятся в ExceptionFilter и логируются с `error_class='timeout'` или `error_class='size_exceeded'` (NFR-OBS-1). `request_id` propagируется через AsyncLocalStorage (см. ADR-008), поэтому 408-запись в логе корректно атрибутируется.
- **Verdict**: chosen — единственный путь, выполняющий NFR-LAT-2b (rate-floor) на Node-стеке; ни один HTTP-фреймворк Node-экосистемы не предоставляет минимальную скорость body как настройку.

### Alternative B: Положиться на ingress (NGINX/Envoy) для тайм-аутов

- **Cost**: 0 кода.
- **Complexity**: ingress-конфиг — отдельный артефакт, не в репозитории сервиса.
- **Correctness**: NFR-LAT-2e — реализация может ужесточать, но НЕ ослаблять. Если оператор конфигурит ingress с `client_body_timeout=60s` — NFR-LAT-2a (30s) нарушен. Сервис не имеет defense-in-depth. Объекция 2 ревью прямо требует, чтобы тайм-ауты были на сервисе, не «где-то выше».
- **Operability**: 408 от ingress — без `request_id` в логах сервиса (запрос не дошёл до handler), `error_class='timeout'` теряется (NFR-OBS-1).
- **Verdict**: rejected — нарушает defense-in-depth и NFR-LAT-2e.

### Alternative C: Только `FastifyAdapter` без `MinRateTransform` (полагаемся на `connectionTimeout` для всех slowloris-сценариев)

- **Cost**: 0 своего кода.
- **Complexity**: тривиально.
- **Correctness**: `connectionTimeout` срабатывает только при **полной** тишине ≥ 30 секунд. Атакующий, посылающий 1 байт каждые 29 секунд (≈ 8 bps в среднем), обходит idle-timeout полностью; на 200 RPS пика 50 таких сессий держатся часами. NFR-LAT-2b (минимальная скорость) прямо требует обнаружения этого.
- **Verdict**: rejected — не закрывает объекцию 2 ревью.

### Alternative D: Сторонний пакет `@fastify/rate-limit` или подобный

- **Cost**: транзитивная зависимость.
- **Complexity**: одна строка регистрации плагина.
- **Correctness**: `@fastify/rate-limit` ограничивает **частоту запросов**, не **скорость передачи тела внутри запроса**. Это другой риск (NFR-THR-1, не NFR-LAT-2b). Готового пакета для byte-rate-floor на body в Node-экосистеме нет.
- **Verdict**: rejected — решает другую задачу.

## Decision

Принят **`FastifyAdapter` config + `MinRateTransform` в pipeline + `AbortController` per-request**.

Конфигурация адаптера в `main.ts`:

```ts
const app = await NestFactory.create<NestFastifyApplication>(
  AppModule,
  new FastifyAdapter({
    connectionTimeout: 30_000,        // NFR-LAT-2a (idle на сокете)
    requestTimeout: 900_000,           // NFR-LAT-2c (wall-clock per request)
    bodyLimit: 100 * 1024 * 1024,      // FR-6
    keepAliveTimeout: 30_000,          // защита keep-alive idle
    maxRequestsPerSocket: 1000,         // защита от long-lived abuse-сокетов
    disableRequestLogging: true,        // логи под контролем nestjs-pino, ADR-008
  }),
);

// Отключаем дефолтный body-parser для octet-stream — handler получает Readable.
app.getHttpAdapter().getInstance().addContentTypeParser(
  'application/octet-stream',
  { parseAs: 'stream' },
  (req, payload, done) => done(null, payload),
);
```

`MinRateTransform` + **module-level WeakSet sweeper** (один глобальный таймер на pod, не per-request):

```ts
// libs/streams/min-rate.transform.ts
const ACTIVE_TRANSFORMS = new Set<MinRateTransform>();
let SWEEPER: NodeJS.Timeout | null = null;

function ensureSweeper(): void {
  if (SWEEPER) return;
  SWEEPER = setInterval(() => {
    for (const t of ACTIVE_TRANSFORMS) t.tick();
  }, 1000);
  SWEEPER.unref();
}

export class MinRateTransform extends Transform {
  private readonly window: number[] = new Array(30).fill(0);  // 30 × 1s
  private windowIdx = 0;
  totalBytes = 0;                                              // public — читается ADR-004 шаг 6
  private bytesAfterGrace = 0;

  constructor(
    private readonly minRateBps: number,           // 125_000 = 1 Mbps / 8
    private readonly windowMs: number,              // 30_000
    private readonly gracePrefixBytes: number,      // 1_048_576 (первый MB)
  ) {
    super();
    ensureSweeper();
    ACTIVE_TRANSFORMS.add(this);
  }

  _transform(chunk: Buffer, _enc: BufferEncoding, cb: TransformCallback): void {
    this.totalBytes += chunk.length;
    if (this.totalBytes > this.gracePrefixBytes) {
      this.bytesAfterGrace += chunk.length;
      this.window[this.windowIdx] += chunk.length;
    }
    cb(null, chunk);
  }

  /** Called by global sweeper once per second. Public для тестов. */
  tick(): void {
    this.windowIdx = (this.windowIdx + 1) % 30;
    this.window[this.windowIdx] = 0;
    if (this.totalBytes <= this.gracePrefixBytes) return;
    const sumBytes = this.window.reduce((a, b) => a + b, 0);
    const requiredBytes = this.minRateBps * (this.windowMs / 1000);
    if (sumBytes < requiredBytes) {
      this.destroy(new RequestTimeoutError('min body rate violated'));
    }
  }

  _final(cb: () => void): void { ACTIVE_TRANSFORMS.delete(this); cb(); }
  _destroy(err: Error | null, cb: (err: Error | null) => void): void {
    ACTIVE_TRANSFORMS.delete(this);
    cb(err);
  }
}
```

Стоимость: один `setInterval(1000)` на pod независимо от RPS; сложность тика O(N × 30) = O(N) где N = одновременные in-flight загрузки. На пике 50 одновременных загрузок (см. ADR-012 capacity model) — 1 итерация в секунду по 50 элементам, sub-millisecond event-loop time.

**Per-pod max-concurrent-uploads семафор** (defense-in-depth перед HPA):

```ts
// libs/concurrency/upload-semaphore.ts
@Injectable()
export class UploadSemaphore {
  private inFlight = 0;
  private readonly limit = parseInt(process.env.MAX_CONCURRENT_UPLOADS ?? '50', 10);

  async acquire(): Promise<void> {
    if (this.inFlight >= this.limit) {
      throw new ServiceUnavailableException({
        error: { code: 'too_many_in_flight', message: 'pod saturated, retry later' },
      });
    }
    this.inFlight++;
  }

  release(): void { this.inFlight = Math.max(0, this.inFlight - 1); }
  current(): number { return this.inFlight; }
}
```

Используется как guard в upload-handler ДО шага 3 (peek). При исчерпании — `503 Service Unavailable` с `error.code = 'too_many_in_flight'` (расширение FR-8 enum, не противоречит спеке: 503 — стандартный сигнал «retry later»). Численный лимит 50 согласован с capacity model в ADR-012; HPA масштабирует количество pod'ов при saturation rate `acquire-failures > 1%`.

В upload-handler'е (Fastify route, через NestJS controller с `@Req()`):

```ts
@Put('/upload')
async upload(@Req() req: FastifyRequest, @Res() reply: FastifyReply) {
  const ctrl = new AbortController();
  reply.raw.on('close', () => ctrl.abort());

  const stream = req.raw                                   // Node IncomingMessage
    .pipe(new MinRateTransform(125_000, 30_000, 1_048_576)); // NFR-LAT-2b

  // ... magic-byte peek (ADR-007) → BlobStore.put(stream, ctrl.signal) (ADR-002/006)
}
```

ExceptionFilter:

```ts
// libs/error/error.filter.ts
@Catch()
export class GlobalErrorFilter implements ExceptionFilter {
  catch(err: unknown, host: ArgumentsHost) {
    const reply = host.switchToHttp().getResponse<FastifyReply>();
    if (err instanceof RequestTimeoutError ||
        (err as any)?.code === 'FST_ERR_CONNECTION_TIMEOUT' ||
        (err as any)?.code === 'FST_ERR_REQUEST_TIMEOUT') {
      return reply.status(408).send({
        error: { code: 'request_timeout', message: 'request exceeded timeout limits' },
      });
    }
    if ((err as any)?.code === 'FST_ERR_CTP_BODY_TOO_LARGE') {
      return reply.status(413).send({
        error: { code: 'body_too_large', message: 'body exceeds 100 MB limit' },
      });
    }
    // ... остальные кодовые пути → FR-8b таблица
  }
}
```

## Consequences

### Positive

- Объекция 2 ревью закрыта buckle-to-bone: все три порога NFR-LAT-2 (a/b/c) реализованы в коде сервиса как defense-in-depth, независимо от ingress.
- При 200 RPS пика slowloris-сессии разрываются в ≤ 30 секунд (полный idle через `connectionTimeout`) или в 30 секунд после конца grace-prefix (`MinRateTransform`); event-loop не насыщается; NFR-AVL-1 защищён.
- `408 request_timeout` (FR-8) единым кодом покрывает все три условия (a/b/c); клиент по `error.code` понимает причину.
- `MinRateTransform` — стандартный Node `Transform`, прозрачно встраивается в pipeline между `request.raw`, magic-byte peek (ADR-007) и `Upload` (ADR-006); backpressure уважается.
- `AbortController.signal` пробрасывается в `@aws-sdk/lib-storage` `Upload` и в DB-клиент → корректная каскадная отмена при тайм-ауте; компенсация по ADR-004 запускается автоматически.

### Negative

- **30-секундное окно среднего ratio bps допускает спайк paus до 30 секунд в пределах окна** (если до этого скорость была высокой). Чисто математически окно — это сглаживание, не абсолютный пол; для clean abuse достаточно 1 байта в 1 секунду — это закроется идлом (a) через `connectionTimeout`, но 1 KB в секунду в течение 1 секунды и затем 0 байт 29 секунд — закроется идлом тоже, не rate-floor. Окно по идее закрывает «medium-fast slowloris», не «полный idle». Обе атаки закрыты, но разными правилами.
- `MinRateTransform` — свой код с ring-buffer и `setInterval` тиком; нужны юнит-тесты на race между `_transform` и `tick`. `setInterval(...).unref()` не блокирует выход процесса, но в контексте per-request стрима это таймер на каждый запрос (200 RPS = 200 активных интервалов) — overhead ~200×1ms callback'ов в секунду, незначимо.
- Wall-clock 900с (`requestTimeout`, NFR-LAT-2c) при 100 MB и реальной скорости 1 Mbps — это в обрез; легитимный клиент со скоростью 0.95 Mbps будет порезан на 408 в 99% случаев. NFR-LAT-2b нижняя граница — 1 Mbps, спека прямо это допускает; multipart-upload в нашем API НЕ поддерживается (FR-5). Это принимаемое следствие спеки.
- При большом количестве 408-ответов клиенты будут retry-ить; retry с тем же `X-Image-Id` попадёт в FR-12d / 409 conflict, если предыдущий запрос успел сделать INSERT в `pending` до tarpit. Это решается тем, что 408-путь в ADR-004 проходит DELETE pending-записи в компенсации перед возвратом ответа (через `AbortController` → `OnAbort` hook).
- Fastify `connectionTimeout` применяется ко всему сокету, включая keep-alive idle — это пересекается с `keepAliveTimeout`. На практике оба установлены в 30s, и разрыв соединения происходит по тому, что наступит первым; разница незначима.

## Open questions

- Стоит ли вынести параметры (idle, rate, window, grace-prefix, body-limit, max-concurrent-uploads) в ENV-переменные? NFR-LAT-2e говорит «реализация может ужесточать». Скорее да, default'ы фиксированы спекой; для prod-разводки полезно иметь ручки. Архитектурное ревью.
- Метрика `slowloris_disconnect_count` — out-of-scope (NFR-OBS-1 запрещает счётчики). Внешний оператор узнаёт о slowloris только через парсинг JSON-логов с `error_class='timeout'` — это принимаемое следствие отказа от метрик.

## Response to arch-review

Disagree-flag arch-review (per-request `setInterval` vs WeakSet sweeper) — **принят**. Decision-блок выше обновлён: один module-level `Set<MinRateTransform>` + один глобальный `setInterval(1000)` на pod, который перебирает активные стримы. Стоимость — те же ~80 строк кода, поведение детерминированное независимо от RPS. Дополнительно введён `UploadSemaphore` (limit 50 на pod, ENV-override) как defense-in-depth перед HPA и для tarpit-защиты «1 Mbps + 1 byte attack» — атакующий, прошедший `MinRateTransform`, всё равно занимает один из 50 слотов pod'а; 50 атакующих = насыщенный pod, новые запросы получают 503. HPA реагирует на saturation rate, новые pod'ы поднимаются.
