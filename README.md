# Пайплайн агентов Claude Code для проектирования бэкенд-задач

Этот репозиторий — **конфигурация Claude Code**, превращающая `claude` в управляемый процесс проектирования: интервью → спека → адверсариальное ревью → ADR → ревью архитектуры → пост-ревью кода. Сам бэкенд не пишется; артефакт, который оценивается, это `.claude/`-конфигурация и сопровождающие документы (`CLAUDE.md`, шаблоны, рефлексия).

Если вы только что клонировали репозиторий и хотите запустить пайплайн — читайте `CLAUDE.md`. Этот README отвечает на вопрос «как устроен процесс и почему именно так».

---

## 1. Обзор процесса

Пять стадий, пять ролей, пять артефактов. Между стадиями — явные переходы по `STATE.md` и (на двух стыках) ручные действия разработчика.

| # | Стадия | Роль | Артефакт | Кто читает |
|---|---|---|---|---|
| 1 | Опрос требований | `interviewer` | `spec.md` (FR/NFR + open assumptions) | разработчик апрувит, дальше — `spec-skeptic` и `architect` |
| 2 | Адверсариальное ревью спеки | `spec-skeptic` | `spec-review.md` (≥7 objections, two-pass) | разработчик применяет вердикты, далее `architect` (но НЕ `arch-reviewer`) |
| 3 | Архитектурное решение | `architect` | `process/<slug>/adr/NNN-*.md` | `arch-reviewer`, потом `code-auditor` |
| 4 | Архитектурное ревью | `arch-reviewer` | `arch-review.md` (per-ADR + cross-cutting) | разработчик решает go/iterate/kill |
| 5 | Пост-ревью кода | `code-auditor` | `post-review.md` (file:line evidence) | разработчик чинит/мёржит |

Канонические промпты — в `.claude/agents/<name>.md`. Канонические шаблоны артефактов — в `docs/templates/`.

---

## 2. Роли в деталях

Системные промпты живут в `.claude/agents/` — здесь только конспект. Когда меняется поведение, правится файл агента, не этот README.

### 2.1 `interviewer` (`.claude/agents/interviewer.md`)

- **Цель:** вытащить FR-N и NFR-KIND-N в `spec.md`. Не дать разработчику уйти в реализацию.
- **Обязано:** один вопрос за ход; multiple choice по умолчанию; систематически обойти все 9 NFR-категорий (latency / throughput / availability / durability / security / observability / capacity / dependencies / deployment); при уклончивом ответе переспросить с тремя конкретными опциями; правило 3 попыток → пишем `[ASSUMED: ...]`; surface противоречий с цитированием обеих строк.
- **Запрещено:** предлагать технологии, фреймворки, ретрай-политики; задавать несколько вопросов за один ход; принимать «потом разберёмся» вместо `[ASSUMED]`; закрывать интервью пока есть пустые NFR-секции.
- **Артефакт:** `process/<slug>/spec.md` + транзит `STATE.md` к `stage: spec-approved` после ручного `approve` от разработчика.

### 2.2 `spec-skeptic` (`.claude/agents/spec-skeptic.md`)

- **Цель:** найти 3am production failures, которые автор спеки не увидел. Изоляция — читает только `spec.md`, не видит интервью-диалог.
- **Обязано:** Pass 1 — ≥7 пронумерованных objections, каждое с `severity / area / scenario / what to fix / refs`; Pass 2 — самооценка `deep / medium / shallow` с одним предложением обоснования; verdict выдавать только если ≥5 objections выжили как `deep` или `medium`. Иначе пишет «Insufficient depth — Pass 1 must be redone».
- **Запрещено:** «Looks good overall», generic «consider X», agreeing with author, скип Pass 2, редактирование `spec.md`.
- **Артефакт:** `process/<slug>/spec-review.md`. Транзит `STATE.md → stage: spec-reviewed`.

### 2.3 `architect` (`.claude/agents/architect.md`)

- **Цель:** превратить спеку и применённые вердикты в набор ADR с явными trade-off’ами.
- **Обязано:** один ADR на одно решение (один файл `process/<slug>/adr/NNN-<topic>.md`); ≥2 альтернативы с оценкой по 4 осям (`cost / complexity / correctness / operability`); `## Decision` цитирует FR-N / NFR-KIND-N из спеки; `## Consequences ### Negative` непустой; `block` и `major` objections из `spec-review.md` явно адресуются (в `## Context` или `## Consequences`).
- **Запрещено:** ADR с одной альтернативой; «индустриальный стандарт» как обоснование; пустой `### Negative`; вымышленные FR/NFR-IDs; редактирование `spec.md` или `spec-review.md`.
- **Артефакт:** `process/<slug>/adr/NNN-*.md`. Транзит `STATE.md → stage: arch-proposed`.

### 2.4 `arch-reviewer` (`.claude/agents/arch-reviewer.md`)

- **Цель:** независимое ревью архитектуры. Самое важное правило — **не читать `spec-review.md`**. Реверс-инжиниринг не нужен; нужна вторая, не выровненная позиция.
- **Обязано:** per-ADR секция с `verdict (accept/challenge/reject)` + ≥3 техническими аргументами + ≥2 3am-сценариями + операционными проблемами + **disagree-flag**. Disagree-flag обязателен в каждой per-ADR секции в одной из двух форм: «I disagree with: ...» либо «I considered the following objections [≥2] and rejected them because [...]». Cross-cutting секция: observability, failure isolation, deployment. Финальный вердикт: `block / iterate / approve`.
- **Запрещено:** читать `spec-review.md` (этот запрет — load-bearing prompt-rule, см. §6.3); approve без непустого disagree-flag; generic «consider monitoring»; редактирование ADR.
- **Артефакт:** `process/<slug>/arch-review.md`. Транзит `STATE.md → stage: arch-reviewed`.

### 2.5 `code-auditor` (`.claude/agents/code-auditor.md`)

- **Цель:** проверить реализацию против спеки и ADR с file:line-цитированием каждого утверждения. Read-only.
- **Обязано:** заполнить три таблицы целиком — все FR-N, все NFR-KIND-N, все ADR-IDs (статусы: `met / not met / not testable`, `implemented / deviated / not implemented`); каждая строка имеет `file.ext:LN` evidence; findings с severity и suggested fix; vердикт `ship / fix-required / reject`.
- **Запрещено:** verdict без полностью заполненных таблиц; findings без file:line; модификация кода; trust-by-spec без grep’а.
- **Артефакт:** `process/<slug>/post-review.md`. Транзит `STATE.md → stage: audit-done`.

---

## 3. Поток артефактов

| Артефакт | Кто пишет | Кто читает | Кто НЕ читает |
|---|---|---|---|
| `spec.md` | `interviewer` (+ ручные правки разработчика) | `spec-skeptic`, `architect`, `arch-reviewer`, `code-auditor` | — |
| `spec-review.md` | `spec-skeptic` | `architect` (учитывает block/major objections), разработчик (применяет вердикты) | **`arch-reviewer` — hard rule** |
| `adr/NNN-*.md` | `architect` | `arch-reviewer`, `code-auditor` | — |
| `arch-review.md` | `arch-reviewer` | разработчик (решает go/iterate/kill), `code-auditor` опционально | — |
| `post-review.md` | `code-auditor` | разработчик | — |
| `STATE.md` | каждый сабагент обновляет на своей стадии | `/status`, хук `state-guard.sh`, slash-команды для предусловий | — |

Изоляция `arch-reviewer` от `spec-review.md` явно прописана в трёх местах: системный промпт агента, тело команды `/review-arch`, рубрика `.claude/skills/review-rubric/SKILL.md`. См. §6.3 — это load-bearing.

---

## 4. Точки HITL

Пайплайн не молотит впустую — есть пять явных точек, где требуется действие разработчика. Все остальные переходы автоматизированы сабагентами.

| # | Когда | Что делает разработчик | Зачем |
|---|---|---|---|
| 1 | Во время `/interview` | Отвечает на вопросы интервьюера | Иначе нет требований |
| 2 | После `spec.md` | Пишет `approve <date>` в `§Approval` | Подтверждает, что спека отражает реальные требования. Без апрува сабагент не двинет stage в `spec-approved`. |
| 3 | После `spec-review.md` | Применяет вердикты к `spec.md` и **вручную** ставит `stage: verdicts-applied` (либо лог-строку `no-action-needed`) | Это интерпретирующее решение — какие objections валидны для этой задачи; модель не должна решать за разработчика. |
| 4 | После каждого ADR / всего набора | Если architect оставил альтернативы открытыми — разработчик выбирает | ADR может корректно описать развилку, но не закрыть её, если требуется бизнес-вход. |
| 5 | После `arch-review.md` | Решает go / iterate / kill | Это не вопрос промпта — это вопрос «инвестируем ли мы N человеко-недель в этот дизайн». |

Дополнительно: после `post-review.md` разработчик решает merge / fix / reject — но это уже не часть пайплайна проектирования, это его выходная точка.

---

## 5. Критерии завершения этапов

| Стадия | Что значит «готово» |
|---|---|
| `intake` | `process/<slug>/STATE.md` создан, `process/CURRENT = <slug>`, `Pending human action` указывает на `/interview`. |
| `interview` | Все 9 NFR-секций спеки содержат либо конкретный `NFR-KIND-N`, либо `[ASSUMED: ...]`-строку. Все `[ASSUMED]` сводятся в `## Open assumptions`. |
| `spec-approved` | Разработчик дописал в `§Approval` дословно `approve` + дата. Интервьюер обновил `STATE.md`. |
| `spec-reviewed` | `spec-review.md` содержит ≥7 objections; ≥5 переживают Pass 2 как `deep`/`medium`; verdict записан. Если этот гейт не пройден — verdict не пишется и стадия не закрывается. |
| `verdicts-applied` | Ручной HITL: разработчик прошёлся по объектам, обновил `spec.md`, вручную выставил stage. Лог-строка фиксирует accepted / rejected / deferred. |
| `arch-proposed` | По одному ADR на каждое архитектурное решение из спеки, у каждого ≥2 альтернативы с 4-осевой оценкой и непустым `### Negative`. Все `block` и `major` objections адресованы. |
| `arch-reviewed` | `arch-review.md` имеет per-ADR секцию для каждого ADR (verdict + ≥3 аргумента + ≥2 3am-сценария + disagree-flag), cross-cutting секцию и финальный verdict. |
| `audit-done` | Все FR/NFR/ADR классифицированы со статусом и file:line evidence. Findings с severity. Verdict `ship`/`fix-required`/`reject`. |

Эти правила одновременно вшиты в системные промпты сабагентов (как обязательные поведения), в шаблоны (`docs/templates/*.template.md` — структурный каркас) и в рубрику ревью (`.claude/skills/review-rubric/SKILL.md`).

---

## 6. Открытые дизайн-решения

Это требование тестового задания (`test-task.md` строки 47–52). Ниже — позиция по каждому из пяти пунктов.

### 6.1 Subagents vs slash commands vs skills vs hooks

Не «всё subagents». Маппинг следующий:

- **Subagents — для ролей.** Каждый из 5 этапов это отдельная роль с собственным системным промптом, изолированным контекстом и собственным набором запретов. Это естественно ложится на сабагентов: контекст-изоляция бесплатна, переключение ролей чёткое, system prompt задаёт характер.
- **Slash commands — для переходов.** `/start`, `/interview`, `/challenge-spec`, `/architect`, `/review-arch`, `/audit-code`, `/status` — это «глаголы» пайплайна. Они валидируют stage, готовят файлы (копируют шаблоны, создают директории), вызывают нужный сабагент через Task. Это тонкие wrapper-команды без бизнес-логики ролей. Команда — детерминированный шаг, она не должна «думать».
- **Skills — для переиспользуемых конвенций.** `spec-template`, `adr-template`, `review-rubric` лежат в `.claude/skills/`. Они описывают **дисциплину** артефакта: какие секции обязательны, какие IDs, какие antiprompts (например, «Looks good overall» — banned). Skill ссылается на канонический шаблон в `docs/templates/`, не дублируя его. Так у обоих ревьюеров (`spec-skeptic` и `arch-reviewer`) одна и та же рубрика глубины и формула disagree-flag.
- **Hooks — для валидации.** `.claude/hooks/state-guard.sh` — PreToolUse-хук на Task. Он независимо проверяет, что `(subagent_type, stage)` валидно, и блокирует вызов если нет. Это belt-and-suspenders поверх инлайн-валидации в командах: даже если кто-то вызовет сабагент напрямую (через Task minus команда), хук не пропустит. Хук — единственный примитив, который видит **все** вызовы Task и может централизованно сказать «нет».

Один и тот же функциональный кусок не дублируется в двух примитивах. Например, дисциплина «≥7 objections + Pass 2» живёт в одном месте — в `spec-skeptic` агенте и в `review-rubric` skill (на которую агент ссылается); slash-команда `/challenge-spec` про это не знает.

### 6.2 Обмен артефактами

**Через файлы в `process/<slug>/`, никогда через контекст основного агента.** Каждый сабагент читает явно перечисленные пути и пишет на явно перечисленные пути. Slash-команда передаёт сабагенту абсолютные пути в промпте; сабагент не наследует контекст разговора (Task tool изолирует контекст).

Это даёт **возобновляемость**. Сценарий:

1. Разработчик запустил `/start payment-service`, прошёл интервью, получил `spec.md`, апрувнул, запустил `/challenge-spec`. Получил `spec-review.md`.
2. Закрыл ноутбук. Через 4 дня снова открыл `claude` в той же папке.
3. Запустил `/status` — увидел `Project: payment-service / Stage: spec-reviewed / Pending: apply verdicts and set stage: verdicts-applied`.
4. Применил вердикты, вручную поправил stage, запустил `/architect` — продолжил с того же места.

Контекст основного агента может быть полностью утерян — состояние пайплайна целиком в `STATE.md` и артефактах.

Альтернатива «всё через контекст основного агента» отвергнута: контекст ограничен, не сериализуется, не выживает между сессиями, не виден ревьюеру при оценке.

### 6.3 Защита от sycophancy

Это самое больное место подобных пайплайнов. Просто «попроси быть критичным» не работает. Конкретные техники, разложенные по местам кода:

- **Изоляция контекстов через сабагентов.** Каждый ревьюер запускается в чистом контексте, без диалога, который произвёл артефакт. Это снимает «социальное давление» — нет «автора», с которым нужно соглашаться. (Все 5 ролей — отдельные сабагенты. См. секцию `tools` в каждом `.claude/agents/*.md`.)
- **Квота ≥7 objections + Pass 2 с ≥5 выживших.** `spec-skeptic` обязан сначала **сгенерировать**, потом **самокритично рейтинговать**. Если квота не выполнена, агент пишет «Insufficient depth — Pass 1 must be redone» и не выдаёт verdict. (См. `.claude/agents/spec-skeptic.md` `# Mandatory two-pass process` и `# Verdict gate`; `.claude/skills/review-rubric/SKILL.md` `## Two-pass discipline`.)
- **Двухпроходная глубинная рубрика deep/medium/shallow.** Pass 2 — это анти-padding-механизм. Generic «consider observability» помечается shallow и не учитывается в гейте. (См. `.claude/skills/review-rubric/SKILL.md` `## Depth rubric`.)
- **3am production frame.** Системный промпт обоих ревьюеров буквально содержит фрейм «3am, production on fire». Каждый objection / scenario обязан быть формулируем в этой раме. Generic советы фрейм не выдерживают. (См. `.claude/agents/spec-skeptic.md` `# Frame`; `.claude/agents/arch-reviewer.md` `# Frame`.)
- **Per-ADR disagree-flag с двумя именованными формами.** `arch-reviewer` обязан в каждой per-ADR секции занять одну из двух позиций: «I disagree with X because Y» **либо** «I considered objections [≥2] and rejected them because [...]». Пустой / уклончивый flag инвалидизирует весь review. Form 2 заставляет агент **придумать** возможные возражения, даже если он соглашается — это отрезает «looks good». (См. `.claude/agents/arch-reviewer.md` пункт 5 и `.claude/skills/review-rubric/SKILL.md` `## Disagree-flag conventions`.)
- **Явный список запрещённых фраз.** «Looks good overall», «Good catch by the author», «Seems fine», «Consider X» без сценария — banned в обоих ревьюерах. (См. `.claude/skills/review-rubric/SKILL.md` `## Forbidden phrases`.)
- **Жёсткая изоляция `arch-reviewer` от `spec-review.md`.** Чтобы получить две **не выровненные** позиции, второй ревьюер не должен видеть первого. Запрет прописан в трёх местах: системный промпт `arch-reviewer`, тело команды `/review-arch` (которая буквально не передаёт путь), рубрика. Claude Code не позволяет path-whitelist на Read для отдельного сабагента, поэтому запрет — prompt-load-bearing; повторение в трёх местах — митигация. (См. `.claude/agents/arch-reviewer.md` `# Inputs (and a hard isolation rule)`; `.claude/commands/review-arch.md` `## Critical isolation rule`.)

Сюда же ложатся и более мелкие приёмы: правило «3 попыток → `[ASSUMED]`» у интервьюера (вместо догадывания за разработчика), запрет `architect` придумывать FR/NFR-IDs которых нет в спеке, требование `code-auditor` всегда ссылаться на file:line вместо trust-by-ADR.

### 6.4 Точки HITL

См. §4 выше. Краткое обоснование каждого гейта:

1. **Интервью** — иначе нет требований, всё остальное теряет смысл.
2. **Апрув спеки** — фиксирует, что разработчик читал, а не пролистывал. Без явного `approve` сабагент не закрывает стадию.
3. **Применение spec-review вердиктов** — это интерпретирующее решение (какие objections валидны для контекста). Автоматизировать опасно: разработчик лучше знает, что в его задаче — реальная дыра, что — теоретическая.
4. **Выбор между альтернативами в ADR** — если architect корректно показал развилку и не нашёл доминирующего варианта, выбор должен быть бизнес-входом, не решением модели.
5. **Go / iterate / kill после arch-review** — решение об инвестировании человеко-недель. Никогда не должно автоматизироваться.

### 6.5 Критерии завершения этапов

См. §5 выше. Обобщая — критерий каждой стадии — **наличие конкретного артефакта с конкретной структурой** (а не «агенты согласились»). Структура задана шаблоном (`docs/templates/`). Структурную полноту проверяет следующий за ней сабагент — он откажется работать, если предыдущий артефакт не дозаполнен (например, `architect` падает, если в спеке нет FR-IDs, на которые он мог бы сослаться).

Альтернатива — «голосование агентов» — отвергнута: агенты системно склонны соглашаться (см. §6.3), голосование лишь маскирует это.

---

## 7. Полигон: пример прогона

Полигон — DeepSeek HTTP-клиент: интеграция с LLM-провайдером (retry на 429/5xx с уважением `Retry-After`, rate limiting по token bucket, SSE streaming с обработкой обрыва, классификация ошибок, таймауты, наблюдаемость через метрики и trace-spans). Выбран потому, что в нём ≥5 архитектурных развилок: стратегия retry, алгоритм rate-limit, протокол стриминга, классификация ошибок, observability footprint.

Артефакты прогона будут лежать в `process/deepseek-client/` и заполняются в Phase 6 (текущая фаза — Phase 5: документация). После Phase 6 в этой папке появятся `spec.md`, `spec-review.md`, `adr/NNN-*.md`, `arch-review.md`.

---

## 8. Что НЕ включено (намеренно)

- **Сам бэкенд.** Это явное требование тестового задания: оценивается процесс, не код. Опциональный маленький кусок реализации с прогоном `code-auditor` — кандидат на Phase 7 (если время позволит).
- **UI или обвязка над `claude` CLI.** По заданию запрещено.
- **Своя система агентов поверх Claude Code.** Используются исключительно штатные примитивы: subagents, slash commands, skills, hooks.
- **Покрытие всех мыслимых этапов разработки.** Пять стадий, которые работают, лучше десяти, которые заявлены. Например, нет отдельной стадии «design review by product manager» или «security review» — они либо включены в существующие промпты (security как NFR-категория интервью + раздел arch-review), либо сознательно опущены.

---

## 9. Воспроизводимость

```bash
git clone <this-repo>
cd <repo>
claude
# в первом приглашении сессии:
/start <slug>
/interview
# далее по CLAUDE.md
```

Никаких переменных окружения. Никаких машинно-специфичных зависимостей. Тестировано на macOS; должно работать на Linux. Хук `state-guard.sh` тестируется локально через `bash .claude/hooks/state-guard.test.sh` (10 сценариев перехода, все зелёные).

---

## 10. Расширение

- **Новый сабагент:** добавить файл в `.claude/agents/<name>.md` с YAML-фронт-маттером (`name`, `description`, `tools`). Если он должен быть гейтнут хуком — расширить `case "$SUBAGENT_TYPE"` и блок `case "$SUBAGENT_TYPE" in ... ALLOWED=...` в `state-guard.sh` + добавить тест в `state-guard.test.sh`.
- **Новая slash-команда:** добавить файл в `.claude/commands/<name>.md` с YAML-фронт-маттером (`description`, `argument-hint`, `allowed-tools`). Внутри — секции `## Resolve active project`, `## Stage validation`, `## Hand off to subagent` (если применимо).
- **Новый skill:** `.claude/skills/<name>/SKILL.md` с YAML `name` и `description`. Skill — это конвенция, а не код; пишите дисциплину артефакта, ссылайтесь на канонический шаблон в `docs/templates/`.
- **Новый шаблон артефакта:** `docs/templates/<artifact>.template.md`. Канон один — не дублируйте в скиллах.

См. также `docs/decisions.md` — пост-мортем, компромиссы и «что бы доделали при бесконечном времени».
