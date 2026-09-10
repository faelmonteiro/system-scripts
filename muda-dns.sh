#!/bin/bash
set -o pipefail
set -u

# Verifica se está rodando como root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Este script precisa ser executado como root."
    echo "Use: sudo $0"
    exit 1
fi

# Lock de instância exclusiva
acquire_lock() {
    local lock_file="/run/muda-dns.lock"
    exec 9>"$lock_file" 2>/dev/null || return 0
    if ! flock -n 9; then
        echo "❌ Outra instância do muda-dns já está em execução."
        exit 1
    fi
}
acquire_lock

# Verifica se o dnscrypt-proxy está instalado
if ! command -v dnscrypt-proxy &> /dev/null; then
    echo "❌ dnscrypt-proxy não encontrado. Instale-o primeiro."
    exit 1
fi

# Cores
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    ESC=$'\033'
    RESET="${ESC}[0m"
    BOLD="${ESC}[1m"
    RED="${ESC}[0;31m"
    GREEN="${ESC}[0;32m"
    YELLOW="${ESC}[0;33m"
    BLUE="${ESC}[0;34m"
    MAGENTA="${ESC}[0;35m"
    CYAN="${ESC}[0;36m"
    WHITE="${ESC}[1;37m"
else
    RESET='' BOLD='' RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE=''
fi

# Arquivos
TOML_FILE="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
RESOLV_FILE="/etc/resolv.conf"
BACKUP_FILE="/etc/resolv.conf.muda-dns.bak"
NM_CONF_DIR="/etc/NetworkManager/conf.d"
NM_DNS_FILE="/etc/NetworkManager/conf.d/dns-muda-dns.conf"
LOG_FILE="/var/log/muda-dns.log"

# Verifica se o arquivo de configuração existe
if [ ! -f "$TOML_FILE" ]; then
    echo "❌ Arquivo de configuração não encontrado: $TOML_FILE"
    echo "   O dnscrypt-proxy está instalado corretamente?"
    exit 1
fi

# Rotação de log (evita crescimento indefinido mantendo últimas 1000 linhas se > 1MB)
rotate_log() {
    local file="$1"
    local max_size="${2:-1048576}" # 1MB
    if [ -f "$file" ]; then
        local sz
        sz=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [ "$sz" -ge "$max_size" ]; then
            tail -n 1000 "$file" > "${file}.tmp" 2>/dev/null && mv -f "${file}.tmp" "$file" 2>/dev/null || true
        fi
    fi
}

# Log
log() {
    rotate_log "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Trap para Ctrl+C
cleanup() {
    echo
    echo "${YELLOW}⚠️ Interrompido! O estado do DNS pode estar inconsistente.${RESET}"
    echo "${YELLOW}Execute novamente e use a opção de Status para verificar.${RESET}"
    exit 130
}
trap cleanup INT TERM

# Pausa
pause() {
    echo
    read -rp "Pressione Enter para continuar..." _
}

# Função para aplicar servidores no dnscrypt-proxy.toml
apply_servers() {
    local servers="$1"

    if [ ! -f "$TOML_FILE" ]; then
        echo "${RED}❌ Arquivo não encontrado: $TOML_FILE${RESET}"
        return 1
    fi

    if grep -Eq '^[[:space:]]*server_names[[:space:]]*=' "$TOML_FILE"; then
        sed -i -E "s|^[[:space:]]*server_names[[:space:]]*=.*|server_names = $servers|" "$TOML_FILE"
    else
        echo "server_names = $servers" >> "$TOML_FILE"
    fi

    # Validação: confirma que a linha server_names foi gravada
    if ! grep -Eq '^[[:space:]]*server_names[[:space:]]*=' "$TOML_FILE"; then
        echo "${RED}❌ Falha ao gravar servidores no $TOML_FILE${RESET}"
        return 1
    fi
}

# Função para configurar o DNS local
setup_local_dns() {
    # Faz backup apenas uma vez, se ainda não existir
    if [ ! -e "$BACKUP_FILE" ] && [ -e "$RESOLV_FILE" ]; then
        cp -a "$RESOLV_FILE" "$BACKUP_FILE" 2>/dev/null
    fi

    # Configura o NetworkManager para não reescrever o resolv.conf
    if [ -d "$NM_CONF_DIR" ]; then
        cat <<EOF > "$NM_DNS_FILE"
[main]
dns=none
rc-manager=unmanaged
EOF
        chmod 644 "$NM_DNS_FILE" 2>/dev/null
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            systemctl reload NetworkManager 2>/dev/null || nmcli general reload dns 2>/dev/null
        fi
    fi

    # Desmascara serviços caso tenham sido mascarados antes
    systemctl unmask systemd-resolved 2>/dev/null

    # Para e desabilita systemd-resolved para evitar conflito com 127.0.0.1
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
    fi

    # Se systemd-networkd estiver inativo, mantém desabilitado sem derrubar rede ativa
    if ! systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        systemctl disable systemd-networkd 2>/dev/null || true
    fi

    # Remove temporariamente a proteção imutável se existir
    chattr -i "$RESOLV_FILE" 2>/dev/null

    # Aponta o DNS para o dnscrypt-proxy local
    echo "nameserver 127.0.0.1" > "$RESOLV_FILE"

    # Protege o resolv.conf contra sobrescrita
    chattr +i "$RESOLV_FILE" 2>/dev/null

    # Reinicia o dnscrypt-proxy
    if ! systemctl restart dnscrypt-proxy; then
        echo "${RED}❌ Falha ao reiniciar dnscrypt-proxy! Verifique com: journalctl -xeu dnscrypt-proxy${RESET}"
        return 1
    fi
}

# Função para verificar se o DNS está resolvendo (retry com backoff)
verify_dns() {
    echo "${CYAN}🔍 Testando resolução DNS...${RESET}"
    local attempts=0
    local max_attempts=5

    while [ "$attempts" -lt "$max_attempts" ]; do
        if command -v dig &>/dev/null; then
            if dig +short +timeout=2 google.com @127.0.0.1 2>/dev/null | grep -qE '^[0-9]'; then
                echo "${GREEN}✅ DNS está resolvendo corretamente via 127.0.0.1${RESET}"
                return 0
            fi
        elif command -v nslookup &>/dev/null; then
            if nslookup -timeout=2 google.com 127.0.0.1 >/dev/null 2>&1; then
                echo "${GREEN}✅ DNS está resolvendo corretamente via 127.0.0.1${RESET}"
                return 0
            fi
        else
            echo "${YELLOW}⚠️ Nenhuma ferramenta de teste DNS encontrada (dig/nslookup). Pulando verificação.${RESET}"
            return 0
        fi

        attempts=$((attempts + 1))
        if [ "$attempts" -lt "$max_attempts" ]; then
            sleep 1
        fi
    done

    echo "${RED}❌ DNS NÃO está resolvendo após $max_attempts tentativas! Verifique a configuração.${RESET}"
    echo "${YELLOW}   Dica: journalctl -xeu dnscrypt-proxy${RESET}"
    return 1
}

# Função para restaurar o padrão
restore_dns() {
    # Remove a override do NetworkManager criada pelo script
    if [ -f "$NM_DNS_FILE" ]; then
        rm -f "$NM_DNS_FILE" 2>/dev/null
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            systemctl reload NetworkManager 2>/dev/null || nmcli general reload dns 2>/dev/null
        fi
    fi

    # Remove proteção de imutável, se existir
    chattr -i "$RESOLV_FILE" 2>/dev/null

    # Restaura backup com segurança (sem deletar resolv.conf antes da cópia)
    if [ -e "$BACKUP_FILE" ]; then
        cp -a "$BACKUP_FILE" "$RESOLV_FILE" 2>/dev/null && rm -f "$BACKUP_FILE" 2>/dev/null
    else
        # Se não houver backup, tenta voltar para o padrão systemd-resolved
        ln -sf /run/systemd/resolve/stub-resolv.conf "$RESOLV_FILE" 2>/dev/null || \
        ln -sf /run/systemd/resolve/resolv.conf "$RESOLV_FILE" 2>/dev/null
    fi

    # Reativa serviços de rede padrão
    systemctl unmask systemd-resolved 2>/dev/null
    systemctl enable systemd-resolved 2>/dev/null
    systemctl restart systemd-resolved 2>/dev/null
}

# Função de status
show_status() {
    local servers
    local mode_icon
    local mode_name
    local dnscrypt_active
    local resolved_active
    local resolved_enabled
    local networkd_active
    local networkd_enabled

    servers=$(grep -E '^[[:space:]]*server_names' "$TOML_FILE" 2>/dev/null | sed -E 's/^[[:space:]]*server_names[[:space:]]*=[[:space:]]*//')

    if grep -E '^[[:space:]]*server_names' "$TOML_FILE" 2>/dev/null | grep -q 'cloudflare-security-443'; then
        mode_icon="🏫"
        mode_name="ESCOLA (stealth na porta 443)"
    elif grep -E '^[[:space:]]*server_names' "$TOML_FILE" 2>/dev/null | grep -q 'adguard-dns-filter'; then
        mode_icon="🏠"
        mode_name="CASA (filtro padrão)"
    else
        mode_icon="❓"
        mode_name="Desconhecido ou personalizado"
    fi

    dnscrypt_active=$(systemctl is-active dnscrypt-proxy 2>/dev/null)
    resolved_active=$(systemctl is-active systemd-resolved 2>/dev/null)
    resolved_enabled=$(systemctl is-enabled systemd-resolved 2>/dev/null)
    networkd_active=$(systemctl is-active systemd-networkd 2>/dev/null)
    networkd_enabled=$(systemctl is-enabled systemd-networkd 2>/dev/null)

    echo
    echo "${BOLD}${MAGENTA}=================== 📊 STATUS ===================${RESET}"
    echo "${BOLD}Modo detectado:${RESET} ${YELLOW}${mode_icon} ${mode_name}${RESET}"
    echo "${BOLD}Servidores configurados:${RESET} ${CYAN}${servers:-não encontrado}${RESET}"
    echo

    echo "${BOLD}${BLUE}Serviços:${RESET}"

    if [ "$dnscrypt_active" = "active" ]; then
        echo "${GREEN}✅ dnscrypt-proxy: ATIVO${RESET}"
    else
        echo "${RED}❌ dnscrypt-proxy: INATIVO (${dnscrypt_active:-desconhecido})${RESET}"
    fi

    if [ "$resolved_active" = "active" ]; then
        echo "${GREEN}✅ systemd-resolved: ATIVO (${resolved_enabled:-desconhecido})${RESET}"
    else
        echo "${YELLOW}⚠️ systemd-resolved: INATIVO (${resolved_active:-desconhecido}/${resolved_enabled:-desconhecido})${RESET}"
    fi

    if [ "$networkd_active" = "active" ]; then
        echo "${GREEN}✅ systemd-networkd: ATIVO (${networkd_enabled:-desconhecido})${RESET}"
    else
        echo "${YELLOW}⚠️ systemd-networkd: INATIVO (${networkd_active:-desconhecido}/${networkd_enabled:-desconhecido})${RESET}"
    fi

    if [ -f "$NM_DNS_FILE" ] || [ -f "/etc/NetworkManager/conf.d/dns.conf" ]; then
        echo "${GREEN}✅ NetworkManager: Gerenciamento de DNS desativado (dns=none)${RESET}"
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "${YELLOW}⚠️ NetworkManager: Ativo sem trava explicita (pode tentar atualizar resolv.conf)${RESET}"
    fi

    echo
    echo "${BOLD}${BLUE}DNS local:${RESET}"

    if [ -e "$RESOLV_FILE" ] || [ -L "$RESOLV_FILE" ]; then
        if grep -q '^nameserver 127.0.0.1' "$RESOLV_FILE" 2>/dev/null; then
            echo "${GREEN}✅ /etc/resolv.conf: está usando 127.0.0.1${RESET}"
        else
            echo "${RED}❌ /etc/resolv.conf: NÃO está usando 127.0.0.1${RESET}"
        fi

        if [ ! -L "$RESOLV_FILE" ] && lsattr "$RESOLV_FILE" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            echo "${YELLOW}🔒 /etc/resolv.conf: está IMUTÁVEL (chattr +i)${RESET}"
        else
            echo "${GREEN}🔓 /etc/resolv.conf: está EDITÁVEL (sem chattr +i)${RESET}"
        fi

        echo
        echo "${BOLD}Conteúdo atual de /etc/resolv.conf:${RESET}"
        sed 's/^/    /' "$RESOLV_FILE" 2>/dev/null || echo "    (vazio)"
    else
        echo "${RED}❌ /etc/resolv.conf não existe.${RESET}"
    fi

    echo

    if [ -e "$BACKUP_FILE" ]; then
        echo "${GREEN}✅ Backup existe: $BACKUP_FILE${RESET}"
    else
        echo "${YELLOW}⚠️ Backup não existe.${RESET}"
    fi

    echo
    echo "${BOLD}${BLUE}Verificação de Escuta Local:${RESET}"
    if ss -tulpn 2>/dev/null | grep -E '"dnscrypt-proxy"' | grep -qE ':53[[:space:]]|:53$'; then
        echo "${GREEN}✅ dnscrypt-proxy está escutando na porta 53 (127.0.0.1)${RESET}"
    else
        echo "${RED}❌ dnscrypt-proxy NÃO está escutando na porta 53!${RESET}"
    fi

    echo "${BOLD}${MAGENTA}=================================================${RESET}"
}

# Modo CLI (sem menu interativo)
if [ -n "$1" ]; then
    case "$1" in
        escola|1)
            if apply_servers '["quad9-dnscrypt-ip4-filter-pri", "cloudflare-security-443", "nextdns-filter"]' && setup_local_dns; then
                log "✅ Modo ESCOLA ativado (CLI)"
                echo "${GREEN}✅ Modo ESCOLA ativado (stealth, porta 443)!${RESET}"
                verify_dns
            else
                log "❌ Falha ao ativar Modo ESCOLA (CLI)"
                echo "${RED}❌ Não foi possível aplicar os servidores do Modo ESCOLA.${RESET}"
            fi
            ;;
        casa|2)
            if apply_servers '["quad9-dnscrypt-ip4-filter-alt", "cloudflare-security", "adguard-dns-filter", "nextdns-filter"]' && setup_local_dns; then
                log "✅ Modo CASA ativado (CLI)"
                echo "${GREEN}✅ Modo CASA ativado (filtro + DNSSEC + criptografia)!${RESET}"
                verify_dns
            else
                log "❌ Falha ao ativar Modo CASA (CLI)"
                echo "${RED}❌ Não foi possível aplicar os servidores do Modo CASA.${RESET}"
            fi
            ;;
        restaurar|restore|3)
            restore_dns
            log "♻️ DNS restaurado para padrão (CLI)"
            echo "${GREEN}✅ Configurações restauradas.${RESET}"
            ;;
        status|4)
            show_status
            ;;
        *)
            echo "Uso: $0 [escola|casa|restaurar|status]"
            exit 1
            ;;
    esac
    exit $?
fi

# Menu em loop
while true; do
    clear

    # Detecta modo atual para mostrar no menu
    current_mode="${YELLOW}❓ Desconhecido${RESET}"
    if grep -E '^[[:space:]]*server_names' "$TOML_FILE" 2>/dev/null | grep -q 'cloudflare-security-443'; then
        current_mode="${GREEN}🏫 ESCOLA${RESET}"
    elif grep -E '^[[:space:]]*server_names' "$TOML_FILE" 2>/dev/null | grep -q 'adguard-dns-filter'; then
        current_mode="${GREEN}🏠 CASA${RESET}"
    fi

    echo "${BOLD}${BLUE}════════════════════════════════════════════${RESET}"
    echo "${BOLD}${BLUE}   🌐 GERENCIADOR DE DNS (CASA/ESCOLA)${RESET}"
    echo "${BOLD}${BLUE}   Modo atual: ${RESET}${current_mode}"
    echo "${BOLD}${BLUE}════════════════════════════════════════════${RESET}"
    echo "${YELLOW}1) 🏫 Modo ESCOLA ${RESET}${CYAN}(porta 443 - stealth)${RESET}"
    echo "${YELLOW}2) 🏠 Modo CASA ${RESET}${CYAN}(filtro padrão)${RESET}"
    echo "${YELLOW}3) ♻️  Restaurar Padrão ${RESET}${CYAN}(systemd-resolved)${RESET}"
    echo "${YELLOW}4) 📊 Status${RESET}"
    echo "${YELLOW}5) 🚪 Sair${RESET}"
    echo "${BOLD}${BLUE}════════════════════════════════════════════${RESET}"

    read -rp "Escolha uma opção (1-5): " opcao

    case "$opcao" in
        1)
            # Servidores stealth, porta 443, para evitar bloqueio na escola
            if apply_servers '["quad9-dnscrypt-ip4-filter-pri", "cloudflare-security-443", "nextdns-filter"]' && setup_local_dns; then
                log "✅ Modo ESCOLA ativado"
                echo "${GREEN}✅ Modo ESCOLA ativado (stealth, porta 443)!${RESET}"
                verify_dns
            else
                log "❌ Falha ao ativar Modo ESCOLA"
                echo "${RED}❌ Não foi possível aplicar os servidores do Modo ESCOLA.${RESET}"
            fi
            pause
            ;;

        2)
            # Servidores normais com filtro para casa
            if apply_servers '["quad9-dnscrypt-ip4-filter-alt", "cloudflare-security", "adguard-dns-filter", "nextdns-filter"]' && setup_local_dns; then
                log "✅ Modo CASA ativado"
                echo "${GREEN}✅ Modo CASA ativado (filtro + DNSSEC + criptografia)!${RESET}"
                verify_dns
            else
                log "❌ Falha ao ativar Modo CASA"
                echo "${RED}❌ Não foi possível aplicar os servidores do Modo CASA.${RESET}"
            fi
            pause
            ;;

        3)
            echo "${YELLOW}⚠️ Isso vai desfazer a configuração e voltar ao systemd-resolved.${RESET}"
            read -rp "Tem certeza? (s/N): " confirma
            if [[ "$confirma" =~ ^[sS]$ ]]; then
                restore_dns
                log "♻️ DNS restaurado para padrão do sistema"
                echo "${GREEN}✅ Configurações de rede restauradas para o padrão do sistema.${RESET}"
            else
                echo "${CYAN}Operação cancelada.${RESET}"
            fi
            pause
            ;;

        4)
            show_status
            pause
            ;;

        5)
            echo "${YELLOW}🚪 Saindo...${RESET}"
            exit 0
            ;;

        *)
            echo "${RED}❌ Opção inválida. Tente novamente.${RESET}"
            sleep 1
            ;;
    esac
done
