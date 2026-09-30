> Вынесено из `docs/SESSION_HANDOFF.md` при раскладке 2026-09-30 (D-097). Актуальный индекс — там.

## Обслуживание бокса — сессия 2026-09-11

Первый прогон мандата brain 30.08 («вы дежурный по боксу»). Имена соседей, каталогов и
служб тут не пишутся (D-038). Всё — read-only
обзор скриптом через `ssh … bash -s < файл` (D-046), затем правки порциями. Что нашлось и
что с этим стало:

- **`apt-daily.timer` был disabled** (класс #234): утренний `apt-daily-upgrade` бегал по
  протухшему кэшу и «обновлять было нечего», а ждал 41 пакет. Включён; `upgrade` поставил
  230 пакетов (glibc, openssl, openssh, systemd, python, node 22.23.2, PostgreSQL 17.11);
  `dpkg --audit` и `apt list --upgradable` пусты; `autoremove --purge && clean` −183 МБ.
- ⚠️ **Грабли: `apt list --upgradable` до `apt update` — список по протухшему кэшу.**
  PostgreSQL в нём не было, а свежий `update` подтянул 17.11 из pgdg, и postinst
  перезапустил кластер на 30 секунд — при рамке мандата «PostgreSQL не останавливать».
  Жильцы пережили (`terminating connection` у нас и у одного соседа, процессы живы, сайты
  200). **В следующий раз: `apt-mark hold postgresql-17 postgresql-client-17` перед
  `upgrade`, PostgreSQL обновлять отдельным шагом и с ведома соседей.**
- **`logrotate` не был установлен вовсе** — `access.log` nginx рос с июня до 125 МБ.
  Поставлен, таймер включён, первый прогон ротировал. journald — drop-in в
  `journald.conf.d` (`SystemMaxUse=150M`).
- **Зона времени**: `/etc/localtime → Host`, debconf `Etc/UTC` (ружьё из письма brain
  04.09). `Host` тождествен `Europe/Moscow` по `zdump`; переключено на `Europe/Moscow`
  без смены оффсета. Файл `Host` не трогать: **`timezone = Host` и `log_timezone = Host` у
  PostgreSQL** — общий конфиг четырёх баз, решать всем вместе.
- **Своё**: релизов теперь три (`remote-activate.sh` держит три вместо пяти), `/tmp`
  вычищен, drop-in `<служба>.service.d/exit-status.conf` (`SuccessExitStatus=143`) — Next standalone на SIGTERM выходит 143, и без этого каждый
  рестарт при выкатке писался в журнал как «Failed». Именно эти строки (13 штук за 30.08)
  и были «аварией» в вопросе brain. Служба перезапущена под новый `node`.
- **Чужое, не тронуто** (в письме brain таблицей): у одного соседа два git-checkout'а на
  боксе (2,3 ГБ) плюс 5 релизов, у других 5 и 3; общий pnpm-store 987 МБ, `prune`
  удалил 0 — всё живое. Соседи держат старый `node`/libc до своего рестарта.
- **Диск** 7,0 → 6,8 ГБ из 9,8. **За владельцем**: ребут (закроет glibc/node у соседей,
  срочности нет), swap-файл, `timezone = Host` у PostgreSQL.
- Приёмка #104: пять доменов с бокса, `<title>` свой у каждого.

