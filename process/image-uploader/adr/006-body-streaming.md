# ADR-006: Тело загружается потоково в S3 multipart, без буферизации на pod

## Status

proposed

## Context

FR-5 — один запрос, одно тело сырого `application/octet-stream`. FR-6 — до 100 MB. NFR-DEP-2 — stateless, эфемерный диск/RAM pod'а. NFR-THR-1b — 200 RPS пик (NFR-CAP-1 → 400 RPS на горизонте). Если десятки запросов одновременно буферизуют 100 MB в RAM/диск pod'а — OOM kill / disk-full / каскадный flapping подов (объекция 9 ревью отклонена разработчиком, но физика остаётся: при 50 одновременных 100 MB загрузках это 5 GB одновременных буферов на pod). FR-10 требует прочитать первые 32 байта для magic-byte (ADR-007) ДО сохранения. ADR-002 `BlobStore.put` принимает `Readable`. AWS SDK v3 (`@aws-sdk/lib-storage` `Upload`) поддерживает streaming multipart прямо из `Readable`.

- Drives: FR-5, FR-6, FR-10, NFR-DEP-2, NFR-THR-1, NFR-CAP-1

## Alternatives

### Alternative A: Полная буферизация тела в RAM pod'а до начала PutObject

- **Cost**: при 50 одновременных 100 MB upload'ах = 5 GB RSS на pod. Pod-limit 1–2 GB → OOM kill kubelet'ом.
- **Complexity**: тривиально (`buf = await readToBuffer(req.raw)` → `s3.send(new PutObjectCommand({Body: buf}))`).
- **Correctness**: при OOM kill — все in-flight запросы теряются (connection reset), бюджет NFR-AVL-1 сгорает быстро. Дополнительно: Fastify `bodyLimit` принудительно конструирует Buffer (если включён обычный body-parser), что эквивалентно этому варианту — и его мы как раз отключаем (см. ADR-001 `addContentTypeParser` с `parseAs: 'stream'`).
- **Operability**: Kubernetes restart_count растёт; flapping подов; readiness-probe бьёт.
- **Verdict**: rejected — несовместим с NFR-DEP-2 (stateless с эфемерным буфером — да, но в пределах разумных лимитов pod'а).

### Alternative B: Буферизация на эфемерный диск pod'а до начала PutObject

- **Cost**: ephemeralStorage limit нужно задавать ~10 GB на pod (50 × 100 MB + запас); это меняет cost-планирование ноды.
- **Complexity**: запись в tempfile (`fs.createWriteStream` через `pipeline`), затем второе чтение и стрим в S3 — лишний syscall-цикл и I/O.
- **Correctness**: лимит ephemeralStorage Kubernetes считает по async-инкременту → промахи возможны → kubelet evict-ит pod в середине upload'а.
- **Operability**: при evict in-flight файлы теряются; orphan-метаданные в БД (ADR-004 gc восстановит, но клиенты получают reset).
- **Verdict**: rejected — sub-optimal во всех осях.

### Alternative C: Стриминг `request.raw` напрямую в S3 multipart upload через `@aws-sdk/lib-storage` `Upload`; первые 32 байта peek'аются через `MagicBytePeekTransform`

- **Cost**: `Upload` использует `partSize` 8 MiB и `queueSize: 4` (параллельность part-upload'ов) → constant-memory ~32 MiB на запрос на parts + ~64 KiB на `MagicBytePeekTransform`-buffer. При 50 одновременных = ~1.6 GB RSS — укладывается в 2 GB pod limit.
- **Complexity**: один pipeline через `node:stream/promises` `pipeline()`: `request.raw → MinRateTransform (ADR-005) → MagicBytePeekTransform (ADR-007) → Upload.body`. Pipeline остаётся `Readable` всю дорогу; backpressure корректен по построению.
- **Correctness**: magic-byte (ADR-007) проверяется на peek'нутых 32 байтах ДО завершения первой part'ы; если sniff отрицательный — `Upload.abort()` отменяет multipart, S3 принимает `AbortMultipartUpload` и parts удаляются. FR-10 «файл в storage НЕ сохраняется» соблюдён: даже если первая part уже отправлена, без `CompleteMultipartUpload` объект НЕ становится видимым в бакете (S3 семантика).
- **Operability**: при ошибке/отмене (`AbortController.abort()` из ADR-005 или magic-byte fail) — `Upload.abort()` чистит частично загруженные parts; S3 lifecycle-rule `AbortIncompleteMultipartUpload` (operational рекомендация в README) — defense-in-depth для случая, когда сам процесс умер до Abort.
- **Verdict**: chosen — единственный способ обработать FR-6 при NFR-DEP-2 без OOM/disk-full.

### Alternative D: Pre-signed PUT URL — клиент льёт прямо в S3, минуя сервис

- **Cost**: 0 трафика через сервис.
- **Complexity**: нужен отдельный endpoint для запроса pre-signed URL → ломает FR-5 (один PUT с сырым телом — не несколько round-trip).
- **Correctness**: magic-byte (FR-10) невозможен — сервис не видит тело. Это блокер.
- **Operability**: размер тела не контролируется сервисом → FR-6 ломается (S3 enforce'ит свой лимит — не наш).
- **Verdict**: rejected — несовместим с FR-5 и FR-10.

## Decision

Принят **streaming через AWS SDK v3 `@aws-sdk/lib-storage` `Upload` (S3 multipart) + кастомный `MagicBytePeekTransform` для FR-10**.

Pipeline в upload-handler'е (учтён disagree-flag arch-review: peek ДО `CreateMultipartUpload`):

```ts
import { pipeline } from 'node:stream/promises';
import { Upload } from '@aws-sdk/lib-storage';
import { PassThrough } from 'node:stream';

@Put('/upload')
async upload(@Req() req: FastifyRequest, @Res() reply: FastifyReply) {
  const id = (req.headers['x-image-id'] as string | undefined) ?? randomUUIDv7();
  const ctrl = new AbortController();
  reply.raw.on('close', () => ctrl.abort());

  // ADR-005: семафор перед всем остальным (fast-fail при насыщении pod'а).
  await this.uploadSemaphore.acquire();
  try {
    const minRate = new MinRateTransform(125_000, 30_000, 1_048_576);  // ADR-005
    const peek = new MagicBytePeekTransform();                          // ADR-007

    // ── Шаг 3 (ADR-004): peek 32 байт ДО CreateMultipartUpload ──
    // Только peek, без запуска S3 pipeline'а. На отрицательном sniff
    // выходим до любых S3-API-вызовов — нулевая cost-amplification на abuse 415.
    const peekBuffer = await this.peekFirstBytes(req.raw, 32);
    const sniff = sniffMagicBytes(peekBuffer);
    if (!sniff) throw new InvalidFormatError();   // → 415 invalid_format

    // ── Шаг 4 (ADR-004): INSERT pending до открытия multipart ──
    const storage = await this.storageRepo.activeStorage();
    await this.fileRepo.insertPending(id, storage.id, sniff.mime);
    // Если CONFLICT (FR-12d) — выкинется ConflictError, никаких S3-API-call'ов.

    // ── Шаг 5 (ADR-004): теперь и только теперь открываем multipart ──
    const upload = new Upload({
      client: this.s3,
      params: {
        Bucket: storage.bucket,
        Key: id,
        Body: peek,                                // peek проксирует stream дальше
        ContentType: sniff.mime,                   // ADR-007
        ContentDisposition: 'attachment',          // ADR-010 (защита polyglot-XSS)
        Metadata: { 'x-content-type-options': 'nosniff' },  // ADR-010
        IfNoneMatch: '*',                          // FR-12d defense in depth
      },
      partSize: 8 * 1024 * 1024,                   // 8 MiB
      queueSize: 4,                                // 4 параллельных part'а
      leavePartsOnError: false,
      abortController: ctrl,
    });

    try {
      // peek уже инициализирован peekBuffer; pipeline продолжает с этого места.
      peek.write(peekBuffer);                       // вернуть peek-буфер обратно в pipeline
      await Promise.all([
        pipeline(req.raw, minRate, peek),
        upload.done(),
      ]);
    } catch (e) {
      await upload.abort().catch(() => {});
      await this.fileRepo.deletePending(id);       // ADR-004 компенсация
      throw e;
    }

    // ── Шаг 6 (ADR-004): UPDATE status='committed' + bytes ──
    await this.fileRepo.markCommitted(id, minRate.totalBytes);
    return reply.status(200).send({
      id,
      url: `${storage.public_base}/${id}`,         // ADR-010
    });
  } finally {
    this.uploadSemaphore.release();                // ADR-005
  }
}
```

`peekFirstBytes(req.raw, 32)` — синхронное чтение 32 байт из `req.raw` через `request.raw.once('readable')` и `request.raw.read(32)`; если короче 32 байт — `_flush`-эквивалент возвращает то, что есть, и sniff применяется к малому буферу (см. ADR-007). Возвращённый `peekBuffer` затем «вливается» обратно в pipeline через `peek.write(peekBuffer)` до запуска `pipeline()` — это не теряет first chunk и не требует unconsumed-buffer hack'а.

S3Client retry-config (явно зафиксирован):

```ts
const s3 = new S3Client({
  region: process.env.S3_REGION,
  endpoint: process.env.S3_ENDPOINT,
  maxAttempts: 2,                                  // 1 retry total (default 3 — слишком жадный)
  retryMode: 'standard',
  // standard backoff: 100ms × 2^attempt + jitter
});
```

Уменьшение `maxAttempts` с 3 (default AWS SDK) до 2 защищает от удержания part-buffer'ов в retry-loop при transient S3 5xx (см. arch-review failure scenario «AWS S3 region degradation»). При 50 одновременных upload'ах × 32 MiB part-buffer × 3 retry = до 4.8 GB в worst-case; с `maxAttempts: 2` — до 3.2 GB, что вписывается в 4 GB pod-limit (см. ADR-012 capacity model).

Для `LocalFS` — `pipeline(req.raw, minRate, peek, fs.createWriteStream(path, { flags: 'wx' }))` без буферизации; `wx` (write+exclusive) даёт conditional create (ADR-002 эквивалент `IfNoneMatch: *`).

S3 bucket lifecycle-rule (operational требование, не часть кода): `AbortIncompleteMultipartUpload` после 1 дня — чистит зависшие multipart'ы при катастрофическом падении pod'а до `Upload.abort()`.

## Consequences

### Positive

- Constant-memory обработка: peak RSS на pod ~1.6 GB при 50 одновременных upload'ах независимо от размера каждого — выполнимо в стандартных pod-limits.
- FR-10 соблюдается: при отрицательном результате magic-byte вызывается `upload.abort()`, `CompleteMultipartUpload` НЕ происходит, объект НЕ становится видимым в бакете.
- `Upload({ leavePartsOnError: false, abortController })` + bucket lifecycle `AbortIncompleteMultipartUpload` — двухслойная защита от orphan parts.
- Эфемерный диск pod'а вообще не используется для тела — disk-full исключён по построению.
- `pipeline()` из `node:stream/promises` — стандартный Node-механизм с корректным backpressure и propagation ошибок; не требует ручных слушателей `'error'`/`'close'`.
- `IfNoneMatch: '*'` в `Upload.params` — defense-in-depth для FR-12d (collision); если две конкурентных загрузки с тем же UUID одновременно дошли до S3 (что не должно случиться благодаря ADR-004 INSERT-first), вторая получит `412 Precondition Failed`.

### Negative

- **8 MiB partSize фиксирован**: для файлов < 8 MiB multipart-обвязка избыточна (один part-upload = три API-call'а: CreateMultipartUpload + UploadPart + CompleteMultipartUpload вместо одного PutObject). При 50 RPS среднем размере, скажем, 2 MiB — это ~150 лишних S3-запросов в секунду. Стоимость 5 USD за 1 млн запросов → ~$2/день. Принимаемая операционная цена за единый код-путь.
- `MagicBytePeekTransform` буферизует первые 32 байта в `internal Buffer`, и пока не накопил 32 байта — НЕ выпускает данные дальше в S3. Это стартовая задержка ≈ 1 RTT клиента, незначима.
- При ошибке S3 multipart, если `upload.abort()` не успел (network partition / kill -9 контейнера), parts висят в бакете максимум сутки (lifecycle rule). Это операционный долг; стоимость хранения parts ничтожна.
- `@aws-sdk/lib-storage` `Upload.abort()` — асинхронный (отправляет `AbortMultipartUpload` API call); если он сам тоже упал, defense-in-depth полностью на bucket lifecycle. Это допустимо.
- `queueSize: 4` параллелит part-upload'ы внутри одного запроса — для маленьких файлов это лишний overhead. Альтернатива: для тел < 8 MiB после peek использовать прямой `PutObjectCommand` (single-shot). Усложняет код-путь — отложено на оптимизацию по факту.
- AWS SDK v3 модулярный: каждый клиент — отдельный пакет (`@aws-sdk/client-s3`, `@aws-sdk/lib-storage`). Total install ≈ 4 MiB на диске; на startup ~150 ms parse. Принимаемое.

## Open questions

- Стоит ли динамически переключаться между single-shot `PutObjectCommand` (для тел < 8 MiB, известных через peek + Content-Length-эстимейт) и multipart `Upload`? Усложняет код, но экономит S3-API-вызовы. Архитектурное ревью.
- 8 MiB partSize выбран как компромисс. Для файлов 50–100 MB больший partSize (16/32 MiB) ускорил бы upload, но увеличил бы peak memory (queueSize × partSize). Профилирование на NFR-LAT-1 — отдельный таск.
- `IfNoneMatch: '*'` в `PutObject`/`Upload` — поддерживается AWS S3 (с 2024-08), MinIO 2024+, прочие S3-совместимые провайдеры — частично. Если выбран провайдер без поддержки, защита FR-12d ложится только на unique-constraint в БД (ADR-003). Документировать в operational README как pre-condition выбора S3-вендора.

## Response to arch-review

Disagree-flag arch-review (peek ДО `CreateMultipartUpload`) — **принят**. Decision-блок выше переписан: 32 байта peek'аются синхронно из `req.raw` через `read(32)` ДО любых S3-API-вызовов; `Upload` создаётся **только** после успешного sniff'а. Adversarial cost-amplification (атакующий генерирует 2 S3-API-call'а на каждый 415-payload) устранена. Дополнительно: `maxAttempts: 2` в `S3Client` config для ограничения retry-loop memory (см. failure scenario «AWS S3 region degradation»); memory-limit рекомендация для pod'а — в ADR-012 (capacity model).
