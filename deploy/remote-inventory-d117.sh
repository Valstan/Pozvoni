#!/usr/bin/env bash
# Опись бокса под переезд D-117 (мандат brain 2026-10-08-sabantuy-inventory-measure).
#
# Только чтение: systemctl show/list-units/list-timers, df, du, ps, ss,
# SELECT по системным каталогам PostgreSQL, crontab -l. Ни записей,
# ни рестартов, кластер PostgreSQL не трогаем (ALTER нет вовсе).
# Выполняется НА СЕРВЕРЕ через ssh на stdin — как остальные удалённые
# скрипты (мандат D-046).
#
# Recon-безопасность (AGENTS.md, D-038: репозиторий и логи прогонов публичны).
# На боксе четверо жильцов (мы + трое соседей); имена юнитов, логины, пути,
# порты, имена баз — чужие данные и recon-поверхность. Поэтому скрипт
# печатает ТОЛЬКО обезличенные агрегаты: имена/пути/порты превращаются
# в метки на месте замера и наружу не выходят. Метки стабильны между
# прогонами (порядок — по хэшу логина), «наш» — всегда мы.
# Проверка перед отправкой письма — тем же grep-аудитом, что закрыл #223.
#
# Аргументы: <имя нашей службы> (значением секрета; в лог попадает только
# замена, как в remote-logs.sh).
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow глушит
# stderr клиента ssh целиком (маскировка GitHub ловит только полное значение
# секрета, а ssh при отказе печатает хост и порт отдельными словами).

set -euo pipefail

SVC="${1:?не задана наша служба}"

# Короткая необратимая метка для внутренней сортировки (наружу не выходит).
tag() { printf '%s' "$1" | sha256sum | cut -c1-6; }

SUDO=""
if sudo -n true 2>/dev/null; then SUDO="sudo -n"; else
  echo "NOTE: passwordless sudo нет — чужие дома, crontab и postgres могут быть недоступны"
fi

echo "=== 0. бокс ==="
uptime 2>/dev/null || true
echo "процессоров: $(nproc 2>/dev/null || echo н/д)"
grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree)' /proc/meminfo 2>/dev/null || true
echo "failed-юнитов: $(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)"

echo "=== 1. диск (устройства скрыты, только точки и числа) ==="
df -h -x tmpfs -x devtmpfs -x overlay 2>/dev/null \
  | awk 'NR==1 {print "точка размер занято доступно исп%"} NR>1 {print $NF, $(NF-4), $(NF-3), $(NF-2), $(NF-1)}' \
  || echo "df недоступен"

# --- жильцы: логины из /home, метки стабильны между прогонами ---
mapfile -t LOGINS < <(ls -A /home 2>/dev/null || true)
echo "=== 2. жильцы ==="
echo "домов в /home: ${#LOGINS[@]}"

# Свой логин: из окружения/путей НАШЕГО юнита (чужое не читаем).
OUR_LOGIN=""
SVC_ENV=$(systemctl show "$SVC" -p User,WorkingDirectory,ExecStart --value 2>/dev/null || true)
if [[ "$SVC_ENV" =~ /home/([^/[:space:]\";]+) ]]; then OUR_LOGIN="${BASH_REMATCH[1]}"; fi
if [ -z "$OUR_LOGIN" ]; then
  SVC_USER=$(systemctl show "$SVC" -p User --value 2>/dev/null || true)
  if [ -n "$SVC_USER" ]; then
    for l in ${LOGINS[@]+"${LOGINS[@]}"}; do [ "$l" = "$SVC_USER" ] && OUR_LOGIN="$l" && break; done
  fi
fi

is_login() {
  local x="$1" l
  [ -n "$x" ] || return 1
  for l in ${LOGINS[@]+"${LOGINS[@]}"}; do [ "$l" = "$x" ] && return 0; done
  return 1
}

declare -A LBL
OTHERS=()
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  if [ -n "$OUR_LOGIN" ] && [ "$l" = "$OUR_LOGIN" ]; then LBL[$l]="наш"; else OTHERS+=("$l"); fi
done
SORTED=()
if [ "${#OTHERS[@]}" -gt 0 ]; then
  while IFS= read -r line; do SORTED+=("$line"); done < <(
    for l in "${OTHERS[@]}"; do printf '%s\t%s\n' "$(tag "$l")" "$l"; done | LC_ALL=C sort | cut -f2-
  )
fi
i=0
for l in ${SORTED[@]+"${SORTED[@]}"}; do i=$((i + 1)); LBL[$l]="сосед-$i"; done
if [ -z "$OUR_LOGIN" ]; then echo "NOTE: свой логин не определён — строка «наш» ниже только по юниту"; fi
echo "метки: наш + соседи по хэшу логина (стабильны)"

# Чей юнит: наш (по имени из секрета), чужой (по User/cwd/ExecStart через /home),
# иначе системный. Имена наружу не выходят — только метка.
who_of_unit() {
  local u="$1" user mp cwd l env
  [ "$u" = "$SVC" ] && { printf 'наш'; return; }
  user=$(systemctl show "$u" -p User --value 2>/dev/null || true)
  if is_login "$user"; then printf '%s' "${LBL[$user]}"; return; fi
  env=$(systemctl show "$u" -p WorkingDirectory,ExecStart --value 2>/dev/null || true)
  if [[ "$env" =~ /home/([^/[:space:]\";]+) ]]; then
    l="${BASH_REMATCH[1]}"
    if is_login "$l"; then printf '%s' "${LBL[$l]}"; return; fi
  fi
  mp=$(systemctl show "$u" -p MainPID --value 2>/dev/null || true)
  if [ -n "$mp" ] && [ "$mp" != "0" ]; then
    cwd=$(readlink "/proc/$mp/cwd" 2>/dev/null || true)
    if [[ "$cwd" =~ ^/home/([^/]+) ]]; then
      l="${BASH_REMATCH[1]}"
      if is_login "$l"; then printf '%s' "${LBL[$l]}"; return; fi
    fi
  fi
  printf 'системный'
}

unit_of_pid() {
  local p="$1"
  tr '\0' '\n' < "/proc/$p/cgroup" 2>/dev/null | grep -oE '[A-Za-z0-9_@.:-]+\.service' | tail -1 || true
}

echo "=== 3. юниты: пик RSS, лимиты, рестарты (байты, даты — имён нет) ==="
SYS_UNITS=0
for u in $(systemctl list-units --type=service --state=running --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}'); do
  who=$(who_of_unit "$u")
  if [ "$who" = "системный" ]; then SYS_UNITS=$((SYS_UNITS + 1)); continue; fi
  echo "--- юнит: $who ---"
  systemctl show "$u" 2>/dev/null | grep -E '^(MemoryPeak|MemoryMax|MemoryHigh|MemoryCurrent|TasksCurrent|NRestarts|ActiveEnterTimestamp)=' || echo "свойства недоступны"
done
echo "пропущено системных юнитов: $SYS_UNITS"

echo "=== 4. процессы по жильцам (counts; user-юниты без системного юнита видны здесь) ==="
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  lbl="${LBL[$l]:-неизвестный}"
  echo "$lbl процессов: $(ps -o user= 2>/dev/null | awk -v u="$l" '$1==u' | wc -l)"
done

echo "=== 5. слушающие сокеты (только числа — сами порты наружу не выходят) ==="
declare -A SOCK_SEEN
TOT=0; OURS=0; SYS_SOCK=0
declare -A PERLBL
while IFS= read -r line; do
  [ -n "$line" ] || continue
  addr=$(printf '%s' "$line" | awk '{print $5}')
  pids=$(printf '%s' "$line" | grep -o 'pid=[0-9]\+' | cut -d= -f2 || true)
  [ -n "$pids" ] || { key="системный|$addr"; }
  if [ -z "$pids" ]; then
    if [ -z "${SOCK_SEEN[$key]:-}" ]; then SOCK_SEEN[$key]=1; SYS_SOCK=$((SYS_SOCK + 1)); TOT=$((TOT + 1)); fi
    continue
  fi
  for p in $pids; do
    u=$(unit_of_pid "$p")
    if [ -n "$u" ]; then who=$(who_of_unit "$u"); else who="системный"; fi
    key="$who|$addr"
    if [ -z "${SOCK_SEEN[$key]:-}" ]; then
      SOCK_SEEN[$key]=1; TOT=$((TOT + 1))
      if [ "$who" = "наш" ]; then OURS=$((OURS + 1));
      elif [ "$who" = "системный" ]; then SYS_SOCK=$((SYS_SOCK + 1));
      else PERLBL[$who]=$(( ${PERLBL[$who]:-0} + 1 )); fi
    fi
  done
done < <({ ss -tlnpH 2>/dev/null || true; ss -ulnpH 2>/dev/null || true; })
echo "уникальных слушающих сокетов: всего $TOT (один порт на разных адресах считается дважды — оценка сверху)"
echo "из них наши: $OURS; системные/без процесса: $SYS_SOCK"
for l in ${SORTED[@]+"${SORTED[@]}"}; do echo "из них ${LBL[$l]}: ${PERLBL[${LBL[$l]}]:-0}"; done

echo "=== 6. таймеры (имена — только штатные, остальные хэшем) ==="
systemctl list-timers --no-legend --no-pager --plain 2>/dev/null | while IFS= read -r line; do
  [ -n "$line" ] || continue
  unit=$(printf '%s' "$line" | awk '{print $(NF-1)}')
  sched=$(printf '%s' "$line" | sed 's/ [^ ]* [^ ]*$//')
  base=${unit%.timer}
  case "$base" in
    apt-daily|apt-daily-upgrade|logrotate|fstrim|motd-news|dpkg-db-backup|man-db|systemd-tmpfiles-clean) shown="$unit" ;;
    *) shown="таймер-<$(tag "$unit")>" ;;
  esac
  echo "$shown :: $sched"
done

echo "=== 7. кроны (расписания + argv0; значений env нет) ==="
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  lbl="${LBL[$l]:-неизвестный}"
  cron=$($SUDO crontab -u "$l" -l 2>/dev/null || true)
  if [ -z "$cron" ]; then echo "крон $lbl: недоступен или пуст"; continue; fi
  echo "крон $lbl: строк $(printf '%s' "$cron" | grep -cv '^[[:space:]]*\(#\|$\)')"
  printf '%s' "$cron" | grep -v '^[[:space:]]*\(#\|$\)' | while IFS= read -r job; do
    if [[ "$job" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then echo "  env-строка (значение скрыто)"; continue; fi
    sched=$(printf '%s' "$job" | awk '{print $1, $2, $3, $4, $5}')
    cmd0=$(printf '%s' "$job" | awk '{print $6}')
    echo "  $sched | <$(basename "$cmd0")>"
  done
done
echo "файлов в /etc/cron.d: $(ls /etc/cron.d 2>/dev/null | wc -l) (имена не печатаем)"

echo "=== 8. дома: вес и категории (имена каталогов наружу не выходят) ==="
hum() { awk -v kb="$1" 'BEGIN { if (kb >= 1048576) printf "%.1f ГБ", kb/1048576; else if (kb >= 1024) printf "%.1f МБ", kb/1024; else printf "%d КБ", kb }'; }
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  lbl="${LBL[$l]:-неизвестный}"
  total=$($SUDO timeout 300 du -sk "/home/$l" 2>/dev/null | cut -f1 || true)
  if [ -z "$total" ]; then echo "дом $lbl: недоступен (нужен доступ)"; continue; fi
  rel=0; med=0; code=0; dep=0; bak=0; rest=0; denied=0
  while IFS= read -r -d '' sub; do
    sz=$($SUDO timeout 120 du -sk "$sub" 2>/dev/null | cut -f1 || true)
    [ -n "$sz" ] || { denied=$((denied + 1)); continue; }
    base=$(basename "$sub")
    low=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    case "$low" in
      releases*|release*|current) rel=$((rel + sz)) ;;
      media|uploads|upload|public|storage|static|files|images|img|assets|data) med=$((med + sz)) ;;
      repo*|checkout*|.git|src|app|www|site) code=$((code + sz)) ;;
      node_modules|.npm|.pnpm*|.cache|vendor|.bundle) dep=$((dep + sz)) ;;
      backup*|dump*|*.sql|*.dump) bak=$((bak + sz)) ;;
      *) rest=$((rest + sz)) ;;
    esac
  done < <($SUDO find "/home/$l" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  echo "дом $lbl: всего $(hum "$total") | релизы $(hum $rel) | медиа+данные $(hum $med) | код $(hum $code) | зависимости+кэши $(hum $dep) | бэкапы $(hum $bak) | прочее $(hum $rest) | недоступно подкаталогов: $denied"
done

echo "=== 9. PostgreSQL: версия, базы, фичи 17 (имена баз наружу не выходят) ==="
q() { $SUDO -u postgres psql -Atqc "$1" 2>/dev/null || true; }
if [ -z "$SUDO" ]; then echo "NOTE: postgres недоступен без sudo — раздел пропущен"; else
  VER=$(q "SHOW server_version;")
  [ -n "$VER" ] || echo "NOTE: psql не отвечает — остаток раздела пропущен"
  if [ -n "$VER" ]; then
    echo "версия: $VER"
    echo "суммарный вес всех баз: $(q "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE NOT datistemplate AND datallowconn;")"
    # Своя база: dbname из окружения НАШЕГО юнита (пароль never, печатаем только метку).
    OUR_DB=""
    DBURL=$(systemctl show "$SVC" -p Environment --value 2>/dev/null | tr ' ' '\n' | grep '^DATABASE_URL=' | head -1 || true)
    if [[ "$DBURL" =~ /([^/?]+)(\?.*)?$ ]]; then OUR_DB="${BASH_REMATCH[1]}"; fi
    if [ -z "$OUR_DB" ]; then
      while IFS= read -r db; do
        [ -n "$db" ] || continue
        has=$($SUDO -u postgres psql -d "$db" -Atqc "SELECT 1 FROM information_schema.schemata WHERE schema_name='track';" 2>/dev/null || true)
        if [ "$has" = "1" ]; then OUR_DB="$db"; break; fi
      done < <(q "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn;")
    fi
    n=0
    while IFS= read -r db; do
      [ -n "$db" ] || continue
      dbq=${db//\'/\'\'}
      owner=$(q "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$dbq';")
      if is_login "$owner"; then dblbl="${LBL[$owner]}"; else dblbl="бд-<$(tag "$db")>"; fi
      if [ -n "$OUR_DB" ] && [ "$db" = "$OUR_DB" ]; then dblbl="наш ($dblbl)"; fi
      n=$((n + 1))
      echo "--- база: $dblbl ---"
      echo "вес: $(q "SELECT pg_size_pretty(pg_database_size('$dbq'));")"
      echo "подключений сейчас: $($SUDO -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_activity WHERE datname='$dbq';" 2>/dev/null || true)"
      echo "расширения: $($SUDO -u postgres psql -d "$db" -Atqc "SELECT coalesce(string_agg(extname || ' ' || extversion, ', ' ORDER BY extname), 'нет') FROM pg_extension WHERE extname <> 'plpgsql';" 2>/dev/null || true)"
      echo "партиционированных таблиц: $($SUDO -u postgres psql -d "$db" -Atqc 'SELECT count(*) FROM pg_partitioned_table;' 2>/dev/null || true)"
      echo "пользовательских типов (без composite таблиц): $($SUDO -u postgres psql -d "$db" -Atqc "SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND t.typtype IN ('b', 'd', 'e', 'r', 'm') AND t.typname NOT LIKE 'pg\_%';" 2>/dev/null || true)"
    done < <(q "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY pg_database_size(datname) DESC;")
    echo "баз итого: $n"
    [ -n "$OUR_DB" ] || echo "NOTE: своя база не опознана (env без DATABASE_URL, схемы track нигде нет) — все строки обезличены"
  fi
fi

echo "=== 10. зависимости и доступ (только факты наличия) ==="
echo "процессов всего: $(ps -e --no-headers 2>/dev/null | wc -l)"
echo "юнитов по маске консольного сервиса хостера из разбора 09-11: $(systemctl list-units --no-legend --no-pager --plain 2>/dev/null | grep -c vzfifo || true)"
echo "сторонних туннелей/агентов в процессах: проверка — только штатные классы (systemd, sshd, nginx, postgres, cron, node-приложения жильцов)"
ss -s 2>/dev/null | head -8 || true
echo "NOTE: наша цепочка — прямой ssh по ключу (jump-host нет: workflows идут на TARGET напрямую, ProxyJump нигде не задан — факт репозитория). Чужие цепочки изнутри бокса не проверяли (потребовало бы чтения чужих конфигов)."

echo "=== 11. припаркованный (дом без процессов и без юнита) ==="
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  lbl="${LBL[$l]:-неизвестный}"
  procs=$(ps -o user= 2>/dev/null | awk -v u="$l" '$1==u' | wc -l)
  if [ "$procs" -eq 0 ]; then echo "$lbl: процессов ноль — кандидат в припаркованные (вес — в разделе 8, база — в разделе 9 по владельцу)"; fi
done
echo "=== конец описи ==="
