#!/usr/bin/env bash
# =============================================================================
# modules/03-spoof-network.sh
# Mecanismos de spoofing de rede (MAC, Hostname, DNS, Timezone, Portas, TTL, IPv6, Bluetooth)
# =============================================================================

# ==================== SPOOF: MAC ====================
randomize_mac() {
info "Randomizando MAC Address"
local found=0
local iface iname current_mac new_mac default_ifaces
default_ifaces=$(get_default_ifaces | tr '\n' ' ')
for iface in /sys/class/net/*/device; do
[[ -e "$iface" ]] || continue
iname=$(echo "$iface" | cut -d'/' -f5)
should_process_iface "$iname" || continue
found=1
if [[ " $default_ifaces " == *" $iname "* ]]; then
if [[ "${RANDOMIZE_ALLOW_DEFAULT_IFACE:-0}" != "1" ]]; then
warn "Pulando interface default [$iname]. Use RANDOMIZE_ALLOW_DEFAULT_IFACE=1 para permitir."
continue
else
warn "[$iname] é interface default. Você pode perder conectividade."
fi
fi
current_mac=$(cat "/sys/class/net/$iname/address" 2>/dev/null)
backup_original "mac_$iname" "$current_mac" || { warn "[$iname] Falha no backup do MAC original. Pulando."; continue; }
new_mac=$(generate_random_mac) || { warn "[$iname] Falha na geração do MAC. Pulando."; continue; }
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] [%s] %s -> %s\n' "$iname" "$current_mac" "$new_mac"
continue
fi
ip link set dev "$iname" down 2>/dev/null
if ip link set dev "$iname" address "$new_mac" 2>/dev/null; then
ok "[$iname] $current_mac -> $new_mac"
log_change "MAC|$iname|$current_mac -> $new_mac"
else
warn "[$iname] falha ao alterar MAC"
fi
ip link set dev "$iname" up 2>/dev/null
if [[ -d "/sys/class/net/$iname/wireless" ]] && command -v nmcli &>/dev/null; then
( sleep 1 && nmcli device connect "$iname" 2>/dev/null ) &
fi
done
if [[ $found -eq 0 ]]; then
warn "Nenhuma interface de rede processada."
fi
}

rotate_mac_quiet() {
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] rotate_mac_quiet\n'
return 0
fi
local iface iname old_mac new_mac default_ifaces
default_ifaces=$(get_default_ifaces | tr '\n' ' ')
for iface in /sys/class/net/*/device; do
[[ -e "$iface" ]] || continue
iname=$(echo "$iface" | cut -d'/' -f5)
should_process_iface "$iname" || continue
if [[ " $default_ifaces " == *" $iname "* && "${RANDOMIZE_ALLOW_DEFAULT_IFACE:-0}" != "1" ]]; then
continue
fi
old_mac=$(cat "/sys/class/net/$iname/address" 2>/dev/null)
backup_original "mac_$iname" "$old_mac" || continue
new_mac=$(generate_random_mac) || continue
ip link set dev "$iname" down 2>/dev/null
if ip link set dev "$iname" address "$new_mac" 2>/dev/null; then
log_change "MAC|$iname|$old_mac -> $new_mac"
if command -v notify-send &>/dev/null && { [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; }; then
notify-send -t 3000 "MAC alterado" "$iname: $new_mac" 2>/dev/null || true
fi
fi
ip link set dev "$iname" up 2>/dev/null
if [[ -d "/sys/class/net/$iname/wireless" ]] && command -v nmcli &>/dev/null; then
( sleep 1 && nmcli device connect "$iname" 2>/dev/null ) &
fi
done
}

randomize_mac_quiet() {
rotate_mac_quiet
}

# ==================== SPOOF: HOSTNAME ====================
randomize_hostname() {
info "Randomizando Hostname"
local current_hostname new_hostname
current_hostname=$(hostname)
new_hostname="pc-$(random_string 8)"
backup_original "hostname" "$current_hostname" || return 1
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] hostname %s -> %s\n' "$current_hostname" "$new_hostname"
return 0
fi
set_hostname_safe "$new_hostname"
write_str "/etc/hostname" "$new_hostname"
chmod 644 /etc/hostname 2>/dev/null || true
if [[ -f /etc/hosts ]]; then
backup_original "hosts" "$(cat /etc/hosts)" || return 1
if grep -qE '^[[:space:]]*127\.0\.1\.1' /etc/hosts; then
run sed -i -E "s/^([[:space:]]*127\.0\.1\.1[[:space:]]+).*/\1$new_hostname/" /etc/hosts
else
append_str "/etc/hosts" "127.0.1.1 $new_hostname"
fi
fi
ok "$current_hostname -> $new_hostname"
log_change "HOSTNAME|$current_hostname -> $new_hostname"
}

# ==================== SPOOF: DNS ====================
randomize_dns() {
info "Randomizando DNS"
if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null || systemctl is-active --quiet dnscrypt-proxy.service 2>/dev/null; then
ok "DNSCrypt ativo. DNS não será alterado para manter proteção criptografada."
log_change "DNS|dnscrypt-protected"
return 0
fi
local dns_list=(
"1.1.1.1"
"8.8.8.8"
"9.9.9.9"
"208.67.222.222"
"94.140.14.14"
"76.76.2.0"
"185.228.168.9"
)
local idx1 idx2 primary secondary
idx1=$(( $(rand_u32) % ${#dns_list[@]} ))
idx2=$(( (idx1 + 1 + $(rand_u32) % (${#dns_list[@]} - 1)) % ${#dns_list[@]} ))
primary="${dns_list[$idx1]}"
secondary="${dns_list[$idx2]}"
if [[ -f /etc/resolv.conf ]]; then
backup_original "dns" "$(cat /etc/resolv.conf)"
fi
if command -v resolvectl &>/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
warn "NetworkManager ativo. Ele pode sobrescrever o DNS depois."
fi
if ip link show type tun 2>/dev/null | grep -q tun || ip link show type wireguard 2>/dev/null | grep -q wg; then
warn "VPN/tun/wireguard detectado. O DNS pode ser gerenciado pela VPN."
fi
fi
local dns_applied=0
local iface orig_dns
if command -v resolvectl &>/dev/null \
&& systemctl is-active --quiet systemd-resolved 2>/dev/null; then
local found=0
for iface in $(get_default_ifaces); do
found=1
orig_dns=$(get_resolvectl_dns "$iface")
[[ -z "$orig_dns" ]] && orig_dns="__NONE__"
backup_original "resolved_dns_$iface" "$orig_dns"
if run resolvectl dns "$iface" "$primary" "$secondary" 2>/dev/null; then
ok "DNS (resolvectl [$iface]): $primary, $secondary"
dns_applied=1
else
warn "Falha ao definir DNS via resolvectl em $iface"
fi
done
if [[ $found -eq 0 ]]; then
warn "Nenhuma interface default encontrada."
fi
if command -v resolvectl &>/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
run resolvectl flush-caches 2>/dev/null || true
fi
else
if command -v lsattr &>/dev/null && lsattr /etc/resolv.conf 2>/dev/null | grep -q '^....i'; then
warn "/etc/resolv.conf está imutável. Pulando."
return 0
fi
if {
echo "# Gerado por randomize_ids.sh em $(date)"
echo "nameserver $primary"
echo "nameserver $secondary"
} | write_file /etc/resolv.conf; then
chmod 644 /etc/resolv.conf 2>/dev/null || true
ok "DNS (resolv.conf): $primary, $secondary"
dns_applied=1
else
warn "Falha ao escrever /etc/resolv.conf"
fi
fi
if [[ $dns_applied -eq 1 ]]; then
log_change "DNS|$primary|$secondary"
fi
}

# ==================== SPOOF: TIMEZONE ====================
randomize_timezone() {
info "Randomizando Timezone"
local tz_list=(
"America/New_York"
"America/Chicago"
"America/Denver"
"America/Los_Angeles"
"Europe/London"
"Europe/Berlin"
"Europe/Paris"
"Europe/Moscow"
"Asia/Tokyo"
"Asia/Shanghai"
"Asia/Kolkata"
"Asia/Dubai"
"Pacific/Auckland"
"Australia/Sydney"
"America/Sao_Paulo"
"America/Argentina/Buenos_Aires"
)
local current_tz chosen idx
current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "desconhecido")
backup_original "timezone" "$current_tz"
idx=$(( $(rand_u32) % ${#tz_list[@]} ))
chosen="${tz_list[$idx]}"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] timezone %s -> %s\n' "$current_tz" "$chosen"
return 0
fi
if run timedatectl set-timezone "$chosen" 2>/dev/null; then
ok "$current_tz -> $chosen"
else
run ln -sf "/usr/share/zoneinfo/$chosen" /etc/localtime
write_str "/etc/timezone" "$chosen"
chmod 644 /etc/timezone 2>/dev/null || true
ok "$current_tz -> $chosen (fallback)"
fi
log_change "TIMEZONE|$current_tz -> $chosen"
}


# ==================== SPOOF: PORTAS / TTL / IPv6 ====================
randomize_ports() {
info "Randomizando portas efêmeras"
    local current_range min_port max_port
    current_range=$(</proc/sys/net/ipv4/ip_local_port_range)
    backup_original "port_range" "$current_range"
    min_port=$(rand_range 20000 39999)
    max_port=$(rand_range 50000 64999)
    echo "  Atual: $current_range"
    echo "  Novo: $min_port  $max_port"
    printf '%s %s\n' "$min_port" "$max_port" | write_file /proc/sys/net/ipv4/ip_local_port_range
    ok "Portas efêmeras alteradas"
    log_change "PORTS|$current_range -> $min_port $max_port"
}

randomize_ttl() {
    info "Randomizando TTL"
    local ttl_list=(64 128 255 60 100 130)
    local current_ttl new_ttl idx
    local available=()
    local t
    current_ttl=$(</proc/sys/net/ipv4/ip_default_ttl)
    backup_original "ttl" "$current_ttl"
    for t in "${ttl_list[@]}"; do
        [[ "$t" != "$current_ttl" ]] && available+=("$t")
    done
    if (( ${#available[@]} == 0 )); then
        available=("${ttl_list[@]}")
    fi
    idx=$(( $(rand_u32) % ${#available[@]} ))
    new_ttl="${available[$idx]}"
    echo "  Atual: $current_ttl"
    echo "  Novo: $new_ttl"
    write_str "/proc/sys/net/ipv4/ip_default_ttl" "$new_ttl"
    if [[ -f /proc/sys/net/ipv6/conf/all/hop_limit ]]; then
        backup_original "hop_limit" "$(</proc/sys/net/ipv6/conf/all/hop_limit)"
        write_str "/proc/sys/net/ipv6/conf/all/hop_limit" "$new_ttl"
    fi
ok "TTL alterado"
log_change "TTL|$current_ttl -> $new_ttl"
}

toggle_ipv6() {
local action="${1:-disable}"
case "$action" in
disable|off|0)
info "Desabilitando IPv6"
local current_state
current_state=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")
backup_original "ipv6_state" "$current_state"
run sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
run sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
local iface iname
for iface in /sys/class/net/*/; do
iname=$(basename "$iface")
if [[ -w "/proc/sys/net/ipv6/conf/$iname/disable_ipv6" ]]; then
write_str "/proc/sys/net/ipv6/conf/$iname/disable_ipv6" "1"
fi
done
ok "IPv6 desabilitado"
log_change "IPV6|disabled"
;;
enable|on|1)
info "Reabilitando IPv6"
run sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
run sysctl -w net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
local iface iname
for iface in /sys/class/net/*/; do
iname=$(basename "$iface")
if [[ -w "/proc/sys/net/ipv6/conf/$iname/disable_ipv6" ]]; then
write_str "/proc/sys/net/ipv6/conf/$iname/disable_ipv6" "0"
fi
done
ok "IPv6 reabilitado"
log_change "IPV6|enabled"
;;
*)
die "Ação inválida para ipv6: '$action' (use: disable ou enable)"
;;
esac
}

toggle_bluetooth() {
local action="${1:-disable}"
case "$action" in
disable|off|0|block)
info "Desabilitando/Bloqueando Bluetooth"
local current_state
current_state=$(check_bluetooth_disabled)
backup_original "bluetooth_state" "$current_state"
if command -v rfkill &>/dev/null; then
run rfkill block bluetooth 2>/dev/null || true
fi
if command -v systemctl &>/dev/null; then
run systemctl stop bluetooth.service 2>/dev/null || true
fi
ok "Bluetooth desabilitado (rfkill/systemd)"
log_change "BLUETOOTH|disabled"
;;
enable|on|1|unblock)
info "Reabilitando Bluetooth"
if command -v rfkill &>/dev/null; then
run rfkill unblock bluetooth 2>/dev/null || true
fi
if command -v systemctl &>/dev/null; then
run systemctl start bluetooth.service 2>/dev/null || true
fi
ok "Bluetooth reabilitado"
log_change "BLUETOOTH|enabled"
;;
randomize|spoof)
info "Randomizando identificadores do Bluetooth (Nome + MAC/BD_ADDR)"
if command -v rfkill &>/dev/null; then
run rfkill unblock bluetooth 2>/dev/null || true
fi
local new_bt_mac
new_bt_mac=$(generate_random_mac)
if command -v btmgmt &>/dev/null; then
run btmgmt --index 0 power off 2>/dev/null || true
if run btmgmt --index 0 public-addr "$new_bt_mac" 2>/dev/null || run btmgmt --index 0 static-addr "$new_bt_mac" 2>/dev/null; then
ok "BD_ADDR (MAC Bluetooth) alterado para: $new_bt_mac"
log_change "BLUETOOTH|mac:$new_bt_mac"
else
warn "Chipset Bluetooth não permitiu alterar BD_ADDR via btmgmt"
fi
run btmgmt --index 0 power on 2>/dev/null || true
elif command -v bdaddr &>/dev/null; then
if run bdaddr -i hci0 "$new_bt_mac" 2>/dev/null; then
run hciconfig hci0 reset 2>/dev/null || true
ok "BD_ADDR (MAC Bluetooth) alterado via bdaddr: $new_bt_mac"
log_change "BLUETOOTH|mac:$new_bt_mac"
fi
else
warn "btmgmt/bdaddr não encontrados para alterar o MAC físico do Bluetooth."
fi
if command -v bluetoothctl &>/dev/null; then
local fake_bt_name="Device-$(random_string 6)"
run bluetoothctl discoverable off 2>/dev/null || true
run bluetoothctl pairable off 2>/dev/null || true
run bluetoothctl system-alias "$fake_bt_name" 2>/dev/null || true
ok "Bluetooth oculto (discoverable=off) e nome alterado para: $fake_bt_name"
log_change "BLUETOOTH|alias:$fake_bt_name"
else
warn "bluetoothctl não disponível."
fi
;;
*)
die "Ação inválida para bluetooth: '$action' (use: disable, enable ou randomize)"
;;
esac
}

randomize_network() {
info "Randomizando parâmetros de rede"
randomize_ports
randomize_ttl
toggle_ipv6 disable
toggle_bluetooth disable
}

