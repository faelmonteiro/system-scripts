#!/usr/bin/env bash
# =============================================================================
# modules/02-checks.sh
# Funções de verificação de status e detecção de spoofing ativo em cada componente
# =============================================================================

# ==================== VERIFICAÇÃO DE SPOOF ====================
check_mac_spoofed() {
local iface iname orig curr
for iface in /sys/class/net/*/device; do
[[ -e "$iface" ]] || continue
iname=$(echo "$iface" | cut -d'/' -f5)
if [[ -f "$STATE_DIR/original_mac_$iname" ]]; then
orig=$(cat "$STATE_DIR/original_mac_$iname")
curr=$(cat "/sys/class/net/$iname/address" 2>/dev/null)
if [[ "$orig" != "$curr" ]]; then
echo 1
return
fi
fi
done
echo 0
}

check_hostname_spoofed() {
if [[ -f "$STATE_DIR/original_hostname" ]]; then
local orig curr
orig=$(cat "$STATE_DIR/original_hostname")
curr=$(hostname)
[[ "$orig" != "$curr" ]] && echo 1 && return
fi
echo 0
}

check_dns_spoofed() {
if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null || systemctl is-active --quiet dnscrypt-proxy.service 2>/dev/null; then
echo 1
return
fi
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
local iface orig curr
for iface in $(get_default_ifaces); do
if [[ -f "$STATE_DIR/original_resolved_dns_$iface" ]]; then
orig=$(cat "$STATE_DIR/original_resolved_dns_$iface")
curr=$(get_resolvectl_dns "$iface")
if [[ "$orig" == "__NONE__" ]]; then
if [[ -n "$curr" ]]; then
echo 1
return
fi
elif [[ "$orig" != "$curr" ]]; then
echo 1
return
fi
fi
done
elif [[ -f "$STATE_DIR/original_dns" ]]; then
local orig curr
orig=$(grep '^nameserver' "$STATE_DIR/original_dns" 2>/dev/null | sort)
curr=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | sort)
if [[ "$orig" != "$curr" ]]; then
echo 1
return
fi
fi
echo 0
}

check_tz_spoofed() {
if [[ -f "$STATE_DIR/original_timezone" ]]; then
local orig curr
orig=$(cat "$STATE_DIR/original_timezone")
curr=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
[[ "$orig" != "$curr" ]] && echo 1 && return
fi
echo 0
}

check_disk_spoofed() {
[[ -f "$UDEV_RULE_FILE" ]] && echo 1 || echo 0
}

check_dmi_spoofed() {
local f
for f in \
product_uuid \
product_name \
product_serial \
board_serial \
board_name \
board_vendor \
sys_vendor \
chassis_serial; do
if findmnt -n "/sys/class/dmi/id/$f" &>/dev/null; then
echo 1
return
fi
done
echo 0
}

check_ram_spoofed() {
findmnt -n /proc/meminfo &>/dev/null && echo 1 || echo 0
}

check_cpu_spoofed() {
findmnt -n /proc/cpuinfo &>/dev/null && echo 1 || echo 0
}

check_uptime_spoofed() {
findmnt -n /proc/uptime &>/dev/null && echo 1 || echo 0
}

check_machineid_spoofed() {
if [[ -f "$STATE_DIR/original_machine_id" ]]; then
local orig curr
orig=$(cat "$STATE_DIR/original_machine_id")
curr=$(cat /etc/machine-id 2>/dev/null)
[[ "$orig" != "$curr" ]] && echo 1 && return
fi
echo 0
}

check_screen_spoofed() {
if [[ -f "$XRANDR_WRAPPER" ]] && grep -q 'FAKE_XRANDR' "$XRANDR_WRAPPER" 2>/dev/null; then
echo 1
else
echo 0
fi
}

check_ports_spoofed() {
if [[ -f "$STATE_DIR/original_port_range" ]]; then
local orig curr
orig=$(cat "$STATE_DIR/original_port_range")
curr=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
[[ "$orig" != "$curr" ]] && echo 1 && return
fi
echo 0
}

check_ttl_spoofed() {
if [[ -f "$STATE_DIR/original_ttl" ]]; then
local orig curr
orig=$(cat "$STATE_DIR/original_ttl")
curr=$(cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null)
[[ "$orig" != "$curr" ]] && echo 1 && return
fi
echo 0
}

check_ipv6_disabled() {
[[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]] && echo 1 || echo 0
}

check_bluetooth_disabled() {
if command -v rfkill &>/dev/null && rfkill list bluetooth 2>/dev/null | grep -qE "Soft blocked: yes|Hard blocked: yes"; then
echo 1
elif command -v systemctl &>/dev/null && ! systemctl is-active --quiet bluetooth 2>/dev/null; then
echo 1
else
echo 0
fi
}

check_user_spoofed() {
[[ -f "$TEMP_USER_FILE" ]] && id "$(cat "$TEMP_USER_FILE")" &>/dev/null && echo 1 || echo 0
}

check_auto_running() {
if command -v systemctl &>/dev/null && systemctl is-active --quiet "$SYSTEMD_TIMER" 2>/dev/null; then
echo 1
else
echo 0
fi
}

