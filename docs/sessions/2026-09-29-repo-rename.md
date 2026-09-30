> Вынесено из `docs/SESSION_HANDOFF.md` при раскладке 2026-09-30 (D-097). Актуальный индекс — там.

## Переименование репозитория в Pozvoni — сессия 2026-09-29 (ЗАВЕРШЕНО)

Решение владельца: основная тема — «ПОЗВОНИ» (`позвони.вмалмыже.рф`), такси — часть
портала со своим доменом-адресом (`такси.вмалмыже.рф`). Репозиторий переименован
`Valstan/TaksiMalmyzh` → **`Valstan/Pozvoni`** (GitHub кириллицу в имени не принимает).

**Выполнено 2026-09-29:**
1. Владелец переименовал репозиторий в Settings на GitHub.
2. PR #96 смержен squash (`d497ee1`), CI зелёный (`build` + `gitleaks`).
3. `origin` переключён на `https://github.com/Valstan/Pozvoni.git`, `main` подтянут.
4. Вложенный worktree `gallant-darwin-5f35b6` (пустая агентская сессия от 19.09) удалён.

**Ожидало brain — исполнено обеими сторонами 2026-09-29/30:** brain переименовал
`mailboxes/TaksiMalmyzh` → `mailboxes/Pozvoni` и `projects/TaksiMalmyzh.md` →
`projects/Pozvoni.md` у себя (письмо `2026-09-29-rename-accepted-read-as-pozvoni-since-today`);
второй PR с обновлением ссылок смержен 2026-09-30 (PR #105, squash `62eb190`, CI
зелёный): `AGENTS.md`/`start.md`/`mailbox/README.md`/`PROJECT_STATE.md`. Тем же PR —
строка-указатель `brain_find.py` в `AGENTS.md` (просьба brain из письма
`2026-09-29-strings-accepted-window-recorded-archives-closed`); ответ brain —
`mailbox/to-brain/2026-09-30-rename-links-done-brain-find-in-canon.md`.

**Локальный каталог** `D:\valstan\REPO\TaksiMalmyzh` переименовать в `Pozvoni` после
закрытия сессии (git не зависит от пути каталога).

