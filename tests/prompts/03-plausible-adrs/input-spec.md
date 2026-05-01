# Spec: deepseek-retry-streaming

## Goal

Узкий слой retry + streaming поверх HTTP-клиента к DeepSeek API: устойчивость к транзиентным сбоям (5xx / 429 / network) и поддержка потокового вывода токенов через SSE.

## Functional requirements

- **FR-1**: Клиент должен повторять запрос на транзиентных сбоях (5xx, 429, network reset) до достижения предела попыток.
- **FR-2**: Клиент должен поддерживать SSE-стриминг chat completions: проксировать токены потребителю по мере получения от провайдера.
- **FR-3**: Клиент должен возвращать классифицированную ошибку (`Retryable | Permanent | RateLimited`) когда retries исчерпаны.

## Non-functional requirements

### Latency

- **NFR-LAT-1**: p99 cold-start latency (успешный non-streaming запрос) — < 5 секунд при здоровом провайдере.
- **NFR-LAT-2**: Дополнительный overhead от retry-слоя — < 50ms на успешном пути.

### Throughput

- **NFR-THR-1**: Сервис-потребитель: пик 100 RPS, типичная нагрузка 30 RPS.

### Availability / SLA

- **NFR-AVL-1**: 99.5% successful-completion-rate в окне 1 минута, при условии что DeepSeek доступен.

### Security

- **NFR-SEC-1**: API-ключ — из env-переменной, никогда не логируется.

### Observability

- **NFR-OBS-1**: Метрики: `request_count{status}`, `request_duration_seconds` (histogram), `retry_count_total`. Trace-spans на каждый attempt.

### Capacity

- **NFR-CAP-1**: Нагрузка ограничена сверху rate-limit-ом DeepSeek (детали определяются вендором).

### Dependencies

- **NFR-DEP-1**: DeepSeek HTTP API. HTTP-клиент — `net/http` стандартной библиотеки Go.

### Deployment

- **NFR-DEP-2**: Поставляется как Go-библиотека внутреннему сервису.

## Out of scope

- Кеширование ответов.
- Поддержка не-DeepSeek провайдеров.
- Биллинг / квоты.

## Approval

- Status: approved
- Approved by: developer
- Date: 2026-01-15
