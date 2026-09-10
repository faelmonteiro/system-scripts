#!/usr/bin/env bash
# =============================================================================
# modules/01-core.sh
# Dependências do sistema, locking exclusivo, checagem de root e cleanup de traps
# =============================================================================

# ==================== DEPENDÊNCIAS / LOCK ====================
check_dependencies() {
local required=(
ip hostname awk sed mount umount findmnt od tr flock
grep cut head date mkdir chmod rm mv cp basename dirname
cat sort tail wc id whoami readlink sleep nproc pkill sysctl mktemp
)
local optional=(
systemctl resolvectl timedatectl hostnamectl localectl udevadm
useradd chpasswd userdel curl notify-send xrandr lsblk bleachbit
)
local missing=()
local cmd
for cmd in "${required[@]}"; do
command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
die "Comandos necessários não encontrados: ${missing[*]}"
fi
local missing_opt=()
for cmd in "${optional[@]}"; do
command -v "$cmd" &>/dev/null || missing_opt+=("$cmd")
done
if (( ${#missing_opt[@]} > 0 )); then
[[ $DEBUG -eq 1 ]] && warn "Comandos opcionais não encontrados: ${missing_opt[*]}"
fi
}

acquire_lock() {
local lock_file old_umask
if [[ $EUID -eq 0 ]]; then
lock_file="/run/randomize-ids.lock"
else
lock_file="${XDG_RUNTIME_DIR:-${HOME:-/tmp}}/randomize-ids-$UID.lock"
fi
old_umask=$(umask)
umask 077
exec 9>"$lock_file" || die "Não foi possível abrir lock file: $lock_file"
if ! flock -n 9; then
die "Outra instância do script já está rodando."
fi
umask "$old_umask"
}

require_root() {
if [[ $EUID -ne 0 ]]; then
die "Este comando precisa ser executado como root. Use: sudo $0 $*"
fi
}

needs_root() {
case "$1" in
mac|hostname|dns|timezone|tz|disk|dmi|user|clean|ram|machineid|machine-id|\
screen|cpu|uptime|ports|ttl|ipv6|bluetooth|bt|network|net|all|all-user|paranoid|restore|\
auto|stop|log|profile|verify|persona|harden|harden-undo|uninstall|\
rotate-quiet|systemd-rotate|--systemd-rotate)
return 0
;;
*)
return 1
;;
esac
}

cleanup_on_exit() {
[[ $DRY_RUN -eq 1 ]] && return 0
local iface iname
for iface in /sys/class/net/*/device; do
[[ -e "$iface" ]] || continue
iname=$(echo "$iface" | cut -d'/' -f5)
ip link set dev "$iname" up 2>/dev/null || true
done
}

