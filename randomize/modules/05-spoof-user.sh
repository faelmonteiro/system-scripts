#!/usr/bin/env bash
# =============================================================================
# modules/05-spoof-user.sh
# Mecanismo de spoofing e isolamento de usuário/identidade
# =============================================================================

# ==================== SPOOF: USUÁRIO ====================
randomize_username() {
info "Criando usuário temporário"
local current_user temp_user temp_pass old_temp
current_user="${SUDO_USER:-${USER:-root}}"
temp_user="user_$(random_string 6)"
echo "  Usuário atual: $current_user"
if [[ -f "$TEMP_USER_FILE" ]]; then
old_temp=$(cat "$TEMP_USER_FILE")
if id "$old_temp" &>/dev/null; then
warn "Já existe usuário temporário ativo: $old_temp"
warn "Use restore para remover antes de criar outro."
return 0
fi
fi
if [[ $DRY_RUN -eq 1 ]]; then
printf '[DRY-RUN] useradd -m -s /bin/bash %s\n' "$temp_user"
return 0
fi
if ! command -v useradd &>/dev/null || ! command -v chpasswd &>/dev/null; then
warn "useradd/chpasswd não disponíveis."
return 1
fi
local user_shell="/bin/bash"
[[ -x "$user_shell" ]] || user_shell="/bin/sh"
local chpasswd_ok=0
local useradd_ok=0
local expiry_date
expiry_date=$(date -d '+1 day' +%F 2>/dev/null || echo "")
{ set +x; } 2>/dev/null
temp_pass="$(random_string 16)"
if [[ ${#temp_pass} -ne 16 ]]; then
[[ $DEBUG -eq 1 ]] && set -x
err "Falha ao gerar senha aleatória (tamanho inesperado)."
return 1
fi
if [[ -n "$expiry_date" ]]; then
useradd -m -s "$user_shell" -e "$expiry_date" "$temp_user" 2>/dev/null && useradd_ok=1
else
useradd -m -s "$user_shell" "$temp_user" 2>/dev/null && useradd_ok=1
fi
if (( useradd_ok == 0 )); then
[[ $DEBUG -eq 1 ]] && set -x
err "Falha ao criar usuário."
return 1
fi
if printf '%s:%s\n' "$temp_user" "$temp_pass" | chpasswd 2>/dev/null; then
ensure_state
write_str "$TEMP_USER_FILE" "$temp_user"
( umask 077 && write_str "$TEMP_PASS_FILE" "$temp_pass" )
chmod 600 "$TEMP_PASS_FILE" 2>/dev/null || true
chpasswd_ok=1
fi
unset temp_pass
[[ $DEBUG -eq 1 ]] && set -x
if (( chpasswd_ok == 0 )); then
err "Falha ao definir senha para o usuário temporário."
userdel -r "$temp_user" 2>/dev/null || true
return 1
fi
backup_original "username" "$current_user"
ok "Usuário criado: $temp_user"
echo "  Senha salva em: $TEMP_PASS_FILE"
echo "  Use: su - $temp_user"
warn "Usuário sem privilégios administrativos por padrão."
if [[ -n "$expiry_date" ]]; then
warn "Conta expira em: $expiry_date"
fi
log_change "USERNAME|$temp_user"
}

