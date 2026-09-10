#!/usr/bin/env bash
# =============================================================================
# randomize-ids.sh (Versão Modularizada)
# Ferramenta de randomização de identificadores do sistema Linux.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"

# Carregamento sequencial dos submódulos
for mod in "$MODULES_DIR"/*.sh; do
  if [[ -f "$mod" ]]; then
    # shellcheck source=/dev/null
    source "$mod"
  fi
done

main "$@"
