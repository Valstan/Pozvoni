#!/usr/bin/env bash
# Обслуживание бокса — окно D-087 (мандат brain 2026-10-07).
#
# Объём (решено владельцем 07.10, сообщение brain 07.10):
#   1. Проверка systemd-detect-virt (контрольная, без неё ребут не делать)
#   2. Проверка/установка timezone PostgreSQL в Europe/Moscow
# Ребут — ОТДЕЛЬНЫМ шагом workflow (иначе обрыв SSH красит шаг в красный,
# хотя ребут и есть цель). Приёмка — скриптом remote-acceptance-d087.sh
# после подъёма бокса.
#
# Swap снят решением D-114 (тип бокса не позволяет) — не делаем.
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow глушит
# stderr клиента ssh целиком, потому что тот при отказе печатает хост и порт
# отдельными словами, а маскировка GitHub ловит только полное значение секрета
# (AGENTS.md, D-038).
#
# ⚠️ Ребут здесь НЕ делаем: обрыв SSH-сессии дал бы шагу ненулевой код,
# и прогон покраснел бы штатно. Ребут — отдельным шагом workflow, приёмка —
# отдельным шагом после подъёма.

set -euo pipefail

sudo -n true || { echo "нет passwordless sudo — обслуживание делать некому"; exit 1; }

# ── 1. Контрольная проверка: systemd-detect-virt ───────────────────────────────────────
# Перед ребубом убеждаемся, что бокс — не контейнер, где ребут невозможен или опасен.
echo "=== 1. systemd-detect-virt ==="
VIRT=$(systemd-detect-virt 2>/dev/null || true)
echo "тип виртуализации: $VIRT"
case "$VIRT" in
  none|vm|qemu|kvm|vmware|oracle|microsoft|xen|amazon|google)
    echo "OK: ребут возможен" ;;
  *)
    echo "ОСТАНОВКА: systemd-detect-virt вернул «$VIRT» — ребут на этом типе бокса не безопасен"
    exit 1 ;;
esac

# ── 2. Timezone PostgreSQL ───────────────────────────────────────────────────────────────
echo "=== 2. Timezone PostgreSQL ==="

# Читаем текущие настройки
CURRENT_TZ=$(sudo -u postgres psql -Atqc "SHOW timezone;" 2>/dev/null || true)
CURRENT_LOG_TZ=$(sudo -u postgres psql -Atqc "SHOW log_timezone;" 2>/dev/null || true)
echo "текущий timezone: $CURRENT_TZ"
echo "текущий log_timezone: $CURRENT_LOG_TZ"

# Проверяем, что уже Europe/Moscow (или Host, который тождествен Europe/Moscow)
if [ "$CURRENT_TZ" = "Europe/Moscow" ] || [ "$CURRENT_TZ" = "MSK" ]; then
  echo "OK: timezone уже Europe/Moscow"
elif [ "$CURRENT_TZ" = "Host" ]; then
  # Host тождествен Europe/Moscow по zdump (проверено в сессии 2026-09-11)
  # Но brain просит явно Europe/Moscow — переключаем
  echo "переключаю timezone с Host на Europe/Moscow..."
  sudo -u postgres psql -c "ALTER SYSTEM SET timezone = 'Europe/Moscow';"
  sudo -u postgres psql -c "ALTER SYSTEM SET log_timezone = 'Europe/Moscow';"
  sudo systemctl restart postgresql
  echo "OK: timezone переключён на Europe/Moscow"
else
  echo "ОСТАНОВКА: неожиданный timezone «$CURRENT_TZ» — требуется ручная проверка"
  exit 1
fi

# Проверяем результат
NEW_TZ=$(sudo -u postgres psql -Atqc "SHOW timezone;" 2>/dev/null || true)
echo "новый timezone: $NEW_TZ"
if [ "$NEW_TZ" != "Europe/Moscow" ]; then
  echo "ОСТАНОВКА: timezone не Europe/Moscow после переключения"
  exit 1
fi

echo "предребутное обслуживание пройдено — дальше ребут отдельным шагом workflow"
