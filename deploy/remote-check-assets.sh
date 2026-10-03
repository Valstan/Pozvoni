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
# Аргументы: <публичный URL> [<версия maplibre>]
# Диагностика — в stdout (вызывающий workflow глушит stderr ssh, AGENTS.md D-038).

set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "не задан публичный URL"
  exit 1
fi

URL="${1:?не задан публичный URL}"
MAPLIBRE="${2:-6.6.0}"

# Печатаем только нужные заголовки: полный дамп в публичный лог не нужен, а коды
# ответов и ключевые заголовки — ровно то, что проверяет #250.
show() {
  local label="$1" path="$2"
  echo "--- $label ($path) ---"
  curl -sSI --max-time 20 "$URL$path" \
    | grep -iE '^(HTTP/|cache-control|content-type|expires|etag):' || true
}

# 1. Чанк _next/static — берём из главной страницы, чтобы не закладывать в хэш руками.
chunk=$(curl -sS --max-time 20 "$URL/" | grep -oE '/_next/static/[^"]+\.(js|css)' | head -n 1)
if [ -z "$chunk" ]; then
  echo "не нашёл ассет _next/static на главной"
  exit 1
fi
show "_next/static" "$chunk"

# 2. Воркер MapLibre (.mjs) — путь версионный, версия приходит аргументом.
show "воркер .mjs" "/map/maplibre/$MAPLIBRE/maplibre-gl-worker.mjs"

# 3. Шрифт карты (.pbf) — единственные шрифтовые ассеты (веб-шрифтов нет, системные).
show "шрифт .pbf" "/map/fonts/Noto Sans Regular/0-255.pbf"

# 4. Иконка — представитель бинарных ассетов вне _next.
show "icon.svg" "/icon.svg"

echo "проверка заголовков ассетов завершена"
