# Spec: deepseek-http-client

## Goal

Нужен HTTP-клиент к DeepSeek API для нашего внутреннего сервиса. Поддержать chat completions (sync и streaming), быть надёжным под нагрузкой, легко интегрироваться в существующий бэкенд.

## Functional requirements

- **FR-1**: Клиент должен отправлять chat-completion запросы к DeepSeek API и возвращать ответ как структурированный объект.
- **FR-2**: Клиент должен поддерживать streaming-режим — поток токенов по мере генерации.
- **FR-3**: Клиент должен ретраить failed requests, чтобы повысить надёжность. Retries должны быть idempotent.
- **FR-4**: Клиент должен инкапсулировать аутентификацию (API-ключ) — потребитель не должен видеть детали.

## Non-functional requirements

### Latency

- **NFR-LAT-1**: Low latency expected. Клиент не должен добавлять заметный overhead к network-round-trip провайдера.

### Throughput

- **NFR-THR-1**: Должен выдерживать рабочую нагрузку нашего сервиса. По нашим прикидкам это «нормальный» уровень.

### Availability / SLA

- **NFR-AVL-1**: 99% доступности при условии, что сам провайдер DeepSeek доступен. (Если он лежит — не наша проблема.)

### Durability

- **NFR-DUR-1**: Stateless клиент, durability не применима.

### Security

- **NFR-SEC-1**: API-ключ хранится в env-переменной. Не логируем ключ. Используем HTTPS.

### Observability

- **NFR-OBS-1**: Standard logging. Логируем запросы и ответы на DEBUG-уровне, ошибки на ERROR.

### Capacity

- **NFR-CAP-1**: Клиент должен сохранять strict ordering of streaming chunks даже при retries — потребитель собирает ответ по порядку и не должен видеть разрывов.

### Dependencies

- **NFR-DEP-1**: DeepSeek HTTP API (OpenAI-совместимый endpoint). HTTP-библиотека на выбор реализатора.

### Deployment

- **NFR-DEP-2**: Поставляется как Go-библиотека, импортируется внутренним сервисом. Деплоится вместе с сервисом.

## Out of scope

- Кеширование ответов на стороне клиента. (Делает потребитель при необходимости.)
- Поддержка не-DeepSeek провайдеров. Только DeepSeek.
- Биллинг и квоты на стороне клиента.

## Open assumptions

- [ASSUMED: base URL = `https://api.deepseek.com/v1` — стандартный публичный endpoint]
- [ASSUMED: модель по умолчанию = `deepseek-chat` — потребитель может переопределить]

## Approval

- Status: approved
- Approved by: developer
- Date: 2026-01-15
- approve - 2026-01-15
