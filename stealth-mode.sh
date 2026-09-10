#!/usr/bin/env bash
#
# stealth-mode.sh
# Orquestrador de Modo Stealth: MAC Spoof + ProtonVPN Rotativo + DNS Seguro
#
# Uso:
#   ./stealth-mode.sh          (menu interativo)
#   ./stealth-mode.sh on       (ativa tudo + auto-rotação 10m)
#   ./stealth-mode.sh off      (desativa tudo)
#   ./stealth-mode.sh rotate   (troca servidor VPN imediatamente)
#   ./stealth-mode.sh status   (mostra status)
#   ./stealth-mode.sh login    (faz login / troca de conta)
#   ./stealth-mode.sh logout   (sai da conta)
#
VERSION="1.2.2"
set -o pipefail
set -u
ORIG_ARGS=("$@")

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
ICON_SHIELD="🛡️"
ICON_VPN="🌐"
ICON_MAC="🔗"
ICON_DNS="📡"
ICON_OK="✅"
ICON_OFF="⬜"
ICON_ON="🟢"
ICON_ROTATE="🔄"
ICON_STATUS="📊"
ICON_EXIT="🚪"
ICON_WARN="⚠️"
ICON_LOCK="🔒"
ICON_UNLOCK="🔓"
ICON_GHOST="👻"
ICON_LOGIN="🔑"
ICON_LOGOUT="🚪"
ICON_ACCOUNT="👤"

# ==================== CONFIGURAÇÃO ====================
# Intervalo de rotação automática em segundos (600s = 10 minutos)
ROTATION_INTERVAL=600
ROTATOR_PID_FILE="/run/stealth-rotator.pid"

# Países disponíveis no plano grátis do ProtonVPN
FREE_COUNTRIES=("US" "NL" "JP" "RO" "PL")

declare -A COUNTRY_NAMES=(
    ["US"]="🇺🇸 Estados Unidos"
    ["NL"]="🇳🇱 Holanda"
    ["JP"]="🇯🇵 Japão"
    ["RO"]="🇷🇴 Romênia"
    ["PL"]="🇵🇱 Polônia"
)

RESOLV_FILE="/etc/resolv.conf"
SCRIPT_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
MUDA_DNS_SCRIPT="/usr/local/bin/muda-dns.sh"
if [[ ! -x "$MUDA_DNS_SCRIPT" && -x "$SCRIPT_DIR/muda-dns.sh" ]]; then
    MUDA_DNS_SCRIPT="$SCRIPT_DIR/muda-dns.sh"
fi
LOG_FILE="/var/log/stealth-mode.log"

# ==================== HELPERS ====================
rotate_log() {
    local file="$1"
    local max_size="${2:-1048576}" # 1MB
    if [[ -f "$file" ]]; then
        local sz
        sz=$(wc -c < "$file" 2>/dev/null || echo 0)
        if (( sz >= max_size )); then
            tail -n 1000 "$file" > "${file}.tmp" 2>/dev/null && mv -f "${file}.tmp" "$file" 2>/dev/null || true
        fi
    fi
}

log() {
    rotate_log "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null
}

info()  { printf '%s\n' "${CYAN}[INFO]${NC} $*"; }
ok()    { printf '%s\n' "${GREEN}[OK]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[AVISO]${NC} $*"; }
err()   { printf '%s\n' "${RED}[ERRO]${NC} $*" >&2; }

pause() {
    echo
    read -rp "Pressione ENTER para continuar..." _
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo &>/dev/null; then
            exec sudo -- "$0" "${ORIG_ARGS[@]}"
        else
            err "Este script precisa ser executado como root. Use: sudo $0 ${ORIG_ARGS[*]}"
            exit 1
        fi
    fi
}

acquire_lock() {
    local lock_file="/run/stealth-mode.lock"
    exec 8>"$lock_file" 2>/dev/null || return 0
    if ! flock -n 8; then
        err "Outra instância do stealth-mode já está em execução."
        exit 1
    fi
}

rand_u32() {
    local n
    n=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d '[:space:]')
    echo "${n:-$RANDOM}"
}

# Identifica o usuário real (mesmo sob sudo ou subshell)
get_real_user() {
    local u="${SUDO_USER:-}"
    if [[ -z "$u" || "$u" == "root" ]]; then
        u=$(logname 2>/dev/null || true)
    fi
    if [[ -z "$u" || "$u" == "root" ]]; then
        u=$(id -nu 1000 2>/dev/null || true)
    fi
    if [[ -z "$u" || "$u" == "root" ]]; then
        echo ""
    else
        echo "$u"
    fi
}

# Executa o protonvpn no contexto do usuário real (com suporte a D-Bus, HOME e chaveiro)
run_protonvpn() {
    local real_user
    real_user=$(get_real_user)

    if [[ $EUID -eq 0 && -n "$real_user" && "$real_user" != "root" ]]; then
        local uid uhome
        uid=$(id -u "$real_user" 2>/dev/null || echo "1000")
        uhome=$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6)
        uhome="${uhome:-/home/$real_user}"

        local -a env_args=(
            "-u" "$real_user"
            "-H"
            "HOME=$uhome"
            "USER=$real_user"
            "LOGNAME=$real_user"
            "XDG_CONFIG_HOME=${uhome}/.config"
            "XDG_CACHE_HOME=${uhome}/.cache"
            "XDG_DATA_HOME=${uhome}/.local/share"
            "XDG_STATE_HOME=${uhome}/.local/state"
        )

        if [[ -n "$uid" && -S "/run/user/${uid}/bus" ]]; then
            env_args+=(
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus"
                "XDG_RUNTIME_DIR=/run/user/${uid}"
            )
        fi

        sudo "${env_args[@]}" protonvpn "$@"
    else
        protonvpn "$@"
    fi
}

# Notificação visual na área de trabalho
send_notification() {
    local title="$1"
    local msg="$2"
    if command -v notify-send &>/dev/null; then
        local real_user
        real_user=$(get_real_user)
        if [[ $EUID -eq 0 && -n "$real_user" && "$real_user" != "root" ]]; then
            local uid uhome
            uid=$(id -u "$real_user" 2>/dev/null || echo "1000")
            uhome=$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6)
            uhome="${uhome:-/home/$real_user}"

            local -a env_args=(
                "-u" "$real_user"
                "-H"
                "HOME=$uhome"
                "USER=$real_user"
                "LOGNAME=$real_user"
            )
            if [[ -n "$uid" && -S "/run/user/${uid}/bus" ]]; then
                env_args+=(
                    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus"
                    "XDG_RUNTIME_DIR=/run/user/${uid}"
                )
            fi
            sudo "${env_args[@]}" notify-send -i network-vpn "$title" "$msg" 2>/dev/null || true
        else
            notify-send -i network-vpn "$title" "$msg" 2>/dev/null || true
        fi
    fi
}

# Função de confirmação (retorna 0 para sim, 1 para não)
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local ans
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [S/n]: " ans
        [[ ! "$ans" =~ ^[nN]$ ]]
    else
        read -rp "$prompt [s/N]: " ans
        [[ "$ans" =~ ^[sS]$ ]]
    fi
}

# ==================== VERIFICAÇÃO DE LOGIN ====================
is_logged_in() {
    # 1. Se info contém Account ou Username, o usuário está logado
    local info_output
    info_output=$(run_protonvpn info 2>&1)
    if echo "$info_output" | grep -qiE "account:|username:"; then
        return 0
    fi

    # 2. Se a saída de info ou status indicar explicitamente ausência de conta/login
    if echo "$info_output" | grep -qiE "no account|not logged|please login|login required|please sign|sign in|not signed in"; then
        return 1
    fi

    local status_output
    status_output=$(run_protonvpn status 2>&1)

    if echo "$status_output" | grep -qiE "no account|not logged|please login|login required|no configuration|not initialized|no user|please sign|sign in|not signed in"; then
        return 1
    fi

    # 3. Se status indicar Connected ou Disconnected
    if echo "$status_output" | grep -qiE "status:\s*(connected|disconnected)"; then
        return 0
    fi

    # 4. Se comando info executou com sucesso (código 0)
    if run_protonvpn info &>/dev/null; then
        return 0
    fi

    if [[ -n "$status_output" ]] && ! echo "$status_output" | grep -qiE "error|failed"; then
        return 0
    fi

    return 1
}

# Retorna o nome da conta logada (se disponível)
get_account_name() {
    local acc
    acc=$(run_protonvpn info 2>/dev/null | grep -iE "account|username|name|email" | head -1 | sed "s/.*: *//; s/['\"]//g" | tr -d ' ')
    if [[ -z "$acc" ]]; then
        acc=$(run_protonvpn account 2>/dev/null | grep -iE "username|account|name" | head -1 | sed 's/.*: *//' | tr -d ' ')
    fi
    echo "${acc:-}"
}

# ==================== LOGIN / LOGOUT ====================
do_login() {
    echo
    printf '%s\n' "  ${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    printf '%s\n' "  ${CYAN}${BOLD}║${NC}  ${ICON_LOGIN} ${BOLD}LOGIN PROTONVPN${NC}                        ${CYAN}${BOLD}║${NC}"
    printf '%s\n' "  ${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo

    # Se já estiver logado, pergunta se quer trocar de conta
    if is_logged_in; then
        local current
        current=$(get_account_name)
        if [[ -n "$current" ]]; then
            ok "Você já está logado como: ${BOLD}${current}${NC}"
        else
            ok "Você já está logado em uma conta."
        fi
        echo
        if ! confirm "  Deseja sair e entrar com OUTRA conta?"; then
            info "Operação cancelada. Conta atual mantida."
            return 0
        fi
        echo
        info "Fazendo logout da conta atual..."
        run_protonvpn disconnect &>/dev/null
        run_protonvpn signout &>/dev/null || run_protonvpn logout &>/dev/null
        ok "Logout realizado. ${ICON_LOGOUT}"
        echo
    fi

    info "Iniciando login interativo do ProtonVPN..."
    info "Digite suas credenciais quando solicitado abaixo."
    echo
    printf '  %s\n' "${DIM}💡 Não tem credenciais? Crie em: https://account.protonvpn.com/account${NC}"
    printf '  %s\n' "${DIM}   (Use o 'ProtonVPN credentials' na seção Account / Login)${NC}"
    echo
    printf '%s\n' "  ${GRAY}─────────────────────────────────────────────────────${NC}"

    # Chama o login interativo (signin na v3 ou login na v2)
    if run_protonvpn signin || run_protonvpn login; then
        printf '%s\n' "  ${GRAY}─────────────────────────────────────────────────────${NC}"
        echo
        sleep 2
        if is_logged_in; then
            ok "Login realizado com sucesso! ${ICON_OK}"
            log "LOGIN: Usuário autenticado no ProtonVPN"
            return 0
        else
            warn "Login executado, mas não consegui confirmar o status."
            warn "Verifique manualmente com: protonvpn status"
            return 0
        fi
    else
        printf '%s\n' "  ${GRAY}─────────────────────────────────────────────────────${NC}"
        echo
        err "Falha no login. Verifique suas credenciais e tente novamente."
        warn "Você também pode tentar manualmente: protonvpn signin"
        return 1
    fi
}

do_logout() {
    echo
    if ! is_logged_in; then
        warn "Você não está logado em nenhuma conta."
        return 0
    fi

    if ! confirm "  Deseja realmente SAIR da conta ProtonVPN?"; then
        info "Cancelado."
        return 0
    fi

    # Desconecta a VPN antes de deslogar (segurança)
    if is_vpn_active; then
        info "Desconectando VPN antes do logout..."
        run_protonvpn disconnect &>/dev/null
        sleep 2
    fi

    run_protonvpn signout &>/dev/null || run_protonvpn logout &>/dev/null
    ok "Logout realizado com sucesso. ${ICON_LOGOUT}"
    log "LOGOUT: Usuário deslogado do ProtonVPN"
}

# ==================== DEPENDÊNCIAS ====================
check_dependencies() {
    local missing=()

    command -v protonvpn &>/dev/null || missing+=("protonvpn")
    command -v randomize-ids &>/dev/null || missing+=("randomize-ids")
    command -v curl &>/dev/null || missing+=("curl")
    command -v chattr &>/dev/null || missing+=("chattr")

    if (( ${#missing[@]} > 0 )); then
        err "Dependências não encontradas: ${missing[*]}"
        echo
        echo "Instalação:"
        echo "  protonvpn:     sudo pacman -S protonvpn  (ou AUR: protonvpn-cli)"
        echo "  randomize-ids: já deve estar em /usr/local/bin/randomize-ids"
        echo
        echo "Após instalar o protonvpn, faça login:"
        echo "  sudo stealth-mode login"
        exit 1
    fi

    # ✨ NOVO: Se não estiver logado, oferece o login na hora
    if ! is_logged_in; then
        echo
        printf '%s\n' "  ${YELLOW}${BOLD}${ICON_WARN} Você ainda não está logado no ProtonVPN.${NC}"
        echo
        printf '  %s\n' "${DIM}É necessário fazer login para usar o Modo Stealth.${NC}"
        echo
        if confirm "  Deseja fazer o login AGORA?" y; then
            do_login
            echo
            if ! is_logged_in; then
                err "Ainda não foi possível confirmar o login."
                err "Faça login manualmente e tente novamente: sudo stealth-mode login"
                exit 1
            fi
        else
            info "Cancelado. Quando quiser, faça login com: sudo stealth-mode login"
            exit 0
        fi
    fi
}

# ==================== FUNÇÕES DE STATUS ====================
is_vpn_active() {
    local status_out
    status_out=$(run_protonvpn status 2>/dev/null)

    # "disconnected" CONTÉM "connected", então verifica o negativo PRIMEIRO
    if echo "$status_out" | grep -qiE "disconnected|not connected|disabled"; then
        if ip link show proton0 2>/dev/null | grep -q "state UP"; then
            return 0
        fi
        return 1
    fi

    if echo "$status_out" | grep -qi "connected"; then
        return 0
    fi
    if ip link show type tun 2>/dev/null | grep -q "state UP"; then
        return 0
    fi
    if ip link show proton0 2>/dev/null | grep -q "state UP"; then
        return 0
    fi
    return 1
}

is_rotator_running() {
    if [[ -f "$ROTATOR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$ROTATOR_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

is_mac_spoofed() {
    randomize-ids status --json 2>/dev/null | grep -q '"mac": true' && return 0
    return 1
}

is_dns_locked() {
    lsattr "$RESOLV_FILE" 2>/dev/null | awk '{print $1}' | grep -q 'i' && return 0
    return 1
}

get_current_ip() {
    curl -s --max-time 10 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 10 https://ifconfig.me 2>/dev/null || \
    echo "N/A"
}

get_vpn_country() {
    run_protonvpn status 2>/dev/null | grep -i "country" | sed 's/.*: *//' | tr -d '\r' | xargs 2>/dev/null || echo "?"
}

# ==================== ROTAÇÃO & CONEXÃO VPN ====================
vpn_connect_server() {
    local target_country="${1:-}"

    # 1. Tentar por país se especificado (--country no ProtonVPN v3)
    if [[ -n "$target_country" ]]; then
        if run_protonvpn connect --country "$target_country" &>/dev/null; then
            return 0
        fi
    fi

    # 2. Tentar conexão aleatória
    if run_protonvpn connect --random &>/dev/null; then
        return 0
    fi

    # 3. Fallback: conexão rápida
    if run_protonvpn connect &>/dev/null; then
        return 0
    fi

    return 1
}

pick_different_country() {
    local current_country
    current_country=$(get_vpn_country)
    local candidates=()

    for c in "${FREE_COUNTRIES[@]}"; do
        local c_name="${COUNTRY_NAMES[$c]:-}"
        if [[ "$c" != "$current_country" && "$c_name" != *"$current_country"* ]]; then
            candidates+=("$c")
        fi
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        candidates=("${FREE_COUNTRIES[@]}")
    fi

    local idx=$(( $(rand_u32) % ${#candidates[@]} ))
    echo "${candidates[$idx]}"
}

rotate_server() {
    echo
    info "Rotacionando servidor VPN..."

    if ! is_vpn_active; then
        warn "VPN não está ativa. Ative o Modo Stealth primeiro."
        return 1
    fi

    run_protonvpn disconnect &>/dev/null
    sleep 2

    local country
    country=$(pick_different_country)
    local country_name="${COUNTRY_NAMES[$country]:-$country}"

    info "Novo destino: ${BOLD}${country_name}${NC} ${ICON_ROTATE}"

    if vpn_connect_server "$country"; then
        sleep 5
        local new_ip
        new_ip=$(get_current_ip)
        ok "Servidor rotacionado com sucesso!"
        printf '  %s\n' "${WHITE}Novo IP:${NC} ${GREEN}${BOLD}${new_ip}${NC}"
        printf '  %s\n' "${WHITE}Local:${NC}   ${CYAN}${country_name}${NC}"
        log "VPN ROTACIONADA MANUALMENTE | IP: $new_ip | País: $country ($country_name)"
        send_notification "🔄 VPN Rotacionada" "Novo país: ${country_name}\nNovo IP: ${new_ip}"
    else
        err "Falha ao rotacionar. Tente: protonvpn connect"
    fi
}

rotate_server_silent() {
    if ! is_vpn_active; then
        return 1
    fi

    run_protonvpn disconnect &>/dev/null
    sleep 2

    local country
    country=$(pick_different_country)
    local country_name="${COUNTRY_NAMES[$country]:-$country}"

    if vpn_connect_server "$country"; then
        sleep 5
        local new_ip
        new_ip=$(get_current_ip)
        log "AUTO-ROTAÇÃO (10m) | IP: $new_ip | País: $country ($country_name)"
        send_notification "🔄 VPN Auto-Rotacionada (10m)" "Nova região: ${country_name}\nNovo IP: ${new_ip}"
        return 0
    else
        log "AUTO-ROTAÇÃO FALHOU ao conectar ao país $country"
        return 1
    fi
}

start_rotator() {
    stop_rotator &>/dev/null

    info "Iniciando rotação automática a cada $(( ROTATION_INTERVAL / 60 )) minutos..."

    (
        exec 8>&- 2>/dev/null || true
        while true; do
            sleep "$ROTATION_INTERVAL"
            if [[ ! -f "$ROTATOR_PID_FILE" ]]; then
                break
            fi
            local cur_pid
            cur_pid=$(cat "$ROTATOR_PID_FILE" 2>/dev/null || echo "")
            if [[ -n "$cur_pid" && "$cur_pid" != "$BASHPID" ]]; then
                break
            fi
            if ! is_vpn_active; then
                log "AUTO-ROTAÇÃO: VPN detectada como inativa. Encerrando daemon."
                rm -f "$ROTATOR_PID_FILE" 2>/dev/null
                break
            fi
            log "AUTO-ROTAÇÃO: Intervalo de $(( ROTATION_INTERVAL / 60 )) minutos atingido. Trocando região..."
            rotate_server_silent
        done
    ) &>/dev/null &

    local pid=$!
    echo "$pid" > "$ROTATOR_PID_FILE"
    chmod 644 "$ROTATOR_PID_FILE" 2>/dev/null || true
    ok "Rotação automática ativa em segundo plano (PID: $pid) a cada $(( ROTATION_INTERVAL / 60 )) min ${ICON_ROTATE}"
    log "AUTO-ROTAÇÃO iniciada (PID: $pid, Intervalo: ${ROTATION_INTERVAL}s)"
}

stop_rotator() {
    if [[ -f "$ROTATOR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$ROTATOR_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            info "Daemon de rotação automática finalizado (PID: $pid)."
        fi
        rm -f "$ROTATOR_PID_FILE" 2>/dev/null
        log "AUTO-ROTAÇÃO finalizada"
    fi
}

# ==================== FUNÇÕES PRINCIPAIS ====================
activate_stealth() {
    echo
    printf '%s\n' "  ${MAGENTA}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    printf '%s\n' "  ${MAGENTA}${BOLD}║${NC}  ${ICON_GHOST} ${BOLD}ATIVANDO MODO STEALTH${NC}                    ${MAGENTA}${BOLD}║${NC}"
    printf '%s\n' "  ${MAGENTA}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo

    # 1. Destravar DNS
    info "Destravando DNS para a VPN assumir..."
    chattr -i "$RESOLV_FILE" 2>/dev/null
    ok "DNS destravado ${ICON_UNLOCK}"

    # 2. Spoofar MAC
    info "Randomizando MAC Address..."
    if randomize-ids mac &>/dev/null; then
        ok "MAC Address spoofado ${ICON_MAC}"
    else
        warn "Falha ao spoofar MAC (pode não haver interface compatível)"
    fi

    # 3. Sortear país e conectar VPN (entropia real via /dev/urandom)
    local idx=$(( $(rand_u32) % ${#FREE_COUNTRIES[@]} ))
    local country="${FREE_COUNTRIES[$idx]}"
    local country_name="${COUNTRY_NAMES[$country]:-$country}"

    info "Conectando ao ProtonVPN: ${BOLD}${country_name}${NC} ${ICON_VPN}"

    if is_vpn_active; then
        run_protonvpn disconnect &>/dev/null
        sleep 2
    fi

    if vpn_connect_server "$country"; then
        ok "VPN conectada: ${country_name}"
    else
        err "Falha ao conectar à VPN!"
        warn "Tente manualmente: protonvpn connect"
        return 1
    fi

    # 4. Aguardar estabilização
    info "Aguardando estabilização da conexão..."
    sleep 5

    # 5. Verificar IP
    local new_ip
    new_ip=$(get_current_ip)
    echo
    ok "Modo Stealth ATIVO! ${ICON_SHIELD}"
    echo
    printf '  %s\n' "${WHITE}Seu novo IP público:${NC} ${GREEN}${BOLD}${new_ip}${NC}"
    printf '  %s\n' "${WHITE}Localização:${NC}         ${CYAN}${country_name}${NC}"
    echo
    log "STEALTH ATIVO | IP: $new_ip | País: $country ($country_name)"

    # 6. Iniciar rotação automática da região a cada 10 minutos
    start_rotator

    # Notificação na área de trabalho
    send_notification "🛡️ Modo Stealth Ativado" "VPN conectada em ${country_name}\nIP: ${new_ip}\nRotação automática a cada $(( ROTATION_INTERVAL / 60 )) minutos"
}

deactivate_stealth() {
    echo
    printf '%s\n' "  ${BLUE}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    printf '%s\n' "  ${BLUE}${BOLD}║${NC}  ${ICON_EXIT} ${BOLD}DESATIVANDO MODO STEALTH${NC}                 ${BLUE}${BOLD}║${NC}"
    printf '%s\n' "  ${BLUE}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo

    # 0. Parar rotação automática
    stop_rotator

    # 1. Desconectar VPN
    info "Desconectando ProtonVPN..."
    run_protonvpn disconnect &>/dev/null
    sleep 2
    ok "VPN desconectada ${ICON_OFF}"

    # 2. Restaurar MAC e identificadores
    info "Restaurando MAC Address e identificadores originais (randomize-ids)..."
    if randomize-ids restore &>/dev/null; then
        ok "Identificadores e MAC restaurados ${ICON_MAC}"
    else
        warn "Falha ao restaurar MAC/IDs (pode já estar no original)"
    fi

    # 3. Restaurar DNS
    info "Restaurando DNS seguro (dnscrypt-proxy)..."
    if [[ -x "$MUDA_DNS_SCRIPT" ]]; then
        "$MUDA_DNS_SCRIPT" casa &>/dev/null
        ok "DNS restaurado e travado ${ICON_LOCK}"
    else
        warn "Script muda-dns.sh não encontrado em $MUDA_DNS_SCRIPT"
        warn "Restaure o DNS manualmente!"
        chattr +i "$RESOLV_FILE" 2>/dev/null
    fi

    echo
    ok "Sistema restaurado ao estado normal! ${ICON_OK}"
    log "STEALTH DESATIVADO | Sistema restaurado"

    send_notification "🛡️ Modo Stealth Desativado" "Proteções desativadas e rede restaurada."
}

show_status() {
    echo
    printf '%s\n' "  ${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    printf '%s\n' "  ${CYAN}${BOLD}║${NC}  ${ICON_STATUS} ${BOLD}STATUS DO SISTEMA${NC}                       ${CYAN}${BOLD}║${NC}"
    printf '%s\n' "  ${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo

    # ✨ NOVO: Status da conta ProtonVPN
    if is_logged_in; then
        local account
        account=$(get_account_name)
        if [[ -n "$account" ]]; then
            printf '  %s %s\n' "${ICON_ACCOUNT}" "${GREEN}${BOLD}Conta:${NC} Logada (${account})"
        else
            printf '  %s %s\n' "${ICON_ACCOUNT}" "${GREEN}${BOLD}Conta:${NC} Logada"
        fi
    else
        printf '  %s %s\n' "${ICON_ACCOUNT}" "${RED}${BOLD}Conta:${NC} Não logada"
    fi

    # VPN
    if is_vpn_active; then
        local country
        country=$(get_vpn_country)
        printf '  %s %s\n' "${ICON_ON}" "${GREEN}${BOLD}VPN:${NC} Conectada (${country:-desconhecido})"
    else
        printf '  %s %s\n' "${ICON_OFF}" "${RED}VPN:${NC} Desconectada"
    fi

    # MAC
    if is_mac_spoofed; then
        printf '  %s %s\n' "${ICON_ON}" "${GREEN}${BOLD}MAC:${NC} Spoofado"
    else
        printf '  %s %s\n' "${ICON_OFF}" "${GRAY}MAC:${NC} Original"
    fi

    # DNS
    if is_dns_locked; then
        printf '  %s %s\n' "${ICON_LOCK}" "${GREEN}${BOLD}DNS:${NC} Travado (dnscrypt-proxy)"
    else
        printf '  %s %s\n' "${ICON_UNLOCK}" "${YELLOW}DNS:${NC} Destravado (VPN gerenciando)"
    fi

    # Rotação Automática
    if is_rotator_running; then
        local rpid
        rpid=$(cat "$ROTATOR_PID_FILE" 2>/dev/null || echo "?")
        printf '  %s %s\n' "${ICON_ROTATE}" "${GREEN}${BOLD}Rotação Auto:${NC} Ativa (a cada $(( ROTATION_INTERVAL / 60 )) min, PID: $rpid)"
    else
        printf '  %s %s\n' "${ICON_OFF}" "${GRAY}Rotação Auto:${NC} Inativa"
    fi

    # IP Público
    echo
    info "Consultando IP público..."
    local ip
    ip=$(get_current_ip)
    printf '  %s %s\n' "${WHITE}IP Público:${NC}" "${GREEN}${BOLD}${ip}${NC}"

    echo
}

# ==================== MENU INTERATIVO ====================
show_menu() {
    clear
    printf '%s\n' "  ${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    printf '%s\n' "  ${MAGENTA}${BOLD}║${NC}  ${ICON_SHIELD} ${BOLD}STEALTH MODE v${VERSION}${NC}                              ${MAGENTA}${BOLD}║${NC}"
    printf '%s\n' "  ${MAGENTA}${BOLD}║${NC}  ${DIM}MAC Spoof + ProtonVPN Rotativo + DNS Seguro${NC}        ${MAGENTA}${BOLD}║${NC}"
    printf '%s\n' "  ${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo

    # Status rápido no menu
    local vpn_status mac_status dns_status account_status rotator_status
    if is_vpn_active; then
        vpn_status="${GREEN}${ICON_ON} VPN Ativa${NC}"
    else
        vpn_status="${GRAY}${ICON_OFF} VPN Inativa${NC}"
    fi

    if is_mac_spoofed; then
        mac_status="${GREEN}${ICON_ON} MAC Spoofed${NC}"
    else
        mac_status="${GRAY}${ICON_OFF} MAC Original${NC}"
    fi

    if is_dns_locked; then
        dns_status="${GREEN}${ICON_LOCK} DNS Travado${NC}"
    else
        dns_status="${YELLOW}${ICON_UNLOCK} DNS Livre${NC}"
    fi

    if is_logged_in; then
        account_status="${GREEN}${ICON_ACCOUNT} Logado${NC}"
    else
        account_status="${RED}${ICON_ACCOUNT} Sem login${NC}"
    fi

    if is_rotator_running; then
        rotator_status="${GREEN}${ICON_ROTATE} Rotação (10m) Ativa${NC}"
    else
        rotator_status="${GRAY}${ICON_OFF} Rotação Inativa${NC}"
    fi

    printf '  %s  %s\n' "$account_status" "$vpn_status"
    printf '  %s  %s\n' "$mac_status" "$dns_status"
    printf '  %s\n' "$rotator_status"
    echo
    printf '%s\n' "  ${GRAY}─────────────────────────────────────────────────────${NC}"
    echo
    printf '  %s\n' "  ${YELLOW}${BOLD}1${NC} › ${ICON_GHOST} ${BOLD}Ativar Modo Stealth${NC}    ${DIM}(MAC + VPN + Auto-Rotação 10m)${NC}"
    printf '  %s\n' "  ${YELLOW}${BOLD}2${NC} › ${ICON_EXIT} ${BOLD}Desativar Tudo${NC}         ${DIM}(Restaura sistema + para rotação)${NC}"
    printf '  %s\n' "  ${YELLOW}${BOLD}3${NC} › ${ICON_ROTATE} ${BOLD}Rotacionar Agora${NC}       ${DIM}(Novo país/IP imediatamente)${NC}"
    printf '  %s\n' "  ${YELLOW}${BOLD}4${NC} › ${ICON_STATUS} ${BOLD}Status${NC}               ${DIM}(Ver estado atual)${NC}"
    printf '  %s\n' "  ${YELLOW}${BOLD}5${NC} › ${ICON_LOGIN} ${BOLD}Login / Trocar Conta${NC} ${DIM}(Autenticar no ProtonVPN)${NC}"
    printf '  %s\n' "  ${YELLOW}${BOLD}0${NC} › ${ICON_EXIT} Sair"
    echo
    printf '%s\n' "  ${GRAY}─────────────────────────────────────────────────────${NC}"
    echo
}

interactive_menu() {
    while true; do
        show_menu
        read -rp "  Escolha uma opção: " choice

        case "$choice" in
            1) activate_stealth; pause ;;
            2) deactivate_stealth; pause ;;
            3) rotate_server; pause ;;
            4) show_status; pause ;;
            5) do_login; pause ;;
            0)
                echo
                printf '  %s\n' "${DIM}Até mais! ${ICON_SHIELD}${NC}"
                echo
                exit 0
                ;;
            *) ;;
        esac
    done
}

# ==================== CLI MODE ====================
if [[ -n "${1:-}" ]]; then
    require_root

    # Login/logout não precisam de todas as dependências de cara
    case "$1" in
        login)
            do_login
            exit $?
            ;;
        logout)
            do_logout
            exit $?
            ;;
    esac

    check_dependencies

    case "$1" in
        on|start|activate)
            acquire_lock
            activate_stealth
            ;;
        off|stop|deactivate)
            acquire_lock
            deactivate_stealth
            ;;
        rotate|new-ip)
            acquire_lock
            rotate_server
            ;;
        rotator-start)
            start_rotator
            ;;
        rotator-stop)
            stop_rotator
            ;;
        status)
            show_status
            ;;
        *)
            echo "Uso: sudo $0 [on|off|rotate|rotator-start|rotator-stop|status|login|logout]"
            exit 1
            ;;
    esac
    exit 0
fi

# ==================== MAIN ====================
require_root
acquire_lock
check_dependencies
interactive_menu
