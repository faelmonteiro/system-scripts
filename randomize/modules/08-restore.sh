#!/usr/bin/env bash
# =============================================================================
# modules/08-restore.sh
# Restauração completa de hardware, rede, arquivos de configuração e estado original
# =============================================================================

# ==================== RESTORE ====================
restore_all() {
info "Restaurando identificadores"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] restore_all\n'
return 0
fi
if [[ "$(check_auto_running)" == "1" || -f "$STATE_DIR/macchanger.pid" ]]; then
stop_auto
fi
stop_uptime_updater
local restored=0
local restore_errors=0
local bat f

# MAC
local macfile iface_name mac
for macfile in "$STATE_DIR"/original_mac_*; do
[[ -s "$macfile" ]] || continue
iface_name=$(basename "$macfile" | sed 's/^original_mac_//')
mac=$(cat "$macfile")
run ip link set dev "$iface_name" down 2>/dev/null || true
if run ip link set dev "$iface_name" address "$mac" 2>/dev/null; then
run ip link set dev "$iface_name" up 2>/dev/null || true
ok "MAC restaurado: $iface_name -> $mac"
else
run ip link set dev "$iface_name" up 2>/dev/null || true
warn "Falha ao restaurar MAC de $iface_name"
restore_errors=$((restore_errors + 1))
fi
restored=1
done

# Hostname
if [[ -s "$STATE_DIR/original_hostname" ]]; then
local orig_host
orig_host=$(cat "$STATE_DIR/original_hostname")
if ! valid_hostname "$orig_host"; then
warn "Hostname original inválido no backup: $orig_host"
restore_errors=$((restore_errors + 1))
else
set_hostname_safe "$orig_host"
if write_str "/etc/hostname" "$orig_host"; then
chmod 644 /etc/hostname 2>/dev/null || true
else
warn "Falha ao escrever /etc/hostname"
restore_errors=$((restore_errors + 1))
fi
if [[ -f /etc/hosts ]]; then
if ! run sed -i -E "s/^([[:space:]]*127\.0\.1\.1[[:space:]]+)[^[:space:]]+/\1$orig_host/" /etc/hosts 2>/dev/null; then
warn "Falha ao restaurar /etc/hosts"
restore_errors=$((restore_errors + 1))
fi
fi
ok "Hostname restaurado: $orig_host"
restored=1
fi
fi

# Hosts
if [[ -s "$STATE_DIR/original_hosts" ]]; then
if run cp "$STATE_DIR/original_hosts" /etc/hosts 2>/dev/null; then
chmod 644 /etc/hosts 2>/dev/null || true
ok "/etc/hosts restaurado ao estado original"
else
warn "Falha ao restaurar /etc/hosts"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi

# DNS resolv.conf
if [[ -s "$STATE_DIR/original_dns" ]]; then
if run cp "$STATE_DIR/original_dns" /etc/resolv.conf 2>/dev/null; then
chmod 644 /etc/resolv.conf 2>/dev/null || true
ok "DNS restaurado (resolv.conf)"
else
warn "Falha ao restaurar /etc/resolv.conf"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi

# DNS resolvectl
local iface_backup iface dns
for iface_backup in "$STATE_DIR"/original_resolved_dns_*; do
[[ -f "$iface_backup" ]] || continue
iface=$(basename "$iface_backup" | sed 's/^original_resolved_dns_//')
dns=$(cat "$iface_backup")
if [[ -z "$dns" || "$dns" == "__NONE__" ]]; then
if run resolvectl revert "$iface" 2>/dev/null; then
ok "DNS revertido (resolvectl [$iface])"
else
warn "Falha ao reverter DNS (resolvectl [$iface])"
restore_errors=$((restore_errors + 1))
fi
else
if run resolvectl dns "$iface" $dns 2>/dev/null; then
ok "DNS restaurado (resolvectl [$iface])"
else
warn "Falha ao restaurar DNS (resolvectl [$iface])"
restore_errors=$((restore_errors + 1))
fi
fi
restored=1
done

# Timezone
if [[ -s "$STATE_DIR/original_timezone" ]]; then
local orig_tz
orig_tz=$(cat "$STATE_DIR/original_timezone")
if [[ -n "$orig_tz" && "$orig_tz" != "desconhecido" ]]; then
if run timedatectl set-timezone "$orig_tz" 2>/dev/null; then
ok "Timezone restaurado: $orig_tz"
else
warn "Falha ao restaurar timezone: $orig_tz"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi
fi

# Locale
if [[ -s "$STATE_DIR/original_locale" ]]; then
local orig_locale
orig_locale=$(cat "$STATE_DIR/original_locale")
if [[ -n "$orig_locale" && "$orig_locale" != "__NONE__" ]] && command -v localectl &>/dev/null; then
if run localectl set-locale "LANG=$orig_locale" 2>/dev/null; then
ok "Locale restaurado: $orig_locale"
else
warn "Falha ao restaurar locale: $orig_locale"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi
fi

# DMI (loop isolado)
local dmi_files=(
product_uuid product_name product_serial board_serial
board_name board_vendor sys_vendor chassis_serial
)
local dmi_file real_path dmi_remaining=0
for dmi_file in "${dmi_files[@]}"; do
real_path="/sys/class/dmi/id/$dmi_file"
if findmnt -n "$real_path" &>/dev/null; then
if run umount "$real_path" 2>/dev/null; then
run rm -f "$FAKE_DMI_DIR/$dmi_file"
ok "DMI restaurado: $dmi_file"
restored=1
else
warn "Falha ao desmontar DMI: $dmi_file"
dmi_remaining=1
fi
fi
done
if [[ $dmi_remaining -eq 0 ]]; then
run rm -rf "$FAKE_DMI_DIR"
else
restore_errors=$((restore_errors + 1))
fi

# ✅ BATERIA (fora do loop DMI)
for bat in /sys/class/power_supply/BAT*; do
[[ -d "$bat" ]] || continue
for f in serial_number model_name manufacturer; do
if findmnt -n "$bat/$f" &>/dev/null; then
if run umount "$bat/$f" 2>/dev/null; then
run rm -f "$STATE_DIR/fake_bat_${f}"
ok "Bateria restaurada: $bat/$f"
restored=1
else
warn "Falha ao desmontar $bat/$f"
restore_errors=$((restore_errors + 1))
fi
fi
done
done

# ✅ SOM (fora do loop DMI)
if findmnt -n /proc/asound/cards &>/dev/null; then
if run umount /proc/asound/cards 2>/dev/null; then
run rm -f "$STATE_DIR/fake_asound_cards"
ok "Placa de som (/proc/asound/cards) restaurada"
restored=1
else
warn "Falha ao desmontar /proc/asound/cards"
restore_errors=$((restore_errors + 1))
fi
fi

# ✅ KERNEL VERSION (fora do loop DMI)
if findmnt -n /proc/version &>/dev/null; then
if run umount /proc/version 2>/dev/null; then
run rm -f "$STATE_DIR/fake_proc_version"
ok "Versão do kernel (/proc/version) restaurada"
restored=1
else
warn "Falha ao desmontar /proc/version"
restore_errors=$((restore_errors + 1))
fi
fi

# RAM
if findmnt -n /proc/meminfo &>/dev/null; then
if run umount /proc/meminfo 2>/dev/null; then
run rm -f "$FAKE_RAM_FILE"
ok "RAM restaurada"
restored=1
else
warn "Falha ao desmontar /proc/meminfo"
restore_errors=$((restore_errors + 1))
fi
fi
if ! findmnt -n /proc/meminfo &>/dev/null; then
run rm -f "$FAKE_RAM_FILE"
fi

# CPU
if findmnt -n /proc/cpuinfo &>/dev/null; then
if run umount /proc/cpuinfo 2>/dev/null; then
run rm -f "$FAKE_CPU_FILE"
ok "CPU restaurada"
restored=1
else
warn "Falha ao desmontar /proc/cpuinfo"
restore_errors=$((restore_errors + 1))
fi
fi
if ! findmnt -n /proc/cpuinfo &>/dev/null; then
run rm -f "$FAKE_CPU_FILE"
fi

# Uptime
if findmnt -n /proc/uptime &>/dev/null; then
if run umount /proc/uptime 2>/dev/null; then
run rm -f "$FAKE_UPTIME_FILE"
ok "Uptime restaurado"
restored=1
else
warn "Falha ao desmontar /proc/uptime"
restore_errors=$((restore_errors + 1))
fi
fi
if ! findmnt -n /proc/uptime &>/dev/null; then
run rm -f "$FAKE_UPTIME_FILE"
fi

# Disco / udev
if [[ -f "$STATE_DIR/original_udev_serial" ]]; then
local orig_rule
orig_rule=$(cat "$STATE_DIR/original_udev_serial")
if [[ -n "$orig_rule" && "$orig_rule" != "__NONE__" ]]; then
printf '%s\n' "$orig_rule" | write_file "$UDEV_RULE_FILE"
chmod 644 "$UDEV_RULE_FILE" 2>/dev/null || true
ok "Regra udev original restaurada"
else
run rm -f "$UDEV_RULE_FILE"
ok "Regra udev removida"
fi
if command -v udevadm &>/dev/null; then
run udevadm control --reload-rules 2>/dev/null || true
run udevadm trigger --subsystem-match=block 2>/dev/null || true
fi
restored=1
elif [[ -f "$UDEV_RULE_FILE" ]]; then
run rm -f "$UDEV_RULE_FILE"
if command -v udevadm &>/dev/null; then
run udevadm control --reload-rules 2>/dev/null || true
run udevadm trigger --subsystem-match=block 2>/dev/null || true
fi
ok "Regra udev removida"
restored=1
fi

# Usuário temporário
if [[ -s "$TEMP_USER_FILE" ]]; then
local temp_user
temp_user=$(cat "$TEMP_USER_FILE")
if id "$temp_user" &>/dev/null; then
run pkill -u "$temp_user" 2>/dev/null || true
sleep 1
if run userdel -r "$temp_user" 2>/dev/null; then
ok "Usuário temporário removido: $temp_user"
else
warn "Falha ao remover usuário temporário: $temp_user"
restore_errors=$((restore_errors + 1))
fi
fi
run rm -f "$TEMP_USER_FILE" "$TEMP_PASS_FILE"
restored=1
fi

# Machine-ID
if [[ -s "$STATE_DIR/original_machine_id" ]]; then
if run cp "$STATE_DIR/original_machine_id" /etc/machine-id 2>/dev/null; then
chmod 444 /etc/machine-id 2>/dev/null || true
if [[ -f /var/lib/dbus/machine-id && ! -L /var/lib/dbus/machine-id ]]; then
run cp "$STATE_DIR/original_machine_id" /var/lib/dbus/machine-id 2>/dev/null || true
chmod 444 /var/lib/dbus/machine-id 2>/dev/null || true
fi
ok "Machine-ID restaurado"
else
warn "Falha ao restaurar /etc/machine-id"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi

# Screen
if [[ -f "$XRANDR_WRAPPER" ]] && grep -q 'FAKE_XRANDR' "$XRANDR_WRAPPER" 2>/dev/null; then
run rm -f "$XRANDR_WRAPPER"
ok "xrandr wrapper removido"
restored=1
fi

# Restaurar /usr/local/bin/xrandr legítimo que foi salvo antes de ser sobrescrito
if [[ -s "$STATE_DIR/original_xrandr_usr_local_backup" ]]; then
local usr_local_backup
usr_local_backup=$(cat "$STATE_DIR/original_xrandr_usr_local_backup")
if [[ -f "$usr_local_backup" ]]; then
run mv "$usr_local_backup" "$XRANDR_WRAPPER" 2>/dev/null || true
run chmod 755 "$XRANDR_WRAPPER" 2>/dev/null || true
ok "xrandr original restaurado em $XRANDR_WRAPPER"
fi
fi

local real_bin=""
if [[ -s "$STATE_DIR/original_xrandr_real_path" ]]; then
real_bin=$(cat "$STATE_DIR/original_xrandr_real_path")
fi
if [[ -n "$real_bin" && -e "$real_bin" ]]; then
run mv "$real_bin" "${real_bin%.real}" 2>/dev/null || true
run chmod 755 "${real_bin%.real}" 2>/dev/null || true
restored=1
else
for real_bin in /usr/bin/xrandr.real /usr/local/bin/xrandr.real; do
if [[ -e "$real_bin" ]]; then
run mv "$real_bin" "${real_bin%.real}" 2>/dev/null || true
run chmod 755 "${real_bin%.real}" 2>/dev/null || true
restored=1
fi
done
fi

# Portas
if [[ -s "$STATE_DIR/original_port_range" ]]; then
if cat "$STATE_DIR/original_port_range" | write_file /proc/sys/net/ipv4/ip_local_port_range; then
ok "Portas efêmeras restauradas"
else
warn "Falha ao restaurar portas efêmeras"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi

# TTL
if [[ -s "$STATE_DIR/original_ttl" ]]; then
if cat "$STATE_DIR/original_ttl" | write_file /proc/sys/net/ipv4/ip_default_ttl; then
ok "TTL restaurado"
else
warn "Falha ao restaurar TTL"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi
if [[ -s "$STATE_DIR/original_hop_limit" ]]; then
if cat "$STATE_DIR/original_hop_limit" | write_file /proc/sys/net/ipv6/conf/all/hop_limit; then
ok "Hop limit restaurado"
else
warn "Falha ao restaurar hop_limit"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi

# IPv6
if [[ -s "$STATE_DIR/original_ipv6_state" ]]; then
local orig_state
orig_state=$(cat "$STATE_DIR/original_ipv6_state")
if [[ -n "$orig_state" ]]; then
if run sysctl -w net.ipv6.conf.all.disable_ipv6="$orig_state" 2>/dev/null && \
run sysctl -w net.ipv6.conf.default.disable_ipv6="$orig_state" 2>/dev/null; then
ok "IPv6 restaurado"
else
warn "Falha ao restaurar IPv6"
restore_errors=$((restore_errors + 1))
fi
restored=1
fi
fi

# Bluetooth
if [[ -s "$STATE_DIR/original_bluetooth_state" ]]; then
local orig_bt_state
orig_bt_state=$(cat "$STATE_DIR/original_bluetooth_state")
if [[ "$orig_bt_state" == "0" ]]; then
if command -v rfkill &>/dev/null; then
run rfkill unblock bluetooth 2>/dev/null || true
fi
if command -v systemctl &>/dev/null; then
run systemctl start bluetooth.service 2>/dev/null || true
fi
ok "Bluetooth reabilitado"
else
if command -v rfkill &>/dev/null; then
run rfkill block bluetooth 2>/dev/null || true
fi
ok "Bluetooth desabilitado conforme estado original"
fi
restored=1
fi

if [[ $restored -eq 0 ]]; then
warn "Nenhum backup encontrado."
elif [[ $restore_errors -gt 0 ]]; then
warn "$restore_errors operação(es) de restauração falharam. Backups mantidos em: $STATE_DIR"
warn "Corrija os erros e execute restore novamente."
run rm -f "$UPTIME_PID_FILE" "$UPTIME_OFFSET_FILE"
else
local archive_dir="$STATE_DIR/restore-archive-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$archive_dir" 2>/dev/null || true
mv "$STATE_DIR"/original_* "$archive_dir"/ 2>/dev/null || true
run rm -f "$UPTIME_PID_FILE" "$UPTIME_OFFSET_FILE"
run rm -f "$ACTIVE_PERSONA_FILE"
ok "Backups arquivados em: $archive_dir"
ok "Restauração concluída."
fi
}

