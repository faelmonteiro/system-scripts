#!/usr/bin/env bash
# =============================================================================
# modules/09-auto-audit.sh
# Daemon de rotação automática de MAC, testes de vazamento (leak test) e auditoria
# =============================================================================

# ==================== AUTO MAC ====================
start_auto() {
local interval="${1:-}"
if [[ -n "$interval" && "$interval" =~ ^[0-9]+$ ]]; then
INTERVAL="$interval"
fi
if (( INTERVAL < 10 )); then
warn "Intervalo mínimo é 10 segundos. Usando 10s."
INTERVAL=10
fi
info "Iniciando MAC changer automático"
if [[ $DRY_RUN -eq 0 ]] && ! command -v systemctl &>/dev/null; then
warn "systemctl não disponível."
return 1
fi
local script_path escaped_path
script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
escaped_path=${script_path//\"/\\\"}
escaped_path=${escaped_path//%/%%}
{
cat <<EOF
[Unit]
Description=Randomize MAC Address Service
After=network.target
[Service]
Type=oneshot
KillMode=process
ExecStart=/bin/bash -c 'exec "\$0" rotate-quiet' "$escaped_path"
EOF
} | write_file "/etc/systemd/system/$SYSTEMD_SERVICE"
chmod 644 "/etc/systemd/system/$SYSTEMD_SERVICE" 2>/dev/null || true
{
cat <<EOF
[Unit]
Description=Randomize MAC Timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}s
[Install]
WantedBy=timers.target
EOF
} | write_file "/etc/systemd/system/$SYSTEMD_TIMER"
chmod 644 "/etc/systemd/system/$SYSTEMD_TIMER" 2>/dev/null || true
run systemctl daemon-reload 2>/dev/null || true
run systemctl enable --now "$SYSTEMD_TIMER" 2>/dev/null || true
ok "Timer systemd ativo (a cada ${INTERVAL}s)"
}

stop_auto() {
info "Parando MAC changer automático"
if command -v systemctl &>/dev/null; then
run systemctl disable --now "$SYSTEMD_TIMER" 2>/dev/null || true
run systemctl disable --now "$SYSTEMD_SERVICE" 2>/dev/null || true
run systemctl daemon-reload 2>/dev/null || true
fi
run rm -f "/etc/systemd/system/$SYSTEMD_SERVICE" "/etc/systemd/system/$SYSTEMD_TIMER"
run rm -f "$STATE_DIR/macchanger.pid"
ok "Timer systemd parado/removido"
}

show_log() {
info "Log de mudanças de MAC"
if [[ -f "$CHANGE_LOG" ]]; then
tail -30 "$CHANGE_LOG"
echo
echo "Total de mudanças: $(wc -l < "$CHANGE_LOG")"
else
echo "  Nenhuma mudança registrada."
fi
}

# ==================== AUDITORIA ====================
run_leak_test() {
info "Teste rápido de vazamento e isolamento de hardware"
if command -v curl &>/dev/null; then
local pub_ip
pub_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
echo -n "  IP público: "
if [[ -n "$pub_ip" ]]; then
echo "$pub_ip"
else
echo "não determinado"
fi
else
warn "curl não instalado."
fi
echo "  DNS atual:"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
resolvectl status 2>/dev/null | grep -i "DNS Servers" | head -3 | sed 's/^/    /'
else
grep "nameserver" /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
fi
echo -n "  IPv6: "
if [[ "$(check_ipv6_disabled)" == "1" ]]; then
echo "desabilitado"
else
echo "ativo"
fi

echo -n "  Proteção de Memória Bruta (/dev/mem): "
if grep -qE "strict_devmem=1" /proc/cmdline 2>/dev/null; then
echo "protegido (STRICT_DEVMEM)"
else
echo "padrão do kernel"
fi

echo -n "  Criptografia de Disco (LUKS): "
if command -v lsblk &>/dev/null && lsblk -f 2>/dev/null | grep -q "crypto_LUKS"; then
echo "ativo (LUKS detectado)"
else
echo "não detectado em partição ativa"
fi

warn "WebRTC/navegador não são verificados aqui."
}

show_browser_check() {
info "Checklist de fingerprinting de navegador"
echo "  1. EFF Cover Your Tracks: https://coveryourtracks.eff.org/"
echo "  2. BrowserLeaks: https://browserleaks.com/"
echo "  3. IP/DNS Leak: https://ipleak.net/"
}

show_disclaimer() {
info "Threat model e limitações"
echo "  - Hardware físico (dmidecode raw) não é enganado por bind mounts."
echo "  - Navegadores continuam vulneráveis via WebRTC/Canvas/Fonts."
echo "  - ISPs veem tráfego real. Use VPN/Tor quando apropriado."
echo "  - Esta ferramenta não fornece anonimato completo."
}

# ==================== VERIFY ====================
verify_spoofs() {
info "Verificando spoofs"
local fails=0 checks=0
local iface iname orig curr

# MAC
for iface in /sys/class/net/*/device; do
[[ -e "$iface" ]] || continue
iname=$(echo "$iface" | cut -d'/' -f5)
if [[ -f "$STATE_DIR/original_mac_$iname" ]]; then
checks=$((checks + 1))
orig=$(cat "$STATE_DIR/original_mac_$iname")
curr=$(cat "/sys/class/net/$iname/address" 2>/dev/null)
if [[ "$orig" == "$curr" ]]; then
err "MAC [$iname] não está spoofado"
fails=$((fails + 1))
else
ok "MAC [$iname]"
fi
fi
done

# Hostname
if [[ -f "$STATE_DIR/original_hostname" ]]; then
checks=$((checks + 1))
orig=$(cat "$STATE_DIR/original_hostname")
curr=$(hostname)
if [[ "$orig" == "$curr" ]]; then
err "Hostname não está spoofado"
fails=$((fails + 1))
else
ok "Hostname"
fi
fi

# Machine-ID
if [[ -f "$STATE_DIR/original_machine_id" ]]; then
checks=$((checks + 1))
orig=$(cat "$STATE_DIR/original_machine_id")
curr=$(cat /etc/machine-id 2>/dev/null)
if [[ "$orig" == "$curr" ]]; then
err "Machine-ID não está spoofado"
fails=$((fails + 1))
else
ok "Machine-ID"
fi
fi

# Timezone
if [[ -f "$STATE_DIR/original_timezone" ]]; then
orig=$(cat "$STATE_DIR/original_timezone")
if [[ "$orig" != "desconhecido" ]]; then
checks=$((checks + 1))
curr=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "desconhecido")
if [[ "$orig" == "$curr" ]]; then
err "Timezone não está spoofado"
fails=$((fails + 1))
else
ok "Timezone"
fi
fi
fi

# DMI
if [[ "$(check_dmi_spoofed)" == "1" ]]; then
checks=$((checks + 1))
ok "DMI bind mount ativo"
fi

# RAM
if [[ "$(check_ram_spoofed)" == "1" ]]; then
checks=$((checks + 1))
ok "RAM bind mount ativo"
fi

# CPU
if [[ "$(check_cpu_spoofed)" == "1" ]]; then
checks=$((checks + 1))
ok "CPU bind mount ativo"
fi

# Uptime
if [[ "$(check_uptime_spoofed)" == "1" ]]; then
checks=$((checks + 1))
ok "Uptime bind mount ativo"
if [[ -f "$UPTIME_PID_FILE" ]] && kill -0 "$(cat "$UPTIME_PID_FILE")" 2>/dev/null; then
ok "Uptime updater rodando"
else
warn "Uptime spoofado, mas updater não está rodando"
fi
fi

# Bateria
local bat_found=0 bat f
for bat in /sys/class/power_supply/BAT*; do
[[ -d "$bat" ]] || continue
bat_found=1
for f in serial_number model_name manufacturer; do
if findmnt -n "$bat/$f" &>/dev/null; then
checks=$((checks + 1))
ok "Bateria spoofada: $bat/$f"
fi
done
done
if [[ $bat_found -eq 0 ]]; then
warn "Nenhuma bateria (BAT*) encontrada para verificar"
fi

# Som (ALSA)
if findmnt -n /proc/asound/cards &>/dev/null; then
checks=$((checks + 1))
ok "/proc/asound/cards spoofado"
fi

# Kernel Version
if findmnt -n /proc/version &>/dev/null; then
checks=$((checks + 1))
ok "/proc/version spoofado"
fi

# Bluetooth
if [[ "$(check_bluetooth_disabled)" == "1" ]]; then
checks=$((checks + 1))
ok "Bluetooth desabilitado"
fi

# Disco
if [[ -f "$UDEV_RULE_FILE" ]]; then
checks=$((checks + 1))
ok "Regra udev de disco ativa"
fi

# Portas
if [[ -f "$STATE_DIR/original_port_range" ]]; then
checks=$((checks + 1))
orig=$(cat "$STATE_DIR/original_port_range")
curr=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
if [[ "$orig" == "$curr" ]]; then
err "Portas efêmeras não alteradas"
fails=$((fails + 1))
else
ok "Portas efêmeras"
fi
fi

# TTL
if [[ -f "$STATE_DIR/original_ttl" ]]; then
checks=$((checks + 1))
orig=$(cat "$STATE_DIR/original_ttl")
curr=$(cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null)
if [[ "$orig" == "$curr" ]]; then
err "TTL não alterado"
fails=$((fails + 1))
else
ok "TTL"
fi
fi

# IPv6
if [[ "$(check_ipv6_disabled)" == "1" ]]; then
checks=$((checks + 1))
ok "IPv6 desabilitado"
fi

# DNS
if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
checks=$((checks + 1))
ok "DNSCrypt ativo"
elif [[ -f "$STATE_DIR/original_dns" ]]; then
checks=$((checks + 1))
orig=$(grep '^nameserver' "$STATE_DIR/original_dns" 2>/dev/null | sort)
curr=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | sort)
if [[ "$orig" != "$curr" ]]; then
ok "DNS alterado"
else
err "DNS não alterado"
fails=$((fails + 1))
fi
fi

local dns_backup dns_changed
for dns_backup in "$STATE_DIR"/original_resolved_dns_*; do
[[ -f "$dns_backup" ]] || continue
checks=$((checks + 1))
iface=$(basename "$dns_backup" | sed 's/^original_resolved_dns_//')
orig=$(cat "$dns_backup")
curr=$(get_resolvectl_dns "$iface")
dns_changed=0
if [[ "$orig" == "__NONE__" ]]; then
[[ -n "$curr" ]] && dns_changed=1
elif [[ "$orig" != "$curr" ]]; then
dns_changed=1
fi
if [[ $dns_changed -eq 1 ]]; then
ok "DNS resolvectl [$iface]"
else
err "DNS resolvectl [$iface] não alterado"
fails=$((fails + 1))
fi
done

# Screen
if [[ -f "$XRANDR_WRAPPER" ]] && grep -q 'FAKE_XRANDR' "$XRANDR_WRAPPER" 2>/dev/null; then
checks=$((checks + 1))
local xrandr_path
xrandr_path=$(command -v xrandr 2>/dev/null || true)
if [[ "$xrandr_path" == "$XRANDR_WRAPPER" ]]; then
ok "Wrapper xrandr ativo no PATH"
else
warn "Wrapper xrandr existe, mas pode não estar no PATH"
fi
fi

# Usuário
if [[ "$(check_user_spoofed)" == "1" ]]; then
checks=$((checks + 1))
ok "Usuário temporário ativo"
fi

echo
if [[ $checks -eq 0 ]]; then
warn "Nenhum spoof detectado."
return 0
elif [[ $fails -eq 0 ]]; then
ok "$checks/$checks verificações OK."
return 0
else
err "$fails/$checks verificações falharam."
return 1
fi
}

# ==================== STATUS ====================
