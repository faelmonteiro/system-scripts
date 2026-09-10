#!/usr/bin/env bash
set -euo pipefail
# Gerenciador universal de E-cores para processadores Intel híbridos.
# Funciona em Intel 12ª, 13ª, 14ª geração e Core Ultra.

if [[ "${BASH_VERSINFO[0]}" -lt 5 ]]; then
    echo "Erro: Este script requer Bash 5.0 ou superior." >&2
    exit 1
fi

VERSION="1.2.0"
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || echo "$0")

# ─── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
    BOLD='\033[1m'
else
    GREEN='' RED='' YELLOW='' BLUE='' CYAN='' NC='' BOLD=''
fi

# ─── Uso CLI ─────────────────────────────────────────────────────────────────
show_usage() {
    echo -e "${BOLD}Uso:${NC} $(basename "$0") [COMANDO] [OPÇÕES]"
    echo ""
    echo -e "${BOLD}Comandos:${NC}"
    echo -e "  ${GREEN}--on${NC}, ${GREEN}on${NC}         Ligar E-cores"
    echo -e "  ${RED}--off${NC}, ${RED}off${NC}       Desligar E-cores"
    echo -e "  ${YELLOW}--toggle${NC}         Alternar estado (liga/desliga)"
    echo -e "  ${BLUE}--status${NC}         Ver status atual dos núcleos"
    echo -e "  ${CYAN}--version${NC}, ${CYAN}-V${NC}   Mostrar versão e informações do sistema"
    echo -e "  ${BOLD}--help${NC}, ${BOLD}-h${NC}      Mostrar esta ajuda"
    echo ""
    echo -e "${BOLD}Opções:${NC}"
    echo -e "  ${CYAN}--quiet${NC}, ${CYAN}-q${NC}     Modo silencioso (sem saída no terminal)"
    echo -e "  ${CYAN}--persist${NC}, ${CYAN}-p${NC}   Persistir estado no boot via systemd"
    echo -e "  ${CYAN}--dry-run${NC}, ${CYAN}-d${NC}   Simular ação sem alterar os núcleos"
    echo ""
    echo -e "${BOLD}Exemplos:${NC}"
    echo -e "  $(basename "$0") --off --persist    # Desligar e manter OFF no boot"
    echo -e "  $(basename "$0") --on --persist     # Ligar e remover persistência"
    echo -e "  $(basename "$0") --toggle --quiet   # Toggle silencioso (para atalhos)"
    echo -e "  $(basename "$0") --off --dry-run    # Simular desligamento sem alterar"
    echo ""
    echo -e "${BOLD}Integração com GameMode (Feral):${NC}"
    echo -e "  Adicione ao ${CYAN}~/.config/gamemode.ini${NC}:"
    echo -e "  ${YELLOW}[custom]${NC}"
    echo -e "  ${YELLOW}start=${SCRIPT_PATH} --off --quiet${NC}"
    echo -e "  ${YELLOW}end=${SCRIPT_PATH} --on --quiet${NC}"
    echo ""
}

# ─── Ajuda e versão sem exigir root ──────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --version|-V)
            echo -e "${BOLD}toggle-ecores-generic${NC} v${VERSION}"
            echo -e "${CYAN}Kernel:${NC}  $(uname -r)"
            exit 0
            ;;
    esac
done

# ─── Flags globais ───────────────────────────────────────────────────────────
QUIET=false
PERSIST=false
DRY_RUN=false

# Pré-processar flags globais antes de elevar para root
FILTERED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=true ;;
        --persist|-p) PERSIST=true ;;
        --dry-run|-d) DRY_RUN=true ;;
        *) FILTERED_ARGS+=("$arg") ;;
    esac
done
set -- "${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}"

# Auto-elevate to root
if [[ $EUID -ne 0 ]]; then
    # Repassar flags globais junto com os argumentos filtrados
    SUDO_ARGS=()
    [[ "$QUIET" == true ]] && SUDO_ARGS+=(--quiet)
    [[ "$PERSIST" == true ]] && SUDO_ARGS+=(--persist)
    [[ "$DRY_RUN" == true ]] && SUDO_ARGS+=(--dry-run)
    if [[ -n "${NO_COLOR:-}" ]]; then
        exec sudo env NO_COLOR="$NO_COLOR" "$0" "${SUDO_ARGS[@]}" "$@"
    else
        exec sudo "$0" "${SUDO_ARGS[@]}" "$@"
    fi
fi

# ─── Logging ─────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/ecores-toggle.log"

log() {
    [[ "$QUIET" == true ]] && return
    echo -e "$@"
}

log_action() {
    local action="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $action (user: ${SUDO_USER:-$USER})" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Detectar CPU ────────────────────────────────────────────────────────────
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs)
VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | cut -d':' -f2 | xargs)

if [[ "$VENDOR" != "GenuineIntel" ]]; then
    echo -e "${RED}✗ Este script é apenas para processadores Intel com arquitetura híbrida.${NC}"
    echo -e "${YELLOW}Seu processador: ${CPU_MODEL} (${VENDOR})${NC}"
    exit 1
fi

# Helper function to expand CPU range strings like "0-3,5,7-9" into an array
parse_cpu_range() {
    local range_str="$1"
    local -n out_array="$2"

    [[ -z "$range_str" ]] && return

    IFS=',' read -ra PARTS <<< "$range_str"
    for part in "${PARTS[@]}"; do
        if [[ "$part" == *-* ]]; then
            IFS='-' read -r start end <<< "$part"
            for ((i=start; i<=end; i++)); do
                out_array+=("$i")
            done
        elif [[ -n "$part" ]]; then
            out_array+=("$part")
        fi
    done
}

# ─── Encontrar E-cores e P-cores ─────────────────────────────────────────────
E_CORES=()
P_CORES=()
ALL_PRESENT=()

# Ler todos os CPUs presentes no sistema (online + offline)
parse_cpu_range "$(cat /sys/devices/system/cpu/present 2>/dev/null)" ALL_PRESENT

# Method 1: Usar pastas nativas do kernel (mais confiável)
if [[ -f "/sys/devices/cpu_atom/cpus" && -f "/sys/devices/cpu_core/cpus" ]]; then
    parse_cpu_range "$(cat /sys/devices/cpu_atom/cpus 2>/dev/null)" E_CORES
    parse_cpu_range "$(cat /sys/devices/cpu_core/cpus 2>/dev/null)" P_CORES

    # Method 1.5: cpu_atom/cpus pode ficar vazio quando E-cores estão offline.
    # Se temos P-cores mas não E-cores, e a pasta cpu_atom existe (confirmando
    # arquitetura híbrida), derivamos: E-cores = todos os presentes - P-cores.
    if [[ ${#E_CORES[@]} -eq 0 && ${#P_CORES[@]} -gt 0 && ${#ALL_PRESENT[@]} -gt 0 ]]; then
        declare -A P_CORE_MAP
        for p in "${P_CORES[@]}"; do
            P_CORE_MAP["$p"]=1
        done
        for cpu_id in "${ALL_PRESENT[@]}"; do
            if [[ -z "${P_CORE_MAP[$cpu_id]+_}" ]]; then
                E_CORES+=("$cpu_id")
            fi
        done
        unset P_CORE_MAP
    fi
fi

# Method 2: Fallback usando core_type (se Method 1 falhou)
if [[ ${#E_CORES[@]} -eq 0 || ${#P_CORES[@]} -eq 0 ]]; then
    E_CORES=()
    P_CORES=()

    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_id=$(basename "$cpu_dir" | sed 's/cpu//')

        # Skip non-CPU directories
        if [[ ! "$cpu_id" =~ ^[0-9]+$ ]]; then
            continue
        fi

        if [[ -f "$cpu_dir/topology/core_type" ]]; then
            core_type=$(cat "$cpu_dir/topology/core_type" 2>/dev/null)
            # 1, 2 (LP E-core) or 32 (0x20) = E-core
            # 0 or 64 (0x40) = P-core
            if [[ "$core_type" == "Atom" || "$core_type" == "1" || "$core_type" == "2" || "$core_type" == "32" ]]; then
                E_CORES+=("$cpu_id")
            elif [[ "$core_type" == "Core" || "$core_type" == "0" || "$core_type" == "64" ]]; then
                P_CORES+=("$cpu_id")
            fi
        fi
    done

    # Method 2.5: Mesmo fallback de derivação do Method 1.5 — se encontramos
    # P-cores mas não E-cores (podem estar offline), derivamos por subtração.
    if [[ ${#E_CORES[@]} -eq 0 && ${#P_CORES[@]} -gt 0 && ${#ALL_PRESENT[@]} -gt 0 ]]; then
        declare -A P_CORE_MAP2
        for p in "${P_CORES[@]}"; do
            P_CORE_MAP2["$p"]=1
        done
        for cpu_id in "${ALL_PRESENT[@]}"; do
            if [[ -z "${P_CORE_MAP2[$cpu_id]+_}" ]]; then
                E_CORES+=("$cpu_id")
            fi
        done
        unset P_CORE_MAP2
    fi
fi

if [[ ${#E_CORES[@]} -eq 0 ]]; then
    echo -e "${RED}✗ Não foi possível identificar E-cores automaticamente.${NC}"
    echo -e "${YELLOW}Seu processador pode não ter arquitetura híbrida.${NC}"
    exit 1
fi

TOTAL_CPUS=${#ALL_PRESENT[@]}
P_COUNT=${#P_CORES[@]}
E_COUNT=${#E_CORES[@]}

# ─── Contagem de E-cores online/offline ──────────────────────────────────────
count_ecores_state() {
    E_ONLINE=0
    E_OFFLINE=0
    for cpu in "${E_CORES[@]}"; do
        path="/sys/devices/system/cpu/cpu${cpu}/online"
        if [[ -f "$path" ]]; then
            state=$(cat "$path" 2>/dev/null)
            if [[ "$state" == "1" ]]; then
                ((E_ONLINE++)) || true
            else
                ((E_OFFLINE++)) || true
            fi
        else
            ((E_ONLINE++)) || true
        fi
    done
}

# ─── Persistência com systemd ────────────────────────────────────────────────
SYSTEMD_UNIT="/etc/systemd/system/ecores-off.service"
SCRIPT_PATH=$(realpath "$0")

persist_state() {
    local state=$1
    if [[ "$DRY_RUN" == true ]]; then
        log "${CYAN}[DRY-RUN] Simulação: Persistência no boot seria alterada para estado: ${state}.${NC}"
        return
    fi

    if [[ "$state" == "0" ]]; then
        cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Desativar E-cores Intel no boot
After=sysinit.target
ConditionPathExists=${SCRIPT_PATH}

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --off --quiet
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ecores-off.service 2>/dev/null
        log "${GREEN}✓ Persistência ativada: E-cores serão desativados automaticamente no boot.${NC}"
        log_action "Persistência ON (E-cores OFF no boot)"
    else
        if [[ -f "$SYSTEMD_UNIT" ]]; then
            systemctl disable ecores-off.service 2>/dev/null
            rm -f "$SYSTEMD_UNIT"
            systemctl daemon-reload
            log "${GREEN}✓ Persistência removida. E-cores voltarão ao padrão no boot.${NC}"
            log_action "Persistência OFF"
        else
            log "${YELLOW}⚠ Nenhuma persistência configurada para remover.${NC}"
        fi
    fi
}

is_persist_active() {
    [[ -f "$SYSTEMD_UNIT" ]] && systemctl is-enabled ecores-off.service &>/dev/null
}

# ─── Toggle E-cores ──────────────────────────────────────────────────────────
function toggle_ecores() {
    local state=$1 # 0 to disable, 1 to enable
    local action_text=$2
    local icon=$3

    if [[ "$DRY_RUN" == true ]]; then
        log "\n${CYAN}➜ [DRY-RUN] Simulando: ${action_text}...${NC}"
        for cpu in "${E_CORES[@]}"; do
            path="/sys/devices/system/cpu/cpu${cpu}/online"
            if [[ -f "$path" ]]; then
                log "  ${icon} [DRY-RUN] CPU ${cpu} seria alterada para ${state}."
            else
                log "  ${YELLOW}⚠ [DRY-RUN] CPU ${cpu} não pode ser alterada (CPU bootstrap).${NC}"
            fi
        done
        log "${GREEN}[DRY-RUN] Simulação concluída!${NC}\n"
        log_action "[DRY-RUN] ${action_text} (${E_COUNT} cores)"
        return
    fi

    log "\n${CYAN}➜ ${action_text}...${NC}"
    for cpu in "${E_CORES[@]}"; do
        path="/sys/devices/system/cpu/cpu${cpu}/online"
        if [[ -f "$path" ]]; then
            if echo "$state" > "$path" 2>/dev/null; then
                log "  ${icon} CPU ${cpu} alterado."
            else
                log "  ${RED}✗ Falha ao alterar CPU ${cpu} (pode estar em uso crítico).${NC}"
            fi
        else
            log "  ${YELLOW}⚠ CPU ${cpu} não pode ser alterada (CPU bootstrap).${NC}"
        fi
    done
    log "${GREEN}Concluído!${NC}\n"

    # Logging
    if [[ "$state" == "0" ]]; then
        log_action "E-cores OFF (${E_COUNT} cores desativados)"
    else
        log_action "E-cores ON (${E_COUNT} cores ativados)"
    fi

    # Persistência automática se flag --persist ativa
    if [[ "$PERSIST" == true ]]; then
        persist_state "$state"
    fi

    # Envia notificação de desktop se notify-send estiver disponível
    if command -v notify-send &>/dev/null; then
        local REAL_USER="${SUDO_USER:-$USER}"
        local REAL_UID
        REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "")
        if [[ -n "$REAL_UID" ]]; then
            local NOTIFY_CMD=(sudo -u "$REAL_USER" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus" notify-send "Gerenciador Intel E-cores")
            if [[ "$state" == "0" ]]; then
                "${NOTIFY_CMD[@]}" "E-cores desativados (Modo Gaming/Performance)" -i cpu || true
            else
                "${NOTIFY_CMD[@]}" "E-cores ativados (Modo Multitarefa)" -i cpu || true
            fi
        fi
    fi
}

# ─── Status ──────────────────────────────────────────────────────────────────
function show_status() {
    echo -e "\n${BOLD}Status dos Núcleos:${NC}"
    echo -e "${BLUE}P-cores (Performance):${NC}"
    for cpu in "${P_CORES[@]}"; do
        path="/sys/devices/system/cpu/cpu${cpu}/online"
        if [[ -f "$path" ]]; then
            state=$(cat "$path" 2>/dev/null)
            if [[ "$state" == "1" ]]; then
                echo -e "  ${GREEN}● CPU ${cpu}: Online${NC}"
            else
                echo -e "  ${RED}● CPU ${cpu}: Offline${NC}"
            fi
        else
            # CPU0 não tem arquivo "online" — está sempre online
            echo -e "  ${GREEN}● CPU ${cpu}: Online (fixo)${NC}"
        fi
    done

    echo -e "\n${YELLOW}E-cores (Eficiência):${NC}"
    for cpu in "${E_CORES[@]}"; do
        path="/sys/devices/system/cpu/cpu${cpu}/online"
        if [[ -f "$path" ]]; then
            state=$(cat "$path" 2>/dev/null)
            if [[ "$state" == "1" ]]; then
                echo -e "  ${GREEN}● CPU ${cpu}: Online${NC}"
            else
                echo -e "  ${RED}● CPU ${cpu}: Offline${NC}"
            fi
        else
            # E-core sem arquivo "online" — está sempre online (ex: CPU 0)
            echo -e "  ${GREEN}● CPU ${cpu}: Online (fixo)${NC}"
        fi
    done

    # Resumo
    count_ecores_state
    echo ""
    echo -e "  ${BOLD}Resumo E-cores:${NC} ${GREEN}${E_ONLINE} online${NC} / ${RED}${E_OFFLINE} offline${NC} (de ${E_COUNT} total)"

    # Mostrar estado de persistência
    if is_persist_active; then
        echo -e "  ${CYAN}🔁 Persistência:${NC} ${GREEN}Ativa${NC} (E-cores OFF no boot)"
    else
        echo -e "  ${CYAN}🔁 Persistência:${NC} ${YELLOW}Inativa${NC} (padrão do sistema no boot)"
    fi
    echo ""
}

# ─── Ajuda ───────────────────────────────────────────────────────────────────
function show_help() {
    clear
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           ❓ O que são E-cores e quando usar?                ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"

    echo -e "\n${CYAN}🧠 O que são?${NC}"
    echo -e "  Processadores Intel recentes (12ª ger+) possuem dois tipos de núcleos:"
    echo -e "  ${GREEN}🚀 P-cores (Performance):${NC} Rápidos, para jogos e tarefas pesadas."
    echo -e "  ${YELLOW}🔋 E-cores (Eficiência):${NC}  Econômicos, para tarefas de fundo."

    echo -e "\n${RED}⛔ Quando DESLIGAR os E-cores?${NC}"
    echo -e "  ${BOLD}🎮 Jogos:${NC}              Evita micro-stutters (jogo indo pro núcleo lento)."
    echo -e "  ${BOLD}🌡️  Temperatura:${NC}        Menos núcleos = menos calor, evita throttling."
    echo -e "  ${BOLD}🎵 Áudio Profissional:${NC} Evita estalos (xruns) em DAWs."

    echo -e "\n${GREEN}✅ Quando MANTER LIGADOS?${NC}"
    echo -e "  ${BOLD}🖥️  Uso diário:${NC}         Navegar, ver vídeos, programar."
    echo -e "  ${BOLD}⚙️  Renderização:${NC}       Mais núcleos = mais velocidade."
    echo -e "  ${BOLD}📂 Multitarefa:${NC}        Muitos apps abertos ao mesmo tempo."

    echo -e "\n${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "Pressione Enter para voltar..."
    read -rp ""
}

# ─── Suporte a argumentos CLI (Modo Não-Interativo / Atalhos) ────────────────
case "${1:-}" in
    --off|off)
        toggle_ecores 0 "Desativando E-cores" "${RED}⏻${NC}"
        exit 0
        ;;
    --on|on)
        toggle_ecores 1 "Ativando E-cores" "${GREEN}⏻${NC}"
        exit 0
        ;;
    --toggle|toggle)
        # Detectar estado misto e normalizar
        online=0
        offline=0
        for cpu in "${E_CORES[@]}"; do
            p="/sys/devices/system/cpu/cpu${cpu}/online"
            if [[ -f "$p" ]]; then
                s=$(cat "$p" 2>/dev/null)
                if [[ "$s" == "1" ]]; then
                    ((online++)) || true
                else
                    ((offline++)) || true
                fi
            else
                ((online++)) || true
            fi
        done
        if [[ $online -gt 0 && $offline -gt 0 ]]; then
            log "${YELLOW}⚠ Estado misto detectado: ${online} online, ${offline} offline. Normalizando...${NC}"
        fi
        if [[ $online -gt 0 ]]; then
            toggle_ecores 0 "Desativando E-cores" "${RED}⏻${NC}"
        else
            toggle_ecores 1 "Ativando E-cores" "${GREEN}⏻${NC}"
        fi
        exit 0
        ;;
    --status|status)
        show_status
        exit 0
        ;;
    --version|-V)
        echo -e "${BOLD}toggle-ecores-generic${NC} v${VERSION}"
        echo -e "${CYAN}CPU:${NC}     ${CPU_MODEL}"
        echo -e "${CYAN}Kernel:${NC}  $(uname -r)"
        echo -e "${CYAN}P-cores:${NC} ${P_COUNT}   ${CYAN}E-cores:${NC} ${E_COUNT}   ${CYAN}Total:${NC} ${TOTAL_CPUS}"
        count_ecores_state
        echo -e "${CYAN}Estado:${NC}  ${GREEN}${E_ONLINE} online${NC} / ${RED}${E_OFFLINE} offline${NC}"
        if is_persist_active; then
            echo -e "${CYAN}Persist:${NC} ${GREEN}Ativa${NC} (E-cores OFF no boot)"
        else
            echo -e "${CYAN}Persist:${NC} ${YELLOW}Inativa${NC}"
        fi
        exit 0
        ;;
    --help|-h)
        show_usage
        exit 0
        ;;
    "")
        # Sem argumentos → modo interativo (cai pro menu abaixo)
        ;;
    *)
        echo -e "${RED}✗ Argumento desconhecido: ${1}${NC}"
        show_usage
        exit 1
        ;;
esac

# ─── Modo Interativo (Menu) ──────────────────────────────────────────────────
while true; do
    count_ecores_state
    clear
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         Gerenciador Universal de E-cores (Intel) v${VERSION}       ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${CYAN}💻 CPU:${NC} ${CPU_MODEL}"
    echo -e "${GREEN}🚀 P-cores:${NC} ${P_COUNT}   ${YELLOW}🔋 E-cores:${NC} ${GREEN}${E_ONLINE}↑${NC}/${RED}${E_OFFLINE}↓${NC} (de ${E_COUNT})   ${BLUE}📊 Total:${NC} ${TOTAL_CPUS}"

    # Indicador de persistência
    if is_persist_active; then
        echo -e "${CYAN}🔁 Persistência:${NC} ${GREEN}Ativa${NC} (E-cores OFF no boot)"
    fi

    echo -e "\n${BOLD}Escolha uma opção:${NC}"
    echo -e "  ${RED}1)${NC} Desligar E-cores (Modo Gaming / Performance Pura)"
    echo -e "  ${GREEN}2)${NC} Ligar E-cores (Modo Padrão / Multitarefa)"
    echo -e "  ${BLUE}3)${NC} Ver status atual dos núcleos"
    echo -e "  ${CYAN}4)${NC} Persistência no boot (ativar/desativar)"
    echo -e "  ${YELLOW}5)${NC} O que são E-cores e quando usar? (Ajuda)"
    echo -e "  ${BOLD}6)${NC} Sair"
    echo ""
    read -rp "➜ Opção (1-6): " opcao

    case "$opcao" in
        1)
            read -rp "Confirma desativar ${E_COUNT} E-cores? (s/N): " confirm
            if [[ "${confirm,,}" == "s" ]]; then
                toggle_ecores 0 "Desativando E-cores" "${RED}⏻${NC}"
            else
                echo -e "${YELLOW}Cancelado.${NC}"
            fi
            read -rp "Pressione Enter para continuar..."
            ;;
        2)
            read -rp "Confirma ativar ${E_COUNT} E-cores? (s/N): " confirm
            if [[ "${confirm,,}" == "s" ]]; then
                toggle_ecores 1 "Ativando E-cores" "${GREEN}⏻${NC}"
            else
                echo -e "${YELLOW}Cancelado.${NC}"
            fi
            read -rp "Pressione Enter para continuar..."
            ;;
        3)
            show_status
            read -rp "Pressione Enter para continuar..."
            ;;
        4)
            if is_persist_active; then
                echo -e "\n${CYAN}Persistência está ${GREEN}ATIVA${NC} ${CYAN}(E-cores OFF no boot).${NC}"
                read -rp "Deseja desativar a persistência? (s/N): " confirm
                if [[ "${confirm,,}" == "s" ]]; then
                    persist_state 1
                fi
            else
                echo -e "\n${CYAN}Persistência está ${YELLOW}INATIVA${NC} ${CYAN}(padrão do sistema no boot).${NC}"
                read -rp "Deseja ativar persistência (E-cores OFF no boot)? (s/N): " confirm
                if [[ "${confirm,,}" == "s" ]]; then
                    persist_state 0
                fi
            fi
            read -rp "Pressione Enter para continuar..."
            ;;
        5)
            show_help
            ;;
        6)
            echo -e "\n${GREEN}Saindo... Até logo!${NC}\n"
            exit 0
            ;;
        *)
            echo -e "\n${RED}✗ Opção inválida! Digite um número de 1 a 6.${NC}"
            sleep 2
            ;;
    esac
done
