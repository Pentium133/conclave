# CLAUDE.md — точка входа для Claude Code

## Что это

Это пайплайн агентов Claude Code, который проводит разработчика через структурированное проектирование бэкенд-задачи: интервью → спека → адверсариальное ревью → ADR → ревью архитектуры → пост-ревью кода. Сам бэкенд здесь не пишется — артефакт репозитория это **конфигурация** (`.claude/`, шаблоны, хук) и порядок её использования.

## Quickstart

```bash
cd <repo>            # этот репозиторий
claude               # запустить сессию Claude Code в корне
/start <slug>        # пример: /start payment-service
/interview           # отвечаем на вопросы — на выходе process/<slug>/spec.md
# вручную: апрувим спеку — пишем `approve` и дату в §Approval файла spec.md
/challenge-spec      # адверсариальное ревью спеки
# вручную: применяем вердикты (см. ниже отдельный раздел)
/architect           # ADRs в process/<slug>/adr/
/review-arch         # независимое ревью архитектуры
/audit-code <paths>  # когда появится код — пост-ревью реализации
/status              # в любой момент: где мы, что дальше
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
                          │ /audit-code <paths> (subagent: code-auditor)
                          ▼
                     audit-done
```

Все переходы (кроме двух HITL — апрува спеки и установки `verdicts-applied`) выполняют сабагенты, обновляя `process/<slug>/STATE.md`.

## Slash-команды

| Команда | Что делает | Допустимая stage |
|---|---|---|
| `/start <slug>` | Создаёт `process/<slug>/`, копирует `STATE.md`, выставляет `stage: intake`, пишет `process/CURRENT` | (нет активного проекта) |
| `/status` | Read-only — показывает stage, чек-лист, артефакты, pending action | любая |
| `/interview` | Запускает сабагент `interviewer` для роста `spec.md` | `intake`, `interview` |
| `/challenge-spec` | Запускает `spec-skeptic` — ≥7 возражений + двупроходная самооценка | `spec-approved` |
| `/architect` | Запускает `architect` — пишет ADRs в `process/<slug>/adr/` | `verdicts-applied` (или `spec-reviewed` с лог-строкой `no-action-needed`) |
| `/review-arch` | Запускает `arch-reviewer` — независимое ревью; **не читает `spec-review.md`** | `arch-proposed` |
| `/audit-code <paths>` | Запускает `code-auditor` — file:line аудит реализации против спеки и ADR | `arch-reviewed`, `audit-done` |

Stage-валидация дублирована: внутри тела команды + в PreToolUse хуке `.claude/hooks/state-guard.sh` (belt-and-suspenders).

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

Пайплайн полностью основан на файлах. Закройте сессию, откройте `claude` снова, выполните `/status` — оно прочтёт `process/CURRENT` и покажет stage, артефакты и `Pending human action`. Продолжайте с команды, разрешённой для текущей stage. Контекст основного агента не несёт состояния; всё в `STATE.md` и артефактах.

## Требования к окружению

- Любая дефолтная установка Claude Code (macOS / Linux).
- Не нужны ни API-ключи, ни переменные окружения сверх тех, что уже нужны самому Claude Code.
- Нужны `bash` и `jq` для хука `state-guard.sh`. `jq` опционален — при его отсутствии хук падает на grep-парсинг JSON (менее устойчиво, но работоспособно).
- Утилита `date` (стандартная coreutils / BSD).

## Ручное применение spec-review вердиктов (важно)

Это единственный HITL-переход, который сабагенты НЕ выполняют сами. Алгоритм после `/challenge-spec`:

1. Прочитайте `process/<slug>/spec-review.md`.
2. Для каждого пронумерованного objection пометьте у себя в голове или прямо в файле: **accepted / rejected / deferred**.
3. По всем accepted — отредактируйте `process/<slug>/spec.md` (добавьте FR/NFR, поправьте противоречия, нажмите конкретные числа).
4. **Вручную** откройте `process/<slug>/STATE.md` и:
   - Замените в frontmatter `stage: spec-reviewed` на `stage: verdicts-applied`.
   - Поставьте крестик в чек-листе: `- [x] verdicts-applied — <today>`.
   - Допишите в `## Log`: `- <today HH:MM> — verdicts applied (accepted: N, rejected: M, deferred: K)`.
5. Запустите `/architect`.

Альтернативный путь (вердикты признаны не требующими действий): оставьте `stage: spec-reviewed`, допишите в лог строку, содержащую подстроку `no-action-needed`, и запустите `/architect` — команда это распознает.

## Что дальше

- `README.md` — полное описание процесса, ролей и открытых дизайн-решений (для ревьюера).
- `docs/decisions.md` — пост-морт и компромиссы.
- `.claude/agents/*.md` — канонические системные промпты ролей.
- `.claude/commands/*.md` — тела slash-команд.
- `.claude/hooks/state-guard.sh` — PreToolUse валидация переходов.
- `docs/templates/*.template.md` — каноны артефактов.
