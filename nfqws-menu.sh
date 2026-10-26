#!/bin/sh
# nfqws-menu.sh — интерактивное меню установки/управления
# nfqws-keenetic / nfqws2-keenetic / nfqws-keenetic-web для OpenWrt
# Форк: https://github.com/Dea1hwa1cher/nfqws-menu-openwrt (адаптация nfqws-menu под OpenWrt)
# Апстрим: https://github.com/rndnaame/nfqws-menu
#
# Версионирование (MAJOR.MINOR.PATCH):
#   PATCH (+0.0.1) — небольшие правки
#   MINOR (+0.1.0) — средние изменения
#   MAJOR (+1.0.0) — критические изменения

set -e

SCRIPT_VERSION="0.1.7"

RAW_BASE="https://raw.githubusercontent.com/Dea1hwa1cher/nfqws-menu-openwrt/main"
STRATEGIES_API="https://api.github.com/repos/Dea1hwa1cher/nfqws-menu-openwrt/contents/strategies"

# Туннели для fallback-скачивания, если основной канал недоступен (DPI и т.п.)
# Порядок = приоритет. opkgtun0 / opgktun0 — резервные туннельные интерфейсы.
FALLBACK_IFACES="awg0 t2s0 nwg0 opkgtun0 opgktun0"

# Таймауты скачивания (сек). Чуть выше для сильного DPI, но не слишком —
# чтобы быстрее уходить на fallback/зеркало.
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=25
CURL_MAX_TIME_LARGE=180   # rkn.list ~2 МБ и подобные
WGET_TIMEOUT=20


# ---------------------------------------------------------------------------
# Цвета
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  ESC=$(printf '\033')
  RED="${ESC}[0;31m"
  GREEN="${ESC}[0;32m"
  YELLOW="${ESC}[1;33m"
  BLUE="${ESC}[0;34m"
  CYAN="${ESC}[0;36m"
  MAGENTA="${ESC}[0;35m"
  DIM="${ESC}[2m"
  NC="${ESC}[0m"
  BOLD="${ESC}[1m"
else
  RED= GREEN= YELLOW= BLUE= CYAN= MAGENTA= DIM= NC= BOLD=
fi

# ---------------------------------------------------------------------------
# Платформа и операционная система (OpenWrt / Linux)
# ---------------------------------------------------------------------------
ROUTER_OS=""        # openwrt | generic
ROUTER_OS_NAME=""   # OpenWrt, ImmortalWrt, Linux
ROUTER_OS_VER=""    # 24.10.1, 23.05.5, ...
ROUTER_MODEL=""     # Модель роутера
ROUTER_TITLE=""     # Версия/заголовок для строки меню
ROUTER_FW_TYPE="unknown"   # fw4 (nftables) | fw3 (iptables) | unknown
OS_HAS_NF_QUEUE=""  # 1=модули NFQUEUE есть/загружены, 0=нет, ""=не определено
OS_CHECKED=0
DISTRIB_ARCH_VAL=""

CONF_BASE_DIR="/etc"
INIT_BASE_DIR="/etc/init.d"
STATUS_FILE="/usr/lib/opkg/status"
OPKG_CONF_DIR="/etc/opkg"
APK_REPO_DIR="/etc/apk/repositories.d"
APK_KEYS_DIR="/etc/apk/keys"

detect_os() {
  [ "$OS_CHECKED" = "1" ] && return 0
  OS_CHECKED=1

  # 1) OpenWrt / ImmortalWrt / forks  2) Keenetic / Netcraze OS  3) Padavan
  # (комментарии между ветками elif ломают парсер busybox ash — не вставлять)
  if [ -f /etc/openwrt_release ] || [ -f /etc/openwrt_version ]; then
    ROUTER_OS="openwrt"
  elif [ -f /etc/os-release ] && grep -qiE 'ID(_LIKE)?=.*(openwrt|immortalwrt)' /etc/os-release 2>/dev/null; then
    ROUTER_OS="openwrt"
  elif command -v uci >/dev/null 2>&1 && [ -d /etc/config ]; then
    ROUTER_OS="openwrt"
  else
    ROUTER_OS="generic"
  fi

  case "$ROUTER_OS" in
    openwrt)
      local id release rev arch desc
      if [ -f /etc/openwrt_release ]; then
        id=$(sed -n "s/^DISTRIB_ID=['\"]\?\([^'\"]*\)['\"]\?/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
        release=$(sed -n "s/^DISTRIB_RELEASE=['\"]\?\([^'\"]*\)['\"]\?/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
        rev=$(sed -n "s/^DISTRIB_REVISION=['\"]\?\([^'\"]*\)['\"]\?/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
        arch=$(sed -n "s/^DISTRIB_ARCH=['\"]\?\([^'\"]*\)['\"]\?/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
        desc=$(sed -n "s/^DISTRIB_DESCRIPTION=['\"]\?\([^'\"]*\)['\"]\?/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
      fi
      ROUTER_OS_NAME="${id:-OpenWrt}"
      ROUTER_OS_VER="${release:-}"
      DISTRIB_ARCH_VAL="${arch:-}"
      if [ -n "$release" ]; then
        ROUTER_TITLE="$ROUTER_OS_NAME $release"
      elif [ -n "$rev" ]; then
        ROUTER_TITLE="$ROUTER_OS_NAME $rev"
      else
        ROUTER_TITLE="$ROUTER_OS_NAME"
      fi

      # Определение модели оборудования в OpenWrt
      if [ -f /tmp/sysinfo/model ]; then
        ROUTER_MODEL=$(cat /tmp/sysinfo/model 2>/dev/null | tr -d '\r\n')
      elif [ -f /proc/device-tree/model ]; then
        ROUTER_MODEL=$(tr -d '\0\r\n' < /proc/device-tree/model 2>/dev/null)
      elif command -v ubus >/dev/null 2>&1; then
        ROUTER_MODEL=$(ubus call system board 2>/dev/null | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      fi
      [ -z "$ROUTER_MODEL" ] && [ -n "$desc" ] && ROUTER_MODEL="$desc"
      [ -z "$ROUTER_MODEL" ] && ROUTER_MODEL="OpenWrt Device"

      # Определение подсистемы фаервола OpenWrt
      if [ -x /sbin/fw4 ] || command -v nft >/dev/null 2>&1; then
        ROUTER_FW_TYPE="fw4"
      elif [ -x /sbin/fw3 ] || command -v iptables >/dev/null 2>&1; then
        ROUTER_FW_TYPE="fw3"
      fi

      # Проверка наличия модулей NFQUEUE в ядре OpenWrt
      if lsmod 2>/dev/null | grep -qE 'nft_queue|xt_NFQUEUE|ipt_NFQUEUE|nfnetlink_queue'; then
        OS_HAS_NF_QUEUE=1
      elif [ -r /proc/net/netfilter/nfnetlink_queue ]; then
        OS_HAS_NF_QUEUE=1
      elif [ -r /usr/lib/opkg/status ] && grep -qE '^Package:[[:space:]]*kmod-(nft-queue|ipt-nfqueue)' /usr/lib/opkg/status 2>/dev/null; then
        OS_HAS_NF_QUEUE=1
      elif command -v apk >/dev/null 2>&1 && apk list --installed 2>/dev/null | grep -qE '^kmod-(nft-queue|ipt-nfqueue)-'; then
        OS_HAS_NF_QUEUE=1
      else
        OS_HAS_NF_QUEUE=0
      fi

      CONF_BASE_DIR="/etc"
      INIT_BASE_DIR="/etc/init.d"
      STATUS_FILE="/usr/lib/opkg/status"
      OPKG_CONF_DIR="/etc/opkg"
      ;;

    generic|*)
      ROUTER_OS="generic"
      ROUTER_OS_NAME="Linux"
      if [ -f /etc/os-release ]; then
        ROUTER_OS_NAME=$(sed -n "s/^NAME=['\"]\?\([^'\"]*\)['\"]\?/\1/p" /etc/os-release 2>/dev/null | head -1)
        ROUTER_OS_VER=$(sed -n "s/^VERSION_ID=['\"]\?\([^'\"]*\)['\"]\?/\1/p" /etc/os-release 2>/dev/null | head -1)
      fi
      ROUTER_TITLE="${ROUTER_OS_NAME}${ROUTER_OS_VER:+ $ROUTER_OS_VER}"
      ROUTER_MODEL=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || uname -n 2>/dev/null || echo "Linux Device")
      CONF_BASE_DIR="/etc"
      INIT_BASE_DIR="/etc/init.d"
      STATUS_FILE="/usr/lib/opkg/status"
      OPKG_CONF_DIR="/etc/opkg"
      ;;
  esac
}

detect_os

# ---------------------------------------------------------------------------
# Язык UI (${CONF_BASE_DIR}/nfqws-menu/nfqws-menu.lang, env NFQWS_MENU_LANG / NFQWS_MENU_UTF8)
# ---------------------------------------------------------------------------
UI_LANG_FILE="${CONF_BASE_DIR}/nfqws-menu/nfqws-menu.lang"
if [ ! -f "$UI_LANG_FILE" ] && [ -f "${CONF_BASE_DIR}/nfqws-menu.lang" ]; then
  mkdir -p "${CONF_BASE_DIR}/nfqws-menu" 2>/dev/null || true
  mv "${CONF_BASE_DIR}/nfqws-menu.lang" "$UI_LANG_FILE" 2>/dev/null || \
    cp "${CONF_BASE_DIR}/nfqws-menu.lang" "$UI_LANG_FILE" 2>/dev/null || true
fi

ui_detect_default_lang() {
  case "${NFQWS_MENU_LANG:-}" in
    ru|RU|utf8|UTF8) echo "ru"; return ;;
    en|EN|ascii|ASCII) echo "en"; return ;;
  esac
  case "${NFQWS_MENU_UTF8:-}" in
    1|yes|true|on|ON)  echo "ru"; return ;;
    0|no|false|off|OFF) echo "en"; return ;;
  esac
  if [ -f "$UI_LANG_FILE" ]; then
    case "$(cat "$UI_LANG_FILE" 2>/dev/null | tr -d ' \r\n')" in
      ru|RU) echo "ru"; return ;;
      en|EN) echo "en"; return ;;
    esac
  fi
  if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    echo "ru"; return
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) echo "ru"; return ;;
  esac
  echo "en"
}

ui_apply_lang() {
  UI_LANG="$1"
  case "$UI_LANG" in
    ru)
      UI_UTF8=1
      RUN_MARK=" ⚡"
      UPD_MARK=" ⭡"
      LBL_UPD_LEGEND="⭡ — доступна новая версия"
      LBL_INSTALLED="Установленные компоненты:"
      LBL_NONE="— ничего не установлено —"
      LBL_COMPONENTS="КОМПОНЕНТЫ"
      LBL_STRATEGIES="СТРАТЕГИИ / СПИСКИ"
      LBL_UTILS="УТИЛИТЫ"
      LBL_REMOVE="СЕРВИС"
      LBL_S1="Сжать bin/sbin (UPX)"
      LBL_S2="Сменить / проверить зеркала OpenWrt"
      LBL_S3="Починить базу OPKG (NUL/битый status)"
      LBL_U="Обновить все пакеты"
      LBL_1="Установка NFQWS / NFQWS2"
      LBL_3="Выбор стратегии"
      LBL_4="Обновить IPSet List"
      LBL_5="Загрузить rkn.list (125k+ доменов)"
      LBL_6="Обход блокировки DoT/DoH"
      LBL_7="Смена активных fake:blob"
      LBL_8="Обновление hosts"
      LBL_9="Управление DoT/DoH"
      LBL_88="Удаление пакетов"
      LBL_99="Обновить скрипт"
      LBL_00="Выход"
      LBL_PROMPT="Выберите пункт [Enter = выход]: "
      LBL_BACK="Нажмите Enter для возврата в меню..."
      LBL_MODEL="Модель:"
      LBL_LANG="Language: RU"
      LBL_INVALID="Неверный пункт меню"
      LBL_BACK_ITEM="Назад"
      LBL_YOUR_CHOICE="Ваш выбор"
      LBL_INSTALL_TITLE="Установка NFQWS / NFQWS2"
      LBL_INSTALL_DIRECT="Прямая установка .ipk / .apk (обход фида)"
      LBL_IPSET_WARN1="⚠ ОСТОРОЖНО"
      LBL_IPSET_WARN2="Вы собираетесь изменить ipset.list."
      LBL_IPSET_WARN3="Большой список CIDR от Flowseal (33K+) может нагрузить роутер"
      LBL_IPSET_WARN4="и поломать работу отдельных сервисов / сайтов."
      LBL_IPSET_OPT1="Загрузить IPSet от FlowSeal (33K+ CIDR)"
      LBL_IPSET_OPT2="Загрузить стандартный IPSet от nfqws-keenetic"
      ;;
    *)
      UI_LANG="en"
      UI_UTF8=0
      RUN_MARK=" *"
      UPD_MARK=" ⭡"
      LBL_UPD_LEGEND="⭡ — newer version available"
      LBL_INSTALLED="Installed components:"
      LBL_NONE="(none)"
      LBL_COMPONENTS="COMPONENTS"
      LBL_STRATEGIES="STRATEGIES / LISTS"
      LBL_UTILS="UTILITIES"
      LBL_REMOVE="SERVICE"
      LBL_S1="Compress bin/sbin (UPX)"
      LBL_S2="Switch / test OpenWrt repository mirrors"
      LBL_S3="Repair OPKG database (corrupt/NUL status)"
      LBL_U="Upgrade all packages"
      LBL_1="Install NFQWS / NFQWS2"
      LBL_3="Select strategy"
      LBL_4="Update IPSet list"
      LBL_5="Download rkn.list (125k+ domains)"
      LBL_6="Bypass DoT/DoH blocking"
      LBL_7="Switch active fake:blob"
      LBL_8="Update hosts file"
      LBL_9="Manage DoT/DoH DNS"
      LBL_88="Remove packages"
      LBL_99="Update this script"
      LBL_00="Exit"
      LBL_PROMPT="Select an option [Enter = exit]: "
      LBL_BACK="Press Enter to return to the menu..."
      LBL_MODEL="Model:"
      LBL_LANG="Language: EN"
      LBL_INVALID="Invalid menu option"
      LBL_BACK_ITEM="Back"
      LBL_YOUR_CHOICE="Your choice"
      LBL_INSTALL_TITLE="Install NFQWS / NFQWS2"
      LBL_INSTALL_DIRECT="Direct install .ipk / .apk (bypass feeds)"
      LBL_IPSET_WARN1="⚠ CAUTION"
      LBL_IPSET_WARN2="You are about to change ipset.list."
      LBL_IPSET_WARN3="A large Flowseal CIDR list (33K+) may load the router"
      LBL_IPSET_WARN4="and break some services / websites."
      LBL_IPSET_OPT1="Download IPSet from FlowSeal (33K+ CIDR)"
      LBL_IPSET_OPT2="Download standard IPSet from nfqws-keenetic"
      ;;
  esac
}

ui_apply_lang "$(ui_detect_default_lang)"

# --- Проверка новых версий: значения по умолчанию --------------------------
# Метки и подпись задаёт ui_apply_lang; здесь — только то, что нужно, если
# отрисовка случится до выбора языка.
: "${UPD_MARK:= ⭡}"
: "${LBL_UPD_LEGEND:=$UPD_MARK - a newer version is available}"
UPD_TTL="${NFQWS_MENU_UPDATE_TTL:-600}"   # 10 мин
UPD_REDRAW=0
UPD_JOB=""
MENU_PID=""

menu_change_language() {
  if [ "$UI_LANG" = "ru" ]; then
    ui_apply_lang "en"
  else
    ui_apply_lang "ru"
  fi
  mkdir -p "$(dirname "$UI_LANG_FILE")" 2>/dev/null || true
  echo "$UI_LANG" > "$UI_LANG_FILE" 2>/dev/null || true
}

info()  { printf '%s\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
error() { printf '%s\n' "${RED}[x]${NC} $*"; }
ask()   { printf '%s' "${CYAN}[?]${NC} $*"; }

# ---------------------------------------------------------------------------
# Общие хелперы
# ---------------------------------------------------------------------------

# Обычный read (без stty и без /dev/tty — иначе ломается Backspace у SSH-клиентов).
# Использование: read_menu varname
read_menu() {
  read -r "$1"
}

# Сбросить буфер stdin, чтобы «Enter» от установщика не проглатывал следующий read.
drain_stdin() {
  local _ds
  while read -r -t 0 _ds 2>/dev/null; do
    read -r _ds 2>/dev/null || break
  done
}

# confirm_yes: Y/n — да по умолчанию. confirm_no: y/N — нет по умолчанию.
confirm_yes() {
  ask "${1:-Continue?} [Y/n]: "
  # Ответ обнуляем перед чтением: если read не получит строки (конец ввода),
  # прежнее значение не должно означать «да» — иначе долгий подбор запускается
  # сам, а на экране при этом «[Y/n]: n».
  local ans=''
  read_menu ans || return 1
  case "$ans" in n|N|н|Н) return 1 ;; esac
  return 0
}

confirm_no() {
  ask "${1:-Continue?} [y/N]: "
  local ans=''
  read_menu ans
  case "$ans" in y|Y|д|Д) return 0 ;; esac
  return 1
}

pause_press_enter() {
  echo
  ask "${LBL_BACK:-Нажмите Enter для возврата в меню...}"
  read_menu _ || true
}

# Интерфейсы из FALLBACK_IFACES, которые есть в системе и не в состоянии down.
# WireGuard/Amnezia часто дают operstate=unknown — их тоже берём.
list_up_fallback_ifaces() {
  local iface oper
  for iface in $FALLBACK_IFACES; do
    [ -d "/sys/class/net/$iface" ] || continue
    oper=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo down)
    case "$oper" in
      down) continue ;;
    esac
    echo "$iface"
  done
}

# Локальный кэш загрузок (offline / при блокировке GitHub)
CACHE_DIR="${CONF_BASE_DIR}/nfqws-menu"

cache_strategy_path() {
  # $1=ver(1|2) $2=имя.conf или default
  local ver="$1" name="$2"
  echo "${CACHE_DIR}/strategies/nfqws${ver}/${name}"
}

save_strategy_cache() {
  # $1=ver $2=name $3=src_file
  local ver="$1" name="$2" src="$3" dest
  [ -f "$src" ] && [ -s "$src" ] || return 1
  dest=$(cache_strategy_path "$ver" "$name")
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  cp "$src" "$dest" 2>/dev/null || return 1
  return 0
}

list_strategies_from_cache() {
  local ver="$1" d
  d="${CACHE_DIR}/strategies/nfqws${ver}"
  [ -d "$d" ] || return 1
  # только *.conf, не default (его показываем отдельно)
  ls -1 "$d"/*.conf 2>/dev/null | while read -r f; do
    [ -f "$f" ] && [ -s "$f" ] || continue
    basename "$f"
  done
}

# Альтернативные URL для raw.githubusercontent.com / api.github.com (зеркала CDN).
# Печатает по одному URL на строку; исходный — первым.
github_alt_urls() {
  # Порядок: оригинал → CDN → ghproxy (мёртвый proxy не первым)
  local url="$1" rest owner repo ref path_rest

  case "$url" in
    https://raw.githubusercontent.com/*)
      rest="${url#https://raw.githubusercontent.com/}"
      owner="${rest%%/*}"; rest="${rest#*/}"
      repo="${rest%%/*}"; rest="${rest#*/}"
      ref="${rest%%/*}"; path_rest="${rest#*/}"
      if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$ref" ] && [ -n "$path_rest" ]; then
        case "$ref" in
          refs/heads/*) ref="${ref#refs/heads/}" ;;
          refs/tags/*)  ref="${ref#refs/tags/}" ;;
        esac
        printf '%s\n' "https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${path_rest}"
        printf '%s\n' "https://fastly.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path_rest}"
        printf '%s\n' "https://cdn.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path_rest}"
        printf '%s\n' "https://ghproxy.net/https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${path_rest}"
        return 0
      fi
      ;;
    https://api.github.com/*)
      printf '%s\n' "$url"
      printf '%s\n' "https://ghproxy.net/${url}"
      return 0
      ;;
    https://github.com/*/releases/download/*)
      printf '%s\n' "$url"
      printf '%s\n' "https://ghproxy.net/${url}"
      return 0
      ;;
    https://*.github.io/*|http://*.github.io/*)
      printf '%s\n' "$url"
      printf '%s\n' "https://ghproxy.net/${url}"
      return 0
      ;;
  esac
  printf '%s\n' "$url"
}

# Одна попытка HTTP GET в stdout
_http_get_stdout() {
  local url="$1" iface="${2:-}"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$iface" ]; then
      curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        --interface "$iface" "$url" 2>/dev/null
    else
      curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        "$url" 2>/dev/null
    fi
  elif [ -z "$iface" ] && command -v wget >/dev/null 2>&1; then
    wget -qO- -T "$WGET_TIMEOUT" "$url" 2>/dev/null
  else
    return 1
  fi
}

# Одна попытка HTTP GET в файл
_http_get_file() {
  local url="$1" dest="$2" iface="${3:-}"
  rm -f "$dest"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$iface" ]; then
      curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        --interface "$iface" \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$url" -o "$dest" 2>/dev/null
    else
      curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$url" -o "$dest" 2>/dev/null
    fi
  elif [ -z "$iface" ] && command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" -T "$WGET_TIMEOUT" --no-cache "$url" 2>/dev/null || \
      wget -qO "$dest" -T "$WGET_TIMEOUT" "$url" 2>/dev/null
  else
    return 1
  fi
  [ -f "$dest" ] && [ -s "$dest" ]
}

# Скачивание с прогрессом (для больших файлов: rkn.list и т.п.)
# curl: progress-bar; wget: обычный индикатор (без -q).
_http_get_file_progress() {
  local url="$1" dest="$2" iface="${3:-}"
  rm -f "$dest"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$iface" ]; then
      curl -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        --interface "$iface" --progress-bar -o "$dest" "$url"
    else
      curl -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        --progress-bar -o "$dest" "$url"
    fi
  elif [ -z "$iface" ] && command -v wget >/dev/null 2>&1; then
    # без -q — показывает % / скорость
    wget -O "$dest" -T "$WGET_TIMEOUT" --no-cache "$url" || \
      wget -O "$dest" -T "$WGET_TIMEOUT" "$url"
  else
    return 1
  fi
  [ -f "$dest" ] && [ -s "$dest" ]
}

# Как download_file, но с отображением хода (stderr).
# ---------------------------------------------------------------------------
# Единое скачивание: зеркала → (опц.) туннели → проверки
# download_file URL DEST [progress] [sh] [min=N] [timeout=N] [connect=N]
#   progress  — progress-bar (большие файлы)
#   sh        — shebang + sh -n (install.sh / меню)
#   min=N     — минимум байт (для sh по умолчанию 8000)
#   timeout=N — CURL_MAX_TIME / WGET на эту загрузку
# ---------------------------------------------------------------------------
download_file() {
  local url="$1" dest="$2"
  shift 2
  local progress=0 validate_sh=0 min_bytes=0 timeout="" connect=""
  local alt iface sz syn_err ok=0 _c _m _w

  while [ $# -gt 0 ]; do
    case "$1" in
      progress) progress=1 ;;
      sh|script) validate_sh=1 ;;
      min=*) min_bytes="${1#min=}" ;;
      timeout=*) timeout="${1#timeout=}" ;;
      connect=*) connect="${1#connect=}" ;;
    esac
    shift
  done

  case "$min_bytes" in ''|*[!0-9]*) min_bytes=0 ;; esac
  if [ "$validate_sh" -eq 1 ] && [ "$min_bytes" -eq 0 ]; then
    min_bytes=8000
  fi

  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  rm -f "$dest"

  _c="$CURL_CONNECT_TIMEOUT"
  _m="$CURL_MAX_TIME"
  _w="$WGET_TIMEOUT"
  if [ -n "$connect" ]; then
    CURL_CONNECT_TIMEOUT="$connect"
  else
    CURL_CONNECT_TIMEOUT=5
  fi
  if [ -n "$timeout" ]; then
    CURL_MAX_TIME="$timeout"
    WGET_TIMEOUT="$timeout"
  elif [ "$progress" -eq 1 ]; then
    CURL_MAX_TIME="$CURL_MAX_TIME_LARGE"
    WGET_TIMEOUT="$CURL_MAX_TIME_LARGE"
  else
    CURL_MAX_TIME=25
    WGET_TIMEOUT=20
  fi

  for alt in $(github_alt_urls "$url"); do
    rm -f "$dest"
    # Только fallback-зеркала (основной URL уже в «Источник:»)
    [ "$validate_sh" -eq 1 ] && [ "$alt" != "$url" ] && info "Пробуем зеркало: $alt" >&2
    if [ "$progress" -eq 1 ]; then
      _http_get_file_progress "$alt" "$dest" || continue
    else
      _http_get_file "$alt" "$dest" || continue
    fi

    sz=$(wc -c < "$dest" 2>/dev/null | tr -d ' \t')
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$min_bytes" -gt 0 ] && [ "$sz" -lt "$min_bytes" ]; then
      warn "Обрывок (${sz} Б < ${min_bytes}) — другой источник..." >&2
      rm -f "$dest"
      continue
    fi
    if [ "$validate_sh" -eq 1 ]; then
      if ! head -1 "$dest" | grep -qE '^#!/(usr/)?bin/(sh|bash)'; then
        warn "Нет shebang — пропуск источника" >&2
        rm -f "$dest"
        continue
      fi
      syn_err=$(sh -n "$dest" 2>&1) || {
        warn "Скрипт битый (syntax) — пропуск источника" >&2
        [ -n "$syn_err" ] && printf '%s\n' "$syn_err" >&2
        rm -f "$dest"
        continue
      }
    fi

    ok=1
    [ "$alt" != "$url" ] && info "Скачано через зеркало" >&2
    break
  done

  if [ "$ok" -ne 1 ] && command -v curl >/dev/null 2>&1; then
    for iface in $(list_up_fallback_ifaces); do
      warn "Основной канал недоступен, пробуем через $iface ..." >&2
      for alt in $(github_alt_urls "$url"); do
        rm -f "$dest"
        if [ "$progress" -eq 1 ]; then
          _http_get_file_progress "$alt" "$dest" "$iface" || continue
        else
          _http_get_file "$alt" "$dest" "$iface" || continue
        fi
        sz=$(wc -c < "$dest" 2>/dev/null | tr -d ' \t')
        case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
        if [ "$min_bytes" -gt 0 ] && [ "$sz" -lt "$min_bytes" ]; then
          rm -f "$dest"
          continue
        fi
        if [ "$validate_sh" -eq 1 ]; then
          head -1 "$dest" | grep -qE '^#!/(usr/)?bin/(sh|bash)' || { rm -f "$dest"; continue; }
          sh -n "$dest" 2>/dev/null || { rm -f "$dest"; continue; }
        fi
        ok=1
        info "Скачано через $iface" >&2
        break 2
      done
    done
  fi

  CURL_CONNECT_TIMEOUT="$_c"
  CURL_MAX_TIME="$_m"
  WGET_TIMEOUT="$_w"

  if [ "$ok" -ne 1 ] || [ ! -s "$dest" ]; then
    rm -f "$dest"
    return 1
  fi
  return 0
}

# Совместимость: тонкие обёртки (1–2 вызова в меню)
download_file_progress() {
  download_file "$1" "$2" progress
}

download_sh_validated() {
  download_file "$1" "$2" sh "min=${3:-8000}" connect=5 timeout=25
}


# Скачать URL в stdout: прямой → зеркала GitHub → туннели (--interface).
fetch_url() {
  local url="$1" alt iface body
  # 1) оригинал + CDN-зеркала
  for alt in $(github_alt_urls "$url"); do
    if body=$(_http_get_stdout "$alt"); then
      if [ -n "$body" ]; then
        [ "$alt" != "$url" ] && info "Скачано через зеркало" >&2
        printf '%s' "$body"
        return 0
      fi
    fi
  done
  # 2) туннели
  if command -v curl >/dev/null 2>&1; then
    for iface in $(list_up_fallback_ifaces); do
      warn "Основной канал недоступен, пробуем через $iface ..." >&2
      for alt in $(github_alt_urls "$url"); do
        if body=$(_http_get_stdout "$alt" "$iface"); then
          if [ -n "$body" ]; then
            info "Скачано через $iface" >&2
            printf '%s' "$body"
            return 0
          fi
        fi
      done
    done
  fi
  return 1
}

# ---------------------------------------------------------------------------
# SHA256 для blobs (strategies/blobs/SHA256SUMS)
# ---------------------------------------------------------------------------
BLOBS_SHA256SUMS_URL="${RAW_BASE}/strategies/blobs/SHA256SUMS"
BLOBS_SHA256SUMS_CACHE="/tmp/nfqws-blobs-SHA256SUMS"

# 0 = есть sha256sum или openssl
have_sha256() {
  command -v sha256sum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1
}

# SHA256 файла → stdout (только хеш). При ошибке return 1.
file_sha256() {
  local f="$1"
  [ -f "$f" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
  else
    return 1
  fi
}

# Скачать/обновить кэш SHA256SUMS (TTL ~1ч). Не фатально при ошибке сети.
ensure_blobs_sha256sums() {
  local ttl=3600 now age
  now=$(date +%s 2>/dev/null || echo 0)
  if [ -f "$BLOBS_SHA256SUMS_CACHE" ] && [ -s "$BLOBS_SHA256SUMS_CACHE" ]; then
    # mtime кэша
    if age=$(stat -c %Y "$BLOBS_SHA256SUMS_CACHE" 2>/dev/null); then
      if [ $((now - age)) -lt "$ttl" ]; then
        return 0
      fi
    elif age=$(date -r "$BLOBS_SHA256SUMS_CACHE" +%s 2>/dev/null); then
      if [ $((now - age)) -lt "$ttl" ]; then
        return 0
      fi
    else
      # нет stat — считаем кэш свежим, пока файл есть
      return 0
    fi
  fi
  if download_file "$BLOBS_SHA256SUMS_URL" "$BLOBS_SHA256SUMS_CACHE"; then
    return 0
  fi
  # старый кэш лучше, чем ничего
  [ -s "$BLOBS_SHA256SUMS_CACHE" ] && return 0
  return 1
}

# Ожидаемый SHA256 для basename из кэша SUMS (пусто если нет)
blob_expected_sha256() {
  local name="$1"
  [ -s "$BLOBS_SHA256SUMS_CACHE" ] || return 0
  # формат: <hash>  <filename>  (два пробела) или hash + пробелы + name
  awk -v n="$name" '
    $2 == n { print $1; exit }
    NF >= 2 {
      # путь мог быть strategies/blobs/name
      bn = $2
      sub(/.*\//, "", bn)
      if (bn == n) { print $1; exit }
    }
  ' "$BLOBS_SHA256SUMS_CACHE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Удалённые .sh: скачать (validated) + выполнить на полном tty
# ---------------------------------------------------------------------------
# $1=url  [$2=min_bytes, по умолчанию 8000; для коротких installers — 2000]
_run_remote_sh_restore_traps() {
  if [ -n "${MENU_PID:-}" ]; then
    trap 'upd_cleanup' EXIT
    trap 'upd_cleanup; exit 129' HUP
    trap 'upd_cleanup; exit 130' INT
    trap 'upd_cleanup; exit 143' TERM
  else
    trap - EXIT HUP INT TERM
  fi
}

run_remote_sh() {
  local url="$1" min_bytes="${2:-8000}" tmp rc=0
  shift 2 2>/dev/null || shift $#
  rm -f /tmp/nfqws-remote-*.sh 2>/dev/null || true
  tmp="/tmp/nfqws-remote-$$.sh"
  trap 'rm -f /tmp/nfqws-remote-$$.sh 2>/dev/null; _run_remote_sh_restore_traps' EXIT INT TERM

  if ! download_sh_validated "$url" "$tmp" "$min_bytes"; then
    error "Не удалось скачать целый скрипт: $url"
    rm -f "$tmp"
    _run_remote_sh_restore_traps
    return 1
  fi

  # Полный tty — иначе интерактив (awg-menu и т.п.) не поднимается
  if [ -c /dev/tty ]; then
    sh "$tmp" "$@" < /dev/tty > /dev/tty 2>&1 || rc=$?
  else
    sh "$tmp" "$@" || rc=$?
  fi
  rm -f "$tmp"
  _run_remote_sh_restore_traps
  drain_stdin
  return "$rc"
}

# Единый формат пункта меню → удалённый установщик:
#   [+] Открываем: 11. awg-openwrt
#   [+] Источник: https://...
#   ================================================
# $1=номер  $2=название  $3=url  [$4=min_bytes]
run_menu_remote_sh() {
  local num="$1" name="$2" url="$3" min_bytes="${4:-8000}"
  echo
  info "Открываем: ${num}. ${name}"
  info "Источник: $url"
  printf '%s\n' "================================================"
  run_remote_sh "$url" "$min_bytes"
}

# Записать opkg-репозиторий и обновить индекс
ensure_opkg_repo() {
  local name="$1" url="$2"
  if [ "$(pkg_backend)" = "apk" ]; then
    # OpenWrt 25.x: apk-индекс packages.adb + файл-декларация в repositories.d
    mkdir -p "$APK_REPO_DIR"
    echo "${url}/packages.adb" > "${APK_REPO_DIR}/${name}.list"
  else
    mkdir -p "$OPKG_CONF_DIR"
    echo "src/gz $name $url" > "$OPKG_CONF_DIR/${name}.conf"
  fi
  pkg_update
}

# Бэкенд пакетного менеджера: opkg (Entware, OpenWrt ≤24.10) или apk (OpenWrt 25.x)
pkg_backend() {
  if command -v opkg >/dev/null 2>&1; then
    echo "opkg"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  else
    echo "none"
  fi
}

pkg_update() {
  if [ "$(pkg_backend)" = "apk" ]; then
    apk update
  else
    opkg update
  fi
}

pkg_install() {
  if [ "$(pkg_backend)" = "apk" ]; then
    apk --update-cache add "$@"
  else
    opkg install "$@"
  fi
}

# Установка локального файла пакета (.ipk / .apk)
pkg_install_file() {
  if [ "$(pkg_backend)" = "apk" ]; then
    apk add --allow-untrusted "$@"
  else
    opkg install "$@"
  fi
}

# LAN IP роутера для подсказок со ссылками LuCI / веб-интерфейса
get_lan_ip() {
  uci get network.lan.ipaddr 2>/dev/null || echo "<ip-роутера>"
}

pkg_remove() {
  if [ "$(pkg_backend)" = "apk" ]; then
    # apk del не знает --autoremove (зависимости чистит сам) — фильтруем
    local args="" a
    for a in "$@"; do
      [ "$a" = "--autoremove" ] && continue
      args="$args $a"
    done
    # shellcheck disable=SC2086
    apk del $args
  else
    opkg remove "$@"
  fi
}

# URL нативного фида OpenWrt для nfqws
nfqws_feed_url() {
  echo "https://nfqws.github.io/$1/openwrt"
}

# GPG-ключ нативного фида OpenWrt (opkg проверяет подпись Packages).
# Файл ключа: <feed>/openwrt/<feed>.pub
ensure_openwrt_feed_key() {
  local feed="$1"
  if [ "$(pkg_backend)" = "apk" ]; then
    # apk: ключ .pem кладётся в /etc/apk/keys (проверка подписи автоматическая)
    local pem="${APK_KEYS_DIR}/${feed}.pem"
    mkdir -p "$APK_KEYS_DIR" || { error "Не создать $APK_KEYS_DIR."; return 1; }
    if ! download_file "https://nfqws.github.io/$feed/openwrt/$feed.pem" "$pem"; then
      error "Не удалось скачать ключ фида $feed (.pem)."
      return 1
    fi
    info "Ключ фида $feed установлен: $pem"
    return 0
  fi
  local key_file="/tmp/nfqws-feed.pub" rc=0
  if ! command -v opkg-key >/dev/null 2>&1; then
    error "opkg-key не найден — установка подписанных пакетов OpenWrt невозможна."
    return 1
  fi
  if ! download_file "https://nfqws.github.io/$feed/openwrt/$feed.pub" "$key_file"; then
    error "Не удалось скачать GPG-ключ фида $feed."
    return 1
  fi
  opkg-key add "$key_file" >/dev/null 2>&1 || rc=$?
  rm -f "$key_file"
  if [ "$rc" -ne 0 ]; then
    error "opkg-key add не прошёл."
    return 1
  fi
  info "GPG-ключ фида $feed добавлен."
  return 0
}

# Перезапуск init-скрипта, если есть
service_restart() {
  local init="$1"
  [ -x "$init" ] && "$init" restart 2>/dev/null || true
}

# Бэкап файла с меткой времени
backup_file() {
  local f="$1" dest
  [ -f "$f" ] || return 0
  dest="${f}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$dest" && info "Бэкап: $dest"
}

# Стратегии: подменяем возможные оставшиеся /opt пути под OpenWrt
strategy_retarget_paths() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -i "s|/opt/etc/nfqws2/|${CONF_BASE_DIR}/nfqws2/|g; s|/opt/etc/nfqws/|${CONF_BASE_DIR}/nfqws/|g; s|/opt/var/log/|/var/log/|g" "$f" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Архитектура / модель (кэш)
# ---------------------------------------------------------------------------
ARCH=""
ARCH_RAW=""
ARCH_SOURCE=""   # opkg | conf | openwrt_release | uname | ""

# Нормализация сырого идентификатора → ARCH (mipsel|mips|aarch64|armv7|x86_64|x86).
# Пустой результат = не распознано. mipsel* / mipselsf* проверяются ДО mips*.
_arch_normalize() {
  case "$1" in
    aarch64*|arm64*)                    echo "aarch64" ;;
    armv7*|armv6*|arm*|armhf*)          echo "armv7" ;;
    mipsel*|mipselsf*|mips64el*)        echo "mipsel" ;;
    mips*|mipssf*)                      echo "mips" ;;
    x86_64*|amd64*|x64*)                echo "x86_64" ;;
    i[3-6]86*|x86*|i686*)               echo "x86" ;;
    *)                                  echo "" ;;
  esac
}

# Лучшая строка «arch NAME PRIORITY» из stdin (opkg print-architecture или opkg.conf).
_arch_pick_best() {
  awk '
    $1 == "arch" && $2 != "" && $2 != "all" {
      p = $3 + 0
      n = $2
      bonus = 0
      if (n ~ /^mipsel/ || n ~ /^mipselsf/ || n ~ /^mips64el/) bonus = 2
      else if (n ~ /^aarch64/ || n ~ /^arm64/) bonus = 2
      else if (n ~ /^arm/ || n ~ /^armv7/) bonus = 2
      score = p * 10 + bonus
      if (score > best) { best = score; name = n }
    }
    END { if (name != "") print name }
  '
}

_arch_from_opkg() {
  if [ "$(pkg_backend)" = "apk" ]; then
    # apk --print-arch отдаёт одно слово — приведём к виду «arch NAME PRI»
    apk --print-arch 2>/dev/null | awk '{ print "arch " $1 " 100" }' | _arch_pick_best
    return
  fi
  opkg print-architecture 2>/dev/null | _arch_pick_best
}

# Чтение /etc/opkg.conf
_arch_from_opkg_conf() {
  local conf="${1:-/etc/opkg.conf}" line name from_url=""
  [ -f "$conf" ] || return 0

  name=$(grep -E '^[[:space:]]*arch[[:space:]]+' "$conf" 2>/dev/null | _arch_pick_best)
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      src/gz*|src\ *)
        case "$line" in
          *mipselsf*|*mips64el*) from_url="mipselsf"; break ;;
          *mipssf*)              from_url="mipssf"; break ;;
          *aarch64*|*arm64*)     from_url="aarch64"; break ;;
          *armv7*|*armhf*)       from_url="armv7"; break ;;
          */x64*|*x86_64*)       from_url="x86_64"; break ;;
          */x86*|*i386*)         from_url="x86"; break ;;
        esac
        ;;
    esac
  done < "$conf"
  [ -n "$from_url" ] && printf '%s\n' "$from_url"
}

# Строка под заголовком: Модель: WR3000P (KN-3811) 5.1.5 aarch64
# ARCH зелёный из opkg / openwrt_release, жёлтый из opkg.conf / uname.
print_arch_line() {
  local arch_col
  case "$ARCH_SOURCE" in
    opkg|openwrt_release) arch_col="$GREEN" ;;
    conf|uname) arch_col="$YELLOW" ;;
    *) arch_col="$DIM" ;;
  esac

  printf '%s' "${LBL_MODEL:-Model:}"
  if [ -n "$ROUTER_MODEL" ]; then
    printf ' %s' "$ROUTER_MODEL"
  else
    printf ' %s—%s' "$DIM" "$NC"
  fi
  if [ -n "$ROUTER_TITLE" ]; then
    printf ' (%s)' "$ROUTER_TITLE"
  fi
  if [ -n "$ARCH" ]; then
    printf ' %s%s%s' "$arch_col" "$ARCH" "$NC"
  fi
  printf '\n'

  if [ "$ROUTER_OS" = "openwrt" ] || [ "$ROUTER_OS" = "generic" ]; then
    if [ "$OS_HAS_NF_QUEUE" = "0" ]; then
      if [ "$ROUTER_FW_TYPE" = "fw4" ]; then
        printf '%s\n' "${RED}${BOLD}[!] Модули ядра NFQUEUE не найдены. Установите пакет kmod-nft-queue менеджером пакетов прошивки${NC}"
      else
        printf '%s\n' "${RED}${BOLD}[!] Модули ядра NFQUEUE не найдены. Установите пакеты kmod-ipt-nfqueue iptables-mod-nfqueue менеджером пакетов прошивки${NC}"
      fi
    fi
  fi
}

detect_arch() {
  local um cand

  # Гарантируем, что ОС уже определена
  [ "$OS_CHECKED" = "1" ] || detect_os

  # Уже определено — только перерисовать строку
  if [ -n "$ARCH" ] || [ -n "$ARCH_SOURCE" ]; then
    print_arch_line
    return 0
  fi

  # 1) opkg print-architecture
  ARCH_RAW=$(_arch_from_opkg)
  ARCH=$(_arch_normalize "$ARCH_RAW")
  [ -n "$ARCH" ] && ARCH_SOURCE="opkg"

  # 2) opkg.conf
  if [ -z "$ARCH" ]; then
    ARCH_RAW=$(_arch_from_opkg_conf)
    ARCH=$(_arch_normalize "$ARCH_RAW")
    [ -n "$ARCH" ] && ARCH_SOURCE="conf"
  fi

  # 3) OpenWrt: DISTRIB_ARCH из /etc/openwrt_release
  if [ -z "$ARCH" ] && [ "$ROUTER_OS" = "openwrt" ] && [ -n "${DISTRIB_ARCH_VAL:-}" ]; then
    cand=$(_arch_normalize "$DISTRIB_ARCH_VAL")
    if [ -n "$cand" ]; then
      ARCH="$cand"
      ARCH_RAW="$DISTRIB_ARCH_VAL"
      ARCH_SOURCE="openwrt_release"
    fi
  fi

  # 4) uname -m
  if [ -z "$ARCH" ]; then
    um=$(uname -m 2>/dev/null || true)
    cand=$(_arch_normalize "$um")
    if [ -n "$cand" ]; then
      ARCH="$cand"
      ARCH_RAW="$um"
      ARCH_SOURCE="uname"
    fi
  fi

  [ -z "$ARCH_SOURCE" ] && ARCH_SOURCE="none"

  print_arch_line

  if [ -z "$ARCH" ]; then
    warn "ARCH не определена — установка NFQWS по архитектуре может быть недоступна."
  fi
  return 0
}

need_arch() {
  [ -z "$ARCH" ] && detect_arch
  if [ -z "$ARCH" ]; then
    error "Нужна архитектура: проверьте вывод opkg print-architecture / apk --print-arch или /etc/opkg.conf."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Кэш opkg / процессов
# ---------------------------------------------------------------------------
OPKG_INSTALLED_CACHE=""
PROC_CACHE=""
PORT90_CACHE=""

# Список установленных из статуса opkg (/usr/lib/opkg/status) — без вызова opkg, без lock.
# Только Status «… installed» (не «not-installed» — старые residual-записи).
# Формат строк: «name - version».
refresh_opkg_cache() {
  if [ "$(pkg_backend)" = "apk" ]; then
    # apk list --installed: «name-version arch {…} [installed]» → «name - version».
    # Версию собираем с конца: -rN ревизия + сегмент, начинающийся с цифры
    # (regex не подходит: левое совпадение режет имена типа nfqws-keenetic-*).
    OPKG_INSTALLED_CACHE=$(apk list --installed 2>/dev/null | awk '{
      nv = $1
      n = split(nv, seg, "-")
      ver = ""
      if (n >= 2 && seg[n] ~ /^r[0-9]+$/) { ver = "-" seg[n]; n-- }
      if (n >= 1 && seg[n] ~ /^[0-9]/) { ver = seg[n] ver; n-- }
      name = seg[1]
      for (i = 2; i <= n; i++) name = name "-" seg[i]
      if (name != "" && ver != "") print name " - " ver
    }') || OPKG_INSTALLED_CACHE=""
    return 0
  fi
  local status="$STATUS_FILE"
  [ -r "$status" ] || status="/usr/lib/opkg/status"
  [ -r "$status" ] || status="/var/lib/opkg/status"
  if [ ! -r "$status" ]; then
    OPKG_INSTALLED_CACHE=""
    return 0
  fi
  OPKG_INSTALLED_CACHE=$(awk '
    function flush() {
      # « installed» есть у installed; у not-installed пробела перед installed нет
      if (ok && pkg != "" && ver != "") print pkg " - " ver
      pkg = ""; ver = ""; ok = 0
    }
    /^Package:[[:space:]]*/ {
      flush()
      pkg = $0
      sub(/^Package:[[:space:]]*/, "", pkg)
      next
    }
    /^Version:[[:space:]]*/ {
      ver = $0
      sub(/^Version:[[:space:]]*/, "", ver)
      next
    }
    /^Status:[[:space:]]*/ {
      ok = ($0 ~ / installed/)
      next
    }
    /^$/ { flush() }
    END { flush() }
  ' "$status" 2>/dev/null) || OPKG_INSTALLED_CACHE=""
}

refresh_proc_cache() {
  PROC_CACHE=$(ps w 2>/dev/null || ps 2>/dev/null || true)
}

# Без fork: shell-цикл по кэшу
is_installed() {
  local line pref
  [ -n "$OPKG_INSTALLED_CACHE" ] || refresh_opkg_cache
  pref="$1 - "
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$pref"*) return 0 ;;
    esac
  done <<EOF
$OPKG_INSTALLED_CACHE
EOF
  return 1
}

# Без grep/sed/head — один shell-цикл по кэшу
pkg_version() {
  local line pref
  [ -n "$OPKG_INSTALLED_CACHE" ] || refresh_opkg_cache
  pref="$1 - "
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$pref"*) printf '%s\n' "${line#"$pref"}"; return 0 ;;
    esac
  done <<EOF
$OPKG_INSTALLED_CACHE
EOF
  return 1
}

port_is_open() {
  local port="$1" ok=1 hex_port
  if [ "$port" = "90" ] && [ -n "$PORT90_CACHE" ]; then
    [ "$PORT90_CACHE" = "1" ]
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | grep -qE "[.:]${port}[[:space:]]" && ok=0
  elif command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -qE "[.:]${port}[[:space:]]" && ok=0
  elif [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
    hex_port=$(printf '%04X' "$port")
    { grep -q ":${hex_port} " /proc/net/tcp 2>/dev/null || \
      grep -q ":${hex_port} " /proc/net/tcp6 2>/dev/null; } && ok=0
  fi
  if [ "$port" = "90" ]; then
    if [ "$ok" -eq 0 ]; then PORT90_CACHE=1; else PORT90_CACHE=0; fi
  fi
  return "$ok"
}

proc_running() {
  local name="$1" line
  [ -n "$PROC_CACHE" ] || refresh_proc_cache
  # Быстрая отсечка по подстроке без fork, затем проверка целого имени бинарника
  # (чтобы nfqws не срабатывал на nfqws2 / nfqws-menu.sh, а tg-ws-proxy — на tg-ws-proxy-rs)
  case "$PROC_CACHE" in
    *"$name"*) ;;
    *) return 1 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"/$name "*|*"/$name"|*" $name "*|*" $name") return 0 ;;
    esac
  done <<EOF
$PROC_CACHE
EOF
  return 1
}

# Запущен ли amneziawg: модуль ядра загружен или поднят интерфейс awg*.
# Вызывается только для awg (см. show_installed) — остальные kind'и проверяются напрямую.
service_is_up() {
  [ -d /sys/module/amneziawg ] && return 0
  if command -v awg >/dev/null 2>&1; then
    awg show interfaces 2>/dev/null | grep -q . && return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip link show awg0 >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Один awk: OPKG + PROC + UPD → готовые строки статуса (минимум fork на MIPS)
# Метки ⭡: ключи UPD_CACHE = nfqws-keenetic|nfqws2-keenetic|nfqws-keenetic-web|
#   tg-ws-proxy-rs|dpi-detector (см. upd_check_bg).
show_installed() {
  local out web_up=0 awg_up=0
  local extras="" rs_ver dpi_ver _awg_ver _tm_ver
  PORT90_CACHE=""
  refresh_opkg_cache
  refresh_proc_cache

  echo
  printf '%s\n' "${BOLD}${LBL_INSTALLED}${NC}"

  # port 90 / awg — один раз
  port_is_open 90 && web_up=1
  service_is_up awg && awg_up=1

  # Внешние tool-версии (не из opkg) — до awk
  if [ -x "${TG_WS_PROXY_RS_BIN:-/usr/bin/tg-ws-proxy-rs}" ]; then
    rs_ver=$(tg_ws_proxy_rs_version 2>/dev/null) || rs_ver="ok"
    extras="${extras}tool|tg-ws-proxy-rs|${rs_ver:-ok}|tg-ws-proxy-rs
"
  fi
  if [ -x "$(dpi_detector_bin)" ] || command -v dpi-detector >/dev/null 2>&1; then
    dpi_ver=$(dpi_detector_version 2>/dev/null) || dpi_ver="ok"
    extras="${extras}tool|dpi-detector|${dpi_ver:-ok}|
"
  fi
  if [ -x /usr/bin/telemt ] || [ -f /etc/init.d/telemt ]; then
    _tm_ver=""
    if [ -x /usr/bin/telemt ]; then
      _tm_ver=$(/usr/bin/telemt --version 2>/dev/null | head -n1 | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    fi
    extras="${extras}tool|telemt|${_tm_ver:-ok}|telemt
"
  fi
  if [ -d /sys/module/amneziawg ] || command -v awg >/dev/null 2>&1; then
    _awg_ver=""
    if [ -r /sys/module/amneziawg/version ]; then
      _awg_ver=$(cat /sys/module/amneziawg/version 2>/dev/null | tr -d '\r\n')
    fi
    extras="${extras}tool|amneziawg|${_awg_ver:-ok}|amneziawg
"
  fi
  # список сервисов в /etc/init.d
  if [ -d /etc/init.d ]; then
    local f base
    for f in /etc/init.d/nfqws*; do
      [ -f "$f" ] && [ -x "$f" ] || continue
      base=${f##*/}
      [ -n "$base" ] || continue
      # пакеты nfqws* и так показываются строками opkg — не дублировать
      case "$base" in
        nfqws-keenetic|nfqws2-keenetic|nfqws-keenetic-web) continue ;;
      esac
      extras="${extras}init|${base}
"
    done
  fi

  out=$(
    WEB_UP="$web_up" AWG_UP="$awg_up" \
    G="$GREEN" N="$NC" R="${RUN_MARK}" U="${UPD_MARK}" D="$DIM" \
    awk -v none="$LBL_NONE" '
    function ver_gt(a, b,   i, na, nb, xa, xb, ca, cb) {
      if (a == "" || b == "" || a == b) return 0
      na = split(a, A, /[^0-9A-Za-z]+/)
      nb = split(b, B, /[^0-9A-Za-z]+/)
      for (i = 1; i <= na || i <= nb; i++) {
        xa = (i <= na) ? A[i] : "0"
        xb = (i <= nb) ? B[i] : "0"
        if (xa ~ /^[0-9]+$/ && xb ~ /^[0-9]+$/) {
          ca = xa + 0; cb = xb + 0
          if (ca > cb) return 1
          if (ca < cb) return 0
        } else {
          if (xa > xb) return 1
          if (xa < xb) return 0
        }
      }
      return 0
    }
    function row(name, ver, mark,   s) {
      s = sprintf("  %s%-22s%s %s%s", G, name, N, ver, mark)
      print s
      shown++
    }
    function mark_run(on) { return on ? R : "" }
    function mark_upd(pkg, localv,   rem) {
      rem = remote[pkg]
      if (rem == "" || localv == "" || rem == localv) return ""
      if (ver_gt(rem, localv)) return U G rem N
      return ""
    }
    function proc_has(s) { return PROC ~ ("(^|[[:space:]/])" s "([[:space:]]|$)") }

    BEGIN {
      section = "opkg"
      shown = 0
      G = ENVIRON["G"]; N = ENVIRON["N"]; R = ENVIRON["R"]
      U = ENVIRON["U"]; D = ENVIRON["D"]
      WEB_UP = ENVIRON["WEB_UP"] + 0
      AWG_UP = ENVIRON["AWG_UP"] + 0
    }
    /^---PROC---$/ { section = "proc"; next }
    /^---UPD---$/  { section = "upd";  next }
    /^---EXTRA---$/ { section = "extra"; next }
    section == "opkg" {
      if ($0 ~ /^[^ ]+ - /) {
        pkg = $1
        ver = $0
        sub(/^[^ ]+ - /, "", ver)
        opkg[pkg] = ver
      }
      next
    }
    section == "proc" { PROC = PROC $0 "\n"; next }
    section == "upd" {
      if ($1 != "" && $1 != "checked") {
        rem = $0; sub(/^[^ ]+ /, "", rem)
        remote[$1] = rem
      }
      next
    }
    section == "extra" {
      if ($0 ~ /^tool\|/) {
        n = split($0, t, "|")
        # tool|name|ver
        tname = t[2]; tver = t[3]
        tools[tname] = tver
        next
      }
      if ($0 ~ /^init\|/) {
        svc = substr($0, 6)
        if (svc != "") inits[svc] = 1
        next
      }
      next
    }
    END {
      # --- основные opkg-пакеты ---
      if ("nfqws-keenetic" in opkg) {
        m = mark_run(proc_has("nfqws")) mark_upd("nfqws-keenetic", opkg["nfqws-keenetic"])
        row("nfqws-keenetic", opkg["nfqws-keenetic"], m)
      }
      if ("nfqws2-keenetic" in opkg) {
        m = mark_run(proc_has("nfqws2")) mark_upd("nfqws2-keenetic", opkg["nfqws2-keenetic"])
        row("nfqws2-keenetic", opkg["nfqws2-keenetic"], m)
      }
      if ("nfqws-keenetic-web" in opkg) {
        m = mark_run(WEB_UP || proc_has("lighttpd")) mark_upd("nfqws-keenetic-web", opkg["nfqws-keenetic-web"])
        row("nfqws-keenetic-web", opkg["nfqws-keenetic-web"], m)
      }
      # tools (tg-ws, dpi, keenkit, telemt)
      if ("tg-ws-proxy-rs" in tools) {
        m = mark_run(proc_has("tg-ws-proxy-rs")) mark_upd("tg-ws-proxy-rs", tools["tg-ws-proxy-rs"])
        row("tg-ws-proxy-rs", tools["tg-ws-proxy-rs"], m)
      }
      if ("magitrickle" in opkg) {
        m = mark_run(proc_has("magitrickle")) mark_upd("magitrickle", opkg["magitrickle"])
        row("magitrickle", opkg["magitrickle"], m)
      }
      if ("dpi-detector" in tools) {
        m = mark_upd("dpi-detector", tools["dpi-detector"])
        row("dpi-detector", tools["dpi-detector"], m)
      }
      # awg-openwrt (AmneziaWG)
      if (("kmod-amneziawg" in opkg) || ("amneziawg-tools" in opkg) || ("luci-proto-amneziawg" in opkg) || ("amneziawg" in tools)) {
        aver = ("kmod-amneziawg" in opkg) ? opkg["kmod-amneziawg"] : (("amneziawg-tools" in opkg) ? opkg["amneziawg-tools"] : (("amneziawg" in tools) ? tools["amneziawg"] : "ok"))
        up = AWG_UP || proc_has("amneziawg")
        m = mark_run(up)
        row("awg-openwrt", aver, m)
      }
      if ("luci-app-telemt" in opkg) {
        tver = ("telemt" in opkg) ? opkg["telemt"] : opkg["luci-app-telemt"]
        m = mark_run(proc_has("telemt")) mark_upd("luci-app-telemt", opkg["luci-app-telemt"])
        row("luci-app-telemt", tver, m)
      } else if ("telemt" in opkg) {
        m = mark_run(proc_has("telemt")) mark_upd("telemt", opkg["telemt"])
        row("telemt", opkg["telemt"], m)
      } else if ("telemt" in tools) {
        m = mark_run(proc_has("telemt"))
        row("telemt", tools["telemt"], m)
      }

      # прочие init.d
      skip["nfqws"]=1; skip["nfqws2"]=1; skip["lighttpd"]=1
      skip["tg-ws-proxy"]=1; skip["tg-ws-proxy-rs"]=1; skip["magitrickle"]=1
      skip["telemt"]=1; skip["luci-app-telemt"]=1
      skip["kmod-amneziawg"]=1; skip["amneziawg-tools"]=1
      skip["luci-proto-amneziawg"]=1; skip["luci-app-amneziawg"]=1; skip["luci-i18n-amneziawg-ru"]=1
      skip["amneziawg"]=1; skip["awg-manager"]=1
      for (svc in inits) {
        if (svc in skip) continue
        ver = (svc in opkg) ? opkg[svc] : ""
        m = mark_run(proc_has(svc))
        row(svc, ver, m)
      }

      if (shown == 0) printf "  %s%s%s\n", D, none, N
    }
    ' <<EOF
$OPKG_INSTALLED_CACHE
---PROC---
$PROC_CACHE
---UPD---
$( [ -f "${UPD_CACHE:-}" ] && cat "$UPD_CACHE" 2>/dev/null )
---EXTRA---
$extras
EOF
  )
  printf '%s\n' "$out"
  echo
}

# ---------------------------------------------------------------------------
# Выбор версии NFQWS (1 / 2 / both) — общий для strategy и ipset
# ---------------------------------------------------------------------------
# $1 = allow_both (1|0). Результат в переменную NFQWS_VER.
need_nfqws_installed() {
  local has1=0 has2=0
  is_installed "nfqws-keenetic"  && has1=1
  is_installed "nfqws2-keenetic" && has2=1
  if [ "$has1" -eq 0 ] && [ "$has2" -eq 0 ]; then
    warn "Ни одна версия NFQWS не установлена."
    if confirm_yes "Перейти к установке?"; then
      menu_install_nfqws
    fi
    return 1
  fi
  HAS_NFQWS1=$has1
  HAS_NFQWS2=$has2
  return 0
}

pick_nfqws_ver() {
  # $1 = allow_both (1|0). Ставит NFQWS_VER = 1|2|both
  local allow_both="${1:-0}"
  if [ "$HAS_NFQWS1" -eq 1 ] && [ "$HAS_NFQWS2" -eq 1 ]; then
    echo
    echo "Установлены обе версии."
    echo "  1) nfqws-keenetic  (v1)"
    echo "  2) nfqws2-keenetic (v2)"
    [ "$allow_both" = "1" ] && echo "  a) Обе"
    ask "${LBL_YOUR_CHOICE} [0]: "
    read -r c
    case "$c" in
      1) NFQWS_VER=1 ;;
      2) NFQWS_VER=2 ;;
      a|A|а|А)
        [ "$allow_both" = "1" ] || return 1
        NFQWS_VER=both
        ;;
      *) return 1 ;;
    esac
  elif [ "$HAS_NFQWS1" -eq 1 ]; then
    NFQWS_VER=1
  else
    NFQWS_VER=2
  fi
  return 0
}

nfqws_conf_path() {
  case "$1" in
    1) echo "${CONF_BASE_DIR}/nfqws/nfqws.conf" ;;
    2) echo "${CONF_BASE_DIR}/nfqws2/nfqws2.conf" ;;
  esac
}

# OpenWrt: procd-сервисы nfqws-keenetic / nfqws2-keenetic (или nfqws / nfqws2)
nfqws_init_path() {
  case "$1" in
    1)
      if [ -x "${INIT_BASE_DIR}/nfqws" ]; then
        echo "${INIT_BASE_DIR}/nfqws"
      elif [ -x "${INIT_BASE_DIR}/nfqws-keenetic" ]; then
        echo "${INIT_BASE_DIR}/nfqws-keenetic"
      elif [ -f "${INIT_BASE_DIR}/nfqws" ]; then
        echo "${INIT_BASE_DIR}/nfqws"
      else
        echo "${INIT_BASE_DIR}/nfqws-keenetic"
      fi
      ;;
    2)
      if [ -x "${INIT_BASE_DIR}/nfqws2" ]; then
        echo "${INIT_BASE_DIR}/nfqws2"
      elif [ -x "${INIT_BASE_DIR}/nfqws2-keenetic" ]; then
        echo "${INIT_BASE_DIR}/nfqws2-keenetic"
      elif [ -f "${INIT_BASE_DIR}/nfqws2" ]; then
        echo "${INIT_BASE_DIR}/nfqws2"
      else
        echo "${INIT_BASE_DIR}/nfqws2-keenetic"
      fi
      ;;
  esac
}

nfqws_lists_dir() {
  case "$1" in
    1) echo "${CONF_BASE_DIR}/nfqws" ;;
    2) echo "${CONF_BASE_DIR}/nfqws2/lists" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1–2. Установка пакетов
# ---------------------------------------------------------------------------
install_deps() {
  info "Установка зависимостей..."
  pkg_update
  pkg_install ca-certificates wget-ssl curl 2>/dev/null || true
  pkg_remove wget-nossl 2>/dev/null || true
}

ask_web_install() {
  echo
  if confirm_no "Установить веб-интерфейс nfqws-keenetic-web?"; then
    install_web
  fi
}

# Конфликт пакетов nfqws-keenetic ↔ nfqws2-keenetic: ставить вместе нельзя.
# $1 = версия, которую ОСТАВЛЯЕМ (1|2) — противоположная удаляется вместе с web.
# 0 = конфликта нет или устранён; 1 = пользователь отказался (вызов отменяет установку).
resolve_nfqws_conflict() {
  local keep="$1" other other_pkg
  [ "$keep" = "1" ] && { other=2; other_pkg="nfqws2-keenetic"; } || { other=1; other_pkg="nfqws-keenetic"; }
  is_installed "$other_pkg" || return 0
  warn "Обнаружен ${other_pkg}. Пакеты конфликтуют — ставить вместе нельзя."
  if ! confirm_no "Удалить ${other_pkg} (и веб-интерфейс)?"; then
    warn "Установка отменена (${other_pkg} остаётся)."
    return 1
  fi
  _stop_nfqws_hard "$other"
  pkg_remove nfqws-keenetic-web "$other_pkg" 2>/dev/null || true
  _stop_nfqws_hard "$other"
  refresh_opkg_cache
  return 0
}

install_nfqws1() {
  need_arch || return 1
  info "Установка nfqws-keenetic (версия 1)..."
  resolve_nfqws_conflict 1 || return 1
  install_deps
  ensure_openwrt_feed_key "nfqws-keenetic" || return 1
  ensure_opkg_repo "nfqws-keenetic" "$(nfqws_feed_url nfqws-keenetic)"
  if pkg_install nfqws-keenetic; then
    refresh_opkg_cache
    if is_installed "nfqws-keenetic"; then
      info "nfqws-keenetic установлен."
      ask_web_install
    else
      error "opkg не сообщил об ошибке, но пакет nfqws-keenetic не установлен."
      return 1
    fi
  else
    error "Не удалось установить nfqws-keenetic (конфликт или ошибка opkg)."
    return 1
  fi
}

install_nfqws2() {
  need_arch || return 1
  info "Установка nfqws2-keenetic (версия 2)..."
  resolve_nfqws_conflict 2 || return 1
  install_deps
  ensure_openwrt_feed_key "nfqws2-keenetic" || return 1
  ensure_opkg_repo "nfqws2-keenetic" "$(nfqws_feed_url nfqws2-keenetic)"
  if pkg_install nfqws2-keenetic; then
    refresh_opkg_cache
    if is_installed "nfqws2-keenetic"; then
      info "nfqws2-keenetic установлен."
      ask_web_install
    else
      error "opkg не сообщил об ошибке, но пакет nfqws2-keenetic не установлен."
      return 1
    fi
  else
    error "Не удалось установить nfqws2-keenetic (конфликт или ошибка opkg)."
    return 1
  fi
}

# Версия из raw VERSION (fetch_url → зеркала jsDelivr/ghproxy)
fetch_pkg_version_file() {
  # Только быстрые зеркала, короткие таймауты (без долгого GitHub)
  local repo="$1" ver url _c _m _w
  _c="$CURL_CONNECT_TIMEOUT"; _m="$CURL_MAX_TIME"; _w="$WGET_TIMEOUT"
  CURL_CONNECT_TIMEOUT=4
  CURL_MAX_TIME=10
  WGET_TIMEOUT=10
  ver=""
  for url in \
    "https://ghproxy.net/https://raw.githubusercontent.com/${repo}/master/VERSION" \
    "https://cdn.jsdelivr.net/gh/${repo}@master/VERSION" \
    "https://fastly.jsdelivr.net/gh/${repo}@master/VERSION"
  do
    ver=$(_http_get_stdout "$url" 2>/dev/null | tr -d ' \t\r\n' | head -1)
    [ -n "$ver" ] && break
    ver=""
  done
  CURL_CONNECT_TIMEOUT="$_c"
  CURL_MAX_TIME="$_m"
  WGET_TIMEOUT="$_w"
  [ -n "$ver" ] || return 1
  printf '%s\n' "$ver"
}

# Прямая установка .ipk / .apk из GitHub Releases (обход блокировок фидов)
install_package_direct() {
  local pkg="$1" ver repo fn ext backend dest dl_ok=0
  need_arch || return 1
  backend=$(pkg_backend)
  ext="ipk"
  [ "$backend" = "apk" ] && ext="apk"

  case "$pkg" in
    nfqws-keenetic)
      repo="nfqws/nfqws-keenetic"
      ;;
    nfqws2-keenetic)
      repo="nfqws/nfqws2-keenetic"
      resolve_nfqws_conflict 2 || return 1
      ;;
    nfqws-keenetic-web)
      repo="nfqws/nfqws-keenetic-web"
      ;;
    *)
      error "Неизвестный пакет: $pkg"
      return 1
      ;;
  esac

  echo
  info "Запрос актуальной версии ${pkg} через зеркала..."
  ver=$(fetch_pkg_version_file "$repo" 2>/dev/null || true)
  if [ -z "$ver" ]; then
    case "$pkg" in
      nfqws-keenetic)     ver="2.11.4" ;;
      nfqws2-keenetic)    ver="1.3.1" ;;
      nfqws-keenetic-web) ver="3.0.24" ;;
    esac
    warn "Не удалось получить версию из сети, используется базовая: ${ver}"
  else
    info "Актуальная версия: ${ver}"
  fi

  fn="${pkg}_${ver#v}_all_openwrt.${ext}"
  dest="/tmp/${fn}"
  rm -f "$dest"

  info "Скачивание пакета ${fn}..."
  local url1="https://ghproxy.net/https://github.com/${repo}/releases/download/v${ver#v}/${fn}"
  local url2="https://github.com/${repo}/releases/download/v${ver#v}/${fn}"
  local url3="https://nfqws.github.io/${pkg}/openwrt/${pkg}_${ver#v}_all.${ext}"

  for u in "$url1" "$url2" "$url3"; do
    if download_file "$u" "$dest" progress min=200000; then
      dl_ok=1
      break
    fi
  done

  if [ "$dl_ok" -ne 1 ] || [ ! -f "$dest" ]; then
    error "Не удалось скачать пакет ${fn} ни с одного зеркала."
    rm -f "$dest"
    return 1
  fi

  case "$pkg" in
    nfqws-keenetic)
      resolve_nfqws_conflict 1 || { rm -f "$dest"; return 1; }
      ;;
    nfqws2-keenetic)
      resolve_nfqws_conflict 2 || { rm -f "$dest"; return 1; }
      ;;
  esac

  # Остановка сервиса перед обновлением бинарника
  case "$pkg" in
    nfqws2-keenetic) stop_nfqws2_hard ;;
    nfqws-keenetic)  stop_nfqws1_hard ;;
  esac

  info "Установка ${fn}..."
  if ! pkg_install_file "$dest"; then
    error "Ошибка установки пакета ${fn}."
    rm -f "$dest"
    return 1
  fi
  rm -f "$dest"
  refresh_opkg_cache

  info "Пакет ${pkg} успешно установлен!"
  case "$pkg" in
    nfqws-keenetic|nfqws2-keenetic)
      ask_web_install
      ;;
    nfqws-keenetic-web)
      info "Веб-интерфейс установлен."
      info "Адрес: http://$(get_lan_ip):90"
      info "Логин/пароль — учётные данные root-пользователя роутера"
      ;;
  esac
  return 0
}

menu_install_ipk_direct() {
  local choice
  while true; do
    echo
    printf '%s\n' "${BOLD}── ${LBL_INSTALL_DIRECT:-Прямая установка .ipk / .apk} ──${NC}"
    printf '%s\n' "${DIM}Скачивание standalone-пакетов с релизов GitHub / ghproxy.${NC}"
    printf '%s\n' "${DIM}Формат пакета для текущей системы: %s${NC}" "$(pkg_backend)"
    echo
    printf "  %s1)%s  nfqws-keenetic (версия 1)\n" "$GREEN" "$NC"
    printf "  %s2)%s  nfqws2-keenetic (версия 2)\n" "$GREEN" "$NC"
    printf "  %s3)%s  nfqws-keenetic-web (веб-интерфейс)\n" "$GREEN" "$NC"
    printf "  %s0)%s  ${LBL_BACK_ITEM}\n" "$DIM" "$NC"
    ask "${LBL_YOUR_CHOICE} [0]: "
    read_menu choice
    case "$choice" in
      1) install_package_direct "nfqws-keenetic" ;;
      2) install_package_direct "nfqws2-keenetic" ;;
      3) install_package_direct "nfqws-keenetic-web" ;;
      0|"") return 0 ;;
      *) warn "${LBL_INVALID}" ;;
    esac
  done
}

menu_install_nfqws() {
  echo
  printf '%s\n' "${BOLD}── ${LBL_INSTALL_TITLE} ──${NC}"
  printf "  %s1)%s  nfqws-keenetic\n" "$GREEN" "$NC"
  printf "  %s2)%s  nfqws2-keenetic\n" "$GREEN" "$NC"
  printf "  %s3)%s  nfqws-keenetic-web\n" "$GREEN" "$NC"
  printf "  %s4)%s  ${LBL_INSTALL_DIRECT}\n" "$GREEN" "$NC"
  printf "  %s0)%s  ${LBL_BACK_ITEM}\n" "$DIM" "$NC"
  ask "${LBL_YOUR_CHOICE} [0]: "
  read_menu choice
  case "$choice" in
    1) install_nfqws1 ;;
    2) install_nfqws2 ;;
    3) install_web ;;
    4) menu_install_ipk_direct ;;
    0|"") return ;;
    *) warn "${LBL_INVALID}" ;;
  esac
}

install_web() {
  info "Установка nfqws-keenetic-web..."
  install_deps
  ensure_openwrt_feed_key "nfqws-keenetic-web" || return 1
  ensure_opkg_repo "nfqws-keenetic-web" "$(nfqws_feed_url nfqws-keenetic-web)"
  if pkg_install nfqws-keenetic-web; then
    refresh_opkg_cache
    if is_installed "nfqws-keenetic-web"; then
      info "Веб-интерфейс установлен."
      info "Адрес: http://$(get_lan_ip):90"
      info "Логин/пароль — учётные данные root-пользователя роутера"
      info "Авторизацию можно отключить: ${CONF_BASE_DIR}/nfqws_web.conf → enabled = false"
      return 0
    fi
    error "pkg_install не сообщил об ошибке, но пакет nfqws-keenetic-web не установлен."
    return 1
  fi
  error "Не удалось установить nfqws-keenetic-web."
  return 1
}

# ---------------------------------------------------------------------------
# 3. Стратегии
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Корневой SHA256SUMS (список strategies/nfqwsN/*.conf без GitHub API)
# ---------------------------------------------------------------------------
REPO_SHA256SUMS_URL="${RAW_BASE}/SHA256SUMS"
REPO_SHA256SUMS_CACHE="/tmp/nfqws-repo-SHA256SUMS"

ensure_repo_sha256sums() {
  local ttl=3600 now age
  now=$(date +%s 2>/dev/null || echo 0)
  if [ -f "$REPO_SHA256SUMS_CACHE" ] && [ -s "$REPO_SHA256SUMS_CACHE" ]; then
    if age=$(stat -c %Y "$REPO_SHA256SUMS_CACHE" 2>/dev/null); then
      [ $((now - age)) -lt "$ttl" ] && return 0
    elif age=$(date -r "$REPO_SHA256SUMS_CACHE" +%s 2>/dev/null); then
      [ $((now - age)) -lt "$ttl" ] && return 0
    else
      return 0
    fi
  fi
  if download_file "$REPO_SHA256SUMS_URL" "$REPO_SHA256SUMS_CACHE"; then
    return 0
  fi
  [ -s "$REPO_SHA256SUMS_CACHE" ] && return 0
  return 1
}

# Имена *.conf из strategies/<ver>/ по корневому SHA256SUMS
list_strategies_from_sums() {
  local ver="$1"
  [ -s "$REPO_SHA256SUMS_CACHE" ] || return 1
  awk -v pref="strategies/${ver}/" '
    NF >= 2 {
      p = $2
      # только strategies/nfqwsN/name.conf (без подкаталогов)
      if (index(p, pref) != 1) next
      rest = substr(p, length(pref) + 1)
      if (rest ~ /\//) next
      if (rest ~ /\.conf$/) print rest
    }
  ' "$REPO_SHA256SUMS_CACHE" | sort -u
}

list_strategies() {
  # 1) SHA256SUMS  2) GitHub API  3) локальный кэш (offline)
  local ver="$1"
  local list="" url cache_list

  if ensure_repo_sha256sums; then
    list=$(list_strategies_from_sums "$ver" || true)
  fi
  if [ -z "$list" ]; then
    url="${STRATEGIES_API}/${ver}"
    list=$(fetch_url "$url" 2>/dev/null | grep -o '"name": *"[^"]*\.conf"' | sed 's/.*"\([^"]*\)".*/\1/' || true)
  fi

  cache_list=$(list_strategies_from_cache "$ver" 2>/dev/null || true)
  if [ -n "$cache_list" ]; then
    list=$(printf '%s\n%s\n' "$list" "$cache_list" | grep -E '\.conf$' | sort -u)
  fi

  if [ -n "$list" ]; then
    printf '%s\n' "$list" | grep -E '\.conf$' || true
    return 0
  fi
  return 1
}


detect_isp_interface() {
  local iface=""
  if command -v ip >/dev/null 2>&1; then
    iface=$(ip route 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  fi
  if [ -z "$iface" ]; then
    iface=$(route -n 2>/dev/null | awk '/^0\.0\.0\.0/ {print $8; exit}')
  fi
  if [ -z "$iface" ]; then
    iface=$(route 2>/dev/null | awk '/^default/ {print $NF; exit}')
  fi
  echo "$iface"
}

# Проверка глобального IPv6 на интерфейсе (любой scope global, не только 2a00*).
# $1 — один iface или несколько через пробел ("ppp0 eth3"): достаточно одного с global.
# Возвращает 0 если найден, иначе 1.
iface_has_global_ipv6() {
  local ifaces="$1" iface
  [ -z "$ifaces" ] && return 1
  for iface in $ifaces; do
    [ -z "$iface" ] && continue
    if command -v ip >/dev/null 2>&1; then
      # любой inet6 … scope global (2a00, 2a02, 2606, 2001, …); без link/host
      if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -qE 'inet6[[:space:]]+[0-9a-fA-F]'; then
        return 0
      fi
    else
      # ifconfig (BusyBox): "inet6 addr: 2a02:…/64 Scope:Global"
      if ifconfig "$iface" 2>/dev/null | grep -qiE 'inet6.*Scope:Global'; then
        return 0
      fi
    fi
  done
  return 1
}

# Записать ISP_INTERFACE="…" в conf (замена или вставка в начало).
set_isp_interface_line() {
  local conf="$1" val="$2"
  [ -n "$val" ] || return 0
  if grep -qE '^ISP_INTERFACE=' "$conf" 2>/dev/null; then
    sed -i "s|^ISP_INTERFACE=.*|ISP_INTERFACE=\"$val\"|" "$conf"
  else
    printf 'ISP_INTERFACE="%s"\n' "$val" | cat - "$conf" > "${conf}.new" && mv "${conf}.new" "$conf"
  fi
}

# $1=conf  $2=опционально: ISP из конфига ДО смены стратегии (эталон для сравнения)
fix_isp_interface() {
  local conf="$1" preferred="${2:-}" detected current ipv6_val current_ipv6 chosen iface_for_v6 conf_isp ans
  detected=$(detect_isp_interface)
  if [ -z "$detected" ]; then
    warn "Не удалось определить интерфейс провайдера (route/ip route)."
    return 1
  fi

  # Эталон: переданное значение из старого конфига, иначе то что уже в conf
  # tr -d '\r"' — иначе CRLF из .conf даёт \r и ломает вывод
  if [ -n "$preferred" ]; then
    current=$(printf '%s' "$preferred" | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  else
    current=$(grep -E '^ISP_INTERFACE=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi

  info "Интерфейс провайдера (default route): ${GREEN}${detected}${NC}"
  if [ -n "$current" ]; then
    info "В текущем конфиге: ISP_INTERFACE=\"${RED}${current}${NC}\""
  else
    info "В текущем конфиге ISP_INTERFACE не задан."
  fi

  chosen=""
  if [ -n "$current" ] && [ "$current" = "$detected" ]; then
    info "ISP_INTERFACE уже совпадает с интерфейсом провайдера."
    chosen="$detected"
  elif [ -z "$current" ]; then
    ask "Установить ISP_INTERFACE=\"${GREEN}${detected}${NC}\"? [${GREEN}Y${NC}/${RED}n${NC}]: "
    read -r ans || ans=n
    case "$ans" in
      n|N|н|Н) warn "ISP_INTERFACE не изменён." ;;
      *) chosen="$detected" ;;
    esac
  else
    # current ≠ detected: Y → detected, N → оставить как в текущем конфиге
    ask "Установить ISP_INTERFACE=\"${GREEN}${detected}${NC}\"? (в текущем конфиге: \"${RED}${current}${NC}\") [${GREEN}Y${NC}/${RED}n${NC}]: "
    read -r ans || ans=n
    case "$ans" in
      n|N|н|Н)
        chosen="$current"
        info "Оставляем ISP_INTERFACE=\"${RED}${current}${NC}\" из текущего конфига."
        ;;
      *) chosen="$detected" ;;
    esac
  fi

  if [ -n "$chosen" ]; then
    conf_isp=$(grep -E '^ISP_INTERFACE=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ "$conf_isp" != "$chosen" ]; then
      set_isp_interface_line "$conf" "$chosen"
      info "ISP_INTERFACE=\"$chosen\" записан в $conf"
    fi
  fi

  # --- IPV6_ENABLED: по фактическому ISP (chosen или то что в conf / detected) ---
  iface_for_v6="$chosen"
  [ -z "$iface_for_v6" ] && iface_for_v6=$(grep -E '^ISP_INTERFACE=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$iface_for_v6" ] && iface_for_v6="$detected"

  echo
  info "=== Проверка IPv6 на $iface_for_v6 ==="
  if iface_has_global_ipv6 "$iface_for_v6"; then
    ipv6_val=1
    info "Найден глобальный IPv6 (scope global) на $iface_for_v6 → IPV6_ENABLED=1"
  else
    ipv6_val=0
    info "Глобальный IPv6 на $iface_for_v6 не найден → IPV6_ENABLED=0"
  fi

  current_ipv6=$(grep -E '^IPV6_ENABLED=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$current_ipv6" = "$ipv6_val" ]; then
    info "IPV6_ENABLED уже = $ipv6_val — без изменений."
  else
    if grep -qE '^IPV6_ENABLED=' "$conf" 2>/dev/null; then
      sed -i "s|^IPV6_ENABLED=.*|IPV6_ENABLED=$ipv6_val|" "$conf"
    else
      if grep -qE '^ISP_INTERFACE=' "$conf" 2>/dev/null; then
        sed -i "/^ISP_INTERFACE=/a IPV6_ENABLED=$ipv6_val" "$conf"
      else
        printf 'IPV6_ENABLED=%s\n' "$ipv6_val" | cat - "$conf" > "${conf}.new" && mv "${conf}.new" "$conf"
      fi
    fi
    info "IPV6_ENABLED=$ipv6_val записан в $conf"
  fi
}

extract_blob_paths() {
  grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | tr ' \t' '\n' | \
    sed -n -e 's/.*@\(\/[^[:space:]"]*\.bin\).*/\1/p' \
           -e 's/.*=\(\/[^[:space:]"]*\.bin\).*/\1/p' | sort -u
}

extract_list_paths() {
  grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | tr ' \t' '\n' | \
    sed -n -e 's/.*[=:]\(\/[^[:space:]"]*\.list\).*/\1/p' \
           -e 's/^\(\/[^[:space:]"]*\.list\)$/\1/p' | sort -u
}

# Универсальная проверка отсутствующих файлов из конфига
# $1=label $2=conf $3=extractor_func $4=repo_subdir $5=ask_msg
check_conf_files() {
  local label="$1" conf="$2" extractor="$3" repo_sub="$4" ask_msg="$5"
  local paths path name missing=0 missing_list=""

  if [ ! -f "$conf" ]; then
    warn "Конфиг $conf не найден — проверка $label пропущена."
    return 1
  fi

  paths=$($extractor "$conf")
  if [ -z "$paths" ]; then
    info "В конфиге нет ссылок на $label — проверка не требуется."
    return 0
  fi

  info "$label, указанные в конфиге:"
  for path in $paths; do
    if [ -f "$path" ]; then
      info "  OK  $path"
    else
      warn "  нет $path"
      missing=1
      missing_list="$missing_list $path"
    fi
  done

  [ "$missing" -eq 0 ] && { info "Все используемые $label на месте."; return 0; }

  warn "Часть $label отсутствует."
  confirm_yes "$ask_msg" || return 0

  for path in $missing_list; do
    name=$(basename "$path")
    mkdir -p "$(dirname "$path")"
    # auto.list заполняется демоном — пустой допустим только для него
    if [ "$repo_sub" = "lists" ] && [ "$name" = "auto.list" ]; then
      touch "$path"
      info "  создан пустой $path (заполняется демоном)"
      continue
    fi
    info "Скачивание $name → $path"
    if download_file "${RAW_BASE}/strategies/${repo_sub}/${name}" "$path"; then
      info "  готово"
    else
      rm -f "$path"
      warn "  нет в репозитории / ошибка загрузки — файл не создан ($name)"
    fi
  done
}

# Проверка blobs: наличие + SHA256 (по strategies/blobs/SHA256SUMS).
# Устаревшие/битые и отсутствующие предлагается скачать.
# $1=ver (не используется, совместимость) $2=conf
check_blobs() {
  local conf="$2"
  local paths path name missing=0 missing_list="" expected local_sha sums_ok=0

  if [ ! -f "$conf" ]; then
    warn "Конфиг $conf не найден — проверка blobs пропущена."
    return 1
  fi

  paths=$(extract_blob_paths "$conf")
  if [ -z "$paths" ]; then
    info "В конфиге нет ссылок на blobs — проверка не требуется."
    return 0
  fi

  if ensure_blobs_sha256sums; then
    sums_ok=1
    info "Эталон SHA256SUMS загружен (кэш: $BLOBS_SHA256SUMS_CACHE)."
  else
    warn "SHA256SUMS недоступен — проверка только по наличию файлов."
  fi

  info "blobs, указанные в конфиге:"
  for path in $paths; do
    name=$(basename "$path")
    if [ ! -f "$path" ]; then
      warn "  нет $path"
      missing=1
      missing_list="$missing_list $path"
      continue
    fi

    if [ "$sums_ok" -eq 1 ] && have_sha256; then
      expected=$(blob_expected_sha256 "$name")
      if [ -n "$expected" ]; then
        local_sha=$(file_sha256 "$path" || true)
        if [ -n "$local_sha" ] && [ "$local_sha" = "$expected" ]; then
          info "  OK  $path  (sha256)"
        else
          warn "  устарел/повреждён $path"
          [ -n "$local_sha" ] && info "    local  $local_sha"
          info "    expect $expected"
          missing=1
          missing_list="$missing_list $path"
        fi
      else
        info "  OK  $path  (нет в SHA256SUMS)"
      fi
    else
      info "  OK  $path"
    fi
  done

  [ "$missing" -eq 0 ] && { info "Все используемые blobs на месте и актуальны."; return 0; }

  warn "Часть blobs отсутствует или не совпадает с репозиторием."
  confirm_yes "Скачать отсутствующие/устаревшие blobs из strategies/blobs/?" || return 0

  for path in $missing_list; do
    name=$(basename "$path")
    mkdir -p "$(dirname "$path")"
    info "Скачивание $name → $path"
    if ! download_file "${RAW_BASE}/strategies/blobs/${name}" "$path"; then
      rm -f "$path"
      warn "  нет в репозитории / ошибка загрузки — файл не создан ($name)"
      continue
    fi
    # пост-проверка SHA при наличии эталона
    if [ "$sums_ok" -eq 1 ] && have_sha256; then
      expected=$(blob_expected_sha256 "$name")
      if [ -n "$expected" ]; then
        local_sha=$(file_sha256 "$path" || true)
        if [ -n "$local_sha" ] && [ "$local_sha" = "$expected" ]; then
          info "  готово (sha256 OK)"
        else
          warn "  скачан, но sha256 не совпал — удаляю $path"
          [ -n "$local_sha" ] && info "    local  $local_sha"
          info "    expect $expected"
          rm -f "$path"
        fi
      else
        info "  готово (нет эталона в SHA256SUMS)"
      fi
    else
      info "  готово"
    fi
  done
}

check_lists() { check_conf_files "lists" "$2" extract_list_paths "lists" "Скачать отсутствующие lists из strategies/lists/?"; }

update_lists() {
  local ver="$1" dest_dir name
  dest_dir=$(nfqws_lists_dir "$ver")
  mkdir -p "$dest_dir"
  for name in user.list exclude.list ipset.list ipset_exclude.list; do
    info "Обновление $name ..."
    if download_file "${RAW_BASE}/strategies/lists/${name}" "${dest_dir}/${name}"; then
      info "  → ${dest_dir}/${name}"
    else
      warn "  не удалось скачать $name (пропуск)"
    fi
  done
  info "Списки обновлены (auto.list не изменялся)."
}

apply_strategy() {
  local ver="$1" conf_name="$2" conf_path conf_dest tmp had_rkn=0 rkn_path
  local init_script stopped_svc=0 cache_file saved_isp=""

  conf_dest=$(nfqws_conf_path "$ver")

  if [ "$conf_name" = "default" ]; then
    if [ "$ver" = "1" ]; then
      conf_path="https://raw.githubusercontent.com/nfqws/nfqws-keenetic/master/etc/nfqws/nfqws.conf"
    else
      conf_path="https://raw.githubusercontent.com/nfqws/nfqws2-keenetic/master/etc/nfqws2/nfqws2.conf"
    fi
  else
    conf_path="${RAW_BASE}/strategies/nfqws${ver}/${conf_name}"
  fi

  if [ ! -f "$conf_dest" ]; then
    error "Конфиг $conf_dest не найден. Сначала установите соответствующий пакет."
    return 1
  fi

  # Запоминаем привязку rkn.list в MODE_LIST — стратегия перезапишет весь конфиг
  if conf_has_rkn_hostlist "$conf_dest" "$ver"; then
    had_rkn=1
    info "В текущем конфиге есть привязка rkn.list — будет восстановлена после смены стратегии."
  fi

  # ISP_INTERFACE из текущего конфига (до замены стратегией) — эталон для сравнения с route
  if grep -qE '^ISP_INTERFACE=' "$conf_dest" 2>/dev/null; then
    saved_isp=$(grep -E '^ISP_INTERFACE=' "$conf_dest" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi

  info "Скачивание стратегии: $conf_name"
  info "URL: $conf_path"
  tmp="/tmp/nfqws-strategy-$$.conf"
  init_script=$(nfqws_init_path "$ver")

  if ! download_file "$conf_path" "$tmp"; then
    # default: запасной branch main
    if [ "$conf_name" = "default" ] && echo "$conf_path" | grep -q '/master/'; then
      conf_path=$(echo "$conf_path" | sed 's|/master/|/main/|')
      info "Пробуем branch main: $conf_path"
      download_file "$conf_path" "$tmp" || true
    fi
  fi

  # Сеть/DPI мешают — остановить nfqws и повторить (сервис может ломать загрузку)
  if [ ! -s "$tmp" ] && [ -x "$init_script" ]; then
    warn "Скачивание не удалось — останавливаем $(basename "$init_script") и пробуем снова..."
    "$init_script" stop 2>/dev/null || true
    stopped_svc=1
    sleep 1
    download_file "$conf_path" "$tmp" || true
  fi

  if [ ! -s "$tmp" ]; then
    # offline: локальный кэш
    cache_file=$(cache_strategy_path "$ver" "$conf_name")
    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
      warn "Сеть недоступна — берём из кэша: $cache_file"
      cp "$cache_file" "$tmp"
    else
      error "Не удалось скачать $conf_path (и нет кэша offline)"
      [ "$stopped_svc" -eq 1 ] && service_restart "$init_script"
      rm -f "$tmp"
      return 1
    fi
  else
    save_strategy_cache "$ver" "$conf_name" "$tmp" 2>/dev/null || true
  fi

  # CRLF → LF: иначе source конфига даёт «: not found» и ломает порты в iptables
  if tr -d '\r' < "$tmp" > "${tmp}.lf" 2>/dev/null; then
    mv "${tmp}.lf" "$tmp"
  else
    rm -f "${tmp}.lf"
  fi

  # Стратегии в репозитории написаны под Entware (/opt/etc/nfqws*) —
  # на OpenWrt пакет живёт в /etc/nfqws*, подменяем префикс путей.
  strategy_retarget_paths "$tmp"

  backup_file "$conf_dest"

  if grep -qE '^(ISP_INTERFACE|NFQWS_ARGS|NFQWS_BASE_ARGS)=' "$tmp" 2>/dev/null; then
    cp "$tmp" "$conf_dest"
    info "Конфиг полностью заменён стратегией $conf_name"
  else
    warn "Файл стратегии не выглядит как полный конфиг — попробуйте вручную."
    cat "$tmp"
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"

  echo
  info "=== Проверка ISP_INTERFACE / IPV6_ENABLED ==="
  # $saved_isp — значение из конфига до смены стратегии
  fix_isp_interface "$conf_dest" "$saved_isp"

  echo
  info "=== Проверка blobs ==="
  check_blobs "$ver" "$conf_dest"

  echo
  info "=== Проверка lists ==="
  check_lists "$ver" "$conf_dest"

  echo
  if confirm_no "Принудительно обновить все lists (user/exclude/ipset) из репозитория?"; then
    update_lists "$ver"
  else
    info "Принудительное обновление lists пропущено."
  fi

  # Восстановить привязку rkn.list в MODE_LIST, если она была до смены стратегии
  if [ "$had_rkn" -eq 1 ]; then
    echo
    info "=== Восстановление rkn.list в MODE_LIST ==="
    # skip_backup=1 — бэкап уже сделан перед заменой конфига стратегией
    if inject_rkn_into_mode_list "$ver" "$conf_dest" 1; then
      rkn_path=$(rkn_list_path "$ver" 2>/dev/null || true)
      if [ -n "$rkn_path" ] && [ ! -f "$rkn_path" ]; then
        warn "Файл $rkn_path отсутствует — скачайте через пункт меню «rkn.list»."
      fi
    fi
  fi

  # ts-фулинг: нужен TCP timestamp на Windows
  warn_ts_fooling "$conf_dest"

  echo
  service_restart "$(nfqws_init_path "$ver")"
  info "Сервис перезапущен."
}

# Предупреждение, если в конфиге --dpi-desync-fooling=ts или tcp_ts
warn_ts_fooling() {
  local conf="$1"
  [ -f "$conf" ] || return 0
  # ищем в не-комментариях
  if ! grep -vE '^[[:space:]]*#' "$conf" 2>/dev/null | grep -qE -- '--dpi-desync-fooling=ts|tcp_ts'; then
    return 0
  fi
  echo
  printf '%s\n' "${RED}${BOLD}⚠ ВАЖНО${NC}"
  printf '%s\n' "${RED}При использовании ts-фулинг в стратегиях нужно убедиться,${NC}"
  printf '%s\n' "${RED}что TCP timestamp включён и работает (только для WINDOWS ОС).${NC}"
  echo
  printf '%s\n' "${RED}Включить метки времени RFC 1323 (CMD от администратора):${NC}"
  echo
  printf '%s\n' "${RED}  netsh interface tcp set global timestamps=enabled${NC}"
  echo
}

# Метка стратегии из комментария: # general (SIMPLE FAKE ALT).bat -> nfqws2
# Возвращает текст в скобках как есть (для отображения).
detect_current_strategy() {
  local conf="$1"
  [ -f "$conf" ] || return 0
  grep -iE 'general[[:space:]]*\(' "$conf" 2>/dev/null | \
    sed -n 's/.*(\([^)]*\)).*/\1/p' | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Нормализация для сравнения: "SIMPLE FAKE ALT" / simple_fake_alt → simplefakealt
strategy_id_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]_-'
}

# Восстановление конфига из .bak.* (nfqws.conf.bak.YYYYMMDDHHMMSS / nfqws2.conf.bak.…)
restore_conf_from_backup() {
  local ver="$1"
  local conf_dest conf_dir conf_base bak_list i f num selected strat tag count=0

  conf_dest=$(nfqws_conf_path "$ver")
  conf_dir=$(dirname "$conf_dest")
  conf_base=$(basename "$conf_dest")

  echo
  info "Резервные копии конфига ($conf_base) — NFQWS V${ver}:"
  # от свежего к старому (timestamp в имени: .bak.YYYYMMDDHHMMSS)
  bak_list=$(
    for f in "$conf_dir"/"$conf_base".bak.*; do
      [ -f "$f" ] || continue
      echo "$f"
    done | sort -r
  )
  for f in $bak_list; do
    count=$((count + 1))
    # стратегия из комментария вида: #  general (ALT11).bat  ->  nfqws2
    strat=$(grep -iE 'general[[:space:]]*\(' "$f" 2>/dev/null | \
      sed -n 's/.*(\([^)]*\)).*/\1/p' | head -1 | tr -d '[:space:]')
    if [ -n "$strat" ]; then
      tag=" ($strat)"
    else
      tag=""
    fi
    if [ "$count" -eq 1 ]; then
      printf "  %s%2d) %s%s%s\n" "$YELLOW$BOLD" "$count" "$(basename "$f")" "$tag" "$NC"
    else
      printf "  %2d) %s%s\n" "$count" "$(basename "$f")" "$tag"
    fi
  done

  if [ "$count" -eq 0 ]; then
    warn "Резервные копии не найдены в $conf_dir"
    return 0
  fi

  echo "   0) ${LBL_BACK_ITEM}"
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r num
  [ -z "$num" ] || [ "$num" = "0" ] && return 0

  i=1
  selected=""
  for f in $bak_list; do
    if [ "$i" = "$num" ]; then
      selected="$f"
      break
    fi
    i=$((i + 1))
  done
  [ -z "$selected" ] && { warn "Неверный номер"; return 1; }

  echo
  info "Восстановление из: $(basename "$selected")"
  info "В текущий конфиг:  $conf_dest"
  if ! confirm_yes "Восстановить этот бэкап?"; then
    info "Отменено."
    return 0
  fi

  if ! cp -a "$selected" "$conf_dest"; then
    error "Не удалось скопировать $selected → $conf_dest"
    return 1
  fi
  info "Конфиг восстановлен из $(basename "$selected")"

  echo
  info "=== Проверка ISP_INTERFACE / IPV6_ENABLED ==="
  fix_isp_interface "$conf_dest"

  echo
  service_restart "$(nfqws_init_path "$ver")"
  info "Сервис перезапущен."
}

menu_strategy() {
  need_nfqws_installed || return
  pick_nfqws_ver 0 || return

  local conf_dest current_id dir list i files f base num idx selected
  local cache_file has_cache
  conf_dest=$(nfqws_conf_path "$NFQWS_VER")
  current_id=$(detect_current_strategy "$conf_dest")
  [ -n "$current_id" ] && info "Текущая стратегия в конфиге: $current_id"

  dir="nfqws${NFQWS_VER}"
  echo
  info "Доступные стратегии ($dir):"
  list=$(list_strategies "$dir" || true)
  if [ -z "$list" ]; then
    warn "Не удалось получить список стратегий (сеть / GitHub)."
    warn "Пробуем зеркала CDN и offline-кэш; default — из nfqws или кэша."
  fi

  i=1
  files="default"
  cache_file=$(cache_strategy_path "$NFQWS_VER" "default")
  has_cache=0
  [ -f "$cache_file" ] && [ -s "$cache_file" ] && has_cache=1
  if [ -z "$current_id" ]; then
    printf "  %s%2d) default  (стандартная из репозитория nfqws)  <-- текущая?%s\n" "$GREEN$BOLD" "$i" "$NC"
  elif [ "$has_cache" -eq 1 ]; then
    printf "  %s%2d) default  (стандартная из репозитория nfqws)%s\n" "$CYAN" "$i" "$NC"
  else
    printf "  %2d) default  (стандартная из репозитория nfqws)\n" "$i"
  fi
  i=2

  # shellcheck disable=SC2086
  for f in $list; do
    base=$(echo "$f" | sed 's/\.conf$//' | tr '[:upper:]' '[:lower:]')
    cache_file=$(cache_strategy_path "$NFQWS_VER" "$f")
    has_cache=0
    [ -f "$cache_file" ] && [ -s "$cache_file" ] && has_cache=1
    # SIMPLE FAKE ALT ↔ simple_fake_alt (пробелы/подчёркивания не учитываем)
    if [ -n "$current_id" ] && [ "$(strategy_id_norm "$base")" = "$(strategy_id_norm "$current_id")" ]; then
      printf "  %s%2d) %s  <-- текущая%s\n" "$GREEN$BOLD" "$i" "$f" "$NC"
    elif [ "$has_cache" -eq 1 ]; then
      printf "  %s%2d) %s%s\n" "$CYAN" "$i" "$f" "$NC"
    else
      printf "  %2d) %s\n" "$i" "$f"
    fi
    files="$files $f"
    i=$((i + 1))
  done
  printf '  %s99) Восстановление из backup%s\n' "${YELLOW}${BOLD}" "$NC"
  echo "   0) ${LBL_BACK_ITEM}"
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r num
  [ -z "$num" ] || [ "$num" = "0" ] && return

  if [ "$num" = "99" ]; then
    restore_conf_from_backup "$NFQWS_VER"
    return
  fi

  idx=1
  selected=""
  for f in $files; do
    if [ "$idx" = "$num" ]; then
      selected="$f"
      break
    fi
    idx=$((idx + 1))
  done
  [ -z "$selected" ] && { warn "Неверный номер"; return; }

  apply_strategy "$NFQWS_VER" "$selected"
}

# ---------------------------------------------------------------------------
# 4. IPSet List
# ---------------------------------------------------------------------------
IPSET_FLOWSEAL_URL="https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt"
# Стандартные списки из официальных пакетов nfqws
IPSET_NFQWS1_URL="https://raw.githubusercontent.com/nfqws/nfqws-keenetic/master/etc/nfqws/ipset.list"
IPSET_NFQWS2_URL="https://raw.githubusercontent.com/nfqws/nfqws2-keenetic/master/etc/nfqws2/lists/ipset.list"

# Санитизация hostlist/ipset: без #/; пустых, хвостовых пробелов и \r (CRLF).
# $1=src $2=dest. 0=ok, 1=пусто/ошибка. Число записей — в глобальной
# _LIST_CLEAN_COUNT: явный контракт вместо скрытого динамического скоупа $count.
_list_file_clean() {
  local src="$1" dest="$2"
  awk '!/^[[:space:]]*([#;]|$)/ {
    gsub(/[ \t\r]+$/, "")
    if ($0 != "") print
  }' "$src" > "$dest" 2>/dev/null || true
  _LIST_CLEAN_COUNT=$(wc -l < "$dest" 2>/dev/null | tr -d ' ')
  case "$_LIST_CLEAN_COUNT" in ''|*[!0-9]*) _LIST_CLEAN_COUNT=0 ;; esac
  [ "$_LIST_CLEAN_COUNT" -gt 0 ]
}

# Скачать URL → tmp (очищенный in-place). Выставляет count. 0=ok, 1=ошибка.
_ipset_fetch_clean() {
  local url="$1" tmp="$2"
  info "URL: $url"
  if ! download_file "$url" "$tmp"; then
    error "Не удалось скачать список."
    return 1
  fi
  if ! _list_file_clean "$tmp" "${tmp}.clean"; then
    error "Скачанный файл пуст или не содержит записей."
    rm -f "$tmp" "${tmp}.clean"
    return 1
  fi
  mv -f "${tmp}.clean" "$tmp"
  info "Записей в списке: $_LIST_CLEAN_COUNT"
  return 0
}

_ipset_write_file() {
  local src="$1" dest="$2" cnt="$3" dir
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  backup_file "$dest"
  cp "$src" "$dest"
  info "Записано: $dest ($cnt строк)"
}

_ipset_apply_and_restart() {
  local src="$1" cnt="$2"
  case "$NFQWS_VER" in
    1)
      _ipset_write_file "$src" "$(nfqws_lists_dir 1)/ipset.list" "$cnt"
      service_restart "$(nfqws_init_path 1)"
      info "Сервис nfqws перезапущен."
      ;;
    2)
      _ipset_write_file "$src" "$(nfqws_lists_dir 2)/ipset.list" "$cnt"
      service_restart "$(nfqws_init_path 2)"
      info "Сервис nfqws2 перезапущен."
      ;;
    both)
      _ipset_write_file "$src" "$(nfqws_lists_dir 1)/ipset.list" "$cnt"
      _ipset_write_file "$src" "$(nfqws_lists_dir 2)/ipset.list" "$cnt"
      service_restart "$(nfqws_init_path 1)"
      service_restart "$(nfqws_init_path 2)"
      info "Сервисы перезапущены."
      ;;
  esac
}

# Скачать (с очисткой) и применить ipset к текущей NFQWS_VER. 0=ok.
_ipset_fetch_apply() {
  local url="$1" tmp="$2"
  _ipset_fetch_clean "$url" "$tmp" || return 1
  _ipset_apply_and_restart "$tmp" "$_LIST_CLEAN_COUNT"
  return 0
}

update_ipset_list() {
  need_nfqws_installed || return

  local choice tmp src_label
  tmp="/tmp/nfqws-ipset-$$.txt"

  echo
  printf '%s\n' "${RED}${BOLD}${LBL_IPSET_WARN1}${NC}"
  printf '%s\n' "${RED}${LBL_IPSET_WARN2}${NC}"
  printf '%s\n' "${RED}${LBL_IPSET_WARN3}${NC}"
  printf '%s\n' "${RED}${LBL_IPSET_WARN4}${NC}"
  echo
  echo "  1) ${LBL_IPSET_OPT1}"
  echo "  2) ${LBL_IPSET_OPT2}"
  echo "  0) ${LBL_BACK_ITEM}"
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r choice
  case "$choice" in
    1) ;;
    2) ;;
    0|"") return 0 ;;
    *) warn "${LBL_INVALID}"; return 1 ;;
  esac

  pick_nfqws_ver 1 || return

  if [ "$choice" = "1" ]; then
    src_label="Flowseal/zapret-discord-youtube"
    info "Скачивание IPSet с $src_label ..."
    _ipset_fetch_apply "$IPSET_FLOWSEAL_URL" "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
  fi

  # choice=2 — стандартный ipset из поставки пакета (URL зависит от версии)
  src_label="nfqws (поставка пакета)"
  info "Скачивание стандартного IPSet ($src_label) ..."

  case "$NFQWS_VER" in
    1)
      _ipset_fetch_apply "$IPSET_NFQWS1_URL" "$tmp" || { rm -f "$tmp"; return 1; }
      ;;
    2)
      _ipset_fetch_apply "$IPSET_NFQWS2_URL" "$tmp" || { rm -f "$tmp"; return 1; }
      ;;
    both)
      # одна из версий может не скачаться — ставим то, что скачалось
      _ipset_fetch_apply "$IPSET_NFQWS1_URL" "$tmp" || warn "nfqws1: ipset.list не обновлён."
      _ipset_fetch_apply "$IPSET_NFQWS2_URL" "$tmp" || warn "nfqws2: ipset.list не обновлён."
      ;;
  esac
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 5. rkn.list (zapret4rocket) → lists + MODE_LIST (nfqws v1 / nfqws2)
# ---------------------------------------------------------------------------
RKN_LIST_URL="https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/master/extra_strats/TCP/RKN/List.txt"
# Зеркало (как в zapret4rocket/z4r) — если GitHub raw режется DPI
RKN_LIST_MIRROR_URL="http://mizulina.shit.vc:666/IndeecFOX/zapret4rocket/master/extra_strats/TCP/RKN/List.txt"

# Аргумент --hostlist=.../rkn.list для указанной версии nfqws (путь — rkn_list_path)
rkn_hostlist_arg() {
  local p
  p=$(rkn_list_path "$1") || return 1
  printf '%s\n' "--hostlist=$p"
}

# Путь к rkn.list для версии
rkn_list_path() {
  case "$1" in
    1) echo "$(nfqws_lists_dir 1)/rkn.list" ;;
    2) echo "$(nfqws_lists_dir 2)/rkn.list" ;;
    *) return 1 ;;
  esac
}

# Есть ли в конфиге привязка rkn.list (MODE_LIST / hostlist)
conf_has_rkn_hostlist() {
  local conf="$1" ver="$2" arg
  arg=$(rkn_hostlist_arg "$ver") || return 1
  [ -f "$conf" ] || return 1
  grep -qF -- "$arg" "$conf" 2>/dev/null
}

# Вставить --hostlist=.../rkn.list в MODE_LIST конфига (идемпотентно).
# Возвращает 0 если уже было / успешно добавлено, 1 при ошибке.
# $1=ver  $2=conf (опционально; по умолчанию nfqws_conf_path)
# $3=1 — не делать backup (уже сделан, напр. в apply_strategy)
inject_rkn_into_mode_list() {
  local ver="$1" conf="${2:-}" skip_backup="${3:-0}" hostlist_arg user_list tmp_conf
  hostlist_arg=$(rkn_hostlist_arg "$ver") || return 1
  [ -z "$conf" ] && conf=$(nfqws_conf_path "$ver")
  [ -f "$conf" ] || { warn "Конфиг не найден: $conf — MODE_LIST не обновлён."; return 1; }

  case "$ver" in
    1) user_list="$(nfqws_lists_dir 1)/user.list" ;;
    2) user_list="$(nfqws_lists_dir 2)/user.list" ;;
  esac

  # уже есть
  if grep -qF -- "$hostlist_arg" "$conf" 2>/dev/null; then
    info "MODE_LIST уже содержит $hostlist_arg"
    return 0
  fi

  if grep -qE '^[[:space:]]*MODE_LIST=' "$conf" 2>/dev/null; then
    [ "$skip_backup" = "1" ] || backup_file "$conf"
    # Вставляем --hostlist=...rkn.list перед закрывающей кавычкой.
    # awk надёжнее busybox sed (пробелы, пустые кавычки, CRLF, single quotes).
    tmp_conf="/tmp/nfqws-mode-$$.conf"
    awk -v arg="$hostlist_arg" '
      BEGIN { done=0 }
      /^[[:space:]]*MODE_LIST=/ && !done {
        line=$0
        sub(/\r$/, "", line)
        # MODE_LIST="content"  → MODE_LIST="content arg"  (или пустые кавычки)
        if (match(line, /^[[:space:]]*MODE_LIST="/)) {
          prefix = substr(line, 1, RSTART+RLENGTH-1)  # включая открывающую "
          rest = substr(line, RSTART+RLENGTH)
          if (match(rest, /"/)) {
            content = substr(rest, 1, RSTART-1)
            gsub(/[ \t]+$/, "", content)
            if (content == "")
              print prefix arg "\""
            else
              print prefix content " " arg "\""
          } else {
            print line " " arg
          }
        } else {
          print line " " arg
        }
        done=1
        next
      }
      { print }
    ' "$conf" > "$tmp_conf" && mv "$tmp_conf" "$conf"
    if grep -qF -- "$hostlist_arg" "$conf" 2>/dev/null; then
      info "В MODE_LIST добавлено: $hostlist_arg"
      return 0
    fi
    warn "Не удалось изменить MODE_LIST автоматически — добавьте вручную:"
    warn "  MODE_LIST=\"... $hostlist_arg\""
    rm -f "$tmp_conf"
    return 1
  fi

  # MODE_LIST отсутствует — создаём с user.list + rkn
  [ "$skip_backup" = "1" ] || backup_file "$conf"
  printf '\nMODE_LIST="--hostlist=%s %s"\n' "$user_list" "$hostlist_arg" >> "$conf"
  info "MODE_LIST создан с user.list и rkn.list"
  return 0
}

# Применить rkn.list к выбранной версии: $1=ver $2=src_tmp $3=count $4=skip_download
_rkn_apply_for_ver() {
  local ver="$1" src_tmp="$2" cnt="$3" skip_dl="$4"
  local dest init_script conf need_restart=0 had_rkn=0

  dest=$(rkn_list_path "$ver") || return 1
  init_script=$(nfqws_init_path "$ver")
  conf=$(nfqws_conf_path "$ver")

  if [ "$skip_dl" -eq 0 ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src_tmp" "$dest"
    info "Записано: $dest ($cnt строк)"
    need_restart=1
  fi

  # Была ли привязка до inject (чтобы не перезапускать зря)
  conf_has_rkn_hostlist "$conf" "$ver" && had_rkn=1

  inject_rkn_into_mode_list "$ver" "$conf" || true

  # Перезапуск: обновили файл списка ИЛИ только что добавили в MODE_LIST
  if [ "$need_restart" -eq 1 ] || [ "$had_rkn" -eq 0 ]; then
    if [ "$had_rkn" -eq 0 ] && conf_has_rkn_hostlist "$conf" "$ver"; then
      need_restart=1
    fi
  fi

  if [ "$need_restart" -eq 1 ]; then
    service_restart "$init_script"
    info "Сервис перезапущен ($init_script)."
  else
    info "Изменений нет — перезапуск сервиса не требуется (v$ver)."
  fi
}

update_rkn_list() {
  need_nfqws_installed || return
  pick_nfqws_ver 1 || return

  local tmp="/tmp/nfqws-rkn-$$.txt"
  local skip_download=0

  # Проверяем существующие файлы (любая из выбранных версий)
  local check_dest=""
  case "$NFQWS_VER" in
    1)   check_dest=$(rkn_list_path 1) ;;
    2)   check_dest=$(rkn_list_path 2) ;;
    both) check_dest=$(rkn_list_path 2)
          [ -f "$(rkn_list_path 1)" ] && check_dest=$(rkn_list_path 1)
          ;;
  esac

  if [ -n "$check_dest" ] && [ -f "$check_dest" ]; then
    # Не считаем 125k строк через grep — на роутере это долго.
    # Размер в КБ (мгновенно); точный count — только после скачивания.
    local existing_kb
    existing_kb=$(wc -c < "$check_dest" 2>/dev/null | tr -d ' ')
    if [ -n "$existing_kb" ] && [ "$existing_kb" -gt 0 ] 2>/dev/null; then
      existing_kb=$((existing_kb / 1024))
    else
      existing_kb="?"
    fi
    info "Файл уже существует: $check_dest (${existing_kb} КБ)"
    if ! confirm_no "Обновить rkn.list?"; then
      info "Обновление списка пропущено."
      skip_download=1
    fi
  fi

  if [ "$skip_download" -eq 0 ]; then
    info "Скачивание rkn.list (zapret4rocket, ~2 МБ) ..."
    # Сначала GitHub raw; зеркала — если raw недоступен (DPI)
    local _old_max="$CURL_MAX_TIME" _old_wget="$WGET_TIMEOUT" _ok=0 _u
    CURL_MAX_TIME="${CURL_MAX_TIME_LARGE:-180}"
    WGET_TIMEOUT="$CURL_MAX_TIME"
    for _u in \
      "$RKN_LIST_URL" \
      "https://cdn.jsdelivr.net/gh/IndeecFOX/zapret4rocket@master/extra_strats/TCP/RKN/List.txt" \
      "https://fastly.jsdelivr.net/gh/IndeecFOX/zapret4rocket@master/extra_strats/TCP/RKN/List.txt" \
      "https://ghproxy.net/https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/master/extra_strats/TCP/RKN/List.txt" \
      "$RKN_LIST_MIRROR_URL"
    do
      [ -n "$_u" ] || continue
      info "URL: $_u"
      if download_file_progress "$_u" "$tmp"; then
        # sanity: rkn.list должен быть заметного размера (>100 КБ)
        local _sz
        _sz=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
        if [ -n "$_sz" ] && [ "$_sz" -gt 100000 ] 2>/dev/null; then
          info "Получено: $((_sz / 1024)) КБ"
          _ok=1
          break
        fi
        warn "Скачано слишком мало байт ($_sz) — пробуем следующий источник..."
        rm -f "$tmp"
      else
        warn "Не удалось с этого URL — следующий источник..."
      fi
    done
    CURL_MAX_TIME="$_old_max"
    WGET_TIMEOUT="$_old_wget"
    if [ "$_ok" -ne 1 ]; then
      error "Не удалось скачать rkn.list (все источники недоступны или таймаут)."
      rm -f "$tmp"
      return 1
    fi

    if ! _list_file_clean "$tmp" "${tmp}.clean"; then
      error "Скачанный файл пуст или не содержит записей."
      rm -f "$tmp" "${tmp}.clean"
      return 1
    fi
    mv -f "${tmp}.clean" "$tmp"
    info "Записей в списке: $_LIST_CLEAN_COUNT"
  fi

  case "$NFQWS_VER" in
    1)   _rkn_apply_for_ver 1 "$tmp" "$_LIST_CLEAN_COUNT" "$skip_download" ;;
    2)   _rkn_apply_for_ver 2 "$tmp" "$_LIST_CLEAN_COUNT" "$skip_download" ;;
    both)
      _rkn_apply_for_ver 1 "$tmp" "$_LIST_CLEAN_COUNT" "$skip_download"
      _rkn_apply_for_ver 2 "$tmp" "$_LIST_CLEAN_COUNT" "$skip_download"
      ;;
  esac

  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 6. DoT/DoH bypass strategy в NFQWS_ARGS_CUSTOM
# Стратегии: strategies/dns_filter_nfqws1 | strategies/dns_filter_nfqws2
# ---------------------------------------------------------------------------

# Fallback, если скачивание с GitHub недоступно (формат nfqws2 / lua)
DOT_DOH_STRATEGY_NFQWS2='#DNS
--filter-tcp=443,853
--filter-l7=http,tls
--hostlist-domains=dns.iij.jp,dot.sb,dns.sb,doh.sb,dns.google,dot.pub,doh.pub,controld.com,opendns.com,anycast.censurfridns.dk,dns.alidns.com,libredns.gr,cloudflare-dns.com,one.one.one.one,opennameserver.org,cleanbrowsing.org,dns.adguard-dns.com,dns.comss.one,xbox-dns.ru,dns.malw.link,geohide.ru,dns.nextdns.io,dns10.quad9.net,dns.astracat.network,dns.bezmezhau.com,dns.dns-ai.ru,dns.mafioznik.xyz,free.shecan.ir
--out-range=-d10
--payload=tls_client_hello,http_req
--lua-desync=multisplit:pos=1,host+2,midsld+2,endsld-2:seqovl=4:tcp_ts_up
--lua-desync=fake:blob=tls_clienthello:tcp_md5:tcp_seq=10000:tls_mod=rnd,dupsid,sni=ozon.ru:repeats=3
--new
--filter-tcp=443,853
--filter-l7=http,tls
--ipset-ip=104.16.248.249,104.16.249.249,91.239.100.100,89.233.43.71,8.8.8.8,8.8.4.4,1.12.12.12,120.53.53.53,208.67.222.222,208.67.220.220,223.5.5.5,223.6.6.6,116.202.176.26,1.1.1.1,1.0.0.1,1.1.1.2,1.0.0.2,1.1.1.3,1.0.0.3,217.160.70.42,213.202.211.221,81.169.136.222,185.181.61.24,185.228.168.9,185.228.169.9,94.140.14.14,94.140.15.15,94.140.14.140,94.140.14.141,94.140.14.15,94.140.15.16,45.90.28.94,45.90.30.94,76.76.2.11,76.76.10.11,9.9.9.9,9.9.9.10,149.112.112.112,185.222.222.222,45.11.45.11,172.104.93.80
--out-range=-d10
--payload=tls_client_hello,http_req
--lua-desync=multisplit:pos=1,27:seqovl=4:tcp_ts_up
--lua-desync=fake:blob=tls_clienthello:tcp_md5:tcp_seq=10000:tls_mod=rnd,dupsid,sni=ozon.ru:repeats=3
--new
--filter-udp=443,853
--filter-l7=quic
--hostlist-domains=cloudflare-dns.com,dns.adguard-dns.com,dns.nextdns.io,nextdns.io,dns.google,controld.com
--payload=quic_initial
--lua-desync=send:ipfrag:ipfrag_pos_udp=88'

# Fallback для nfqws1 (классический dpi-desync)
DOT_DOH_STRATEGY_NFQWS1='#DNS
--filter-tcp=443,853 --filter-l7=http,tls --hostlist-domains=dns.iij.jp,dot.sb,dns.sb,doh.sb,dns.google,dot.pub,doh.pub,controld.com,opendns.com,anycast.censurfridns.dk,dns.alidns.com,libredns.gr,cloudflare-dns.com,one.one.one.one,opennameserver.org,cleanbrowsing.org,dns.adguard-dns.com,dns.comss.one,xbox-dns.ru,dns.malw.link,geohide.ru,dns.nextdns.io,dns10.quad9.net,dns.astracat.network,dns.bezmezhau.com,dns.dns-ai.ru,dns.mafioznik.xyz,free.shecan.ir --dpi-desync=multisplit,fake --dpi-desync-split-pos=1,host+2,midsld+2,endsld-2 --dpi-desync-split-seqovl=4 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls=/etc/nfqws/tls_clienthello.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=ozon.ru --dpi-desync-repeats=3
--new
--filter-tcp=443,853 --filter-l7=http,tls --ipset-ip=104.16.248.249,104.16.249.249,91.239.100.100,89.233.43.71,8.8.8.8,8.8.4.4,1.12.12.12,120.53.53.120,208.67.222.222,208.67.220.220,223.5.5.5,223.6.6.6,116.202.176.26,1.1.1.1,1.0.0.1,1.1.1.2,1.0.0.2,1.1.1.3,1.0.0.3,217.160.70.42,213.202.211.221,81.169.136.222,185.181.61.24,185.228.168.9,185.228.169.9,94.140.14.14,94.140.15.15,94.140.14.140,94.140.14.141,94.140.14.15,94.140.15.16,45.90.28.94,45.90.30.94,76.76.2.11,76.76.10.11,9.9.9.9,9.9.9.10,149.112.112.112,185.222.222.222,45.11.45.11,172.104.93.80 --dpi-desync=multisplit,fake --dpi-desync-split-pos=1,27 --dpi-desync-split-seqovl=4 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls=/etc/nfqws/tls_clienthello.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=ozon.ru --dpi-desync-repeats=3
--new
--filter-udp=443,853 --filter-l7=quic --hostlist-domains=cloudflare-dns.com,dns.adguard-dns.com,dns.nextdns.io,nextdns.io,dns.google,controld.com --dpi-desync=ipfrag2 --dpi-desync-ipfrag-pos-udp=88'

ensure_port_in_var() {
  local conf_file="$1" var="$2" port="$3" line val new_val
  line=$(grep -E "^${var}=" "$conf_file" 2>/dev/null | head -1)
  if [ -z "$line" ]; then
    printf '%s=%s\n' "$var" "$port" >> "$conf_file"
    info "${var}: создано со значением $port"
    return 0
  fi
  val=${line#${var}=}
  val=$(echo "$val" | tr -d '"' | tr -d "'")
  if echo ",$val," | grep -qE ",${port},"; then
    info "${var}: порт $port уже есть ($val)"
    return 0
  fi
  if [ -z "$val" ]; then new_val="$port"; else new_val="${val},${port}"; fi
  sed -i "s|^${var}=.*|${var}=${new_val}|" "$conf_file"
  info "${var}: добавлен порт $port → ${new_val}"
}

# Загрузить стратегию dns_filter для ver=1|2 в strat_tmp; return 0 при успехе
load_dot_doh_strategy() {
  local ver="$1" dest="$2"
  local url="${RAW_BASE}/strategies/dns_filter_nfqws${ver}"
  local tmp="/tmp/dns_filter_nfqws${ver}-$$.txt"

  rm -f "$tmp"
  if download_file "$url" "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    # убрать CRLF и пустые ведущие строки
    tr -d '\r' < "$tmp" | sed '/^[[:space:]]*$/d' > "$dest"
    rm -f "$tmp"
    strategy_retarget_paths "$dest"
    # маркер #DNS в начало, если его нет
    if ! grep -qE '^[[:space:]]*#DNS' "$dest" 2>/dev/null; then
      { printf '%s\n' '#DNS'; cat "$dest"; } > "${dest}.n" && mv "${dest}.n" "$dest"
    fi
    info "Стратегия dns_filter_nfqws${ver} скачана с GitHub."
    return 0
  fi
  rm -f "$tmp"

  warn "Не удалось скачать dns_filter_nfqws${ver} — используем встроенный fallback."
  if [ "$ver" = "1" ]; then
    printf '%s\n' "$DOT_DOH_STRATEGY_NFQWS1" > "$dest"
  else
    printf '%s\n' "$DOT_DOH_STRATEGY_NFQWS2" > "$dest"
  fi
  strategy_retarget_paths "$dest"
  return 0
}

# Вставить содержимое strat_tmp в NFQWS_ARGS_CUSTOM конфига conf
inject_custom_strategy() {
  local conf="$1" strat_tmp="$2"
  local tmp="/tmp/nfqws-conf-dot-$$.tmp"
  local found=0 in_block=0 has_content=0

  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_block" -eq 0 ]; then
      case "$line" in
        NFQWS_ARGS_CUSTOM=\"\")
          found=1
          printf 'NFQWS_ARGS_CUSTOM="\n' >> "$tmp"
          cat "$strat_tmp" >> "$tmp"
          printf '"\n' >> "$tmp"
          ;;
        NFQWS_ARGS_CUSTOM=\")
          found=1; in_block=1
          printf '%s\n' "$line" >> "$tmp"
          ;;
        NFQWS_ARGS_CUSTOM=\"*\")
          found=1
          local body
          body=${line#NFQWS_ARGS_CUSTOM=\"}
          body=${body%\"}
          printf 'NFQWS_ARGS_CUSTOM="\n' >> "$tmp"
          if [ -n "$(echo "$body" | tr -d '[:space:]')" ]; then
            printf '%s\n' "$body" >> "$tmp"
            printf -- '--new\n' >> "$tmp"
          fi
          cat "$strat_tmp" >> "$tmp"
          printf '"\n' >> "$tmp"
          ;;
        NFQWS_ARGS_CUSTOM=\"*)
          found=1; in_block=1; has_content=1
          printf '%s\n' "$line" >> "$tmp"
          ;;
        *)
          printf '%s\n' "$line" >> "$tmp"
          ;;
      esac
    else
      case "$line" in
        \"|[[:space:]]*\")
          [ "$has_content" -eq 1 ] && printf -- '--new\n' >> "$tmp"
          cat "$strat_tmp" >> "$tmp"
          printf '%s\n' "$line" >> "$tmp"
          in_block=0
          ;;
        *\")
          local body
          body=${line%\"}
          if [ -n "$(echo "$body" | tr -d '[:space:]\\')" ]; then
            printf '%s\n' "$body" >> "$tmp"
            has_content=1
          fi
          [ "$has_content" -eq 1 ] && printf -- '--new\n' >> "$tmp"
          cat "$strat_tmp" >> "$tmp"
          printf '"\n' >> "$tmp"
          in_block=0
          ;;
        *)
          if [ -n "$(echo "$line" | tr -d '[:space:]\\')" ]; then
            has_content=1
          fi
          printf '%s\n' "$line" >> "$tmp"
          ;;
      esac
    fi
  done < "$conf"

  if [ "$found" -eq 0 ]; then
    printf '\nNFQWS_ARGS_CUSTOM="\n' >> "$tmp"
    cat "$strat_tmp" >> "$tmp"
    printf '"\n' >> "$tmp"
  fi

  if [ "$in_block" -eq 1 ]; then
    error "Не найдена закрывающая кавычка NFQWS_ARGS_CUSTOM — конфиг не изменён."
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$conf"
  return 0
}

apply_dot_doh_for_ver() {
  local ver="$1"
  local conf init_script strat_tmp svc_name

  conf=$(nfqws_conf_path "$ver")
  init_script=$(nfqws_init_path "$ver")
  if [ "$ver" = "1" ]; then
    svc_name="nfqws"
  else
    svc_name="nfqws2"
  fi

  if [ ! -f "$conf" ]; then
    error "Конфиг $conf не найден."
    return 1
  fi

  if grep -qE '#DNS|dot\.pub,doh\.pub|dns\.iij\.jp|xbox-dns\.ru' "$conf" 2>/dev/null; then
    warn "Похоже, стратегия DoT/DoH уже присутствует в конфиге (nfqws${ver})."
    confirm_no "Добавить повторно?" || { info "Пропуск nfqws${ver}."; return 0; }
  fi

  backup_file "$conf"

  strat_tmp="/tmp/nfqws${ver}-dot-$$.txt"
  load_dot_doh_strategy "$ver" "$strat_tmp" || {
    rm -f "$strat_tmp"
    return 1
  }

  if ! inject_custom_strategy "$conf" "$strat_tmp"; then
    rm -f "$strat_tmp"
    return 1
  fi
  rm -f "$strat_tmp"

  info "Стратегия DoT/DoH (dns_filter_nfqws${ver}) добавлена в NFQWS_ARGS_CUSTOM."

  echo
  info "=== Проверка портов 853 (DoT) [nfqws${ver}] ==="
  ensure_port_in_var "$conf" "TCP_PORTS" "853"
  ensure_port_in_var "$conf" "UDP_PORTS" "853"
  service_restart "$init_script"
  info "Сервис $svc_name перезапущен."
  return 0
}

menu_dot_doh() {
  refresh_opkg_cache
  need_nfqws_installed || return 0

  echo
  info "Стратегии: dns_filter_nfqws1 / dns_filter_nfqws2"
  info "  https://github.com/Dea1hwa1cher/nfqws-menu-openwrt/blob/main/strategies/dns_filter_nfqws1"
  info "  https://github.com/Dea1hwa1cher/nfqws-menu-openwrt/blob/main/strategies/dns_filter_nfqws2"
  echo

  pick_nfqws_ver 1 || { info "Отменено."; return 0; }

  case "$NFQWS_VER" in
    1)
      confirm_yes "Добавить стратегию обхода DoT/DoH в NFQWS_ARGS_CUSTOM (nfqws1)?" || { info "Отменено."; return 0; }
      apply_dot_doh_for_ver 1 || true
      ;;
    2)
      confirm_yes "Добавить стратегию обхода DoT/DoH в NFQWS_ARGS_CUSTOM (nfqws2)?" || { info "Отменено."; return 0; }
      apply_dot_doh_for_ver 2 || true
      ;;
    both)
      confirm_yes "Добавить стратегию обхода DoT/DoH в оба конфига?" || { info "Отменено."; return 0; }
      apply_dot_doh_for_ver 1 || true
      apply_dot_doh_for_ver 2 || true
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Данные DoH-серверов для OpenWrt
# ---------------------------------------------------------------------------

# Data-driven DoH: N|label|uri
doh_servers_data() {
  cat <<'EOF'
1|Yandex Primary|https://77.88.8.8/dns-query
2|Yandex Secondary|https://77.88.8.1/dns-query
3|Cloudflare|https://cloudflare-dns.com/dns-query
4|Google|https://dns.google/dns-query
5|Quad9|https://dns.quad9.net/dns-query
6|CleanBrowsing|https://doh.cleanbrowsing.org/doh/security-filter/
7|OpenDNS|https://doh.opendns.com/dns-query
8|AdGuard Default|https://dns.adguard-dns.com/dns-query
9|AdGuard Family|https://family.adguard-dns.com/dns-query
10|ControlD Free|https://freedns.controld.com/p0
11|DNS.SB|https://doh.dns.sb/dns-query
12|DNS4EU Protective|https://protective.joindns4.eu/dns-query
13|DNS4EU Unfiltered|https://unfiltered.joindns4.eu/dns-query
14|OpenNameServer ns1|https://ns1.opennameserver.org/dns-query
15|OpenNameServer ns2|https://ns2.opennameserver.org/dns-query
16|OpenNameServer ns3|https://ns3.opennameserver.org/dns-query
17|OpenNameServer ns4|https://ns4.opennameserver.org/dns-query
18|IIJ Japan|https://public.dns.iij.jp/dns-query
19|Alibaba DNS|https://dns.alidns.com/dns-query
20|DNSPod|https://doh.pub/dns-query
21|Xbox-DNS|https://xbox-dns.ru/dns-query
22|Comss DNS|https://dns.comss.one/dns-query
23|Malw Link|https://dns.malw.link/dns-query
24|NullsProxy|https://dns.nullsproxy.com/dns-query
25|Cloudflare Gateway|https://5u35p8m9i7.cloudflare-gateway.com/dns-query
26|Geo Hide|https://dns.geohide.ru/dns-query
27|AstraCat|https://dns.astracat.network/dns-query
28|Bezmezhau|https://dns.bezmezhau.com/dns-query
29|DNS-AI|https://dns.dns-ai.ru/dns-query
30|Mafioznik|https://dns.mafioznik.xyz/dns-query
31|Shecan Free|https://free.shecan.ir/dns-query
EOF
}






# ---------------------------------------------------------------------------
# Управление DoT/DoH — OpenWrt: https-dns-proxy (DoH) + dnsmasq per-domain.
# Сервер = uci-секция https-dns-proxy (listen_port задаём всегда явно),
# привязка домена = list dhcp.@dnsmasq[0].server «/domain/127.0.0.1#PORT».
# dnsmasq_config_update='' — не подменять все upstream'ы dnsmasq на прокси.
# DoT (ndmc dns-proxy) на OpenWrt не реализован — только DoH.
# ---------------------------------------------------------------------------
HDP_PORT_BASE=5053

hdp_installed() {
  [ -x /etc/init.d/https-dns-proxy ] && return 0
  command -v https-dns-proxy >/dev/null 2>&1 && return 0
  return 1
}

hdp_ensure() {
  command -v uci >/dev/null 2>&1 || { error "uci не найден."; return 1; }
  if ! hdp_installed; then
    info "Установка https-dns-proxy (DoH-прокси для dnsmasq)..."
    pkg_update >/dev/null 2>&1 || true
    pkg_install https-dns-proxy || { error "Не удалось установить https-dns-proxy."; return 1; }
  fi
  if ! uci -q get https-dns-proxy.config >/dev/null 2>&1; then
    error "Конфиг /etc/config/https-dns-proxy не найден."
    return 1
  fi
  # режим выборочных доменов: прокси не должен забирать весь DNS dnsmasq.
  # Имя опции в разных версиях пакета: dnsmasq_config_update / update_dnsmasq_config.
  local cur
  cur=$(uci -q get https-dns-proxy.config.dnsmasq_config_update 2>/dev/null)
  [ -z "$cur" ] && cur=$(uci -q get https-dns-proxy.config.update_dnsmasq_config 2>/dev/null)
  if [ "$cur" = "*" ]; then
    if uci -q get https-dns-proxy.config.dnsmasq_config_update >/dev/null 2>&1; then
      uci set https-dns-proxy.config.dnsmasq_config_update=''
    elif uci -q get https-dns-proxy.config.update_dnsmasq_config >/dev/null 2>&1; then
      uci set https-dns-proxy.config.update_dnsmasq_config=''
    fi
    uci commit https-dns-proxy
    info "https-dns-proxy переведён в режим выборочных доменов (только привязанные домены пойдут через DoH)."
  fi
  return 0
}

# Список инстансов: «uci-секция|эффективный порт|URI».
# Порт без явного listen_port пакет выдаёт по счётчику от 5053, причём шагает
# на КАЖДЫЙ инстанс (init: port="$((port+1))" после запуска), поэтому считаем
# здесь так же — иначе новый порт совпал бы с занятым авто-портом.
hdp_instances() {
  local out line id uri port auto next
  out=$(uci -q show https-dns-proxy 2>/dev/null) || return 0
  auto=$HDP_PORT_BASE
  printf '%s\n' "$out" | grep -E '^https-dns-proxy\.[^=]+=https-dns-proxy$' | \
  while IFS= read -r line; do
    id=${line#https-dns-proxy.}
    id=${id%=https-dns-proxy}
    [ -n "$id" ] || continue
    uri=$(uci -q get "https-dns-proxy.$id.resolver_url" 2>/dev/null)
    port=$(uci -q get "https-dns-proxy.$id.listen_port" 2>/dev/null)
    case "$port" in
      ''|*[!0-9]*) port=$auto ;;
    esac
    next=$((auto + 1))
    auto=$next
    printf '%s|%s|%s\n' "$id" "$port" "${uri:-?}"
  done
}

hdp_next_port() {
  local max=$((HDP_PORT_BASE - 1)) line port
  while IFS='|' read -r _id port _uri; do
    case "$port" in *[!0-9]*) continue ;; esac
    [ "$port" -gt "$max" ] 2>/dev/null && max=$port
  done <<EOF
$(hdp_instances)
EOF
  echo $((max + 1))
}

# Привязки доменов: «домен|порт»
owrt_dns_routes() {
  local list r d
  list=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null) || return 0
  for r in $list; do
    case "$r" in
      /*/*127.0.0.1\#*) ;;
      *) continue ;;
    esac
    d=${r#/}
    printf '%s|%s\n' "${d%%/*}" "${d##*#}"
  done
}

show_dns_servers_openwrt() {
  echo
  printf '%s\n' "${BOLD}DoH-серверы (https-dns-proxy):${NC}"
  local any=0 line id port uri
  while IFS='|' read -r id port uri; do
    [ -n "$id" ] || continue
    any=1
    printf '  %s%s%s %s➔ 127.0.0.1#%s%s\n' "$CYAN" "$uri" "$NC" "$DIM" "$port" "$NC"
  done <<EOF
$(hdp_instances)
EOF
  [ "$any" -eq 0 ] && printf '  %s— серверов нет —%s\n' "$DIM" "$NC"
  echo
  printf '%s\n' "${BOLD}Привязки доменов (dnsmasq):${NC}"
  any=0
  local d p all_routes="" total=0 shown=0
  all_routes=$(owrt_dns_routes)
  if [ -n "$all_routes" ]; then
    total=$(printf '%s\n' "$all_routes" | grep -c '|')
  fi
  if [ "$total" -gt 0 ]; then
    while IFS='|' read -r d p; do
      [ -n "$d" ] || continue
      shown=$((shown + 1))
      if [ "$shown" -le 10 ]; then
        printf '  %s%-40s%s %s➔ 127.0.0.1#%s%s\n' "$CYAN" "$d" "$NC" "$DIM" "$p" "$NC"
      fi
    done <<EOF
$all_routes
EOF
    if [ "$total" -gt 10 ]; then
      printf '  %s... и ещё %s домен(ов) (всего %s)%s\n' "$DIM" "$((total - 10))" "$total" "$NC"
    fi
  else
    printf '  %s— привязок нет —%s\n' "$DIM" "$NC"
  fi
}

# Получить порт инстанса по URI или создать новый
owrt_doh_get_or_add_port() {
  local target_uri="$1" id port uri
  while IFS='|' read -r id port uri; do
    [ -n "$id" ] || continue
    if [ "$uri" = "$target_uri" ]; then
      echo "$port"
      return 0
    fi
  done <<EOF
$(hdp_instances)
EOF
  if owrt_doh_add "$target_uri" >/dev/null 2>&1; then
    while IFS='|' read -r id port uri; do
      [ -n "$id" ] || continue
      if [ "$uri" = "$target_uri" ]; then
        echo "$port"
        return 0
      fi
    done <<EOF
$(hdp_instances)
EOF
  fi
  return 1
}

owrt_doh_add() {
  # $1 = URI DoH
  local uri="$1" host bootstrap="" sid port id u
  case "$uri" in
    https://*) ;;
    *) error "URI должен начинаться с https:// — получено: $uri"; return 1 ;;
  esac
  host=${uri#https://}
  host=${host%%/*}
  host=${host%%:*}
  # bootstrap — только точный IPv4: цифры/точки и ровно 3 точки,
  # иначе хост вида 1.2.3.4.example.com попал бы в bootstrap целиком
  case "$host" in
    *[!0-9.]*) ;;
    *)
      if [ "$(printf '%s' "$host" | tr -cd '.' | wc -c)" = "3" ]; then
        bootstrap="$host"
      fi
      ;;
  esac

  if ! hdp_ensure; then return 1; fi

  # не плодить дубликаты
  while IFS='|' read -r id port u; do
    [ -n "$id" ] || continue
    [ "$u" = "$uri" ] && { warn "Такой сервер уже добавлен."; return 0; }
  done <<EOF
$(hdp_instances)
EOF

  port=$(hdp_next_port)
  sid=$(uci add https-dns-proxy https-dns-proxy 2>/dev/null) || { error "uci add не удался."; return 1; }
  uci set "https-dns-proxy.$sid.resolver_url=$uri"
  [ -n "$bootstrap" ] && uci set "https-dns-proxy.$sid.bootstrap_dns=$bootstrap"
  uci set "https-dns-proxy.$sid.listen_port=$port"
  uci commit https-dns-proxy
  /etc/init.d/https-dns-proxy enable >/dev/null 2>&1 || true
  /etc/init.d/https-dns-proxy restart >/dev/null 2>&1 || /etc/init.d/https-dns-proxy start >/dev/null 2>&1 || true
  info "Сервер добавлен: $uri ➔ 127.0.0.1#$port"
}

owrt_pick_doh_port() {
  local n=0 ports="" id port uri pick
  # Меню — в stderr: функция вызывается через $(...) и обязана вернуть в stdout только порт
  echo >&2
  printf '%s\n' "${BOLD}Выберите DoH-сервер:${NC}" >&2
  while IFS='|' read -r id port uri; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    printf ' %s) %s %s(127.0.0.1#%s)%s\n' "$n" "$uri" "$DIM" "$port" "$NC" >&2
    ports="$ports $port"
  done <<EOF
$(hdp_instances)
EOF
  if [ "$n" -eq 0 ]; then
    warn "Настроенных DoH-серверов нет. Сначала добавьте сервер (пункт 1)." >&2
    return 1
  fi
  echo " 0) Отмена" >&2
  ask "${LBL_YOUR_CHOICE} [0]: " >&2
  read -r pick
  case "$pick" in 0|"") return 1 ;; esac
  case "$pick" in *[!0-9]*) warn "${LBL_INVALID}" >&2; return 1 ;; esac
  if [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then
    printf '%s\n' $ports | awk -v n="$pick" 'NR == n'
    return 0
  fi
  warn "${LBL_INVALID}" >&2
  return 1
}

_fetch_geohide_domains() {
  local cache_dir="$CACHE_DIR"
  if [ -f "./domains_geohide" ]; then
    awk '!/^[[:space:]]*(#|$)/ { print $1 }' "./domains_geohide"
    return 0
  fi
  if [ -f "${cache_dir}/domains_geohide" ]; then
    awk '!/^[[:space:]]*(#|$)/ { print $1 }' "${cache_dir}/domains_geohide"
    return 0
  fi
  local tmp="/tmp/domains_geohide-$$.txt"
  if download_file "${RAW_BASE}/domains_geohide" "$tmp"; then
    mkdir -p "$cache_dir" 2>/dev/null || true
    cp -f "$tmp" "${cache_dir}/domains_geohide" 2>/dev/null || true
    awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

owrt_bind_domains_to_port() {
  local doms="$1" port="$2" d count=0 cur_routes NL='
'
  [ -n "$doms" ] && [ -n "$port" ] || return 1
  if ! uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
    uci add dhcp dnsmasq >/dev/null
  fi
  cur_routes=$(owrt_dns_routes)
  for d in $doms; do
    [ -n "$d" ] || continue
    case "$d" in '#'*|'//'*) continue ;; esac
    # Если уже привязан к этому же порту — пропускаем
    case "${NL}${cur_routes}${NL}" in
      *"${NL}${d}|${port}${NL}"*) continue ;;
    esac
    # Если был привязан к другому порту — удаляем старую привязку без reload
    case "${NL}${cur_routes}${NL}" in
      *"${NL}${d}|"*) owrt_route_del "$d" 1 >/dev/null 2>&1 || true ;;
    esac
    if uci -q add_list "dhcp.@dnsmasq[0].server=/$d/127.0.0.1#$port"; then
      count=$((count + 1))
    fi
  done
  if [ "$count" -gt 0 ]; then
    uci commit dhcp
    reload_dns_service
    info "Привязано доменов: $count ➔ 127.0.0.1#$port"
  else
    info "Все выбранные домены уже привязаны к 127.0.0.1#$port (без изменений)."
  fi
  return 0
}

owrt_bind_domain_menu() {
  if ! hdp_ensure; then return 1; fi
  local pchoice doms="" rec_uri="" rec_name=""

  echo
  printf '%s\n' "${BOLD}Привязка доменов к DoH-серверу (dnsmasq):${NC}"
  echo "  1) Instagram & CDN (instagram.com, cdninstagram.com...)"
  echo "  2) Twitch (gql.twitch.tv, usher.ttvnw.net — реклама/лаги)"
  echo "  3) Supercell / Brawl Stars (brawlstars, clashofclans, supercell...)"
  echo "  4) Rutor & NTC.party (rutor.is, ntc.party)"
  echo "  5) Discord (discord.com, discord.media, discord.gg...)"
  echo "  6) GeoHide (350+ сервисов с гео-блокировкой РФ: AI Studio, Claude, Cursor...)"
  echo "  7) Ввести свой домен(ы) вручную"
  echo "  0) Отмена"
  echo
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r pchoice

  case "$pchoice" in
    0|"") return 0 ;;
    1)
      doms="instagram.com cdninstagram.com igcdn.com ig.me"
      rec_name="CleanBrowsing Security"
      rec_uri="https://doh.cleanbrowsing.org/doh/security-filter/"
      ;;
    2)
      doms="gql.twitch.tv usher.ttvnw.net"
      rec_name="Xbox-DNS"
      rec_uri="https://xbox-dns.ru/dns-query"
      ;;
    3)
      doms="supercell.com supercellid.com brawlstarsgame.com clashofclans.com clashroyaleapp.com supercell.helpshift.com"
      rec_name="NullsProxy"
      rec_uri="https://dns.nullsproxy.com/dns-query"
      ;;
    4)
      doms="rutor.is rutor.info ntc.party"
      rec_name="Malw Link"
      rec_uri="https://dns.malw.link/dns-query"
      ;;
    5)
      doms="discord.com discordapp.com discordapp.net discord.gg discord.media discordcdn.com"
      rec_name="Google DoH"
      rec_uri="https://dns.google/dns-query"
      ;;
    6)
      info "Загрузка списка GeoHide (350+ доменов)..."
      doms=$(_fetch_geohide_domains)
      if [ -z "$doms" ]; then
        error "Не удалось загрузить список GeoHide."
        return 1
      fi
      rec_name="Geo Hide"
      rec_uri="https://dns.geohide.ru/dns-query"
      ;;
    7)
      ask "Домены через запятую или пробел (напр. example.com,cdn.example.com): "
      read -r doms
      doms=$(echo "$doms" | tr ',;' '  ')
      [ -z "$doms" ] && return 0
      ;;
    *)
      warn "${LBL_INVALID}"
      return 0
      ;;
  esac

  local port="" target_choice
  if [ -n "$rec_uri" ]; then
    echo
    printf '%s\n' "${BOLD}К какому DoH-серверу привязать:${NC}"
    printf '  1) Рекомендуемый: %s%s%s %s(%s)%s\n' "$GREEN" "$rec_name" "$NC" "$DIM" "$rec_uri" "$NC"
    echo "  2) Выбрать из других настроенных DoH-серверов"
    echo "  0) Отмена"
    ask "${LBL_YOUR_CHOICE} [1]: "
    read -r target_choice
    case "$target_choice" in
      0) return 0 ;;
      2) port=$(owrt_pick_doh_port) ;;
      1|"")
        port=$(owrt_doh_get_or_add_port "$rec_uri")
        [ -n "$port" ] || { error "Не удалось добавить или получить порт для $rec_name."; return 1; }
        ;;
      *) warn "${LBL_INVALID}"; return 0 ;;
    esac
  else
    port=$(owrt_pick_doh_port)
  fi

  [ -n "$port" ] || return 0
  owrt_bind_domains_to_port "$doms" "$port"
}

owrt_unbind_menu() {
  local n=0 doms="" d p pick all_routes total=0 shown=0
  all_routes=$(owrt_dns_routes)
  [ -z "$all_routes" ] && { info "Привязок нет."; return 0; }
  total=$(printf '%s\n' "$all_routes" | grep -c '|')

  echo
  printf '%s\n' "${BOLD}Привязки доменов:${NC}"
  while IFS='|' read -r d p; do
    [ -n "$d" ] || continue
    n=$((n + 1))
    shown=$((shown + 1))
    if [ "$shown" -le 20 ]; then
      printf ' %2s) %-35s %s➔ 127.0.0.1#%s%s\n' "$n" "$d" "$DIM" "$p" "$NC"
    fi
    doms="$doms $d"
  done <<EOF
$all_routes
EOF
  if [ "$total" -gt 20 ]; then
    printf '  %s... и ещё %s домен(ов) (всего %s)%s\n' "$DIM" "$((total - 20))" "$total" "$NC"
  fi
  echo " a) Удалить все привязки"
  echo " g) Удалить только привязки GeoHide"
  echo " 0) Отмена"
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r pick
  case "$pick" in
    a|A) owrt_route_del_all ;;
    g|G)
      local gdoms
      gdoms=$(_fetch_geohide_domains)
      if [ -n "$gdoms" ]; then
        info "Удаление записей GeoHide из dnsmasq..."
        local count=0
        for d in $gdoms; do
          owrt_route_del "$d" 1 >/dev/null 2>&1 && count=$((count + 1)) || true
        done
        if [ "$count" -gt 0 ]; then
          uci commit dhcp
          reload_dns_service
          info "Удалено привязок GeoHide: $count"
        else
          info "Привязок из списка GeoHide не найдено."
        fi
      else
        warn "Список GeoHide пуст или недоступен."
      fi
      ;;
    0|"") return 0 ;;
    *)
      case "$pick" in *[!0-9]*) warn "${LBL_INVALID}"; return 0 ;; esac
      [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ] || { warn "${LBL_INVALID}"; return 0; }
      d=$(printf '%s\n' $doms | awk -v n="$pick" 'NR == n')
      owrt_route_del "$d"
      ;;
  esac
}

owrt_route_del() {
  # $1 = домен; $2 = nocommit (опционально: 1 = без commit/reload)
  local list r d removed=0 nocommit="${2:-0}"
  list=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null) || return 0
  for r in $list; do
    d=${r#/}
    d=${d%%/*}
    [ "$d" = "$1" ] || continue
    uci -q del_list "dhcp.@dnsmasq[0].server=$r" && removed=$((removed + 1))
  done
  [ "$removed" -eq 0 ] && return 1
  if [ "$nocommit" != "1" ]; then
    uci commit dhcp
    reload_dns_service
    info "Привязка удалена: $1"
  fi
  return 0
}

owrt_route_del_all() {
  local list r d removed=0
  list=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null) || return 0
  for r in $list; do
    case "$r" in
      /*/*127.0.0.1\#*) ;;
      *) continue ;;
    esac
    uci -q del_list "dhcp.@dnsmasq[0].server=$r" && removed=$((removed + 1))
  done
  [ "$removed" -eq 0 ] && { info "Привязок нет."; return 0; }
  uci commit dhcp
  reload_dns_service
  info "Удалено привязок: $removed"
}

owrt_del_server_menu() {
  local n=0 ids="" id port uri pick
  echo
  printf '%s\n' "${BOLD}Удаление DoH-сервера:${NC}"
  while IFS='|' read -r id port uri; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    printf ' %s) %s %s(127.0.0.1#%s)%s\n' "$n" "$uri" "$DIM" "$port" "$NC"
    ids="$ids $id"
  done <<EOF
$(hdp_instances)
EOF
  [ "$n" -eq 0 ] && { info "Серверов нет."; return 0; }
  echo " 0) Отмена"
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r pick
  case "$pick" in 0|"") return 0 ;; esac
  case "$pick" in
    *[!0-9]*) warn "${LBL_INVALID}"; return 0 ;;
  esac
  [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ] || { warn "${LBL_INVALID}"; return 0; }
  id=$(printf '%s\n' $ids | awk -v n="$pick" 'NR == n')
  local port_del
  port_del=$(uci -q get "https-dns-proxy.$id.listen_port" 2>/dev/null)
  uci -q delete "https-dns-proxy.$id"
  uci commit https-dns-proxy
  if [ -n "$port_del" ]; then
    local d p
    while IFS='|' read -r d p; do
      [ -n "$d" ] || continue
      [ "$p" = "$port_del" ] || continue
      uci -q del_list "dhcp.@dnsmasq[0].server=/$d/127.0.0.1#$port_del"
    done <<EOF
$(owrt_dns_routes)
EOF
    uci commit dhcp
  fi
  /etc/init.d/https-dns-proxy restart >/dev/null 2>&1 || true
  reload_dns_service
  info "Сервер удалён."
}

owrt_add_doh_menu() {
  echo
  printf '%s\n' "${BOLD}Добавление DoH сервера (https-dns-proxy):${NC}"
  local line
  while IFS='|' read -r num label uri; do
    printf ' %2s) %s\n' "$num" "$label"
  done <<EOF
$(doh_servers_data)
EOF
  printf ' %2s) Ввести вручную (произвольный URI)\n' 32
  echo " 0) Отмена"
  printf '%s\n' "${DIM}────────────────────────────────────────────────────────${NC}"
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r raw_choices
  [ -z "$raw_choices" ] || [ "$raw_choices" = "0" ] && return

  local choice uri added_any=0
  for choice in $(echo "$raw_choices" | tr ',;' '  '); do
    case "$choice" in
      0) return 0 ;;
      32)
        ask "Введите URI DoH сервера: "
        read -r uri
        [ -n "$uri" ] && { owrt_doh_add "$uri" && added_any=1; }
        ;;
      *[!0-9]*) continue ;;
      *)
        uri=$(doh_servers_data | grep -E "^${choice}\|" | cut -d'|' -f3)
        [ -n "$uri" ] && { owrt_doh_add "$uri" && added_any=1; }
        ;;
    esac
  done
  [ "$added_any" -eq 1 ] || info "Ничего не добавлено."
}

menu_dns_manage() {
  while true; do
    clear 2>/dev/null || true
    show_dns_servers_openwrt
    echo
    printf '%s\n' " ${BOLD}1)${NC} Добавить DoH сервер (https-dns-proxy)"
    printf '%s\n' " ${BOLD}2)${NC} Привязать домен к DoH серверу"
    printf '%s\n' " ${BOLD}3)${NC} ${RED}Удалить привязку домена${NC}"
    printf '%s\n' " ${BOLD}4)${NC} ${RED}Удалить DoH сервер${NC}"
    printf '%s\n' " ${BOLD}0)${NC} ${LBL_BACK_ITEM}"
    printf '%s\n' "${DIM}────────────────────────────────────────────────────────${NC}"
    printf '%s\n' "${DIM}DoT на OpenWrt этим меню не управляется — используйте DoH-серверы.${NC}"
    ask "${LBL_YOUR_CHOICE} [0]: "
    read -r choice
    case $choice in
      1) owrt_add_doh_menu ;;
      2) owrt_bind_domain_menu ;;
      3) owrt_unbind_menu ;;
      4) owrt_del_server_menu ;;
      0|"") return 0 ;;
      *) warn "Неверный ввод, попробуйте снова."; sleep 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 8. Обновление hosts (статические DNS-записи в /etc/hosts)
# ---------------------------------------------------------------------------
HOSTS_MARK_BEGIN="# >>> nfqws-menu hosts >>>"
HOSTS_MARK_END="# <<< nfqws-menu hosts <<<"

reload_dns_service() {
  if [ -x /etc/init.d/dnsmasq ]; then
    /etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart 2>/dev/null || true
    info "dnsmasq перечитан."
  else
    warn "dnsmasq не найден — перезапустите DNS-сервис вручную."
  fi
}

# Файл без управляемого блока nfqws-menu
hosts_strip_block() {
  awk -v B="$HOSTS_MARK_BEGIN" -v E="$HOSTS_MARK_END" \
    '$0 == B { skip=1; next } $0 == E { skip=0; next } !skip' "$1" 2>/dev/null
}

# Пары «IP<TAB>DOMAIN» из текущего блока /etc/hosts
hosts_existing_pairs() {
  awk -v B="$HOSTS_MARK_BEGIN" -v E="$HOSTS_MARK_END" \
    '$0 == B { inb=1; next } $0 == E { inb=0; next } inb && NF >= 2 { print $1 "\t" $2 }' /etc/hosts 2>/dev/null
}

# Текущие статические записи — форматированные строки на stdout
host_entries_view() {
  [ -r /etc/hosts ] || return 0
  local ip domain
  while IFS="$(printf '\t')" read -r ip domain || [ -n "$ip" ]; do
    [ -n "$ip" ] && [ -n "$domain" ] || continue
    printf '  %s%-40s%s %s➔%s %s\n' "$CYAN" "$domain" "$NC" "$DIM" "$NC" "$ip"
  done <<EOF
$(hosts_existing_pairs)
EOF
}

# Удалить блок записей nfqws-menu из /etc/hosts
host_entries_delete_all() {
  if [ -f /etc/hosts ] && grep -qF "$HOSTS_MARK_BEGIN" /etc/hosts 2>/dev/null; then
    # запись в .new + mv: обрыв не оставит /etc/hosts обрезанным
    hosts_strip_block /etc/hosts > /etc/hosts.nfqws.new && \
      mv -f /etc/hosts.nfqws.new /etc/hosts
    rm -f /etc/hosts.nfqws.new
    reload_dns_service
    info "Блок nfqws-menu удалён из /etc/hosts."
  else
    info "Записей nfqws-menu в /etc/hosts нет."
  fi
}

# Применить записи; $1 = файл пар «IP<TAB>DOMAIN»
host_entries_apply() {
  [ -f /etc/hosts ] || : > /etc/hosts
  local block="/tmp/nfqws-hosts-block-$$.tmp" merged="/tmp/nfqws-hosts-merge-$$.txt" n_dom
  hosts_existing_pairs > "$merged"
  cat "$1" >> "$merged"
  {
    printf '%s\n' "$HOSTS_MARK_BEGIN"
    # сохраняем уникальные пары IP DOMAIN в исходном порядке
    awk -F '\t' '
      NF >= 2 && $1 != "" && $2 != "" {
        pair = $1 "\t" $2
        if (!seen[pair]++) {
          order[++n] = pair
        }
      }
      END {
        for (i = 1; i <= n; i++) {
          split(order[i], p, "\t")
          print p[1] " " p[2]
        }
      }
    ' "$merged" > "${block}.body"
    cat "${block}.body"
    printf '%s\n' "$HOSTS_MARK_END"
  } > "$block"
  n_dom=$(wc -l < "${block}.body" 2>/dev/null | tr -d ' ')
  hosts_strip_block /etc/hosts > "${block}.base"
  cat "${block}.base" "$block" > /etc/hosts.nfqws.new && \
    mv -f /etc/hosts.nfqws.new /etc/hosts
  rm -f /etc/hosts.nfqws.new "$block" "${block}.base" "${block}.body" "$merged"
  info "Записано: /etc/hosts (записей в блоке: ${n_dom:-0})."
  reload_dns_service
}

menu_update_hosts() {
  local hosts_url="${RAW_BASE}/hosts"
  local tmp="/tmp/nfqws-hosts-$$.txt"
  local sec_file="/tmp/nfqws-hosts-sec-$$.txt"

  info "Загрузка hosts..."
  if ! download_file "$hosts_url" "$tmp"; then
    error "Не удалось загрузить $hosts_url"
    return 1
  fi

  # Секции = строки, начинающиеся с # (без пустых)
  awk '/^#/ {
    name = $0
    sub(/^#+[ \t]*/, "", name)
    gsub(/[ \t\r]+$/, "", name)
    if (name != "") print name
  }' "$tmp" > "$sec_file"

  if [ ! -s "$sec_file" ]; then
    error "В файле hosts нет секций (комментариев #...)"
    rm -f "$tmp" "$sec_file"
    return 1
  fi

  local n_sec
  n_sec=$(wc -l < "$sec_file" | tr -d ' ')

  echo
  printf '%s\n' "${BOLD}Какие записи добавить в hosts (можно несколько через запятую или все)?${NC}"
  local i=1
  while IFS= read -r sec || [ -n "$sec" ]; do
    printf ' %s) #%s\n' "$i" "$sec"
    i=$((i + 1))
  done < "$sec_file"
  local all_num=$i
  printf ' %s) Все\n' "$all_num"
  printf ' %s88) Удалить записи%s\n' "$RED" "$NC"
  printf ' %s99) Просмотреть записи%s\n' "$YELLOW" "$NC"
  printf ' 0) Отмена\n'
  printf '%s\n' "${DIM}────────────────────────────────────────────────────────${NC}"
  ask "Выберите варианты: "
  read -r raw_choices

  [ -z "$raw_choices" ] || [ "$raw_choices" = "0" ] && {
    rm -f "$tmp" "$sec_file"
    return 0
  }

  # 99 — просмотреть текущие записи ip host на роутере
  local want_view=0
  for c in $(echo "$raw_choices" | tr ',;' '  '); do
    [ "$c" = "99" ] && want_view=1 && break
  done
  if [ "$want_view" -eq 1 ]; then
    echo
    printf '%s\n' "${BOLD}${YELLOW}Текущие статические DNS-записи:${NC}"
    printf '%s\n' "${DIM}────────────────────────────────────────────────────────${NC}"
    local view_cnt=0 view_line
    while IFS= read -r view_line || [ -n "$view_line" ]; do
      [ -n "$view_line" ] || continue
      view_cnt=$((view_cnt + 1))
      printf '%s\n' "$view_line"
    done <<EOF
$(host_entries_view)
EOF
    if [ "$view_cnt" -eq 0 ]; then
      printf '  %s— записей нет —%s\n' "$DIM" "$NC"
    else
      printf '%s\n' "${DIM}────────────────────────────────────────────────────────${NC}"
      info "Всего: $view_cnt"
    fi
    rm -f "$tmp" "$sec_file"
    return 0
  fi

  # 88 — удалить все домены из блока nfqws-menu в /etc/hosts
  local want_delete=0
  for c in $(echo "$raw_choices" | tr ',;' '  '); do
    [ "$c" = "88" ] && want_delete=1 && break
  done
  if [ "$want_delete" -eq 1 ]; then
    local existing_cnt
    existing_cnt=$(hosts_existing_pairs | wc -l | tr -d ' ')
    if [ "${existing_cnt:-0}" -eq 0 ]; then
      info "Записей nfqws-menu в /etc/hosts нет."
      rm -f "$tmp" "$sec_file"
      return 0
    fi

    if ! confirm_no "Удалить все записи nfqws-menu из /etc/hosts (${existing_cnt} шт.)?"; then
      rm -f "$tmp" "$sec_file"
      return 0
    fi

    host_entries_delete_all
    rm -f "$tmp" "$sec_file"
    info "Готово."
    return 0
  fi

  # Нормализуем выбор: запятые/пробелы → список номеров
  local choices selected_all=0
  choices=$(echo "$raw_choices" | tr ',;' '  ' | tr -s ' ')

  for c in $choices; do
    case "$c" in
      "$all_num"|all|все|ALL) selected_all=1; break ;;
    esac
  done

  # Список выбранных имён секций
  local selected_secs=""
  if [ "$selected_all" -eq 1 ]; then
    selected_secs=$(cat "$sec_file")
  else
    for c in $choices; do
      case "$c" in
        *[!0-9]*) continue ;;
      esac
      [ "$c" -ge 1 ] 2>/dev/null && [ "$c" -le "$n_sec" ] 2>/dev/null || continue
      local name
      name=$(sed -n "${c}p" "$sec_file")
      [ -n "$name" ] && selected_secs="$selected_secs
$name"
    done
  fi

  selected_secs=$(printf '%s\n' "$selected_secs" | sed '/^$/d')
  if [ -z "$selected_secs" ]; then
    warn "Ничего не выбрано."
    rm -f "$tmp" "$sec_file"
    return 0
  fi

  local pairs="/tmp/nfqws-hosts-pairs-$$.txt"
  : > "$pairs"

  # Собираем IP\tDOMAIN: только IPv4, валидный домен
  local sec
  # имена секций могут содержать пробелы — читаем построчно, не через word splitting
  while IFS= read -r sec || [ -n "$sec" ]; do
    [ -z "$sec" ] && continue
    info "Секция: #$sec"
    awk -v sec="$sec" '
      BEGIN { insec=0 }
      /^#/ {
        name = $0
        sub(/^#+[ \t]*/, "", name)
        gsub(/[ \t\r]+$/, "", name)
        insec = (name == sec) ? 1 : 0
        next
      }
      insec && NF >= 2 {
        ip = $1
        domain = $2
        # отсекаем некорректные IP (IPv4 / IPv6)
        if (ip !~ /^[0-9a-fA-F.:]+$/) next
        # битые/пустые домены (objects..com, .com, my..org)
        if (domain == "" || domain ~ /^\./ || domain ~ /\.\./ || domain !~ /\./) next
        print ip "\t" domain
      }
    ' "$tmp" >> "$pairs"
  done <<EOF
$selected_secs
EOF

  if [ ! -s "$pairs" ]; then
    warn "В выбранных секциях нет валидных записей IP DOMAIN."
    rm -f "$tmp" "$sec_file" "$pairs"
    return 0
  fi

  # Уникальные пары IP<TAB>DOMAIN
  local pairs_uniq="/tmp/nfqws-hosts-uniq-$$.txt"
  awk -F '\t' '!seen[$1, $2]++' "$pairs" > "$pairs_uniq"

  host_entries_apply "$pairs_uniq"

  rm -f "$tmp" "$sec_file" "$pairs" "$pairs_uniq"
  info "Готово."
}

# ---------------------------------------------------------------------------
# 99. Обновить скрипт
# ---------------------------------------------------------------------------
extract_script_version() {
  local src="${1:--}"
  grep -E '^SCRIPT_VERSION=' "$src" 2>/dev/null | head -1 | \
    sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p'
}

# Канонический путь скрипта меню: установленная копия, иначе та, из которой
# запущены сейчас (иначе п.99 пишет в один файл, а `menu` ссылается на другой)
menu_script_target() {
  local t="/usr/bin/nfqws-menu.sh"
  if [ ! -f "$t" ] && [ -n "${SCRIPT_PATH:-}" ] && [ -f "$SCRIPT_PATH" ]; then
    case "$SCRIPT_PATH" in
      /usr/*|/etc/*|/root/*|/tmp/*) t="$SCRIPT_PATH" ;;
    esac
  fi
  printf '%s\n' "$t"
}

update_self() {
  local dest tmp="/tmp/nfqws-menu-update-$$.sh"
  dest=$(menu_script_target)
  local remote_ver url

  info "Скачивание nfqws-menu.sh ..."
  rm -f "$tmp"
  url="${RAW_BASE}/nfqws-menu.sh"
  if ! download_file "$url" "$tmp" sh min=50000 connect=5 timeout=40; then
    error "Не удалось скачать целый скрипт ни с одного источника"
    return 1
  fi
  if ! grep -q 'SCRIPT_VERSION=' "$tmp" 2>/dev/null; then
    error "В файле нет SCRIPT_VERSION"
    rm -f "$tmp"
    return 1
  fi

  remote_ver=$(extract_script_version "$tmp")
  [ -z "$remote_ver" ] && remote_ver="?"
  if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
    info "Уже актуальная версия: v${SCRIPT_VERSION}"
    rm -f "$tmp"
    return 0
  fi

  info "Установка v${remote_ver} (было v${SCRIPT_VERSION}) → $dest"
  # dest — сам работающий скрипт: пишем в .new на той же ФС и mv -f (атомарно).
  # Прямая cat > $dest при обрыве записи (нет места) портит меню без отката.
  if ! cat "$tmp" > "${dest}.new"; then
    error "Не удалось записать ${dest}.new"
    rm -f "$tmp" "${dest}.new"
    return 1
  fi
  chmod +x "${dest}.new" 2>/dev/null || true
  if ! mv -f "${dest}.new" "$dest"; then
    error "Не удалось заменить $dest"
    rm -f "$tmp" "${dest}.new"
    return 1
  fi
  rm -f "$tmp"
  rm -f "${CACHE_DIR}/updates.cache" 2>/dev/null || true
  SCRIPT_PATH="$dest"
  export SCRIPT_PATH
  ensure_menu_symlink
  info "Перезапуск меню..."
  exec sh "$dest"
}

# ---------------------------------------------------------------------------
# 10–14. Утилиты
# ---------------------------------------------------------------------------
DPI_DETECTOR_INSTALL_URL="https://raw.githubusercontent.com/Runnin4ik/dpi-detector/rust/install.sh"
AWG_OPENWRT_INSTALL_URL="https://raw.githubusercontent.com/2Grey/awg-openwrt/master/amneziawg-feed-install.sh"
AWG_OPENWRT_CHECK_URL="https://raw.githubusercontent.com/2Grey/awg-openwrt/master/amneziawg-check.sh"

# dpi-detector: приоритет /usr/bin (OpenWrt), fallback /usr/local/bin или /tmp
dpi_detector_bin() {
  if [ -x /usr/bin/dpi-detector ]; then
    echo "/usr/bin/dpi-detector"
  elif [ -x /usr/local/bin/dpi-detector ]; then
    echo "/usr/local/bin/dpi-detector"
  elif command -v dpi-detector >/dev/null 2>&1; then
    command -v dpi-detector
  elif [ -x /tmp/dpi-detector ]; then
    echo "/tmp/dpi-detector"
  else
    echo "/usr/bin/dpi-detector"
  fi
}

cleanup_dpi_detector_dupes() {
  local primary="" f
  if [ -x "$(dpi_detector_bin)" ]; then
    primary=$(dpi_detector_bin)
  elif command -v dpi-detector >/dev/null 2>&1; then
    primary=$(command -v dpi-detector)
  fi
  [ -z "$primary" ] && return 0
  for f in /tmp/dpi-detector ${HOME:+$HOME/dpi-detector} /tmp/dpi-detector*; do
    [ -f "$f" ] || continue
    [ "$f" = "$primary" ] && continue
    rm -f "$f" && info "  удалён дубликат: $f"
  done
}

menu_dpi_detector() {
  # Если бинарник был сохранён в /tmp, но отсутствует в /usr/bin — переносим в /usr/bin
  if [ ! -x /usr/bin/dpi-detector ] && [ -x /tmp/dpi-detector ]; then
    cp -f /tmp/dpi-detector /usr/bin/dpi-detector 2>/dev/null && chmod +x /usr/bin/dpi-detector
  fi

  if [ -x "$(dpi_detector_bin)" ]; then
    echo
    info "Открываем: 10. dpi-detector"
    info "Локально: $(dpi_detector_bin)"
    printf '%s\n' "================================================"
    cleanup_dpi_detector_dupes
    if [ -c /dev/tty ]; then
      "$(dpi_detector_bin)" </dev/tty
    else
      "$(dpi_detector_bin)"
    fi
    return 0
  fi

  export DPI_INSTALL_DIR="/usr/bin"
  run_menu_remote_sh "10" "dpi-detector" "$DPI_DETECTOR_INSTALL_URL" || return 1

  # Если установщик сохранил бинарник в /tmp или /usr/local/bin — переносим в /usr/bin
  if [ ! -x /usr/bin/dpi-detector ]; then
    if [ -x /usr/local/bin/dpi-detector ]; then
      cp -f /usr/local/bin/dpi-detector /usr/bin/dpi-detector 2>/dev/null && chmod +x /usr/bin/dpi-detector
    elif [ -x /tmp/dpi-detector ]; then
      cp -f /tmp/dpi-detector /usr/bin/dpi-detector 2>/dev/null && chmod +x /usr/bin/dpi-detector
    fi
  fi

  echo
  info "Очистка дубликатов dpi-detector (/tmp)..."
  cleanup_dpi_detector_dupes
  if [ -x "$(dpi_detector_bin)" ]; then
    info "Запуск $(dpi_detector_bin) ..."
    if [ -c /dev/tty ]; then
      "$(dpi_detector_bin)" </dev/tty
    else
      "$(dpi_detector_bin)"
    fi
  else
    warn "Бинарник $(dpi_detector_bin) не найден — запуск пропущен."
  fi
}

install_awg_openwrt() {
  local extra_arg="$1"
  echo
  info "Установка AmneziaWG (2Grey/awg-openwrt)..."
  if [ -n "$extra_arg" ]; then
    run_remote_sh "$AWG_OPENWRT_INSTALL_URL" 4000 "$extra_arg"
  else
    run_remote_sh "$AWG_OPENWRT_INSTALL_URL" 4000
  fi
  refresh_opkg_cache
  echo
  pause_press_enter
}

check_awg_openwrt() {
  echo
  info "Диагностика AmneziaWG (amneziawg-check.sh)..."
  run_remote_sh "$AWG_OPENWRT_CHECK_URL" 2000
  echo
  pause_press_enter
}

menu_awg_openwrt() {
  local choice kmod_st tools_st proto_st ru_st mod_ver
  while :; do
    echo
    printf '%s\n' "${CYAN}${BOLD}              awg-openwrt (AmneziaWG для OpenWrt)${NC}"
    printf '%s\n' "${DIM}     https://github.com/2Grey/awg-openwrt${NC}"
    echo

    if is_installed "kmod-amneziawg"; then
      kmod_st="${GREEN}установлен${NC} ($(pkg_version "kmod-amneziawg" 2>/dev/null || echo "ok"))"
    else
      kmod_st="${YELLOW}не установлен${NC}"
    fi

    if is_installed "amneziawg-tools"; then
      tools_st="${GREEN}установлен${NC} ($(pkg_version "amneziawg-tools" 2>/dev/null || echo "ok"))"
    else
      tools_st="${YELLOW}не установлен${NC}"
    fi

    if is_installed "luci-proto-amneziawg"; then
      proto_st="${GREEN}установлен${NC} ($(pkg_version "luci-proto-amneziawg" 2>/dev/null || echo "ok"))"
    else
      proto_st="${YELLOW}не установлен${NC}"
    fi

    if is_installed "luci-i18n-amneziawg-ru"; then
      ru_st="${GREEN}установлен${NC}"
    else
      ru_st="${DIM}не установлен${NC}"
    fi

    if [ -d /sys/module/amneziawg ]; then
      mod_ver="загружен"
      [ -r /sys/module/amneziawg/version ] && mod_ver="загружен ($(cat /sys/module/amneziawg/version 2>/dev/null))"
      mod_ver="${GREEN}${mod_ver} (⚡)${NC}"
    else
      mod_ver="${DIM}не загружен${NC}"
    fi

    printf '  Ядро (kmod-amneziawg):        %b\n' "$kmod_st"
    printf '  Утилиты (amneziawg-tools):    %b\n' "$tools_st"
    printf '  Протокол LuCI:                %b\n' "$proto_st"
    printf '  Русский перевод LuCI:         %b\n' "$ru_st"
    printf '  Модуль в ядре:                %b\n' "$mod_ver"
    echo
    echo "  [1] Установить / обновить AmneziaWG (с русским переводом LuCI)"
    echo "  [2] Установить / обновить AmneziaWG (без перевода)"
    echo "  [3] Диагностика системы (amneziawg-check.sh)"
    echo "  [4] Статус интерфейсов (awg show)"
    echo "  [8] Удалить AmneziaWG (пакеты и репозиторий)"
    echo "  [0] Назад"
    echo
    ask "Ваш выбор [0]: "
    read -r choice
    case "$choice" in
      1) install_awg_openwrt "-r" ;;
      2) install_awg_openwrt ;;
      3) check_awg_openwrt ;;
      4)
        echo
        if command -v awg >/dev/null 2>&1; then
          info "Вывод 'awg show':"
          awg show || true
        else
          warn "Утилита 'awg' не найдена (пакет amneziawg-tools не установлен)."
        fi
        echo
        pause_press_enter
        ;;
      8)
        if confirm_no "Удалить AmneziaWG (пакеты kmod-amneziawg, amneziawg-tools, luci-proto-amneziawg и фид)?"; then
          remove_awg_openwrt
          pause_press_enter
        fi
        ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# TG WS Proxy (Rust) — установка, подбор параметров и сквозная проверка
# ---------------------------------------------------------------------------
# В opkg этого пакета нет: это релизный бинарь с GitHub, и ставит его штатный
# install.sh проекта — он же пишет config.conf и Entware-инициализацию под
# rc.unslung. Меню добавляет то, чего у установщика быть не может: замер этой
# сети, подбор параметров под неё и проверку, что выданная ссылка работает
# целиком, а не «порт открыт».

# Пути install.sh tg-ws-proxy-rs на OpenWrt
TG_WS_PROXY_RS_BIN="/usr/bin/tg-ws-proxy-rs"
TG_WS_PROXY_RS_INIT="/etc/init.d/tg-ws-proxy-rs"
TG_WS_PROXY_RS_CONF_DIR="/etc/tg-ws-proxy-rs"
TG_WS_PROXY_RS_LOG="/var/log/tg-ws-proxy-rs.log"
TG_WS_PROXY_RS_CONF="$TG_WS_PROXY_RS_CONF_DIR/config.conf"
TG_WS_PROXY_RS_SECRET="$TG_WS_PROXY_RS_CONF_DIR/secret.conf"
TG_WS_PROXY_RS_REPO="valnesfjord/tg-ws-proxy-rs"
TG_WS_PROXY_RS_DC_TARGETS="2:149.154.167.220,4:149.154.167.220"
TG_WS_PROXY_RS_TOP_DOMAINS=4
TG_WS_PROXY_RS_FRONTING_DOMAIN="sprinthost.ru"
# Латентность последней пробы, результаты перебора вариантов и выбор
# пользователя.  Результаты — строками «индекс|ms|вердикт|описание».
TG_WS_PROXY_RS_LAST_MS=""
TG_WS_PROXY_RS_RESULTS=""
TG_WS_PROXY_RS_PICK=""
TG_WS_PROXY_RS_BEST_IDX=""

is_tg_ws_proxy_rs_installed() { [ -x "$TG_WS_PROXY_RS_BIN" ]; }

tg_ws_proxy_rs_version() {
  "$TG_WS_PROXY_RS_BIN" --version 2>/dev/null | head -1 | \
    sed -n 's/.*[[:space:]]\([0-9][0-9.]*\)[[:space:]]*$/\1/p'
}

# config.conf — шелл-присваивания, читаем их sed-ом (так же делает инсталлер).
tg_ws_proxy_rs_conf_get() {
  sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$TG_WS_PROXY_RS_CONF" 2>/dev/null | tr -d '\r' | head -1
}

# Записать ключ, сохранив остальные строки и комментарии. awk, а не sed:
# значение приходит из сети и может содержать /, & и кавычки.
tg_ws_proxy_rs_conf_set() {
  local key="$1" val="$2" tmp="$TG_WS_PROXY_RS_CONF.tmp.$$"
  [ -f "$TG_WS_PROXY_RS_CONF" ] || return 1
  awk -v k="$key" -v v="$val" '
    $0 ~ "^" k "=" { print k "=\"" v "\""; seen = 1; next }
    { print }
    END { if (!seen) print k "=\"" v "\"" }
  ' "$TG_WS_PROXY_RS_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$TG_WS_PROXY_RS_CONF"
}

# Бэкапы конфига копятся с каждым подбором (по одному на прогон), поэтому
# держим последние три — так же, как инсталлер поступает со своими.
tg_ws_proxy_rs_prune_backups() {
  local dir="$TG_WS_PROXY_RS_CONF_DIR" keep=3 old
  [ -d "$dir" ] || return 0
  # shellcheck disable=SC2012 # имена однотипные: config.conf.bak.<дата>
  for old in $(ls -1 "$dir"/config.conf.bak.* 2>/dev/null | sort -r | tail -n +$((keep + 1))); do
    rm -f "$old"
  done
  return 0
}

# Проба своего слушателя появилась в 2.4.5 — у более старого бинаря её нет.
tg_ws_proxy_rs_supports_check_listener() {
  "$TG_WS_PROXY_RS_BIN" --help 2>&1 | grep -q -- '--check-listener'
}

# Свободный порт для пробного запуска: сервис держит свой, а проба поднимает
# собственный слушатель. Начинаем с порта сервиса + 1.
tg_ws_proxy_rs_free_port() {
  local base port
  base=$(tg_ws_proxy_rs_conf_get PORT); [ -n "$base" ] || base=1443
  port=$((base + 1))
  while [ "$port" -lt $((base + 20)) ]; do
    port_is_open "$port" || { echo "$port"; return 0; }
    port=$((port + 1))
  done
  return 1
}

# Имя релизного архива — то, что инсталлер скачает и распакует. Меню нужно оно
# до установки, чтобы показать размер.
tg_ws_proxy_rs_target() {
  local best
  best=$(_arch_from_opkg)
  [ -n "$best" ] || best="${DISTRIB_ARCH_VAL:-$ARCH_RAW}"
  [ -n "$best" ] || best=$(uname -m 2>/dev/null) || return 1
  case "$best" in
    aarch64*)        printf '%s' aarch64-unknown-linux-musl ;;
    armv7*|arm_cortex-a[7-9]*|arm_cortex-a1[0-5]*) printf '%s' armv7-unknown-linux-musleabihf ;;
    mipsel*)         printf '%s' mipsel-unknown-linux-musl ;;
    mips*)           printf '%s' mips-unknown-linux-musl ;;
    x86_64*|x64*|amd64*) printf '%s' x86_64-unknown-linux-musl ;;
    *) return 1 ;;
  esac
}

tg_ws_proxy_rs_mb() {  # $1 = байты, $2 = знаков после точки (1 или 2)
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  # %.2f и %.1f заданы буквально: в BusyBox awk нет формы с «*».
  if [ "${2:-2}" = "1" ]; then
    awk -v b="$1" 'BEGIN{printf "%.1f МБ", b/1048576}'
  else
    awk -v b="$1" 'BEGIN{printf "%.2f МБ", b/1048576}'
  fi
}

# Размер распакованного бинаря: релиз кладёт его в .tar.gz, и на флеш ложится
# заметно больше архива (у обычной сборки — примерно вдвое). Числа сняты с
# релиза v2.4.5 и больше не перемеряются: от релиза к релизу они гуляют на
# десятые доли процента (v2.5.0 поменял второй знак в трёх ячейках из десяти),
# а таблица нужна, чтобы сравнивать сборки между собой, а не как точный размер.
# Формат: <target> <обычная> <upx>.
TG_WS_PROXY_RS_BIN_SIZES="
aarch64-unknown-linux-musl 3846224 1441272
armv7-unknown-linux-musleabihf 3687132 1347496
mipsel-unknown-linux-musl 4930100 1471168
mips-unknown-linux-musl 4909616 1447848
x86_64-unknown-linux-musl 4588192 1707600
"

# Размер бинаря для цели; пусто — цели нет в таблице (показываем только архив).
tg_ws_proxy_rs_bin_size() {
  local size
  size=$(printf '%s\n' "$TG_WS_PROXY_RS_BIN_SIZES" | awk -v t="$1" -v v="$2" '$1==t{print (v=="upx")?$3:$2}')
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$size"
}

# Потребление памяти: RSS сразу после старта сервиса, без трафика. Замерено на
# mipsel с релизом v2.4.5 (разброс между прогонами ±0.2 МБ). Формат:
# <target> <обычная> <upx>, в килобайтах. Цель без строки — память покажем
# словами, без чисел, чтобы не выдумывать чужие замеры.
TG_WS_PROXY_RS_RAM_SIZES="
mipsel-unknown-linux-musl 2688 3248
"

tg_ws_proxy_rs_ram_size() {  # $1 = target, $2 = plain|upx
  local size
  size=$(printf '%s\n' "$TG_WS_PROXY_RS_RAM_SIZES" | awk -v t="$1" -v v="$2" '$1==t{print (v=="upx")?$3:$2}')
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$size"
}

# Обычная сборка или компактная. Разница — флеш против ОЗУ: UPX-бинарь
# распаковывается в память целиком, и вытеснить её ядро не может (у обычного
# кода страницы файловые, их ядро освобождает под давлением, а на роутере нет
# даже свопа). Поэтому по умолчанию — обычная, а компактная для тех боксов, где
# флеша в обрез.
tg_ws_proxy_rs_choose_variant() {
  local target plain_bin upx_bin plain_ram upx_ram answer image tries
  local plain_flash plain_mem plain_evict upx_flash upx_mem upx_evict
  TG_WS_PROXY_RS_UPX=0
  target=$(tg_ws_proxy_rs_target 2>/dev/null) || target=''
  plain_bin=''; upx_bin=''; plain_ram=''; upx_ram=''
  if [ -n "$target" ]; then
    plain_bin=$(tg_ws_proxy_rs_bin_size "$target" plain 2>/dev/null) || plain_bin=''
    upx_bin=$(tg_ws_proxy_rs_bin_size "$target" upx 2>/dev/null) || upx_bin=''
    plain_ram=$(tg_ws_proxy_rs_ram_size "$target" plain 2>/dev/null) || plain_ram=''
    upx_ram=$(tg_ws_proxy_rs_ram_size "$target" upx 2>/dev/null) || upx_ram=''
    # Таблица в килобайтах (как /proc), форматтер ждёт байты.
    [ -n "$plain_ram" ] && plain_ram=$((plain_ram * 1024))
    [ -n "$upx_ram" ] && upx_ram=$((upx_ram * 1024))
  fi
  # Ячейки таблицы — только ASCII, а «МБ» стоит в заголовке: printf в BusyBox
  # считает ширину в байтах, и кириллица в ячейке сломала бы выравнивание.
  plain_flash='—'; plain_mem='—'; plain_evict='код вытесняемый'
  upx_flash='—'; upx_mem='—'; upx_evict='образ в ОЗУ, не вытесняется'
  if [ -n "$plain_bin" ]; then
    plain_flash=$(tg_ws_proxy_rs_mb "$plain_bin"); plain_flash="${plain_flash% МБ}"
  fi
  if [ -n "$upx_bin" ]; then
    upx_flash=$(tg_ws_proxy_rs_mb "$upx_bin"); upx_flash="${upx_flash% МБ}"
  fi
  if [ -n "$plain_ram" ]; then
    plain_mem=$(tg_ws_proxy_rs_mb "$plain_ram" 1); plain_mem="~${plain_mem% МБ}"
    plain_evict='1.6 МБ — код читается с флеша'
  fi
  if [ -n "$upx_ram" ]; then
    upx_mem=$(tg_ws_proxy_rs_mb "$upx_ram" 1); upx_mem="~${upx_mem% МБ}+"
    upx_evict='нет — образ распакован в ОЗУ'
  elif [ -n "$plain_bin" ]; then
    upx_evict="образ ≈$(tg_ws_proxy_rs_mb "$plain_bin") в ОЗУ, не вытесняется"
  fi
  echo
  info "Какую сборку поставить?"
  echo
  echo "                      флеш, МБ память, МБ вытесняемых"
  printf '  1) Обычная          %-9s%-11s%s\n' "$plain_flash" "$plain_mem" "$plain_evict"
  printf '  2) Компактная (UPX) %-9s%-11s%s\n' "$upx_flash" "$upx_mem" "$upx_evict"
  echo
  echo "  Рекомендуется обычная сборка; компактная — если флеш-памяти мало."
  # Ответ не из списка не принимаем молча: сюда легко попасть нажатием «n» на
  # предыдущий вопрос, и тогда на экране «n», а поставлено будет что-то другое.
  tries=0
  while [ "$tries" -lt 3 ]; do
    ask "${LBL_YOUR_CHOICE} [0]: "
    read_menu answer || break
    case "$answer" in
      1|"") TG_WS_PROXY_RS_UPX=0; break ;;
      2) TG_WS_PROXY_RS_UPX=1; break ;;
      *) warn "Ответ не распознан — введите 1 или 2." ;;
    esac
    tries=$((tries + 1))
  done
  if [ "$TG_WS_PROXY_RS_UPX" = "1" ]; then
    image=''
    [ -n "$plain_bin" ] && image=" (≈$(tg_ws_proxy_rs_mb "$plain_bin"))"
    info "Компактная сборка: образ$image распаковывается в ОЗУ целиком и не вытесняется — флеш экономится за счёт постоянной памяти."
  fi
  return 0
}

tg_ws_proxy_rs_install() {
  local url="https://raw.githubusercontent.com/${TG_WS_PROXY_RS_REPO}/main/install.sh"
  local script="/tmp/tgws-install.$$.sh" out rc upx_arg='' bin_size size_text esc
  tg_ws_proxy_rs_choose_variant || return 1
  [ "$TG_WS_PROXY_RS_UPX" = "1" ] && upx_arg='--upx'
  if ! download_sh_validated "$url" "$script" 20000; then
    error "Не удалось скачать целый install.sh — проверьте доступ к GitHub / зеркалам."
    return 1
  fi
  info "Установка из релиза…"
  # --platform openwrt задаём явно; вывод показываем под отступом и без строк,
  # которые дальше повторяет меню.
  out=$(sh "$script" --platform openwrt $upx_arg 2>&1)
  rc=$?
  rm -f "$script"
  # Инсталлер красит вывод ANSI-кодами, поэтому сначала снимаем цвет (меню
  # красит само), затем убираем строки, которые дальше повторяет меню: ссылку
  # оно печатает само и только после проверки связи, а «Rollback backup»
  # дублирует «Backup» тем же путём.
  esc=$(printf '\033')
  printf '%s\n' "$out" | sed "s/${esc}\[[0-9;]*m//g" | grep -v -e '^Proxy link:' -e '^Rollback backup:' | sed 's/^/    /'
  if [ "$rc" -ne 0 ]; then
    error "install.sh завершился с ошибкой."
    return 1
  fi
  is_tg_ws_proxy_rs_installed || { error "Бинарь не найден: $TG_WS_PROXY_RS_BIN"; return 1; }
  bin_size=$(wc -c < "$TG_WS_PROXY_RS_BIN" 2>/dev/null | tr -d ' \r\n') || bin_size=''
  size_text=$(tg_ws_proxy_rs_mb "$bin_size" 2>/dev/null) || size_text=''
  if [ -n "$size_text" ]; then
    info "Установлено: $(tg_ws_proxy_rs_version), $size_text"
  else
    info "Установлено: $(tg_ws_proxy_rs_version)"
  fi
  return 0
}

# Перезапуск без вывода init-скрипта: в этом пункте он только шумит, а факт
# перезапуска сообщает одна строка.
tg_ws_proxy_rs_restart() {
  [ -x "$TG_WS_PROXY_RS_INIT" ] || return 0
  if "$TG_WS_PROXY_RS_INIT" restart >/dev/null 2>&1; then
    info "Сервис перезапущен."
    return 0
  fi
  warn "Сервис не перезапустился — смотрите лог: $TG_WS_PROXY_RS_LOG"
  return 1
}

# Замер CF-доменов: --check печатает строку на домен, но WARN-строки лога
# влезают в ту же строку, поэтому результат берём из [OK ] в строке.
# На выходе «ms домен» по возрастанию, только ответившие.
tg_ws_proxy_rs_measure_domains() {
  local line dom ms
  "$TG_WS_PROXY_RS_BIN" --check --default-domains 2>&1 | while IFS= read -r line; do
    case "$line" in
      *"[OK ]"*) ;;
      *) continue ;;
    esac
    dom=$(printf '%s' "$line" | sed -n 's/^ *kws2\.\([^ ]*\) .*/\1/p')
    ms=$(printf '%s' "$line" | sed -n 's/.*\[OK \] *\([0-9][0-9]*\)ms.*/\1/p')
    [ -n "$dom" ] && [ -n "$ms" ] && printf '%s %s\n' "$ms" "$dom"
  done | sort -n | awk '!seen[$2]++ { print $2 }'
}

# Сквозная проверка штатной пробой бинаря: он поднимает слушатель на свободном
# порту с тем же секретом, маршрутами и тирами, что и сервис, и требует resPQ от
# DC Telegram. Конфиг читается так же, как его читает init-скрипт — через
# переменные окружения (с той же чисткой CR, что и там: файл мог побывать в
# редакторе на Windows).
tg_ws_proxy_rs_probe() {
  local port out section verdict
  port=$(tg_ws_proxy_rs_free_port) || {
    warn "Нет свободного порта для проверки (заняты порты рядом с сервисным)."
    return 1
  }

  out=$(
    scrub_and_source() {
      tr -d '\r' < "$1" > "/tmp/tgws-conf.$$" 2>/dev/null || true
      if [ -f "/tmp/tgws-conf.$$" ]; then
        . "/tmp/tgws-conf.$$" 2>/dev/null || true
        rm -f "/tmp/tgws-conf.$$"
      fi
    }
    scrub_and_source "$TG_WS_PROXY_RS_CONF" 2>/dev/null
    scrub_and_source "$TG_WS_PROXY_RS_SECRET" 2>/dev/null

    [ -n "$HOST" ] && export TG_HOST="$HOST"
    [ -n "$LINK_IP" ] && export TG_LINK_IP="$LINK_IP"
    export TG_SECRET="$SECRET"
    # Community-список доменов здесь не включаем намеренно: он добавляет около
    # 27 секунд на каждый прогон (31 с против 4 с в замере), а варианту лестницы
    # не нужен — домены замеряются отдельно, один раз, до перебора.
    [ -n "$CF_DOMAIN" ] && export TG_CF_DOMAIN="$CF_DOMAIN"
    [ -n "$CF_WORKER_DOMAIN" ] && export TG_CF_WORKER_DOMAIN="$CF_WORKER_DOMAIN"
    [ -n "$MTPROTO_PROXY" ] && export TG_MTPROTO_PROXY="$MTPROTO_PROXY"

    # shellcheck disable=SC2086 # EXTRA_ARGS — список аргументов, как его пишет инсталлер
    "$TG_WS_PROXY_RS_BIN" --port "$port" --check-listener $EXTRA_ARGS 2>&1
  )

  # В том же прогоне проверяются и CF-домены из конфига, поэтому вердикт берём
  # из секции своего слушателя, а не из кода выхода. Заодно запоминаем её
  # латентность — по ней ищется быстрейший вариант лестницы.
  section=$(printf '%s\n' "$out" | sed -n '/Own listener/,/^=\{10,\}/p')
  verdict=$(printf '%s\n' "$section" | grep -o '\[\(OK \|FAIL\|SKIP\)\]' | head -1)
  TG_WS_PROXY_RS_LAST_MS=$(printf '%s\n' "$section" | grep -o '[0-9][0-9]*ms' | head -1 | tr -d 'ms')
  [ "$verdict" = "[OK ]" ]
}

# Варианты лестницы: индекс → DC_IP | EXTRA_ARGS | описание.
# Порядок здесь — порядок перебора; в списке для пользователя они сортируются
# по замеру.
tg_ws_proxy_rs_variant() {
  case "$1" in
    1) printf '%s|%s|%s\n' "$TG_WS_PROXY_RS_DC_TARGETS" \
         "--pinned-upstream ws,cfproxy,tcp" "прямой WebSocket (ws → cfproxy → tcp)" ;;
    2) printf '%s|%s|%s\n' "$TG_WS_PROXY_RS_DC_TARGETS" \
         "--pinned-upstream ws,cfproxy,tcp --fronting-domain $TG_WS_PROXY_RS_FRONTING_DOMAIN" \
         "прямой WebSocket с фронтингом SNI" ;;
    3) printf '%s|%s|%s\n' "" "" "лестница по умолчанию (cfproxy → tcp)" ;;
    4) printf '%s|%s|%s\n' "" "--cf-disable-tls" \
         "cfproxy поверх ws:// (порт 80 вместо 443)" ;;
    *) return 1 ;;
  esac
}

# Проверяет каждый вариант пробой и складывает результат в
# TG_WS_PROXY_RS_RESULTS строками «индекс|ms|вердикт|описание».
# Сервис не перезапускается: проба поднимает собственный слушатель и читает
# конфиг с диска.
tg_ws_proxy_rs_probe_variants() {
  local i row dc args label ms
  TG_WS_PROXY_RS_RESULTS=""
  info "Проверяю варианты (по одному прогону на каждый, это самая долгая часть)…"
  i=1
  while :; do
    row=$(tg_ws_proxy_rs_variant "$i") || break
    dc=$(printf '%s' "$row" | cut -d'|' -f1)
    args=$(printf '%s' "$row" | cut -d'|' -f2)
    label=$(printf '%s' "$row" | cut -d'|' -f3)

    # Ничего не печатаем: итог покажет список ниже, а строка на каждый вариант
    # его же и дублировала.
    tg_ws_proxy_rs_conf_set DC_IP "$dc"
    tg_ws_proxy_rs_conf_set EXTRA_ARGS "$args"
    if tg_ws_proxy_rs_probe; then
      ms="$TG_WS_PROXY_RS_LAST_MS"; [ -n "$ms" ] || ms=0
      TG_WS_PROXY_RS_RESULTS="$TG_WS_PROXY_RS_RESULTS$i|$ms|OK|$label
"
    else
      TG_WS_PROXY_RS_RESULTS="$TG_WS_PROXY_RS_RESULTS$i|999999|FAIL|$label
"
    fi
    i=$((i + 1))
  done
  return 0
}

# Печатает список проверенных путей: обычные — с временем и пометкой быстрейшего,
# запасной режим TLS-MITM — отдельной строкой ниже: он для сломанного TLS, а не
# для скорости, и часто оказывается быстрее всех просто потому, что идёт по
# открытому HTTP.
tg_ws_proxy_rs_show_variants() {
  local rows normal fallback
  rows=$(printf '%s' "$TG_WS_PROXY_RS_RESULTS" | grep -v '^$')
  [ -n "$rows" ] || return 1
  normal=$(printf '%s\n' "$rows" | awk -F'|' '$1 != 4')
  fallback=$(printf '%s\n' "$rows" | awk -F'|' '$1 == 4')

  TG_WS_PROXY_RS_BEST_IDX=$(printf '%s\n' "$normal" | awk -F'|' '$3 == "OK" { print $2 " " $1 }' | sort -n | awk 'NR == 1 { print $2 }')

  echo
  printf '%s\n' "${BOLD}Проверенные пути:${NC}"
  printf '%s\n' "$normal" | awk -F'|' -v best="$TG_WS_PROXY_RS_BEST_IDX" '
    {
      n++
      mark = ($1 == best) ? "   <- быстрейший" : ""
      if ($3 == "OK") printf "  [%d] OK   %5sms  %s%s\n", n, $2, $4, mark
      else            printf "  [%d] FAIL         %s\n", n, $4
    }'
  if [ -n "$fallback" ]; then
    echo
    printf '%s\n' "  запасной режим (TLS-MITM, метаданные идут открыто):"
    printf '%s\n' "$fallback" | awk -F'|' '
      {
        if ($3 == "OK") printf "  [%d] OK   %5sms  %s\n", $1, $2, $4
        else            printf "  [%d] FAIL         %s\n", $1, $4
      }'
  fi
  return 0
}

# Спрашивает, какой путь взять. Пишет индекс в TG_WS_PROXY_RS_PICK;
# пустая строка означает «оставить как было».
tg_ws_proxy_rs_ask_variant() {
  local rows pick row verdict tries=0
  # Список печатается в том же порядке, поэтому номер в ответе — это строка
  # результатов, а не отдельная нумерация.
  rows=$(printf '%s' "$TG_WS_PROXY_RS_RESULTS" | grep -v '^$')
  TG_WS_PROXY_RS_PICK=""

  while [ "$tries" -lt 3 ]; do
    if [ -n "$TG_WS_PROXY_RS_BEST_IDX" ]; then
      ask "Какой путь взять? [Enter = быстрейший, 0 = не менять]: "
    else
      ask "Ни один путь не ответил. [Enter = не менять]: "
    fi
    read -r pick

    case "$pick" in
      "")
        [ -n "$TG_WS_PROXY_RS_BEST_IDX" ] && TG_WS_PROXY_RS_PICK="$TG_WS_PROXY_RS_BEST_IDX"
        return 0
        ;;
      0) return 0 ;;
      *[!0-9]*) warn "Нужен номер из списка." ;;
      *)
        row=$(printf '%s\n' "$rows" | awk -F'|' -v n="$pick" '$1 == n')
        if [ -z "$row" ]; then
          warn "Нет такого номера."
        else
          verdict=$(printf '%s' "$row" | cut -d'|' -f3)
          if [ "$verdict" = "OK" ]; then
            TG_WS_PROXY_RS_PICK=$(printf '%s' "$row" | cut -d'|' -f1)
            return 0
          fi
          warn "Этот путь не ответил — выберите другой."
        fi
        ;;
    esac
    tries=$((tries + 1))
  done
  return 0
}

# Отвечал ли вариант с такими параметрами: по нему решается, считать ли
# оставленный конфиг проверенным.
tg_ws_proxy_rs_variant_ok_for() {
  local i row
  i=1
  while :; do
    row=$(tg_ws_proxy_rs_variant "$i") || return 1
    if [ "$(printf '%s' "$row" | cut -d'|' -f1)" = "$1" ] &&
       [ "$(printf '%s' "$row" | cut -d'|' -f2)" = "$2" ]; then
      printf '%s' "$TG_WS_PROXY_RS_RESULTS" | grep -q "^$i|.*|OK|"
      return $?
    fi
    i=$((i + 1))
  done
}

# Подбор параметров под сеть: CF-домены по замеру, затем перебор вариантов
# лестницы с пробой каждого — список с результатами отдаётся пользователю,
# какой путь взять, решает он.
tg_ws_proxy_rs_tune() {
  local domains best orig_dc orig_args
  # Проба по ходу перебора пишет варианты в конфиг, поэтому исходные значения
  # сохраняем: «не менять» должно вернуть именно их.
  orig_dc=$(tg_ws_proxy_rs_conf_get DC_IP)
  orig_args=$(tg_ws_proxy_rs_conf_get EXTRA_ARGS)
  TG_WS_PROXY_RS_RESULTS=""
  TG_WS_PROXY_RS_PICK=""
  TG_WS_PROXY_RS_BEST_IDX=""
  info "Замер CF-доменов…"
  domains=$(tg_ws_proxy_rs_measure_domains | head -"$TG_WS_PROXY_RS_TOP_DOMAINS")
  if [ -z "$domains" ]; then
    warn "Ни один CF-домен не ответил — оставляем список по умолчанию."
  else
    best=$(printf '%s\n' "$domains" | tr '\n' ',' | sed 's/,$//')
    tg_ws_proxy_rs_conf_set CF_DOMAIN "$best"
    info "CF-домены: $best"
  fi

  # Все варианты проверяются пробой, а затем список отдаётся пользователю:
  # какой путь взять — его решение, замер лишь показывает цену каждого.
  tg_ws_proxy_rs_probe_variants
  tg_ws_proxy_rs_show_variants
  tg_ws_proxy_rs_ask_variant

  if [ -n "$TG_WS_PROXY_RS_PICK" ]; then
    row=$(tg_ws_proxy_rs_variant "$TG_WS_PROXY_RS_PICK")
    tg_ws_proxy_rs_conf_set DC_IP "$(printf '%s' "$row" | cut -d'|' -f1)"
    tg_ws_proxy_rs_conf_set EXTRA_ARGS "$(printf '%s' "$row" | cut -d'|' -f2)"
    tg_ws_proxy_rs_restart
    info "Путь: $(printf '%s' "$row" | cut -d'|' -f3)"
    return 0
  fi

  # Ничего не выбрано (или ни один путь не ответил) — возвращаем то, что было
  # до подбора: перебор по ходу писал варианты в конфиг.
  tg_ws_proxy_rs_conf_set DC_IP "$orig_dc"
  tg_ws_proxy_rs_conf_set EXTRA_ARGS "$orig_args"
  tg_ws_proxy_rs_restart

  if tg_ws_proxy_rs_variant_ok_for "$orig_dc" "$orig_args"; then
    info "Оставлены прежние параметры — этот путь отвечает."
    return 0
  fi
  warn "Путь не изменён, но прежние параметры в списке не отвечали."
  return 1
}

tg_ws_proxy_rs_print_link() {
  local link
  echo
  link=$(sed -n 's/.*\(tg:\/\/proxy?[^ ]*\).*/\1/p' "$TG_WS_PROXY_RS_LOG" 2>/dev/null | tail -1)
  if [ -n "$link" ]; then
    printf '%s\n' "${BOLD}Ссылка для клиентов:${NC}"
    printf '%s\n' "${BOLD}  $link${NC}"
  else
    warn "Ссылки в логе нет — сервис, похоже, не запущен."
    [ -x "$TG_WS_PROXY_RS_INIT" ] && "$TG_WS_PROXY_RS_INIT" status
  fi
  echo
  printf '%s\n' "  config: $TG_WS_PROXY_RS_CONF_DIR/config.conf (секрет — secret.conf рядом)"
  printf '%s\n' "  init:   $TG_WS_PROXY_RS_INIT"
}

menu_tg_ws_proxy_rs() {
  local fresh=0
  echo

  if is_tg_ws_proxy_rs_installed; then
    info "TG WS Proxy Rust — установлено $(tg_ws_proxy_rs_version)"
    if confirm_yes "Переустановить/обновить из последнего релиза?"; then
      tg_ws_proxy_rs_install || return 1
    fi
  else
    info "TG WS Proxy Rust (tg-ws-proxy-rs)"
    confirm_yes "Установить tg-ws-proxy-rs?" || return 0
    tg_ws_proxy_rs_install || return 1
    fresh=1
  fi

  echo
  if ! tg_ws_proxy_rs_supports_check_listener; then
    warn "У этого бинаря нет пробы своего слушателя — нужна версия 2.4.5 или новее."
    warn "Обновить: перезапустите этот пункт и подтвердите переустановку."
    tg_ws_proxy_rs_print_link
    return 0
  fi

  # На чистой установке подбор не спрашивают: только что поставили — незачем
  # оставлять прокси невыверенным. Спрашиваем при повторном заходе.
  if [ "$fresh" = "1" ] || confirm_yes "Подобрать параметры и проверить?"; then
    backup_file "$TG_WS_PROXY_RS_CONF"
    tg_ws_proxy_rs_prune_backups
    if tg_ws_proxy_rs_tune; then
      echo
      info "Связь проверена: resPQ от DC Telegram."
    else
      echo
      warn "Связь не подтвердилась. Последние строки лога:"
      tail -n 8 "$TG_WS_PROXY_RS_LOG" 2>/dev/null | sed 's/^/    /'
    fi
  fi

  tg_ws_proxy_rs_print_link
}

remove_tg_ws_proxy_rs() {
  is_tg_ws_proxy_rs_installed || { warn "tg-ws-proxy-rs не установлен."; return 0; }
  [ -x "$TG_WS_PROXY_RS_INIT" ] && "$TG_WS_PROXY_RS_INIT" stop 2>/dev/null
  rm -f "$TG_WS_PROXY_RS_INIT" "$TG_WS_PROXY_RS_BIN"
  info "tg-ws-proxy-rs удалён."
  if [ -d "$TG_WS_PROXY_RS_CONF_DIR" ]; then
    if confirm_no "Удалить конфиг и секрет ($TG_WS_PROXY_RS_CONF_DIR)?"; then
      rm -rf "$TG_WS_PROXY_RS_CONF_DIR"
      info "Каталог $TG_WS_PROXY_RS_CONF_DIR удалён."
    else
      info "Конфиг и секрет оставлены в $TG_WS_PROXY_RS_CONF_DIR."
    fi
  fi
  return 0
}

menu_magitrickle() {
  echo
  info "MagiTrickle"
  refresh_opkg_cache

  local mag_init="/etc/init.d/magitrickle"

  if is_installed "magitrickle"; then
    info "Пакет установлен — обновление..."
    pkg_update
    pkg_install magitrickle
    if [ -x "$mag_init" ]; then
      "$mag_init" restart
      info "Сервис перезапущен: $mag_init restart"
    else
      warn "Init-скрипт $mag_init не найден."
    fi
    info "Обновление завершено."
  else
    info "Пакет не установлен — установка..."
    confirm_yes "Добавить репозиторий MagiTrickle и установить пакет?" || { info "Отменено."; return 0; }
    if ! run_remote_sh "http://bin.magitrickle.dev/packages/add_repo.sh" 500; then
      error "Не удалось выполнить установщик репозитория MagiTrickle."
      return 1
    fi
    pkg_update
    pkg_install magitrickle
    if [ -x "$mag_init" ]; then
      "$mag_init" start
      info "Сервис запущен: $mag_init start"
    else
      warn "Init-скрипт $mag_init не найден."
    fi
    info "Установка завершена."
  fi

  echo
  printf '%s\n' "${BOLD}Управление сервисом${NC}"
  cat << EOF
$mag_init (start | stop | restart | status)
EOF
}

# ---------------------------------------------------------------------------
# 13. luci-app-telemt — LuCI Web UI + core daemon (Medvedolog/luci-app-telemt)
# ---------------------------------------------------------------------------
LUCI_TELEMT_REPO="Medvedolog/luci-app-telemt"
LUCI_TELEMT_VER="3.5.8"
TELEMT_OWRT_REPO="Medvedolog/telemt_owrt"
TELEMT_OWRT_TAG="3.5.8-2"
TELEMT_OWRT_VER="3.5.8-r2"

is_telemt_installed() {
  is_installed "luci-app-telemt" || is_installed "telemt" || \
    [ -x /usr/bin/telemt ] || [ -f /etc/init.d/telemt ] || [ -f /etc/config/telemt ]
}

_telemt_detect_core_arch() {
  [ -z "$ARCH" ] && detect_arch
  local raw="${DISTRIB_ARCH_VAL:-$ARCH_RAW}"
  case "$ARCH" in
    aarch64)
      case "$raw" in
        *cortex-a53*) echo "aarch64_cortex-a53" ;;
        *)            echo "aarch64_generic" ;;
      esac
      ;;
    x86_64)
      echo "x86_64"
      ;;
    *)
      echo ""
      ;;
  esac
}

install_luci_telemt() {
  local core_arch sel_arch="" core_fn core_url luci_fn luci_url
  local dest_core dest_luci backend arch_choice

  backend=$(pkg_backend)
  core_arch=$(_telemt_detect_core_arch)

  echo
  info "Подготовка к установке luci-app-telemt..."
  printf '%s\n' "  Пакетный менеджер: ${backend}"
  printf '%s\n' "  Архитектура роутера: ${ARCH:-unknown} (${DISTRIB_ARCH_VAL:-$ARCH_RAW})"
  echo

  if [ -n "$core_arch" ]; then
    info "Автоопределение архитектуры ядра: ${core_arch}"
    echo "  1) ${core_arch} (рекомендуется)"
    echo "  2) aarch64_cortex-a53"
    echo "  3) aarch64_generic"
    echo "  4) x86_64"
    echo "  5) Только веб-интерфейс luci-app-telemt (без ядра)"
    ask "Выберите вариант [1]: "
    read -r arch_choice
    case "$arch_choice" in
      2) sel_arch="aarch64_cortex-a53" ;;
      3) sel_arch="aarch64_generic" ;;
      4) sel_arch="x86_64" ;;
      5) sel_arch="" ;;
      1|"") sel_arch="$core_arch" ;;
      *) warn "Неверный выбор, используется ${core_arch}"; sel_arch="$core_arch" ;;
    esac
  else
    warn "Официальные прекомпилированные пакеты telemt_owrt собраны под aarch64 и x86_64."
    warn "Для архитектуры ${ARCH:-unknown} ядро telemt потребуется собрать или установить отдельно."
    if ! confirm_yes "Продолжить установку веб-интерфейса luci-app-telemt?"; then
      return 0
    fi
    sel_arch=""
  fi

  # 1. Установка ядра telemt (если выбрана архитектура)
  if [ -n "$sel_arch" ]; then
    if [ "$backend" = "apk" ]; then
      core_fn="telemt-${TELEMT_OWRT_VER}_${sel_arch}.apk"
    else
      core_fn="telemt_${TELEMT_OWRT_VER}_${sel_arch}.ipk"
    fi
    core_url="https://github.com/${TELEMT_OWRT_REPO}/releases/download/${TELEMT_OWRT_TAG}/${core_fn}"
    dest_core="/tmp/${core_fn}"

    info "Скачивание ядра telemt (${core_fn})..."
    rm -f "$dest_core"
    if ! download_file "$core_url" "$dest_core" progress; then
      error "Не удалось скачать ядро telemt (${core_fn})."
      rm -f "$dest_core"
      return 1
    fi

    info "Установка пакета ядра ${core_fn}..."
    if ! pkg_install_file "$dest_core"; then
      warn "Ошибка при установке пакета ядра ${core_fn}."
    fi
    rm -f "$dest_core"
  fi

  # 2. Установка зависимостей LuCI
  info "Установка зависимостей (luci-base, luci-compat, ca-bundle, qrencode)..."
  pkg_install luci-base luci-compat ca-bundle qrencode 2>/dev/null || true

  # 3. Установка luci-app-telemt
  if [ "$backend" = "apk" ]; then
    luci_fn="luci-app-telemt-${LUCI_TELEMT_VER}-r1.apk"
  else
    luci_fn="luci-app-telemt_${LUCI_TELEMT_VER}-r1_all.ipk"
  fi
  luci_url="https://github.com/${LUCI_TELEMT_REPO}/releases/download/${LUCI_TELEMT_VER}/${luci_fn}"
  dest_luci="/tmp/${luci_fn}"

  info "Скачивание веб-интерфейса ${luci_fn}..."
  rm -f "$dest_luci"
  if ! download_file "$luci_url" "$dest_luci" progress; then
    # Fallback на стабильную версию 3.4.0
    warn "Попытка загрузки версии 3.4.0..."
    if [ "$backend" = "apk" ]; then
      luci_fn="luci-app-telemt_3.4.0_noarch.apk"
    else
      luci_fn="luci-app-telemt_3.4.0_all.ipk"
    fi
    luci_url="https://github.com/${LUCI_TELEMT_REPO}/releases/download/3.4.0/${luci_fn}"
    dest_luci="/tmp/${luci_fn}"
    if ! download_file "$luci_url" "$dest_luci" progress; then
      error "Не удалось скачать luci-app-telemt."
      rm -f "$dest_luci"
      return 1
    fi
  fi

  info "Установка пакета ${luci_fn}..."
  if ! pkg_install_file "$dest_luci"; then
    error "Не удалось установить ${luci_fn}."
    rm -f "$dest_luci"
    return 1
  fi
  rm -f "$dest_luci"

  # Очистка кешей LuCI
  rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
  refresh_opkg_cache

  # Включение автозапуска сервиса procd
  if [ -x /etc/init.d/telemt ]; then
    /etc/init.d/telemt enable 2>/dev/null || true
  fi

  echo
  info "Установка luci-app-telemt успешно завершена!"
  local lan_ip; lan_ip=$(get_lan_ip)
  printf '%s\n' "  Веб-интерфейс доступен в LuCI:"
  printf '%s\n' "  ${GREEN}${BOLD}http://${lan_ip}/cgi-bin/luci/admin/services/telemt${NC}"
  echo

  if [ -x /etc/init.d/telemt ]; then
    if confirm_yes "Запустить сервис telemt прямо сейчас?"; then
      /etc/init.d/telemt restart
    fi
  fi
  return 0
}

remove_telemt() {
  echo
  info "Удаление luci-app-telemt и telemt..."
  if [ -x /etc/init.d/telemt ]; then
    /etc/init.d/telemt stop 2>/dev/null || true
    /etc/init.d/telemt disable 2>/dev/null || true
  fi
  pkg_remove luci-app-telemt telemt 2>/dev/null || true
  rm -f /usr/bin/telemt /etc/init.d/telemt
  rm -rf /tmp/etc/telemt.toml /tmp/telemt* /tmp/luci-app-telemt*
  rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
  if [ -f /etc/config/telemt ]; then
    if confirm_no "Удалить конфигурацию и секреты (/etc/config/telemt)?"; then
      rm -f /etc/config/telemt
      info "Конфигурация /etc/config/telemt удалена."
    else
      info "Конфигурация сохранена в /etc/config/telemt."
    fi
  fi
  refresh_opkg_cache
  info "luci-app-telemt и telemt удалены."
}

telemt_show_info() {
  echo
  printf '%s\n' "${CYAN}${BOLD}Параметры сервиса telemt (из UCI /etc/config/telemt):${NC}"
  if ! [ -f /etc/config/telemt ]; then
    warn "Конфигурационный файл /etc/config/telemt не найден."
    return 0
  fi
  local port host secret lan_ip
  port=$(uci get telemt.main.port 2>/dev/null || echo "не задан")
  host=$(uci get telemt.main.mask_host 2>/dev/null || echo "не задан")
  secret=$(uci get telemt.main.secret 2>/dev/null || echo "")
  lan_ip=$(get_lan_ip)

  printf '  Порт:       %s\n' "$port"
  printf '  Маскировка: %s\n' "$host"
  [ -n "$secret" ] && printf '  Секрет:     %s\n' "$secret"
  echo
  printf '%s\n' "  Веб-интерфейс LuCI (настройка, пользователи, QR-коды):"
  printf '%s\n' "  ${GREEN}${BOLD}http://${lan_ip}/cgi-bin/luci/admin/services/telemt${NC}"
}

menu_telemt() {
  local choice lan_ip ver_luci ver_core svc_st
  while :; do
    echo
    printf '%s\n' "${CYAN}${BOLD}              luci-app-telemt (MTProxy для OpenWrt)${NC}"
    printf '%s\n' "${DIM}     LuCI: https://github.com/Medvedolog/luci-app-telemt${NC}"
    printf '%s\n' "${DIM}     Core: https://github.com/Medvedolog/telemt_owrt${NC}"
    echo

    if is_installed "luci-app-telemt"; then
      ver_luci=$(pkg_version "luci-app-telemt")
      printf '  Веб-интерфейс LuCI:  %sустановлен%s (%s)\n' "${GREEN}" "${NC}" "${ver_luci:-ok}"
    else
      printf '  Веб-интерфейс LuCI:  %sне установлен%s\n' "${YELLOW}" "${NC}"
    fi

    if [ -x /usr/bin/telemt ]; then
      ver_core=$(/usr/bin/telemt --version 2>/dev/null | head -n1 | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
      [ -z "$ver_core" ] && ver_core=$(pkg_version "telemt")
      printf '  Ядро telemt:         %sустановлено%s (/usr/bin/telemt %s)\n' "${GREEN}" "${NC}" "${ver_core:-ok}"
    else
      printf '  Ядро telemt:         %sне установлено%s\n' "${YELLOW}" "${NC}"
    fi

    if [ -x /etc/init.d/telemt ]; then
      if proc_running "telemt"; then
        svc_st="${GREEN}запущен (⚡)${NC}"
      else
        svc_st="${RED}остановлен${NC}"
      fi
      printf '  Сервис telemt:       %s\n' "$svc_st"
    fi

    lan_ip=$(get_lan_ip)
    printf '  Ссылка в LuCI:       http://%s/cgi-bin/luci/admin/services/telemt\n' "$lan_ip"
    echo
    echo "  1. Установить / обновить luci-app-telemt и ядро telemt"
    echo "  2. Запустить сервис telemt"
    echo "  3. Перезапустить сервис telemt"
    echo "  4. Остановить сервис telemt"
    echo "  5. Журнал сервиса (logread / telemt)"
    echo "  6. Параметры подключения (UCI)"
    echo "  7. Удалить luci-app-telemt и ядро"
    echo "  0. ${LBL_BACK_ITEM:-Назад}"
    echo
    ask "${LBL_YOUR_CHOICE:-Ваш выбор} [0]: "
    read -r choice

    case "$choice" in
      0|"") return 0 ;;
      1) install_luci_telemt ;;
      2)
        if [ -x /etc/init.d/telemt ]; then
          /etc/init.d/telemt start
          info "Команда start отправлена."
        else
          warn "Сервис /etc/init.d/telemt не найден."
        fi
        ;;
      3)
        if [ -x /etc/init.d/telemt ]; then
          /etc/init.d/telemt restart
          info "Команда restart отправлена."
        else
          warn "Сервис /etc/init.d/telemt не найден."
        fi
        ;;
      4)
        if [ -x /etc/init.d/telemt ]; then
          /etc/init.d/telemt stop
          info "Сервис telemt остановлен."
        else
          warn "Сервис /etc/init.d/telemt не найден."
        fi
        ;;
      5)
        echo
        info "Последние записи журнала telemt:"
        if command -v logread >/dev/null 2>&1; then
          logread -e telemt | tail -n 25
        else
          cat /var/log/telemt.log 2>/dev/null | tail -n 25 || warn "Логи не найдены."
        fi
        ;;
      6) telemt_show_info ;;
      7)
        if confirm_yes "Точно удалить luci-app-telemt и ядро telemt?"; then
          remove_telemt
        fi
        ;;
      *) warn "${LBL_INVALID:-Неверный выбор}" ;;
    esac
  done
}


# ---------------------------------------------------------------------------
# 88. Удаление
# ---------------------------------------------------------------------------
remove_backups() {
  local dirs="$CONF_BASE_DIR/nfqws $CONF_BASE_DIR/nfqws2 $CONF_BASE_DIR/nfqws2/lists"
  local f count=0 found=""

  echo
  info "Поиск резервных копий (.bak.* , *.conf-opkg , *.list-opkg)..."
  for d in $dirs; do
    [ -d "$d" ] || continue
    for f in "$d"/*.bak.* "$d"/*.conf-opkg "$d"/*.list-opkg; do
      [ -f "$f" ] || continue
      found="$found $f"
    done
  done
  if [ -z "$found" ]; then
    info "Резервные копии не найдены."
    return 0
  fi
  for f in $found; do
    echo "  $f"
    count=$((count + 1))
  done
  echo
  if confirm_no "Удалить найденные файлы ($count шт.)?"; then
    for f in $found; do
      rm -f "$f" && info "  удалён: $f" || warn "  не удалось: $f"
    done
    info "Готово."
  else
    info "Отменено."
  fi
}

is_dpi_detector_installed() {
  [ -x "$(dpi_detector_bin)" ] || command -v dpi-detector >/dev/null 2>&1
}

dpi_detector_version() {
  local bin
  if [ -x "$(dpi_detector_bin)" ]; then
    bin=$(dpi_detector_bin)
  elif command -v dpi-detector >/dev/null 2>&1; then
    bin=$(command -v dpi-detector)
  else
    return 1
  fi
  "$bin" --version 2>/dev/null | head -1 | \
    sed -n 's/.*dpi-detector[[:space:]]\+\([^[:space:]]*\).*/\1/p'
}

remove_dpi_detector() {
  local paths="$(dpi_detector_bin) /usr/bin/dpi-detector /usr/local/bin/dpi-detector /tmp/dpi-detector" f found=0
  [ -n "$HOME" ] && paths="$paths $HOME/dpi-detector"
  for f in $paths; do
    [ -f "$f" ] && rm -f "$f" && info "  удалён: $f" && found=1
  done
  f=$(command -v dpi-detector 2>/dev/null || true)
  [ -n "$f" ] && [ -f "$f" ] && rm -f "$f" && info "  удалён: $f" && found=1
  if [ "$found" -eq 0 ]; then
    warn "dpi-detector не найден."
  else
    info "dpi-detector удалён."
  fi
}

is_awg_openwrt_installed() {
  is_installed "amneziawg-tools" || is_installed "kmod-amneziawg" || is_installed "luci-proto-amneziawg" || [ -d /sys/module/amneziawg ] || command -v awg >/dev/null 2>&1
}

remove_awg_openwrt() {
  pkg_remove luci-i18n-amneziawg-ru luci-proto-amneziawg luci-app-amneziawg amneziawg-tools kmod-amneziawg 2>/dev/null || true
  if [ -f /etc/opkg/customfeeds.conf ]; then
    sed -i '\|^[[:space:]]*src/gz[[:space:]][[:space:]]*awg[[:space:]]|d' /etc/opkg/customfeeds.conf 2>/dev/null || true
    sed -i '\|2grey\.github\.io/awg-openwrt|d' /etc/opkg/customfeeds.conf 2>/dev/null || true
    sed -i '\|slava-shchipunov\.github\.io/awg-openwrt|d' /etc/opkg/customfeeds.conf 2>/dev/null || true
  fi
  if [ -f /etc/apk/repositories.d/customfeeds.list ]; then
    sed -i '\|2grey\.github\.io/awg-openwrt|d' /etc/apk/repositories.d/customfeeds.list 2>/dev/null || true
    sed -i '\|slava-shchipunov\.github\.io/awg-openwrt|d' /etc/apk/repositories.d/customfeeds.list 2>/dev/null || true
  fi
  rm -f /etc/apk/keys/awg-openwrt-feed.pem /tmp/awg-openwrt-feed.* 2>/dev/null || true
  refresh_opkg_cache
  info "AmneziaWG удалён."
}

remove_magitrickle() {
  local mag_init="/etc/init.d/magitrickle"
  if is_installed "magitrickle"; then
    [ -x "$mag_init" ] && "$mag_init" stop 2>/dev/null || true
    pkg_remove magitrickle 2>/dev/null || true
    info "magitrickle удалён."
  else
    warn "magitrickle не установлен."
  fi
  # репозиторий пишет add_repo.sh — имя файла нам неизвестно, ищем по подстроке
  local repo_files="" f rc="$OPKG_CONF_DIR"
  [ "$(pkg_backend)" = "apk" ] && rc="$APK_REPO_DIR"
  for f in "$rc"/*magitrickle*; do
    if [ -f "$f" ]; then
      repo_files="$repo_files
$f"
    fi
  done
  [ -n "$repo_files" ] || return 0
  echo
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] && printf '%s\n' "  ${DIM}$f${NC}"
  done <<EOF
$repo_files
EOF
  if confirm_no "Удалить репозиторий MagiTrickle?"; then
    while IFS= read -r f || [ -n "$f" ]; do
      if [ -f "$f" ]; then
        rm -f "$f" && info "  удалён: $f"
      fi
    done <<EOF
$repo_files
EOF
  else
    info "Репозиторий MagiTrickle оставлен."
  fi
}

# ---------------------------------------------------------------------------
# 7. Смена активных fake:blob
# ---------------------------------------------------------------------------
nfqws_blobs_dir() {
  case "$1" in
    1) echo "${CONF_BASE_DIR}/nfqws" ;;
    2) echo "${CONF_BASE_DIR}/nfqws2/blobs" ;;
  esac
}

# map_file: name|basename
# list_file: idx|section|name|basename
# Один проход awk: секции + --blob= + fake:blob= (без grep/fork на каждую строку)
parse_fake_blobs() {
  local conf="$1"
  local map_file="$2"
  local list_file="$3"

  : > "$map_file"
  : > "$list_file"
  [ -f "$conf" ] || return 1

  # BusyBox/mawk-совместимый однопроходный разбор
  awk -v mapf="$map_file" -v listf="$list_file" '
  function basename(p,   n, a) {
    gsub(/["\047]/, "", p)
    if (p ~ /^0[xX]*/) return "(hex)"
    n = split(p, a, "/")
    return (n > 0 && a[n] != "") ? a[n] : p
  }
  BEGIN {
    cur = "?"
    idx = 0
  }
  {
    line = $0

    # Секции NFQWS_*ARGS*
    if (match(line, /^(NFQWS_BASE_ARGS|NFQWS_ARGS_QUIC|NFQWS_ARGS_UDP|NFQWS_ARGS_CUSTOM|NFQWS_EXTRA_ARGS|NFQWS_ARGS)=/)) {
      cur = substr(line, 1, RLENGTH - 1)
    }

    # Токены --blob=name:path (пробелы/табы как разделители)
    n = split(line, tok, /[ \t]+/)
    for (i = 1; i <= n; i++) {
      if (tok[i] ~ /^--blob=/) {
        rest = substr(tok[i], 8)   # после --blob=
        colon = index(rest, ":")
        if (colon < 1) continue
        name = substr(rest, 1, colon - 1)
        path = substr(rest, colon + 1)
        sub(/^@/, "", path)
        gsub(/["\047]/, "", path)
        if (name == "") continue
        base = basename(path)
        if (!(name in blobmap)) {
          blobmap[name] = base
          # порядок map не важен — пишем в END
        }
      }
    }

    # fake:blob=NAME (не hex) — basename резолвим в END (после всего map)
    if (index(line, "fake:blob=") == 0) next
    tmp = line
    while (match(tmp, /fake:blob=[^: \t"]+/)) {
      fb = substr(tmp, RSTART, RLENGTH)
      name = substr(fb, 11)   # после fake:blob=
      tmp = substr(tmp, RSTART + RLENGTH)
      if (name == "" || name ~ /^0[xX]/) continue
      if (name in seen) continue
      seen[name] = 1
      idx++
      order[idx] = name
      sec[name] = cur
    }
  }
  END {
    for (name in blobmap)
      print name "|" blobmap[name] > mapf
    close(mapf)
    for (i = 1; i <= idx; i++) {
      name = order[i]
      base = (name in blobmap) ? blobmap[name] : "(нет --blob= / встроенный)"
      print i "|" sec[name] "|" name "|" base > listf
    }
    close(listf)
    exit (idx > 0 ? 0 : 1)
  }
  ' "$conf"
}

list_repo_blobs() {
  # 1) strategies/blobs/SHA256SUMS  2) GitHub API  3) встроенный fallback
  local cache="/tmp/nfqws-repo-blobs.list"
  local now age=999999 list

  now=$(date +%s 2>/dev/null || echo 0)
  if [ -f "$cache" ]; then
    age=$((now - $(stat -c %Y "$cache" 2>/dev/null || echo 0)))
  fi
  if [ -f "$cache" ] && [ "$age" -lt 3600 ] && [ -s "$cache" ]; then
    cat "$cache"
    return 0
  fi

  if ensure_blobs_sha256sums; then
    list=$(awk 'NF >= 2 {
      n = $2
      sub(/.*\//, "", n)
      if (n ~ /\.bin$/) print n
    }' "$BLOBS_SHA256SUMS_CACHE" 2>/dev/null | sort -u)
    if [ -n "$list" ]; then
      printf '%s\n' "$list" > "$cache"
      cat "$cache"
      return 0
    fi
  fi

  if fetch_url "${STRATEGIES_API}/blobs" 2>/dev/null | \
      grep -oE '"name":[[:space:]]*"[^"]+\.bin"' | \
      sed 's/.*"\([^"]*\.bin\)".*/\1/' | sort -u > "$cache" && [ -s "$cache" ]; then
    cat "$cache"
    return 0
  fi

  printf '%s\n' \
    ACTIVE_DISCORD_UDP.bin ACTIVE_GAME_UDP.bin \
    discord-ip-discovery-without-port.bin \
    quic_initial.bin quic_initial_4pda_to.bin quic_initial_5ka_ru.bin \
    quic_initial_dbankcloud_ru.bin quic_initial_leagueoflegends.com.bin \
    quic_initial_lemana_pro.bin quic_initial_rr1kyber2.bin quic_initial_rutube_ru.bin \
    quic_initial_steam_chat_com.bin quic_initial_steamcommunity_com.bin \
    quic_initial_steamstatic_com.bin quic_initial_tencent_com.bin \
    quic_initial_vk_com.bin quic_initial_www_google_com.bin \
    quic_lordfilm.bin quic_my_youtube_initial.bin \
    stun.bin stun2.bin \
    tls_burgerkingrus_ru.bin tls_cf1.bin tls_clienthello.bin \
    tls_clienthello_4pda_to.bin tls_clienthello_5ka_ru.bin \
    tls_clienthello_awswaf_com.bin tls_clienthello_max_ru.bin \
    tls_clienthello_sochi_park.bin tls_clienthello_steam_chat_com.bin \
    tls_clienthello_steamstatic_com.bin tls_clienthello_teamspeak_com.bin \
    tls_clienthello_www_google_com.bin tls_clienthello_www_sferum_ru.bin \
    tls_lordfilm.bin tls_magnit.bin
}


menu_change_fake_blob() {
  need_nfqws_installed || return 0
  pick_nfqws_ver 0 || { warn "Отменено."; return 0; }

  local conf blobs_dir map_file list_file
  conf=$(nfqws_conf_path "$NFQWS_VER")
  blobs_dir=$(nfqws_blobs_dir "$NFQWS_VER")
  if [ ! -f "$conf" ]; then
    error "Конфиг $conf не найден."
    return 0
  fi

  map_file="/tmp/nfqws-fakeblob-map-$$"
  list_file="/tmp/nfqws-fakeblob-list-$$"

  echo
  info "Анализ конфига: $conf"
  if ! parse_fake_blobs "$conf" "$map_file" "$list_file"; then
    warn "В конфиге не найдено использований fake:blob=NAME: (кроме hex)."
    rm -f "$map_file" "$list_file"
    return 0
  fi

  echo
  printf '%s\n' "${BOLD}Сейчас в конфиге найдены следующие fake:blob:${NC}"
  local last_sec="" idx sec name base
  while IFS='|' read -r idx sec name base; do
    if [ "$sec" != "$last_sec" ]; then
      echo
      printf '%s\n' "${CYAN}${sec}${NC}"
      last_sec=$sec
    fi
    printf '  [%s] %s (%s)\n' "$idx" "$name" "$base"
  done < "$list_file"
  echo

  ask "Какой из найденных fake:blob требуется заменить? (номер / Enter = отмена): "
  read -r choice
  case "$choice" in
    ''|0|q|Q|н|Н) info "Отменено."; rm -f "$map_file" "$list_file"; return 0 ;;
  esac
  if ! echo "$choice" | grep -qE '^[0-9]+$'; then
    warn "Нужен номер."
    rm -f "$map_file" "$list_file"
    return 0
  fi

  local sel_line sel_name sel_base sel_sec
  sel_line=$(grep -E "^${choice}\|" "$list_file" | head -1)
  if [ -z "$sel_line" ]; then
    warn "Номер $choice не найден в списке."
    rm -f "$map_file" "$list_file"
    return 0
  fi
  sel_sec=$(echo "$sel_line" | cut -d'|' -f2)
  sel_name=$(echo "$sel_line" | cut -d'|' -f3)
  sel_base=$(echo "$sel_line" | cut -d'|' -f4)

  info "Выбрано: [$choice] $sel_name ($sel_base) в $sel_sec"

  echo
  printf '%s\n' "${BOLD}Доступные blob-файлы для замены (--blob=${sel_name}:...):${NC}"
  echo

  local i=1 b cand_file="/tmp/nfqws-blob-cands-$$"
  : > "$cand_file"

  if [ -d "$blobs_dir" ]; then
    for b in "$blobs_dir"/*.bin; do
      [ -f "$b" ] || continue
      printf '%s\n' "$(basename "$b")"
    done
  fi | sort -u > "/tmp/nfqws-local-blobs-$$"

  list_repo_blobs > "/tmp/nfqws-repo-blobs-$$"

  {
    cat "/tmp/nfqws-local-blobs-$$" 2>/dev/null
    cat "/tmp/nfqws-repo-blobs-$$" 2>/dev/null
  } | awk '!a[$0]++' > "$cand_file"

  i=1
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    if [ -f "${blobs_dir}/${b}" ]; then
      printf '  [%2d] %s  (локально)\n' "$i" "$b"
    else
      printf '  [%2d] %s  (из репозитория)\n' "$i" "$b"
    fi
    i=$((i + 1))
  done < "$cand_file"
  local max_cand=$((i - 1))

  if [ "$max_cand" -lt 1 ]; then
    warn "Нет доступных .bin файлов."
    rm -f "$map_file" "$list_file" "$cand_file" /tmp/nfqws-local-blobs-$$ /tmp/nfqws-repo-blobs-$$
    return 0
  fi
  echo
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r bchoice
  case "$bchoice" in
    ''|0|q|Q) info "Отменено."; rm -f "$map_file" "$list_file" "$cand_file" /tmp/nfqws-local-blobs-$$ /tmp/nfqws-repo-blobs-$$; return 0 ;;
  esac
  if ! echo "$bchoice" | grep -qE '^[0-9]+$' || [ "$bchoice" -lt 1 ] || [ "$bchoice" -gt "$max_cand" ]; then
    warn "Неверный номер."
    rm -f "$map_file" "$list_file" "$cand_file" /tmp/nfqws-local-blobs-$$ /tmp/nfqws-repo-blobs-$$
    return 0
  fi

  local new_bin new_path
  new_bin=$(sed -n "${bchoice}p" "$cand_file")
  new_path="${blobs_dir}/${new_bin}"

  if [ ! -f "$new_path" ]; then
    info "Скачивание $new_bin → $new_path ..."
    mkdir -p "$blobs_dir"
    if ! download_file "${RAW_BASE}/strategies/blobs/${new_bin}" "$new_path"; then
      error "Не удалось скачать $new_bin"
      rm -f "$map_file" "$list_file" "$cand_file" /tmp/nfqws-local-blobs-$$ /tmp/nfqws-repo-blobs-$$
      return 1
    fi
    info "Скачано."
  fi

  backup_file "$conf"

  local tmp="/tmp/nfqws-fakeblob-edit-$$.conf"
  if grep -qE -- "--blob=${sel_name}:" "$conf"; then
    sed -E "s|--blob=${sel_name}:[^[:space:]\"]*|--blob=${sel_name}:@${new_path}|g" "$conf" > "$tmp"
  else
    warn "В конфиге нет --blob=${sel_name}:... — добавляю в NFQWS_BASE_ARGS."
    local inserted=0
    : > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$inserted" -eq 0 ]; then
        case "$line" in
          NFQWS_BASE_ARGS=\"*)
            printf '%s\n' "$line" >> "$tmp"
            case "$line" in
              *\")
                # однострочный — добавим после через sed-подобную вставку на следующей итерации сложно;
                # вставим отдельную строку с дописыванием после открытия, если multi-line
                ;;
              *)
                printf '                 --blob=%s:@%s\n' "$sel_name" "$new_path" >> "$tmp"
                inserted=1
                ;;
            esac
            continue
            ;;
          NFQWS_BASE_ARGS=\")
            printf '%s\n' "$line" >> "$tmp"
            printf '                 --blob=%s:@%s\n' "$sel_name" "$new_path" >> "$tmp"
            inserted=1
            continue
            ;;
        esac
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$conf"
    if [ "$inserted" -eq 0 ]; then
      printf '\n# added by nfqws-menu\nNFQWS_BASE_ARGS="${NFQWS_BASE_ARGS} --blob=%s:@%s"\n' \
        "$sel_name" "$new_path" >> "$tmp"
    fi
  fi

  if [ ! -s "$tmp" ]; then
    error "Ошибка формирования нового конфига."
    rm -f "$tmp" "$map_file" "$list_file" "$cand_file" /tmp/nfqws-local-blobs-$$ /tmp/nfqws-repo-blobs-$$
    return 1
  fi

  mv "$tmp" "$conf"
  info "Готово: --blob=${sel_name}:@${new_path}"
  info "  (было: $sel_base → стало: $new_bin)"

  echo
  if confirm_yes "Перезапустить сервис nfqws${NFQWS_VER}?"; then
    service_restart "$(nfqws_init_path "$NFQWS_VER")"
    info "Сервис перезапущен."
  else
    info "Перезапуск пропущен — примените вручную."
  fi

  rm -f "$map_file" "$list_file" "$cand_file" /tmp/nfqws-local-blobs-$$ /tmp/nfqws-repo-blobs-$$
  return 0
}



# Принудительная остановка nfqws/nfqws2 перед remove/reinstall.
# init is_running() ломается на пустом pidfile (bad number / kill without pid),
# из-за чего процесс остаётся висеть после opkg remove.
_stop_nfqws_hard() {
  local ver="$1" init proc pidf
  case "$ver" in
    1) proc="nfqws";  pidf="/var/run/nfqws.pid" ;;
    2) proc="nfqws2"; pidf="/var/run/nfqws2.pid" ;;
    *) return 0 ;;
  esac
  init=$(nfqws_init_path "$ver")
  [ -x "$init" ] && "$init" stop 2>/dev/null || true
  killall "$proc" 2>/dev/null || true
  rm -f "$pidf"
}

stop_nfqws1_hard() { _stop_nfqws_hard 1; }
stop_nfqws2_hard() { _stop_nfqws_hard 2; }

# Удаление пакета nfqws* с предварительным kill
remove_nfqws_pkg() {
  local pkg="$1"
  case "$pkg" in
    nfqws2-keenetic)
      info "Остановка nfqws2 перед удалением..."
      stop_nfqws2_hard
      ;;
    nfqws-keenetic)
      info "Остановка nfqws перед удалением..."
      stop_nfqws1_hard
      ;;
  esac
  pkg_remove "$pkg"
  # хвосты после remove
  case "$pkg" in
    nfqws2-keenetic) stop_nfqws2_hard ;;
    nfqws-keenetic)  stop_nfqws1_hard ;;
  esac
}

menu_remove() {
  echo
  printf '%s\n' "${BOLD}Что удалить?${NC}"
  echo

  refresh_opkg_cache

  local items="" p i=1 target idx
  is_installed "nfqws-keenetic"     && items="$items nfqws-keenetic"
  is_installed "nfqws2-keenetic"    && items="$items nfqws2-keenetic"
  is_installed "nfqws-keenetic-web" && items="$items nfqws-keenetic-web"
  is_dpi_detector_installed         && items="$items dpi-detector"
  is_awg_openwrt_installed          && items="$items awg-openwrt"
  is_tg_ws_proxy_rs_installed       && items="$items tg-ws-proxy-rs"
  is_installed "magitrickle"        && items="$items magitrickle"
  is_telemt_installed               && items="$items luci-app-telemt"

  if [ -n "$items" ]; then
    for p in $items; do
      printf "  [%d] %s\n" "$i" "$p"
      i=$((i + 1))
    done
  else
    warn "Установленных пакетов не найдено."
  fi
  echo "  [a] Удалить все пакеты NFQWS"
  echo "  [b] Удалить резервные копии (.bak.* / *-opkg)"
  echo "  [0] ${LBL_BACK_ITEM}"
  echo
  ask "${LBL_YOUR_CHOICE} [0]: "
  read -r choice

  case "$choice" in
    0|"") return ;;
    b|B|б|Б) remove_backups ;;
    a|A|а|А)
      if confirm_no "Точно удалить все пакеты NFQWS (и dpi-detector, если есть)?"; then
        stop_nfqws2_hard
        stop_nfqws1_hard
        pkg_remove nfqws-keenetic-web nfqws2-keenetic nfqws-keenetic 2>/dev/null || true
        stop_nfqws2_hard
        stop_nfqws1_hard
        remove_dpi_detector
        info "Удаление завершено."
      fi
      ;;
    *)
      idx=1; target=""
      for p in $items; do
        [ "$idx" = "$choice" ] && { target="$p"; break; }
        idx=$((idx + 1))
      done
      [ -z "$target" ] && { warn "Неверный выбор"; return; }
      confirm_no "Удалить $target?" || return
      case "$target" in
        dpi-detector)  remove_dpi_detector ;;
        awg-openwrt|awg-manager) remove_awg_openwrt ;;
        tg-ws-proxy-rs) remove_tg_ws_proxy_rs ;;
        magitrickle)   remove_magitrickle ;;
        telemt|luci-app-telemt) remove_telemt ;;
        nfqws-keenetic|nfqws2-keenetic)
          remove_nfqws_pkg "$target" || true
          info "$target удалён."
          ;;
        *)
          pkg_remove "$target"
          info "$target удалён."
          ;;
      esac
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Сервисные утилиты (S / U)
# ---------------------------------------------------------------------------
opkg_upgrade_all() {
  echo
  info "$LBL_U"
  if [ "$(pkg_backend)" = "apk" ]; then
    info "apk update && apk upgrade ..."
    if ! pkg_update; then
      error "apk update не удался."
      return 1
    fi
    if ! apk upgrade; then
      error "apk upgrade не удался."
      return 1
    fi
  else
    info "opkg update ..."
    if ! opkg update; then
      error "opkg update не удался."
      return 1
    fi
    local pkgs
    pkgs=$(opkg list-upgradable 2>/dev/null | awk '{print $1}')
    if [ -n "$pkgs" ]; then
      info "Обновление доступных пакетов: $(printf '%s ' $pkgs)"
      if ! opkg upgrade $pkgs; then
        error "opkg upgrade не удался."
        return 1
      fi
    else
      info "Все пакеты opkg уже обновлены."
    fi
  fi
  refresh_opkg_cache
  info "Обновление пакетов завершено."

  # dpi-detector ставится не через opkg — обновляем отдельно, если уже установлен
  if [ -x "$(dpi_detector_bin)" ]; then
    info "Найден $(dpi_detector_bin) — обновление..."
    export DPI_INSTALL_DIR="/usr/bin"
    if run_remote_sh "${DPI_DETECTOR_INSTALL_URL:-https://raw.githubusercontent.com/Runnin4ik/dpi-detector/rust/install.sh}"; then
      if [ ! -x /usr/bin/dpi-detector ] && [ -x /tmp/dpi-detector ]; then
        cp -f /tmp/dpi-detector /usr/bin/dpi-detector 2>/dev/null && chmod +x /usr/bin/dpi-detector
      fi
      info "dpi-detector обновлён."
    else
      warn "Не удалось обновить dpi-detector."
    fi
  fi
}

# UPX не может переписать файл запущенного процесса (ETXTBSY) — сервисы
# останавливаются на время сжатия и запускаются обратно.
service_upx_compress() {
  echo
  info "$LBL_S1"
  local targets="" b init_upx stop_svc=0 runnable="" svc_init=""
  for b in /usr/bin/nfqws /usr/bin/nfqws2 /usr/bin/tg-ws-proxy-rs /usr/bin/dpi-detector /usr/bin/telemt /usr/bin/magitrickle /usr/sbin/magitrickle /usr/bin/awg; do
    if [ -f "$b" ] && [ ! -L "$b" ] && [ -x "$b" ]; then
      targets="$targets $b"
    fi
  done
  if [ -z "$targets" ]; then
    warn "Не найдено установленных бинарников для сжатия."
    return 0
  fi
  warn "UPX сожмёт установленные бинарники:${targets}"
  warn "Уже сжатые бинарники UPX пропускает; сбой на отдельном файле не критичен."
  if ! confirm_yes "Продолжить?"; then
    info "Отменено."
    return 0
  fi
  if ! command -v upx >/dev/null 2>&1; then
    info "Установка upx..."
    pkg_update 2>/dev/null || true
    if ! pkg_install upx; then
      error "Не удалось установить upx."
      return 1
    fi
  fi

  # Бинарники с init-скриптом останавливаем; dpi-detector / awg — не сервисы.
  refresh_proc_cache
  if confirm_no "Остановить запущенные сервисы на время сжатия?"; then
    stop_svc=1
  fi
  for b in $targets; do
    init_upx=""
    case "$b" in
      /usr/bin/nfqws)          init_upx=$(nfqws_init_path 1) ;;
      /usr/bin/nfqws2)         init_upx=$(nfqws_init_path 2) ;;
      /usr/bin/tg-ws-proxy-rs) init_upx="$TG_WS_PROXY_RS_INIT" ;;
      /usr/bin/telemt)         init_upx="/etc/init.d/telemt" ;;
      /usr/bin/magitrickle|/usr/sbin/magitrickle) init_upx="/etc/init.d/magitrickle" ;;
    esac
    if [ -n "$init_upx" ] && [ -x "$init_upx" ] && proc_running "${b##*/}"; then
      if [ "$stop_svc" -eq 1 ]; then
        "$init_upx" stop 2>/dev/null || true
        svc_init="$svc_init $init_upx"
        runnable="$runnable $b"
      else
        warn "  пропуск $b: сервис запущен — сжимайте после его остановки."
      fi
    else
      runnable="$runnable $b"
    fi
  done
  [ -n "$svc_init" ] && info "Сервисы остановлены на время сжатия."

  if [ -z "$runnable" ]; then
    warn "Сжимать нечего: все кандидаты — запущенные сервисы."
  else
    info "Сжатие (может занять несколько минут)..."
    for b in $runnable; do
      info "UPX: $b"
      upx --lzma --best "$b" || warn "UPX не сжал $b (не критично)."
    done
  fi

  if [ -n "$svc_init" ]; then
    info "Запуск остановленных сервисов..."
    for init_upx in $svc_init; do
      service_restart "$init_upx"
    done
  fi
  info "Готово."
}

# ---------------------------------------------------------------------------
# Зеркала репозиториев OpenWrt (opkg / apk)
# ---------------------------------------------------------------------------
mirror_get_repo_files() {
  local f files=""
  if [ "$(pkg_backend)" = "apk" ]; then
    [ -f /etc/apk/repositories ] && files="/etc/apk/repositories"
    if [ -d "$APK_REPO_DIR" ]; then
      for f in "$APK_REPO_DIR"/*.list; do
        [ -f "$f" ] && files="${files:+${files} }$f"
      done
    fi
  else
    [ -f "$OPKG_CONF_DIR/distfeeds.conf" ] && files="$OPKG_CONF_DIR/distfeeds.conf"
    [ -f "$OPKG_CONF_DIR/customfeeds.conf" ] && files="${files:+${files} }$OPKG_CONF_DIR/customfeeds.conf"
    [ -f "$OPKG_CONF_DIR/opkg.conf" ] && files="${files:+${files} }$OPKG_CONF_DIR/opkg.conf"
    if [ -d "$OPKG_CONF_DIR" ]; then
      for f in "$OPKG_CONF_DIR"/*.conf; do
        [ -f "$f" ] || continue
        case "$f" in
          */distfeeds.conf|*/customfeeds.conf|*/opkg.conf) ;;
          *) files="${files:+${files} }$f" ;;
        esac
      done
    fi
  fi
  echo "$files"
}

mirror_get_current() {
  local f cur=""
  for f in $(mirror_get_repo_files); do
    [ -f "$f" ] || continue
    cur=$(awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^https?:\/\//) {
            u = $i
            idx = index(u, "/releases")
            if (idx == 0) idx = index(u, "/snapshots")
            if (idx > 0) {
              print substr(u, 1, idx - 1)
              exit
            }
          }
        }
      }
    ' "$f" 2>/dev/null)
    if [ -n "$cur" ]; then
      echo "$cur"
      return 0
    fi
  done
  echo "https://downloads.openwrt.org"
}

mirror_apply() {
  local new="$1" cur files f count=0 yr
  [ -n "$new" ] || return 1
  new="${new%/}"
  case "$new" in
    http://*|https://*) ;;
    *)
      error "Некорректный URL зеркала (требуется префикс http:// или https://): $new"
      return 1
      ;;
  esac

  cur=$(mirror_get_current)
  if [ "$cur" = "$new" ]; then
    info "Выбранное зеркало уже установлено: $cur"
    if confirm_yes "Проверить доступность репозиториев (pkg_update)?"; then
      pkg_update || warn "Ошибка при обновлении списка пакетов."
    fi
    return 0
  fi

  files=$(mirror_get_repo_files)
  if [ -z "$files" ]; then
    error "Конфигурационные файлы репозиториев не найдены."
    return 1
  fi

  yr=$(date +%Y 2>/dev/null || echo 1970)
  if [ "$yr" -lt 2024 ] && [ "${new#https://}" != "$new" ]; then
    warn "Внимание: системные часы роутера ($(date)) могут быть не синхронизированы!"
    warn "HTTPS-запросы могут завершаться ошибкой проверки SSL-сертификатов (NTP)."
  fi

  info "Переключение зеркала репозиториев OpenWrt:"
  info "  Текущее: $cur"
  info "  Новое:   $new"

  for f in $files; do
    [ -f "$f" ] || continue
    if grep -qF "$cur" "$f" 2>/dev/null; then
      [ -f "${f}.orig" ] || cp -p "$f" "${f}.orig"
      cp -p "$f" "${f}.bak"
      sed -i "s|${cur}|${new}|g" "$f"
      count=$((count + 1))
      info "  Обновлён файл: $f"
    fi
  done

  if [ "$count" -eq 0 ]; then
    warn "Ни в одном файле репозиториев не обнаружено вхождений '$cur'."
    return 1
  fi

  info "Файлы обновлены ($count). Проверяем доступность репозиториев (pkg_update)..."
  if pkg_update; then
    info "Успешно! Репозитории доступны через зеркало: $new"
    refresh_opkg_cache
  else
    error "Не удалось обновить список пакетов через зеркало: $new"
    if confirm_yes "Откатить изменения назад на $cur?"; then
      for f in $files; do
        if [ -f "${f}.bak" ]; then
          mv -f "${f}.bak" "$f"
        fi
      done
      pkg_update >/dev/null 2>&1 || true
      info "Изменения откатаны."
    else
      warn "Изменения сохранены. При необходимости выберите другое зеркало или восстановите оригинал."
    fi
  fi
}

mirror_toggle_ssl() {
  local cur new
  cur=$(mirror_get_current)
  case "$cur" in
    https://*)
      new="http://${cur#https://}"
      info "Переключение с HTTPS на HTTP: $new"
      ;;
    http://*)
      new="https://${cur#http://}"
      info "Переключение с HTTP на HTTPS: $new"
      ;;
    *)
      error "Не удалось определить протокол для $cur"
      return 1
      ;;
  esac
  mirror_apply "$new"
}

mirror_restore_original() {
  local f files restored=0
  files=$(mirror_get_repo_files)
  for f in $files; do
    if [ -f "${f}.orig" ]; then
      cp -f "${f}.orig" "$f"
      restored=$((restored + 1))
      info "  Восстановлен: $f (из ${f}.orig)"
    fi
  done
  if [ "$restored" -gt 0 ]; then
    info "Оригинальные конфигурационные файлы восстановлены ($restored)."
    pkg_update || warn "pkg_update завершился с предупреждением."
    refresh_opkg_cache
  else
    info "Резервные копии .orig не найдены. Устанавливаем официальный upstream: https://downloads.openwrt.org"
    mirror_apply "https://downloads.openwrt.org"
  fi
}

service_mirror_menu() {
  local cur mchoice custom_url
  while true; do
    cur=$(mirror_get_current)
    echo
    printf '%s\n' "${BOLD}${CYAN}[::]  ${LBL_S2}${NC}"
    echo "      Текущий источник: ${YELLOW}${cur}${NC}"
    echo
    echo "      1. Официальный (downloads.openwrt.org)"
    echo "      2. Alibaba Cloud (mirrors.aliyun.com/openwrt — быстрый CDN в РФ)"
    echo "      3. Tsinghua TUNA (mirrors.tuna.tsinghua.edu.cn/openwrt)"
    echo "      4. USTC (mirrors.ustc.edu.cn/openwrt)"
    echo "      5. Accum.se (mirror.accum.se/mirror/openwrt.org — Швеция/EU)"
    echo "      6. Ввести свой URL зеркала вручную"
    echo "      7. Проверить доступность репозиториев (pkg_update)"
    echo "      8. Переключить протокол (HTTPS ↔ HTTP)"
    echo "      9. Восстановить оригинальные настройки (.orig)"
    echo "      0. ${LBL_BACK_ITEM}"
    echo
    ask "${LBL_YOUR_CHOICE} [0]: "
    read -r mchoice
    case "$mchoice" in
      1) mirror_apply "https://downloads.openwrt.org" ;;
      2) mirror_apply "https://mirrors.aliyun.com/openwrt" ;;
      3) mirror_apply "https://mirrors.tuna.tsinghua.edu.cn/openwrt" ;;
      4) mirror_apply "https://mirrors.ustc.edu.cn/openwrt" ;;
      5) mirror_apply "https://mirror.accum.se/mirror/openwrt.org" ;;
      6)
        echo
        ask "Введите базовый URL зеркала (например: https://mirrors.aliyun.com/openwrt): "
        read -r custom_url
        if [ -n "$custom_url" ]; then
          mirror_apply "$custom_url"
        else
          warn "URL не указан."
        fi
        ;;
      7)
        echo
        info "Проверка доступности репозиториев через $cur..."
        if pkg_update; then
          info "Репозитории успешно обновлены!"
        else
          error "Ошибка при обновлении репозиториев."
        fi
        ;;
      8) mirror_toggle_ssl ;;
      9) mirror_restore_original ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор." ;;
    esac
  done
}

# Починить базу OPKG status: NUL-байты и склеенные записи (из-за аварийного отключения питания) -> segfault opkg
_opkg_repair_status() {
  local st="${1:-}" bak tmp fixed n0 n1 nuls candidate
  if [ -z "$st" ]; then
    for candidate in /usr/lib/opkg/status /var/lib/opkg/status /opt/lib/opkg/status; do
      if [ -f "$candidate" ]; then
        st="$candidate"
        break
      fi
    done
  fi
  [ -n "$st" ] && [ -f "$st" ] || {
    return 0
  }

  nuls=$(tr -cd '\000' < "$st" 2>/dev/null | wc -c | tr -d ' \n')
  case "$nuls" in ''|*[!0-9]*) nuls=0 ;; esac
  if [ "$nuls" -eq 0 ]; then
    return 0
  fi

  warn "Повреждён $st ($nuls NUL-байт) — восстанавливаю..."
  bak="${st}.bak.corrupt.$(date +%Y%m%d%H%M%S)"
  cp -a "$st" "$bak" 2>/dev/null || true
  info "  Бэкап: $bak"
  tmp="/tmp/opkg-status-$$.nonul"
  fixed="/tmp/opkg-status-$$.fixed"
  tr -d '\000' < "$st" > "$tmp" 2>/dev/null || cp "$st" "$tmp"
  awk 'BEGIN{RS="";ORS="\n\n"} /^Package: / && /Status: / {print}' "$tmp" > "$fixed"
  n0=$(grep -c '^Package:' "$st" 2>/dev/null)
  n1=$(grep -c '^Package:' "$fixed" 2>/dev/null)
  case "$n0" in ''|*[!0-9]*) n0=0 ;; esac
  case "$n1" in ''|*[!0-9]*) n1=0 ;; esac
  if [ ! -s "$fixed" ]; then
    error "  Не удалось восстановить базу $st"
    rm -f "$tmp" "$fixed"
    return 1
  fi
  cp "$fixed" "$st"
  info "  База opkg восстановлена: записей ~$n0 -> $n1 (NUL-байты удалены)."
  rm -f "$tmp" "$fixed"
  return 0
}

service_opkg_repair() {
  echo
  info "$LBL_S3"
  local st="" candidate
  for candidate in /usr/lib/opkg/status /var/lib/opkg/status /opt/lib/opkg/status; do
    if [ -f "$candidate" ]; then
      st="$candidate"
      break
    fi
  done
  if [ -z "$st" ]; then
    error "Файл базы opkg status не найден."
    pause_press_enter
    return 1
  fi

  info "Проверка базы: $st"
  if _opkg_repair_status; then
    info "База проверена."
  fi
  info "Проверка целостности вызовом opkg list-installed..."
  if opkg list-installed >/dev/null 2>&1; then
    info "OPKG работает штатно."
  else
    warn "opkg всё ещё сообщает об ошибке."
  fi
  pause_press_enter
}

menu_service() {
  while true; do
    echo
    printf '%s\n' "${BOLD}${CYAN}[::]  ${LBL_REMOVE} (S)${NC}"
    echo "      1. $LBL_S1"
    echo "      2. $LBL_S2"
    echo "      3. $LBL_S3"
    echo "      U. $LBL_U"
    echo "      0. ${LBL_BACK_ITEM}"
    echo
    ask "${LBL_YOUR_CHOICE} [0]: "
    read -r schoice
    case "$schoice" in
      1) service_upx_compress || true ;;
      2) service_mirror_menu || true ;;
      3) service_opkg_repair || true ;;
      U|u) opkg_upgrade_all || true ;;
      0|"") return 0 ;;
      *) warn "Неверный выбор." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Проверка новых версий: в фоне, чтобы меню открывалось сразу
# ---------------------------------------------------------------------------
# Меню не ждёт сеть: версии с сервера тянет отдельный процесс, он кладёт их в
# кэш и будит меню сигналом USR1, по которому цикл перерисовывает экран. Метки
# появляются сами через секунду-другую после открытия, а сам экран рисуется
# мгновенно — в том числе когда GitHub недоступен.
#
# В кэше лежат только версии с сервера, без сравнения: сравнение с
# установленными делается при отрисовке, поэтому после обновления метка
# исчезает сразу и перепроверка для этого не нужна.
UPD_CACHE="${CACHE_DIR}/updates.cache"

# Версия скрипта меню: первые 2 КБ файла через зеркала — 200 КБ тянуть незачем.
upd_menu_version() {
  local url alt tmp ver
  url="${RAW_BASE}/nfqws-menu.sh"
  tmp="/tmp/nfqws-menu-upd-$$"
  if command -v curl >/dev/null 2>&1; then
    for alt in $(github_alt_urls "$url"); do
      curl -fsS -m 8 -r 0-2047 "$alt" -o "$tmp" 2>/dev/null || continue
      ver=$(extract_script_version "$tmp") || ver=""
      if [ -n "$ver" ]; then
        rm -f "$tmp"
        printf '%s' "$ver"
        return 0
      fi
    done
  else
    # Fallback если curl не установлен: читаем заголовки скрипта через HTTP-стек меню
    for alt in $(github_alt_urls "$url"); do
      ver=$(_http_get_stdout "$alt" 2>/dev/null | head -n 30 | extract_script_version -) || ver=""
      if [ -n "$ver" ]; then
        rm -f "$tmp"
        printf '%s' "$ver"
        return 0
      fi
    done
  fi
  rm -f "$tmp"
  return 1
}

# Тег последнего стабильного релиза из редиректа releases/latest (без pre-release).
upd_release_tag() {   # $1 = owner/repo
  local url alt loc
  command -v curl >/dev/null 2>&1 || return 1
  url="https://github.com/$1/releases/latest"
  for alt in $(github_alt_urls "$url"); do
    loc=$(curl -sS -m 8 -o /dev/null -w '%{redirect_url}' "$alt" 2>/dev/null) || continue
    case "$loc" in
      */releases/tag/*)
        printf '%s' "${loc##*/releases/tag/}" | sed 's/^v//'
        return 0
        ;;
    esac
  done
  return 1
}

# Новейший релиз включая pre-release (API releases?per_page=1).
# Нужен для dpi-detector: все теги — prerelease, /releases/latest пустой.
upd_release_tag_any() {   # $1 = owner/repo
  local repo="$1" url json tag
  command -v curl >/dev/null 2>&1 || return 1
  for url in \
    "https://api.github.com/repos/${repo}/releases?per_page=1" \
    "https://ghproxy.net/https://api.github.com/repos/${repo}/releases?per_page=1"
  do
    json=$(curl -fsS -m 10 -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null) || continue
    tag=$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$tag" ] || continue
    printf '%s' "$tag" | sed 's/^v//'
    return 0
  done
  return 1
}

# Версии с сервера в кэш (работает в фоне). Проверяются только установленные
# пакеты: у остальных сравнивать не с чем.
upd_check_bg() {
  local tmp="${UPD_CACHE}.tmp.$$" ver pair
  mkdir -p "$CACHE_DIR" 2>/dev/null || true
  : > "$tmp" || return 1
  ver=$(upd_menu_version 2>/dev/null) || ver=""
  [ -n "$ver" ] && printf 'menu %s\n' "$ver" >> "$tmp"
  for pair in \
    nfqws-keenetic:nfqws/nfqws-keenetic \
    nfqws2-keenetic:nfqws/nfqws2-keenetic \
    nfqws-keenetic-web:nfqws/nfqws-keenetic-web
  do
    is_installed "${pair%%:*}" || continue
    ver=$(fetch_pkg_version_file "${pair#*:}" 2>/dev/null) || ver=""
    [ -n "$ver" ] && printf '%s %s\n' "${pair%%:*}" "$ver" >> "$tmp"
  done
  if is_tg_ws_proxy_rs_installed; then
    ver=$(upd_release_tag "valnesfjord/tg-ws-proxy-rs" 2>/dev/null) || ver=""
    [ -n "$ver" ] && printf 'tg-ws-proxy-rs %s\n' "$ver" >> "$tmp"
  fi
  if is_dpi_detector_installed; then
    # все релизы dpi-detector — pre-release; /releases/latest их не видит
    ver=$(upd_release_tag_any "Runnin4ik/dpi-detector" 2>/dev/null) || ver=""
    [ -n "$ver" ] && printf 'dpi-detector %s\n' "$ver" >> "$tmp"
  fi
  # Время проверки пишется всегда: иначе неудачный прогон повторялся бы на
  # каждом входе в меню.
  printf 'checked %s\n' "$(date +%s)" >> "$tmp"
  mv "$tmp" "$UPD_CACHE" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # USR1 только если есть реальные метки — иначе лишний clear меню
  if ! upd_has_pending; then
    return 0
  fi
  if [ -r "/proc/${MENU_PID}/cmdline" ] &&
     tr -d '\0' < "/proc/${MENU_PID}/cmdline" 2>/dev/null | grep -q 'nfqws-menu'
  then
    kill -USR1 "$MENU_PID" 2>/dev/null || true
  fi
  return 0
}

# Кэш моложе TTL — сеть не нужна.
upd_cache_fresh() {
  local checked now
  [ -f "$UPD_CACHE" ] || return 1
  checked=$(sed -n 's/^checked //p' "$UPD_CACHE" 2>/dev/null | head -1)
  case "$checked" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  [ $((now - checked)) -lt "$UPD_TTL" ]
}

# PID-файл + завершение чужих/осиротевших экземпляров меню.
# После обрыва SSH старый процесс часто крутит read -t вхолостую (100% CPU).
MENU_PIDFILE="/tmp/nfqws-menu.pid"

_menu_is_menu_pid() {
  local p="$1" c
  [ -n "$p" ] && [ -r "/proc/$p/cmdline" ] || return 1
  c=$(tr -d '\0' < "/proc/$p/cmdline" 2>/dev/null)
  # без широкого */nfqws-menu*: под него попадали tail/vim/less на файлах меню
  case "$c" in
    *nfqws-menu.sh*|*'/bin/menu'*|*'/usr/bin/menu'*|*'/opt/bin/menu'*) return 0 ;;
  esac
  return 1
}

_menu_kill_pid() {
  local p="$1"
  [ -n "$p" ] && [ "$p" != "$$" ] || return 0
  kill -TERM "$p" 2>/dev/null || true
  sleep 1
  kill -KILL "$p" 2>/dev/null || true
}

# Убить другие копии меню (в т.ч. после обрыва сессии).
ensure_single_instance() {
  local old p
  old=$(cat "$MENU_PIDFILE" 2>/dev/null | tr -d ' \t\r\n')
  if [ -n "$old" ] && [ "$old" != "$$" ] && [ "$old" != "$PPID" ] && kill -0 "$old" 2>/dev/null; then
    if _menu_is_menu_pid "$old"; then
      warn "Предыдущее меню (PID $old) — завершаем..."
      _menu_kill_pid "$old"
    fi
  fi
  # Доп. проход: любые nfqws-menu кроме нас (и нашего родителя)
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    p=${p#/proc/}
    [ "$p" = "$$" ] && continue
    [ "$p" = "$PPID" ] && continue
    _menu_is_menu_pid "$p" || continue
    warn "Лишний процесс меню (PID $p) — завершаем..."
    _menu_kill_pid "$p"
    rm -f /tmp/*."$p" /tmp/*-"$p" /tmp/*."$p".* /tmp/*-"$p".* 2>/dev/null || true
  done
  mkdir -p "$(dirname "$MENU_PIDFILE")" 2>/dev/null || true
  printf '%s\n' "$$" > "$MENU_PIDFILE"
  return 0
}

upd_cleanup() {
  [ -n "${UPD_JOB:-}" ] && kill "$UPD_JOB" 2>/dev/null
  rm -f "${UPD_CACHE}.tmp.$$" 2>/dev/null
  rm -f "${MENU_PIDFILE:-/tmp/nfqws-menu.pid}" 2>/dev/null
  rm -f /tmp/*."$$" /tmp/*-"$$" /tmp/*."$$".* /tmp/*-"$$".* 2>/dev/null || true
  return 0
}

# Один раз при входе в меню: подписка на сигнал и, если кэш устарел, фоновый
# процесс. Кэш свежий — метки рисуются сразу, без единого запроса.
upd_start() {
  MENU_PID=$$
  trap 'UPD_REDRAW=1' USR1
  trap 'upd_cleanup' EXIT
  # обрыв SSH / kill / Ctrl+C — сразу выходим, не оставляем зомби с 100% CPU
  trap 'upd_cleanup; exit 129' HUP
  trap 'upd_cleanup; exit 130' INT
  trap 'upd_cleanup; exit 143' TERM
  # NFQWS_MENU_UPDATE_BG=0 — без фоновой проверки (без второго кадра)
  case "${NFQWS_MENU_UPDATE_BG:-1}" in
    0|false|FALSE|no|NO) return 0 ;;
  esac
  upd_cache_fresh && return 0
  ( upd_check_bg ) </dev/null >/dev/null 2>&1 &
  UPD_JOB=$!
  return 0
}

# Версия с сервера для ключа (пусто — данных нет).
upd_remote() {
  [ -f "$UPD_CACHE" ] || return 0
  sed -n "s/^$1 //p" "$UPD_CACHE" 2>/dev/null | head -1
}

# Установленная версия для ключа.
upd_local() {
  local _v
  case "$1" in
    menu)           printf '%s' "$SCRIPT_VERSION" ;;
    tg-ws-proxy-rs) tg_ws_proxy_rs_version 2>/dev/null ;;
    dpi-detector)   dpi_detector_version 2>/dev/null ;;
    awg-openwrt|awg-manager)
      _v=$(pkg_version "kmod-amneziawg" 2>/dev/null)
      [ -z "$_v" ] && _v=$(pkg_version "amneziawg-tools" 2>/dev/null)
      printf '%s' "$_v"
      ;;
    *)              pkg_version "$1" 2>/dev/null ;;
  esac
  return 0
}

# Сравнение версий a > b (semver-подобно: 1.2.10 > 1.2.9). 0 = да.
# Ревизионный суффикс (-1, -rN) отсекается у обеих сторон — согласовано с
# awk-версией ver_gt в show_installed (иначе X.Y.Z-1 считалась новее X.Y.Z).
ver_gt() {
  local a="$1" b="$2" ia ib n=1
  case "$a" in *-*) a="${a%%-*}" ;; esac
  case "$b" in *-*) b="${b%%-*}" ;; esac
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 1
  while [ $n -le 8 ]; do
    ia="${a%%.*}"; ib="${b%%.*}"
    case "$ia" in ''|*[!0-9]*) ia=0 ;; esac
    case "$ib" in ''|*[!0-9]*) ib=0 ;; esac
    [ "$ia" -gt "$ib" ] 2>/dev/null && return 0
    [ "$ia" -lt "$ib" ] 2>/dev/null && return 1
    [ "$a" = "$ia" ] && a=0 || a="${a#*.}"
    [ "$b" = "$ib" ] && b=0 || b="${b#*.}"
    [ "$a" = "0" ] && [ "$b" = "0" ] && [ $n -gt 1 ] && return 1
    n=$((n + 1))
  done
  return 1
}

# Есть ли хоть одна метка обновления по текущему кэшу.
upd_has_pending() {
  local key rest
  [ -f "$UPD_CACHE" ] || return 1
  while read -r key rest; do
    case "$key" in ''|checked) continue ;; esac
    [ -n "$(upd_mark "$key")" ] && return 0
  done < "$UPD_CACHE"
  return 1
}

# Метка: только если на сервере НОВЕЕ, чем установлено. « ⭡1.2.7».
upd_mark() {
  local remote installed
  remote=$(upd_remote "$1")
  [ -n "$remote" ] || return 0
  installed=$(upd_local "$1")
  [ -n "$installed" ] || return 0
  [ "$remote" = "$installed" ] && return 0
  ver_gt "$remote" "$installed" || return 0
  # стрелка + версия на сервере зелёным
  printf '%s%s%s%s' "$UPD_MARK" "$GREEN" "$remote" "$NC"
  return 0
}

# Подпись к меткам — печатается, только если хоть одна метка есть.
upd_legend() {
  upd_has_pending && printf '  %s%s%s\n' "$DIM" "$LBL_UPD_LEGEND" "$NC"
  return 0
}

# Чтение выбора с оглядкой на фоновую проверку. READ_RC: 0 — ввод получен,
# 1 — перерисовать (пришла проверка), 2 — stdin закрыт (меню завершается).
# На BusyBox/ash USR1 часто НЕ прерывает блокирующий read — поэтому на TTY
# крутим read -t 1 и сами смотрим UPD_REDRAW (перерисовка без Enter).
read_choice() {
  local _var="$1"
  READ_RC=0
  if [ -t 0 ]; then
    while true; do
      if [ "$UPD_REDRAW" = 1 ]; then
        UPD_REDRAW=0
        READ_RC=1
        return 1
      fi
      # сессия умерла (SSH drop) — не крутить CPU
      if [ ! -t 0 ]; then
        READ_RC=2
        return 1
      fi
      # timeout 1 с: 0 = строка введена; иначе таймаут/сигнал → снова цикл
      if read -r -t 1 "$_var" 2>/dev/null; then
        return 0
      fi
      if [ ! -t 0 ]; then
        READ_RC=2
        return 1
      fi
      if [ "$UPD_REDRAW" = 1 ]; then
        UPD_REDRAW=0
        READ_RC=1
        return 1
      fi
    done
  fi
  # не TTY (pipe/скрипт): обычный блокирующий read
  if read_menu "$_var"; then
    return 0
  fi
  if [ "$UPD_REDRAW" = 1 ]; then
    UPD_REDRAW=0
    READ_RC=1
    return 1
  fi
  READ_RC=2
  return 1
}

# ---------------------------------------------------------------------------
# Главное меню
# ---------------------------------------------------------------------------
main_menu() {
  ensure_single_instance
  upd_start
  local os_tag="OpenWrt"
  [ "$ROUTER_OS" = "generic" ] && os_tag="Linux"
  while true; do
    clear 2>/dev/null || true
    echo
    printf '%s\n' "${CYAN}========================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}    NFQWS-MENU ($os_tag)  v${SCRIPT_VERSION}$(upd_mark menu)${NC}"
    printf '%s\n' "${CYAN}========================================${NC}"
    detect_arch
    show_installed
    upd_legend
    printf '%s\n' "${CYAN}${BOLD}[::]  ${LBL_COMPONENTS}${NC}"
    echo "      1.  $LBL_1"
    echo
    printf '%s\n' "${CYAN}${BOLD}[::]  ${LBL_STRATEGIES}${NC}"
    echo "      2.  $LBL_3"
    echo "      3.  $LBL_4"
    echo "      4.  $LBL_5"
    echo "      5.  $LBL_6"
    echo "      6.  $LBL_7"
    echo "      7.  $LBL_8"
    echo "      8.  $LBL_9"
    echo
    printf '%s\n' "${CYAN}${BOLD}[::]  ${LBL_UTILS}${NC}"
    echo "      10. dpi-detector"
    echo "      11. awg-openwrt (AmneziaWG)"
    echo "      12. MagiTrickle"
    echo "      13. luci-app-telemt (MTProxy)"
    echo "      14. TG WS Proxy Rust"
    echo
    printf '%s\n' "${CYAN}${BOLD}[::]  ${LBL_REMOVE} [${GREEN}S${CYAN}${BOLD}]  |  ${LBL_LANG} [${GREEN}77${CYAN}${BOLD}]${NC}"
    echo "      88. $LBL_88"
    echo "      99. $LBL_99"
    echo "      00. $LBL_00"
    echo
    ask "$LBL_PROMPT"
    if read_choice choice; then
      :   # обычный путь: выбор разбирается ниже
    elif [ "$READ_RC" = 1 ]; then
      continue    # пришла фоновая проверка версий — перерисуем с метками
    else
      exit 1      # stdin закрыт: как и раньше, выходим из меню
    fi

    # || true — при set -e любой return 1 из пункта не должен завершать скрипт
    case "$choice" in
      1)  menu_install_nfqws || true ;;
      2)  menu_strategy || true ;;
      3)  update_ipset_list || true ;;
      4)  update_rkn_list || true ;;
      5)  menu_dot_doh || true ;;
      6)  menu_change_fake_blob || true ;;
      7)  menu_update_hosts || true ;;
      8)  menu_dns_manage || true ;;
      10) menu_dpi_detector || true ;;
      11) menu_awg_openwrt || true ;;
      12) menu_magitrickle || true ;;
      # 15/16 — алиасы старой нумерации (совместимость)
      13|15) menu_telemt || true ;;
      14|16) menu_tg_ws_proxy_rs || true ;;
      S|s) menu_service || true ;;
      U|u) opkg_upgrade_all || true ;;
      77) menu_change_language; continue ;;
      88) menu_remove || true ;;
      99) update_self || true ;;
      00|0|"")
        info "$LBL_00."
        exit 0
        ;;
      *) warn "${LBL_INVALID:-Invalid menu option}" ;;
    esac

    # После внешних установщиков stdin часто «грязный» — чистим перед паузой
    drain_stdin
    echo
    ask "$LBL_BACK"
    if read_choice _; then
      :
    elif [ "$READ_RC" = 1 ]; then
      continue
    else
      exit 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------
case "$0" in
  /*) SCRIPT_PATH="$0" ;;
  *)  SCRIPT_PATH="$(pwd)/$0" ;;
esac
if [ ! -f "$SCRIPT_PATH" ]; then
  for a in "$0" "$@"; do
    case "$a" in
      *.sh)
        if [ -f "$a" ]; then
          case "$a" in /*) SCRIPT_PATH="$a" ;; *) SCRIPT_PATH="$(pwd)/$a" ;; esac
          break
        fi
        ;;
    esac
  done
fi
export SCRIPT_PATH

ensure_menu_symlink() {
  local target link="/usr/bin/menu" cur
  target=$(menu_script_target)
  [ -d /usr/bin ] || link="/bin/menu"
  [ -f "$target" ] || return 0
  # curl -o сбрасывает +x — всегда восстанавливаем, иначе menu → Permission denied
  chmod +x "$target" 2>/dev/null || true
  mkdir -p "$(dirname "$link")" 2>/dev/null || return 0
  if [ -L "$link" ]; then
    cur=$(readlink "$link" 2>/dev/null || true)
    [ "$cur" = "$target" ] && return 0
  fi
  [ -e "$link" ] && [ ! -L "$link" ] && return 0
  ln -sf "$target" "$link" 2>/dev/null || true
}

ensure_menu_symlink

# Не запускаем интерактивное меню, если скрипт подключён через source/.
if (return 0 2>/dev/null); then
  return 0
fi

if ! command -v opkg >/dev/null 2>&1 && ! command -v apk >/dev/null 2>&1; then
  error "Пакетный менеджер (opkg/apk) не найден."
  exit 1
fi

main_menu
