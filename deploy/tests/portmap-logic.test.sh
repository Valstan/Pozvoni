#!/usr/bin/env bash
# Логика `remote-portmap.sh` на подставных systemctl/ss//proc: настоящий снимок
# карты портов снять можно только на живом боксе, и второй раз — дорого. Здесь
# проверяются ровно три вещи, которые иначе всплыли бы уже на боксе:
#   1) порт узнаёт жильца через cgroup процесса («наш» / «сосед-N»);
#   2) чужой порт без процесса помечается «системный» и не течёт именами;
#   3) нумерация соседей стабильна между прогонами (хэш ключа, не порядок обхода).
# Порты, адреса и имена домов в этом файле — выдуманные, бокса не касаются.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/deploy/remote-portmap.sh"
[ -f "$SRC" ] || { echo "нет $SRC"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/home/appuser/ourproject" "$T/home/appuser/neighbour5" "$T/home/appuser/neighbour7"
mkdir -p "$T/proc/101" "$T/proc/202" "$T/proc/303" "$T/bin"

printf '11:memory:/system.slice/pozvoni.service\n'    > "$T/proc/101/cgroup"
printf '11:memory:/system.slice/neighbour5.service\n' > "$T/proc/202/cgroup"
printf '11:memory:/system.slice/neighbour7.service\n' > "$T/proc/303/cgroup"

cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "list-units" ]; then
  printf '%s\n' \
    "pozvoni.service loaded active running Pozvoni" \
    "neighbour5.service loaded active running Neighbour five" \
    "neighbour7.service loaded active running Neighbour seven"
  exit 0
fi
if [ "${1:-}" = "show" ]; then
  case "${2:-}" in
    pozvoni.service)    printf '%s\n' "$STUB_HOME/ourproject" ;;
    neighbour5.service) printf '%s\n' "$STUB_HOME/neighbour5" ;;
    neighbour7.service) printf '%s\n' "$STUB_HOME/neighbour7" ;;
  esac
  exit 0
fi
exit 0
STUB

cat > "$T/bin/ss" <<'STUB'
#!/usr/bin/env bash
# Порт без процесса (22, 53) и порты с процессом своего жильца (3000/8081/9091).
if [ "${1:-}" = "-tlnpH" ]; then
  cat <<'OUT'
LISTEN 0      4096               127.0.0.1:3000           0.0.0.0:*    users:(("node",pid=101,fd=20))
LISTEN 0      4096               127.0.0.1:8081           0.0.0.0:*    users:(("node",pid=202,fd=20))
LISTEN 0      4096                      *:9091                 *:*     users:(("uvicorn",pid=303,fd=11))
LISTEN 0       128                   0.0.0.0:22             0.0.0.0:*
LISTEN 0       128                 127.0.0.53:53            0.0.0.0:*
LISTEN 0       128                      [::]:22                 [::]:*
OUT
fi
exit 0
STUB
chmod +x "$T/bin/systemctl" "$T/bin/ss"

# Копия скрипта с подменой абсолютных путей домов и /proc (на раннере они не наши).
sed -e "s#/home#${T}/home#g" -e "s#/proc/#${T}/proc/#g" "$SRC" > "$T/portmap.sh"

run() { STUB_HOME="$T/home/appuser" PATH="$T/bin:$PATH" bash "$T/portmap.sh" pozvoni.service; }

run > "$T/out1.json"
run > "$T/out2.json"

check() {
  node -e '
const fs = require("fs");
const [f1, f2] = process.argv.slice(1);
const a = JSON.parse(fs.readFileSync(f1, "utf8"));
const b = JSON.parse(fs.readFileSync(f2, "utf8"));
const fail = (m) => { console.error("FAIL " + m); console.error("out1 " + JSON.stringify(a)); console.error("out2 " + JSON.stringify(b)); process.exit(1); };
if (JSON.stringify(a) !== JSON.stringify(b)) fail("карта не стабильна между прогонами");
const keys = Object.keys(a).sort((x, y) => x - y);
if (keys.join(",") !== "22,53,3000,8081,9091") fail("набор портов: " + keys.join(","));
if (a["3000"] !== "наш") fail("3000 -> " + a["3000"]);
if (a["22"] !== "системный" || a["53"] !== "системный") fail("системные помечены неверно");
const nb = [a["8081"], a["9091"]].sort();
if (nb.join(",") !== "сосед-1,сосед-2") fail("соседи: " + nb.join(","));
console.log("portmap: ок (5 портов, метки наш/сосед-N/системный, нумерация стабильна)");
' "$T/out1.json" "$T/out2.json"
}

check
