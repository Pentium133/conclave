# ADR-001: Retry transient HTTP failures with bounded exponential backoff

## Status

proposed

## Context

`FR-1` требует устойчивости к транзиентным сбоям (5xx, 429, network reset). `NFR-LAT-2` ограничивает overhead retry-слоя 50ms на успешном пути. `NFR-AVL-1` требует 99.5% successful-completion-rate. Без явной retry-стратегии любой одиночный 5xx от DeepSeek возвращает ошибку потребителю — это режет availability и нагружает потребителя на повторы.

- Drives: FR-1, FR-3, NFR-LAT-2, NFR-AVL-1.

## Alternatives

### Alternative A: Bounded exponential backoff с фиксированным максимумом попыток

- **Cost**: Дополнительные latency-бюджет на retries в худшем случае ≈ 100 + 200 + 400 + 800 + 1600 ≈ 3.1 сек до отказа.
- **Complexity**: Низкая. Один цикл `for attempt := 0; attempt < maxAttempts; attempt++` с `time.Sleep(2^attempt * baseDelay)`.
- **Correctness**: Покрывает 5xx и transient network errors. Идемпотентен по построению для chat completions (DeepSeek не сохраняет состояние между запросами).
- **Operability**: Чёткий retry budget — оператор видит `retry_count_total` и понимает, насколько часто падаем.
- **Verdict**: chosen — баланс простоты и покрытия.

### Alternative B: Fixed-interval retries (например, 3 попытки с шагом 500ms)

- **Cost**: Меньший worst-case overhead (1.5 сек), но хуже распределяет нагрузку при общей деградации провайдера.
- **Complexity**: Тривиальная.
- **Correctness**: Те же типы ошибок, тот же idempotency assumption.
- **Operability**: Меньше control knobs — нет естественного «успокаивания» при затяжном инциденте.
- **Verdict**: rejected — фиксированный интервал плох под продолжительной деградацией upstream: нагрузка остаётся постоянной, провайдер не успевает восстановиться.

## Decision

Принимаем **Alternative A**. Параметры:

- `maxAttempts = 5` (включая первичную попытку).
- `baseDelay = 100ms`.
- Sleep перед attempt N (N>=1) = `2^(N-1) * baseDelay`, то есть 100ms, 200ms, 400ms, 800ms, 1600ms.
- Retry на: HTTP 5xx, HTTP 429, и сетевые ошибки (`net.OpError`, EOF mid-stream).
- На исчерпании попыток — возвращаем `RateLimited` если последняя ошибка 429, иначе `Retryable`. (`Permanent` — для 4xx кроме 429.)

## Consequences

### Positive

- Покрытие FR-1: повторяем все обозначенные классы транзиентных сбоев.
- Graceful degradation: затяжной 5xx → клиент проседает, но не падает мгновенно; `NFR-AVL-1` достижимо.
- Простота отладки: единственная функция `doWithRetry`, retry-budget виден в метриках.

### Negative

- Tail-latency: при сбое на последней попытке потребитель ждёт ~3 сек прежде чем получит ошибку. Это «съедает» бюджет `NFR-LAT-1` (5 сек p99), оставляя ~1.9 сек на сам upstream — если у DeepSeek плохой день, можем не уложиться.
- Расход токенов: повторяемый запрос = повторно тарифицируется на стороне DeepSeek (если запрос успел дойти до генерации до обрыва). Косвенный $-cost.

## Open questions

- Нужен ли отдельный нижний потолок на сумму sleep'ов (deadline вместо attempts)? Сейчас потолок — counter, не время.
- Нужно ли логировать payload каждой неуспешной попытки или только финальную ошибку? (Дублирование объёма логов.)
