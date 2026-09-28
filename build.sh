#!/usr/bin/env bash
# build.sh — regenerate the embedded heredoc sections in install.sh from source files.
#
# You only ever edit files in src/ (and uninstall.sh). Then run:
#   ./build.sh
# to update install.sh. Commit both.
#
# Source of truth:
#   src/quadlet-monitor.sh      →  MAIN_SCRIPT_EOF  section in install.sh
#   src/quadlet-monitor.service →  SERVICE_EOF      section in install.sh
#   src/quadlet-monitor.timer   →  TIMER_EOF        section in install.sh
#   uninstall.sh                →  UNINSTALL_EOF    section in install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"
TMP_SH="${INSTALL_SH}.tmp"

[[ -f "$INSTALL_SH" ]] || { echo "ERROR: $INSTALL_SH not found" >&2; exit 1; }

replace_heredoc() {
    local marker="$1"
    local src_rel="$2"
    local src_file="$SCRIPT_DIR/$src_rel"

    [[ -f "$src_file" ]] || { echo "ERROR: $src_file not found" >&2; exit 1; }

    awk -v marker="$marker" -v srcfile="$src_file" '
        BEGIN { skip = 0 }
        skip {
            if ($0 == marker) {
                print
                skip = 0
            }
            next
        }
        /<< / {
            if (index($0, marker) > 0) {
                print
                while ((getline line < srcfile) > 0) {
                    print line
                }
                close(srcfile)
                skip = 1
                next
            }
        }
        { print }
    ' "$INSTALL_SH" > "$TMP_SH"
    mv "$TMP_SH" "$INSTALL_SH"
}

echo "=== quadlet-monitor build ==="

replace_heredoc "MAIN_SCRIPT_EOF"   "src/quadlet-monitor.sh"
echo "  ✓ embedded src/quadlet-monitor.sh"

replace_heredoc "SERVICE_EOF"       "src/quadlet-monitor.service"
echo "  ✓ embedded src/quadlet-monitor.service"

replace_heredoc "TIMER_EOF"         "src/quadlet-monitor.timer"
echo "  ✓ embedded src/quadlet-monitor.timer"

replace_heredoc "UNINSTALL_EOF"     "uninstall.sh"
echo "  ✓ embedded uninstall.sh"

# Verify the result is syntactically valid
if bash -n "$INSTALL_SH" 2>/dev/null; then
    echo ""
    echo "✓ install.sh regenerated and syntax-checked."
else
    echo ""
    echo "✗ ERROR: install.sh has a syntax error after regeneration." >&2
    exit 1
fi
