# ADR-010: Публичный URL — каноническая функция от `storages.public_base + uuid`, без проксирования через сервис

## Status

proposed

## Context

FR-9 — URL для скачивания: (a) без TTL; (b) без авторизации; (c) единственный барьер — непредсказуемость UUID; (d) детерминированная функция от UUID и базового домена бакета/CDN — клиент может построить URL сам. NFR-DEP-1c — CDN явно не требуется, можно отдавать напрямую из бакета. ADR-002 `BlobStore.URL(key)` использует параметры storage-сущности (FR-3a). FR-3c — file+storage ⇒ URL без иных источников. Объекция 11 ревью отклонена разработчиком (миграция между storage ломает «вечный URL»), но архитектурное решение должно минимизировать поверхность поломки и явно зафиксировать правила.

- Drives: FR-9a, FR-9b, FR-9c, FR-9d, FR-3a, FR-3c, NFR-DEP-1c, NFR-DEP-1a

## Alternatives

### Alternative A: URL = `<storages.public_base>/<files.id>` — клиент скачивает напрямую из бакета/CDN, минуя сервис

- **Cost**: 0 трафика через сервис на скачивании; cost скачивания = bandwidth провайдера S3 / CDN.
- **Complexity**: тривиальная конкатенация. Storage-сущность в БД хранит `public_base` (например, `https://prod-images.example.com` для CDN-варианта или `https://s3.eu-central-1.amazonaws.com/my-bucket` для прямого бакета).
- **Correctness**: FR-9d — детерминирован: клиент с известным UUID и `public_base` строит URL сам. FR-9a — пока бакет/CDN живут под этим хостом, URL валиден. Переключение S3-эндпоинта (миграция MinIO → AWS) НЕ ломает URL, если оператор поднимает CDN или DNS-CNAME перед бакетом и `public_base` указывает на него (отделение `public_base` от physical endpoint).
- **Operability**: load-снятие с сервиса полное; bandwidth/cost провайдера за исходящий трафик — отдельный счёт.
- **Verdict**: chosen — выполняет FR-9 a-d буквально, минимизирует нагрузку на сервис.

### Alternative B: URL = `https://<service>/v1/files/<uuid>` — сервис проксирует скачивание

- **Cost**: весь download-трафик идёт через сервис; для горизонта 50 TB / 24 мес и неограниченных скачиваний это терабайты/мес исходящего трафика через под; дополнительный compute и bandwidth.
- **Complexity**: новый GET-эндпоинт; но «LIST / поиск / перечисление файлов» out-of-scope, и спека прямо говорит «Скачивание файла идёт мимо сервиса». Этот alternative противоречит явному out-of-scope.
- **Correctness**: можно было бы добавить headers nosniff/Content-Disposition (объекция 3 ревью отклонена, но защита возможна). Но это не требование спеки.
- **Operability**: добавляет SLO на download-эндпоинт, не специфицированный в spec; pod CPU/память расходуется на проксирование.
- **Verdict**: rejected — противоречит explicit out-of-scope «Скачивание файла идёт мимо сервиса».

### Alternative C: Pre-signed URL с длинным TTL (например, 100 лет)

- **Cost**: 0 cost разницы.
- **Complexity**: Pre-signed URL подписывается секретом и содержит подпись + expires. Это нарушает FR-9d «детерминированная функция от UUID и базового домена» — клиент не может построить URL сам, ему нужна подпись.
- **Correctness**: формально FR-9a «не имеет TTL» нарушается (TTL есть, просто длинный); FR-9d прямо ломается.
- **Operability**: ротация ключей подписи в провайдере = инвалидация всех ранее выданных URL = массовый алерт.
- **Verdict**: rejected — нарушает FR-9a и FR-9d.

## Decision

Принят **`URL = <storages.public_base>/<files.id>`**, прямой публичный доступ к бакету/CDN, без проксирования.

`storages.public_base` (см. ADR-003) — TEXT-поле, конфигурируется при создании storage-сущности оператором; должно быть **CDN-доменом ИЛИ публичным DNS-CNAME перед бакетом**, не raw-endpoint конкретного S3-провайдера. Это якорь FR-9a — миграция между провайдерами становится re-mapping DNS/CDN-origin, а не изменением `public_base` в БД (что бы инвалидировало все ранее выданные URL).

Для `LocalFS` (dev) `public_base` указывает на локальный download-эндпоинт self-hosted, например `http://localhost:8080/dev-files`; в dev-режиме сервис экспонирует один read-эндпоинт (только для local backend) — это **dev-only исключение**, не часть production-контракта (FR-4 запрещает LocalFS в prod).

`BlobStore.url(key)` для S3 и LocalFS (одинаково):
```ts
url(key: string): string {
  return `${this.storage.public_base}/${key}`;
}
```

Бакет (S3) должен быть сконфигурирован с public-read ACL ИЛИ за CDN с public-read origin policy. Это операционное предусловие — фиксируется в README операционной части и в `BlobStore.HealthCheck` (ADR-009): для S3 health-check может опционально проверять `GetBucketPolicyStatus.IsPublic == true` (вне MVP).

S3-объекты сохраняются (ADR-002 `Put`) с `Content-Type` из ADR-007 magic-byte sniffer'а; `Content-Disposition`, `X-Content-Type-Options` — НЕ выставляются (объекция 3 ревью отклонена).

## Consequences

### Positive

- 0 download-трафика через сервис → SLO задержки/доступности upload'а не зависят от download-нагрузки.
- FR-9d буквально: клиент, зная UUID и `public_base`, конструирует URL сам — не нужно вызывать API сервиса для resolve URL.
- Миграция S3-бэкенда между провайдерами через DNS/CDN-origin re-point не ломает `public_base` → ранее выданные URL остаются валидны (смягчение риска объекции 11).
- NFR-DEP-1c (CDN опционален) — `public_base` может быть raw-bucket-URL или CDN — конфигурация одной строкой в storage-сущности.

### Negative

- Публичный read бакета — operational risk: misconfiguration ACL может exposed дополнительные данные, лежащие в том же бакете; mitigation — выделенный bucket только под image-uploader, без других объектов.
- `Content-Type: image/*` выставляется на S3-метаданном (ADR-002, ADR-007), но `X-Content-Type-Options: nosniff` НЕТ — теоретический stored-XSS через полиглот сохраняется (объекция 3 ревью отклонена; принимаемый риск).
- Если оператор сменит `storages.public_base` в БД (например, переключит CDN-провайдера с другим доменом) — все ранее выданные URL станут невалидными для клиентов, не получивших обновление. ADR-002 + ADR-003 явно показывают, что `public_base` — единственная точка контроля; разработчик должен документировать «не менять public_base после первого использования» в operational README. Это операционное предусловие, не technical guarantee.
- Bandwidth-cost провайдера за исходящий download-трафик растёт линейно с количеством скачиваний, и сервис на это не имеет контроля (download out-of-scope). Принимаемое.
- В dev-режиме появляется опциональный read-эндпоинт для LocalFS — это асимметрия с prod (где такого эндпоинта нет). Должно быть явно guarded конфигом `ENV=dev`, иначе риск утечки в prod.

## Open questions

- Должен ли `BlobStore` для S3 проверять `IsPublic` бакета на старте сервиса (fail-fast) или ограничиться runtime-проверкой через `HealthCheck`? Архитектурное ревью.
- Сценарий миграции `public_base` (объекция 11) явно отклонён — но если когда-нибудь потребуется, единственный путь будет: (a) обновить запись `storages` с новым `public_base`, (b) принять, что `BlobStore.URL` теперь возвращает новые URL, (c) на CDN/DNS поднять reverse-proxy со старого хоста на новый для compatibility. Это дополнительная инфраструктура, не код. Зафиксировать в operational README — задача архитектурного ревью.

