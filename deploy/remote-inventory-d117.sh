#!/usr/bin/env bash
# Опись бокса под переезд D-117 (мандат brain 2026-10-08-sabantuy-inventory-measure).
# Версия 2: привязка не по логинам, а по подкаталогам дома.
#
# Урок прогона 1 (14:24 UTC 08.10): в /home ОДИН дом, а юнитов приложений три —
# жильцы делят одного системного пользователя, и метка по логину слепила всех
# в «наш». Здесь ключ жильца — первый подкаталог дома из WorkingDirectory /
# ExecStart / cwd юнита (наш — из окружения нашей службы). Чужие имена наружу
# не выходят: печатаются только метки (стабильны между прогонами) и числа.
#
# Только чтение: systemctl show/list-units/list-timers, df, du, stat, ps, ss,
# SELECT по системным каталогам PostgreSQL, crontab -l, чтение cgroupfs
# (memory.peak/current, pids.current — учёт systemd может молчать, как в
# прогоне 1, а cgroupfs цифры отдаёт). Ни записей, ни рестартов.
# Выполняется НА СЕРВЕРЕ через ssh на stdin (мандат D-046).
#
# Recon-безопасность (AGENTS.md, D-038: репозиторий и логи прогонов публичны).
# Имена юнитов/таймеров (кроме штатных), логины, подкаталоги, пути, порты,
# имена баз и ролей — чужие данные: всё превращается в метки на месте замера.
# Проверка перед письмом — тем же grep-аудитом, что закрыл #223.
#
# Аргументы: <имя нашей службы> (значением секрета; в лог попадает только
# замена, как в remote-logs.sh).
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow глушит
# stderr клиента ssh целиком (маскировка GitHub ловит только полное значение
# секрета, а ssh при отказе печатает хост и порт отдельными словами).

set -euo pipefail

SVC="${1:?не задана наша служба}"

# Короткая необратимая метка (детерминирована, стабильна между прогонами).
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
df -i -x tmpfs -x devtmpfs -x overlay 2>/dev/null \
  | awk 'NR==1 {print "точка инодов занято свободно исп%"} NR>1 {print $NF, $(NF-4), $(NF-3), $(NF-2), $(NF-1)}' \
  || echo "df -i недоступен"

# --- жильцы: дома, подкаталоги, ключи, метки ---
mapfile -t LOGINS < <(ls -A /home 2>/dev/null || true)
echo "=== 2. жильцы (ключи — подкаталоги домов, метки стабильны) ==="
echo "домов в /home: ${#LOGINS[@]}"

# Наш логин и наш подкаталог — из окружения НАШЕГО юнита (чужое не читаем).
OUR_LOGIN=""; OUR_SUB=""
SVC_ENV=$(systemctl show "$SVC" -p User,WorkingDirectory,ExecStart --value 2>/dev/null || true)
if [[ "$SVC_ENV" =~ /home/([^/[:space:]\";]+)(/([^/[:space:]\";]+))? ]]; then
  OUR_LOGIN="${BASH_REMATCH[1]}"; OUR_SUB="${BASH_REMATCH[3]:-}"
fi
if [ -z "$OUR_LOGIN" ]; then
  SVC_USER=$(systemctl show "$SVC" -p User --value 2>/dev/null || true)
  for l in ${LOGINS[@]+"${LOGINS[@]}"}; do [ "$l" = "$SVC_USER" ] && OUR_LOGIN="$l" && break; done
fi

is_login() {
  local x="$1" l
  [ -n "$x" ] || return 1
  for l in ${LOGINS[@]+"${LOGINS[@]}"}; do [ "$l" = "$x" ] && return 0; done
  return 1
}

# Ключ жильца: "логин/подкаталог" либо "логин" (юнит прямо в доме).
# SUBKEY["дом-подметка"] = ключ; KEYLBL[ключ] = метка; SUBNAMES — имена для
# внутреннего сопоставления владельцев баз (наружу не выходят).
declare -A SUBKEY KEYLBL
SUBNAMES=()
OUR_KEY=""
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  while IFS= read -r -d '' sub; do
    base=$(basename "$sub")
    SUBNAMES+=("$base")
    key="$l/$base"
    stag="под-$(tag "$sub")"
    SUBKEY[$stag]="$key"
    if [ -n "$OUR_LOGIN" ] && [ "$l" = "$OUR_LOGIN" ] && [ -n "$OUR_SUB" ] && [ "$base" = "$OUR_SUB" ]; then
      OUR_KEY="$key"; KEYLBL[$key]="наш"
    fi
  done < <($SUDO find "/home/$l" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  if [ -n "$OUR_LOGIN" ] && [ "$l" = "$OUR_LOGIN" ] && [ -z "$OUR_KEY" ]; then
    OUR_KEY="$l"; KEYLBL[$l]="наш"
  fi
done
# Остальные ключи — соседи по хэшу ключа (стабильно).
OTHERS=()
for stag in "${!SUBKEY[@]}"; do
  [ "${SUBKEY[$stag]}" = "$OUR_KEY" ] || OTHERS+=("${SUBKEY[$stag]}")
done
# Плюс ключ «логин целиком» для юнитов, живущих прямо в доме.
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  if [ "$l" != "$OUR_KEY" ] && [ -z "${KEYLBL[$l]:-}" ]; then OTHERS+=("$l"); fi
done
SORTED=()
if [ "${#OTHERS[@]}" -gt 0 ]; then
  while IFS= read -r line; do SORTED+=("$line"); done < <(
    for k in "${OTHERS[@]}"; do printf '%s\t%s\n' "$(tag "$k")" "$k"; done | LC_ALL=C sort | cut -f2-
  )
fi
i=0
for k in ${SORTED[@]+"${SORTED[@]}"}; do i=$((i + 1)); KEYLBL[$k]="сосед-$i"; done
[ -n "$OUR_KEY" ] || echo "NOTE: свой ключ не определён — строка «наш» ниже только по имени юнита"
echo "метки: наш + соседи по хэшу ключа (стабильны); подкаталоги — под-<хэш>"

# Чей юнит: наш (имя из секрета или наш ключ), чужой (дом/подкаталог из
# WorkingDirectory/ExecStart/cwd/User), иначе «без привязки».
declare -A KEYN
who_of_unit() {
  local u="$1" user mp cwd l env sub key
  if [ "$u" = "$SVC" ]; then
    if [ -n "$OUR_KEY" ]; then printf '%s' "${KEYLBL[$OUR_KEY]}"; else printf 'наш'; fi
    return
  fi
  env=$(systemctl show "$u" -p WorkingDirectory,ExecStart --value 2>/dev/null || true)
  if [[ "$env" =~ /home/([^/[:space:]\";]+)(/([^/[:space:]\";]+))? ]]; then
    l="${BASH_REMATCH[1]}"; sub="${BASH_REMATCH[3]:-}"
    if is_login "$l"; then
      if [ -n "$sub" ]; then key="$l/$sub"; else key="$l"; fi
      if [ -n "${KEYLBL[$key]:-}" ]; then printf '%s' "${KEYLBL[$key]}"; return; fi
    fi
  fi
  user=$(systemctl show "$u" -p User --value 2>/dev/null || true)
  if is_login "$user"; then
    if [ -n "${KEYLBL[$user]:-}" ]; then printf '%s' "${KEYLBL[$user]}"; return; fi
  fi
  mp=$(systemctl show "$u" -p MainPID --value 2>/dev/null || true)
  if [ -n "$mp" ] && [ "$mp" != "0" ]; then
    cwd=$(readlink "/proc/$mp/cwd" 2>/dev/null || true)
    if [[ "$cwd" =~ ^/home/([^/]+)(/([^/]+))? ]]; then
      l="${BASH_REMATCH[1]}"; sub="${BASH_REMATCH[3]:-}"
      if is_login "$l"; then
        if [ -n "$sub" ]; then key="$l/$sub"; else key="$l"; fi
        if [ -n "${KEYLBL[$key]:-}" ]; then printf '%s' "${KEYLBL[$key]}"; return; fi
      fi
    fi
  fi
  printf 'без-привязки'
}

unit_of_pid() {
  local p="$1"
  tr '\0' '\n' < "/proc/$p/cgroup" 2>/dev/null | grep -oE '[A-Za-z0-9_@.:-]+\.service' | tail -1 || true
}

# Память юнита из cgroupfs (systemd-учёт может молчать — cgroupfs отдаёт).
cgmem() {
  local u="$1" base f v
  for base in "/sys/fs/cgroup/system.slice/$u" "/sys/fs/cgroup/memory/system.slice/$u"; do
    for f in memory.peak memory.current memory.max pids.current memory.max_usage_in_bytes memory.usage_in_bytes; do
      if [ -r "$base/$f" ]; then
        v=$($SUDO cat "$base/$f" 2>/dev/null || true)
        [ -n "$v" ] && echo "cgroup-$f: $v"
      fi
    done
  done
}

echo "=== 3. юниты: пик RSS, лимиты, рестарты, cgroup (байты, даты — имён нет) ==="
SYS_UNITS=0; NOBIND=0
declare -A UNITWHO
for u in $(systemctl list-units --type=service --state=running --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}'); do
  who=$(who_of_unit "$u")
  UNITWHO[$u]="$who"
  if [ "$who" = "системный" ]; then SYS_UNITS=$((SYS_UNITS + 1)); continue; fi
  if [ "$who" = "без-привязки" ]; then NOBIND=$((NOBIND + 1)); who="без-привязки-№$NOBIND"; UNITWHO[$u]="$who"; fi
  # Счётчик юнитов на ключ — для раздела 8 и поиска припаркованного.
  for k in "${!KEYLBL[@]}"; do
    if [ "${KEYLBL[$k]}" = "$who" ]; then KEYN[$k]=$(( ${KEYN[$k]:-0} + 1 )); fi
  done
  echo "--- юнит: $who ---"
  systemctl show "$u" 2>/dev/null | grep -E '^(MemoryPeak|MemoryMax|MemoryHigh|MemoryCurrent|TasksCurrent|NRestarts|ActiveEnterTimestamp)=' || echo "свойства systemd недоступны"
  cgmem "$u" || true
done
echo "пропущено системных юнитов: $SYS_UNITS"

echo "=== 4. процессы (по юнитам из cgroup + итог по логинам) ==="
declare -A PROCS
for u in "${!UNITWHO[@]}"; do
  who="${UNITWHO[$u]}"
  [ "$who" = "системный" ] && continue
  for base in "/sys/fs/cgroup/system.slice/$u" "/sys/fs/cgroup/memory/system.slice/$u"; do
    if [ -r "$base/pids.current" ]; then
      v=$($SUDO cat "$base/pids.current" 2>/dev/null || true)
      if [ -n "$v" ]; then PROCS[$who]=$(( ${PROCS[$who]:-0} + v )); break; fi
    fi
  done
done
for k in "${!KEYLBL[@]}"; do echo "процессов у ${KEYLBL[$k]} (cgroup): ${PROCS[${KEYLBL[$k]}]:-н/д}"; done
[ "$NOBIND" -gt 0 ] && echo "процессов у без-привязки (cgroup): ${PROCS[без-привязки-№1]:-н/д}"
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  echo "процессов на логин (итог, все жильцы дома): $(ps -o user= 2>/dev/null | awk -v u="$l" '$1==u' | wc -l)"
done

echo "=== 5. слушающие сокеты (только числа — сами порты наружу не выходят) ==="
declare -A SOCK_SEEN PERLBL
TOT=0; SYS_SOCK=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  addr=$(printf '%s' "$line" | awk '{print $5}')
  pids=$(printf '%s' "$line" | grep -o 'pid=[0-9]\+' | cut -d= -f2 || true)
  if [ -z "$pids" ]; then
    key="системный|$addr"
    if [ -z "${SOCK_SEEN[$key]:-}" ]; then SOCK_SEEN[$key]=1; SYS_SOCK=$((SYS_SOCK + 1)); TOT=$((TOT + 1)); fi
    continue
  fi
  for p in $pids; do
    u=$(unit_of_pid "$p")
    if [ -n "$u" ] && [ -n "${UNITWHO[$u]:-}" ]; then who="${UNITWHO[$u]}"; else who="системный"; fi
    key="$who|$addr"
    if [ -z "${SOCK_SEEN[$key]:-}" ]; then
      SOCK_SEEN[$key]=1; TOT=$((TOT + 1))
      if [ "$who" = "системный" ]; then SYS_SOCK=$((SYS_SOCK + 1));
      else PERLBL[$who]=$(( ${PERLBL[$who]:-0} + 1 )); fi
    fi
  done
done < <({ ss -tlnpH 2>/dev/null || true; ss -ulnpH 2>/dev/null || true; })
echo "уникальных слушающих сокетов: всего $TOT (один порт на разных адресах считается дважды — оценка сверху)"
echo "из них системные/без процесса: $SYS_SOCK"
for k in "${!KEYLBL[@]}"; do echo "из них ${KEYLBL[$k]}: ${PERLBL[${KEYLBL[$k]}]:-0}"; done
for n in $(seq 1 "$NOBIND"); do echo "из них без-привязки-№$n: ${PERLBL[без-привязки-№$n]:-0}"; done

echo "=== 6. таймеры (штатные — именем, остальные хэшем; колонка ACTIVATES тоже чистится) ==="
systemctl list-timers --no-legend --no-pager --plain 2>/dev/null | while IFS= read -r line; do
  [ -n "$line" ] || continue
  clean="$line"
  for tok in $(printf '%s' "$line" | grep -oE '[A-Za-z0-9_@.:-]+\.(timer|service)' || true); do
    base=${tok%.*}
    case "$base" in
      apt-daily|apt-daily-upgrade|logrotate|fstrim|motd-news|dpkg-db-backup|man-db|systemd-tmpfiles-clean|certbot|e2scrub_all|ct-preset-deb) rep="$tok" ;;
      *) rep="скрыт-<$(tag "$tok")>" ;;
    esac
    esc=${tok//./\\.}
    clean=$(printf '%s' "$clean" | sed "s/$esc/$rep/g")
  done
  echo "$clean"
done

echo "=== 7. кроны (расписания + argv0; значений env нет) ==="
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  cron=$($SUDO crontab -u "$l" -l 2>/dev/null || true)
  if [ -z "$cron" ]; then echo "крон дома: недоступен или пуст"; continue; fi
  echo "крон дома: строк $(printf '%s' "$cron" | grep -cv '^[[:space:]]*\(#\|$\)')"
  printf '%s' "$cron" | grep -v '^[[:space:]]*\(#\|$\)' | while IFS= read -r job; do
    if [[ "$job" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then echo "  env-строка (значение скрыто)"; continue; fi
    sched=$(printf '%s' "$job" | awk '{print $1, $2, $3, $4, $5}')
    cmd0=$(printf '%s' "$job" | awk '{print $6}')
    echo "  $sched | <$(basename "$cmd0")>"
  done
done
echo "файлов в /etc/cron.d: $(ls /etc/cron.d 2>/dev/null | wc -l) (имена не печатаем)"

echo "=== 8. дома: вес по подкаталогам и категории (имена наружу не выходят) ==="
hum() { awk -v kb="$1" 'BEGIN { if (kb >= 1048576) printf "%.1f ГБ", kb/1048576; else if (kb >= 1024) printf "%.1f МБ", kb/1024; else printf "%d КБ", kb }'; }
NOW=$(date +%s)
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  total=$($SUDO timeout 300 du -sk "/home/$l" 2>/dev/null | cut -f1 || true)
  if [ -z "$total" ]; then echo "дом: недоступен (нужен доступ)"; continue; fi
  links=$($SUDO find "/home/$l" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l)
  echo "дом: всего $(hum "$total"), симлинков верхнего уровня: $links (симлинк на каталог считается дважды — категории ниже оценка сверху)"
  while IFS= read -r -d '' sub; do
    base=$(basename "$sub")
    stag="под-$(tag "$sub")"
    key="${SUBKEY[$stag]:-}"
    lbl="?"
    if [ -n "$key" ] && [ -n "${KEYLBL[$key]:-}" ]; then lbl="${KEYLBL[$key]}"; fi
    units_here=${KEYN[$key]:-0}
    sz=$($SUDO timeout 120 du -sk "$sub" 2>/dev/null | cut -f1 || true)
    [ -n "$sz" ] || { echo "$stag ($lbl): недоступен"; continue; }
    age="н/д"
    mt=$($SUDO stat -c %Y "$sub" 2>/dev/null || true)
    [ -n "$mt" ] && age="$(( (NOW - mt) / 86400 )) дн"
    rel=0; med=0; code=0; dep=0; bak=0; rest=0; denied=0
    while IFS= read -r -d '' d2; do
      s2=$($SUDO timeout 120 du -sk "$d2" 2>/dev/null | cut -f1 || true)
      [ -n "$s2" ] || { denied=$((denied + 1)); continue; }
      low=$(basename "$d2" | tr '[:upper:]' '[:lower:]')
      case "$low" in
        releases*|release*|current) rel=$((rel + s2)) ;;
        media|uploads|upload|public|storage|static|files|images|img|assets|data) med=$((med + s2)) ;;
        repo*|checkout*|.git|src|app|www|site) code=$((code + s2)) ;;
        node_modules|.npm|.pnpm*|.cache|vendor|.bundle) dep=$((dep + s2)) ;;
        backup*|dump*|*.sql|*.dump) bak=$((bak + s2)) ;;
        *) rest=$((rest + s2)) ;;
      esac
    done < <($SUDO find "$sub" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    echo "$stag ($lbl, юнитов здесь: $units_here, возраст: $age): всего $(hum "$sz") | релизы $(hum $rel) | медиа+данные $(hum $med) | код $(hum $code) | зависимости+кэши $(hum $dep) | бэкапы $(hum $bak) | прочее $(hum $rest) | недоступно: $denied"
  done < <($SUDO find "/home/$l" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
done

echo "=== 8б. корни вне /home (только FHS-имена и числа) ==="
for r in /srv /var/www /opt /root /data /app; do
  if [ -d "$r" ]; then
    t=$($SUDO timeout 120 du -sk "$r" 2>/dev/null | cut -f1 || true)
    n=$($SUDO find "$r" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l || true)
    echo "корень $r: ${t:-недоступен} КБ, записей верхнего уровня: ${n:-н/д}"
  else
    echo "корня $r нет"
  fi
done

echo "=== 9. PostgreSQL: версия, базы, фичи 17 (имена баз наружу не выходят) ==="
q() { $SUDO -u postgres psql -Atqc "$1" 2>/dev/null || true; }
# Владелец базы -> ключ жильца: сравнение без учёта регистра с именами
# подкаталогов и логинов (всё внутреннее, печатается только метка).
key_of_owner() {
  local o="$1" lo s l
  lo=$(printf '%s' "$o" | tr '[:upper:]' '[:lower:]')
  [ -n "$lo" ] || return 1
  for s in ${SUBNAMES[@]+"${SUBNAMES[@]}"}; do
    if [ "$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')" = "$lo" ]; then
      for stag in "${!SUBKEY[@]}"; do
        skl=$(printf '%s' "${SUBKEY[$stag]}" | tr '[:upper:]' '[:lower:]')
        if [ "$skl" = "$lo" ] || [[ "$skl" == */"$lo" ]]; then
          printf '%s' "${KEYLBL[${SUBKEY[$stag]}]}"; return 0
        fi
      done
    fi
  done
  for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
    if [ "$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')" = "$lo" ] && [ -n "${KEYLBL[$l]:-}" ]; then
      printf '%s' "${KEYLBL[$l]}"; return 0
    fi
  done
  return 1
}
if [ -z "$SUDO" ]; then echo "NOTE: postgres недоступен без sudo — раздел пропущен"; else
  VER=$(q "SHOW server_version;")
  [ -n "$VER" ] || echo "NOTE: psql не отвечает — остаток раздела пропущен"
  if [ -n "$VER" ]; then
    echo "версия: $VER"
    echo "суммарный вес всех баз: $(q "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE NOT datistemplate AND datallowconn;")"
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
      if dblbl=$(key_of_owner "$owner"); then :; else dblbl="бд-<$(tag "$db")>"; fi
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
    [ -n "$OUR_DB" ] || echo "NOTE: своя база не опознана — все строки обезличены"
  fi
fi

echo "=== 10. зависимости и доступ (только факты наличия) ==="
echo "процессов всего: $(ps -e --no-headers 2>/dev/null | wc -l)"
echo "юнитов по маске консольного сервиса хостера из разбора 09-11: $(systemctl list-units --no-legend --no-pager --plain 2>/dev/null | grep -c vzfifo || true)"
echo "сторонних туннелей/агентов в процессах: проверка — только штатные классы (systemd, sshd, nginx, postgres, cron, node-приложения жильцов)"
ss -s 2>/dev/null | head -8 || true
echo "NOTE: наша цепочка — прямой ssh по ключу (jump-host нет: workflows идут на TARGET напрямую, ProxyJump нигде не задан — факт репозитория). Чужие цепочки изнутри бокса не проверяли (потребовало бы чтения чужих конфигов)."

echo "=== 11. припаркованный (без юнита и без процессов) ==="
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  procs=$(ps -o user= 2>/dev/null | awk -v u="$l" '$1==u' | wc -l)
  if [ "$procs" -eq 0 ]; then echo "логин без процессов — кандидат в припаркованные (ключи ниже точнее)"; fi
done
for stag in "${!SUBKEY[@]}"; do
  key="${SUBKEY[$stag]}"
  if [ "${KEYN[$key]:-0}" -eq 0 ] && [ "${KEYLBL[$key]}" != "наш" ]; then
    echo "кандидат в припаркованные: $stag (${KEYLBL[$key]}, юнитов здесь: 0 — вес в разделе 8, база в разделе 9 по владельцу)"
  fi
done
echo "=== конец описи ==="
