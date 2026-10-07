#!/usr/bin/env bash
# Приёмка после обслуживания бокса — окно D-087 (мандат brain 2026-10-07).
#
# Проверяет:
#   1. SHOW timezone — PostgreSQL должен быть Europe/Moscow
#   2. Пять доменов 200 — все домены отвечают 200, title свой у каждого
#   3. systemctl --failed пуст — нет упавших служб
#
# Аргументы: <локальный порт> <публичный URL через пробел>
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow глушит
# stderr клиента ssh целиком, потому что тот при отказе печатает хост и порт
# отдельными словами, а маскировка GitHub ловит только полное значение секрета
# (AGENTS.md, D-038).

set -euo pipefail

PORT="${1:?не задан порт}"
shift

# ── 1. SHOW timezone ──────────────────────────────────────────────────────────────────────
echo "=== 1. SHOW timezone ==="
TZ=$(sudo -u postgres psql -Atqc "SHOW timezone;" 2>/dev/null || true)
echo "timezone: $TZ"
if [ "$TZ" != "Europe/Moscow" ]; then
  echo "ОШИБКА: timezone не Europe/Moscow"
  exit 1
fi
echo "OK: timezone Europe/Moscow"

# ── 2. Локальный порт: служба поднялась после ребута ───────────────────────────────────
echo "=== 2. локальный порт ==="
TRIES=10
for i in $(seq 1 "$TRIES"); do
  if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null; then
    break
  fi
  if [ "$i" = "$TRIES" ]; then
    echo "ОШИБКА: служба не ответила по локальному порту за $TRIES попыток"
    exit 1
  fi
  sleep 5
done
echo "OK: служба отвечает локально"

# ── 3. Пять доменов 200 ──────────────────────────────────────────────────────────────────
echo "=== 3. публичные домены 200 ==="
n=0
for url in "$@"; do
  n=$((n + 1))
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)
  if [ "$code" != "200" ]; then
    echo "ОШИБКА: домен $n ответил $code, ожидалось 200"
    exit 1
  fi
  # Title читаем без grep -P (его может не быть): sed хватает.
  title=$(curl -sS --max-time 20 "$url" 2>/dev/null | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | head -n 1 || true)
  if [ -z "$title" ]; then
    echo "ОШИБКА: домен $n — не удалось прочитать title"
    exit 1
  fi
  echo "  домен $n: 200, title: $title"
done
echo "OK: все домены отвечают 200"

# ── 3. systemctl --failed пуст ────────────────────────────────────────────────────────────
echo "=== 4. systemctl --failed ==="
FAILED=$(systemctl --failed --no-legend 2>/dev/null || true)
if [ -n "$FAILED" ]; then
  echo "ОШИБКА: есть упавшие службы:"
  echo "$FAILED"
  exit 1
fi
echo "OK: systemctl --failed пуст"

echo "приёмка пройдена"
