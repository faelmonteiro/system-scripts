#!/usr/bin/env bash
# =============================================================================
# modules/10-status.sh
# Relatório visual de status, exportação de diagnóstico JSON e desinstalação
# =============================================================================

status_json() {
bool() {
[[ "$1" == "1" ]] && echo "true" || echo "false"
}
local s_mac s_host s_dns s_tz s_disk s_dmi s_ram s_cpu s_upt
local s_mid s_scr s_ports s_ttl s_ipv6 s_bt s_user s_auto s_bat s_snd s_krn persona
local bat f
s_mac=$(check_mac_spoofed)
s_host=$(check_hostname_spoofed)
s_dns=$(check_dns_spoofed)
s_tz=$(check_tz_spoofed)
s_disk=$(check_disk_spoofed)
s_dmi=$(check_dmi_spoofed)
s_ram=$(check_ram_spoofed)
s_cpu=$(check_cpu_spoofed)
s_upt=$(check_uptime_spoofed)
s_mid=$(check_machineid_spoofed)
s_scr=$(check_screen_spoofed)
s_ports=$(check_ports_spoofed)
s_ttl=$(check_ttl_spoofed)
s_ipv6=$(check_ipv6_disabled)
s_bt=$(check_bluetooth_disabled)
s_user=$(check_user_spoofed)
s_auto=$(check_auto_running)

s_bat=0
for bat in /sys/class/power_supply/BAT*; do
[[ -d "$bat" ]] || continue
for f in serial_number model_name manufacturer; do
if findmnt -n "$bat/$f" &>/dev/null; then
s_bat=1
break 2
fi
done
done

s_snd=0
findmnt -n /proc/asound/cards &>/dev/null && s_snd=1

s_krn=0
findmnt -n /proc/version &>/dev/null && s_krn=1

persona="null"
if [[ -f "$ACTIVE_PERSONA_FILE" ]]; then
local _raw_persona _p
_raw_persona=$(cat "$ACTIVE_PERSONA_FILE")
_p="${_raw_persona//\\/\\\\}"
_p="${_p//\"/\\\"}"
_p="${_p//$'\n'/\n}"
_p="${_p//$'\r'/\\r}"
_p="${_p//$'\t'/\\t}"
persona="\"$_p\""
fi

cat <<EOF
{
"version": "$VERSION",
"spoofed": {
"mac": $(bool "$s_mac"),
"hostname": $(bool "$s_host"),
"dns": $(bool "$s_dns"),
"timezone": $(bool "$s_tz"),
"disk": $(bool "$s_disk"),
"dmi": $(bool "$s_dmi"),
"ram": $(bool "$s_ram"),
"cpu": $(bool "$s_cpu"),
"uptime": $(bool "$s_upt"),
"battery": $(bool "$s_bat"),
"sound": $(bool "$s_snd"),
"kernel_version": $(bool "$s_krn"),
"machine_id": $(bool "$s_mid"),
"screen": $(bool "$s_scr"),
"ports": $(bool "$s_ports"),
"ttl": $(bool "$s_ttl"),
"ipv6_disabled": $(bool "$s_ipv6"),
"bluetooth_disabled": $(bool "$s_bt"),
"user": $(bool "$s_user")
},
"auto_rotation": $(bool "$s_auto"),
"active_persona": $persona,
"state_dir": "$STATE_DIR"
}
EOF
}

show_status() {
if [[ "${1:-}" == "--json" ]]; then
status_json
return 0
fi
if [[ $EUID -ne 0 ]]; then
warn "Executar status como root mostra mais detalhes."
fi
info "Status dos identificadores"

echo "--- MAC ---"
local iface iname mac original
for iface in /sys/class/net/*/device; do
[[ -e "$iface" ]] || continue
iname=$(echo "$iface" | cut -d'/' -f5)
mac=$(cat "/sys/class/net/$iname/address" 2>/dev/null)
original=""
if [[ -f "$STATE_DIR/original_mac_$iname" ]]; then
original=" (original: $(cat "$STATE_DIR/original_mac_$iname"))"
fi
echo "  $iname: $mac$original"
done
echo

echo "--- Hostname ---"
local current original_host
current=$(hostname)
original_host=""
if [[ -f "$STATE_DIR/original_hostname" ]]; then
original_host=" (original: $(cat "$STATE_DIR/original_hostname"))"
fi
echo "  $current$original_host"
echo

echo "--- DNS ---"
if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
ok "DNSCrypt ativo"
else
if command -v resolvectl &>/dev/null; then
resolvectl status 2>/dev/null | grep "DNS Servers" | head -3 | sed 's/^/  /'
else
grep "nameserver" /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
fi
fi
echo

echo "--- Timezone ---"
echo "  $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'desconhecido')"
echo

echo "--- Disco ---"
if command -v lsblk &>/dev/null; then
lsblk -d -o NAME,SIZE,MODEL,SERIAL 2>/dev/null | head -10
fi
if [[ -f "$UDEV_RULE_FILE" ]]; then
ok "Spoof udev ativo"
fi
echo

echo "--- DMI ---"
local dmi_spoofed=""
if [[ "$(check_dmi_spoofed)" == "1" ]]; then
dmi_spoofed=" [SPOOFADO]"
fi
echo "  Produto: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'N/A')$dmi_spoofed"
echo "  Fabricante: $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo 'N/A')$dmi_spoofed"
echo

echo "--- RAM ---"
local ram_total
ram_total=$(grep '^MemTotal:' /proc/meminfo | LC_ALL=C awk '{print $2}')
echo "  Total: $((ram_total / 1024)) MB"
if [[ "$(check_ram_spoofed)" == "1" ]]; then
ok "RAM spoofada"
fi
echo

echo "--- CPU ---"
echo "  $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || echo 'N/A')"
if [[ "$(check_cpu_spoofed)" == "1" ]]; then
ok "CPU spoofada"
fi
echo

echo "--- Uptime ---"
local uptime_secs up_days up_hours up_mins
uptime_secs=$(cut -d'.' -f1 /proc/uptime 2>/dev/null || echo 0)
up_days=$((uptime_secs / 86400))
up_hours=$(( (uptime_secs % 86400) / 3600 ))
up_mins=$(( (uptime_secs % 3600) / 60 ))
echo "  ${up_days}d ${up_hours}h ${up_mins}m"
if [[ "$(check_uptime_spoofed)" == "1" ]]; then
ok "Uptime spoofado"
fi
echo

echo "--- Machine-ID ---"
echo "  $(cat /etc/machine-id 2>/dev/null || echo 'N/A')"
if [[ -f "$STATE_DIR/original_machine_id" ]]; then
echo "  (original: $(cat "$STATE_DIR/original_machine_id"))"
fi
echo

echo "--- Rede ---"
echo "  TTL: $(cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null || echo 'N/A')"
echo "  Portas efêmeras: $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo 'N/A')"
echo "  IPv6: $([[ "$(check_ipv6_disabled)" == "1" ]] && echo 'DESABILITADO' || echo 'ativo')"
echo "  Bluetooth: $([[ "$(check_bluetooth_disabled)" == "1" ]] && echo 'DESABILITADO' || echo 'ativo')"
echo

echo "--- Tela ---"
if [[ "$(check_screen_spoofed)" == "1" ]]; then
local fake_res
fake_res=$(grep '^# FAKE_RES=' "$XRANDR_WRAPPER" 2>/dev/null | head -1 | cut -d'"' -f2)
echo "  Resolução reportada: ${fake_res:-N/A} [SPOOFADO]"
else
echo "  Resolução: $(xrandr 2>/dev/null | grep '\*' | awk '{print $1}' | head -1 || echo 'N/A')"
fi
echo

echo "--- Bateria ---"
local bat_found=0
for bat in /sys/class/power_supply/BAT*; do
[[ -d "$bat" ]] || continue
bat_found=1
echo "  $(basename "$bat"):"
for f in serial_number model_name manufacturer; do
local val
val=$(cat "$bat/$f" 2>/dev/null || echo 'N/A')
local spoof=""
findmnt -n "$bat/$f" &>/dev/null && spoof=" [SPOOFADO]"
echo "    $f: $val$spoof"
done
done
[[ $bat_found -eq 0 ]] && echo "  Nenhuma bateria (BAT*) encontrada"
echo

echo "--- Som (ALSA) ---"
if findmnt -n /proc/asound/cards &>/dev/null; then
ok "/proc/asound/cards spoofado"
cat /proc/asound/cards 2>/dev/null | sed 's/^/  /'
else
echo "  Estado original"
fi
echo

echo "--- Versão do Kernel ---"
if findmnt -n /proc/version &>/dev/null; then
ok "/proc/version spoofado"
cat /proc/version 2>/dev/null | sed 's/^/  /'
else
cat /proc/version 2>/dev/null | sed 's/^/  /'
fi
echo

echo "--- Usuário ---"
echo "  $(whoami) (UID: $(id -u))"
if [[ -f "$TEMP_USER_FILE" ]]; then
local tuser
tuser=$(cat "$TEMP_USER_FILE")
if id "$tuser" &>/dev/null; then
echo "  Usuário temporário ativo: $tuser"
fi
fi
echo

echo "--- MAC auto ---"
if [[ "$(check_auto_running)" == "1" ]]; then
ok "ATIVO (systemd timer)"
echo "  Intervalo: $((INTERVAL / 60)) minutos"
else
echo "  INATIVO"
fi
}

# ==================== UNINSTALL ====================
uninstall_components() {
local do_restore=0
local purge=0
local arg
for arg in "$@"; do
case "$arg" in
--restore)
do_restore=1
;;
--purge)
purge=1
;;
esac
done
info "Desinstalando componentes"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] uninstall\n'
return 0
fi
if ! ask_yes "Continuar?"; then
info "Cancelado."
return 0
fi
if [[ $do_restore -eq 1 ]]; then
restore_all
else
warn "Sem --restore, bind mounts, usuário temporário e alterações atuais podem permanecer até reboot/restore."
fi
stop_auto
run rm -f "$UDEV_RULE_FILE"
if command -v udevadm &>/dev/null; then
run udevadm control --reload-rules 2>/dev/null || true
run udevadm trigger --subsystem-match=block 2>/dev/null || true
fi
if [[ -f "$XRANDR_WRAPPER" ]] && grep -q 'FAKE_XRANDR' "$XRANDR_WRAPPER" 2>/dev/null; then
run rm -f "$XRANDR_WRAPPER"
fi
local real_bin=""
if [[ -s "$STATE_DIR/original_xrandr_real_path" ]]; then
real_bin=$(cat "$STATE_DIR/original_xrandr_real_path")
fi
if [[ -n "$real_bin" && -e "$real_bin" ]]; then
run mv "$real_bin" "${real_bin%.real}" 2>/dev/null || true
run chmod 755 "${real_bin%.real}" 2>/dev/null || true
else
for real_bin in /usr/bin/xrandr.real /usr/local/bin/xrandr.real; do
if [[ -e "$real_bin" ]]; then
run mv "$real_bin" "${real_bin%.real}" 2>/dev/null || true
run chmod 755 "${real_bin%.real}" 2>/dev/null || true
fi
done
fi
# Restaurar /usr/local/bin/xrandr legítimo salvo antes de sobrescrever, se existir backup
if [[ -s "$STATE_DIR/original_xrandr_usr_local_backup" ]]; then
local usr_local_backup
usr_local_backup=$(cat "$STATE_DIR/original_xrandr_usr_local_backup")
if [[ -f "$usr_local_backup" ]]; then
run mv "$usr_local_backup" "$XRANDR_WRAPPER" 2>/dev/null || true
run chmod 755 "$XRANDR_WRAPPER" 2>/dev/null || true
ok "xrandr original restaurado em $XRANDR_WRAPPER"
fi
fi

# Limpar bind mounts de Bateria, Som e Kernel Version
for bat in /sys/class/power_supply/BAT*; do
[[ -d "$bat" ]] || continue
for f in serial_number model_name manufacturer; do
if findmnt -n "$bat/$f" &>/dev/null; then
run umount "$bat/$f" 2>/dev/null || true
run rm -f "$STATE_DIR/fake_bat_${f}" 2>/dev/null || true
fi
done
done
if findmnt -n /proc/asound/cards &>/dev/null; then
run umount /proc/asound/cards 2>/dev/null || true
run rm -f "$STATE_DIR/fake_asound_cards" 2>/dev/null || true
fi
if findmnt -n /proc/version &>/dev/null; then
run umount /proc/version 2>/dev/null || true
run rm -f "$STATE_DIR/fake_proc_version" 2>/dev/null || true
fi

stop_uptime_updater
run rm -f "$HARDEN_SYSCTL"
run sysctl --system 2>/dev/null || true
if [[ $purge -eq 1 ]]; then
if findmnt -n /proc/meminfo &>/dev/null || \
findmnt -n /proc/cpuinfo &>/dev/null || \
findmnt -n /proc/uptime &>/dev/null || \
[[ "$(check_dmi_spoofed)" == "1" ]]; then
warn "Ainda existem bind mounts ativos."
warn "Use: uninstall --restore --purge"
warn "Ou rode restore antes de purgar."
purge=0
fi
fi
if [[ $purge -eq 1 ]]; then
run rm -rf "$STATE_DIR"
ok "State dir removido: $STATE_DIR"
fi
ok "Componentes removidos."
echo "  Para remover o script, apague manualmente: $0"
}

# ==================== AÇÕES AGRUPADAS ====================
