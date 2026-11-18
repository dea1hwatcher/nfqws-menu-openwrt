# kvn 0.0.2 — установка (заменяет keenkit-vpn, его настройки переносятся)
cat > /opt/bin/kvn <<'KVNEOF'
#!/bin/sh
# kvn (KeenVPN) — запуск KeenKit через VPN-интерфейс с раздельными OTA-источниками:
#   п.5 OTA Update (прошивки) -> FW_DOMAIN (Афина)
#   п.8 KeenBOOT OTA Update    -> KB_BASE   (Стас)
# KeenKit не модифицируется: подменяется только curl через PATH (переживает обновления KeenKit).
#
# Использование:
#   kvn              автовыбор рабочего интерфейса из IFACES и запуск KeenKit
#   kvn nwg1         запуск через указанный интерфейс
#   kvn check        проверка каналов и источников
#   kvn uninstall    удалить kvn
# Настройки: /opt/etc/kvn.conf (создаётся при первом запуске)

VERSION="0.0.2"
CONF="/opt/etc/kvn.conf"
WRAP_DIR="/opt/lib/kvn"
KK_SCRIPT="/opt/keenkit.sh"
KK_CONF="/opt/etc/KeenKit.conf"
REAL_CURL="/opt/bin/curl"
NET_DIR="/sys/class/net"

# Значения по умолчанию (переопределяются в $CONF)
IFACES="nwg0 nwg1 nwg2"
FW_DOMAIN="https://osvault.project-athens.com"
FW_LABEL="Афина"
KB_BASE="https://spatiumstas.github.io/KeenKit"
KB_LABEL="Стас"
PROBE_URL="https://spatiumstas.github.io/KeenKit/"

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

msg() { printf "${CYAN}%s${NC}\n" "$*" >&2; }
warn() { printf "${YELLOW}%s${NC}\n" "$*" >&2; }
die() {
  printf "${RED}%s${NC}\n" "$*" >&2
  exit 1
}

write_default_conf() {
  mkdir -p "${CONF%/*}" || die "Не удалось создать ${CONF%/*}"
  cat >"$CONF" <<EOF
# kvn: интерфейсы проверяются по порядку, используется первый рабочий
IFACES="$IFACES"
# п.5 OTA Update — прошивки
FW_DOMAIN="$FW_DOMAIN"
FW_LABEL="$FW_LABEL"
# п.8 KeenBOOT OTA Update — загрузчики
KB_BASE="$KB_BASE"
KB_LABEL="$KB_LABEL"
# адрес для проверки работоспособности интерфейса
PROBE_URL="$PROBE_URL"
EOF
  chmod 600 "$CONF"
}

valid_url() {
  case "$1" in
  https://*/ | *[!A-Za-z0-9.:/_-]*) return 1 ;;
  https://?*) return 0 ;;
  *) return 1 ;;
  esac
}

valid_iface() {
  case "$1" in
  "" | *[!A-Za-z0-9_.-]*) return 1 ;;
  *) [ -d "$NET_DIR/$1" ] ;;
  esac
}

load_conf() {
  [ -f "$CONF" ] || write_default_conf
  # shellcheck source=/dev/null
  . "$CONF" || die "Ошибка чтения $CONF"
  valid_url "$FW_DOMAIN" || die "FW_DOMAIN: нужен https://хост без / в конце ($FW_DOMAIN)"
  valid_url "$KB_BASE" || die "KB_BASE: нужен https://хост[/путь] без / в конце ($KB_BASE)"
  case "$PROBE_URL" in https://?*) ;; *) die "PROBE_URL должен начинаться с https://" ;; esac
  [ -n "$IFACES" ] || die "IFACES пуст"
}

check_deps() {
  [ -x "$REAL_CURL" ] || die "Нет $REAL_CURL (opkg install curl)"
  [ -f "$KK_SCRIPT" ] || die "KeenKit не установлен ($KK_SCRIPT)"
}

list_ifaces() {
  for f in "$NET_DIR"/*; do printf '%s ' "${f##*/}"; done
}

probe_iface() {
  "$REAL_CURL" --interface "$1" -fsS -m 8 -o /dev/null "$PROBE_URL" >/dev/null 2>&1
}

# Первый интерфейс из IFACES, через который доступен PROBE_URL. Отсутствующие пропускаются молча.
pick_iface() {
  for i in $IFACES; do
    valid_iface "$i" || continue
    if probe_iface "$i"; then
      echo "$i"
      return 0
    fi
    warn "$i: нет доступа к GitHub"
  done
  return 1
}

write_wrapper() {
  mkdir -p "$WRAP_DIR" || die "Не удалось создать $WRAP_DIR"
  cat >"$WRAP_DIR/curl.tmp" <<'WRAP'
#!/bin/sh
# Сгенерировано kvn, изменения будут перезаписаны.
# Внешние запросы -> через $KK_IFACE; $KK_FW/files/keenboot/* -> $KK_KB/files/keenboot/*;
# локальный RCI (127.0.0.1/localhost) -> напрямую.
REAL=/opt/bin/curl
[ -n "${KK_IFACE:-}" ] || exec "$REAL" "$@"
local_call=0
n=$#
for arg do
  case "$arg" in
  http://127.0.0.1[:/]* | http://localhost[:/]*) local_call=1 ;;
  esac
  if [ -n "${KK_FW:-}" ] && [ -n "${KK_KB:-}" ]; then
    case "$arg" in
    "$KK_FW/files/keenboot" | "$KK_FW/files/keenboot/"*) arg="$KK_KB${arg#"$KK_FW"}" ;;
    esac
  fi
  set -- "$@" "$arg"
done
shift "$n"
[ "$local_call" = 1 ] && exec "$REAL" "$@"
exec "$REAL" --interface "$KK_IFACE" "$@"
WRAP
  if ! { chmod 755 "$WRAP_DIR/curl.tmp" && mv -f "$WRAP_DIR/curl.tmp" "$WRAP_DIR/curl"; }; then
    die "Не удалось записать $WRAP_DIR/curl"
  fi
}

kk_domain() {
  sed -n 's/^domain="\([^"]*\)"$/\1/p' "$KK_CONF" 2>/dev/null
}

set_kk_domain() {
  [ "$(kk_domain)" = "$FW_DOMAIN" ] && return 0
  if ! { mkdir -p "${KK_CONF%/*}" && printf 'domain="%s"\n' "$FW_DOMAIN" >"$KK_CONF"; }; then
    die "Не удалось записать $KK_CONF"
  fi
}

cmd_run() {
  check_deps
  if [ -n "$1" ]; then
    valid_iface "$1" || die "Интерфейс $1 не найден. Есть: $(list_ifaces)"
    IFACES="$1"
  fi
  iface=$(pick_iface) || die "Нет рабочего интерфейса ($IFACES). Проверка: kvn check"
  write_wrapper
  set_kk_domain
  printf "${CYAN}Прошивки:${NC} ${GREEN}%s${NC}  ${CYAN}KeenBOOT:${NC} ${GREEN}%s${NC}  ${CYAN}Интерфейс:${NC} ${GREEN}%s${NC}\n" \
    "$FW_LABEL" "$KB_LABEL" "$iface"
  KK_IFACE="$iface" KK_FW="$FW_DOMAIN" KK_KB="$KB_BASE" PATH="$WRAP_DIR:$PATH" \
    exec sh "$KK_SCRIPT"
}

http_code() {
  "$REAL_CURL" "$@" -sS -m 10 -o /dev/null -w '%{http_code}' 2>/dev/null || true
}

status() {
  case "$1" in
  2??) printf '%bOK%b' "$GREEN" "$NC" ;;
  000 | "") printf '%bнет%b' "$RED" "$NC" ;;
  *) printf "${RED}%s${NC}" "$1" ;;
  esac
}

# check_row <имя> [параметры curl] — IP выхода и доступность источников через канал
check_row() {
  name="$1"
  shift
  ip=$("$REAL_CURL" "$@" -fsS -m 10 https://api.ipify.org 2>/dev/null) || ip="нет связи"
  printf "%s (%s): KeenBOOT " "$name" "$ip"
  status "$(http_code "$@" "$PROBE_URL")"
  printf ", прошивки "
  status "$(http_code "$@" "$FW_DOMAIN/osvault/")"
  printf '\n'
}

cmd_check() {
  [ -x "$REAL_CURL" ] || die "Нет $REAL_CURL"
  printf "${CYAN}kvn %s${NC}\n" "$VERSION"
  printf "Прошивки (%s): %s\n" "$FW_LABEL" "$FW_DOMAIN"
  printf "KeenBOOT (%s):   %s\n" "$KB_LABEL" "$KB_BASE"
  if [ "$(kk_domain)" = "$FW_DOMAIN" ]; then
    printf 'KeenKit.conf:     %bOK%b\n' "$GREEN" "$NC"
  else
    printf "KeenKit.conf:     ${YELLOW}%s${NC} (исправится при запуске kvn)\n" "$(kk_domain | grep . || echo 'не задан')"
  fi
  printf '\n'
  check_row "напрямую"
  for i in $IFACES; do
    valid_iface "$i" && check_row "$i" --interface "$i"
  done
  return 0
}

cmd_uninstall() {
  printf "Удалить kvn (%s, %s, %s)? (y/n) " "$WRAP_DIR" "$CONF" "$0"
  read -r answer || exit 1
  case "$answer" in
  y | Y)
    rm -rf "$WRAP_DIR" "$CONF" && rm -f "$0" &&
      printf '%bУдалено. KeenKit.conf не тронут.%b\n' "$GREEN" "$NC"
    ;;
  *) msg "Отменено" ;;
  esac
}

case "${1:-}" in
-h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
-V | --version) echo "$VERSION" ;;
check) load_conf && cmd_check ;;
uninstall) cmd_uninstall ;;
"") load_conf && cmd_run "" ;;
-*) die "Неизвестный параметр: $1 (kvn --help)" ;;
*) load_conf && cmd_run "$1" ;;
esac
KVNEOF
chmod 755 /opt/bin/kvn
if [ -f /opt/etc/keenkit-vpn.conf ] && [ ! -f /opt/etc/kvn.conf ]; then mv /opt/etc/keenkit-vpn.conf /opt/etc/kvn.conf; fi
rm -rf /opt/lib/keenkit-vpn /opt/bin/keenkit-vpn /opt/etc/keenkit-vpn.conf
kvn check
