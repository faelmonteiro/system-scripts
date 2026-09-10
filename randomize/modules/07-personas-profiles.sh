#!/usr/bin/env bash
# =============================================================================
# modules/07-personas-profiles.sh
# Definição de personas pré-configuradas e gerenciamento de perfis de identidade
# =============================================================================

# ==================== PERSONAS ====================
get_persona() {
local choice="${1:-random}"
local personas=(
"us-office|Dell Inc.|OptiPlex 7090|Dell Inc.|0KWVT8|America/New_York|en_US.UTF-8|33554432|Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz"
"us-dev|Lenovo|ThinkStation P340|Lenovo|30E9|America/Los_Angeles|en_US.UTF-8|67108864|AMD Ryzen 9 5900X 12-Core Processor"
"eu-office|HP|ProDesk 400 G7|HP|8054|Europe/Berlin|de_DE.UTF-8|16777216|Intel(R) Core(TM) i5-12400F CPU @ 2.50GHz"
"br-home|ASUSTeK Computer Inc.|ASUS ExpertCenter D500|ASUSTeK Computer Inc.|PRIME-B550M-K|America/Sao_Paulo|pt_BR.UTF-8|16777216|AMD Ryzen 5 5600X 6-Core Processor"
)
if [[ "$choice" == "random" ]]; then
local idx
idx=$(( $(rand_u32) % ${#personas[@]} ))
echo "${personas[$idx]}"
return 0
fi
local p
for p in "${personas[@]}"; do
if [[ "$p" == "$choice|"* ]]; then
echo "${p}"
return 0
fi
done
echo ""
}

apply_persona() {
local p_name="${1:-random}"
local p_data
p_data=$(get_persona "$p_name")
if [[ -z "$p_data" ]]; then
err "Persona '$p_name' não encontrada."
return 1
fi
local P_ID P_VENDOR P_PRODUCT P_BOARD_VENDOR P_BOARD_NAME P_TZ P_LOCALE P_RAM P_CPU
IFS='|' read -r P_ID P_VENDOR P_PRODUCT P_BOARD_VENDOR P_BOARD_NAME P_TZ P_LOCALE P_RAM P_CPU <<< "$p_data"
info "Aplicando persona: $P_ID"
export PERSONA_VENDOR="$P_VENDOR"
export PERSONA_PRODUCT="$P_PRODUCT"
export PERSONA_BOARD_VENDOR="$P_BOARD_VENDOR"
export PERSONA_BOARD="$P_BOARD_NAME"
export PERSONA_RAM="$P_RAM"
export PERSONA_CPU="$P_CPU"
local current_tz current_locale
current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "desconhecido")
backup_original "timezone" "$current_tz"
if command -v localectl &>/dev/null; then
current_locale=$(localectl status 2>/dev/null | awk -F= '/LANG=/{print $2}')
backup_original "locale" "${current_locale:-__NONE__}"
fi
randomize_dmi
randomize_cpu
randomize_ram
run timedatectl set-timezone "$P_TZ" 2>/dev/null || true
ok "Timezone: $P_TZ"
if [[ -n "$P_LOCALE" ]] && command -v localectl &>/dev/null; then
run localectl set-locale "LANG=$P_LOCALE" 2>/dev/null || true
ok "Locale: $P_LOCALE (pode exigir logout)"
fi
write_str "$ACTIVE_PERSONA_FILE" "$P_ID"
chmod 600 "$ACTIVE_PERSONA_FILE" 2>/dev/null || true
unset PERSONA_VENDOR PERSONA_PRODUCT PERSONA_BOARD_VENDOR PERSONA_BOARD PERSONA_RAM PERSONA_CPU
ok "Persona aplicada: $P_ID"
}

# ==================== PERFIS ====================
save_profile() {
local name="${1:-default}"
if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
die "Nome de perfil inválido: '$name' (use apenas letras, números, ., _ ou -)"
fi
local pdir="$PROFILE_DIR/$name"
run mkdir -p "$pdir"
chmod 700 "$pdir" 2>/dev/null || true
info "Salvando perfil: $name"
hostname | write_file "$pdir/hostname"
local iface iname
for iface in /sys/class/net/*/device; do
[[ -e "$iface" ]] || continue
iname=$(echo "$iface" | cut -d'/' -f5)
cat "/sys/class/net/$iname/address" | write_file "$pdir/mac_$iname"
done
if [[ -f /etc/resolv.conf ]]; then
run cp /etc/resolv.conf "$pdir/resolv.conf"
fi
timedatectl show -p Timezone --value 2>/dev/null | write_file "$pdir/timezone"
cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null | write_file "$pdir/ttl"
cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null | write_file "$pdir/port_range"
cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null | write_file "$pdir/ipv6_state"
if [[ -f "$ACTIVE_PERSONA_FILE" ]]; then
run cp "$ACTIVE_PERSONA_FILE" "$pdir/active_persona"
fi
ok "Perfil salvo em: $pdir"
}

load_profile() {
local name="${1:-default}"
if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
die "Nome de perfil inválido: '$name' (use apenas letras, números, ., _ ou -)"
fi
local pdir="$PROFILE_DIR/$name"
if [[ ! -d "$pdir" ]]; then
err "Perfil '$name' não encontrado."
list_profiles
return 1
fi
info "Carregando perfil: $name"
warn "Bind mounts de DMI/RAM/CPU/uptime não são restaurados automaticamente por perfil."
backup_current_if_missing "hostname" "$(hostname)"
if [[ -f /etc/hosts ]]; then
backup_current_if_missing "hosts" "$(cat /etc/hosts)"
fi
if [[ -f /etc/resolv.conf ]]; then
backup_current_if_missing "dns" "$(cat /etc/resolv.conf)"
fi
backup_current_if_missing "timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "desconhecido")"
backup_current_if_missing "ttl" "$(cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null)"
backup_current_if_missing "port_range" "$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)"
backup_current_if_missing "ipv6_state" "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)"
local h tz macfile iface_name mac
if [[ -s "$pdir/hostname" ]]; then
h=$(cat "$pdir/hostname")
if ! valid_hostname "$h"; then
warn "Hostname inválido no perfil: $h. Usando hostname atual."
h="$(hostname)"
fi
set_hostname_safe "$h"
write_str "/etc/hostname" "$h"
chmod 644 /etc/hostname 2>/dev/null || true
if [[ -f /etc/hosts ]]; then
backup_current_if_missing "hosts" "$(cat /etc/hosts)"
if grep -qE '^[[:space:]]*127\.0\.1\.1' /etc/hosts; then
run sed -i -E "s/^([[:space:]]*127\.0\.1\.1[[:space:]]+)[^[:space:]]+/\1$h/" /etc/hosts
else
append_str "/etc/hosts" "127.0.1.1 $h"
fi
fi
ok "Hostname: $h"
fi
for macfile in "$pdir"/mac_*; do
[[ -s "$macfile" ]] || continue
iface_name=$(basename "$macfile" | sed 's/^mac_//')
mac=$(cat "$macfile")
run ip link set dev "$iface_name" down 2>/dev/null || true
run ip link set dev "$iface_name" address "$mac" 2>/dev/null || true
run ip link set dev "$iface_name" up 2>/dev/null || true
ok "MAC [$iface_name]: $mac"
done
if [[ -s "$pdir/resolv.conf" ]]; then
run cp "$pdir/resolv.conf" /etc/resolv.conf
chmod 644 /etc/resolv.conf 2>/dev/null || true
ok "DNS restaurado"
fi
if [[ -s "$pdir/timezone" ]]; then
tz=$(cat "$pdir/timezone")
run timedatectl set-timezone "$tz" 2>/dev/null || true
ok "Timezone: $tz"
fi
if [[ -s "$pdir/ttl" ]]; then
cat "$pdir/ttl" | write_file /proc/sys/net/ipv4/ip_default_ttl
fi
if [[ -s "$pdir/port_range" ]]; then
cat "$pdir/port_range" | write_file /proc/sys/net/ipv4/ip_local_port_range
fi
if [[ -s "$pdir/ipv6_state" ]]; then
cat "$pdir/ipv6_state" | write_file /proc/sys/net/ipv6/conf/all/disable_ipv6
fi
if [[ -s "$pdir/active_persona" ]]; then
local persona_name
persona_name=$(cat "$pdir/active_persona")
run cp "$pdir/active_persona" "$ACTIVE_PERSONA_FILE"
chmod 600 "$ACTIVE_PERSONA_FILE" 2>/dev/null || true
if ask_yes "Aplicar persona salva '$persona_name' agora?"; then
apply_persona "$persona_name"
fi
fi
ok "Perfil carregado: $name"
}

list_profiles() {
info "Perfis salvos"
if [[ -d "$PROFILE_DIR" ]] && [[ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]]; then
local pdir name
for pdir in "$PROFILE_DIR"/*/; do
name=$(basename "$pdir")
echo "  - $name"
[[ -f "$pdir/hostname" ]] && echo "      Hostname: $(cat "$pdir/hostname")"
done
else
echo "  Nenhum perfil salvo."
fi
}

