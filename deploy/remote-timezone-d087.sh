#!/usr/bin/env bash
# Таймзона PostgreSQL — окно D-087 (мандат brain 2026-10-07).
#
# Объём: `timezone` и `log_timezone` в `Europe/Moscow`.
# Метод — `ALTER SYSTEM` + `pg_reload_conf()`: оба параметра SIGHUP,
# рестарт кластера НЕ нужен, соединения не рвутся, даунтайма ноль
# (урок 11.09: apt перезапустил PostgreSQL на 30 секунд — здесь так не будет).
# Значение семантически нулевое (`Host` тождествен `Europe/Moscow` по `zdump`,
# сессия 2026-09-11), но brain просит явно — делаем.
#
# Ребут бокса в этом окне — через панель хостера (бокс — openvz, ребут
# изнутри небезопасен: maintenance-d087 останавливается на detect-virt).
# Этот скрипт ребута не делает и от него не зависит — идёт что до, что после;
# значение живёт в `postgresql.auto.conf` и переживает перезапуск.
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow глушит
# stderr клиента ssh целиком, потому что тот при отказе печатает хост и порт
# отдельными словами, а маскировка GitHub ловит только полное значение секрета
# (AGENTS.md, D-038).

set -euo pipefail

sudo -n true || { echo "нет passwordless sudo — править конфиг некому"; exit 1; }

command -v psql >/dev/null 2>&1 || { echo "ОСТАНОВКА: psql на боксе нет"; exit 1; }

# Каждый вызов — новая сессия: так проверка ниже видит именно то, что получат
# новые подключения после reload, а не установки текущей сессии.
q() { sudo -u postgres psql -Atqc "$1" 2>/dev/null || true; }

echo "=== 1. что сейчас ==="
CUR_TZ=$(q "SHOW timezone;")
CUR_LOG_TZ=$(q "SHOW log_timezone;")
test -n "$CUR_TZ" || { echo "ОСТАНОВКА: SHOW timezone пусто — postgres недоступен?"; exit 1; }
echo "timezone: $CUR_TZ"
echo "log_timezone: $CUR_LOG_TZ"

if [ "$CUR_TZ" = "Europe/Moscow" ] && [ "$CUR_LOG_TZ" = "Europe/Moscow" ]; then
  echo "OK: уже Europe/Moscow — менять нечего"
  exit 0
fi

case "$CUR_TZ" in
  Host|MSK|Europe/Moscow) ;;
  *) echo "ОСТАНОВКА: неожиданный timezone «$CUR_TZ» — требуется ручная проверка"; exit 1 ;;
esac

echo "=== 2. ALTER SYSTEM + reload (без рестарта) ==="
q "ALTER SYSTEM SET timezone = 'Europe/Moscow';"
q "ALTER SYSTEM SET log_timezone = 'Europe/Moscow';"
q "SELECT pg_reload_conf();"

echo "=== 3. проверка новой сессией ==="
NEW_TZ=$(q "SHOW timezone;")
NEW_LOG_TZ=$(q "SHOW log_timezone;")
echo "timezone: $NEW_TZ"
echo "log_timezone: $NEW_LOG_TZ"
test "$NEW_TZ" = "Europe/Moscow" || { echo "ОСТАНОВКА: timezone не применился"; exit 1; }
test "$NEW_LOG_TZ" = "Europe/Moscow" || { echo "ОСТАНОВКА: log_timezone не применился"; exit 1; }
echo "таймзона применена без рестарта"
