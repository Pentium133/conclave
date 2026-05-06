# ADR-009: Graceful shutdown — `app.enableShutdownHooks()` + Fastify `app.close()` + readiness/liveness через `@nestjs/terminus`

## Status

proposed

## Context

NFR-DEP-3 (накатано по объекции 7 ревью): на SIGTERM сервис обязан (a) перевести readiness в NotReady; (b) дождаться in-flight до drain-окна ≥ 900 секунд (= NFR-LAT-2c wall-clock max — иначе rolling-update прервёт 100 MB upload'ы); (c) принудительно закрыть по истечении и применить FR-12c компенсацию; (d) readiness проверяет БД и storage; (e) liveness проверяет только TCP/процесс — отделение от readiness исключает каскадный рестарт при кратковременной недоступности БД/S3. NFR-AVL-1 — каждый rolling-update не должен сжигать бюджет 43 мин/мес. Реализация на стеке ADR-001 (Node 22 LTS + NestJS 10 + FastifyAdapter).

- Drives: NFR-DEP-3a, NFR-DEP-3b, NFR-DEP-3c, NFR-DEP-3d, NFR-DEP-3e, NFR-AVL-1, NFR-DEP-2 (rolling update)

## Alternatives

### Alternative A: `app.enableShutdownHooks()` + `OnApplicationShutdown` lifecycle + Fastify `app.close()` + `@nestjs/terminus` для probe-эндпоинтов + `terminationGracePeriodSeconds=930`

- **Cost**: `@nestjs/terminus` — официальный пакет NestJS, ~50 KB транзитивно; кастомный indicator для S3 health-check ~30 строк.
- **Complexity**: NestJS из коробки маршрутизирует `SIGTERM`/`SIGINT` к `app.close()` через `app.enableShutdownHooks()`; lifecycle-хуки `OnApplicationShutdown` в каждом модуле декларативно закрывают свои ресурсы (DB pool, S3 client, custom timers). Probe-controller — два декорированных handler'а на `/healthz/ready` и `/healthz/live`.
- **Correctness**: `app.close()` вызывает Fastify `app.close()` → ждёт активных запросов до конца их `requestTimeout` (900s, ADR-005) ИЛИ до явного abort. Per-handler `AbortController` (ADR-005) пробрасывается в S3 SDK и DB-клиент → при cancel'е компенсация (ADR-004) запускается каскадно. `terminationGracePeriodSeconds=930` (= 900 drain + 8 readiness propagation + 22 buffer) гарантирует, что Kubernetes не пошлёт `SIGKILL` до завершения drain-окна.
- **Operability**: `@nestjs/terminus` `HealthCheckService` — стандартный паттерн NestJS, отлично знаком operators-команде. Custom health-indicator'ы для PostgreSQL (`TypeOrmHealthIndicator` или `MikroOrmHealthIndicator`, в зависимости от выбора ORM в ADR-003) и S3 (custom indicator с `HeadBucketCommand`). Liveness — `HealthCheckService` без indicator'ов, просто 200 OK.
- **Verdict**: chosen — единственный путь, дающий чистое NFR-DEP-3 идиоматично для NestJS.

### Alternative B: Force-close на SIGTERM (никакого draining)

- **Cost**: 0 кода (по дефолту Node принимает `SIGTERM` как синоним `process.exit(0)`).
- **Complexity**: тривиально.
- **Correctness**: каждый rolling update прервёт все активные 100 MB upload'ы (объекция 7 ревью буквально). Бюджет NFR-AVL-1 сгорает за один деплой.
- **Operability**: операторам пришлось бы избегать деплоев — несовместимо с NFR-DEP-2 «rolling update».
- **Verdict**: rejected — нарушает NFR-DEP-3 и NFR-AVL-1.

### Alternative C: PreStop hook на pod без in-process draining

- **Cost**: только конфиг k8s.
- **Complexity**: PreStop запускает `sleep 30 && kill -TERM 1` или подобное.
- **Correctness**: PreStop работает ДО SIGTERM, даёт kube-proxy удалить pod из endpoints. Это полезное дополнение, но НЕ заменяет драинг in-process: после SIGTERM у нас всё равно есть активные 100 MB upload'ы, и без `app.close()` они будут force-killed kubelet'ом.
- **Operability**: смесь логики между k8s YAML и кодом — сложнее дебажить.
- **Verdict**: rejected отдельно, но **частично включён** в выбранный вариант через рекомендацию PreStop `sleep 5` + readiness flip (defense-in-depth для пропагации через kube-proxy).

### Alternative D: Кастомные probe handler'ы без `@nestjs/terminus`

- **Cost**: 0 зависимостей.
- **Complexity**: ручной handler с `db.query('SELECT 1')` и `s3.send(new HeadBucketCommand({...}))` + atomic readiness-flag.
- **Correctness**: технически эквивалентно terminus — все нужные проверки можно реализовать руками.
- **Operability**: теряется стандартный formatting ответа (`@nestjs/terminus` пишет JSON `{ status: 'ok', info: {...}, error: {...} }` — операторам/dashboard'ам легче парсить); другие микросервисы в монорепе, скорее всего, уже используют terminus.
- **Verdict**: rejected — выигрыш минимален, проигрыш в операционной согласованности с остальными микросервисами.

## Decision

Принят **`app.enableShutdownHooks()` + `OnApplicationShutdown` + `@nestjs/terminus` + readiness-flag с pre-shutdown задержкой**.

Bootstrap (`main.ts`):

```ts
const app = await NestFactory.create<NestFastifyApplication>(/* ... */);
app.enableShutdownHooks();                       // NestJS перехватывает SIGTERM/SIGINT
await app.listen({ port: 8080, host: '0.0.0.0' });
```

`HealthModule` (с per-pod jitter и sliding-window — учтено по arch-review #3):

```ts
@Controller('healthz')
export class HealthController {
  // Per-pod jitter — random 0–2с задержка ПЕРЕД каждым readiness-check'ом.
  // Цель: 4 pod'а не уходят в NotReady в lockstep при 30-сек transient
  // RDS failover; флапы рассинхронизируются. Jitter одинаков в течение
  // pod'а (рассчитан при старте), не на каждый probe.
  private readonly jitterMs = Math.floor(Math.random() * 2000);

  // Sliding-window: запоминаем последние 10 результатов probe'а; ready=true
  // если ≥ 5 из последних 10 успешны. Абсорбирует transient blips ≤ 25 секунд
  // (5 окон × 5-сек period) без флапа всех pod'ов одновременно.
  private readonly window: boolean[] = [];
  private static readonly WINDOW_SIZE = 10;
  private static readonly QUORUM = 5;

  constructor(
    private readonly health: HealthCheckService,
    private readonly db: TypeOrmHealthIndicator,
    private readonly s3: S3HealthIndicator,
    private readonly shutdown: ShutdownState,
  ) {}

  @Get('ready')
  @HealthCheck()
  async ready(): Promise<HealthCheckResult> {
    if (this.shutdown.isShuttingDown()) {
      throw new ServiceUnavailableException({ status: 'shutting_down' });
    }
    if (this.jitterMs > 0) {
      await new Promise((r) => setTimeout(r, this.jitterMs));
    }
    let ok: boolean;
    try {
      await this.health.check([
        () => this.db.pingCheck('database', { timeout: 1000 }),
        () => this.s3.headBucket('storage', { timeout: 1000 }),
      ]);
      ok = true;
    } catch {
      ok = false;
    }
    // Update sliding window
    this.window.push(ok);
    if (this.window.length > HealthController.WINDOW_SIZE) this.window.shift();
    const successes = this.window.filter(Boolean).length;
    if (successes >= HealthController.QUORUM) {
      return { status: 'ok', info: {}, error: {}, details: {} };
    }
    throw new ServiceUnavailableException({ status: 'not_ready_quorum_lost' });
  }

  @Get('live')
  liveness() {
    return { status: 'ok' };  // NFR-DEP-3e — TCP/процесс жив
  }
}
```

Эффект: при 30-секундном RDS failover 4 pod'а получают неудачные probes в разное время (jitter 0–2 sec); sliding-window требует ≤ 5 неудач в окне 10 чтобы упасть в NotReady. При 30-сек failover'е каждый pod получит 6 unsuccessful probes (30 / 5sec period), что достаточно для трипа QUORUM-логики, **но** distributed во времени между pod'ами — load balancer всегда имеет ≥ 1 ready pod в окне переходного состояния. NFR-AVL-1 защищён.

`S3HealthIndicator` (custom):

```ts
@Injectable()
export class S3HealthIndicator extends HealthIndicator {
  constructor(@Inject(S3_CLIENT) private readonly s3: S3Client) { super(); }
  async headBucket(key: string, opts: { timeout: number }): Promise<HealthIndicatorResult> {
    try {
      await this.s3.send(
        new HeadBucketCommand({ Bucket: process.env.S3_BUCKET! }),
        { abortSignal: AbortSignal.timeout(opts.timeout) },
      );
      return this.getStatus(key, true);
    } catch (e) {
      throw new HealthCheckError('storage unreachable',
        this.getStatus(key, false, { message: (e as Error).message }));
    }
  }
}
```

`ShutdownState` сервис (singleton с readiness-flag):

```ts
@Injectable()
export class ShutdownState implements OnApplicationShutdown {
  private shuttingDown = false;
  isShuttingDown() { return this.shuttingDown; }
  async onApplicationShutdown() {
    // Step 1: flip readiness — следующий /healthz/ready отдаст 503. NFR-DEP-3a.
    this.shuttingDown = true;
    // Step 2: дать kube-proxy время удалить pod из endpoints (~8 секунд).
    await new Promise((r) => setTimeout(r, 8_000));
    // Step 3: NestJS сам вызовет app.close() после всех OnApplicationShutdown,
    //         что приведёт к Fastify app.close() → drain in-flight до requestTimeout (900s).
    //         NFR-DEP-3b. Per-handler AbortController срабатывает по таймауту (ADR-005).
  }
}
```

Закрытие подключений к зависимостям через lifecycle-хуки в соответствующих модулях:

```ts
@Injectable()
export class S3ClientProvider implements OnApplicationShutdown {
  constructor(@Inject(S3_CLIENT) private readonly s3: S3Client) {}
  async onApplicationShutdown() {
    this.s3.destroy();   // закрывает HTTP keep-alive pool AWS SDK
  }
}
// Аналогично для DB-клиента (см. ADR-003 ORM-зависимый close-вызов).
```

K8s manifest (не код, но документировано в README operational части):

```yaml
spec:
  terminationGracePeriodSeconds: 930   # 900 drain + 8 readiness-prop + 22 buffer; NFR-DEP-3b
  containers:
  - name: image-uploader
    livenessProbe:
      httpGet: { path: /healthz/live, port: 8080 }
      periodSeconds: 10
      failureThreshold: 3
      timeoutSeconds: 2
    readinessProbe:
      httpGet: { path: /healthz/ready, port: 8080 }
      periodSeconds: 5
      failureThreshold: 2     # ~10s до NotReady; NFR-DEP-3a
      timeoutSeconds: 2
    lifecycle:
      preStop:
        exec: { command: ["sleep", "5"] }   # defense-in-depth для kube-proxy propagation
```

## Consequences

### Positive

- Объекция 7 ревью закрыта буквально: `terminationGracePeriodSeconds=930s` ≥ 900s (NFR-DEP-3b), in-flight 100 MB upload'ы не прерываются rolling-update'ом.
- Readiness/Liveness разделение (NFR-DEP-3d/e) исключает каскадный restart pod'ов при кратковременной недоступности БД или S3 — kubelet не убьёт pod, потому что liveness не зависит от зависимостей.
- Readiness падает за ≤10 секунд при потере БД/storage (failureThreshold=2 × period=5s) → load balancer перестаёт направлять новые соединения, in-flight продолжают.
- При drain-overflow per-handler `AbortController.abort()` (ADR-005) триггерит ADR-004 компенсацию через `ctrl.signal` → orphan-метаданные/тела чистятся best-effort до force-close.
- `OnApplicationShutdown` lifecycle-хуки декларативно закрывают каждую зависимость (S3 client, DB pool, custom timers) — нет глобальной cleanup-функции, поведение распределено по модулям, которые владеют ресурсом.
- `@nestjs/terminus` JSON-формат ответа health-check'а согласован с другими микросервисами монорепа — единый dashboard.

### Negative

- **930 секунд `terminationGracePeriodSeconds`** — это 15.5 минут на pod при rolling-update. Для деплоя из 4 pod'ов с replicas-rollout по одному это до часа на полный rollout. CI/CD должен это учитывать; принимаемый trade-off против разрыва in-flight upload'ов.
- **8 секунд sleep в `OnApplicationShutdown` ДО app.close()** — мёртвое время; новые соединения, попавшие в окно (когда readiness уже NotReady, но kube-proxy ещё не удалил из endpoints), всё равно дойдут до сервиса. Они принимаются и обрабатываются нормально — это не плохо, просто "wasted" на рестартующем поде.
- **Readiness-probe делает `SELECT 1` к БД и `HeadBucket` к S3 на каждый цикл** (5 секунд) от каждого pod'а. При 4 pod'ах = 0.8 RPS на БД и storage чисто probe-нагрузки. Незначимо, но в учёте есть.
- **Если в момент shutdown возникает ошибка на `db.pingCheck`** (transient), readiness-probe начинает отдавать 503 ВО ВРЕМЯ drain — это OK (мы и так уже NotReady), но если ошибка случилась ДО shutdown, мы потеряем валидный pod из endpoints на flap'е. Принимаемое следствие отделения NFR-DEP-3d.
- **Force-close при drain-overflow** (NFR-DEP-3c) оставляет orphan'ы на best-effort, NFR-DUR-1 это допускает; gc-процесс ADR-004 чистит их через 15 минут.
- **NestJS lifecycle: `OnApplicationShutdown` хуки выполняются последовательно**, не параллельно (по дефолту `app.close()` идёт сверху вниз по dependency-graph). Если каждый close занимает ≤ 1 секунды, суммарно укладываемся в drain-окно с запасом; но если кто-то добавит долгий `OnApplicationShutdown`, drain-окно может быть исчерпано до того, как Fastify дойдёт до in-flight requests. Митигация: code-review-discipline: `OnApplicationShutdown` должен возвращать «быстро» (< 5s).

## Open questions

- Должен ли readiness-probe в режиме graceful-shutdown отвечать 200 для уже-открытых соединений (чтобы избежать ложного отвала балансера на keep-alive) и 503 только для новых? Технически невозможно отличить — все запросы идут через тот же handler. Принимаемое.
- Стоит ли сделать health-check кэшируемым (TTL 1 секунда), чтобы при `periodSeconds: 5 × 4 pods = 0.8 RPS` пинг БД не занимал ресурс? Микро-оптимизация; отложено.
- `process.on('SIGTERM')` vs `app.enableShutdownHooks()` — последний регистрирует свой listener; если в монорепо есть другие модули, регистрирующие свои handler'ы, может возникнуть гонка. NestJS гарантирует, что его handler идёт последним и ждёт остальных через lifecycle-graph; но cross-cutting логирование/observability shutdown timeline стоит делать через единый `ShutdownState` сервис, а не через сторонние listener'ы. Code-review-discipline.

## Response to arch-review

Disagree-flag arch-review (бинарная readiness в lockstep) — **принят**. Decision-блок обновлён двумя независимыми механизмами:
1. **Per-pod jitter** (random 0–2с при старте pod'а) — 4 pod'а не делают probe одновременно даже при синхронном старте.
2. **Sliding-window quorum** (5 of last 10 probes) — transient blip ≤ 25 секунд абсорбируется без падения в NotReady; 30-секундный RDS failover пробивает quorum, но в разное время на разных pod'ах (благодаря jitter).

**OnApplicationShutdown ordering** (response на arch-review #3 / #1): NestJS lifecycle-graph гарантирует обратный порядок к dependency-tree при `app.close()`. Зафиксированный порядок остановки:
1. **gc-задача (`@nestjs/schedule`)** — останавливается **первой**, до закрытия БД / S3, чтобы in-flight gc-batch имел до 30 секунд через AbortController на завершение или откат транзакции.
2. **Fastify HTTP-сервер** — после gc; начинает draining in-flight upload'ов до `requestTimeout: 900_000` или AbortController-cancel.
3. **S3 client** — после HTTP-сервера; `s3.destroy()` закрывает keep-alive pool.
4. **DB connection pool (TypeORM)** — последним; гарантирует, что и gc, и upload-handler-compensation, и UPDATE-finalize успели завершить свои транзакции.

**Security-hotfix escape-hatch** (response на arch-review #3 / Group C #3): **не вводится** в этой итерации. Принимаемое ограничение: до 1 часа на полный rolling-update 4-pod'ового деплоя при наличии in-flight upload'ов. Mitigation на сторону операций: (a) для критических CVE доступен emergency-path — снизить `terminationGracePeriodSeconds` до 60 на момент hotfix-релиза через однократный k8s manifest patch (это одна `kubectl patch deployment` + последствие — разрыв in-flight 100 MB upload'ов в момент hotfix); (b) blue-green / canary deployment как полноценный механизм рассмотрен и отложен до отдельного ADR при необходимости (out-of-scope текущей итерации). Принципиальное обоснование: 1-часовой rolling — операционно-приемлемое окно для CVE-класса серьёзности, требующего hotfix; мгновенный split-rollout добавил бы значительную инфраструктурную сложность (двойной capacity, traffic-split логика, two-phase migration), несоразмерную NFR этого сервиса.
