#!/usr/bin/env bash
# Карта «порт → жилец» для записки PORT_MAP в комнату КАРМАНа (D-102).
# Выполняется НА СЕРВЕРЕ через ssh на stdin (мандат D-046).
#
# Печатает РОВНО один JSON-объект: {"<порт>": "<метка>"}, где метка — «наш»,
# «сосед-N» или «системный». Метки те же, что в описи D-117 (PR #175/#176):
# наш юнит узнаётся по подкаталогу дома из его WorkingDirectory/ExecStart (на
# общем боксе ключ жильца — путь, а не логин), соседи нумеруются по хэшу ключа
# и потому стабильны между прогонами. Чужих имён, путей и адресов наружу нет.
#
# ⚠️ Порты — recon (AGENTS.md, D-038). Поэтому вызывающий workflow ловит stdout
# этого скрипта В ПЕРЕМЕННУЮ и пишет её прямо в комнату КАРМАНа; в публичный лог
# значения не попадают — там только счётчики по меткам. Диагностики у скрипта нет
# намеренно: любой текст в stdout стал бы портами или именами.
#
# Только чтение: systemctl show/list-units, ss, /proc, ls/find по домам.
# Аргументы: <имя нашей службы> (значением секрета; в лог попадает только замена).
#
# ⚠️ Стандартный `ss` показывает процесс сокета только для своих процессов;
# на общем боксе жильцы делят один системный логин, поэтому сокеты приложений
# видны, а системные (не наши) — нет.

set -euo pipefail

SVC="${1:?не задана наша служба}"

# Короткая необратимая метка (детерминирована, стабильна между прогонами).
tag() { printf '%s' "$1" | sha256sum | cut -c1-6; }

SUDO=""
if sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

# --- ключи жильцов: подкаталоги домов (тот же разбор, что в описи D-117) ---
mapfile -t LOGINS < <(ls -A /home 2>/dev/null || true)

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

# Жильцы копятся плоским списком, а не обходом ключей ассоциативного массива:
# `${!ARR[@]+...}` bash разбирает как косвенное раскрытие значений и падает
# («invalid variable name») — проверено на bash 5.3.
declare -A KEYLBL HASSUB
RESIDENTS=()
OUR_KEY=""
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  while IFS= read -r -d '' sub; do
    base=$(basename "$sub")
    key="$l/$base"
    HASSUB[$l]=1
    RESIDENTS+=("$key")
    if [ -n "$OUR_LOGIN" ] && [ "$l" = "$OUR_LOGIN" ] && [ -n "$OUR_SUB" ] && [ "$base" = "$OUR_SUB" ]; then
      OUR_KEY="$key"; KEYLBL[$key]="наш"
    fi
  done < <($SUDO find "/home/$l" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  if [ -n "$OUR_LOGIN" ] && [ "$l" = "$OUR_LOGIN" ] && [ -z "$OUR_KEY" ]; then
    OUR_KEY="$l"; KEYLBL[$l]="наш"
  fi
done

# Соседи: подкаталоги домов; логин без подкаталогов — жилец сам по себе.
OTHERS=()
for k in ${RESIDENTS[@]+"${RESIDENTS[@]}"}; do
  [ "$k" = "$OUR_KEY" ] || OTHERS+=("$k")
done
for l in ${LOGINS[@]+"${LOGINS[@]}"}; do
  [ "$l" = "$OUR_KEY" ] && continue
  [ -n "${HASSUB[$l]:-}" ] && continue
  OTHERS+=("$l")
done
SORTED=()
if [ "${#OTHERS[@]}" -gt 0 ]; then
  while IFS= read -r line; do SORTED+=("$line"); done < <(
    for k in "${OTHERS[@]}"; do printf '%s\t%s\n' "$(tag "$k")" "$k"; done | LC_ALL=C sort | cut -f2-
  )
fi
i=0
for k in ${SORTED[@]+"${SORTED[@]}"}; do i=$((i + 1)); KEYLBL[$k]="сосед-$i"; done

# --- чей юнит ---
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

declare -A UNITWHO
if [ -n "$OUR_KEY" ]; then UNITWHO["$SVC"]="${KEYLBL[$OUR_KEY]}"; else UNITWHO["$SVC"]="наш"; fi
nobind=0
for u in $(systemctl list-units --type=service --state=running --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}'); do
  [ "$u" = "$SVC" ] && continue
  who="$(who_of_unit "$u")"
  if [ "$who" = "без-привязки" ]; then nobind=$((nobind + 1)); who="без-привязки-№$nobind"; fi
  UNITWHO["$u"]="$who"
done

# --- сокеты: порт → метка ---
# ss -lntpH: State Recv-Q Send-Q Local Peer [users:(("имя",pid=N,fd=M))]; Local — 4-е поле.
declare -A PORTLBL
PKEYS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  addr=$(printf '%s' "$line" | awk '{print $4}')
  port="${addr##*:}"
  [ -n "$port" ] || continue
  pids=$(printf '%s' "$line" | grep -o 'pid=[0-9]\+' | cut -d= -f2 || true)
  lbl="системный"
  if [ -n "$pids" ]; then
    for p in $pids; do
      u=$(unit_of_pid "$p")
      if [ -n "$u" ] && [ -n "${UNITWHO[$u]:-}" ]; then lbl="${UNITWHO[$u]}"; break; fi
    done
  fi
  if [ -z "${PORTLBL[$port]:-}" ]; then
    PKEYS+=("$port"); PORTLBL[$port]="$lbl"
  elif [ "${PORTLBL[$port]}" != "$lbl" ]; then
    PORTLBL[$port]="${PORTLBL[$port]}+$lbl"
  fi
done < <({ ss -tlnpH 2>/dev/null || true; ss -ulnpH 2>/dev/null || true; })

# --- JSON (порты по возрастанию; метки — только наши + хэши) ---
out=""; first=1
for p in $(printf '%s\n' ${PKEYS[@]+"${PKEYS[@]}"} | LC_ALL=C sort -n); do
  [ -n "$p" ] || continue
  if [ "$first" = 1 ]; then first=0; else out="$out,"; fi
  out="$out\"$p\":\"${PORTLBL[$p]}\""
done
printf '{%s}\n' "$out"
