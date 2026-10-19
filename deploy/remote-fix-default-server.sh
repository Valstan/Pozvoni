#!/usr/bin/env bash
# Согласованная замена владельца default_server на :80 (письмо brain 2026-10-19).
#
# Порядок обязателен и не переставляется: сосед (Сабантуй) снимает свой
# `default_server` первым, затем мы ставим свой catch-all с `return 444`.
# Два `default_server` на одном `listen` — ошибка конфигурации: `nginx -t`
# краснеет, а за ним любой рестарт nginx. Поэтому режим apply сначала
# убеждается, что чужого `default_server` на :80 больше нет, и до этого
# момента не трогает конфиг вообще.
#
# Режимы:
#   check — только чтение: состояние, проба чужого Host и наших имён;
#   apply — поставить наш catch-all (идемпотентно).
#
# Коды возврата apply: 0 — стоит и проверено (включая «уже стояло»);
# 3 — ждём соседа, ничего не менялось; 1 — ошибка или откат.
# check возвращает 0, если проверка выполнилась и nginx здоров; 1 — если
# `nginx -t` красный или наши имена не отвечают 200.
#
# Аргументы: <check|apply> [<публичный URL> ...]
# Домены нужны, чтобы найти НАШУ секцию среди секций соседей и проверить наши
# имена. В лог они не печатаются — только номера, как в смоуке.
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow
# глушит stderr ssh целиком (клиент печатает туда хост и порт отдельными
# словами, а маскировка GitHub ловит только полное значение секрета;
# AGENTS.md, «recon-поверхность»). Имена чужих файлов и сервисов не
# печатаются вовсе — состав жильцов бокса в публичный лог не идёт.

set -euo pipefail

MODE="${1:-check}"
shift || true

case "$MODE" in
  check|apply) ;;
  *) echo "неизвестный режим: $MODE (ожидалось check|apply)"; exit 2 ;;
esac

if [ "$#" -eq 0 ]; then
  echo "не переданы публичные URL — нечем найти нашу секцию и проверить имена"
  exit 2
fi

sudo -n true || { echo "нет passwordless sudo — без него правку не сделать"; exit 1; }

host_of() {
  local u="$1"
  u="${u#*://}"
  u="${u%%/*}"
  u="${u%%:*}"
  printf '%s\n' "$u"
}

# Браузер шлёт IDN в punycode, и реестр хранит punycode (DOMAINS.md §3), но
# секрет с URL мог быть набран и кириллицей. Поэтому домен ищется в обеих
# формах; python3 на Ubuntu есть штатно, без него остаётся форма как есть.
to_puny() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import sys; print(sys.argv[1].encode("idna").decode("ascii"))' "$1" 2>/dev/null || true
}
to_unicode() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import sys; print(sys.argv[1].encode("ascii").decode("idna"))' "$1" 2>/dev/null || true
}
host_candidates() {
  local h="$1" alt
  printf '%s\n' "$h"
  alt=$(to_puny "$h")
  if [ -n "$alt" ] && [ "$alt" != "$h" ]; then printf '%s\n' "$alt"; fi
  alt=$(to_unicode "$h")
  if [ -n "$alt" ] && [ "$alt" != "$h" ]; then printf '%s\n' "$alt"; fi
}

# ── Наша секция: файл conf.d, где в server_name есть хотя бы один наш домен ──────────
# OUR_HOSTS хранит ту форму имени, которая нашлась в конфиге, — ею и пробуем.
OUR_HOSTS=()
CONF=""
n=0
for u in "$@"; do
  n=$((n + 1))
  h=$(host_of "$u")
  if [ -z "$h" ]; then
    echo "из URL № $n не удалось выделить имя"
    exit 2
  fi

  matched=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    mapfile -t FOUND < <(sudo grep -lF -- "$cand" /etc/nginx/conf.d/*.conf 2>/dev/null || true)
    if [ "${#FOUND[@]}" -gt 1 ]; then
      echo "домен № $n нашёлся в нескольких файлах nginx — не могу выбрать нашу секцию"
      exit 1
    fi
    if [ "${#FOUND[@]}" -eq 1 ]; then
      if [ -n "$CONF" ] && [ "$CONF" != "${FOUND[0]}" ]; then
        echo "наши домены разошлись по разным файлам nginx — не могу выбрать нашу секцию"
        exit 1
      fi
      CONF="${FOUND[0]}"
      matched="$cand"
      break
    fi
  done < <(host_candidates "$h")

  if [ -z "$matched" ]; then
    echo "домен № $n не нашёлся в конфиге nginx"
    exit 1
  fi
  OUR_HOSTS+=("$matched")
done
if [ -z "$CONF" ]; then
  echo "не нашёл нашу секцию nginx по нашим доменам"
  exit 1
fi

# ── Кто держит default_server: любой чужой файл (наш исключён) ───────────────────────
# Бокс слушает только :80 (внешние 80/443 терминирует прокси хостера), поэтому
# `listen … default_server` в чужом файле — это и есть занятый :80.
mapfile -t FOREIGN < <(
  sudo grep -rlE '^[[:space:]]*listen[^;]*default_server' /etc/nginx 2>/dev/null \
    | grep -vxF "$CONF" | grep -vE '\.bak' || true
)

# ── Наш блок: маркер встречается 0 (нет) или 2 (открыт и закрыт) ─────────────────────
MARKERS=$(sudo grep -cF 'pozvoni-default-server-444' "$CONF" 2>/dev/null) || MARKERS=0
if [ "$MARKERS" = "1" ]; then
  echo "маркер нашего блока встречается один раз — прошлая запись оборвана; нужен человек"
  exit 1
fi

# ── Пробы ────────────────────────────────────────────────────────────────────────────
# Чужой Host: до замены его получает default-сервер соседа (200), после `return 444`
# соединение закрывается без ответа (curl 52/56, http_code 000).
foreign_rc=0
foreign_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
  -H 'Host: probe-unknown.invalid' http://127.0.0.1/ 2>/dev/null) || foreign_rc=$?

our_total=0
our_ok=0
for h in "${OUR_HOSTS[@]}"; do
  our_total=$((our_total + 1))
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Host: $h" http://127.0.0.1/ 2>/dev/null) || code="000"
  if [ "$code" = "200" ]; then our_ok=$((our_ok + 1)); fi
done

# ── apply: предохранитель порядка ────────────────────────────────────────────────────
if [ "$MODE" = "apply" ] && [ "$MARKERS" = "0" ] && [ "${#FOREIGN[@]}" -gt 0 ]; then
  echo "ждём соседа: default_server на :80 ещё не наш; порядок обязателен — ничего не меняю"
  echo "RESULT: WAITING_NEIGHBOUR"
  exit 3
fi
if [ "$MODE" = "apply" ] && [ "$MARKERS" = "2" ] && [ "${#FOREIGN[@]}" -gt 0 ]; then
  echo "дубль default_server: наш блок уже стоит, и чужой тоже — нужен человек, ничего не меняю"
  echo "RESULT: BROKEN"
  exit 1
fi

# ── apply: внести блок (идемпотентно) ────────────────────────────────────────────────
CHANGED=no
BAK=""
if [ "$MODE" = "apply" ] && [ "$MARKERS" = "0" ]; then
  BAK="$CONF.bak-$(date +%Y%m%d-%H%M%S)-444"
  sudo cp -a "$CONF" "$BAK"
  echo "· бэкап секции сделан рядом с файлом"

  BLOCK_TMP=$(mktemp)
  cat > "$BLOCK_TMP" <<'BLOCK'

# >>> pozvoni-default-server-444 — согласованная замена владельца default_server
# (письмо brain 2026-10-19; ставится workflow fix-default-server, режим apply)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
# <<< pozvoni-default-server-444
BLOCK

  if ! sudo tee -a "$CONF" < "$BLOCK_TMP" >/dev/null; then
    rm -f "$BLOCK_TMP"
    echo "не удалось дописать секцию — восстанавливаю из бэкапа"
    sudo cp -a "$BAK" "$CONF"
    echo "RESULT: FAILED"
    exit 1
  fi
  rm -f "$BLOCK_TMP"
  MARKERS=2
  CHANGED=yes

  if ! sudo nginx -t >/dev/null 2>&1; then
    echo "nginx -t не пройден — восстанавливаю секцию из бэкапа"
    sudo cp -a "$BAK" "$CONF"
    sudo nginx -t >/dev/null 2>&1 || true
    echo "RESULT: FAILED (откатились, конфиг не перезагружен)"
    exit 1
  fi
  if ! sudo systemctl reload nginx; then
    echo "reload не прошёл — восстанавливаю секцию из бэкапа"
    sudo cp -a "$BAK" "$CONF"
    sudo systemctl reload nginx || true
    echo "RESULT: FAILED (откатились)"
    exit 1
  fi
  echo "· блок внесён, nginx перезагружен"
fi

# ── Итоговое состояние (обе моды) ────────────────────────────────────────────────────
nginx_t_ok=no
if sudo nginx -t >/dev/null 2>&1; then nginx_t_ok=yes; fi

nginx_t_out=""
if ! nginx_t_out=$(sudo nginx -T 2>/dev/null); then nginx_t_out=""; fi
# Авторитетный подсчёт: default_server-строки именно в НАШЕЙ секции по `nginx -T`.
ours_default=$(printf '%s\n' "$nginx_t_out" | awk -v conf="$CONF" '
  /^# configuration file / { inside = index($0, conf) > 0; next }
  inside && /^[[:space:]]*listen[^;]*default_server/ { n++ }
  END { printf "%d", n + 0 }')

foreign_closed=no
case "$foreign_rc" in
  52|56) foreign_closed=yes ;;
esac

echo "· наша секция: $CONF"
if [ "$MARKERS" = "2" ]; then
  echo "· наш catch-all 444: стоит"
else
  echo "· наш catch-all 444: не стоит"
fi
if [ "${#FOREIGN[@]}" -gt 0 ]; then
  echo "· чужой default_server на :80: есть"
else
  echo "· чужой default_server на :80: нет"
fi
if [ "$nginx_t_ok" = "yes" ]; then
  echo "· nginx -t: ок"
else
  echo "· nginx -t: КРАСНЫЙ"
fi
echo "· default_server в нашей секции: $ours_default из 2 listen-строк"
if [ "$foreign_closed" = "yes" ]; then
  echo "· чужой Host: соединение закрыто без ответа (curl rc $foreign_rc) — return 444 работает"
else
  echo "· чужой Host: http-код $foreign_code (curl rc $foreign_rc) — 444 не срабатывает"
fi
echo "· наши имена: $our_ok из $our_total — 200"

if [ "$nginx_t_ok" = "yes" ] && [ "$ours_default" = "2" ] \
   && [ "$foreign_closed" = "yes" ] && [ "$our_ok" -eq "$our_total" ]; then
  echo "RESULT: DONE"
  exit 0
fi

# Не всё хорошо. Если это мы только что внесли блок — откатываемся.
if [ "$MODE" = "apply" ] && [ "$CHANGED" = "yes" ]; then
  echo "проверка после правки не прошла — откатываю секцию"
  sudo cp -a "$BAK" "$CONF"
  if sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx; then
    echo "· откат выполнен, nginx с прежней секцией"
  else
    echo "· ОТКАТ НЕ ПЕРЕЗАГРУЗИЛСЯ — нужен человек"
  fi
  echo "RESULT: FAILED"
  exit 1
fi

if [ "$MARKERS" = "0" ] && [ "$nginx_t_ok" = "yes" ] && [ "$our_ok" -eq "$our_total" ]; then
  # Блока нет — это нормальное состояние «до замены»; отличаем «сосед снял» от
  # «сосед ещё держит», чтобы apply запускали по второму, а не наугад.
  if [ "${#FOREIGN[@]}" -gt 0 ]; then
    echo "RESULT: WAITING_NEIGHBOUR"
  else
    echo "RESULT: READY_TO_APPLY"
  fi
  exit 0
fi

echo "RESULT: BROKEN (nginx -t красный или наши имена не 200)"
exit 1
