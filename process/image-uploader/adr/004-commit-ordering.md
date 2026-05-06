# ADR-004: Порядок коммита — INSERT-first в `files` (intent), затем PutObject, затем UPDATE-finalize; компенсация при отказе

## Status

proposed

## Context

FR-12 — порядок коммита и семантика `200 OK` (новое требование, добавлено по объекции 1 ревью). Необходимо: (a) обе записи зафиксированы до `200 OK`; (c) при падении второй операции — best-effort компенсация первой; (d) защита от race на client-supplied UUID при конкурентных PUT (объекция 5 ревью). NFR-DUR-1 разрешает orphans пост-фактум, но запрещает «штатный» рассинхрон. ADR-002 предоставляет conditional `Put(IfNoneMatch:*)`, ADR-003 — `INSERT ... ON CONFLICT DO NOTHING` в `files`. Решить: какой порядок и где compensation.

- Drives: FR-12a, FR-12b, FR-12c, FR-12d, FR-12e, NFR-DUR-1, FR-3c

## Alternatives

### Alternative A: PutObject-first → INSERT (S3 ведущий)

- **Cost**: один S3 round-trip + один DB round-trip — ~150 ms median.
- **Complexity**: при race A и B на одном UUID оба сделают PutObject (S3 conditional `If-None-Match: *` спасёт второго: 412). У выигравшего S3 — INSERT, второй — 409. Логика OK.
- **Correctness**: между PutObject (success) и INSERT (failure) есть orphan-окно. Если процесс падает прямо там — orphan в S3 без записи в БД, висит вечно (out-of-scope «Удаление»). Лечится только периодическим reconciliation-сборщиком — отдельная инфраструктура, спекой не предусмотрена.
- **Operability**: orphans в бакете накапливают NFR-CAP-1 шум; отличить orphan от валидного объекта без полного скана БД — нельзя.
- **Verdict**: rejected — наибольший orphan-риск, шумит NFR-CAP-1.

### Alternative B: INSERT-first → PutObject (БД ведущая) — single-phase

- **Cost**: тот же.
- **Complexity**: INSERT прошёл, PutObject упал → запись в БД без тела в S3 → 404 при попытке скачать (объекция 1 ревью буквально). Best-effort компенсация: DELETE из БД. Если DELETE упал — orphan-метаданные.
- **Correctness**: orphan в БД безопасен в одном смысле (ничего лишнего в бакете), опасен в другом — клиент получил 5xx, но при retry с тем же UUID получит 409 от unique constraint, потому что компенсация не сработала. Это ловушка.
- **Operability**: 5xx → 409 на retry — путаница для клиента; reconciliation простая (SELECT files без объекта в S3 — DELETE).
- **Verdict**: rejected как single-phase из-за описанной ловушки 409 при retry.

### Alternative C: Two-phase INSERT (`status='pending'`) → PutObject → UPDATE (`status='committed'`)

- **Cost**: два DB round-trip + один S3 = ~180 ms median; +1 столбец `status` в `files`.
- **Complexity**: больше состояний; нужен фоновой gc-процесс для зачистки `status='pending'` старше N минут.
- **Correctness**: `INSERT ... (id, status='pending') ON CONFLICT DO NOTHING` атомарно резервирует UUID (FR-12d). PutObject под тем же UUID идёт под conditional `If-None-Match: *` (защита, если второй процесс по ошибке тоже зашёл). UPDATE финализирует. Если PutObject упал → DELETE pending-записи; если упал DELETE → запись висит `pending`, но retry клиента с тем же UUID попадёт в DO-NOTHING-ветку, увидит свою же `pending` и сможет повторить PutObject (либо просто получит 409, см. ниже). Если процесс умер между PutObject и UPDATE → orphan в S3 + pending в БД; gc-процесс через TTL чистит обоих.
- **Operability**: gc-процесс — отдельный код-путь, надо мониторить; readiness-probe (NFR-DEP-3d) ничего об этом не знает; для оператора в 3am `status` поле даёт прямой ответ «commit пройдён или нет».
- **Verdict**: chosen — единственная схема, дающая чистую семантику FR-12 + защиту от race + восстанавливаемость при падении процесса.

### Alternative D: Двухфазный коммит (XA / 2PC) между Postgres и S3

- **Cost**: S3 не поддерживает XA. Невозможно.
- **Complexity**: N/A.
- **Correctness**: спека FR-12c явно говорит «двухфазный коммит НЕ требуется».
- **Operability**: N/A.
- **Verdict**: rejected — технически нереализуемо.

## Decision

Принят **two-phase INSERT (`status='pending'`) → PutObject → UPDATE (`status='committed'`)**.

Алгоритм upload-handler (учтён disagree-flag arch-review: INSERT-first означает буквально INSERT перед открытием multipart, не «параллельно»):

```
1. Определить uuid (X-Image-Id или server-generated, FR-7).
2. Определить storage_id (config-driven, ADR-002 + ADR-003).
3. Прочитать первые 32 байта тела через PassThrough peek на req.raw (НЕ запуская
   pipeline в S3 ещё). См. ADR-006 — peek ДО CreateMultipartUpload.
   3a. Если magic-byte sniff fail → return 415 invalid_format. Тело отбрасывается;
       никаких записей в БД и storage не создаётся.
4. INSERT INTO files (id, storage_id, object_key=uuid, content_type=detected, bytes=NULL,
                     status='pending', created_at=now())
   ON CONFLICT (id, created_at) DO NOTHING RETURNING id;
   — если RETURNING пустой → return 409 conflict (FR-12d). На этом этапе никакой
     multipart upload ещё НЕ был открыт, поэтому никаких abort-API-call'ов.
5. Открыть S3 multipart Upload (CreateMultipartUpload) и стримить остаток тела через
   pipeline(req.raw [+ peek-buffered], MinRateTransform, Upload.body). Параметры:
   IfNoneMatch: '*' (FR-12d defense in depth), AbortController привязан к request.
   — если transient 5xx / network error → upload.abort() (best-effort);
     DELETE files WHERE id=$uuid AND status='pending'; return 500 internal_error.
   — если 412 PreconditionFailed на CompleteMultipartUpload (S3 If-None-Match триггер) →
     upload.abort() уже не нужен (Complete не прошёл); DELETE pending; return 409.
   — если timeout (NFR-LAT-2) → upload.abort(); DELETE pending; return 408.
6. UPDATE files SET status='committed', bytes=$bytes_in
   WHERE id=$uuid AND status='pending'.
   — bytes_in приходит из MinRateTransform.totalBytes (ADR-005 счётчик).
   — если 0 rows updated (race с gc — строка уже удалена gc-задачей за TTL) →
     BlobStore.delete($uuid) (best-effort, объект мог не быть нужен клиенту);
     return 500 internal_error (FR-12c).
7. Return 200 {id, url} (FR-8a).
```

Ключевое отличие от первоначальной редакции (до arch-review): шаг 4 (INSERT pending) **завершается** до шага 5 (открытие multipart). На UUID-collision (CONFLICT в шаге 4) сервис возвращает 409 БЕЗ необходимости abort-mid-multipart — нет dangling state в S3, нет лишнего CreateMultipartUpload+AbortMultipartUpload API-call'а. Стоимость: один лишний DB roundtrip ~5 мс перед началом приёма тела; отыгрывается удалением целого error-state'а (compensation на abort-mid-multipart исчезает) и устранением cost-amplification на adversarial UUID-collision.

Семантика `200 OK` (FR-12a): возвращается только после `status='committed'` И `bytes` записан как NOT NULL. Внешним наблюдателям (вне сервиса) `status='pending'` не виден — single-endpoint сервис не имеет публичного read-API; URL для скачивания идёт мимо сервиса (FR-9, NFR-DEP-1c), но **гарантия скачиваемости** даётся только после шага 7.

GC-процесс: фоновая задача в каждом pod через `@nestjs/schedule` (cron `*/5 * * * *`) — раз в 5 минут выполняет `SELECT id, storage_id, object_key FROM files WHERE status='pending' AND created_at < now() - interval '15 minutes' FOR UPDATE SKIP LOCKED LIMIT 100` (15 минут = NFR-LAT-2c wall-clock max + запас). Использует partial index `files_pending_idx (created_at) WHERE status='pending'` (см. ADR-003) — index-only scan без full-table-scan. `LIMIT 100` ограничивает batch и не даёт долгой транзакции. Для каждой записи: `BlobStore.delete()` (best-effort, с тайм-аутом 5 секунд через AbortSignal) → `DELETE FROM files WHERE id=$ AND status='pending'`. Если несколько pod'ов — `SKIP LOCKED` гарантирует, что каждую запись забирает ровно одна реплика. На SIGTERM (см. ADR-009) gc-задача останавливается **первой** в OnApplicationShutdown-graph (до закрытия DB pool и S3 client'а), и при этом текущий in-flight batch имеет до 30 секунд на завершение через AbortController; если не успел — open transaction откатывается БД autonomy на close, partial state на S3 (DELETE прошёл, но DELETE FROM files не успел) обработается на следующем gc-цикле другого pod'а или после рестарта.

## Consequences

### Positive

- FR-12a выполнен буквально: `200 OK` ⇒ обе записи зафиксированы (`status='committed'` + объект в S3).
- FR-12d закрыт **двойной** защитой: unique constraint в БД (ADR-003) + `If-None-Match: *` на S3 (ADR-002). Race на одном UUID ловится тем, что приходит первым.
- При смерти процесса между PutObject и UPDATE — orphan ограничен по времени (gc через 15 минут).
- Объекция 1 ревью закрыта: семантика 200 OK однозначна, порядок операций задан, поведение при отказе второй операции — компенсация описана.
- Объекция 5 ревью закрыта: сценарий «A залил PNG, B залил JPEG поверх с тем же UUID» невозможен — B либо проиграет на INSERT (409), либо на S3 If-None-Match (412); в обоих случаях B видит 409, не overwrite.

### Negative

- Дополнительный столбец `status` и +1 UPDATE удлиняет p50 на ~10 ms — съедает часть бюджета NFR-LAT-1a (p95 < 2c), но запас остаётся большой.
- GC-процесс — новый код-путь, требует тестов на race с активным upload (gc не должен убить «свежий» pending до истечения 15 минут — отсюда временной порог).
- При полном отказе компенсации (DB unreachable после S3 success) орфан остаётся, NFR-DUR-1 это допускает; gc восстановится, когда DB поднимется, но S3-объект может быть не удалён, если DELETE из storage потом тоже упадёт. Эти orphans — операционный долг (storage cost), мониторить через operational SQL.
- Поле `status` мало кому полезно после commit (всегда `committed`); потенциально можно отказаться от него и хранить только `pending`-записи в отдельной таблице — отложено.

## Open questions

- Альтернатива: вместо `status` колонки иметь отдельную таблицу `pending_files` и MOVE на commit. Чище, но удваивает write-amplification. Архитектурное ревью.
- Должен ли gc-интервал (5 минут) и TTL (15 минут) быть конфигурируемыми? Скорее да, default'ы зафиксированы.
- Как поступать, если в момент UPDATE `status='committed'` процесс умер ровно после S3 complete? gc найдёт `status='pending'` + объект в S3 (HEAD вернёт 200), удалит и то и другое — это потеря успешного upload'а с точки зрения клиента, который мог не получить response. Принимаем под NFR-DUR-1 (best-effort durability), но фиксируем как остаточный риск для архитектурного ревью.

## Response to arch-review

Disagree-flag arch-review (порядок шагов 3–4: open multipart до INSERT) — **принят**. Алгоритм Decision-блока переписан: INSERT pending теперь **обязательно завершается до** открытия S3 multipart upload (бывший шаг 3 разделён на peek-only-3 и pipeline-launch-5). Это устраняет abort-mid-multipart code-path и cost-amplification на adversarial 415/409. Cost — один дополнительный DB roundtrip (~5 мс) перед началом приёма тела; в бюджете NFR-LAT-1a (p95 < 2с) это шум. Семантика OnApplicationShutdown ordering для gc-задачи зафиксирована в обновлённом GC-процесс параграфе: gc останавливается **первым** до закрытия DB pool и S3 client.

