# ADR-007: Magic-byte валидация — табличный sniffer первых 32 байт через `MagicBytePeekTransform`

## Status

proposed

## Context

FR-10 — содержимое валидируется по magic-byte, клиентский `Content-Type` игнорируется. FR-11 — whitelist ровно из 4 форматов с конкретными сигнатурами:
- JPEG: `FF D8 FF` (offset 0)
- PNG: `89 50 4E 47 0D 0A 1A 0A` (offset 0)
- WebP: `RIFF` (offset 0–3) + `WEBP` (offset 8–11)
- GIF: `GIF87a` или `GIF89a` (offset 0)

Файлы, не совпавшие ни с одной — отклоняются `415 invalid_format` (FR-8). `Content-Type` ответа сервиса (и метаданные объекта в S3) выставляется ИЗ результата sniffer'а (объекция 3 ревью была отклонена разработчиком, но FR-10 явно запрещает доверять клиентскому Content-Type — отсюда необходимость детерминированного маппинга format → MIME). FR-12 порядок коммита (ADR-004) требует, чтобы валидация прошла ДО шага 5 (PutObject completion).

- Drives: FR-10, FR-11, FR-8 (`invalid_format`), NFR-OBS-1 (`detected_format`)

## Alternatives

### Alternative A: Табличный sniffer — массив записей `{format, mimeType, minLen, match(buf): boolean}`, проверка одним проходом, реализован как Node `Transform`-стрим

- **Cost**: ~80 строк TypeScript (`MagicBytePeekTransform` + таблица).
- **Complexity**: одна функция `sniffMagicBytes(head: Buffer): { format; mime } | null`. Таблица — единственный источник истины для FR-11. Стрим буферизует первые 32 байта во `internal Buffer`, выполняет sniff и пропускает данные дальше; backpressure уважается через `this.push(chunk)`.
- **Correctness**: каждый паттерн — точная последовательность из FR-11; для GIF — две альтернативные сигнатуры; для WebP — сравнение по двум диапазонам [0:4] и [8:12]. Длина peek'а — 32 байта (FR-10 «~16–32 байта»). Прямое отображение спецификации в код, легко покрыть unit-тестами по таблице.
- **Operability**: при добавлении формата — добавить одну строку в таблицу (но это потребует пересмотра whitelist'а и FR-11; out-of-scope).
- **Verdict**: chosen — простой, прямолинейный, тестируемый.

### Alternative B: Сторонний пакет `file-type` (npm)

- **Cost**: транзитивная зависимость; ~1 MB в node_modules.
- **Complexity**: один вызов `await fileTypeFromBuffer(head)`.
- **Correctness**: `file-type` распознаёт ~150 форматов, включая HTML, XML, SVG, PDF, ZIP, RAR, 7Z. FR-11 явно требует whitelist из 4 форматов; доверять `file-type` для отбраковки — нельзя (он скажет `image/svg+xml` для SVG, и нам надо это отвергнуть как явно исключённый формат). Сводится к: вызвать → проверить, что результат ∈ {jpeg, png, webp, gif} → отбросить остальное. Работоспособно, но (а) увеличивает blast-radius при изменении поведения пакета (новая мажорная версия может сместить таблицу или добавить ложные срабатывания); (б) не даёт прямого 1:1 с FR-11; (в) `file-type` читает до **4100 байт** для надёжного определения (документировано) — больше, чем FR-10 «16–32 байта», что увеличивает peek-buffer и слегка ослабляет принцип «минимальное чтение до решения».
- **Operability**: каждое обновление пакета может сместить поведение — нет фиксированного контракта; supply-chain аудит на каждый минор.
- **Verdict**: rejected — потеря контроля над whitelist'ом + dependency на сторонний sniffer, не задокументированный спекой.

### Alternative C: Web Streams API + sniff через `ReadableStream.tee()` и async-проверка

- **Cost**: 0 зависимостей.
- **Complexity**: Node Web Streams (`ReadableStream`) и Node Streams (`stream.Readable`) совместимы через `Readable.toWeb()`/`Readable.fromWeb()`, но переключение туда-обратно в pipeline (Fastify даёт Node `Readable`, AWS SDK ждёт Node `Readable`) добавляет конверсии. `tee()` дублирует поток — пик памяти удваивается на peek-окне.
- **Correctness**: эквивалентно Alternative A.
- **Operability**: смесь двух Streams API в одном pipeline'е — лишняя когнитивная нагрузка для on-call в 3am.
- **Verdict**: rejected — Node `Transform` проще и идиоматичнее для Node-stack'а ADR-001.

## Decision

Принят **табличный sniffer на 32 байта, реализованный как `MagicBytePeekTransform` (Node `Transform`-стрим)**.

```ts
// libs/magic-byte/sniffer.ts
export type ImageFormat = 'jpeg' | 'png' | 'webp' | 'gif';

interface MagicEntry {
  format: ImageFormat;
  mime: `image/${ImageFormat}`;
  minLen: number;
  match: (b: Buffer) => boolean;
}

const TABLE: readonly MagicEntry[] = [
  { format: 'jpeg', mime: 'image/jpeg', minLen: 3,
    match: (b) => b.length >= 3 && b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF },
  { format: 'png',  mime: 'image/png',  minLen: 8,
    match: (b) => b.length >= 8 && b.subarray(0, 8).equals(
      Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) },
  { format: 'webp', mime: 'image/webp', minLen: 12,
    match: (b) => b.length >= 12
      && b.subarray(0, 4).equals(Buffer.from('RIFF', 'ascii'))
      && b.subarray(8, 12).equals(Buffer.from('WEBP', 'ascii')) },
  { format: 'gif',  mime: 'image/gif',  minLen: 6,
    match: (b) => b.length >= 6 && (
      b.subarray(0, 6).equals(Buffer.from('GIF87a', 'ascii')) ||
      b.subarray(0, 6).equals(Buffer.from('GIF89a', 'ascii'))) },
];

export function sniffMagicBytes(head: Buffer): { format: ImageFormat; mime: string } | null {
  for (const e of TABLE) {
    if (e.match(head)) return { format: e.format, mime: e.mime };
  }
  return null;
}

// libs/magic-byte/peek.transform.ts
export class MagicBytePeekTransform extends Transform {
  private buf: Buffer = Buffer.alloc(0);
  private decided = false;
  private detected: ImageFormat | 'none' = 'none';
  private detectedMime: string | null = null;

  _transform(chunk: Buffer, _enc: BufferEncoding, cb: TransformCallback): void {
    if (this.decided) { cb(null, chunk); return; }
    this.buf = Buffer.concat([this.buf, chunk]);
    if (this.buf.length >= 32) {
      const sniff = sniffMagicBytes(this.buf.subarray(0, 32));
      this.decided = true;
      if (!sniff) {
        cb(new InvalidFormatError('magic-byte mismatch'));   // ExceptionFilter → 415
        return;
      }
      this.detected = sniff.format;
      this.detectedMime = sniff.mime;
      cb(null, this.buf);                                     // отправляем накопленное дальше
      this.buf = Buffer.alloc(0);
    } else {
      cb();                                                   // ждём ещё байт
    }
  }

  _flush(cb: TransformCallback): void {
    // Тело короче 32 байт. Пробуем sniff на том, что есть.
    if (!this.decided) {
      const sniff = this.buf.length >= 12 ? sniffMagicBytes(this.buf) : null;
      if (!sniff) { cb(new InvalidFormatError('body too short or unknown format')); return; }
      this.detected = sniff.format;
      this.detectedMime = sniff.mime;
      cb(null, this.buf);
      return;
    }
    cb();
  }

  detectedFormat(): ImageFormat | 'none' { return this.detected; }
  detectedMimeType(): string | null { return this.detectedMime; }
}
```

`MagicBytePeekTransform` встраивается в pipeline upload-handler'а (ADR-006) между `MinRateTransform` (ADR-005) и `Upload.body`. Отрицательный результат sniff'а превращается в `InvalidFormatError` через `cb(err)`; `pipeline()` propagирует ошибку, `Upload.abort()` отменяет multipart, ExceptionFilter мапит на `415 invalid_format` (FR-8).

При успехе — `peek.detectedFormat()` пишется в `files.content_type` (ADR-003) и в `detected_format` JSON-лога (NFR-OBS-1); `peek.detectedMimeType()` выставляется как `Content-Type` метаданное объекта S3 (`Upload({ params: { ContentType: ... } })`).

Peek-длина — 32 байта; фактически достаточно 12 (max из minLen). 32 — запас на случай будущих whitelist-расширений и для гарантии, что short-read однозначно даёт `null` от sniff'а.

## Consequences

### Positive

- Прямое 1:1 отображение FR-11 в код; unit-тест каждой строки таблицы — по одному test-case на формат + по одному negative case.
- Никаких внешних зависимостей; supply-chain поверхность не расширяется (`Buffer` и `node:stream` — stdlib).
- Sniffer запускается ПЕРЕД любой записью (FR-10 «файлы, не прошедшие magic-byte валидацию, в хранилище НЕ сохраняются и метаданные о них в БД НЕ записываются») благодаря тому, что `_transform` возвращает `cb(error)` ДО `this.push(chunk)` при отрицательном результате — pipeline разрушается, `Upload.body` ничего не получает, `Upload.abort()` чистит multipart.
- Детерминированный mime-type, выставляемый в S3-метаданном объекта, — компенсирует часть риска объекции 3 ревью (stored-XSS через полиглот): даже если объекция отклонена и `X-Content-Type-Options: nosniff` не выставляется на CDN, сам S3-объект имеет правильный image/* MIME, и при прямом доступе через S3 API браузер получает его.
- `format` доступен для NFR-OBS-1 поля `detected_format` без дополнительных вычислений.
- `Transform`-стрим встраивается в `pipeline()` идиоматично; backpressure уважается; ошибки автоматически закрывают весь pipeline.

### Negative

- Sniffer проверяет только сигнатуру контейнера, не валидирует его внутреннюю структуру. Полиглот «JPEG SOI + ZIP/HTML/SVG body» проходит проверку (объекция 3 ревью прямо описала этот сценарий и была отклонена разработчиком). Этот риск принят на уровне спеки.
- WebP VP8X с extended chunk и GIF89a с анимацией принимаются (объекция 10 ревью — отклонена). Если в будущем выявится CVE декодера VP8X — whitelist потребует сужения; пересмотр FR-11.
- При short-read (тело короче 12 байт, минимальная длина для самого «толстого» формата WebP) ответ — `415 invalid_format`, что технически некорректно (тело могло быть «оборвано», а не невалидно). Но различить «оборвано» и «невалидно» по 8 байтам нельзя; согласовано с FR-10 («не нашла совпадения»).
- Sniffer — синхронный и блокирующий первое чтение тела; накапливает 32 байта во `internal Buffer` пока не выпускает данные дальше — стартовая задержка 1 RTT клиента. Незначимо.
- Buffer concatenation в `_transform` (`Buffer.concat`) — copy на каждый chunk до 32 байт. На практике первый chunk почти всегда ≥ 32 байт (один TCP-сегмент = 1.4 KB), так что в ≥99% случаев это один-единственный concat. Принимаемое.

## Open questions

- Должен ли sniffer возвращать структурированную ошибку «short body» отдельно от «unknown format» для лучшего UX клиента? Сейчас оба = `invalid_format`. Архитектурное ревью.
- Property-based testing (`fast-check`) на `sniffMagicBytes` — обязательная регрессия в CI: генерируем случайные buffer'ы, проверяем что для каждой validной сигнатуры sniff возвращает корректный формат, для произвольных — `null`. Закладывается в test-инфраструктуру `libs/magic-byte`.
