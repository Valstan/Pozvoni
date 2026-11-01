#!/usr/bin/env bash
# Чужой Host рвётся 444 — своим regex-catch-all, не отбирая default_server.
#
# :80 на боксе общий. `default_server` там держит конфиг соседа, а второй
# `default_server` на том же listen валит `nginx -t`, за ним — любой рестарт.
# Поэтому прежняя версия инструмента ждала, пока сосед снимет свой (письмо
# brain 2026-10-19, вариант А). Ждать не нужно: nginx проверяет регулярные
# `server_name` ДО перехода к default-серверу. Блок `server_name ~^;` в НАШЕЙ
# секции ловит любой Host, не совпавший ни с одним точным или масковым именем,
# и при этом не меняет ни чужой конфиг, ни владельца default_server.
#
# Проверено на nginx 1.28 (та же ветка, что на боксе): свои точные имена и
# явные имена соседа по-прежнему 200, неизвестный Host — соединение закрыто.
# Версия на боксе может отличаться, поэтому apply проверяет результат на живом
# конфиге и откатывается, если regex не сработал.
#
# Риск, который проверяется ДО правки: если сайт соседа обслуживается его
# catch-all'ом (`server_name _` и в блоке есть root/proxy_pass), а явных имён
# нет ни в одном чужом блоке, наш regex перехватит и домены соседа. Тогда apply
# ничего не меняет (BLOCKED_NEIGHBOUR): соседу нужно добавить явное имя в свой
# блок.
#
# Режимы:
#   check — только чтение: состояние, факты о чужих default-блоках (счётчики,
#           без имён и путей), проба чужого Host и наших имён;
#   apply — идемпотентная вставка нашего catch-all с бэкапом, `nginx -t` до
#           reload, приёмка на живом конфиге и откат при неуспехе.
#
# Коды возврата: 0 — проверено или стоит; 3 — мешает сосед, ничего не менялось;
# 1 — ошибка, откат или нужен человек.
#
# Аргументы: <check|apply> [<публичный URL> ...]
# Домены нужны, чтобы найти НАШУ секцию среди секций соседей и проверить наши
# имена. В лог они не печатаются.
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

# ── Чужие файлы, которые держат default_server (наш исключён) ────────────────────────
# Бокс слушает только :80 (внешние 80/443 терминирует прокси хостера), поэтому
# `listen … default_server` в чужом файле — это и есть занятый :80.
mapfile -t FOREIGN < <(
  sudo grep -rlE '^[[:space:]]*listen[^;]*default_server' /etc/nginx 2>/dev/null \
    | grep -vxF "$CONF" | grep -vE '\.bak' || true
)

# ── Наш блок: маркер встречается 0 (нет) или 2 (открыт и закрыт) ─────────────────────
MARKERS=$(sudo grep -cF 'pozvoni-catchall-444' "$CONF" 2>/dev/null) || MARKERS=0
OLD=$(sudo grep -cF 'pozvoni-default-server-444' "$CONF" 2>/dev/null) || OLD=0
if [ "$OLD" != "0" ]; then
  echo "в нашей секции остался старый catch-all с default_server — нужен человек"
  echo "RESULT: HUMAN"
  exit 1
fi
if [ "$MARKERS" = "1" ]; then
  echo "маркер нашего блока встречается один раз — прошлая запись оборвана; нужен человек"
  echo "RESULT: HUMAN"
  exit 1
fi

# ── Разбор чужих секций: счётчики, без имён и путей ──────────────────────────────────
# Одна строка на файл:
#   FILE blocks=… default_blocks=… default_explicit=… default_content=…
#        explicit_blocks=… default_lines=…
# explicit_blocks — блоки хоть с одним явным server_name (не `_`): если они есть,
# у соседа есть своё имя, и наш regex не забирает его домены.
facts_of() {
  sudo awk '
    function flush() {
      blocks++
      if (hasdef) {
        dblocks++
        dlines += deflines
        if (hascontent) dcontent++
        if (nnames > 0) dexplicit++
      }
      if (nnames > 0) explicit_blocks++
      hasdef = 0; hascontent = 0; nnames = 0; deflines = 0
      split("", names)
    }
    {
      line = $0
      sub(/#.*/, "", line)
      if (!inblk && line ~ /^[[:space:]]*server[[:space:]]*\{/) {
        inblk = 1; depth = 0; hasdef = 0; hascontent = 0; nnames = 0; deflines = 0
        split("", names)
      }
      if (inblk) {
        tmp = line
        opens = gsub(/\{/, "{", tmp)
        closes = gsub(/\}/, "}", tmp)
        depth += opens - closes
        if (line ~ /^[[:space:]]*listen[^;]*default_server/) { hasdef = 1; deflines++ }
        if (line ~ /^[[:space:]]*server_name[[:space:]]/) {
          s = line
          sub(/^[[:space:]]*server_name[[:space:]]+/, "", s)
          sub(/;.*/, "", s)
          k = split(s, a, /[[:space:]]+/)
          for (i = 1; i <= k; i++) {
            if (a[i] != "" && a[i] != "_" && !(a[i] in names)) {
              names[a[i]] = 1
              nnames++
            }
          }
        }
        if (line ~ /^[[:space:]]*(root|alias|proxy_pass|try_files)[[:space:]]/) hascontent = 1
        if (depth <= 0) { flush(); inblk = 0 }
      }
    }
    END {
      if (inblk) flush()
      printf "FILE blocks=%d default_blocks=%d default_explicit=%d default_content=%d explicit_blocks=%d default_lines=%d\n", \
        blocks, dblocks, dexplicit, dcontent, explicit_blocks, dlines
    }
  ' "$1"
}

all_names_of() {
  sudo awk '
    {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /^[[:space:]]*server_name[[:space:]]/) {
        s = line
        sub(/^[[:space:]]*server_name[[:space:]]+/, "", s)
        sub(/;.*/, "", s)
        k = split(s, a, /[[:space:]]+/)
        for (i = 1; i <= k; i++) if (a[i] != "" && a[i] != "_") print a[i]
      }
    }
  ' "$1"
}

# Только имена, которые можно послать в Host как есть. Шаблоны, регулярки и
# юникод не пробуем: они либо заведомо не совпадут, либо не пройдут curl.
is_probe_name() {
  case "$1" in
    ""|_|~*|\$*|\**) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
}

DEFAULT_BLOCKS=0
DEFAULT_EXPLICIT=0
DEFAULT_CONTENT=0
EXPLICIT_BLOCKS=0
INCLUDE=no
UNSAFE=no
PARSER_BAD=no
NB_NAMES=()
declare -A NB_SEEN=()
UNPROBEABLE=0

for f in "${FOREIGN[@]}"; do
  if sudo grep -qE '^[[:space:]]*include[[:space:]]' "$f"; then INCLUDE=yes; fi

  # Сверка парсера с простым счётом: сумма listen-строк внутри найденных
  # default-блоков должна совпасть с числом таких строк в файле. Не совпало —
  # разбор сломался (фигурная скобка в кавычках и т.п.), такую правку не делаем.
  listen_lines=$(sudo grep -cE '^[[:space:]]*listen[^;]*default_server' "$f" 2>/dev/null || true)
  [ -n "$listen_lines" ] || listen_lines=0

  facts=$(facts_of "$f")
  dblocks=$(printf '%s\n' "$facts" | sed -n 's/.*default_blocks=\([0-9]*\).*/\1/p')
  dexpl=$(printf '%s\n' "$facts" | sed -n 's/.*default_explicit=\([0-9]*\).*/\1/p')
  dcont=$(printf '%s\n' "$facts" | sed -n 's/.*default_content=\([0-9]*\).*/\1/p')
  expl=$(printf '%s\n' "$facts" | sed -n 's/.*explicit_blocks=\([0-9]*\).*/\1/p')
  dlines=$(printf '%s\n' "$facts" | sed -n 's/.*default_lines=\([0-9]*\).*/\1/p')
  [ -n "$dblocks" ] || dblocks=0
  [ -n "$dexpl" ] || dexpl=0
  [ -n "$dcont" ] || dcont=0
  [ -n "$expl" ] || expl=0
  [ -n "$dlines" ] || dlines=0

  DEFAULT_BLOCKS=$((DEFAULT_BLOCKS + dblocks))
  DEFAULT_EXPLICIT=$((DEFAULT_EXPLICIT + dexpl))
  DEFAULT_CONTENT=$((DEFAULT_CONTENT + dcont))
  EXPLICIT_BLOCKS=$((EXPLICIT_BLOCKS + expl))

  if [ "$dlines" != "$listen_lines" ]; then PARSER_BAD=yes; fi

  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    if ! is_probe_name "$nm"; then
      UNPROBEABLE=$((UNPROBEABLE + 1))
      continue
    fi
    if [ -z "${NB_SEEN[$nm]:-}" ]; then
      NB_SEEN[$nm]=1
      NB_NAMES+=("$nm")
    fi
  done < <(all_names_of "$f")
done

# Сайт соседа на catch-all без единого явного имени: наш regex заберёт и его
# домены. Если явные имена есть хоть где-то в чужих файлах — они и обслуживают
# свой сайт, а неизвестные имена ему не принадлежат.
if [ "$DEFAULT_CONTENT" -gt 0 ] && [ "$EXPLICIT_BLOCKS" -eq 0 ]; then UNSAFE=yes; fi

# ── Пробы ────────────────────────────────────────────────────────────────────────────
# Чужой Host: без нашего catch-all его получает default-сервер соседа (200),
# с `return 444` соединение закрывается без ответа (curl 52/56, код 000).
our_total=0
our_ok=0
for h in "${OUR_HOSTS[@]}"; do
  our_total=$((our_total + 1))
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Host: $h" http://127.0.0.1/ 2>/dev/null) || code="000"
  if [ "$code" = "200" ]; then our_ok=$((our_ok + 1)); fi
done

declare -A NB_BEFORE=()
nb_total=0
nb_ok=0
if [ "${#NB_NAMES[@]}" -gt 0 ]; then
  for h in "${NB_NAMES[@]}"; do
    nb_total=$((nb_total + 1))
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Host: $h" http://127.0.0.1/ 2>/dev/null) || code="000"
    NB_BEFORE["$h"]="$code"
    if [ "$code" = "200" ]; then nb_ok=$((nb_ok + 1)); fi
  done
fi

# ── Предохранители apply: до этой точки конфиг не тронут ─────────────────────────────
if [ "$MODE" = "apply" ] && [ "$PARSER_BAD" = "yes" ]; then
  echo "не смог разобрать чужие default-блоки — правку не делаю, нужен человек"
  echo "RESULT: HUMAN"
  exit 1
fi
if [ "$MODE" = "apply" ] && [ "$INCLUDE" = "yes" ]; then
  echo "в чужом конфиге есть include — его имён не видно; правку не делаю, нужен человек"
  echo "RESULT: HUMAN"
  exit 1
fi
if [ "$MODE" = "apply" ] && [ "$MARKERS" = "0" ] && [ "$UNSAFE" = "yes" ]; then
  echo "у соседа нет ни одного явного server_name, а catch-all отдаёт контент: наш regex заберёт и его домены"
  echo "нужно, чтобы сосед добавил явное server_name в свой блок; ничего не меняю"
  echo "RESULT: BLOCKED_NEIGHBOUR"
  exit 3
fi

# ── apply: внести блок (идемпотентно) ───────────────────────────────────────────────
CHANGED=no
BAK=""
if [ "$MODE" = "apply" ] && [ "$MARKERS" = "0" ]; then
  BAK="$CONF.bak-$(date +%Y%m%d-%H%M%S)-444"
  sudo cp -a "$CONF" "$BAK"
  echo "· бэкап секции сделан рядом с файлом"

  BLOCK_TMP=$(mktemp)
  cat > "$BLOCK_TMP" <<'BLOCK'

# >>> pozvoni-catchall-444 — чужой Host рвётся, default_server соседа не трогаем
# nginx проверяет регулярные server_name раньше default-сервера: сюда попадает
# любой Host, не совпавший ни с одним точным или масковым именем.
server {
    listen 80;
    listen [::]:80;
    server_name ~^;
    return 444;
}
# <<< pozvoni-catchall-444
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
  # reload отдаёт управление раньше, чем старые воркеры перестают принимать
  # новые соединения: без паузы проба может попасть в воркер со старым конфигом
  # и увидеть 200. Секунда — не «подождать, пока заработает», а развести два
  # поколения воркеров; если regex не сработал по-настоящему, повтор ниже это
  # покажет и правка откатится.
  sleep 1
fi

# ── Итоговое состояние ──────────────────────────────────────────────────────────────
nginx_t_ok=no
if sudo nginx -t >/dev/null 2>&1; then nginx_t_ok=yes; fi

# Перепроверяем после reload: не сработал ли наш regex и не пострадали ли имена
# соседа (у нас их явный список до правки). Один повтор через 2 с — на случай,
# если первый запрос ещё застал старое поколение воркеров.
probe_unknown() {
  UNKNOWN_RC=0
  UNKNOWN_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H 'Host: probe-unknown.invalid' http://127.0.0.1/ 2>/dev/null) || UNKNOWN_RC=$?
}
probe_unknown
case "$UNKNOWN_RC" in
  52|56) ;;
  *) sleep 2; probe_unknown ;;
esac
foreign_rc2=$UNKNOWN_RC
foreign_code2=$UNKNOWN_CODE
foreign_closed=no
case "$foreign_rc2" in
  52|56) foreign_closed=yes ;;
esac

nb_regression=no
nb_after_ok=0
if [ "${#NB_NAMES[@]}" -gt 0 ]; then
  for h in "${NB_NAMES[@]}"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Host: $h" http://127.0.0.1/ 2>/dev/null) || code="000"
    if [ "$code" = "200" ]; then nb_after_ok=$((nb_after_ok + 1)); fi
    if [ "${NB_BEFORE[$h]:-}" = "200" ] && [ "$code" != "200" ]; then nb_regression=yes; fi
  done
fi

# Имя файла, а не путь: логи прогонов публичны, а путь на боксе — recon-деталь того же
# класса, что хост и порт (AGENTS.md, D-038). Для разбора хватает и basename.
echo "· наша секция: $(basename "$CONF")"
if [ "$MARKERS" = "2" ]; then
  echo "· наш catch-all 444: стоит (regex, без default_server)"
else
  echo "· наш catch-all 444: не стоит"
fi
echo "· чужих файлов с default_server: ${#FOREIGN[@]}"
echo "· чужие блоки: с явными именами — $EXPLICIT_BLOCKS; default-блоков — $DEFAULT_BLOCKS (из них с явными именами: $DEFAULT_EXPLICIT, с контентом: $DEFAULT_CONTENT)"
echo "· include в чужом конфиге: $INCLUDE"
if [ "$UNPROBEABLE" -gt 0 ]; then
  echo "· имён соседа, которые не пробуем (шаблон/юникод): $UNPROBEABLE"
fi
echo "· nginx -t: $([ "$nginx_t_ok" = yes ] && echo ок || echo КРАСНЫЙ)"
NGINX_VER=$(sudo nginx -v 2>&1 | sed -n 's#^nginx/\([0-9.]*\).*#\1#p')
echo "· nginx: ${NGINX_VER:-неизвестна}"
echo "· default_server в нашей секции: нет (нужен только чужой — ловим regex-именем)"
echo "· чужой Host: $([ "$foreign_closed" = yes ] && echo "закрыто без ответа (curl rc $foreign_rc2) — 444 работает" || echo "http-код $foreign_code2 (curl rc $foreign_rc2) — 444 не срабатывает")"
echo "· наши имена: $our_ok из $our_total — 200"
if [ "$MODE" = "apply" ]; then
  echo "· явные имена соседа после правки: $nb_after_ok из $nb_total — 200 (регрессий: $nb_regression)"
else
  echo "· явные имена соседа: $nb_ok из $nb_total — 200"
fi

# ── Вердикт ─────────────────────────────────────────────────────────────────────────
if [ "$nginx_t_ok" = "yes" ] && [ "$MARKERS" = "2" ] \
   && [ "$foreign_closed" = "yes" ] && [ "$our_ok" -eq "$our_total" ] \
   && [ "$nb_regression" = "no" ]; then
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
  if [ "$INCLUDE" = "yes" ]; then
    echo "RESULT: HUMAN (include в чужом конфиге)"
    exit 1
  fi
  if [ "$UNSAFE" = "yes" ]; then
    echo "RESULT: BLOCKED_NEIGHBOUR"
    exit 0
  fi
  if [ "$PARSER_BAD" = "yes" ]; then
    echo "RESULT: HUMAN (не разобрал чужие default-блоки)"
    exit 1
  fi
  echo "RESULT: READY_TO_APPLY"
  exit 0
fi

echo "RESULT: BROKEN (nginx -t красный, наш блок не сработал или наши имена не 200)"
exit 1
