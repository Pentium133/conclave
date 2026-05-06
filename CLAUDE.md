# CLAUDE.md — точка входа для Claude Code

## Что это

Это **Claude Code плагин `conclave`** — пайплайн агентов, который проводит разработчика через структурированное проектирование бэкенд-задачи: интервью → спека → адверсариальное ревью → ADR → ревью архитектуры → пост-ревью кода. Сам бэкенд здесь не пишется — артефакт репозитория это **конфигурация плагина** (агенты, команды, скиллы, шаблоны, хук) и порядок её использования.

Все команды живут в namespace `/conclave:*`, чтобы исключить конфликты с другими плагинами.

## Установка

Этот репозиторий и есть плагин. Установите его в Claude Code как локальный marketplace:

```bash
# в любой сессии Claude Code:
/plugin marketplace add /path/to/this/repo
/plugin install conclave@<marketplace-name>
```

После этого команды `/conclave:*` будут доступны в любом проекте, а артефакты пайплайна (`process/<slug>/...`) будут писаться в CWD конкретного проекта.

## Quickstart

```bash
cd <your-project>            # любой проект, где хотите запустить пайплайн
claude                       # сессия Claude Code
/conclave:start <slug>       # пример: /conclave:start payment-service
/conclave:interview          # отвечаем на вопросы — на выходе process/<slug>/spec.md
# вручную: апрувим спеку — пишем `approve` и дату в §Approval файла spec.md
/conclave:challenge-spec     # адверсариальное ревью спеки
# вручную: применяем вердикты (см. ниже отдельный раздел)
/conclave:architect          # ADRs в process/<slug>/adr/
/conclave:review-arch        # независимое ревью архитектуры
/conclave:implement <scope>  # (опц.) узкий кусок кода+тестов под утверждённые ADR
/conclave:audit-code <paths> # когда появится код — пост-ревью реализации
/conclave:status             # в любой момент: где мы, что дальше
```

## Машина состояний пайплайна

```
                    /start <slug>
                          │
                          ▼
                       intake
                          │ /interview (subagent: interviewer)
                          ▼
                     interview
                          │ developer пишет `approve` в §Approval spec.md
                          ▼
                   spec-approved
                          │ /challenge-spec (subagent: spec-skeptic)
                          ▼
                   spec-reviewed
                          │ developer применяет вердикты к spec.md
                          │ и вручную ставит stage: verdicts-applied
                          ▼
                  verdicts-applied
                          │ /architect (subagent: architect)
                          ▼
                   arch-proposed
                          │ /review-arch (subagent: arch-reviewer)
                          ▼
                   arch-reviewed
                          │ (опц.) /implement <scope> (subagent: implementer)
                          ▼
                    implemented
                          │ /audit-code <paths> (subagent: code-auditor)
                          ▼
                     audit-done
```

Дефолтный конвейер — design pipeline — заканчивается на `arch-reviewed`. Стадии `implemented` и `audit-done` опциональны: разработчик заходит на них только если хочет продемонстрировать пост-ревью на реальном куске кода (`/implement` пишет узкий чанк по ADR, `/audit-code` его проверяет). Переход `arch-reviewed → audit-done` напрямую тоже допустим — если код шипался вне пайплайна.

Все переходы (кроме двух HITL — апрува спеки и установки `verdicts-applied`) выполняют сабагенты, обновляя `process/<slug>/STATE.md`.

## Slash-команды

| Команда | Что делает | Допустимая stage |
|---|---|---|
| `/conclave:start <slug>` | Создаёт `process/<slug>/`, копирует `STATE.md`, выставляет `stage: intake`, пишет `process/CURRENT` | (нет активного проекта) |
| `/conclave:status` | Read-only — показывает stage, чек-лист, артефакты, pending action | любая |
| `/conclave:interview` | Запускает сабагент `interviewer` для роста `spec.md` | `intake`, `interview` |
| `/conclave:challenge-spec` | Запускает `spec-skeptic` — ≥7 возражений + двупроходная самооценка | `spec-approved` |
| `/conclave:architect` | Запускает `architect` — пишет ADRs в `process/<slug>/adr/` | `verdicts-applied` (или `spec-reviewed` с лог-строкой `no-action-needed`) |
| `/conclave:review-arch` | Запускает `arch-reviewer` — независимое ревью; **не читает `spec-review.md`** | `arch-proposed` |
| `/conclave:implement <scope>` | (опц.) Запускает `implementer` — узкий кусок кода+тестов по утверждённым ADR; ≥5 тестов, цитирование ADR-IDs в коде | `arch-reviewed`, `implemented` |
| `/conclave:audit-code <paths>` | Запускает `code-auditor` — file:line аудит реализации против спеки и ADR | `arch-reviewed`, `implemented`, `audit-done` |

Stage-валидация дублирована: внутри тела команды + в PreToolUse хуке `hooks/state-guard.sh`, привязанном через плагинный `hooks/hooks.json` (belt-and-suspenders).

## Где живут артефакты

```
process/
├── CURRENT                    # одна строка — slug активного проекта
└── <slug>/
    ├── STATE.md               # YAML frontmatter + чек-лист + артефакты + лог
    ├── spec.md                # интервьюер → разработчик апрувит
    ├── spec-review.md         # spec-skeptic
    ├── adr/
    │   ├── 001-<topic>.md     # architect
    │   └── 002-<topic>.md
    ├── arch-review.md         # arch-reviewer
    └── post-review.md         # code-auditor
```

`process/CURRENT` — единственный «активный» проект на репозиторий. Параллельные проекты живут как отдельные подпапки `process/<slug>/`, но переключение `CURRENT` пока ручное.

Пример прогона лежит в `process/deepseek-client/` (HTTP-клиент к LLM-провайдеру: retry, rate limiting, streaming, наблюдаемость) — наполняется на Phase 6.

## Возобновляемость

Пайплайн полностью основан на файлах. Закройте сессию, откройте `claude` снова, выполните `/conclave:status` — оно прочтёт `process/CURRENT` и покажет stage, артефакты и `Pending human action`. Продолжайте с команды, разрешённой для текущей stage. Контекст основного агента не несёт состояния; всё в `STATE.md` и артефактах.

## Требования к окружению

- Любая дефолтная установка Claude Code (macOS / Linux).
- Не нужны ни API-ключи, ни переменные окружения сверх тех, что уже нужны самому Claude Code.
- Нужны `bash` и `jq` для хука `state-guard.sh`. `jq` опционален — при его отсутствии хук падает на grep-парсинг JSON (менее устойчиво, но работоспособно).
- Утилита `date` (стандартная coreutils / BSD).

## Ручное применение spec-review вердиктов (важно)

Это единственный HITL-переход, который сабагенты НЕ выполняют сами. Алгоритм после `/conclave:challenge-spec`:

1. Прочитайте `process/<slug>/spec-review.md`.
2. Для каждого пронумерованного objection пометьте у себя в голове или прямо в файле: **accepted / rejected / deferred**.
3. По всем accepted — отредактируйте `process/<slug>/spec.md` (добавьте FR/NFR, поправьте противоречия, нажмите конкретные числа).
4. **Вручную** откройте `process/<slug>/STATE.md` и:
   - Замените в frontmatter `stage: spec-reviewed` на `stage: verdicts-applied`.
   - Поставьте крестик в чек-листе: `- [x] verdicts-applied — <today>`.
   - Допишите в `## Log`: `- <today HH:MM> — verdicts applied (accepted: N, rejected: M, deferred: K)`.
5. Запустите `/conclave:architect`.

Альтернативный путь (вердикты признаны не требующими действий): оставьте `stage: spec-reviewed`, допишите в лог строку, содержащую подстроку `no-action-needed`, и запустите `/conclave:architect` — команда это распознает.

## Структура плагина

```
.claude-plugin/plugin.json   # манифест плагина (name, version, author)
agents/*.md                  # канонические системные промпты ролей
commands/*.md                # тела slash-команд (зовутся как /conclave:<name>)
skills/<name>/SKILL.md       # скиллы (шаблоны, рубрика ревью)
hooks/state-guard.sh         # PreToolUse валидация переходов
hooks/hooks.json             # привязка хука к Task tool
templates/*.template.md      # каноны артефактов (spec, ADR, reviews, ...)
```

Внутри agents/commands/skills все ссылки на шаблоны идут через `${CLAUDE_PLUGIN_ROOT}/templates/...` — Claude Code подставляет это автоматически в момент загрузки плагина.

## Что дальше

- `README.md` — полное описание процесса, ролей и открытых дизайн-решений (для ревьюера).
- `docs/decisions.md` — пост-морт и компромиссы.
- `agents/*.md`, `commands/*.md`, `skills/*/SKILL.md` — содержимое плагина.
- `hooks/state-guard.sh` + `hooks/hooks.json` — PreToolUse валидация переходов.
- `templates/*.template.md` — каноны артефактов.
