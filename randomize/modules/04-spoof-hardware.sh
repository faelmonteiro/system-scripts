#!/usr/bin/env bash
# =============================================================================
# modules/04-spoof-hardware.sh
# Mecanismos de spoofing de hardware (Disco, DMI, RAM, CPU, Bateria, Som, Kernel, Uptime, Screen, MachineID)
# =============================================================================

# ==================== SPOOF: DISCO ====================
randomize_disk_serial() {
info "Spoofando serial de disco via udev"
if command -v lsblk &>/dev/null; then
echo "  --- Seriais reais ---"
lsblk -d -o NAME,SIZE,MODEL,SERIAL 2>/dev/null || true
fi
if [[ -f "$UDEV_RULE_FILE" ]] && grep -q 'RANDOMIZE_IDS_FAKE_UDEV_RULE' "$UDEV_RULE_FILE" 2>/dev/null; then
backup_original "udev_serial" "__NONE__"
elif [[ -f "$UDEV_RULE_FILE" ]]; then
backup_original "udev_serial" "$(cat "$UDEV_RULE_FILE")"
else
backup_original "udev_serial" "__NONE__"
fi
local rules=""
local disk_found=0
local disk devname fake_serial fake_model
for disk in /dev/sd? /dev/nvme?n? /dev/vd? /dev/xvd? /dev/mmcblk?; do
[[ -e "$disk" ]] || continue
disk_found=1
devname=$(basename "$disk")
fake_serial="$(random_string 4)-$(random_string 8)"
fake_model="Generic SSD $(random_string 4)"
rules+="# Spoof para $devname"$'\n'
rules+="KERNEL==\"$devname\", ENV{ID_SERIAL}=\"$fake_serial\", ENV{ID_SERIAL_SHORT}=\"$fake_serial\", ENV{ID_MODEL}=\"$fake_model\""$'\n'
ok "[$devname] serial falso: $fake_serial | modelo falso: $fake_model"
done
if [[ $disk_found -eq 0 ]]; then
warn "Nenhum disco encontrado."
return 0
fi
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] Criaria regra udev em %s com as regras:\n%s\n' "$UDEV_RULE_FILE" "$rules"
return 0
fi
{
printf '%s\n' "# RANDOMIZE_IDS_FAKE_UDEV_RULE"
printf '%s' "$rules"
} | write_file "$UDEV_RULE_FILE" || { err "Falha ao gravar $UDEV_RULE_FILE"; return 1; }
chmod 644 "$UDEV_RULE_FILE" 2>/dev/null || true
if command -v udevadm &>/dev/null; then
run udevadm control --reload-rules 2>/dev/null || true
run udevadm trigger --subsystem-match=block 2>/dev/null || true
run udevadm settle --timeout=5 2>/dev/null || true
else
warn "udevadm não disponível. Recarregue as regras manualmente."
fi
ok "Regra udev criada: $UDEV_RULE_FILE"
warn "smartctl/hdparm ainda podem mostrar o serial real."
log_change "DISK_SERIAL|spoofed"
}

# ==================== SPOOF: DMI ====================
randomize_dmi() {
info "Spoofando DMI/SMBIOS via bind mount"
run mkdir -p "$FAKE_DMI_DIR"
chmod 700 "$FAKE_DMI_DIR" 2>/dev/null || true
local dmi_files=(
product_uuid
product_name
product_serial
board_serial
board_name
board_vendor
sys_vendor
chassis_serial
)
if [[ -z "${PERSONA_VENDOR:-}" ]]; then
PERSONA_VENDOR="Generic"
PERSONA_PRODUCT="Generic PC"
PERSONA_BOARD_VENDOR="Generic"
PERSONA_BOARD="Generic Board"
fi
echo "  Persona: ${PERSONA_VENDOR:-Generic} / ${PERSONA_PRODUCT:-Generic PC}"
local dmi_file real_path real_val fake_val
for dmi_file in "${dmi_files[@]}"; do
real_path="/sys/class/dmi/id/$dmi_file"
[[ -f "$real_path" ]] || continue
if findmnt -n "$real_path" &>/dev/null; then
warn "$dmi_file já está spoofado. Pulando."
continue
fi
real_val=$(cat "$real_path" 2>/dev/null || echo "N/A")
backup_original "dmi_$dmi_file" "$real_val"
case "$dmi_file" in
product_uuid)
fake_val=$(cat /proc/sys/kernel/random/uuid)
;;
product_name)
fake_val="$PERSONA_PRODUCT"
;;
board_name)
fake_val="$PERSONA_BOARD"
;;
board_vendor)
fake_val="$PERSONA_BOARD_VENDOR"
;;
sys_vendor)
fake_val="$PERSONA_VENDOR"
;;
*_serial)
fake_val="$(random_string 4)-$(random_string 8)-$(random_string 4)"
;;
*)
fake_val="$(random_string 12)"
;;
esac
printf '%s\n' "$fake_val" | write_file "$FAKE_DMI_DIR/$dmi_file"
if [[ "$dmi_file" == "product_uuid" ]]; then
run chmod 600 "$FAKE_DMI_DIR/$dmi_file" 2>/dev/null || true
else
run chmod 644 "$FAKE_DMI_DIR/$dmi_file" 2>/dev/null || true
fi
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] %s: %s -> %s\n' "$dmi_file" "$real_val" "$fake_val"
else
run mount --bind "$FAKE_DMI_DIR/$dmi_file" "$real_path" 2>/dev/null
if findmnt -n "$real_path" &>/dev/null; then
ok "$dmi_file: $real_val -> $fake_val"
else
warn "$dmi_file: falha no bind mount"
fi
fi
done
log_change "DMI|spoofed"
}

# ==================== SPOOF: RAM ====================
randomize_ram() {
info "Spoofando RAM via bind mount"
if findmnt -n /proc/meminfo &>/dev/null; then
warn "RAM já está spoofada. Use restore primeiro."
return 0
fi
local real_total fake_total ratio idx
real_total=$(grep '^MemTotal:' /proc/meminfo | LC_ALL=C awk '{print $2}')
if [[ -z "$real_total" || "$real_total" == "0" ]]; then
real_total=1
fi
backup_original "meminfo" "$(cat /proc/meminfo)"
backup_original "ram_total" "$real_total"
local ram_options=(8388608 16777216 33554432 67108864)
idx=$(( $(rand_u32) % ${#ram_options[@]} ))
fake_total=${PERSONA_RAM:-${ram_options[$idx]}}
ratio=$(LC_ALL=C awk -v fake="$fake_total" -v real="$real_total" 'BEGIN {printf "%.6f", fake/real}')
echo "  RAM real: $((real_total / 1024)) MB"
echo "  RAM falsa: $((fake_total / 1024)) MB"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] bind mount /proc/meminfo\n'
return 0
fi
ensure_state
if LC_ALL=C awk -v ratio="$ratio" -v fake_total="$fake_total" '
{
if ($1 == "MemTotal:") {
printf "%-16s %8d kB\n", $1, fake_total
} else if ($3 == "kB" && $2 ~ /^[0-9]+$/) {
val = int($2 * ratio)
if (val < 0) val = 0
printf "%-16s %8d kB\n", $1, val
} else {
print $0
}
}
' /proc/meminfo > "$FAKE_RAM_FILE"; then
chmod 644 "$FAKE_RAM_FILE" 2>/dev/null || true
run mount --bind "$FAKE_RAM_FILE" /proc/meminfo 2>/dev/null
if findmnt -n /proc/meminfo &>/dev/null; then
ok "/proc/meminfo spoofado"
else
err "Falha no bind mount de /proc/meminfo"
return 1
fi
else
err "Falha ao gerar meminfo falso"
return 1
fi
log_change "RAM|spoofed"
}

# ==================== SPOOF: CPU ====================
randomize_cpu() {
info "Spoofando CPU via bind mount"
if findmnt -n /proc/cpuinfo &>/dev/null; then
warn "CPU já está spoofada. Use restore primeiro."
return 0
fi
backup_original "cpuinfo" "$(cat /proc/cpuinfo)"
local fake_cpu="${PERSONA_CPU:-Intel(R) Core(TM) i5-10400 CPU @ 2.90GHz}"
echo "  CPU falsa: $fake_cpu"
warn "Apenas model name em /proc/cpuinfo é alterado."
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] bind mount /proc/cpuinfo\n'
return 0
fi
ensure_state
LC_ALL=C awk -v cpu="$fake_cpu" '
/^model name/ {
print "model name\t: " cpu
next
}
{ print }
' /proc/cpuinfo > "$FAKE_CPU_FILE"
chmod 644 "$FAKE_CPU_FILE" 2>/dev/null || true
run mount --bind "$FAKE_CPU_FILE" /proc/cpuinfo 2>/dev/null
if findmnt -n /proc/cpuinfo &>/dev/null; then
ok "/proc/cpuinfo spoofado"
else
err "Falha no bind mount de /proc/cpuinfo"
return 1
fi
log_change "CPU|spoofed"
}

# ==================== SPOOF: BATERIA ====================
randomize_battery() {
info "Spoofando bateria via bind mount"
local bat
local found=0
for bat in /sys/class/power_supply/BAT*; do
[[ -d "$bat" ]] || continue
found=1
local f real_val fake_val
for f in serial_number model_name manufacturer; do
[[ -f "$bat/$f" ]] || continue
if findmnt -n "$bat/$f" &>/dev/null; then
warn "$bat/$f já está spoofado."
continue
fi
real_val=$(cat "$bat/$f" 2>/dev/null || echo "N/A")
backup_original "bat_${f}" "$real_val"
if [[ "$f" == "serial_number" ]]; then
fake_val="$(random_string 8)"
elif [[ "$f" == "model_name" ]]; then
fake_val="Generic Battery"
else
fake_val="Generic OEM"
fi
local fake_file="$STATE_DIR/fake_bat_${f}"
printf '%s\n' "$fake_val" | write_file "$fake_file"
chmod 644 "$fake_file" 2>/dev/null || true
if [[ $DRY_RUN -eq 0 ]]; then
run mount --bind "$fake_file" "$bat/$f" 2>/dev/null || true
if findmnt -n "$bat/$f" &>/dev/null; then
ok "$bat/$f: $real_val -> $fake_val"
fi
else
printf '[DRY-RUN] %s/%s: %s -> %s\n' "$bat" "$f" "$real_val" "$fake_val"
fi
done
done
if [[ $found -eq 0 ]]; then
info "Nenhuma bateria (BAT*) encontrada neste sistema."
else
log_change "BATTERY|spoofed"
fi
}

# ==================== SPOOF: SOM (ALSA) ====================
randomize_sound() {
info "Spoofando placas de som via bind mount (/proc/asound/cards)"
if [[ ! -f /proc/asound/cards ]]; then
return 0
fi
if findmnt -n /proc/asound/cards &>/dev/null; then
warn "/proc/asound/cards já está spoofado."
return 0
fi
backup_original "asound_cards" "$(cat /proc/asound/cards)"
local fake_sound_file="$STATE_DIR/fake_asound_cards"
{
echo " 0 [Audio          ]: HDA-Intel - HDA Generic"
echo "                      HDA Generic at 0xf7d10000 irq 45"
} | write_file "$fake_sound_file"
chmod 644 "$fake_sound_file" 2>/dev/null || true
if [[ $DRY_RUN -eq 0 ]]; then
run mount --bind "$fake_sound_file" /proc/asound/cards 2>/dev/null
if findmnt -n /proc/asound/cards &>/dev/null; then
ok "/proc/asound/cards spoofado para áudio genérico"
log_change "SOUND|spoofed"
else
warn "Falha ao aplicar bind mount em /proc/asound/cards"
fi
else
printf '[DRY-RUN] bind mount /proc/asound/cards\n'
fi
}

# ==================== SPOOF: KERNEL VERSION ====================
randomize_kernel_version() {
info "Spoofando versão do kernel via bind mount (/proc/version)"
if [[ ! -f /proc/version ]]; then
return 0
fi
if findmnt -n /proc/version &>/dev/null; then
warn "/proc/version já está spoofado."
return 0
fi
backup_original "proc_version" "$(cat /proc/version)"
local fake_ver_file="$STATE_DIR/fake_proc_version"
printf '%s\n' "Linux version 6.1.0-generic (build@compiler) (gcc 12.2.0) #1 SMP PREEMPT_DYNAMIC" | write_file "$fake_ver_file"
chmod 644 "$fake_ver_file" 2>/dev/null || true
if [[ $DRY_RUN -eq 0 ]]; then
run mount --bind "$fake_ver_file" /proc/version 2>/dev/null
if findmnt -n /proc/version &>/dev/null; then
ok "/proc/version spoofado"
log_change "KERNEL_VERSION|spoofed"
else
warn "Falha no bind mount de /proc/version"
fi
else
printf '[DRY-RUN] bind mount /proc/version\n'
fi
}

# ==================== SPOOF: UPTIME ====================
_start_uptime_updater() {
local fake_file="$1"
local offset="$2"
local cpus boot_time
cpus=$(nproc 2>/dev/null || echo 1)
boot_time=$(LC_ALL=C awk '/^btime/{print $2}' /proc/stat)
trap 'exit 0' TERM INT EXIT
while true; do
[[ -f "$UPTIME_PID_FILE" ]] || break
LC_ALL=C awk -v now="$(date +%s)" -v boot="$boot_time" -v off="$offset" -v cpus="$cpus" '
BEGIN {
real = now - boot
up = real + off
if (up < 1) up = 1
idle = up * 0.7 * cpus
if (idle < 0) idle = 0
printf "%.2f %.2f\n", up, idle
}
' > "$fake_file" 2>/dev/null || break
sleep 3
done
}

randomize_uptime() {
info "Spoofando Uptime"
if findmnt -n /proc/uptime &>/dev/null; then
warn "Uptime já está spoofado. Use restore primeiro."
return 0
fi
backup_original "uptime" "$(cat /proc/uptime)"
local now boot_time real_secs fake_secs offset days hours cpus fake_idle
now=$(date +%s)
boot_time=$(LC_ALL=C awk '/^btime/{print $2}' /proc/stat)
real_secs=$((now - boot_time))
fake_secs=$((3600 + $(rand_u32) % 2592000))
offset=$((fake_secs - real_secs))
days=$((fake_secs / 86400))
hours=$(( (fake_secs % 86400) / 3600 ))
echo "  Uptime falso: ${days}d ${hours}h"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] bind mount /proc/uptime + updater\n'
return 0
fi
ensure_state
stop_uptime_updater
cpus=$(nproc 2>/dev/null || echo 1)
fake_idle=$(LC_ALL=C awk -v secs="$fake_secs" -v cpus="$cpus" 'BEGIN {printf "%.2f", secs*0.7*cpus}')
echo "${fake_secs}.00 $fake_idle" > "$FAKE_UPTIME_FILE"
chmod 644 "$FAKE_UPTIME_FILE" 2>/dev/null || true
run mount --bind "$FAKE_UPTIME_FILE" /proc/uptime 2>/dev/null
if findmnt -n /proc/uptime &>/dev/null; then
echo "$offset" > "$UPTIME_OFFSET_FILE"
_start_uptime_updater "$FAKE_UPTIME_FILE" "$offset" &
echo "$!" > "$UPTIME_PID_FILE"
disown "$!" 2>/dev/null || true
ok "/proc/uptime spoofado dinamicamente"
else
err "Falha no bind mount de /proc/uptime"
return 1
fi
log_change "UPTIME|spoofed"
}

# ==================== SPOOF: MACHINE-ID ====================
randomize_machineid() {
info "Randomizando Machine-ID"
warn "Alterar machine-id em runtime pode quebrar D-Bus, journald, NetworkManager e apps licenciados."
if ! ask_yes "Continuar?"; then
info "Cancelado."
return 0
fi
local old_id="" new_id
if [[ -f /etc/machine-id ]]; then
backup_original "machine_id" "$(cat /etc/machine-id)"
old_id=$(cat /etc/machine-id)
fi
if [[ -f /var/lib/dbus/machine-id ]]; then
backup_original "dbus_machine_id" "$(cat /var/lib/dbus/machine-id)"
fi
new_id=$(od -An -tx1 -N16 /dev/urandom | tr -d '[:space:]')
if [[ ${#new_id} -ne 32 ]]; then
err "Falha ao gerar machine-id."
return 1
fi
write_str "/etc/machine-id" "$new_id"
chmod 444 /etc/machine-id 2>/dev/null || true
if [[ -f /var/lib/dbus/machine-id && ! -L /var/lib/dbus/machine-id ]]; then
write_str "/var/lib/dbus/machine-id" "$new_id"
chmod 444 /var/lib/dbus/machine-id 2>/dev/null || true
fi
ok "${old_id:-N/A} -> $new_id"
warn "Pode ser necessário logout/reboot para alguns serviços."
log_change "MACHINEID|$new_id"
}

# ==================== SPOOF: SCREEN ====================
randomize_screen() {
info "Spoofando resolução de tela via xrandr"
if [[ -n "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
warn "Wayland puro detectado. Wrapper xrandr não afeta apps nativos Wayland."
if ! ask_yes "Continuar?"; then
info "Cancelado."
return 0
fi
fi
local real_xrandr
real_xrandr=$(command -v xrandr 2>/dev/null || true)
if [[ "$real_xrandr" == "$XRANDR_WRAPPER" ]]; then
if [[ -x /usr/bin/xrandr ]]; then
real_xrandr="/usr/bin/xrandr"
else
warn "xrandr resolve para o wrapper e o binário real não foi encontrado. Pulando."
return 0
fi
fi
if [[ -z "$real_xrandr" ]]; then
warn "xrandr não encontrado. Pulando."
return 0
fi
if [[ -f "$XRANDR_WRAPPER" ]] && grep -q 'FAKE_XRANDR' "$XRANDR_WRAPPER" 2>/dev/null; then
warn "Wrapper xrandr já instalado."
return 0
fi
if [[ -e "$XRANDR_WRAPPER" ]] && ! grep -q 'FAKE_XRANDR' "$XRANDR_WRAPPER" 2>/dev/null; then
warn "Arquivo existente em $XRANDR_WRAPPER não é o wrapper fake. Fazendo backup antes de sobrescrever."
local xrandr_pre_backup="${XRANDR_WRAPPER}.backup.$(date +%Y%m%d%H%M%S)"
run cp -a "$XRANDR_WRAPPER" "$xrandr_pre_backup"
backup_original "xrandr_usr_local_backup" "$xrandr_pre_backup"
fi
backup_original "xrandr_path" "$real_xrandr"
local res_list=("1920x1080" "2560x1440" "1366x768" "1920x1200" "3840x2160" "1680x1050" "1440x900")
local idx fake_res fake_w fake_h
idx=$(( $(rand_u32) % ${#res_list[@]} ))
fake_res="${res_list[$idx]}"
fake_w="${fake_res%x*}"
fake_h="${fake_res#*x}"
echo "  Resolução falsa: $fake_res"
local real_backup="${real_xrandr}.real"
if [[ ! -e "$real_backup" ]]; then
run cp -a "$real_xrandr" "$real_backup"
backup_original "xrandr_real_path" "$real_backup"
fi
local real_bin="$real_backup"
local wrapper_content
wrapper_content=$(cat <<EOF
#!/bin/bash
# FAKE_XRANDR wrapper - gerado por randomize_ids.sh
# FAKE_RES="$fake_res"
set -o pipefail
REAL_XRANDR="$real_bin"
if echo "\$*" | grep -qE -- '--output|--mode|--rate|--pos|--rotate|--reflect|--off|--auto|--scale|--transform|--help|--version'; then
exec "\$REAL_XRANDR" "\$@"
fi
"\$REAL_XRANDR" "\$@" 2>/dev/null | sed -E \\
-e "s/[0-9]+x[0-9]+ +[0-9]+\\.[0-9]+[*+]+/$fake_res 60.00*/" \\
-e "s/current [0-9]+ x [0-9]+/current $fake_w x $fake_h/"
EOF
)
printf '%s\n' "$wrapper_content" | write_file "$XRANDR_WRAPPER"
run chmod 755 "$XRANDR_WRAPPER" 2>/dev/null || true
ok "Wrapper instalado em: $XRANDR_WRAPPER"
warn "Se /usr/local/bin não estiver antes no PATH, o wrapper pode não ser usado."
log_change "SCREEN|$fake_res"
}

