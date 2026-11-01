#!/usr/bin/env bash
# remote-check-seo.sh — что поисковик видит с бокса: robots.txt, sitemap.xml,
# <meta name="robots"> главной и наличие favicon. Только чтение, бокс не меняется.
#
# Аргумент — список публичных базовых адресов через пробел. Это тот же секрет, что
# у смоука (DEPLOY_SMOKE_URL): список доменов не должен жить в двух местах, а
# значения vars печатаются в лог прогона (AGENTS.md, D-038).
#
# В лог идёт только то, что и так публично: статусы, имена директив robots.txt,
# число <loc> в карте сайта и хосты из неё (без путей), тип favicon. Тела страниц
# не печатаем — публичный лог не место для дампа HTML.
set -u

URLS="${1:-}"
if [ -z "$URLS" ]; then
  echo "нет адресов для проверки" >&2
  exit 2
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

code_of() { # url -> http-код (000, если не соединились)
  local url="$1" code
  code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 20 "$url" 2>/dev/null) || code=000
  printf '%s' "${code:-000}"
}

header_of() { # url header -> значение заголовка без имени
  curl -sS -o /dev/null -D - --max-time 20 "$1" 2>/dev/null \
    | tr -d '\r' \
    | awk -v want="$2" '{
        line = tolower($0)
        if (index(line, tolower(want) ":") == 1) { sub(/^[^:]*:[ ]*/, ""); print; exit }
      }'
}

for base in $URLS; do
  base="${base%/}"
  echo "== ${base}"

  # robots.txt
  rc=$(code_of "$base/robots.txt")
  if [ "$rc" = "200" ]; then
    dis=$(grep -ci '^[[:space:]]*disallow' "$tmp" || true)
    allow=$(grep -ci '^[[:space:]]*allow' "$tmp" || true)
    maps=$(grep -ci '^[[:space:]]*sitemap' "$tmp" || true)
    deny_all=$(grep -Ei '^[[:space:]]*disallow:[[:space:]]*/[[:space:]]*$' "$tmp" | wc -l | tr -d ' ')
    printf '· /robots.txt: %s, Disallow %s (из них «всё»: %s), Allow %s, Sitemap %s\n' \
      "$rc" "$dis" "$deny_all" "$allow" "$maps"
  else
    printf '· /robots.txt: %s\n' "$rc"
  fi

  # sitemap.xml
  rc=$(code_of "$base/sitemap.xml")
  if [ "$rc" = "200" ]; then
    locs=$(grep -o '<loc>' "$tmp" | wc -l | tr -d ' ')
    hosts=$(grep -o '<loc>[^<]*' "$tmp" | sed 's|<loc>||; s|^[a-z]*://||; s|/.*$||' | sort -u | tr '\n' ' ')
    printf '· /sitemap.xml: %s, <loc> %s, хосты: %s\n' "$rc" "$locs" "${hosts:-нет}"
  else
    printf '· /sitemap.xml: %s\n' "$rc"
  fi

  # Публичные страницы из sitemap.ts: по ним видно, что индексируется не только корень,
  # и не осталось ли noindex там, где страница обещана картой сайта.
  for page in / /nomera /pravila; do
    rc=$(code_of "$base$page")
    if [ "$rc" = "200" ]; then
      meta=$(grep -o -i '<meta[^>]*name="robots"[^>]*>' "$tmp" | head -n 3 | tr '\n' ' ')
      [ -n "$meta" ] || meta='нет'
      xrt=$(header_of "$base$page" 'X-Robots-Tag')
      [ -n "$xrt" ] || xrt='нет'
      printf '· %s: %s, meta robots: %s, X-Robots-Tag: %s\n' "$page" "$rc" "$meta" "$xrt"
    else
      printf '· %s: %s\n' "$page" "$rc"
    fi
  done

  # favicon: и корневой .ico (его ждёт Вебмастер), и наш svg
  rc=$(code_of "$base/favicon.ico")
  ctype=$(header_of "$base/favicon.ico" 'Content-Type')
  printf '· /favicon.ico: %s (%s)\n' "$rc" "${ctype:-без Content-Type}"
  rc=$(code_of "$base/icon.svg")
  printf '· /icon.svg: %s\n' "$rc"
done
