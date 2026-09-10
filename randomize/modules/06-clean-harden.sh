#!/usr/bin/env bash
# =============================================================================
# modules/06-clean-harden.sh
# Limpeza avançada de rastros e aplicação/reversão de hardening do kernel e sistema
# =============================================================================

# ==================== LIMPEZA DE RASTROS ====================
clean_traces() {
info "Limpando rastros"
local opt="${1:-}"
if [[ -z "$opt" ]]; then
echo "Uso: clean_traces --history|--cache|--tmp|--clipboard|--logs|--browser-cache|--all"
return 0
fi
local real_home="/home/${SUDO_USER:-${USER:-}}"
local h logfile
if [[ "$opt" == "--all" || "$opt" == "--history" ]]; then
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] history -c\n'
else
builtin history -c 2>/dev/null || true
fi
for h in "$HOME" "$real_home"; do
truncate_file "$h/.bash_history"
truncate_file "$h/.zsh_history"
truncate_file "$h/.local/share/fish/fish_history"
done
ok "Histórico limpo"
warn "Shells abertos podem regravar o histórico ao sair."
fi
if [[ "$opt" == "--all" || "$opt" == "--cache" ]]; then
if command -v resolvectl &>/dev/null; then
run resolvectl flush-caches 2>/dev/null || true
fi
for h in "$HOME" "$real_home"; do
run rm -rf "$h/.cache/thumbnails" 2>/dev/null || true
run rm -f "$h/.local/share/recently-used.xbel" 2>/dev/null || true
done
ok "Caches limpos"
fi
if [[ "$opt" == "--all" || "$opt" == "--tmp" ]]; then
local target_uid
target_uid=$(id -u "${SUDO_USER:-${USER:-}}" 2>/dev/null || echo "")
if [[ -n "$target_uid" ]]; then
run find /tmp -mindepth 1 -maxdepth 1 \
-uid "$target_uid" \
! -name '.X11-unix' \
! -name '.ICE-unix' \
! -name 'systemd-*' \
! -name 'wayland-*' \
! -name 'ssh-*' \
! -name 'gpg-*' \
-mmin +60 \
-exec rm -rf {} + 2>/dev/null || true
ok "/tmp limpo (arquivos do uid=$target_uid com mais de 60min)"
else
warn "Não foi possível determinar UID do usuário. /tmp não limpo."
fi
fi
if [[ "$opt" == "--all" || "$opt" == "--clipboard" ]]; then
if [[ -n "${DISPLAY:-}" ]]; then
command -v xclip &>/dev/null && run xclip -selection clipboard < /dev/null
command -v xsel &>/dev/null && run xsel --clipboard --delete
fi
if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy &>/dev/null; then
run wl-copy --clear
fi
ok "Clipboard limpo"
fi
if [[ "$opt" == "--browser-cache" ]]; then
if command -v bleachbit &>/dev/null; then
echo "  BleachBit detectado."
echo "  Para limpeza profunda de navegador, execute manualmente:"
echo "    bleachbit --clean firefox.cache google_chrome.cache chromium.cache"
else
warn "BleachBit não instalado."
fi
fi
if [[ "$opt" == "--all" || "$opt" == "--logs" ]]; then
if ! ask_yes "Apagar logs pode violar políticas. Continuar?"; then
info "Logs não apagados."
return 0
fi
run journalctl --rotate 2>/dev/null || true
run journalctl --vacuum-time=1s 2>/dev/null || true
for logfile in /var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/messages /var/log/wtmp /var/log/btmp /var/log/lastlog; do
truncate_file "$logfile"
done
if systemctl is-active --quiet rsyslog 2>/dev/null; then
run systemctl restart rsyslog 2>/dev/null || true
fi
ok "Logs apagados"
fi
}

# ==================== HARDENING ====================
harden_system() {
info "Aplicando hardening do sistema e rede"
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] hardening sysctl e rede\n'
return 0
fi
{
echo "# randomize_ids hardening"
echo "# Proteções de Kernel e Processos"
echo "kernel.dmesg_restrict = 1"
echo "kernel.kptr_restrict = 2"
echo "kernel.yama.ptrace_scope = 1"
echo "fs.suid_dumpable = 0"
echo "kernel.unprivileged_bpf_disabled = 1"
echo ""
echo "# Proteções de Rede e Anti-Fingerprinting (TCP/IP Stack)"
echo "net.ipv4.tcp_timestamps = 0"
echo "net.ipv4.conf.all.rp_filter = 1"
echo "net.ipv4.conf.default.rp_filter = 1"
echo "net.ipv4.conf.all.accept_redirects = 0"
echo "net.ipv6.conf.all.accept_redirects = 0"
echo "net.ipv4.conf.all.send_redirects = 0"
echo "net.ipv4.icmp_echo_ignore_broadcasts = 1"
echo "net.ipv4.icmp_ignore_bogus_error_responses = 1"
echo "net.ipv4.tcp_syncookies = 1"
echo "net.ipv6.conf.all.use_tempaddr = 2"
echo "net.ipv6.conf.default.use_tempaddr = 2"
} | write_file "$HARDEN_SYSCTL"
chmod 644 "$HARDEN_SYSCTL" 2>/dev/null || true
run sysctl --system 2>/dev/null || true
# Desativar telemetrias e relatórios de erro
run systemctl disable --now apport 2>/dev/null || true
run systemctl disable --now whoopsie 2>/dev/null || true
run systemctl disable --now popularity-contest 2>/dev/null || true
run systemctl disable --now avahi-daemon 2>/dev/null || true
# Ativar Firewall UFW se disponível
if command -v ufw &>/dev/null; then
run ufw default deny incoming 2>/dev/null || true
run ufw default allow outgoing 2>/dev/null || true
run ufw --force enable 2>/dev/null || true
ok "Firewall UFW configurado (bloquear entradas, permitir saídas)"
fi
ok "Hardening aplicado: $HARDEN_SYSCTL"
}

harden_undo() {
info "Removendo hardening"
run rm -f "$HARDEN_SYSCTL"
run sysctl --system 2>/dev/null || true
ok "Hardening removido"
}

