#!/bin/bash
# Linux Hardening Manager - Interativo, Educativo, Cross-Distro e com Status
set -uo pipefail

VERSION="1.2.0"
LOG_FILE="/var/log/hardening-manager.log"

rotate_log() {
    local file="$1"
    local max_size="${2:-1048576}" # 1MB
    if [[ -f "$file" ]]; then
        local sz
        sz=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [[ "$sz" -ge "$max_size" ]]; then
            tail -n 1000 "$file" > "${file}.tmp" 2>/dev/null && mv -f "${file}.tmp" "$file" 2>/dev/null || true
        fi
    fi
}

log() {
    rotate_log "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# ==========================================
# 🎨 CORES E ÍCONES
# ==========================================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    WHITE='\033[1;37m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' MAGENTA='' BOLD='' WHITE='' RESET=''
fi

# ==========================================
# 🛠️ FUNÇÕES AUXILIARES
# ==========================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Erro: Este script precisa ser executado como root (use sudo).${RESET}"
        exit 1
    fi
}

acquire_lock() {
    local lock_file="/run/hardening-manager.lock"
    exec 7>"$lock_file" 2>/dev/null || return 0
    if ! flock -n 7; then
        echo -e "${RED}❌ Outra instância do hardening-manager já está em execução.${RESET}"
        exit 1
    fi
}

backup_file() {
    local file=$1
    if [[ -f "$file" && ! -f "${file}.harden_bak" ]]; then
        cp -a "$file" "${file}.harden_bak"
        echo -e "   ${CYAN}💾 Backup criado: ${file}.harden_bak${RESET}"
    fi
}

detect_bootloader() {
    if [[ -f /etc/default/grub ]]; then
        echo "grub"
    elif command -v bootctl &>/dev/null && bootctl status &>/dev/null; then
        echo "systemd-boot"
    else
        echo "unknown"
    fi
}

apply_bootloader_params() {
    local params=$1
    local bl=$(detect_bootloader)

    if [[ "$bl" == "grub" ]]; then
        backup_file "/etc/default/grub"
        local current_line
        current_line=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub || echo "")
        local new_params=""
        for param in $params; do
            if ! echo "$current_line" | grep -qw "$param"; then
                new_params+="$param "
            fi
        done
        if [[ -n "$new_params" ]]; then
            sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${new_params}/" /etc/default/grub

            if command -v update-grub &>/dev/null; then
                update-grub >/dev/null 2>&1
            elif command -v grub-mkconfig &>/dev/null; then
                grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
            fi
            echo -e "   ${GREEN}✅ GRUB atualizado.${RESET}"
        else
            echo -e "   ${YELLOW}⚠️ Parâmetros já presentes no GRUB.${RESET}"
        fi
    elif [[ "$bl" == "systemd-boot" ]]; then
        echo -e "   ${CYAN}🔧 Systemd-boot detectado. Atualizando entradas...${RESET}"
        for entry in /boot/loader/entries/*.conf; do
            if [[ -f "$entry" ]]; then
                backup_file "$entry"
                local entry_opts
                entry_opts=$(grep "^options" "$entry" || echo "")
                local new_params=""
                for param in $params; do
                    if ! echo "$entry_opts" | grep -qw "$param"; then
                        new_params+="$param "
                    fi
                done
                if [[ -n "$new_params" ]]; then
                    sed -i "/^options/ s/$/ ${new_params}/" "$entry"
                fi
            fi
        done
        echo -e "   ${GREEN}✅ Entradas do Systemd-boot atualizadas.${RESET}"
    else
        echo -e "   ${RED}❌ Nenhum bootloader suportado detectado.${RESET}"
    fi
}

# ==========================================
# 📊 FUNÇÃO DE STATUS
# ==========================================

show_status() {
    clear
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "${BOLD}${CYAN}      📊 STATUS ATUAL DO SISTEMA${RESET}"
    echo -e "${BOLD}${CYAN}======================================================${RESET}\n"

    # 1. Sysctl
    if [[ -f /etc/sysctl.d/99-security-hardening.conf ]]; then
        echo -e "${GREEN}✅ Sysctl (Rede e Memória):${RESET} ${BOLD}APLICADO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Mitiga IP Spoofing, SYN Flood, esconde logs do kernel e força ASLR.\n"
    else
        echo -e "${RED}❌ Sysctl (Rede e Memória):${RESET} ${BOLD}NÃO APLICADO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Protege contra ataques de rede e exploração de memória.\n"
    fi

    # 2. NetworkManager IPv6
    local nm_privacy_active=0
    if [[ -f /etc/NetworkManager/conf.d/ipv6-privacy.conf ]]; then
        nm_privacy_active=1
    fi
    if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        if nmcli -t -f ipv6.ip6-privacy connection show --active 2>/dev/null | grep -q '2'; then
            nm_privacy_active=1
        fi
    fi
    if [[ $nm_privacy_active -eq 1 ]]; then
        echo -e "${GREEN}✅ Privacidade IPv6:${RESET} ${BOLD}APLICADO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Gera endereços IPv6 temporários, dificultando rastreamento em redes públicas.\n"
    else
        echo -e "${RED}❌ Privacidade IPv6:${RESET} ${BOLD}NÃO APLICADO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Evita que seu dispositivo seja rastreado pelo endereço MAC via IPv6.\n"
    fi

    # 3. Bootloader
    local bl=$(detect_bootloader)
    local boot_params_found=0
    if [[ "$bl" == "grub" && -f /etc/default/grub ]]; then
        if grep -q "init_on_alloc=1" /etc/default/grub; then
            boot_params_found=1
        fi
    elif [[ "$bl" == "systemd-boot" ]]; then
        if grep -q "init_on_alloc=1" /boot/loader/entries/*.conf 2>/dev/null; then
            boot_params_found=1
        fi
    fi

    if [[ $boot_params_found -eq 1 ]]; then
        echo -e "${GREEN}✅ Bootloader (Kernel):${RESET} ${BOLD}PROTEGIDO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Ativa init_on_alloc=1, slab_nomerge, vsyscall=none e embaralha a memória.\n"
    else
        echo -e "${RED}❌ Bootloader (Kernel):${RESET} ${BOLD}PADRÃO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Adiciona mitigações modernas contra exploits de memória no boot.\n"
    fi

    # 4. Core Dumps
    if grep -q "^\* hard core 0" /etc/security/limits.conf 2>/dev/null || \
       grep -q "^Storage=none" /etc/systemd/coredump.conf 2>/dev/null || \
       grep -q "^Storage=none" /etc/systemd/coredump.conf.d/hardening.conf 2>/dev/null; then
        echo -e "${GREEN}✅ Core Dumps:${RESET} ${BOLD}DESATIVADOS${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Impede que a RAM de programas que crasham seja salva no disco (evita vazamento de senhas).\n"
    else
        echo -e "${RED}❌ Core Dumps:${RESET} ${BOLD}ATIVOS${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Salva memória de programas crashados no disco (risco forense).\n"
    fi

    # 5. Blacklist de Módulos
    if [[ -f /etc/modprobe.d/security-blacklist.conf ]]; then
        if grep -qE "install bluetooth /bin/(false|true)" /etc/modprobe.d/security-blacklist.conf; then
            echo -e "${GREEN}✅ Blacklist de Módulos:${RESET} ${BOLD}AVANÇADO (Paranoid)${RESET}"
            echo -e "   ${WHITE}O que faz:${RESET} Bloqueia protocolos obscuros, filesystems raros, Bluetooth, Webcam e Thunderbolt.\n"
        else
            echo -e "${YELLOW}⚠️ Blacklist de Módulos:${RESET} ${BOLD}INTERMEDIÁRIO${RESET}"
            echo -e "   ${WHITE}O que faz:${RESET} Bloqueia protocolos de rede antigos e filesystems raros (HFS, UDF).\n"
        fi
    else
        echo -e "${RED}❌ Blacklist de Módulos:${RESET} ${BOLD}NÃO APLICADO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Remove drivers vulneráveis ou desnecessários do kernel.\n"
    fi

    # 6. AppArmor
    if systemctl is-enabled apparmor &>/dev/null; then
        echo -e "${GREEN}✅ AppArmor:${RESET} ${BOLD}ATIVO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Confina programas vulneráveis, limitando o acesso a arquivos e rede.\n"
    else
        echo -e "${RED}❌ AppArmor:${RESET} ${BOLD}INATIVO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Controle de Acesso Obrigatório (MAC) para conter exploits.\n"
    fi

    # 7. eBPF & User Namespaces
    local ebpf_status userns_status
    ebpf_status=$(sysctl -n kernel.unprivileged_bpf_disabled 2>/dev/null || echo "0")
    userns_status=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "1")
    if [[ "$ebpf_status" == "1" || "$ebpf_status" == "2" ]]; then
        echo -e "${GREEN}✅ eBPF Não Privilegiado:${RESET} ${BOLD}DESATIVADO (kernel.unprivileged_bpf_disabled=${ebpf_status})${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Impede que usuários normais executem código eBPF JIT no Kernel (fecha classe inteira de LPE exploits).\n"
    else
        echo -e "${YELLOW}⚠️ eBPF Não Privilegiado:${RESET} ${BOLD}ATIVO${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Permite execução de programas eBPF por usuários sem privilégios.\n"
    fi

    if [[ "$userns_status" == "0" ]]; then
        echo -e "${GREEN}✅ User Namespaces Não Privilegiados:${RESET} ${BOLD}RESTRITO (unprivileged_userns_clone=0)${RESET}"
        echo -e "   ${WHITE}O que faz:${RESET} Bloqueia criação não autorizada de namespaces de usuário (mitiga exploração de exploits de Kernel).\n"
    fi

    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    if [[ -z "${CLI_ACTION:-}" ]]; then
        read -rp "Pressione ENTER para voltar ao menu..."
    fi
}

# ==========================================
# 👁️ TELA DE PREVIEW (O que vai acontecer?)
# ==========================================

show_preview() {
    local level=$1
    clear
    echo -e "${BOLD}${MAGENTA}======================================================${RESET}"
    echo -e "${BOLD}${MAGENTA}      👁️  PREVIEW: O QUE ACONTECERÁ COM SEU PC?${RESET}"
    echo -e "${BOLD}${MAGENTA}======================================================${RESET}"

    case $level in
        1)
            echo -e "${GREEN}🟢 NÍVEL 1: BÁSICO (Foco em Rede e Memória)${RESET}\n"
            echo -e "${CYAN}📝 ARQUIVOS QUE SERÃO MODIFICADOS:${RESET}"
            echo -e "  • ${BOLD}/etc/sysctl.d/99-security-hardening.conf${RESET} (Criado)"
            echo -e "  • ${BOLD}/etc/NetworkManager/conf.d/ipv6-privacy.conf${RESET} (Criado, se NM existir)"
            echo -e "  • ${BOLD}Bootloader (GRUB/Systemd-boot)${RESET} (Atualizado)\n"

            echo -e "${YELLOW}💡 CENÁRIOS PRÁTICOS (Exemplos Reais):${RESET}"
            echo -e "  ${BOLD}1. Proteção contra Rastreamento (IPv6):${RESET}"
            echo -e "     ${WHITE}Hoje:${RESET} Seu PC gera um IP fixo baseado na sua placa de rede. Redes Wi-Fi públicas podem rastrear seu dispositivo."
            echo -e "     ${GREEN}Depois:${RESET} Seu IPv6 será temporário e aleatório. Você se torna 'invisível' para rastreadores de rede.\n"

            echo -e "  ${BOLD}2. Defesa contra IP Spoofing:${RESET}"
            echo -e "     ${WHITE}Hoje:${RESET} Um hacker na sua rede pode enviar pacotes fingindo ser o seu roteador."
            echo -e "     ${GREEN}Depois:${RESET} O Kernel ativará o 'Reverse Path Filtering' e rejeitará pacotes com origens falsas automaticamente.\n"

            echo -e "  ${BOLD}3. Mitigação de Exploits de Memória e eBPF:${RESET}"
            echo -e "     ${WHITE}Hoje:${RESET} Se um programa tiver uma falha, hackers usam eBPF JIT e endereços de memória previsíveis para injetar exploits."
            echo -e "     ${GREEN}Depois:${RESET} eBPF sem root desativado, ptrace bloqueado e ${BOLD}init_on_alloc=1${RESET} farão o sistema limpar e proteger a RAM.\n"
            ;;
        2)
            echo -e "${YELLOW}🟡 NÍVEL 2: INTERMEDIÁRIO (Privacidade e Superfície de Ataque)${RESET}\n"
            echo -e "${CYAN}📝 O QUE SERÁ FEITO:${RESET}"
            echo -e "  • ${BOLD}Tudo do Nível 1${RESET} +"
            echo -e "  • Desativar ${BOLD}Core Dumps${RESET} (Despejos de memória)"
            echo -e "  • Blacklist de ${BOLD}Filesystems${RESET} (HFS, UDF) e ${BOLD}Protocolos${RESET} obscuros (SCTP, DCCP)\n"

            echo -e "${YELLOW}💡 CENÁRIOS PRÁTICOS (Exemplos Reais):${RESET}"
            echo -e "  ${BOLD}1. O Fim dos Core Dumps (Proteção de Senhas):${RESET}"
            echo -e "     ${WHITE}Hoje:${RESET} Se seu navegador travar, o Linux salva o conteúdo da RAM (abas, senhas digitadas) em um arquivo no disco chamado 'core dump'."
            echo -e "     ${GREEN}Depois:${RESET} O sistema é proibido de salvar a RAM no disco. Se travar, simplesmente fecha. Hackers forenses não poderão recuperar seus dados.\n"

            echo -e "  ${BOLD}2. Redução de Superfície de Ataque:${RESET}"
            echo -e "     ${WHITE}Hoje:${RESET} O Linux carrega drivers para coisas que você nunca usou (Redes Token Ring, Bluetooth antigo, etc). Se houver falha neles, você é vulnerável."
            echo -e "     ${GREEN}Depois:${RESET} Esses drivers são bloqueados no Kernel. O código vulnerável nem sequer existe na memória do seu PC.\n"

            echo -e "  ${RED}⚠️ O QUE VAI QUEBRAR (Desafios):${RESET}"
            echo -e "     ${RED}❌${RESET} Você ${BOLD}NÃO${RESET} conseguirá mais ler HDs externos formatados em Mac (HFS+)."
            echo -e "     ${RED}❌${RESET} Você ${BOLD}NÃO${RESET} conseguirá assistir DVDs de filmes antigos (UDF)."
            ;;
        3)
            echo -e "${RED}🔴 NÍVEL 3: AVANÇADO (Paranoid / Espionagem Física)${RESET}\n"
            echo -e "${CYAN}📝 O QUE SERÁ FEITO:${RESET}"
            echo -e "  • ${BOLD}Tudo do Nível 1 e 2${RESET} +"
            echo -e "  • Desativar ${BOLD}User Namespaces sem privilégios${RESET} (se suportado pelo kernel)"
            echo -e "  • Bloqueio Físico de ${BOLD}Webcams, Bluetooth e Thunderbolt${RESET} no Kernel."
            echo -e "  • Ativação do ${BOLD}AppArmor${RESET} (Controle de Acesso Obrigatório, se instalado)\n"

            echo -e "${YELLOW}💡 CENÁRIOS PRÁTICOS (Exemplos Reais):${RESET}"
            echo -e "  ${BOLD}1. Imunidade a Espionagem e BadUSB:${RESET}"
            echo -e "     ${WHITE}Hoje:${RESET} Um malware com acesso root pode ligar sua webcam secretamente ou um hacker pode plugar um 'Rubber Ducky' na sua porta USB."
            echo -e "     ${GREEN}Depois:${RESET} O Kernel do Linux ${BOLD}não possui mais o código${RESET} para operar webcams ou bluetooth. É fisicamente impossível o sistema usá-los.\n"

            echo -e "  ${BOLD}2. Defesa contra Ataques DMA (Thunderbolt/Firewire):${RESET}"
            echo -e "     ${WHITE}Hoje:${RESET} Dispositivos Thunderbolt podem ler sua memória RAM diretamente, bypassando o sistema operacional e senhas."
            echo -e "     ${GREEN}Depois:${RESET} O driver do Thunderbolt é removido. A porta existe no hardware, mas o sistema a ignora completamente.\n"

            echo -e "  ${RED}⚠️ O QUE VAI QUEBRAR (Desafios Extremos):${RESET}"
            echo -e "     ${RED}❌${RESET} ${BOLD}Bluetooth${RESET} (Fones, mouses e teclados sem fio pararão de funcionar)."
            echo -e "     ${RED}❌${RESET} ${BOLD}Webcams${RESET} (Zoom, Meet, Teams não reconhecerão nenhuma câmera)."
            echo -e "     ${RED}❌${RESET} Contêineres unprivileged (ex: Podman rootless ou sandboxes Flatpak antigos) podem requerer ajustes se usarem UserNS."
            ;;
    esac

    echo -e "\n${BOLD}${MAGENTA}======================================================${RESET}"
    if [[ "${AUTO_YES:-false}" != true ]]; then
        read -rp "Aperte ENTER para continuar e decidir se aplica ou não..."
    fi
}

# ==========================================
# 🛡️ APLICAÇÃO DAS REGRAS
# ==========================================

apply_basic() {
    echo -e "\n${BOLD}${CYAN}⚙️ APLICANDO NÍVEL BÁSICO...${RESET}"
    log "INÍCIO: Aplicando Nível Básico"

    backup_file "/etc/sysctl.d/99-security-hardening.conf"
    cat <<EOF > /etc/sysctl.d/99-security-hardening.conf
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
kernel.randomize_va_space=2
kernel.perf_event_paranoid=3
kernel.yama.ptrace_scope=1
kernel.unprivileged_bpf_disabled=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0
net.ipv4.tcp_syncookies=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
fs.protected_fifos=2
fs.protected_regular=2
fs.suid_dumpable=0
EOF
    if sysctl -p /etc/sysctl.d/99-security-hardening.conf >/dev/null 2>&1; then
        echo -e "   ${GREEN}✅ Sysctl (Rede/Memória/eBPF/ptrace) aplicado.${RESET}"
        log "OK: sysctl -p /etc/sysctl.d/99-security-hardening.conf aplicado"
    elif sysctl --system >/dev/null 2>&1; then
        echo -e "   ${GREEN}✅ Sysctl (Rede/Memória/eBPF/ptrace) aplicado via --system.${RESET}"
        log "OK: sysctl --system aplicado"
    else
        echo -e "   ${RED}❌ Falha ao aplicar sysctl. Verifique manualmente.${RESET}"
        log "ERRO: sysctl falhou"
    fi

    if systemctl is-active --quiet NetworkManager; then
        mkdir -p /etc/NetworkManager/conf.d/
        backup_file "/etc/NetworkManager/conf.d/ipv6-privacy.conf"
        cat <<EOF > /etc/NetworkManager/conf.d/ipv6-privacy.conf
[connection]
ipv6.ip6-privacy=2
ipv6.addr-gen-mode=3
EOF
        if systemctl reload NetworkManager >/dev/null 2>&1; then
            echo -e "   ${GREEN}✅ Privacidade IPv6 (NM) aplicada.${RESET}"
            log "OK: NetworkManager recarregado com IPv6 privacy"
        else
            echo -e "   ${YELLOW}⚠️ Falha ao recarregar NetworkManager. Reinicie manualmente.${RESET}"
            log "ERRO: systemctl reload NetworkManager falhou"
        fi
    fi

    apply_bootloader_params "init_on_alloc=1 slab_nomerge vsyscall=none page_alloc.shuffle=1 pti=on strict_devmem=1 iommu=force intel_iommu=on amd_iommu=on"
    echo -e "   ${GREEN}✅ Parâmetros do Bootloader (Memória/DMA/IOMMU) configurados.${RESET}"
    log "OK: Nível Básico concluído"
}

apply_intermediate() {
    apply_basic
    echo -e "\n${BOLD}${YELLOW}⚙️ APLICANDO NÍVEL INTERMEDIÁRIO...${RESET}"
    log "INÍCIO: Aplicando Nível Intermediário"

    backup_file "/etc/security/limits.conf"
    if ! grep -q "^\* hard core 0" /etc/security/limits.conf 2>/dev/null; then
        echo "* hard core 0" >> /etc/security/limits.conf
    fi
    # Usa drop-in para sobrescrever sem depender de linhas descomentadas
    mkdir -p /etc/systemd/coredump.conf.d
    cat <<COREDUMP > /etc/systemd/coredump.conf.d/hardening.conf
[Coredump]
Storage=none
ProcessSizeMax=0
COREDUMP
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "   ${GREEN}✅ Core Dumps desativados.${RESET}"

    backup_file "/etc/modprobe.d/security-blacklist.conf"
    cat <<EOF > /etc/modprobe.d/security-blacklist.conf
# Protocolos de rede antigos/inseguros
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install n-hdlc /bin/false
install ax25 /bin/false
install netrom /bin/false
install x25 /bin/false
install rose /bin/false
install decnet /bin/false
install econet /bin/false
install af_802154 /bin/false
install ipx /bin/false
install appletalk /bin/false
install psnap /bin/false
install p8023 /bin/false
install p8022 /bin/false
install can /bin/false
install atm /bin/false
# File systems raros
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install udf /bin/false
EOF
    echo -e "   ${GREEN}✅ Blacklist de módulos (Rede/FS) aplicada.${RESET}"
    log "OK: Nível Intermediário concluído"
}

apply_advanced() {
    apply_intermediate
    echo -e "\n${BOLD}${RED}⚙️ APLICANDO NÍVEL AVANÇADO (PARANOID)...${RESET}"
    log "INÍCIO: Aplicando Nível Avançado (Paranoid)"

    # Restrição de User Namespaces sem privilégios (se o kernel suportar)
    if sysctl kernel.unprivileged_userns_clone >/dev/null 2>&1; then
        if ! grep -q "kernel.unprivileged_userns_clone" /etc/sysctl.d/99-security-hardening.conf 2>/dev/null; then
            echo "kernel.unprivileged_userns_clone=0" >> /etc/sysctl.d/99-security-hardening.conf
        fi
        sysctl -w kernel.unprivileged_userns_clone=0 >/dev/null 2>&1
        echo -e "   ${GREEN}✅ User Namespaces sem privilégios desativados (unprivileged_userns_clone=0).${RESET}"
    fi

    if ! grep -q "install bluetooth /bin/false" /etc/modprobe.d/security-blacklist.conf 2>/dev/null; then
        cat <<EOF >> /etc/modprobe.d/security-blacklist.conf

# Bloqueio de Hardware (Privacidade Extrema)
install bluetooth /bin/false
install btusb /bin/false
install uvcvideo /bin/false
install firewire-core /bin/false
install thunderbolt /bin/false
EOF
    fi
    echo -e "   ${GREEN}✅ Bluetooth, Webcams e Firewire bloqueados no Kernel.${RESET}"

    if systemctl list-unit-files | grep -q "apparmor.service"; then
        apply_bootloader_params "apparmor=1 security=apparmor"
        systemctl enable apparmor >/dev/null 2>&1
        echo -e "   ${GREEN}✅ AppArmor habilitado e configurado no Boot.${RESET}"
    else
        echo -e "   ${YELLOW}⚠️ AppArmor não detectado neste sistema. Pulando configuração MAC.${RESET}"
    fi
    log "OK: Nível Avançado (Paranoid) concluído"
}

# ==========================================
# ⏪ RESTAURAÇÃO
# ==========================================

restore_system() {
    clear
    echo -e "${BOLD}${CYAN}⏪ INICIANDO RESTAURAÇÃO DO SISTEMA...${RESET}"
    local restored=0

    # 1. Restaura arquivos que tinham backup (.harden_bak)
    while IFS= read -r -d '' bak_file; do
        local original_file="${bak_file%.harden_bak}"
        mv -f "$bak_file" "$original_file"
        echo -e "   ${GREEN}♻️ Restaurado: $original_file${RESET}"
        restored=1
    done < <(find /etc /boot/loader/entries -name "*.harden_bak" -print0 2>/dev/null)

    # 2. Limpar arquivos criados pelas regras caso não tenham backup original
    local created_files=(
        "/etc/sysctl.d/99-security-hardening.conf"
        "/etc/modprobe.d/security-blacklist.conf"
        "/etc/NetworkManager/conf.d/ipv6-privacy.conf"
        "/etc/systemd/coredump.conf.d/hardening.conf"
    )
    for cfile in "${created_files[@]}"; do
        if [[ -f "$cfile" && ! -f "${cfile}.harden_bak" ]]; then
            rm -f "$cfile"
            echo -e "   ${GREEN}♻️ Removido: $cfile${RESET}"
            restored=1
        fi
    done

    if [[ $restored -eq 1 ]]; then
        echo -e "\n   ${YELLOW}🔄 Recriando configurações do Bootloader e Sysctl...${RESET}"
        local bl=$(detect_bootloader)
        if [[ "$bl" == "grub" ]]; then
            if command -v update-grub &>/dev/null; then
                update-grub >/dev/null 2>&1
            elif command -v grub-mkconfig &>/dev/null; then
                grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
            fi
        fi
        sysctl --system >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            systemctl reload NetworkManager >/dev/null 2>&1 || true
        fi

        echo -e "\n${BOLD}${GREEN}✅ Sistema restaurado com sucesso!${RESET}"
        echo -e "${YELLOW}⚠️ AVISO: É OBRIGATÓRIO REINICIAR o computador para que os módulos do kernel e parâmetros de boot voltem ao normal.${RESET}"
        log "RESTAURAÇÃO: Sistema restaurado com sucesso"
    else
        echo -e "${YELLOW}⚠️ Nenhum backup (.harden_bak) ou arquivo de hardening encontrado. O sistema já está no padrão.${RESET}"
    fi

    if [[ -z "${CLI_ACTION:-}" ]]; then
        read -rp "Pressione ENTER para voltar ao menu..."
    fi
}

# ==========================================
# 📺 MENU INTERATIVO
# ==========================================

show_menu() {
    clear
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "${BOLD}${CYAN}      🛡️  LINUX HARDENING MANAGER v${VERSION} (Cross-Distro) 🛡️${RESET}"
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "${GREEN}🟢 [1] Nível Básico ${RESET}(Desktop / Uso Diário)"
    echo -e "${YELLOW}🟡 [2] Nível Intermediário ${RESET}(Foco em Privacidade / Servidores)"
    echo -e "${RED}🔴 [3] Nível Avançado ${RESET}(Segurança Extrema / Paranoid)"
    echo -e "${BOLD}📊 [4] Status do Sistema ${RESET}(Ver o que está aplicado)"
    echo -e "${BOLD}⚪ [5] Restaurar Sistema ao Padrão de Fábrica${RESET}"
    echo -e "${BOLD}❌ [0] Sair${RESET}"
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
}

# ==========================================
# 🚀 CLI E LOOP PRINCIPAL
# ==========================================

# Permite exibir ajuda sem exigir root
for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        echo -e "${BOLD}Linux Hardening Manager v${VERSION}${RESET}"
        echo "Uso: sudo $0 [OPÇÕES]"
        echo
        echo "Opções:"
        echo "  --level, -l <1|2|3>    Aplica o nível de hardening especificado"
        echo "  --status, -s           Exibe o status atual das proteções"
        echo "  --restore, -r          Restaura as configurações de fábrica do sistema"
        echo "  --yes, -y              Confirma automaticamente sem prompts interativos"
        echo "  --help, -h             Exibe esta ajuda"
        echo
        echo "Sem opções, inicia o menu interativo."
        exit 0
    fi
done

check_root
acquire_lock

cleanup_exit() {
    echo -e "\n${YELLOW}⚠️ Interrompido pelo usuário. O sistema pode estar parcialmente configurado.${RESET}"
    log "INTERROMPIDO: Ctrl+C pelo usuário"
    exit 130
}
trap cleanup_exit INT TERM

AUTO_YES=false
CLI_LEVEL=""
CLI_ACTION=""

# Processamento CLI não-interativo
if [[ $# -gt 0 ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --level|-l)
                CLI_LEVEL="${2:-}"
                CLI_ACTION="apply"
                shift 2 || shift 1
                ;;
            --status|-s)
                CLI_ACTION="status"
                shift
                ;;
            --restore|-r)
                CLI_ACTION="restore"
                shift
                ;;
            --yes|-y)
                AUTO_YES=true
                shift
                ;;
            --help|-h)
                echo -e "${BOLD}Linux Hardening Manager v${VERSION}${RESET}"
                echo "Uso: sudo $0 [OPÇÕES]"
                echo
                echo "Opções:"
                echo "  --level, -l <1|2|3>    Aplica o nível de hardening especificado"
                echo "  --status, -s           Exibe o status atual das proteções"
                echo "  --restore, -r          Restaura as configurações de fábrica do sistema"
                echo "  --yes, -y              Confirma automaticamente sem prompts interativos"
                echo "  --help, -h             Exibe esta ajuda"
                echo
                echo "Sem opções, inicia o menu interativo."
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Opção desconhecida: $1${RESET}"
                echo "Use sudo $0 --help para ver as opções."
                exit 1
                ;;
        esac
    done

    case "$CLI_ACTION" in
        status)
            show_status
            exit 0
            ;;
        restore)
            if [[ "$AUTO_YES" == true ]]; then
                restore_system
            else
                read -rp "Confirma a restauração de fábrica? (s/N): " confirm
                if [[ "$confirm" =~ ^[sSyY]([iIeE][mMsS])?$ ]]; then
                    restore_system
                else
                    echo -e "${YELLOW}Operação cancelada.${RESET}"
                fi
            fi
            exit 0
            ;;
        apply)
            case "$CLI_LEVEL" in
                1)
                    show_preview 1
                    if [[ "$AUTO_YES" == true ]] || (read -rp "Deseja aplicar o Nível 1? (s/N): " c && [[ "$c" =~ ^[sSyY] ]]); then
                        apply_basic
                        echo -e "\n${BOLD}${GREEN}✅ Nível 1 aplicado com sucesso! Reinicie o sistema.${RESET}"
                    fi
                    ;;
                2)
                    show_preview 2
                    if [[ "$AUTO_YES" == true ]] || (read -rp "Deseja aplicar o Nível 2? (s/N): " c && [[ "$c" =~ ^[sSyY] ]]); then
                        apply_intermediate
                        echo -e "\n${BOLD}${GREEN}✅ Nível 2 aplicado com sucesso! Reinicie o sistema.${RESET}"
                    fi
                    ;;
                3)
                    show_preview 3
                    if [[ "$AUTO_YES" == true ]] || (read -rp "Deseja aplicar o Nível 3? (s/N): " c && [[ "$c" =~ ^[sSyY] ]]); then
                        apply_advanced
                        echo -e "\n${BOLD}${GREEN}✅ Nível 3 aplicado com sucesso! Reinicie o sistema.${RESET}"
                    fi
                    ;;
                *)
                    echo -e "${RED}❌ Nível inválido: '$CLI_LEVEL'. Escolha 1, 2 ou 3.${RESET}"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
    esac
fi

while true; do
    show_menu
    read -rp "Escolha uma opção: " choice

    case $choice in
        1|2|3)
            show_preview "$choice"
            echo -e "\n${BOLD}Deseja aplicar estas alterações agora? (s/n): ${RESET}"
            read -rp "> " confirm
            if [[ "$confirm" =~ ^[sSyY]([iIeE][mMsS])?$ ]]; then
                case $choice in
                    1) apply_basic ;;
                    2) apply_intermediate ;;
                    3) apply_advanced ;;
                esac
                echo -e "\n${BOLD}${GREEN}✅ Processo finalizado! Reinicie o sistema para aplicar as mudanças do Kernel.${RESET}"
                read -rp "Pressione ENTER para voltar ao menu..."
            else
                echo -e "${YELLOW}Operação cancelada pelo usuário.${RESET}"
                sleep 2
            fi
            ;;
        4)
            show_status
            ;;
        5)
            restore_system
            ;;
        0)
            echo -e "${GREEN}👋 Saindo do Linux Hardening Manager. Mantenha-se seguro!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Opção inválida!${RESET}"
            sleep 1
            ;;
    esac
done
