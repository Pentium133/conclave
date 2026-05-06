# ADR-012: Capacity-модель — 4 pod'а × 50 in-flight × 2 GB RAM, HPA до 16

## Status

proposed

## Context

NFR-THR-1 — целевая пропускная способность (50 RPS среднее, 200 RPS пик); NFR-CAP-1 — горизонт 24 месяца, до 400 RPS пика и 50 TB на хранилище. Arch-review #10 поднял: ни один из ADR'ов 001–011 не даёт явной модели «pods × concurrent_uploads × avg_duration = peak RPS» — HPA-конфигурация остаётся guesswork. Без модели операторы не могут (а) решить starting replica count, (б) сконфигурировать k8s memory-limit, (в) определить HPA scale-up trigger, (г) обосновать NFR-AVL-1 при rolling-update под пиком.

Дополнительный context от разработчика (/review-arch follow-up): средний размер upload'а ≈ **50 KB** (тип «web-optimized image / icon»), memory-limit per pod = 2 GB, стартовый replica count = 4. Это вводные данные для модели.

- Drives: NFR-THR-1, NFR-CAP-1, NFR-LAT-1, NFR-AVL-1, NFR-DEP-2 (rolling update), arch-review #10
- Inputs from developer: avg_file_size = 50 KB, pod memory limit = 2 GB, starting replicas = 4

## Capacity model

### Per-request memory

| Источник | Объём |
|---|---|
| AWS SDK v3 multipart Upload working set (`partSize 8 MiB × queueSize 4`, ADR-006) | до 32 MiB |
| `MinRateTransform` ring-buffer + state (ADR-005) | < 1 KiB |
| `MagicBytePeekTransform` peek-buffer (ADR-007) | 32 байта |
| Fastify request/response objects + headers | ~5–10 KiB |
| AsyncLocalStorage context + Pino logger context (ADR-008) | ~1 KiB |
| AWS SDK retry-buffer (`maxAttempts: 2`, ADR-006) | до 1× partSize в worst-case = 8 MiB |
| **Итого worst-case per-request** | **~40 MiB** (32 active + 8 retry) |
| **Реалистично без retry** | **~32 MiB** |

При среднем размере **50 KB** реальный peak per-request — гораздо меньше: первый part 5 MiB не наполняется, multipart-overhead в основном administrative (CreateMultipartUpload + один UploadPart + CompleteMultipartUpload). Working set приближается к ~1 MiB в норме. Worst-case 40 MiB — для 100 MB файлов (FR-6 верхняя граница), которые редки.

### Per-pod budget

```
Pod memory limit:        2048 MiB                  (input)
Node baseline:           ~150 MiB                  (V8 heap base + Buffer pool)
NestJS DI graph:         ~80 MiB                   (modules, providers loaded)
TypeORM connection pool: ~50 MiB                   (10 connections × ~5 MiB each)
AWS SDK keep-alive:      ~50 MiB                   (HTTP/1.1 agent + TLS contexts)
Pino async-buffer:       ~5 MiB                    (но sync: true в проде, см. ADR-008)
─────────────────────────────────────────
Baseline static:         ~335 MiB

Available for in-flight: 2048 - 335 - 200 (safety margin) = ~1500 MiB
                                            ↑ headroom для GC, fragmentation, log spike

Per-request worst-case:  40 MiB (с retry)
Max in-flight per pod:   1500 / 40 = 37 одновременных запросов worst-case
```

**Решение**: per-pod max-concurrent-uploads семафор (ADR-005) = **50** при average-load (50 KB файлы) и автоматически снижается до **30** через ENV `MAX_CONCURRENT_UPLOADS=30`, если оператор замечает memory-pressure при пиках 100 MB файлов. Default 50 покрывает 99% legitimate нагрузки на 50 KB файлах, оставляя headroom для GC.

### Throughput model

```
peak_rps_per_pod = max_in_flight / p99_duration

Где p99_duration:
- Для файлов ≤ 10 MB (NFR-LAT-1a, p99 < 5s):  5 секунд
- Для среднего файла 50 KB:                    ~200 ms (network + 1 part-roundtrip)

NFR-LAT-1a-edge case (5s):
  peak_rps_per_pod = 50 / 5 = 10 RPS

Average (200ms):
  peak_rps_per_pod = 50 / 0.2 = 250 RPS

NFR-THR-1b пик (200 RPS) на 4 pod'а:
  per-pod = 50 RPS — хорошо вмещается в (10 .. 250) диапазон
  при 4 pod'ах: 200 RPS пик распределённо, p99 5s даёт edge-case 40 RPS = ниже NFR
```

### NFR-CAP-1 (400 RPS на горизонте)

При сохранении той же model и 4 pod'ах:
- p99=200ms (avg-нагрузка): 4 × 250 RPS = 1000 RPS (с запасом для 400 RPS пика).
- p99=5s (NFR-LAT-1a): 4 × 10 RPS = 40 RPS (НЕ покрывает 400 RPS пика на edge-сценарии).

Для покрытия NFR-CAP-1 с edge-cases: **HPA до 16 pod'ов** при saturation:
- 16 × 50 / 5 = 160 RPS (worst-case p99=5s) — недостаточно для 400 RPS на edge'е, но FR-LAT-1b (10–100 MB best-effort) допускает деградацию.
- 16 × 250 = 4000 RPS (avg-load) — c огромным запасом.

### NFR-CAP-1 storage budget

```
50 RPS avg × 50 KB/file × 86400 sec/day × 365 days × 2 years
= 50 × 50000 × 86400 × 730
= 158 TB total bytes

Бюджет NFR-CAP-1: 50 TB.

Превышение в ~3.2x. Принимаемые митигации (вне scope этого ADR):
1. Реальный avg может оказаться меньше 50 KB (web-thumbnails ~10–20 KB).
2. Реальная средняя RPS обычно ниже rated peak — 10–20 RPS на работающем сервисе.
3. Бюджет 50 TB — это «target», не «hard limit»; storage scale-up через провайдера.
4. NFR-CAP-1 приближение к лимиту триггерит partitioning lifecycle (ADR-003 monthly
   RANGE) — старые партиции могут быть archived в S3 IA / Glacier (out-of-scope spec).

Действие в этом ADR: фиксируем модель и принимаем риск. Если фактический avg окажется
больше 50 KB или RPS существенно ниже estimate, NFR-CAP-1 потребует пересмотра как
spec-change (annual cost-cap, не storage-target — рекомендация spec-skeptic объекции 6,
формально отклонённая, но математически неизбежная).
```

## Decision

Принята следующая capacity-модель:

| Параметр | Значение | Источник |
|---|---|---|
| Pod memory limit | 2048 MiB | input from developer |
| Pod CPU request / limit | 500m / 1000m | оценка для Node event-loop при 50 in-flight |
| Starting replicas | 4 | input from developer |
| HPA min replicas | 4 | == starting |
| HPA max replicas | 16 | покрывает NFR-CAP-1 400 RPS на avg-load |
| HPA scale trigger | `MAX_CONCURRENT_UPLOADS` saturation rate | через custom metric (см. Negative) |
| Per-pod max in-flight | 50 | ADR-005 семафор |
| Anticipated avg upload size | 50 KB | input from developer |

K8s manifest snippet:

```yaml
spec:
  replicas: 4
  template:
    spec:
      containers:
      - name: image-uploader
        resources:
          requests: { memory: 1024Mi, cpu: 500m }
          limits:   { memory: 2048Mi, cpu: 1000m }
        env:
        - name: MAX_CONCURRENT_UPLOADS
          value: "50"
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: image-uploader
spec:
  minReplicas: 4
  maxReplicas: 16
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: { type: Utilization, averageUtilization: 70 }
  # Custom metric `concurrent_uploads_saturation_ratio` через
  # Prometheus-adapter — приближенно из логов NFR-OBS-1.
  # См. Negative: HPA на JSON-логах — нештатно.
```

## Consequences

### Positive

- Capacity-модель явно зафиксирована. Operations знает: при пиковой нагрузке 200 RPS — 4 pod'а × 50 in-flight × 2 GB; при росте до 400 RPS — HPA до 16 pod'ов.
- 50 in-flight верхний предел гарантирует, что pod'у достаточно памяти даже при worst-case 100 MB файлах (40 MiB per request × 50 = 2000 MiB ≈ pod limit, с учётом baseline остаётся ~150 MiB headroom — достаточно для GC и safety margin).
- Все цифры выводимы из других ADR (memory из ADR-006 multipart, concurrency из ADR-005 semaphore, p99 из NFR-LAT-1).
- Помогает спланировать k8s nodepool: 4 pod'а × 2 GB = 8 GB minimum cluster footprint, HPA → 32 GB peak — для small managed-cluster тривиально.

### Negative

- **HPA scale на NFR-OBS-1 JSON-логах — нештатно**: NFR-OBS-1 запрещает Prometheus-метрики с сервиса; HPA Resource-metrics (CPU) — proxy, не точный. CPU usage не растёт линейно с in-flight (event-loop в основном I/O-bound), поэтому при saturation per-pod-семафора (50) CPU может быть 30–40%, а scale-up не сработает. Workaround: external Prometheus-adapter парсит JSON-логи (`error_class='too_many_in_flight'` rate) и публикует custom metric — полу-ручная инфраструктура.
- **NFR-CAP-1 storage budget не сходится** на 50 KB × 50 RPS × 24 мес = ~158 TB > 50 TB. Принимаем как spec-level-risk; формально это spec-change или operational-cap-budget, не arch-decision. Эскалация в spec-skeptic objection 6 (отклонена) остаётся в силе как known issue.
- **Replicas count = 4 жёстко связан с rolling-update timing**: ADR-009 `terminationGracePeriodSeconds: 930` × 4 pod'а = до 1 часа (см. ADR-009 Negative). При HPA до 16 pod'ов rolling-update вырастает до 4 часов — это операционная цена за NFR-DEP-3b drain-окна. Эскалация в arch-review #3 escape-hatch (отклонена), известное ограничение.
- **CPU 500m request** — оценка; событие в event-loop'е может варьироваться. Профилирование первой production-нагрузкой может потребовать пересмотра (вверх или вниз). Принимаем как initial estimate.
- **Headroom 200 MiB margin** на pod'е — узкий; при OOM-spike на 100 MB файле + неудачном GC pod может упасть в OOM kill. Операционная mitigation: alert на pod RSS > 1800 MiB через k8s metrics.
- **Capacity-model не учитывает long-running connections** для legitimately медленных клиентов (1 Mbps × 100 MB = 800 секунд в одном слоте семафора). При 50 таких соединений ниже avg-throughput оценки, но в семафорный лимит укладываются. На-call должен знать.

## Open questions

- Стоит ли вынести `MAX_CONCURRENT_UPLOADS` в `ConfigMap` per-environment (prod=50, staging=20)? Скорее да; default через ENV — стартовый паттерн.
- HPA scale-up на `concurrent_uploads_saturation_ratio` — построить через Prometheus-adapter из JSON-логов или принять CPU-only (грубый proxy)? Решение архитектурного ревью.
- Ratio HPA min/max замочен на 4/16 (factor 4); типичный k8s-паттерн 1/N. Для security-hotfix scenario (когда хочется быстро rollout без drain) min=1 уменьшил бы rolling-update время. Но min=4 защищает NFR-AVL-1 при normal load. Trade-off.
- Реальный avg upload size — поверка после первой production-недели. Если окажется существенно больше (например, 5 MB вместо 50 KB), NFR-CAP-1 необходимо пересмотреть как cost-cap; capacity-model в этом ADR требует ревизии (max in-flight уменьшится из-за memory-pressure на больших файлах).
