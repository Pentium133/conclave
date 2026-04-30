# Claude Code Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Построить пайплайн агентов Claude Code для проектирования бэкенд-решений: 5 ролей-subagents, 7 slash commands, 3 skills, hooks, документация, и реальный прогон на полигоне DeepSeek HTTP-клиент.

**Architecture:** Subagents для ролей (изоляция контекста), slash commands для переходов, skills для шаблонов артефактов, hooks для валидации переходов и метрик. Артефакты живут в `process/<slug>/`, активный slug — в `process/CURRENT`. State of truth — `process/<slug>/STATE.md`.

**Tech Stack:** Claude Code primitives (agents, commands, skills, hooks), markdown, bash для hooks, jq.

**Spec:** `docs/superpowers/specs/2026-04-30-claude-pipeline-design.md`

**Notation:** в этом плане НЕ пишем литеральные тексты промптов и шаблонов (они объёмные и быстро перегружают контекст исполнителя). Каждая задача даёт спецификацию файла: что в нём должно быть, какие поведения, какой output. Сами тексты пишет исполнитель в момент выполнения задачи, опираясь на эту спецификацию.

---

## Приоритеты (если упираемся в бюджет)

- **MUST** (Phase 0–2, 5, 6) — базовый рабочий пайплайн с прогоном на полигоне.
- **SHOULD** (Phase 3, 4) — шаблоны как skills, hook на валидацию переходов.
- **NICE** (Phase 7) — метрики, двойной проход челленджера, реальный кусочек кода + /audit-code.

При нехватке времени режем с конца. План написан так, что можно остановиться после любой Phase и иметь рабочий артефакт для сдачи.

---

## File Structure

```
swarm/
├── CLAUDE.md                           # Phase 5
├── README.md                           # Phase 5
├── .gitignore                          # Phase 0
├── .claude/
│   ├── settings.json                   # Phase 0
│   ├── agents/
│   │   ├── interviewer.md              # Phase 1
│   │   ├── spec-skeptic.md             # Phase 1
│   │   ├── architect.md                # Phase 1
│   │   ├── arch-reviewer.md            # Phase 1
│   │   └── code-auditor.md             # Phase 1
│   ├── commands/
│   │   ├── start.md                    # Phase 2
│   │   ├── status.md                   # Phase 2
│   │   ├── interview.md                # Phase 2
│   │   ├── challenge-spec.md           # Phase 2
│   │   ├── architect.md                # Phase 2
│   │   ├── review-arch.md              # Phase 2
│   │   └── audit-code.md               # Phase 2
│   ├── skills/
│   │   ├── spec-template/SKILL.md      # Phase 3
│   │   ├── adr-template/SKILL.md       # Phase 3
│   │   └── review-rubric/SKILL.md      # Phase 3
│   └── hooks/
│       ├── state-guard.sh              # Phase 4
│       └── metrics.sh                  # Phase 7
├── docs/
│   ├── decisions.md                    # Phase 5
│   ├── templates/
│   │   ├── STATE.template.md           # Phase 0
│   │   ├── spec.template.md            # Phase 0
│   │   ├── adr.template.md             # Phase 0
│   │   ├── spec-review.template.md     # Phase 0
│   │   ├── arch-review.template.md     # Phase 0
│   │   └── post-review.template.md     # Phase 0
│   └── superpowers/                    # уже создано
└── process/
    ├── CURRENT                         # Phase 6 (создаётся /start)
    └── deepseek-client/                # Phase 6 (артефакты прогона)
        ├── STATE.md
        ├── spec.md
        ├── spec-review.md
        ├── arch-review.md
        ├── post-review.md (опц.)
        └── adr/
```

**Принципы декомпозиции:**
- Один файл = одна роль / одна команда / один шаблон. Никаких «универсальных агентов».
- Subagent-файл содержит только то, что нужно subagent: system prompt, tool whitelist, описание output. Никакой логики переходов между этапами — это в commands.
- Slash command — тонкая обёртка: проверка state → вызов subagent → обновление state. Без бизнес-логики.
- Hooks — единственное место с императивным кодом (bash).

---

## Phase 0: Foundation

### Task 1: Repository scaffold

**Files:**
- Create: `.gitignore`
- Create: `process/.gitkeep` (чтобы папка попала в git до первого прогона)

- [ ] **Step 1: Создать `.gitignore`**

Содержимое: игнорировать `.DS_Store`, `*.swp`, `node_modules/`, `.venv/`, локальные секреты типа `.env`. НЕ игнорировать `process/` — это часть сданного example run.

- [ ] **Step 2: Создать пустую структуру папок**

`mkdir -p .claude/agents .claude/commands .claude/skills .claude/hooks docs/templates process`. Touch `process/.gitkeep`.

- [ ] **Step 3: Commit**

`git add .gitignore process/.gitkeep && git commit -m "chore: scaffold repo structure"`

---

### Task 2: Templates

**Files:**
- Create: `docs/templates/STATE.template.md`
- Create: `docs/templates/spec.template.md`
- Create: `docs/templates/adr.template.md`
- Create: `docs/templates/spec-review.template.md`
- Create: `docs/templates/arch-review.template.md`
- Create: `docs/templates/post-review.template.md`

- [ ] **Step 1: STATE.template.md**

Должен содержать:
- YAML frontmatter с полями: `slug`, `stage` (intake/interview/spec-approved/spec-reviewed/verdicts-applied/arch-proposed/arch-reviewed/audit-done), `created`, `last_updated`.
- Секция «Current stage» — checkbox-список всех 7 stages с датами.
- Секция «Artifacts» — список ожидаемых файлов с статусом (pending / draft / approved).
- Секция «Pending human action» — что разработчик должен сделать дальше.
- Секция «Log» — таймстампы переходов.

- [ ] **Step 2: spec.template.md**

Обязательные секции (заполняет интервьюер):
- **Goal** — одно предложение что делаем
- **Functional requirements** — bullet-список с ID (FR-1, FR-2, ...)
- **Non-functional requirements** с подразделами: latency, throughput, availability/SLA, durability, security, observability, capacity, dependencies, deployment
- **Out of scope** — что сознательно не делаем
- **Open assumptions** — пометки `[ASSUMED]` куда интервьюер вписывает свои допущения когда разработчик уклончив
- **Approval** — поле, где разработчик ставит `approve` + дата

- [ ] **Step 3: adr.template.md**

Стандартный формат ADR:
- **Title** — `ADR-NNN: <decision>`
- **Status** — proposed/accepted/superseded
- **Context** — какие пункты спеки (FR/NFR-IDs) драйвят решение
- **Alternatives** — список из ≥2 рассмотренных, с trade-offs (cost / complexity / correctness / operability) для каждой
- **Decision** — выбранный вариант + явное обоснование
- **Consequences** — позитивные И негативные
- **Open questions** — что вынести в arch-review

- [ ] **Step 4: spec-review.template.md**

- **Frame** — фиксированная фраза «3am production failure mode»
- **Objections** — пронумерованный список из ≥7 слотов; для каждого: severity (block/major/minor), area (NFR/scope/edge/contradiction/missing), сценарий, что фиксить, ссылка на пункт спеки
- **Self-rating pass** — для каждого objection: deep / medium / shallow + почему
- **Verdict** — block / needs-changes / approve-with-notes; разрешён только после ≥5 deep+medium

- [ ] **Step 5: arch-review.template.md**

- **Per-ADR review** — секция на каждый ADR с вердиктом и аргументами
- **Disagree-flag (mandatory)** — обязательное поле «с каким решением архитектора я не согласен»; пустое значение запрещено, нужно `none — considered objections X, Y and rejected because...`
- **Production failure scenarios** — 3am-сценарии для выбранных подходов
- **Cross-cutting issues** — наблюдаемость, изоляция отказов, deployment
- **Final verdict** — block / iterate / approve

- [ ] **Step 6: post-review.template.md**

- **Per-FR check** — таблица FR-ID → met / not met / not testable + evidence (file:line)
- **Per-NFR check** — аналогично
- **Per-ADR check** — таблица ADR-ID → implemented / deviated + evidence
- **Findings** — bugs, NFR violations, missing observability
- **Verdict** — ship / fix-required / reject

- [ ] **Step 7: Commit**

`git add docs/templates/ && git commit -m "feat: добавить шаблоны артефактов пайплайна"`

---

### Task 3: settings.json

**Files:**
- Create: `.claude/settings.json`

- [ ] **Step 1: Создать `.claude/settings.json` с минимальной конфигурацией**

Содержимое:
- `permissions.allow` — Bash для команд `cat`, `cp`, `mkdir`, `bash .claude/hooks/*`, Read/Write/Edit для `process/**`, `.claude/**`, `docs/**`.
- `permissions.deny` — `Bash(rm -rf*)`, `Bash(git push*)` (защита от ненамеренных действий).
- Пустой `hooks` блок — наполним в Phase 4.

- [ ] **Step 2: Smoke test**

Запустить `claude` в папке, проверить что не упало с json parse error. `Ctrl+C` сразу выход.

- [ ] **Step 3: Commit**

`git add .claude/settings.json && git commit -m "feat: базовый settings.json с permissions"`

---

## Phase 1: Subagents

> Каждый subagent — markdown файл в `.claude/agents/<name>.md` с YAML frontmatter (`name`, `description`, `tools`) и system prompt в теле. Tool whitelist принципиален — изоляция возможностей убирает соблазн «выйти из роли».

### Task 4: interviewer subagent

**Files:**
- Create: `.claude/agents/interviewer.md`

- [ ] **Step 1: Написать subagent**

Что должно быть в системном промпте:
- **Role:** senior backend engineer, проводит интервью по требованиям. Цель — выудить FR и NFR, не уходить в реализацию.
- **Inputs:** путь к `process/<slug>/spec.md` (заполняет инкрементально), путь к `STATE.md` (обновляет stage и log).
- **Behaviors (mandatory):**
  - Один вопрос за раз. Multiple choice предпочтительнее open-ended.
  - Систематический проход по NFR-чек-листу (latency, throughput, availability, durability, security, observability, capacity, dependencies, deployment) — нельзя скипать категорию.
  - На уклончивый ответ («как считаете нужным», «как лучше») — переспросить с конкретными вариантами.
  - На противоречие с предыдущим ответом — явно процитировать оба и попросить разрешить.
  - Лимит: ≥3 попытки зафиксировать ответ → пометить `[ASSUMED: <значение>]` в spec.md и продолжить, перечислить все ASSUMED в конце.
- **Forbidden:**
  - Предлагать архитектурные решения / технологии.
  - Завершать интервью с пустыми обязательными NFR-секциями.
- **Stop condition:** все NFR-секции заполнены либо помечены `[ASSUMED]` → попросить разработчика написать `approve` в spec.md → обновить `STATE.md` (stage: spec-approved).
- **Output format:** инкрементально пишет в `process/<slug>/spec.md` по шаблону `docs/templates/spec.template.md`.

- **Tools:** `Read`, `Write`, `Edit`. НЕ давать `Bash`, `WebFetch`.

- [ ] **Step 2: Smoke test структуры**

`bash -c 'head -20 .claude/agents/interviewer.md'` — проверить frontmatter валиден, поля `name`, `description`, `tools` есть.

- [ ] **Step 3: Commit**

`git add .claude/agents/interviewer.md && git commit -m "feat: subagent interviewer"`

---

### Task 5: spec-skeptic subagent

**Files:**
- Create: `.claude/agents/spec-skeptic.md`

- [ ] **Step 1: Написать subagent**

Что в промпте:
- **Role:** adversarial reviewer спеки. Frame — «3am, прод дымится, что в спеке не предусмотрено?».
- **Inputs:** `process/<slug>/spec.md` (через Read). НЕ имеет доступа к диалогу интервью или к контексту основного агента.
- **Process (mandatory two-pass):**
  - **Pass 1:** сгенерировать ≥7 пронумерованных конкретных возражений по шаблону `spec-review.template.md`. Каждое — со scenario (конкретная производственная ситуация), severity, area, что фиксить, ссылка на FR/NFR-ID.
  - **Pass 2:** перечитать свои возражения и оценить каждое по рубрике: deep / medium / shallow. Shallow выбрасываются (зачёркиваются и помечаются «discarded — too generic / not actionable»).
  - **Verdict:** разрешён только после ≥5 переживших оценку (deep+medium) возражений. Verdicts: block / needs-changes / approve-with-notes.
- **Forbidden:**
  - «Looks good overall» без ≥5 возражений. Жёстко: даже если кажется что спека хороша, найди ≥5 сценариев отказа.
  - Generic «consider X» без production scenario.
  - Согласиться с автором спеки. Никаких «good catch by the author».
- **Output:** `process/<slug>/spec-review.md`. Обновить `STATE.md` → stage: spec-reviewed.
- **Tools:** `Read`, `Write`. Никакого `Edit` по spec.md (челленджер не правит чужой артефакт).

- [ ] **Step 2: Smoke check**

Прочитать файл, убедиться что forbidden-секция и two-pass явно прописаны.

- [ ] **Step 3: Commit**

`git add .claude/agents/spec-skeptic.md && git commit -m "feat: subagent spec-skeptic с two-pass"`

---

### Task 6: architect subagent

**Files:**
- Create: `.claude/agents/architect.md`

- [ ] **Step 1: Написать subagent**

Что в промпте:
- **Role:** technical architect. Превращает approved spec.md (с применёнными вердиктами spec-review) в набор ADR-ов.
- **Inputs:** `process/<slug>/spec.md`, `process/<slug>/spec-review.md` (видит ОБА — это сознательно, архитектор должен учитывать возражения челленджера).
- **Process:**
  - Идентифицировать архитектурные развилки в спеке (для DeepSeek-клиента типичные: retry/backoff стратегия, rate-limit алгоритм, streaming протокол, классификация ошибок, идемпотентность, наблюдаемость).
  - На каждую развилку — отдельный ADR в `process/<slug>/adr/NNN-<topic>.md` по шаблону `docs/templates/adr.template.md`.
  - В каждом ADR обязательно ≥2 альтернативы с trade-offs (cost / complexity / correctness / operability).
  - Decision содержит обратные ссылки на FR/NFR-IDs.
  - Consequences обязаны включать НЕГАТИВНЫЕ.
  - Если есть нерешённое — секция «Open questions» с явным маркером для arch-review.
- **Forbidden:**
  - ADR с одной альтернативой («очевидное решение»). Если кажется очевидным — найди вариант, который явно хуже, чтобы trade-off был виден.
  - «We will use X because it's standard» без обоснования через NFR.
- **Output:** ADR-ы пронумерованы последовательно начиная с 001. Обновить `STATE.md` → stage: arch-proposed; список ADR-ов в Artifacts.
- **Tools:** `Read`, `Write`, `Edit`.

- [ ] **Step 2: Smoke check**

Файл валиден, описаны ≥2 альтернативы как mandatory, негативные consequences как mandatory.

- [ ] **Step 3: Commit**

`git add .claude/agents/architect.md && git commit -m "feat: subagent architect"`

---

### Task 7: arch-reviewer subagent

**Files:**
- Create: `.claude/agents/arch-reviewer.md`

- [ ] **Step 1: Написать subagent**

Что в промпте:
- **Role:** независимый ревьюер архитектуры. Frame — «найди причины, по которым это не полетит в проде».
- **Inputs (КРИТИЧНО):** только `process/<slug>/spec.md` и `process/<slug>/adr/*.md`. **Запрещено читать `spec-review.md`** — чтобы не якориться на чужой критике и сформировать независимый взгляд.
- **Process:**
  - На каждый ADR — секция в `arch-review.md`: вердикт (block / approve-with-changes / approve), 3am-сценарии отказа, конкретные production-проблемы.
  - **Disagree-flag (mandatory):** в конце каждой секции — поле «I disagree with...». Пустое значение запрещено: либо назови конкретное несогласие, либо явно напиши «considered the following objections [list] and rejected them because [reasons]».
  - Cross-cutting issues — наблюдаемость as a whole, изоляция отказов, deployment story.
  - Final verdict: block / iterate / approve.
- **Forbidden:**
  - Читать `spec-review.md` (изоляция от челленджера).
  - Approve без явного disagree-flag.
  - Generic «consider monitoring» без указания конкретного сигнала и threshold.
- **Output:** `process/<slug>/arch-review.md`. Обновить STATE → arch-reviewed.
- **Tools:** `Read` (с whitelist путей: только spec.md и adr/), `Write`. Если возможно технически — ограничить Read паттерном; если нет — оставить мягким требованием в промпте (и проверять через метрики).

- [ ] **Step 2: Smoke check**

В промпте явно прописан запрет на spec-review.md, mandatory disagree-flag.

- [ ] **Step 3: Commit**

`git add .claude/agents/arch-reviewer.md && git commit -m "feat: subagent arch-reviewer с изоляцией от spec-review"`

---

### Task 8: code-auditor subagent

**Files:**
- Create: `.claude/agents/code-auditor.md`

- [ ] **Step 1: Написать subagent**

Что в промпте:
- **Role:** post-implementation reviewer. Проверяет код на соответствие spec и ADR.
- **Inputs:** `process/<slug>/spec.md`, `process/<slug>/adr/*.md`, пути к коду (передаются разработчиком в `/audit-code`).
- **Process:**
  - Прочитать spec и все ADR.
  - Прочитать код. Использовать Grep/Glob для поиска по ключевым словам из ADR (например, «retry», «backoff», «rate limit»).
  - Заполнить `process/<slug>/post-review.md` по шаблону: таблицы FR-ID → met/not met/not testable, NFR-ID → met/..., ADR-ID → implemented/deviated. С evidence в виде `file.ext:LN`.
  - Findings: список конкретных проблем с severity.
  - Verdict: ship / fix-required / reject.
- **Forbidden:**
  - Verdict без заполненных таблиц. Каждый FR/NFR/ADR должен иметь явный статус.
  - Findings без `file:line` evidence.
  - Чинить код. Только аудит.
- **Output:** `process/<slug>/post-review.md`. Обновить STATE → audit-done.
- **Tools:** `Read`, `Grep`, `Glob`, `Bash` с whitelist read-only команд (`ls`, `wc`, `head`, `tail`).

- [ ] **Step 2: Commit**

`git add .claude/agents/code-auditor.md && git commit -m "feat: subagent code-auditor"`

---

## Phase 2: Slash commands

> Slash command — тонкая обёртка. Структура каждой: YAML frontmatter (`description`) + тело с инструкциями для основного агента: «прочитай STATE.md, проверь предусловие, вызови такой-то subagent с такими-то аргументами, обнови STATE.md». Аргументы команды (если есть) — через `$ARGUMENTS`.

### Task 9: /start

**Files:**
- Create: `.claude/commands/start.md`

- [ ] **Step 1: Написать команду**

Что делает:
- Принимает `$ARGUMENTS` = slug (валидация: lowercase-kebab-case).
- Проверяет: `process/<slug>/` НЕ должен существовать (отказ если есть).
- Создаёт `process/<slug>/`, `process/<slug>/adr/`.
- Копирует `docs/templates/STATE.template.md` в `process/<slug>/STATE.md`, заполняет slug, created, начальный stage = `intake`.
- Записывает slug в `process/CURRENT` (одна строка).
- Печатает: «Started <slug>. Run `/interview` to begin requirements gathering.»

- [ ] **Step 2: Smoke test**

`claude` → `/start test-slug` → проверить что появилась `process/test-slug/STATE.md` и `process/CURRENT` = `test-slug`. Удалить тестовую папку.

- [ ] **Step 3: Commit**

`git add .claude/commands/start.md && git commit -m "feat: /start команда"`

---

### Task 10: /status

**Files:**
- Create: `.claude/commands/status.md`

- [ ] **Step 1: Написать команду**

Что делает:
- Читает `process/CURRENT`. Если пусто/нет — сообщает «No active project. Run `/start <slug>`.» и выходит.
- Читает `process/<current>/STATE.md`.
- Рендерит пользователю:
  - Текущий stage.
  - Чек-лист этапов (что сделано, что pending).
  - Список артефактов и их статус.
  - **Pending human action** — что должно произойти дальше.
- НЕ обновляет STATE.

- [ ] **Step 2: Smoke test**

`/status` без активного проекта → корректное сообщение. `/start x` → `/status` → видно состояние.

- [ ] **Step 3: Commit**

`git add .claude/commands/status.md && git commit -m "feat: /status команда"`

---

### Task 11: /interview

**Files:**
- Create: `.claude/commands/interview.md`

- [ ] **Step 1: Написать команду**

Что делает:
- Читает `process/CURRENT` → slug.
- Проверяет stage: должен быть `intake` ИЛИ `interview` (resumable). Иначе — отказ с подсказкой что делать.
- Вызывает subagent `interviewer` через Task tool, передавая в prompt: путь к `process/<slug>/spec.md`, путь к `STATE.md`, путь к `docs/templates/spec.template.md`.
- На старте subagent либо создаёт spec.md из шаблона (если не существует), либо продолжает заполнение.
- После завершения интервью (subagent сам обновляет STATE → spec-approved) — печатает результат и предлагает `/challenge-spec`.

- [ ] **Step 2: Smoke test**

После `/start x` → `/interview` должно вызвать subagent. Прерывание Ctrl+C допустимо для smoke; полный прогон — в Phase 6.

- [ ] **Step 3: Commit**

---

### Task 12: /challenge-spec

**Files:**
- Create: `.claude/commands/challenge-spec.md`

- [ ] **Step 1: Написать команду**

Что делает:
- Читает CURRENT, проверяет stage = `spec-approved`.
- Вызывает subagent `spec-skeptic` с путями к spec.md, spec-review.template.md, STATE.md.
- Subagent делает two-pass и пишет spec-review.md, обновляет STATE → spec-reviewed.
- После — печатает summary возражений и предлагает разработчику применить вердикты к spec.md, потом написать в STATE.md `verdicts-applied`.

- [ ] **Step 2: Commit**

---

### Task 13: /architect

**Files:**
- Create: `.claude/commands/architect.md`

- [ ] **Step 1: Написать команду**

Что делает:
- Читает CURRENT, проверяет stage = `verdicts-applied` (или `spec-reviewed` с notes о no-action-needed).
- Вызывает subagent `architect` с путями к spec.md, spec-review.md, adr.template.md, STATE.md.
- Subagent создаёт ADR-ы, обновляет STATE → arch-proposed.
- Печатает список созданных ADR и предлагает `/review-arch`.

- [ ] **Step 2: Commit**

---

### Task 14: /review-arch

**Files:**
- Create: `.claude/commands/review-arch.md`

- [ ] **Step 1: Написать команду**

Что делает:
- Читает CURRENT, проверяет stage = `arch-proposed`.
- Вызывает subagent `arch-reviewer`. **В prompt НЕ передаём путь к spec-review.md** — изоляция. Передаём только spec.md, adr/, arch-review.template.md, STATE.md.
- Subagent создаёт arch-review.md, обновляет STATE → arch-reviewed.
- Печатает final verdict и mandatory disagree-flag, предлагает решение разработчика (go / iterate / kill).

- [ ] **Step 2: Commit**

---

### Task 15: /audit-code

**Files:**
- Create: `.claude/commands/audit-code.md`

- [ ] **Step 1: Написать команду**

Что делает:
- Читает CURRENT, проверяет stage ∈ {arch-reviewed, audit-done} (повторный аудит допустим).
- Принимает `$ARGUMENTS` = пути к коду (один или несколько).
- Вызывает subagent `code-auditor` с путями spec.md, adr/, code paths, post-review.template.md, STATE.md.
- Subagent создаёт post-review.md, обновляет STATE → audit-done.

- [ ] **Step 2: Commit**

`git add .claude/commands/ && git commit -m "feat: набор slash commands пайплайна"` (если коммитим скопом).

---

## Phase 3: Skills (SHOULD)

> Skills загружаются по триггеру и переиспользуются разными subagents. Каждый skill — папка с `SKILL.md` (frontmatter + правила применения).

### Task 16: spec-template skill

**Files:**
- Create: `.claude/skills/spec-template/SKILL.md`

- [ ] **Step 1: Написать skill**

- **Frontmatter:** `name: spec-template`, `description: Use when filling or updating process/<slug>/spec.md — provides the canonical spec format and required sections`.
- **Body:** ссылка на `docs/templates/spec.template.md`, чек-лист обязательных секций, правила: «не закрывай раздел NFR, если есть `[ASSUMED]` без подтверждения», «FR-ID нумеруются последовательно».
- Используется `interviewer` subagent.

- [ ] **Step 2: Commit**

---

### Task 17: adr-template skill

**Files:**
- Create: `.claude/skills/adr-template/SKILL.md`

- [ ] **Step 1: Написать skill**

- **Frontmatter:** `name: adr-template`, `description: Use when writing or updating an ADR file in process/<slug>/adr/`.
- **Body:** ссылка на шаблон, правила: «≥2 альтернатив», «trade-offs по 4 осям», «consequences с явным negative разделом», «обратная ссылка на FR/NFR-ID обязательна».
- Используется `architect`.

- [ ] **Step 2: Commit**

---

### Task 18: review-rubric skill

**Files:**
- Create: `.claude/skills/review-rubric/SKILL.md`

- [ ] **Step 1: Написать skill**

- **Frontmatter:** `name: review-rubric`, `description: Use when generating spec-review.md or arch-review.md — defines the depth rubric and disagree-flag conventions`.
- **Body:** определения deep/medium/shallow с примерами; правила two-pass для spec-skeptic; правила disagree-flag для arch-reviewer; запрет «approve without N concrete issues».
- Используется `spec-skeptic` и `arch-reviewer`.

- [ ] **Step 2: Commit**

`git add .claude/skills/ && git commit -m "feat: skills для шаблонов и рубрики ревью"`

---

## Phase 4: Hooks (SHOULD)

### Task 19: state-guard.sh

**Files:**
- Create: `.claude/hooks/state-guard.sh`

- [ ] **Step 1: Написать тест-фикстуры**

Создать `.claude/hooks/test-fixtures/` с 3 файлами STATE.md в разных stages (intake, spec-approved, arch-reviewed). Это тестовые данные для проверки скрипта.

- [ ] **Step 2: Написать failing test**

Bash-скрипт `.claude/hooks/state-guard.test.sh`:
- Сценарий 1: stage=intake, command=architect → expect exit 1.
- Сценарий 2: stage=spec-approved, command=challenge-spec → expect exit 0.
- Сценарий 3: stage=spec-approved, command=architect → expect exit 1.
Запустить — должен упасть, потому что state-guard.sh ещё нет.

- [ ] **Step 3: Реализовать state-guard.sh**

Скрипт принимает аргументы: `--state-file <path>` `--command <name>`. Читает stage из YAML frontmatter STATE.md, сравнивает с таблицей разрешённых stages для команды. Exit 0 если разрешено, exit 1 + сообщение в stderr если нет.

Таблица разрешённых stages:
- `start`: всегда (но проверяет отсутствие папки — это уже в /start)
- `interview`: intake, interview
- `challenge-spec`: spec-approved
- `architect`: verdicts-applied, spec-reviewed
- `review-arch`: arch-proposed
- `audit-code`: arch-reviewed, audit-done
- `status`: всегда

- [ ] **Step 4: Прогнать тесты — должны пройти**

`bash .claude/hooks/state-guard.test.sh` → all green.

- [ ] **Step 5: Wire-up в slash commands**

В каждой команде (кроме /start, /status) — первый шаг: `bash .claude/hooks/state-guard.sh --state-file process/$(cat process/CURRENT)/STATE.md --command <self>`. Если exit ≠ 0 — команда печатает сообщение и завершается.

- [ ] **Step 6: Commit**

`git add .claude/hooks/state-guard.sh .claude/hooks/state-guard.test.sh .claude/hooks/test-fixtures/ && git commit -m "feat: state-guard с тестами"`

---

## Phase 5: Documentation

### Task 20: CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Написать**

Содержание:
- **What this is** — 2 предложения: пайплайн агентов для проектирования бэкендов.
- **Quickstart** — точные команды: `git clone <url> && cd swarm && claude`, потом `/start <slug>`, потом `/interview`, и т.д.
- **Pipeline stages** — диаграмма (ASCII) переходов между stages.
- **Slash commands reference** — таблица: команда → что делает → предусловие.
- **Where artifacts live** — `process/<slug>/`, объяснение `process/CURRENT`.
- **Resumability** — как поднять процесс с середины.
- **Required environment** — какие модели предполагаются (упомянуть что работает на стандартных моделях Claude Code), нужны ли env vars (нет).

- [ ] **Step 2: Commit**

---

### Task 21: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Написать**

Содержание (по требованиям задания):
- Описание процесса: какие 5 ролей, в каком порядке, что передают друг другу.
- HITL-точки и критерии выхода из этапов.
- **Открытые дизайн-решения** (по списку из задания):
  - Subagents vs slash commands vs skills vs hooks — наш выбор и обоснование (взять из спека `2026-04-30-claude-pipeline-design.md`).
  - Обмен артефактами — через файлы; resumability.
  - Антисикофантия — конкретные приёмы (изоляция, квота, two-pass, disagree-flag).
  - Human-in-the-loop точки.
  - Критерии завершения этапа.
- Ссылка на `example-run`-аналог: `process/deepseek-client/`.

- [ ] **Step 2: Commit**

---

### Task 22: docs/decisions.md

**Files:**
- Create: `docs/decisions.md`

- [ ] **Step 1: Написать рефлексию**

≤1 страница. Заполняется в самом конце, после прогона. Структура:
- Что не сработало с первого раза (конкретные итерации).
- Какие компромиссы приняли (например: state-guard как скрипт из команды, а не настоящий PreToolUse hook — почему).
- Что бы доделали при бесконечном времени (полный список бонусов).
- Сюрпризы.

Этот таск помечается «заполнить в самом конце»; черновик можно начать сейчас, но финал — после Phase 6.

- [ ] **Step 2: Commit**

`git add CLAUDE.md README.md docs/decisions.md && git commit -m "docs: CLAUDE.md, README, рефлексия"`

---

## Phase 6: Example run on DeepSeek polygon

> Это «прогон пайплайна на полигоне». Артефакты остаются в репо как evidence. Часть взаимодействия интерактивная — разработчик играет роль «разработчика, пришедшего с задачей».

### Task 23: /start deepseek-client

- [ ] **Step 1: Запустить**

```bash
claude
> /start deepseek-client
```
Ожидаем создание `process/deepseek-client/` со STATE.md, и `process/CURRENT` = `deepseek-client`.

- [ ] **Step 2: Commit стартовое состояние**

`git add process/ && git commit -m "process: start deepseek-client"`

---

### Task 24: /interview → spec.md

- [ ] **Step 1: Прогнать интервью**

`/interview`. Отвечать на вопросы интервьюера правдоподобно для задачи «HTTP-клиент к DeepSeek». Цель — получить полную спеку.

Подготовить ментально reference-ответы (НЕ в плане, чтобы не подсказывать модели):
- Целевая нагрузка: миддл-сервис, ~50 RPS, P99 < 1s для non-streaming.
- Streaming: SSE.
- Ошибки: распознавать 429, 5xx, network — по-разному ретраить.
- Идемпотентность: client-side request-id.
- Наблюдаемость: метрики — latency p50/95/99, retry counts, rate-limit hits; логи — sampled; tracing — opt-in.

Интервьюер должен сам дойти до этих тем; если не доходит — это сигнал, что промпт надо подкручивать (фиксируется в decisions.md).

- [ ] **Step 2: Дать `approve` в spec.md когда готово**

- [ ] **Step 3: Commit**

`git add process/deepseek-client/spec.md process/deepseek-client/STATE.md && git commit -m "process: spec.md одобрена"`

---

### Task 25: /challenge-spec → spec-review.md

- [ ] **Step 1: Прогнать**

`/challenge-spec`. Получить spec-review.md с ≥7 возражениями и two-pass оценкой.

- [ ] **Step 2: Проверить качество**

Глазами: возражения конкретные? Привязаны к FR/NFR-IDs? Severity осмыслены? Нет ли «consider X» без сценария?

Если качество слабое — НЕ переписывать промпт под ходу прогона (исказит example run). Зафиксировать в decisions.md как «iteration: spec-skeptic слишком обтекаемый, в следующей версии добавим Y».

- [ ] **Step 3: Применить вердикты**

Разработчик читает spec-review.md, расставляет accepted/rejected/deferred, обновляет spec.md под accepted. Помечает в STATE.md → verdicts-applied.

- [ ] **Step 4: Commit**

---

### Task 26: /architect → ADRs

- [ ] **Step 1: Прогнать**

`/architect`. Получить пачку ADR-ов в `process/deepseek-client/adr/`.

- [ ] **Step 2: Проверить структуру**

В каждом ADR ≥2 альтернативы, негативные consequences, обратные ссылки на FR/NFR.

- [ ] **Step 3: Commit**

---

### Task 27: /review-arch → arch-review.md

- [ ] **Step 1: Прогнать**

`/review-arch`. Проверить что ревьюеру НЕ передавался spec-review.md (изоляция работает).

- [ ] **Step 2: Проверить disagree-flag**

В arch-review.md заполнен mandatory disagree-flag.

- [ ] **Step 3: Commit**

`git add process/deepseek-client/ && git commit -m "process: arch review завершён"`

---

## Phase 7: Bonus (NICE)

### Task 28: metrics.sh hook

**Files:**
- Create: `.claude/hooks/metrics.sh`

- [ ] **Step 1: Написать**

Stop hook. После каждого вызова subagent — парсит `spec-review.md` или `arch-review.md` (определяется по последнему изменённому файлу) и пишет в `process/<slug>/metrics.json`:
- `objections_total`, `objections_deep`, `objections_medium`, `objections_shallow_discarded`
- `accepted` / `rejected` / `deferred` counts (после verdicts-applied)
- `arch_disagrees_count`

- [ ] **Step 2: Wire as Stop hook в settings.json**

- [ ] **Step 3: Commit**

---

### Task 29: spec-skeptic double-pass enforcement

- [ ] **Step 1: Усилить промпт**

В `.claude/agents/spec-skeptic.md` явно прописать что Pass 2 — это ОТДЕЛЬНЫЙ внутренний цикл; запрет на verdict без зачёркнутых shallow.

Опционально: разделить на два subagents (`spec-skeptic-pass1`, `spec-skeptic-pass2`) если single-agent self-review плохо работает на практике.

- [ ] **Step 2: Прогнать на полигоне повторно, сравнить качество**

Зафиксировать результат в decisions.md.

- [ ] **Step 3: Commit**

---

### Task 30: Maленький retry-handler + /audit-code

**Files:**
- Create: `src/retry_handler.py` (или другой язык — выбрать в момент исполнения)
- Create: `tests/test_retry_handler.py`

- [ ] **Step 1: Реализовать retry-handler по выбранному ADR**

Минимум: classify_error(response) → {retryable, non_retryable, rate_limit}; backoff(attempt) → delay; retry_loop с лимитом попыток. ≤100 строк.

- [ ] **Step 2: Написать unit-тесты**

≥5 тестов: 5xx → retry, 4xx → no retry, 429 → respect Retry-After, max attempts, success on first try.

- [ ] **Step 3: Прогнать `/audit-code src/retry_handler.py`**

Получить `process/deepseek-client/post-review.md`. Проверить что аудит реально нашёл evidence для каждого FR/ADR пункта (или пометил not-testable с причиной).

- [ ] **Step 4: Commit**

---

### Task 31: Prompt regression tests

**Files:**
- Create: `tests/prompts/evasive-developer.md` (фикстура с уклончивыми ответами)
- Create: `tests/prompts/run.sh`

- [ ] **Step 1: Написать фикстуру**

Сценарий: разработчик отвечает уклончиво и противоречиво на 5 ключевых вопросов. Ожидаемое поведение интервьюера: возвращение к противоречию, multiple choice, лимит попыток → ASSUMED.

- [ ] **Step 2: Реализовать run.sh**

Запускает `claude --print` с pre-recorded ответами. Проверяет что финальная spec.md содержит хотя бы 2 `[ASSUMED]` пометки.

- [ ] **Step 3: Commit**

---

## Финал: проверка перед сдачей

### Task 32: Final review

- [ ] **Step 1: Воспроизводимость**

Из чистой папки: `git clone . /tmp/swarm-test && cd /tmp/swarm-test && claude` → `/start test-x` → должно работать.

- [ ] **Step 2: Заполнить decisions.md финальным контентом**

Перечитать STATE.md, ADR-ы, review — достать сюрпризы и итерации, выписать.

- [ ] **Step 3: Финальный self-check по критериям задания**

Сверить с `test-task.md`:
- [ ] 5 этапов покрыты
- [ ] `.claude/`, `CLAUDE.md`, `README.md`, `docs/decisions.md`, артефакты прогона — все есть
- [ ] Открытые дизайн-решения описаны в README
- [ ] Воспроизводимо без скрытых зависимостей

- [ ] **Step 4: Финальный commit**

`git commit --allow-empty -m "release: пайплайн готов к сдаче"`

---

## Self-Review

Спек coverage: ✓ всё из секции «5 этапов» имеет таски (Phase 1+2+6); ✓ маппинг ролей→примитивы реализован (Phase 1–4); ✓ структура `process/<slug>/` создаётся в Task 9 и используется во всех последующих; ✓ антисикофантия зашита в Tasks 5, 7, 18, 29; ✓ HITL-гейты — в командах через `state-guard` (Task 19); ✓ критерии завершения — в шаблонах (Task 2) и проверяются `state-guard`; ✓ resumability — через STATE.md, `/status` (Task 10).

Type/name consistency: ✓ slug ссылается одинаково везде (`process/<slug>/`, `process/CURRENT`); ✓ stage-имена консистентны (intake, interview, spec-approved, spec-reviewed, verdicts-applied, arch-proposed, arch-reviewed, audit-done) везде в плане; ✓ имена subagents совпадают между Phase 1 и slash commands в Phase 2.

Placeholders: проверено — нет «TBD/TODO/implement later». Где сказано «в момент исполнения» — это сознательное решение по запросу пользователя не зашивать литеральные тексты промптов в план.

Открытое допущение для исполнителя: при написании subagent-файлов и commands нужно сверяться с актуальной документацией Claude Code по формату `.claude/agents/*.md` и `.claude/commands/*.md` (frontmatter поля, как Task tool вызывает subagents). Если за время написания плана формат изменился — следовать актуальному формату, не плану. Этот пункт зафиксировать в `decisions.md`.
