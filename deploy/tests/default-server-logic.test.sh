#!/usr/bin/env bash
# Логика `remote-fix-default-server.sh` на подставных sudo/nginx/curl: на живом
# боксе второй такой прогон не поставить, а цена ошибки — чужой сайт или
# красный `nginx -t` у всех жильцов. Здесь проверяются ровно те вещи, которые
# иначе всплыли бы только на боксе:
#   1) предохранитель: если сайт соседа живёт на catch-all без явного имени,
#      apply не трогает конфиг (BLOCKED_NEIGHBOUR);
#   2) include в чужом файле — не угадываем, отдаём человеку (HUMAN);
#   3) успешный apply ставит блок один раз и делает бэкап;
#   4) повторный apply идемпотентен;
#   5) красный `nginx -t` и регрессия имён соседа откатывают правку.
# Домены, пути и имена здесь выдуманные, бокса не касаются.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/deploy/remote-fix-default-server.sh"
[ -f "$SRC" ] || { echo "нет $SRC"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc/nginx/conf.d"

# ── Подставные команды ──────────────────────────────────────────────────────────────
cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
STUB

cat > "$T/bin/nginx" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -t) exit "$(cat "$STUB_DIR/nginx_t_rc" 2>/dev/null || echo 0)" ;;
  -T) cat "$STUB_DIR"/etc/nginx/conf.d/*.conf ;;
  *) exit 0 ;;
esac
STUB

cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'reload\n' >> "$STUB_DIR/reloads"
exit 0
STUB

# Отвечает по состоянию конфига: пока маркера нет — всё 200 (как сейчас на
# боксе, где чужой Host получает сайт соседа); после вставки блока — точные
# имена наши и соседа 200, неизвестный Host закрыт (curl rc 52). STUB_NB_BROKEN
# имитирует regex, который зацепил имя соседа.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
host=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H)
      shift
      case "${1:-}" in
        Host:*) host="${1#Host: }" ;;
      esac
      ;;
  esac
  shift || true
done
marker=no
if grep -qF 'pozvoni-catchall-444' "$STUB_DIR"/etc/nginx/conf.d/*.conf 2>/dev/null; then
  marker=yes
fi
if [ "$marker" = "no" ]; then
  printf '200'
  exit 0
fi
for h in $STUB_OUR; do
  if [ "$h" = "$host" ]; then printf '200'; exit 0; fi
done
if [ "${STUB_NB_BROKEN:-no}" = "yes" ] && [ "$host" = "${STUB_NB_FIRST:-}" ]; then
  printf '500'
  exit 0
fi
for h in $STUB_NB; do
  if [ "$h" = "$host" ]; then printf '200'; exit 0; fi
done
exit 52
STUB

chmod +x "$T/bin/"*

# Копия скрипта с подменой абсолютного каталога nginx (на раннере он не наш).
sed "s#/etc/nginx#$T/etc/nginx#g" "$SRC" > "$T/remote-fix-default-server.sh"

# ── Фикстуры ────────────────────────────────────────────────────────────────────────
OURS="$T/etc/nginx/conf.d/10-ours.conf"
NEIGHBOUR="$T/etc/nginx/conf.d/20-neighbour.conf"

reset_conf() {
  local kind="$1"
  rm -rf "$T/etc/nginx/conf.d"
  mkdir -p "$T/etc/nginx/conf.d"
  rm -f "$T/nginx_t_rc" "$T/reloads"
  echo 0 > "$T/nginx_t_rc"

  cat > "$OURS" <<'CONF'
server {
    listen 80;
    listen [::]:80;
    server_name ours1.example ours2.example;

    location / {
        proxy_pass http://127.0.0.1:3000;
    }
}
CONF

  case "$kind" in
    safe)
      cat > "$NEIGHBOUR" <<'CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _ n1.example;
    root /srv/neighbour;
}
server {
    listen 80;
    server_name n2.example;
    root /srv/neighbour;
}
CONF
      ;;
    unsafe)
      # Сайт соседа на catch-all: явных имён у блока нет.
      cat > "$NEIGHBOUR" <<'CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /srv/neighbour;
}
server {
    listen 80;
    server_name n2.example;
    root /srv/neighbour;
}
CONF
      ;;
    include)
      cat > "$NEIGHBOUR" <<'CONF'
include /etc/nginx/snippets/neighbour.conf;
server {
    listen 80 default_server;
    server_name _ n1.example;
    root /srv/neighbour;
}
CONF
      ;;
  esac
}

run() {
  local stub_nb_broken="${1:-no}"
  shift || true
  PATH="$T/bin:$PATH" \
    STUB_DIR="$T" \
    STUB_OUR="ours1.example ours2.example" \
    STUB_NB="n1.example n2.example" \
    STUB_NB_FIRST="n1.example" \
    STUB_NB_BROKEN="$stub_nb_broken" \
    bash "$T/remote-fix-default-server.sh" "$@" ours1.example ours2.example
}

fail() {
  echo "FAIL: $*"
  echo "--- последний вывод ---"
  printf '%s\n' "${OUT:-}"
  echo "--- наша секция ---"
  cat "$OURS" 2>/dev/null || true
  exit 1
}

expect_out() { case "$OUT" in *"$1"*) : ;; *) fail "в выводе нет «$1»" ;; esac; }
markers() { grep -cF 'pozvoni-catchall-444' "$OURS" 2>/dev/null || true; }

# 1. check безопасного соседа: только чтение, ничего не меняет.
reset_conf safe
OUT=$(run no check) || fail "check вернул ошибку ($?)"
expect_out "RESULT: READY_TO_APPLY"
[ "$(markers)" = "0" ] || fail "check изменил конфиг"
[ -z "$(ls "$T"/etc/nginx/conf.d/*.bak-* 2>/dev/null || true)" ] || fail "check сделал бэкап"

# 2. сайт соседа на catch-all → apply ничего не трогает.
reset_conf unsafe
set +e; OUT=$(run no apply); rc=$?; set -e
expect_out "RESULT: BLOCKED_NEIGHBOUR"
[ "$rc" = "3" ] || fail "ожидался код 3, получен $rc"
[ "$(markers)" = "0" ] || fail "apply изменил конфиг при UNSAFE"
[ -z "$(ls "$T"/etc/nginx/conf.d/*.bak-* 2>/dev/null || true)" ] || fail "apply сделал бэкап при UNSAFE"

# 3. include в чужом файле → человеку.
reset_conf include
set +e; OUT=$(run no check); rc=$?; set -e
expect_out "RESULT: HUMAN"
[ "$rc" = "1" ] || fail "ожидался код 1, получен $rc"

# 4. успешный apply: блок, бэкап, чужой файл не тронут.
reset_conf safe
cp "$NEIGHBOUR" "$T/neighbour.before"
OUT=$(run no apply) || fail "apply вернул ошибку ($?)"
expect_out "RESULT: DONE"
[ "$(markers)" = "2" ] || fail "маркер нашего блока не 2"
cmp -s "$NEIGHBOUR" "$T/neighbour.before" || fail "чужой файл изменился"
[ "$(ls "$T"/etc/nginx/conf.d/*.bak-* 2>/dev/null | wc -l)" = "1" ] || fail "нет ровно одного бэкапа"

# 5. повторный apply идемпотентен: второй блок не появляется, новый бэкап не нужен.
OUT=$(run no apply) || fail "повторный apply вернул ошибку ($?)"
expect_out "RESULT: DONE"
[ "$(markers)" = "2" ] || fail "повторный apply добавил блок"
[ "$(ls "$T"/etc/nginx/conf.d/*.bak-* 2>/dev/null | wc -l)" = "1" ] || fail "повторный apply сделал лишний бэкап"

# 6. красный nginx -t → откат, конфиг как был.
reset_conf safe
cp "$OURS" "$T/ours.before"
echo 1 > "$T/nginx_t_rc"
set +e; OUT=$(run no apply); rc=$?; set -e
expect_out "RESULT: FAILED"
[ "$rc" = "1" ] || fail "ожидался код 1, получен $rc"
cmp -s "$OURS" "$T/ours.before" || fail "после красного nginx -t конфиг не откатился"
[ ! -s "$T/reloads" ] || fail "reload был, хотя nginx -t красный"

# 7. regex зацепил имя соседа → регрессия и откат.
reset_conf safe
cp "$OURS" "$T/ours.before"
echo 0 > "$T/nginx_t_rc"
set +e; OUT=$(run yes apply); rc=$?; set -e
expect_out "RESULT: FAILED"
[ "$rc" = "1" ] || fail "ожидался код 1, получен $rc"
cmp -s "$OURS" "$T/ours.before" || fail "при регрессии имён соседа конфиг не откатился"
[ "$(markers)" = "0" ] || fail "после отката маркер остался"

echo "default-server: ок (7 случаев: предохранители, идемпотентность, откаты)"
