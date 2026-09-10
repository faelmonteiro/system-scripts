#!/usr/bin/env bash
# =============================================================================
# randomize-ids.sh (Versão Modularizada)
# Ferramenta de randomização de identificadores do sistema Linux.
# =============================================================================

SCRIPT_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"

# Carregamento sequencial dos submódulos
for mod in "$MODULES_DIR"/*.sh; do
  if [[ -f "$mod" ]]; then
    # shellcheck source=/dev/null
    source "$mod"
  fi
done

main "$@"
