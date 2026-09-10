#!/usr/bin/env bash
# =============================================================================
# modules/00-config.sh
# Configurações de estado, cores, ícones, helpers de arquivo e geradores aleatórios.
# =============================================================================

VERSION="1.3.1"
set -o pipefail
set -u
shopt -s nullglob

# ==================== ESTADO ====================
STATE_DIR="/var/lib/randomize-ids"
CHANGE_LOG="$STATE_DIR/mac_changes.log"
PROFILE_DIR="$STATE_DIR/profiles"
FAKE_DMI_DIR="$STATE_DIR/fake_dmi"
FAKE_RAM_FILE="$STATE_DIR/fake_meminfo"
FAKE_CPU_FILE="$STATE_DIR/fake_cpuinfo"
FAKE_UPTIME_FILE="$STATE_DIR/fake_uptime"
UPTIME_PID_FILE="$STATE_DIR/uptime_updater.pid"
UPTIME_OFFSET_FILE="$STATE_DIR/uptime_offset"
ACTIVE_PERSONA_FILE="$STATE_DIR/active_persona"
TEMP_USER_FILE="$STATE_DIR/temp_user"
TEMP_PASS_FILE="$STATE_DIR/temp_user_pass"
XRANDR_WRAPPER="/usr/local/bin/xrandr"
UDEV_RULE_FILE="/etc/udev/rules.d/99-fake-serial.rules"
HARDEN_SYSCTL="/etc/sysctl.d/99-randomize-ids-hardening.conf"
SYSTEMD_SERVICE="randomize-mac.service"
SYSTEMD_TIMER="randomize-mac.timer"
INTERVAL="${RANDOMIZE_INTERVAL:-420}"
DRY_RUN=0
YES_MODE=0
DEBUG=0

# ==================== CORES ====================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
GRAY=$'\033[0;90m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'
else
RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' GRAY='' BOLD='' DIM='' NC=''
fi

# ==================== ÍCONES ====================
if [[ "${RANDOMIZE_NO_EMOJI:-0}" == "1" ]]; then
ICON_SHIELD="[#]"
ICON_MAC="[MAC]"
ICON_HOST="[HOST]"
ICON_DNS="[DNS]"
ICON_TZ="[TZ]"
ICON_DISK="[DISK]"
ICON_DMI="[DMI]"
ICON_RAM="[RAM]"
ICON_MID="[MID]"
ICON_SCREEN="[SCR]"
ICON_CPU="[CPU]"
ICON_UPTIME="[UPT]"
ICON_USER="[USER]"
ICON_PORTS="[PORT]"
ICON_TTL="[TTL]"
ICON_IPV6="[IPv6]"
ICON_BT="[BT]"
ICON_OK="[*]"
ICON_OFF="[ ]"
ICON_GEARS="[ACTIONS]"
ICON_TOOLS="[TOOLS]"
ICON_PROFILE="[PROFILE]"
ICON_SAVE="[SAVE]"
ICON_LOAD="[LOAD]"
ICON_LIST="[LIST]"
ICON_BACK="[BACK]"
ICON_ALL="[ALL]"
ICON_PARANOID="[PARANOID]"
ICON_RESTORE="[RESTORE]"
ICON_NETWORK="[NET]"
ICON_AUTO="[AUTO]"
ICON_STOP="[STOP]"
ICON_STATUS="[STATUS]"
ICON_LOG="[LOG]"
ICON_CLEAN="[CLEAN]"
ICON_VERIFY="[VERIFY]"
ICON_UNINSTALL="[UNINSTALL]"
ICON_HARDEN="[HARDEN]"
ICON_HARDEN_UNDO="[UNDO]"
ICON_LEAK="[LEAK]"
ICON_BROWSER="[BROWSER]"
ICON_WARN="[WARN]"
ICON_EXIT="[EXIT]"
else
ICON_SHIELD="🛡️"
ICON_MAC="🔗"
ICON_HOST="🏷️"
ICON_DNS="📡"
ICON_TZ="🕒"
ICON_DISK="💾"
ICON_DMI="🧬"
ICON_RAM="🧠"
ICON_MID="🆔"
ICON_SCREEN="🖥️"
ICON_CPU="⚙️"
ICON_UPTIME="⏱️"
ICON_USER="👤"
ICON_PORTS="🚪"
ICON_TTL="⏳"
ICON_IPV6="🌍"
ICON_BT="📶"
ICON_OK="✅"
ICON_OFF="⬜"
ICON_GEARS="⚙️"
ICON_TOOLS="🛠️"
ICON_PROFILE="📁"
ICON_SAVE="💾"
ICON_LOAD="📂"
ICON_LIST="📜"
ICON_BACK="↩️"
ICON_ALL="🚀"
ICON_PARANOID="☢️"
ICON_RESTORE="↩️"
ICON_NETWORK="🌐"
ICON_AUTO="🔄"
ICON_STOP="⏹️"
ICON_STATUS="📊"
ICON_LOG="📜"
ICON_CLEAN="🧹"
ICON_VERIFY="✅"
ICON_UNINSTALL="🗑️"
ICON_HARDEN="🔒"
ICON_HARDEN_UNDO="🔓"
ICON_LEAK="🔍"
ICON_BROWSER="🌐"
ICON_WARN="⚠️"
ICON_EXIT="🚪"
fi

# ==================== MENSAGENS ====================
info()  { printf '%s\n' "${CYAN}[INFO]${NC} $*"; }
ok()    { printf '%s\n' "${GREEN}[OK]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[AVISO]${NC} $*"; }
err()   { printf '%s\n' "${RED}[ERRO]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

# ==================== HELPERS ====================
ensure_state() {
if [[ $EUID -eq 0 ]]; then
mkdir -p "$STATE_DIR" "$PROFILE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
chmod 700 "$PROFILE_DIR" 2>/dev/null || true
fi
}

run() {
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] %s\n' "$*"
return 0
fi
"$@"
}

write_file() {
local file="$1"
local tmp=""
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] escreveria em %s\n' "$file"
cat >/dev/null
return 0
fi
case "$file" in
/proc/*|/sys/*|/dev/*)
cat > "$file"
;;
*)
mkdir -p "$(dirname "$file")" 2>/dev/null || true
if [[ -L "$file" ]]; then
cat > "$file"
return 0
fi
tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
if cat > "$tmp"; then
if [[ "$file" == "$STATE_DIR"/* || "$file" == "$PROFILE_DIR"/* ]]; then
chmod 600 "$tmp" 2>/dev/null || true
else
chmod 644 "$tmp" 2>/dev/null || true
fi
mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
else
rm -f "$tmp"
return 1
fi
;;
esac
}

write_str() {
local file="$1"
local content="$2"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] escreveria em %s: %s\n' "$file" "$content"
return 0
fi
printf '%s\n' "$content" | write_file "$file"
}

append_str() {
local file="$1"
local content="$2"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] acrescentaria em %s: %s\n' "$file" "$content"
return 0
fi
printf '%s\n' "$content" >> "$file"
}

truncate_file() {
local file="$1"
[[ -f "$file" ]] || return 0
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] truncar %s\n' "$file"
return 0
fi
: > "$file" 2>/dev/null || true
}

backup_original() {
local key="$1"
local value="$2"
ensure_state
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] backup original_%s\n' "$key"
return 0
fi
if [[ ! -f "$STATE_DIR/original_$key" ]]; then
if ! printf '%s\n' "$value" | write_file "$STATE_DIR/original_$key"; then
err "Falha crítica ao gravar backup de original_${key}! Abortando operação por segurança."
return 1
fi
fi
chmod 600 "$STATE_DIR/original_$key" 2>/dev/null || true
return 0
}

backup_current_if_missing() {
local key="$1"
local value="$2"
ensure_state
if [[ ! -f "$STATE_DIR/original_$key" ]]; then
backup_original "$key" "$value" || return 1
fi
return 0
}

stop_uptime_updater() {
if [[ -f "$UPTIME_PID_FILE" ]]; then
local upt_pid
upt_pid=$(cat "$UPTIME_PID_FILE" 2>/dev/null || echo "")
if [[ -n "$upt_pid" ]] && kill -0 "$upt_pid" 2>/dev/null; then
kill "$upt_pid" 2>/dev/null || true
pkill -P "$upt_pid" 2>/dev/null || true
fi
rm -f "$UPTIME_PID_FILE"
fi
}

log_change() {
[[ $DRY_RUN -eq 1 ]] && return 0
ensure_state
echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" >> "$CHANGE_LOG"
chmod 600 "$CHANGE_LOG" 2>/dev/null || true
}

ask_yes() {
local prompt="$1"
if [[ $YES_MODE -eq 1 || $DRY_RUN -eq 1 ]]; then
return 0
fi
[[ -t 0 ]] || return 1
local ans
read -r -p "$prompt [s/N]: " ans || return 1
[[ "$ans" =~ ^[sS]$ ]]
}

rand_u32() {
local n
n=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d '[:space:]')
echo "${n:-0}"
}

rand_range() {
local min="$1"
local max="$2"
local span
span=$((max - min + 1))
if (( span <= 0 )); then echo "$min"; return; fi
echo $((min + $(rand_u32) % span))
}

random_string() {
LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "$1" || true
}

generate_random_mac() {
local bytes
bytes=$(od -An -tx1 -N6 /dev/urandom 2>/dev/null | tr -d '[:space:]')
if [[ ${#bytes} -ne 12 ]]; then
# Tenta novamente se a primeira leitura de urandom foi truncada
bytes=$(od -An -tx1 -N6 /dev/urandom 2>/dev/null | tr -d '[:space:]')
if [[ ${#bytes} -ne 12 ]]; then
err "Falha crítica ao ler bytes de /dev/urandom para geração de MAC"
return 1
fi
fi
local first
first=$(( (0x${bytes:0:2} & 0xFC) | 0x02 ))
printf '%02x:%s:%s:%s:%s:%s\n' \
"$first" \
"${bytes:2:2}" \
"${bytes:4:2}" \
"${bytes:6:2}" \
"${bytes:8:2}" \
"${bytes:10:2}"
}

get_default_ifaces() {
ip -o route show default 2>/dev/null |
awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' |
sort -u
}

get_resolvectl_dns() {
resolvectl dns "$1" 2>/dev/null |
sed -E 's/^[^:]*:[[:space:]]*//' |
tr -s ' ' |
sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

set_hostname_safe() {
local new_hostname="$1"
if command -v hostnamectl &>/dev/null; then
run hostnamectl set-hostname "$new_hostname" 2>/dev/null || run hostname "$new_hostname" 2>/dev/null || true
else
run hostname "$new_hostname" 2>/dev/null || true
fi
}

should_process_iface() {
local name="$1"
local include="${RANDOMIZE_IFACES:-}"
local exclude="${RANDOMIZE_EXCLUDE_IFACES:-}"
if [[ -n "$include" ]]; then
include=" ${include//,/ } "
[[ "$include" == *" $name "* ]] || return 1
fi
if [[ -n "$exclude" ]]; then
exclude=" ${exclude//,/ } "
[[ "$exclude" == *" $name "* ]] && return 1
fi
return 0
}

valid_hostname() {
[[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

