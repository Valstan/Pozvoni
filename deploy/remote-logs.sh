#!/usr/bin/env bash
# Чтение журнала службы на боксе (инцидент 2026-10-08: прод лежал, рук на боксе
# у проекта не было — только через чужой доступ).
#
# Что делает: состояние юнита, журнал службы (хвост, ОКНО по времени или ПОИСК
# по содержимому), события юнита, память и следы OOM, здоровье journald.
# Выполняется НА СЕРВЕРЕ, через ssh на stdin — как остальные удалённые скрипты
# (мандат D-046).
#
# Recon-безопасность (AGENTS.md, D-038: репозиторий и логи прогонов публичны).
# Журнал systemd содержит имя бокса, а сообщения — имя службы, пути, адреса и
# имена системных пользователей. Всё это вычищается потоковым sed ДО печати:
# имя службы — значением аргумента, имя ssh-пользователя — значением
# --redact-user (в лог попадает только замена), имя бокса — первое поле строки
# журнала, IPv4, домашние и серверные пути — регулярками. ⚠️ Поиск (--grep)
# идёт по ВСЕМУ журналу и может задеть чужие сообщения — шаблон выбирай узкий.
#
# Аргументы: <имя службы> <строк журнала> [--since=<когда>] [--until=<когда>]
#            [--grep=<шаблон>] [--redact-user=<имя>]
#
# Про время и поиск (урок разбора инцидента 08.10). Индексы journald могут не
# видеть часть записей: выборка по времени возвращает пусто там, где записи
# есть, а `-n` отдаёт хвост не того месяца. Поэтому режимов три:
#   * без окна и поиска — хвост журнала службы (как раньше);
#   * --since/--until — окно по времени, значение С ЯВНОЙ зоной (бокс живёт на
#     Europe/Moscow, а инциденты в письмах — в UTC; пример: 2026-10-08T06:25:00Z);
#   * --grep — поиск по содержимому всего журнала (PCRE): --grep читает файлы
#     журнала напрямую и находит записи, до которых не доводит индекс; вывод
#     сортируется по метке времени (порядок обхода файлов не хронологичен —
#     хвост без сортировки отрезал бы самые свежие совпадения).
# Окно и поиск можно совмещать; поиск тогда ограничен окном.
#
# ⚠️ Диагностика печатается в stdout, а не в stderr: вызывающий workflow глушит
# stderr клиента ssh целиком (маскировка GitHub ловит только полное значение
# секрета, а ssh при отказе печатает хост и порт отдельными словами).

set -euo pipefail

SERVICE="${1:?не задана служба}"
LINES="${2:-100}"
if [ $# -gt 2 ]; then shift 2; else shift "$#"; fi

SINCE=""
UNTIL=""
GREP=""
REDACT_USER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since=*)       SINCE="${1#--since=}" ;;
    --until=*)       UNTIL="${1#--until=}" ;;
    --grep=*)        GREP="${1#--grep=}" ;;
    --redact-user=*) REDACT_USER="${1#--redact-user=}" ;;
    *) echo "неизвестный аргумент — ждём --since=/--until=/--grep=/--redact-user="; exit 1 ;;
  esac
  shift
done

case "$LINES" in
  ''|*[!0-9]*) echo "число строк — только цифры"; exit 1 ;;
esac
if [ "$LINES" -gt 500 ]; then
  echo "больше 500 строк за раз не отдаём"
  exit 1
fi
for v in "$SINCE" "$UNTIL" "$GREP" "$REDACT_USER"; do
  if [ "${#v}" -gt 120 ]; then
    echo "значение окна/поиска/редакции длиннее 120 символов — не берём"
    exit 1
  fi
done

# Подстановка окна: ${SINCE:+"--since=$SINCE"} — пустое значение исчезает
# целиком, непустое остаётся ОДНИМ словом даже с пробелами внутри (кавычки
# внутри ${...:+...} защищают от разбиения). Идиому "${A[@]+"${A[@]}"}"
# с вложенными кавычками не берём: на ней уже ловили ошибку разбора.

# Редакция потока: имя службы, имя ssh-пользователя, имя бокса (первое поле
# после метки времени — формат journalctl и syslog), IPv4, домашние и серверные
# пути. Порядок важен: сначала служба (её имя может содержать точки, как у
# адреса), потом остальное.
redact() {
  local sed_args=(-e "s/${SERVICE}/<служба>/g")
  if [ -n "$REDACT_USER" ]; then
    sed_args+=(-e "s/\\b${REDACT_USER}\\b/<пользователь>/g")
  fi
  sed_args+=(
    -e 's/^([A-Z][a-z]{2} +[0-9]+ [0-9:]+) [^ ]+ /\1 <бокс> /'
    -e 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+) [^ ]+ /\1 <бокс> /'
    -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g'
    -e 's#(/home|/opt|/srv)/[^ :]*#<путь>#g'
  )
  sed -E "${sed_args[@]}"
}

# Чтение журнала в файл с показом последних строк. Три тонкости:
#   * <plain|sorted> — сортировать ли вывод по метке времени (для --grep,
#     потому что порядок обхода файлов журнала не хронологичен);
#   * journalctl отдаёт код 1, когда --grep не нашёл ни строки, — это не
#     ошибка, а честное «записей нет»;
#   * настоящие ошибки короткие, но их текст печатаем (обезвреженным): иначе
#     «выборка не выполнилась» без причины.
show_journal() { # <plain|sorted> <строк> <аргументы journalctl...>
  local mode="$1" limit="$2"
  shift 2
  local out err rc=0
  out=$(mktemp 2>/dev/null) || out=""
  err=$(mktemp 2>/dev/null) || err=""
  if [ -z "$out" ] || [ -z "$err" ]; then
    echo "не удалось создать временный файл для выборки журнала"
    if [ -n "$out" ]; then rm -f "$out"; fi
    if [ -n "$err" ]; then rm -f "$err"; fi
    return 0
  fi
  journalctl --no-pager -o short-iso "$@" > "$out" 2> "$err" || rc=$?
  # Постоянный шум stderr journalctl для не-рута («ты не видишь сообщения
  # системы») — подсказка о группах, а не ошибка выборки: файлы журнала
  # при этом читаются (улики в прогонах видно). В классификацию не берём.
  err_clean=$(grep -v -e "not seeing messages" -e "can see all messages" "$err" 2>/dev/null || true)
  if [ "$rc" = "0" ]; then
    if [ -s "$out" ]; then
      if [ "$mode" = "sorted" ]; then
        LC_ALL=C sort "$out" | tail -n "$limit" | redact
      else
        tail -n "$limit" "$out" | redact
      fi
    else
      echo "(записей нет)"
    fi
  elif [ "$rc" = "1" ] && [ ! -s "$out" ] && [ -z "$err_clean" ]; then
    echo "(записей нет)"
  else
    echo "выборка журнала не выполнилась (код $rc)"
    if [ -n "$err_clean" ]; then
      printf '%s\n' "$err_clean" | head -n 2 | redact || true
    fi
  fi
  rm -f "$out" "$err"
}

echo "=== состояние ==="
st=$(systemctl is-active "$SERVICE" 2>/dev/null || true)
echo "active: ${st:-неизвестно}"
st=$(systemctl is-failed "$SERVICE" 2>/dev/null || true)
echo "failed: ${st:-неизвестно}"
systemctl show "$SERVICE" -p ActiveState,SubState,Result,ExecMainStatus,NRestarts,ActiveEnterTimestamp,MemoryAccounting,MemoryCurrent,MemoryMax,MemoryPeak 2>/dev/null || true

if [ -n "$GREP" ]; then
  echo "=== поиск по журналу (весь журнал, --grep; PCRE; вывод по метке времени) ==="
  show_journal sorted 300 ${SINCE:+"--since=$SINCE"} ${UNTIL:+"--until=$UNTIL"} --grep "$GREP"
elif [ -n "$SINCE" ] || [ -n "$UNTIL" ]; then
  echo "=== журнал службы: окно ==="
  show_journal plain 300 -u "$SERVICE" ${SINCE:+"--since=$SINCE"} ${UNTIL:+"--until=$UNTIL"}
else
  echo "=== журнал службы ($LINES строк) ==="
  show_journal plain "$LINES" -u "$SERVICE" -n "$LINES"
fi

# События systemd по юниту (старты/остановки/коды выхода) живут НЕ в `-u`,
# а в системном журнале — без этого куска рестарт-crashloop не виден.
echo "=== события юнита в системном журнале ==="
{
  if [ -n "$SINCE" ] || [ -n "$UNTIL" ]; then
    journalctl --no-pager -o short-iso ${SINCE:+"--since=$SINCE"} ${UNTIL:+"--until=$UNTIL"} 2>/dev/null || true
  else
    journalctl --no-pager -o short-iso -n 600 2>/dev/null || true
  fi
} | grep -F "$SERVICE" | tail -n 80 | redact || echo "событий нет"

echo "=== память и OOM ==="
echo "-- OOM в журнале (текстовый поиск по всем файлам) --"
show_journal sorted 15 --grep '(?i)killed process|invoked oom|oom-kill|out of memory'
echo "-- OOM в кольце ядра (dmesg; живёт от последней загрузки) --"
if dmesg_out=$(dmesg -T 2>/dev/null); then
  printf '%s\n' "$dmesg_out" | grep -iE 'oom|killed process' | tail -n 5 | redact || echo "совпадений нет"
else
  echo "dmesg недоступен этому пользователю"
fi
echo "-- OOM в syslog/kern.log/messages (все ротации; kern.log и нужен для OOM) --"
syslog_files=$(ls -1r /var/log/syslog* /var/log/kern.log* /var/log/messages* 2>/dev/null || true)
if [ -n "$syslog_files" ]; then
  echo "-- список файлов: $(printf '%s ' $syslog_files)"
  syslog_matches=$( { for f in $syslog_files; do
      case "$f" in
        *.gz) zcat "$f" 2>/dev/null ;;
        *)    cat "$f" 2>/dev/null ;;
      esac
    done; } | grep -iE 'oom|killed process' || true )
  if [ -n "$syslog_matches" ]; then
    printf '%s\n' "$syslog_matches" | LC_ALL=C sort -M -k1,1 -k2,2n -k3,3 | tail -n 15 | redact
  else
    echo "совпадений нет"
  fi
else
  echo "syslog/kern.log/messages не найдены"
fi

echo "=== journald ==="
st=$(systemctl is-active systemd-journald 2>/dev/null || true)
echo "${st:-неизвестно}"
journalctl --disk-usage 2>/dev/null || true
echo "-- список загрузок (обрыв/пропуски — признак сломанного индекса) --"
journalctl --list-boots --no-pager 2>/dev/null | tail -n 5 | redact || true
