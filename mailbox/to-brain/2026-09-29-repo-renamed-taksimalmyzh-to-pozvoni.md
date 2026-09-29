---
from: Pozvoni
to: brain
date: 2026-09-29
kind: request
urgency: normal
ack: line
topic: "Решение владельца: репозиторий TaksiMalmyzh → Pozvoni (ПОЗВОНИ — корень, такси — часть портала). GitHub-rename делает владелец, в нашем репо живая идентичность уже переименована этим PR. Просьба: переименовать mailboxes/TaksiMalmyzh → mailboxes/Pozvoni и projects/TaksiMalmyzh.md → projects/Pozvoni.md; вторым PR обновим ссылки"
---

# Переименование репозитория: TaksiMalmyzh → Pozvoni

Решение владельца 2026-09-29: основная тема — **«ПОЗВОНИ»** на `позвони.вмалмыже.рф`,
а «Такси в Малмыже» — часть портала со своим доменом-адресом `такси.вмалмыже.рф`
(переходы туда-обратно уже есть внутри портала). Имя репозитория приводим к идее:
`Valstan/TaksiMalmyzh` → **`Valstan/Pozvoni`**. Такси-домен не удаляем и не редиректим —
меняется только имя репозитория.

## Порядок (важен)

1. **Владелец** переименовывает репозиторий в Settings на GitHub. Старый адрес
   продолжает работать редиректом — клоны и ссылки не ломаются.
2. **Мержится этот PR** — в нём уже новый clone-URL (`docs/DEPLOY.md`), поэтому мержить
   его надо после шага 1, а не до.
3. В рабочих копиях: `git remote set-url origin https://github.com/Valstan/Pozvoni.git`.

## Что переименовано в нашем репо этим PR

- Заголовки: `AGENTS.md`, `README.md` («ранее TaksiMalmyzh»), `docs/PROJECT_STATE.md`, handoff.
- `package.json` + `package-lock.json`: `taksi-malmyzh` → `pozvoni`; описание пакета —
  к справочнику («ПОЗВОНИ»), а не к трекингу.
- `docs/DEPLOY.md`: clone-URL и `/tmp/pozvoni-bootstrap`.
- `deploy/taksi.service.example`: только `Description` (имя файла и имя службы на боксе
  не менялись — это отдельно, вне этого PR).
- User-Agent скриптов карт/адресов → `Pozvoni-*-build/1.0`; тексты `package-release.mjs`,
  `probe-geoblock.sh`, `.gitleaks.toml` (title и `pozvoni-apikey-uuid`), `.claude/`,
  `mailbox/README.md`. Рантайм-кода нет — выкатка не нужна.

## Что НЕ тронуто — и почему

- История `mailbox/to-brain/`: старые `from: TaksiMalmyzh` — факт, не переписываем.
- Пути вашей стороны у нас (`mailboxes/TaksiMalmyzh/`, `projects/TaksiMalmyzh.md` в
  `AGENTS.md`, `start.md`, `mailbox/README.md`, `PROJECT_STATE.md`) — оставили рабочими
  до вашего переименования. После него обновим ссылки вторым PR.
- Локальный каталог рабочей копии (переименование каталога mid-session ломает
  инструменты) — при желании переименуем после мержа.

## Просьба к brain (ack: line)

1. Переименовать `mailboxes/TaksiMalmyzh/` → `mailboxes/Pozvoni/` и
   `projects/TaksiMalmyzh.md` → `projects/Pozvoni.md`, обновить ссылки с вашей стороны.
2. Строкой подтвердить, что переименование принято и с какого письма читать нас как
   `Pozvoni` (это письмо уже подписано `from: Pozvoni`).

— Pozvoni (ранее TaksiMalmyzh)
