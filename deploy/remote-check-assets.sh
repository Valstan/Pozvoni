#!/usr/bin/env bash
# Проверка заголовков ассетов на проде (D-096 #250). Выполняется НА БОКСЕ, через ssh
# на stdin.
#
# Что проверяем (строка 02.10): `curl -I` по трём ассетам — `_next/static`, шрифт,
# `.mjs` — и смотрим Cache-Control и Content-Type. Плюс хвост на 16.10: хэш/версия
# в пути у всего, что immutable; тип у `.mjs`/`.pbf`.
#
# С бокса, а не с раннера GitHub: раннер до прод-домена не достучался (см.
# remote-smoke.sh) — проверка с раннера была бы вечно красной.
#
# ⚠️ Аргументы идут через ssh, а тот склеивает их в строку, которую удалённый
# shell разбирает заново (G30): публичных адресов может быть НЕСКОЛЬКО через пробел.
# Поэтому maplibre — первым аргументом (single token), а адреса — остальными, и их
# скрипт перебирает в цикле, как remote-smoke.sh.
#
# Аргументы: <версия maplibre> <публичный URL> [<публичный URL> ...]
# Диагностика — в stdout (вызывающий workflow глушит stderr ssh, AGENTS.md D-038).

set -euo pipefail

MAPLIBRE="${1:?не задана версия maplibre}"
shift

if [ "$#" -eq 0 ]; then
  echo "не задан публичный URL"
  exit 1
fi

# Печатаем только нужные заголовки: полный дамп в публичный лог не нужен, а коды
# ответов и ключевые заголовки — ровно то, что проверяет #250.
# HEAD к некоторым location nginx приходит пустым (проверено на .pbf) — тогда
# добираем заголовки через GET с дампом, тело в /dev/null.
show() {
  local label="$1" url="$2"
  echo "--- $label ---"
  local headers
  headers=$(curl -sSI --max-time 20 "$url" | grep -iE '^(HTTP/|cache-control|content-type|expires|etag):' || true)
  if [ -z "$headers" ]; then
    headers=$(curl -sS -D - -o /dev/null --max-time 20 "$url" | grep -iE '^(HTTP/|cache-control|content-type|expires|etag):' || true)
  fi
  echo "$headers"
}

for URL in "$@"; do
  echo "=== $URL ==="

  # 1. Чанк _next/static — берём из главной страницы, чтобы не закладывать хэш руками.
  chunk=$(curl -sS --max-time 20 "$URL/" | grep -oE '/_next/static/[^"]+\.(js|css)' | head -n 1)
  if [ -z "$chunk" ]; then
    echo "не нашёл ассет _next/static на главной"
    exit 1
  fi
  show "_next/static $chunk" "$URL$chunk"

  # 2. Воркер MapLibre (.mjs) — путь версионный, версия приходит аргументом.
  show "воркер .mjs" "$URL/map/maplibre/$MAPLIBRE/maplibre-gl-worker.mjs"

  # 3. Шрифт карты (.pbf) — единственные шрифтовые ассеты (веб-шрифтов нет, системные).
  # HEAD к большому файлу может прийти пустым — тогда добираем код и тип через GET.
  show "шрифт .pbf" "$URL/map/fonts/Noto Sans Regular/0-255.pbf"

  # 4. Иконка — представитель бинарных ассетов вне _next.
  show "icon.svg" "$URL/icon.svg"
done

echo "проверка заголовков ассетов завершена"
