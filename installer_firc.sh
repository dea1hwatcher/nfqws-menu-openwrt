#!/bin/sh
# installer_firc.sh — меню firc для Entware (Keenetic / Netcraze)
# Пакет: https://github.com/hoaxisr/firc
# Репозиторий opkg: http://repo.hoaxisr.ru/
# Обёртка: https://github.com/rndnaame/nfqws-menu
#
# 1) Установка firc (src/gz hoaxisr → opkg install firc)
# 2) Удаление firc
# 3) Диагностика
#
# Запуск:
#   sh installer_firc.sh
#   curl -fsSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_firc.sh | sh

# ANSI (portable для ash/BusyBox)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[0;36m')
BLUE=$(printf '\033[0;34m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

info()  { printf '%s\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
error() { printf '%s\n' "${RED}[!]${NC} $*"; }

PKG_NAME="firc"
REPO_BASE="http://repo.hoaxisr.ru"
REPO_BASE_HTTPS="https://repo.hoaxisr.ru"
# как на https://repo.hoaxisr.ru/ — общий фид (firc, awg-manager, …)
OPKG_CONF="/opt/etc/opkg/awg_manager.conf"
OPKG_FEED_NAME="hoaxisr"
INIT_SCRIPT="/opt/etc/init.d/S99firc"
CONF_DIR="/opt/etc/firc"
FIRCD="/opt/bin/fircd"
RUNDIR="/tmp/firc"
LOCKFILE="/tmp/firc/fircd.lock"
SOCK="/tmp/firc/firc.sock"
GITHUB_REPO="hoaxisr/firc"

# ---------------------------------------------------------------------------
# Архитектура
# ---------------------------------------------------------------------------
ARCH=""
ARCH_RAW=""
ARCH_SOURCE=""

_arch_normalize() {
  case "$1" in
    aarch64*|arm64*)             echo "aarch64" ;;
    armv7*|armv6*|arm*)          echo "" ;;
    mipsel*|mipselsf*|mips64el*) echo "mipsel" ;;
    mips*|mipssf*)               echo "mips" ;;
    x86_64*|amd64*|x64*)         echo "x86_64" ;;
    i[3-6]86*|x86*|i686*)        echo "x86" ;;
    *)                           echo "" ;;
  esac
}

_arch_pick_best() {
  awk '
    $1 == "arch" && $2 != "" && $2 != "all" {
      p = $3 + 0
      n = $2
      bonus = 0
      if (n ~ /^mipsel/ || n ~ /^mipselsf/ || n ~ /^mips64el/) bonus = 2
      else if (n ~ /^aarch64/ || n ~ /^arm64/) bonus = 2
      score = p * 10 + bonus
      if (score > best) { best = score; name = n }
    }
    END { if (name != "") print name }
  '
}

_arch_from_opkg() {
  opkg print-architecture 2>/dev/null | _arch_pick_best
}

_arch_from_opkg_conf() {
  conf="${1:-/opt/etc/opkg.conf}"
  [ -f "$conf" ] || return 0
  name=$(grep -E '^[[:space:]]*arch[[:space:]]+' "$conf" 2>/dev/null | _arch_pick_best)
  [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      src/gz*|src\ *)
        case "$line" in
          *mipselsf*|*mips64el*) printf '%s\n' "mipselsf"; return 0 ;;
          *mipssf*)              printf '%s\n' "mipssf"; return 0 ;;
          *aarch64*|*arm64*)     printf '%s\n' "aarch64"; return 0 ;;
        esac
        ;;
    esac
  done < "$conf"
}

detect_arch() {
  ARCH=""
  ARCH_RAW=""
  ARCH_SOURCE=""

  ARCH_RAW=$(_arch_from_opkg)
  ARCH=$(_arch_normalize "$ARCH_RAW")
  [ -n "$ARCH" ] && ARCH_SOURCE="opkg"

  if [ -z "$ARCH" ]; then
    ARCH_RAW=$(_arch_from_opkg_conf /opt/etc/opkg.conf)
    ARCH=$(_arch_normalize "$ARCH_RAW")
    [ -n "$ARCH" ] && ARCH_SOURCE="conf"
  fi

  if [ -z "$ARCH" ]; then
    um=$(uname -m 2>/dev/null)
    case "$um" in
      mips|mipsel|mips64|mips64el|"") ;;
      *)
        cand=$(_arch_normalize "$um")
        if [ -n "$cand" ]; then
          ARCH="$cand"
          ARCH_RAW="$um"
          ARCH_SOURCE="uname"
        fi
        ;;
    esac
  fi
  [ -z "$ARCH_SOURCE" ] && ARCH_SOURCE="none"
}

# ARCH → путь фида repo.hoaxisr.ru
arch_to_repo_path() {
  case "$1" in
    aarch64) echo "aarch64-k3.10" ;;
    mipsel)  echo "mipsel-k3.4" ;;
    mips)    echo "mips-k3.4" ;;
    *)       echo "" ;;
  esac
}

need_arch() {
  [ -z "$ARCH" ] && detect_arch
  if [ -z "$ARCH" ]; then
    error "Не удалось определить архитектуру (нужны aarch64 / mipsel / mips)."
    return 1
  fi
  case "$ARCH" in
    aarch64|mipsel|mips) return 0 ;;
    *)
      error "Архитектура $ARCH не поддерживается firc (только aarch64, mipsel, mips)."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Вспомогательные
# ---------------------------------------------------------------------------
is_pkg_installed() {
  opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "
}

installed_version() {
  opkg list-installed 2>/dev/null | sed -n "s/^${PKG_NAME} - //p" | head -1
}

# fircd в процессе?
is_fircd_running() {
  if command -v pidof >/dev/null 2>&1; then
    pidof fircd >/dev/null 2>&1 && return 0
  fi
  ps 2>/dev/null | grep -v grep | grep -q '[f]ircd'
}

# сокет отвечает?
is_firc_ready() {
  [ -S "$SOCK" ] || return 1
  if command -v socat >/dev/null 2>&1; then
    socat -u /dev/null "UNIX-CONNECT:${SOCK},connect-timeout=2" >/dev/null 2>&1 && return 0
    # старый socat без connect-timeout
    socat -u /dev/null "UNIX-CONNECT:${SOCK}" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 0
}

http_get_stdout() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O- -T 30 "$url"
  else
    return 1
  fi
}

read_choice() {
  if [ -c /dev/tty ]; then
    read -r choice < /dev/tty
  else
    read -r choice
  fi
  printf '%s' "$choice"
}

confirm_yes() {
  printf '%s' "${YELLOW}[?]${NC} $1 [y/N]: "
  c=$(read_choice)
  case "$c" in
    y|Y|yes|YES|д|Д|да|Да) return 0 ;;
    *) return 1 ;;
  esac
}

pause() {
  printf '%s' "${DIM}Нажмите Enter...${NC} "
  read_choice >/dev/null
}

# ---------------------------------------------------------------------------
# Конфликты / подготовка к установке
# ---------------------------------------------------------------------------
# MagiTrickle — тот же DNS-proxy :3553 и remap 53
is_magitrickle_running() {
  if command -v pidof >/dev/null 2>&1; then
    pidof magitrickled >/dev/null 2>&1 && return 0
  fi
  ps 2>/dev/null | grep -v grep | grep -q '[m]agitrickled'
}

stop_magitrickle() {
  for s in /opt/etc/init.d/S99magitrickle /opt/etc/init.d/S98magitrickle \
           /opt/etc/init.d/S99MagiTrickle; do
    if [ -x "$s" ]; then
      info "Остановка MagiTrickle: $s stop"
      "$s" stop 2>/dev/null || true
    fi
  done
  killall magitrickled 2>/dev/null || true
  sleep 1
}

warn_conflicts() {
  hit=0
  if is_magitrickle_running || opkg list-installed 2>/dev/null | grep -q '^magitrickle '; then
    hit=1
    warn "MagiTrickle установлен/запущен — конфликт с firc (DNS :3553, remap 53)."
    warn "Вместе не работают. Перед установкой firc лучше остановить MagiTrickle."
  fi
  # занятые порты
  busy=""
  if command -v netstat >/dev/null 2>&1; then
    busy=$(netstat -lntu 2>/dev/null | grep -E ':(3553|666)\s' || true)
  elif command -v ss >/dev/null 2>&1; then
    busy=$(ss -lntu 2>/dev/null | grep -E ':(3553|666)\s' || true)
  fi
  if [ -n "$busy" ] && ! is_fircd_running; then
    hit=1
    warn "Порты 3553/666 уже заняты (не fircd):"
    printf '%s\n' "$busy" | head -5
  fi
  [ "$hit" = 1 ] && echo
  return 0
}

# Остановить firc и снять stale lock (для чистого postinst / restart)
firc_stop_clean() {
  if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop 2>/dev/null || true
  fi
  if is_fircd_running; then
    killall fircd 2>/dev/null || true
    sleep 1
    killall -9 fircd 2>/dev/null || true
    sleep 1
  fi
  # lock без процесса — мешает старту («another fircd holds lock»)
  if [ -e "$LOCKFILE" ] || [ -d "$RUNDIR" ]; then
    if ! is_fircd_running; then
      rm -rf "$RUNDIR" /tmp/firc-init 2>/dev/null || true
      info "Очищен stale runtime: $RUNDIR"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Версия / статус
# ---------------------------------------------------------------------------
LATEST_TAG=""

fetch_latest() {
  LATEST_TAG=""
  need_arch 2>/dev/null || true
  [ -n "$ARCH" ] || return 0
  path=$(arch_to_repo_path "$ARCH")
  [ -n "$path" ] || return 0

  for base in "$REPO_BASE" "$REPO_BASE_HTTPS"; do
    pkg=$(http_get_stdout "${base}/${path}/Packages" 2>/dev/null) || pkg=""
    if [ -z "$pkg" ] && command -v curl >/dev/null 2>&1; then
      pkg=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        "${base}/${path}/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null) || pkg=""
    fi
    ver=$(printf '%s\n' "$pkg" | awk '
      $1=="Package:" && $2=="firc" {inpkg=1; next}
      inpkg && $1=="Version:" {print $2; exit}
      inpkg && $1=="Package:" {exit}
    ')
    if [ -n "$ver" ]; then
      LATEST_TAG="$ver"
      return 0
    fi
  done
}

fmt_latest() {
  [ -n "$LATEST_TAG" ] && printf ' %s%s[ %s ]%s' "$BLUE" "$BOLD" "$LATEST_TAG" "$NC"
}

show_status() {
  if is_pkg_installed; then
    ver=$(installed_version)
    info "Установлено: ${PKG_NAME} ${ver:-ok}"
  elif [ -x "$FIRCD" ]; then
    warn "Бинарник есть, в opkg — не configured / не установлен"
  else
    printf '%s\n' "${DIM}Не установлено${NC}"
    return 0
  fi
  if is_fircd_running; then
    if is_firc_ready; then
      info "Демон: fircd запущен, сокет $SOCK ok"
    else
      info "Демон: fircd запущен (сокет пока не готов)"
    fi
  else
    printf '%s\n' "  ${DIM}демон: не запущен${NC}"
    [ -e "$LOCKFILE" ] && warn "  есть lock $LOCKFILE без процесса — stale"
  fi
}

warn_old_platform() {
  ver=""
  command -v ndmc >/dev/null 2>&1 && \
    ver=$(ndmc -c show version 2>/dev/null | head -5)
  kver=$(uname -r 2>/dev/null || true)
  model=$(cat /proc/device-tree/model 2>/dev/null || true)
  [ -z "$model" ] && model=$(grep -i 'machine\|Hardware' /proc/cpuinfo 2>/dev/null | head -1)

  old=0
  case "$kver" in
    2.*|3.0*|3.1*|3.2*|3.3*) old=1 ;;
  esac
  case "$model" in
    *kn_rb*|*KN-RB*|*Keenetic_II*|*KeeneticII*) old=1 ;;
  esac
  echo "$ver $model $kver" | grep -qiE 'kn_rb|keenetic.?ii|ndms[[:space:]]*2\.' && old=1

  if [ "$old" = 1 ]; then
    echo
    warn "Старая платформа (ядро ${kver:-?}). firc рассчитан на KeeneticOS 4+/5+."
    echo
  fi
}

# ---------------------------------------------------------------------------
# Диагностика
# ---------------------------------------------------------------------------
diagnose_firc() {
  echo
  printf '%s\n' "${BOLD}Диагностика firc${NC}"
  warn_old_platform
  warn_conflicts

  if [ -x "$FIRCD" ]; then
    info "Бинарник: $FIRCD"
  else
    error "Нет $FIRCD — пакет не распакован."
  fi

  if is_pkg_installed; then
    info "opkg: $(installed_version)"
  else
    warn "opkg: пакет firc не в list-installed (возможен failed configure)"
  fi

  if is_fircd_running; then
    info "Процесс fircd: есть"
    is_firc_ready && info "Сокет: $SOCK отвечает" || warn "Сокет: $SOCK не отвечает"
  else
    warn "Процесс fircd: нет"
    [ -e "$LOCKFILE" ] && warn "Stale lock: $LOCKFILE — снимите: rm -rf $RUNDIR"
  fi

  if command -v ldd >/dev/null 2>&1 && [ -x "$FIRCD" ]; then
    miss=$(ldd "$FIRCD" 2>/dev/null | grep -i 'not found' || true)
    if [ -n "$miss" ]; then
      error "Не хватает библиотек:"
      printf '%s\n' "$miss"
    else
      info "ldd: библиотеки ok"
    fi
  fi

  command -v socat >/dev/null 2>&1 && info "socat: ok" || error "socat не найден"

  [ -f "$CONF_DIR/firc.conf" ] && info "Конфиг: $CONF_DIR/firc.conf" || error "Нет firc.conf"
  [ -f "$CONF_DIR/groups.yaml" ] && info "Группы: $CONF_DIR/groups.yaml" || warn "Нет groups.yaml"

  echo
  printf '%s\n' "${DIM}Логи (logread на Keenetic часто нет):${NC}"
  echo "  cat /tmp/messages 2>/dev/null | grep -i firc | tail -30"
  echo "  $INIT_SCRIPT status | restart"
  echo "  $FIRCD --output-floor warn   # если «holds lock» — демон уже запущен"
  return 0
}

# ---------------------------------------------------------------------------
# Репозиторий
# ---------------------------------------------------------------------------
ensure_hoaxisr_repo() {
  repo_url="$1"
  mkdir -p /opt/etc/opkg
  line="src/gz ${OPKG_FEED_NAME} ${repo_url}"

  if [ -f "$OPKG_CONF" ]; then
    tmp="${OPKG_CONF}.$$"
    awk -v feed="$OPKG_FEED_NAME" -v newline="$line" '
      BEGIN { done = 0 }
      $1 == "src/gz" && $2 == feed {
        if (!done) { print newline; done = 1 }
        next
      }
      { print }
      END { if (!done) print newline }
    ' "$OPKG_CONF" > "$tmp" && mv "$tmp" "$OPKG_CONF"
  else
    printf '%s\n' "$line" > "$OPKG_CONF"
  fi
  info "Репозиторий: $repo_url"
  info "Записан: $OPKG_CONF"
}

# ---------------------------------------------------------------------------
# 1) Установка
# ---------------------------------------------------------------------------
do_install() {
  echo
  info "Установка $PKG_NAME (repo.hoaxisr.ru → opkg install)"
  need_arch || return 1
  warn_old_platform
  warn_conflicts

  # MagiTrickle мешает postinst (общий :3553)
  if is_magitrickle_running; then
    if confirm_yes "Остановить MagiTrickle перед установкой firc?"; then
      stop_magitrickle
    else
      warn "Продолжаем с запущенным MagiTrickle — старт firc может не пройти."
    fi
  fi

  path=$(arch_to_repo_path "$ARCH")
  if [ -z "$path" ]; then
    error "Нет фида для ARCH=$ARCH."
    return 1
  fi

  repo_url="${REPO_BASE}/${path}"
  ensure_hoaxisr_repo "$repo_url"

  if ! opkg update; then
    warn "opkg update (HTTP) не удался — HTTPS..."
    repo_url="${REPO_BASE_HTTPS}/${path}"
    ensure_hoaxisr_repo "$repo_url"
    if ! opkg update; then
      error "opkg update не удался. Сеть / DNS / DPI?"
      return 1
    fi
  fi

  # Conflicts: tunvless
  if opkg list-installed 2>/dev/null | grep -q '^tunvless '; then
    warn "Пакет tunvless конфликтует с firc — удаляем..."
    opkg remove tunvless 2>/dev/null || true
  fi

  # Чистый старт postinst: нет чужого lock / старого fircd
  if is_fircd_running || [ -e "$LOCKFILE" ]; then
    info "Останавливаем текущий fircd / очищаем lock перед install..."
    firc_stop_clean
  fi

  install_rc=0
  if is_pkg_installed; then
    info "Пакет уже есть — opkg upgrade firc"
    opkg upgrade "$PKG_NAME" || opkg install "$PKG_NAME" || install_rc=$?
  else
    info "opkg install firc"
    opkg install "$PKG_NAME" || install_rc=$?
  fi

  # postinst вызывает S99firc restart и при ошибке даёт exit 1.
  # Частые ложные провалы: демон уже держал lock; MagiTrickle; сокет не успел.
  if [ "$install_rc" -ne 0 ]; then
    warn "opkg вернул код $install_rc (часто postinst / старт демона)."

    if [ ! -x "$FIRCD" ]; then
      error "opkg install не удался, бинарника нет."
      return 1
    fi

    # Уже запущен после postinst — считаем успехом
    if is_fircd_running; then
      info "fircd уже запущен — установка по сути успешна."
      is_pkg_installed || warn "opkg configure мог не завершиться; файлы на месте."
      install_rc=0
    else
      info "Повторный старт после очистки runtime..."
      firc_stop_clean
      if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" start 2>/dev/null || "$INIT_SCRIPT" restart 2>/dev/null || true
      fi
      sleep 2
      if is_fircd_running; then
        info "Демон запущен после повторной попытки."
        install_rc=0
      else
        diagnose_firc
        error "Демон не запустился. См. диагностику выше."
        error "Типично: MagiTrickle / занят :3553 / «holds fircd.lock»."
        return 1
      fi
    fi
  fi

  info "Установка завершена: $(installed_version)"
  show_status

  echo
  printf '%s\n' "${BOLD}Управление${NC}"
  echo "  $INIT_SCRIPT  (start | stop | restart | status)"
  echo "  WebUI: http://<IP-роутера>:666  (системный логин)"
  printf '%s\n' "${DIM}Репозиторий: ${repo_url}${NC}"
  printf '%s\n' "${DIM}https://github.com/${GITHUB_REPO}${NC}"
  return 0
}

# ---------------------------------------------------------------------------
# 2) Удаление
# ---------------------------------------------------------------------------
do_remove() {
  echo
  info "Удаление $PKG_NAME"
  if ! is_pkg_installed && [ ! -x "$INIT_SCRIPT" ] && [ ! -d "$CONF_DIR" ] && [ ! -x "$FIRCD" ]; then
    warn "Пакет не установлен."
    return 0
  fi

  if ! confirm_yes "Удалить $PKG_NAME?"; then
    info "Отменено."
    return 0
  fi

  remove_conf=0
  if [ -d "$CONF_DIR" ]; then
    confirm_yes "Также удалить конфиг ($CONF_DIR)?" && remove_conf=1
  fi

  firc_stop_clean

  if is_pkg_installed; then
    opkg remove --autoremove "$PKG_NAME" 2>/dev/null \
      || opkg remove "$PKG_NAME" 2>/dev/null \
      || true
    info "Пакет удалён через opkg."
  fi

  # awg_manager.conf общий с awg-manager — не удаляем

  if [ "$remove_conf" = "1" ] && [ -d "$CONF_DIR" ]; then
    rm -rf "$CONF_DIR"
    info "  удалён: $CONF_DIR"
  fi

  rm -rf "$RUNDIR" /tmp/firc-init 2>/dev/null || true

  if [ -f "$INIT_SCRIPT" ] && ! is_pkg_installed; then
    rm -f "$INIT_SCRIPT"
    info "  удалён: $INIT_SCRIPT"
  fi

  info "Готово."
  return 0
}

# ---------------------------------------------------------------------------
# Меню
# ---------------------------------------------------------------------------
main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '%s\n' "${CYAN}================================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}                    firc${NC}"
    printf '%s\n' "${CYAN}================================================${NC}"
    echo
    printf '%s\n' "${DIM}firc — точечная маршрутизация по доменам (FakeIP)${NC}"
    printf '%s\n' "${DIM}на Keenetic / Entware. Не совместим с MagiTrickle.${NC}"
    echo
    printf '%s\n' "${DIM}src/gz hoaxisr → ${OPKG_CONF}${NC}"
    printf '%s\n' "${DIM}http://repo.hoaxisr.ru/ · KeeneticOS 4+/5+${NC}"
    echo
    show_status
    fetch_latest 2>/dev/null || true
    echo
    printf '  1) Установка / обновление firc%s\n' "$(fmt_latest)"
    echo "  2) Удаление firc"
    echo "  3) Диагностика"
    echo "  0) Выход"
    echo
    printf '%s' "${BOLD}Выбор: ${NC}"
    choice=$(read_choice)
    echo
    case "$choice" in
      1) do_install; pause ;;
      2) do_remove; pause ;;
      3) diagnose_firc; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
