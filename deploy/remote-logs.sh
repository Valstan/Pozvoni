#!/usr/bin/env bash
# Чтение журнала службы на боксе (инцидент 2026-10-08: прод лежал, рук на боксе
# у проекта не было — только через чужой доступ).
#
# Что делает: состояние юнита + хвост журнала службы. Выполняется НА СЕРВЕРЕ,
# через ssh на stdin — как остальные удалённые скрипты (мандат D-046).
#
# Recon-безопасность (AGENTS.md, D-038: репозиторий и логи прогонов публичны).
# Журнал systemd содержит имя бокса, а сообщения — имя службы, пути и адреса.
# Здесь всё это вычищается потоковым sed ДО печати: имя службы — значением
# аргумента (в лог попадает только замена), имя бокса — первое поле строки
# журнала, IPv4 и домашние пути — регулярками.
#
# Аргументы: <имя службы> <строк журнала>
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow глушит
# stderr клиента ssh целиком (маскировка GitHub ловит только полное значение
# секрета, а ssh при отказе печатает хост и порт отдельными словами).

set -euo pipefail

SERVICE="${1:?не задана служба}"
LINES="${2:-100}"

case "$LINES" in
  ''|*[!0-9]*) echo "число строк — только цифры"; exit 1 ;;
esac
if [ "$LINES" -gt 500 ]; then
  echo "больше 500 строк за раз не отдаём"
  exit 1
fi

# Редакция потока: имя службы, имя бокса (первое поле после метки времени),
# IPv4, домашние каталоги. Порядок важен: сначала служба (её имя может
# содержать точки, как у адреса), потом остальное.
redact() {
  sed -E \
    -e "s/${SERVICE}/<служба>/g" \
    -e 's/^([A-Z][a-z]{2} +[0-9]+ [0-9:]+) [^ ]+ /\1 <бокс> /' \
    -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g' \
    -e 's#/home/[^ :]*#<дом>#g'
}

echo "=== состояние ==="
echo "active: $(systemctl is-active "$SERVICE" 2>/dev/null || echo неизвестно)"
echo "failed: $(systemctl is-failed "$SERVICE" 2>/dev/null || echo неизвестно)"
systemctl show "$SERVICE" -p ActiveState,SubState,Result,ExecMainStatus,NRestarts,ActiveEnterTimestamp 2>/dev/null || true

echo "=== журнал службы ($LINES строк) ==="
journalctl -u "$SERVICE" -n "$LINES" --no-pager 2>/dev/null | redact || echo "журнал недоступен"

# События systemd по юниту (старты/остановки/коды выхода) живут НЕ в `-u`,
# а в системном журнале — без этого куска рестарт-crashloop не виден.
echo "=== события юнита в системном журнале ==="
journalctl --no-pager -n 600 2>/dev/null | grep -F "$SERVICE" | tail -80 | redact || echo "событий нет"

echo "=== journald ==="
systemctl is-active systemd-journald 2>/dev/null || echo "journald не active"
journalctl --disk-usage 2>/dev/null || true
