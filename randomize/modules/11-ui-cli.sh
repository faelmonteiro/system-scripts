#!/usr/bin/env bash
# =============================================================================
# modules/11-ui-cli.sh
# Interface interativa TUI (menus FZF/Read), modos compostos (all, paranoid) e dispatcher CLI
# =============================================================================

randomize_all() {
randomize_mac
randomize_hostname
randomize_dns
randomize_timezone
echo
randomize_disk_serial
randomize_dmi
randomize_ram
randomize_machineid
randomize_screen
randomize_cpu
randomize_uptime
randomize_battery
randomize_sound
randomize_kernel_version
echo
randomize_network
}

randomize_all_with_user() {
randomize_all
echo
randomize_username
}

paranoid_mode() {
info "MODO PARANOID"
randomize_all
echo
clean_traces "--all"
echo
start_auto
echo
ok "Sistema randomizado + MAC auto ativo."
echo "  Para parar tudo: sudo $0 restore"
}

# ==================== MENU ====================
clear_screen() {
printf '\033[2J\033[H'
}

pause_menu() {
echo
read -r -p "Pressione ENTER para voltar ao menu..." || return
}

root_action() {
if [[ $EUID -ne 0 ]]; then
warn "Você precisa ser root para fazer isso."
return 1
fi
"$@"
}

status_indicator() {
local val="${2:-$1}"
if [[ "$val" == "1" ]]; then
printf '%s\n' "${GREEN}${ICON_OK}${NC}"
else
printf '%s\n' "${GRAY}${ICON_OFF}${NC}"
fi
}

draw_header() {
echo
printf '%s\n' "  ${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
printf '%s\n' "  ${CYAN}${BOLD}║${NC}  ${MAGENTA}${BOLD}${ICON_SHIELD} RANDOMIZE IDS v${VERSION} ${ICON_SHIELD}${NC}                  ${CYAN}${BOLD}║${NC}"
printf '%s\n' "  ${CYAN}${BOLD}║${NC}  ${DIM}Randomizador de Identificadores do Sistema${NC}         ${CYAN}${BOLD}║${NC}"
printf '%s\n' "  ${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo
}

draw_menu() {
local s_mac s_host s_dns s_tz s_disk s_dmi s_ram s_mid s_scr
local s_cpu s_upt s_ports s_ttl s_ipv6 s_bt s_user s_auto active=0 s
s_mac=$(check_mac_spoofed)
s_host=$(check_hostname_spoofed)
s_dns=$(check_dns_spoofed)
s_tz=$(check_tz_spoofed)
s_disk=$(check_disk_spoofed)
s_dmi=$(check_dmi_spoofed)
s_ram=$(check_ram_spoofed)
s_mid=$(check_machineid_spoofed)
s_scr=$(check_screen_spoofed)
s_cpu=$(check_cpu_spoofed)
s_upt=$(check_uptime_spoofed)
s_ports=$(check_ports_spoofed)
s_ttl=$(check_ttl_spoofed)
s_ipv6=$(check_ipv6_disabled)
s_bt=$(check_bluetooth_disabled)
s_user=$(check_user_spoofed)
s_auto=$(check_auto_running)
for s in $s_mac $s_host $s_dns $s_tz $s_disk $s_dmi $s_ram $s_mid $s_scr $s_cpu $s_upt $s_ports $s_ttl $s_ipv6 $s_bt $s_user; do
[[ "$s" == "1" ]] && active=$((active + 1))
done
printf '%s\n' "  ${WHITE}${BOLD}${ICON_GEARS} IDENTIDADE DO SISTEMA${NC}          ${DIM}[$active/16 spoofs ativos]${NC}"
printf '%s\n' "  ${GRAY}─────────────────────────────────────────────────────${NC}"
echo
printf '%s\n' "  ${YELLOW}${BOLD}${ICON_HOST} Identidade básica:${NC}"
printf '%s\n' "    $(status_indicator mac "$s_mac")  ${WHITE} 1${NC} › ${ICON_MAC} MAC Address"
printf '%s\n' "    $(status_indicator host "$s_host")  ${WHITE} 2${NC} › ${ICON_HOST} Hostname"
printf '%s\n' "    $(status_indicator dns "$s_dns")  ${WHITE} 3${NC} › ${ICON_DNS} DNS"
printf '%s\n' "    $(status_indicator tz "$s_tz")  ${WHITE} 4${NC} › ${ICON_TZ} Timezone"
echo
printf '%s\n' "  ${MAGENTA}${BOLD}${ICON_SCREEN} Spoof de hardware:${NC}"
printf '%s\n' "    $(status_indicator disk "$s_disk")  ${WHITE} 5${NC} › ${ICON_DISK} Serial do disco"
printf '%s\n' "    $(status_indicator dmi "$s_dmi")  ${WHITE} 6${NC} › ${ICON_DMI} DMI/SMBIOS"
printf '%s\n' "    $(status_indicator ram "$s_ram")  ${WHITE} 7${NC} › ${ICON_RAM} RAM"
printf '%s\n' "    $(status_indicator mid "$s_mid")  ${WHITE} 8${NC} › ${ICON_MID} Machine-ID"
printf '%s\n' "    $(status_indicator scr "$s_scr")  ${WHITE} 9${NC} › ${ICON_SCREEN} Tela"
printf '%s\n' "    $(status_indicator cpu "$s_cpu")  ${WHITE}10${NC} › ${ICON_CPU} CPU"
printf '%s\n' "    $(status_indicator upt "$s_upt")  ${WHITE}11${NC} › ${ICON_UPTIME} Uptime"
printf '%s\n' "    $(status_indicator user "$s_user")  ${WHITE}12${NC} › ${ICON_USER} Usuário temporário"
echo
printf '%s\n' "  ${BLUE}${BOLD}${ICON_NETWORK} Rede:${NC}"
printf '%s\n' "    $(status_indicator ports "$s_ports")  ${WHITE}13${NC} › ${ICON_PORTS} Portas efêmeras"
printf '%s\n' "    $(status_indicator ttl "$s_ttl")  ${WHITE}14${NC} › ${ICON_TTL} TTL"
printf '%s\n' "    $(status_indicator ipv6 "$s_ipv6")  ${WHITE}15${NC} › ${ICON_IPV6} IPv6"
printf '%s\n' "    $(status_indicator bt "$s_bt")  ${WHITE}16${NC} › ${ICON_BT} Bluetooth"
echo
printf '%s\n' "  ${GRAY}─────────────────────────────────────────────────────${NC}"
echo
printf '%s\n' "  ${GREEN}${BOLD}${ICON_GEARS} Ações:${NC}"
printf '%s\n' "    ${WHITE}A${NC} › ${ICON_ALL} Aplicar TUDO       ${WHITE}P${NC} › ${ICON_PARANOID} ${RED}${BOLD}PARANOID${NC}"
printf '%s\n' "    ${WHITE}R${NC} › ${ICON_RESTORE} Restaurar tudo     ${WHITE}N${NC} › ${ICON_NETWORK} Rede (ports+ttl+ipv6+bt)"
echo
printf '%s\n' "  ${CYAN}${BOLD}${ICON_TOOLS} Ferramentas:${NC}"
if [[ "$s_auto" == "1" ]]; then
printf '%s\n' "    ${WHITE}M${NC} › ${ICON_AUTO} MAC auto ${GREEN}[ATIVO]${NC}   ${WHITE}X${NC} › ${ICON_STOP} Parar MAC auto"
else
printf '%s\n' "    ${WHITE}M${NC} › ${ICON_AUTO} Iniciar MAC auto"
printf '%s\n' "    ${WHITE}X${NC} › ${ICON_STOP} Parar MAC auto"
fi
printf '%s\n' "    ${WHITE}S${NC} › ${ICON_STATUS} Status             ${WHITE}L${NC} › ${ICON_LOG} Log"
printf '%s\n' "    ${WHITE}C${NC} › ${ICON_CLEAN} Limpar rastros     ${WHITE}F${NC} › ${ICON_PROFILE} Perfis"
printf '%s\n' "    ${WHITE}V${NC} › ${ICON_VERIFY} Verificar spoofs   ${WHITE}U${NC} › ${ICON_UNINSTALL} Uninstall"
printf '%s\n' "    ${WHITE}H${NC} › ${ICON_HARDEN} Hardening          ${WHITE}I${NC} › ${ICON_HARDEN_UNDO} Hardening undo"
printf '%s\n' "    ${WHITE}K${NC} › ${ICON_LEAK} Leak test          ${WHITE}B${NC} › ${ICON_BROWSER} Browser check"
printf '%s\n' "    ${WHITE}D${NC} › ${ICON_WARN} Disclaimer"
echo
printf '%s\n' "    ${WHITE}0${NC} › ${ICON_EXIT} Sair"
echo
}

profile_menu() {
echo
printf '%s\n' "  ${CYAN}${BOLD}${ICON_PROFILE} Perfis:${NC}"
echo "    1) ${ICON_SAVE} Salvar"
echo "    2) ${ICON_LOAD} Carregar"
echo "    3) ${ICON_LIST} Listar"
echo "    0) ${ICON_BACK} Voltar"
echo
local prof_choice
read -r -p "  Opção: " prof_choice || return
case "$prof_choice" in
1)
read -r -p "  Nome do perfil (ENTER=default): " pname || return
save_profile "${pname:-default}"
;;
2)
list_profiles
read -r -p "  Nome para carregar: " pname || return
[[ -n "$pname" ]] && load_profile "$pname"
;;
3)
list_profiles
;;
esac
}

interactive_menu() {
local choice
while true; do
clear_screen
draw_header
draw_menu
read -r -p "  Escolha uma opção: " choice || exit 0
case "$choice" in
1) root_action randomize_mac; pause_menu ;;
2) root_action randomize_hostname; pause_menu ;;
3) root_action randomize_dns; pause_menu ;;
4) root_action randomize_timezone; pause_menu ;;
5) root_action randomize_disk_serial; pause_menu ;;
6) root_action randomize_dmi; pause_menu ;;
7) root_action randomize_ram; pause_menu ;;
8) root_action randomize_machineid; pause_menu ;;
9) root_action randomize_screen; pause_menu ;;
10) root_action randomize_cpu; pause_menu ;;
11) root_action randomize_uptime; pause_menu ;;
12) root_action randomize_username; pause_menu ;;
13) root_action randomize_ports; pause_menu ;;
14) root_action randomize_ttl; pause_menu ;;
15)
if [[ "$(check_ipv6_disabled)" == "1" ]]; then
root_action toggle_ipv6 enable
else
root_action toggle_ipv6 disable
fi
pause_menu
;;
16)
if [[ "$(check_bluetooth_disabled)" == "1" ]]; then
root_action toggle_bluetooth enable
else
root_action toggle_bluetooth disable
fi
pause_menu
;;
[aA]) root_action randomize_all; pause_menu ;;
[pP]) root_action paranoid_mode; pause_menu ;;
[rR])
if ask_yes "Restaurar tudo?"; then
root_action restore_all
fi
pause_menu
;;
[nN]) root_action randomize_network; pause_menu ;;
[mM])
if [[ "$(check_auto_running)" == "1" ]]; then
if ask_yes "MAC auto ativo. Parar?"; then
root_action stop_auto
fi
else
local interval_input
read -r -p "  Intervalo em segundos (ENTER=420): " interval_input || interval_input=""
root_action start_auto "${interval_input:-}"
fi
pause_menu
;;
[xX]) root_action stop_auto; pause_menu ;;
[sS]) show_status; pause_menu ;;
[lL]) root_action show_log; pause_menu ;;
[cC]) root_action clean_traces "--all"; pause_menu ;;
[fF]) root_action profile_menu; pause_menu ;;
[vV]) root_action verify_spoofs; pause_menu ;;
[uU]) root_action uninstall_components; pause_menu ;;
[hH]) root_action harden_system; pause_menu ;;
[iI]) root_action harden_undo; pause_menu ;;
[kK]) run_leak_test; pause_menu ;;
[bB]) show_browser_check; pause_menu ;;
[dD]) show_disclaimer; pause_menu ;;
0|[qQ])
clear_screen
printf '%s\n' "  ${DIM}Até mais! ${ICON_SHIELD}${NC}"
echo
exit 0
;;
*)
;;
esac
done
}

# ==================== HELP / VERSION ====================
show_help() {
cat <<'EOF'
Uso:
  sudo ./randomize-ids.sh [opções] [comando]
Comandos:
  mac, hostname, dns, timezone, disk, dmi, ram, cpu, uptime
  machineid, screen, user, ports, ttl, ipv6, bluetooth, network
  all, all-user, paranoid, restore, status, verify, clean
  auto [segundos], stop, log
  persona [list|apply] [nome]
  profile [save|load|list] [nome]
  harden, harden-undo
  uninstall [--restore] [--purge]
  rotate-quiet
  version, help
Opções globais:
  --dry-run, -n      Simula ações sem alterar o sistema
  --yes, -y          Confirma automaticamente
  --debug            Ativa trace (set -x)
Variáveis de ambiente:
  RANDOMIZE_INTERVAL            Intervalo do MAC auto em segundos (padrão 420)
  RANDOMIZE_IFACES              Lista de interfaces para alterar (ex: eth0,wlan0)
  RANDOMIZE_EXCLUDE_IFACES      Lista de interfaces para não alterar (ex: eth0)
  RANDOMIZE_ALLOW_DEFAULT_IFACE Se 1, permite alterar interface default (padrão 0)
  RANDOMIZE_NO_EMOJI            Se 1, usa ícones ASCII em vez de emojis
  NO_COLOR                      Se definido, desativa cores
Exemplos:
  sudo ./randomize-ids.sh
  sudo ./randomize-ids.sh --dry-run all
  sudo ./randomize-ids.sh paranoid --yes
  sudo ./randomize-ids.sh status --json
  sudo ./randomize-ids.sh restore
  sudo ./randomize-ids.sh auto 300
Aviso:
  Esta ferramenta não fornece anonimato completo.
  Use apenas em sistemas próprios ou autorizados.
EOF
}

show_version() {
echo "randomize_ids $VERSION"
}

# ==================== MAIN ====================
main() {
local COMMAND=""
local args=()
while [[ $# -gt 0 ]]; do
case "$1" in
--dry-run|-n)
DRY_RUN=1
;;
--yes|-y)
YES_MODE=1
;;
--debug)
DEBUG=1
;;
--help|-h)
COMMAND="help"
;;
--version|-V)
COMMAND="version"
;;
--)
shift
args+=("$@")
break
;;
*)
args+=("$1")
;;
esac
shift
done
if (( ${#args[@]} > 0 )); then
set -- "${args[@]}"
else
set --
fi
COMMAND="${COMMAND:-${1:-menu}}"
[[ $# -gt 0 ]] && shift
if [[ $DEBUG -eq 1 ]]; then
set -x
fi
case "$COMMAND" in
help)
show_help
return 0
;;
version)
show_version
return 0
;;
esac
check_dependencies
acquire_lock
trap cleanup_on_exit INT TERM
if needs_root "$COMMAND"; then
require_root "$COMMAND"
fi
case "$COMMAND" in
mac) randomize_mac ;;
hostname) randomize_hostname ;;
dns) randomize_dns ;;
timezone|tz) randomize_timezone ;;
disk) randomize_disk_serial ;;
dmi) randomize_dmi ;;
ram) randomize_ram ;;
machineid|machine-id) randomize_machineid ;;
screen) randomize_screen ;;
cpu) randomize_cpu ;;
uptime) randomize_uptime ;;
user) randomize_username ;;
ports) randomize_ports ;;
ttl) randomize_ttl ;;
ipv6) toggle_ipv6 "${1:-disable}" ;;
bluetooth|bt) toggle_bluetooth "${1:-disable}" ;;
network|net) randomize_network ;;
all) randomize_all ;;
all-user) randomize_all_with_user ;;
paranoid) paranoid_mode ;;
restore) restore_all ;;
status) show_status "${1:-}" ;;
verify) verify_spoofs ;;
clean) clean_traces "${1:---all}" ;;
auto) start_auto "${1:-}" ;;
stop) stop_auto ;;
log) show_log ;;
leak|leak-test) run_leak_test ;;
browser|browser-check) show_browser_check ;;
disclaimer|threat-model) show_disclaimer ;;
harden) harden_system ;;
harden-undo) harden_undo ;;
uninstall) uninstall_components "$@" ;;
rotate-quiet|systemd-rotate|--systemd-rotate)
rotate_mac_quiet
;;
persona)
local sub="${1:-list}"
[[ $# -gt 0 ]] && shift
case "$sub" in
list)
echo "  us-office, us-dev, eu-office, br-home, random"
;;
apply)
apply_persona "${1:-random}"
;;
*)
echo "Uso: $0 persona [list|apply] [nome]"
;;
esac
;;
profile)
local sub="${1:-list}"
[[ $# -gt 0 ]] && shift
case "$sub" in
save)
save_profile "${1:-default}"
;;
load)
load_profile "${1:-default}"
;;
list|"")
list_profiles
;;
*)
echo "Uso: $0 profile [save|load|list] [nome]"
;;
esac
;;
menu)
if [[ -t 0 ]]; then
interactive_menu
else
show_help
fi
;;
*)
show_help
return 1
;;
esac
}
