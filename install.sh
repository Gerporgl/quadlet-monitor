#!/usr/bin/env bash
# quadlet-monitor installer
#
# Usage (from a cloned repo):
#   sudo ./install.sh https://ntfy.example.com/topic
#
# Usage (curl pipe, public repo):
#   curl -fsSL https://raw.githubusercontent.com/Gerporgl/quadlet-monitor/master/install.sh \
#     | sudo bash -s -- https://ntfy.example.com/topic
#
# For private repos, clone first:
#   git clone git@github.com:Gerporgl/quadlet-monitor.git /tmp/quadlet-monitor
#   sudo /tmp/quadlet-monitor/install.sh https://ntfy.example.com/topic
set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
NTFY_URL="${1:-${NTFY_URL:-}}"
NTFY_TOKEN="${2:-${NTFY_TOKEN:-}}"

if [[ -z "$NTFY_URL" ]]; then
    echo "Usage: sudo $0 <NTFY_URL> [NTFY_TOKEN]"
    echo ""
    echo "  NTFY_URL   Full ntfy topic URL, e.g. https://ntfy.example.com/my-topic"
    echo "  NTFY_TOKEN Optional auth token for the ntfy topic"
    echo ""
    echo "Examples:"
    echo "  sudo $0 https://ntfy.example.com/quadlet-updates"
    echo "  sudo $0 https://ntfy.example.com/quadlet-updates my-secret-token"
    exit 1
fi

# Validate URL
if ! [[ "$NTFY_URL" =~ ^https?:// ]]; then
    echo "ERROR: NTFY_URL must start with http:// or https://"
    exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
INSTALL_DIR="/usr/local/bin/quadlet-monitor"
CONFIG_DIR="/etc/quadlet-monitor"
STATE_DIR="/var/lib/quadlet-monitor"
SYSTEMD_DIR="/etc/systemd/system"
# When piped (curl | bash), BASH_SOURCE is empty — fall back to cwd
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: this script must be run as root (use sudo)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
command -v podman >/dev/null 2>&1 || { echo "ERROR: podman is not installed." >&2; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "ERROR: jq is not installed. Install it with: apt install jq" >&2; exit 1; }
command -v curl   >/dev/null 2>&1 || { echo "ERROR: curl is not installed." >&2; exit 1; }

echo "=== quadlet-monitor installer ==="
echo "  NTFY_URL:   $NTFY_URL"
[[ -n "$NTFY_TOKEN" ]] && echo "  NTFY_TOKEN: (set)"
echo ""

# ---------------------------------------------------------------------------
# Determine source: local src/ dir or embedded heredocs
# ---------------------------------------------------------------------------
USE_LOCAL_SRC=false
if [[ -d "$SCRIPT_DIR/src" && -f "$SCRIPT_DIR/src/quadlet-monitor.sh" ]]; then
    USE_LOCAL_SRC=true
fi

write_file() {
    local dest="$1"
    if $USE_LOCAL_SRC; then
        local basename
        basename="$(basename "$dest")"
        cp "$SCRIPT_DIR/src/$basename" "$dest"
    else
        cat > "$dest"
    fi
}

# ---------------------------------------------------------------------------
# Create directories
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"

# ---------------------------------------------------------------------------
# Install main script
# ---------------------------------------------------------------------------
echo "Installing $INSTALL_DIR/quadlet-monitor.sh ..."
if $USE_LOCAL_SRC; then
    cp "$SCRIPT_DIR/src/quadlet-monitor.sh" "$INSTALL_DIR/quadlet-monitor.sh"
else
    cat > "$INSTALL_DIR/quadlet-monitor.sh" << 'MAIN_SCRIPT_EOF'
#!/usr/bin/env bash
# quadlet-monitor — detect Podman container image updates and send ntfy notifications
#
# Maintains a state file mapping each running container to its image digest.
# After podman auto-update (or any other update), diffs old vs new state and
# sends an ntfy notification per changed container.
set -euo pipefail

CONFIG_FILE="/etc/quadlet-monitor/quadlet-monitor.conf"
STATE_FILE="/var/lib/quadlet-monitor/state.json"
STATE_DIR="/var/lib/quadlet-monitor"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: $CONFIG_FILE not found" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

[[ -n "${NTFY_URL:-}" ]] || { echo "ERROR: NTFY_URL not set in $CONFIG_FILE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required but not installed" >&2; exit 1; }

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$ts] $*"
}

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}"
    local curl_args=(
        -sf -X POST
        -H "Title: $title"
        -H "Priority: $priority"
        -H "Tags: 🐳"
    )
    [[ -n "${NTFY_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer $NTFY_TOKEN")

    if curl "${curl_args[@]}" -d "$body" "$NTFY_URL" 2>/dev/null; then
        log "ntfy: sent '$title'"
    else
        log "ERROR: failed to send ntfy notification: $title"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

# Get current state: { container_name: { image, digest, version, created, source } }
get_current_state() {
    local containers
    containers=$(podman ps --format json 2>/dev/null) || {
        log "ERROR: podman ps failed"
        echo '{}'
        return 1
    }

    if [[ "$containers" == "[]" || -z "$containers" ]]; then
        echo '{}'
        return 0
    fi

    # Collect unique image references from running containers
    local images
    images=$(echo "$containers" | jq -r '[.[].Image] | unique | .[]')

    # Inspect all unique images in one call
    local image_data='[]'
    if [[ -n "$images" ]]; then
        # shellcheck disable=SC2086
        image_data=$(podman image inspect $images --format json 2>/dev/null) || image_data='[]'
    fi

    # Build the state map
    echo "$containers" | jq -n \
        --argjson containers "$containers" \
        --argjson images "$image_data" '
        def find_image($img):
            $images | map(select(.RepoTags != null and (.RepoTags | index($img))))
                     | first // {};

        $containers | map(
            . as $c |
            {
                key: $c.Names[0],
                value: (
                    find_image($c.Image) as $info |
                    {
                        image:   $c.Image,
                        digest:  ($info.Digest // "unknown"),
                        version: ($info.Labels["org.opencontainers.image.version"] // ""),
                        created: ($info.Labels["org.opencontainers.image.created"] // $info.Created // ""),
                        source:  ($info.Labels["org.opencontainers.image.source"] // "")
                    }
                )
            }
        ) | from_entries
    '
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" | jq '.containers // {}'
    else
        echo '{}'
    fi
}

save_state() {
    local state="$1"
    local tmp="${STATE_FILE}.tmp"
    echo "$state" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version: 1, updated_at: $ts, containers: .}' > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "quadlet-monitor: starting check"

    local old_state new_state
    old_state=$(load_state)
    new_state=$(get_current_state)

    # First run: capture baseline, no notifications
    if [[ "$old_state" == "{}" ]]; then
        save_state "$new_state"
        local count
        count=$(echo "$new_state" | jq 'length')
        log "Initial state captured: $count container(s). No notifications sent."
        return 0
    fi

    # Find containers whose image digest changed
    local updates
    updates=$(jq -n \
        --argjson old "$old_state" \
        --argjson new "$new_state" '
        [
            ($new | to_entries[] |
                . as $e |
                $old[$e.key] as $o |
                select($o != null) |
                select($o.digest != $e.value.digest) |
                { name: $e.key, old: $o, new: $e.value }
            )
        ]
    ')

    local update_count
    update_count=$(echo "$updates" | jq 'length')
    log "Found $update_count updated container(s)"

    if [[ "$update_count" -gt 0 ]]; then
        while IFS= read -r update; do
            local name old_ver new_ver old_digest new_digest new_img new_created new_source
            name=$(echo "$update" | jq -r '.name')
            old_ver=$(echo "$update" | jq -r '.old.version')
            new_ver=$(echo "$update" | jq -r '.new.version')
            old_digest=$(echo "$update" | jq -r '.old.digest')
            new_digest=$(echo "$update" | jq -r '.new.digest')
            new_img=$(echo "$update" | jq -r '.new.image')
            new_created=$(echo "$update" | jq -r '.new.created')
            new_source=$(echo "$update" | jq -r '.new.source')

            # Truncate digests for readability
            local old_d="${old_digest:0:19}…"
            local new_d="${new_digest:0:19}…"

            # Build title
            local title
            if [[ -n "$new_ver" && -n "$old_ver" && "$old_ver" != "$new_ver" ]]; then
                title="🐳 $name: $old_ver → $new_ver"
            elif [[ -n "$new_ver" ]]; then
                title="🐳 $name → $new_ver"
            else
                title="🐳 $name updated"
            fi

            # Build body
            local body="Image:  $new_img
Digest:  $old_d → $new_d"

            if [[ -n "$new_ver" ]]; then
                if [[ -n "$old_ver" && "$old_ver" != "$new_ver" ]]; then
                    body+=$'\n'"Version: $old_ver → $new_ver"
                else
                    body+=$'\n'"Version: $new_ver"
                fi
            fi

            if [[ -n "$new_created" ]]; then
                body+=$'\n'"Built:   $new_created"
            fi

            if [[ -n "$new_source" ]]; then
                body+=$'\n'"Source:  $new_source"
            fi

            send_ntfy "$title" "$body" || true
        done < <(echo "$updates" | jq -c '.[]')
    fi

    # Save new state
    save_state "$new_state"
    local total
    total=$(echo "$new_state" | jq 'length')
    log "State updated: $total container(s) tracked"
}

main "$@"
MAIN_SCRIPT_EOF
fi
chmod 755 "$INSTALL_DIR/quadlet-monitor.sh"

# ---------------------------------------------------------------------------
# Install systemd units
# ---------------------------------------------------------------------------
echo "Installing $SYSTEMD_DIR/quadlet-monitor.service ..."
if $USE_LOCAL_SRC; then
    cp "$SCRIPT_DIR/src/quadlet-monitor.service" "$SYSTEMD_DIR/quadlet-monitor.service"
else
    cat > "$SYSTEMD_DIR/quadlet-monitor.service" << 'SERVICE_EOF'
[Unit]
Description=Podman Monitor - detect container image updates and send ntfy notifications
Documentation=man:quadlet-monitor
After=podman-auto-update.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/quadlet-monitor/quadlet-monitor.sh
# Give it a reasonable timeout in case registry calls are slow
TimeoutStartSec=120

[Install]
WantedBy=podman-auto-update.service
SERVICE_EOF
fi

echo "Installing $SYSTEMD_DIR/quadlet-monitor.timer ..."
if $USE_LOCAL_SRC; then
    cp "$SCRIPT_DIR/src/quadlet-monitor.timer" "$SYSTEMD_DIR/quadlet-monitor.timer"
else
    cat > "$SYSTEMD_DIR/quadlet-monitor.timer" << 'TIMER_EOF'
[Unit]
Description=Podman Monitor - periodic fallback check for container updates
Documentation=man:quadlet-monitor

[Timer]
OnCalendar=*:0/5
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
fi

# ---------------------------------------------------------------------------
# Install config
# ---------------------------------------------------------------------------
echo "Installing $CONFIG_DIR/quadlet-monitor.conf ..."
cat > "$CONFIG_DIR/quadlet-monitor.conf" << CONF_EOF
# quadlet-monitor configuration
# Full ntfy topic URL (server + topic path)
NTFY_URL="$NTFY_URL"
# Optional: auth token for the ntfy topic (leave empty if not needed)
NTFY_TOKEN="${NTFY_TOKEN}"
CONF_EOF
chmod 600 "$CONFIG_DIR/quadlet-monitor.conf"

# ---------------------------------------------------------------------------
# Install uninstall script
# ---------------------------------------------------------------------------
echo "Installing $INSTALL_DIR/uninstall.sh ..."
if $USE_LOCAL_SRC && [[ -f "$SCRIPT_DIR/uninstall.sh" ]]; then
    cp "$SCRIPT_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
else
    cat > "$INSTALL_DIR/uninstall.sh" << 'UNINSTALL_EOF'
#!/usr/bin/env bash
# quadlet-monitor uninstaller
#
# Usage: sudo ./uninstall.sh
#   or:  sudo /usr/local/bin/quadlet-monitor/uninstall.sh
set -euo pipefail

INSTALL_DIR="/usr/local/bin/quadlet-monitor"
CONFIG_DIR="/etc/quadlet-monitor"
STATE_DIR="/var/lib/quadlet-monitor"
SYSTEMD_DIR="/etc/systemd/system"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (use sudo)."
    exit 1
fi

echo "=== quadlet-monitor uninstaller ==="

# Stop and disable services
echo "Disabling services..."
systemctl disable --now quadlet-monitor.timer 2>/dev/null || true
systemctl disable --now quadlet-monitor.service 2>/dev/null || true

# Remove systemd units
echo "Removing systemd units..."
rm -f "$SYSTEMD_DIR/quadlet-monitor.service"
rm -f "$SYSTEMD_DIR/quadlet-monitor.timer"
# Remove the wants symlink created by WantedBy=podman-auto-update.service
rm -f "$SYSTEMD_DIR/podman-auto-update.service.wants/quadlet-monitor.service" 2>/dev/null || true
# Clean up empty wants dir if it exists
rmdir "$SYSTEMD_DIR/podman-auto-update.service.wants" 2>/dev/null || true

# Remove scripts
echo "Removing $INSTALL_DIR ..."
rm -rf "$INSTALL_DIR"

# Remove config
echo "Removing $CONFIG_DIR ..."
rm -rf "$CONFIG_DIR"

# Remove state (with confirmation)
if [[ -d "$STATE_DIR" ]]; then
    read -r -p "Remove state data in $STATE_DIR? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        rm -rf "$STATE_DIR"
    else
        echo "Keeping $STATE_DIR"
    fi
fi

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

echo ""
echo "quadlet-monitor has been removed."
echo "The podman-auto-update.service and timer are untouched."
UNINSTALL_EOF
fi
chmod 755 "$INSTALL_DIR/uninstall.sh"

# ---------------------------------------------------------------------------
# Enable and start
# ---------------------------------------------------------------------------
echo "Reloading systemd..."
systemctl daemon-reload

echo "Enabling quadlet-monitor.timer ..."
systemctl enable quadlet-monitor.timer

echo "Enabling quadlet-monitor.service ..."
systemctl enable quadlet-monitor.service

# ---------------------------------------------------------------------------
# Initial state capture
# ---------------------------------------------------------------------------
echo ""
echo "Capturing initial container state (no notifications on first run)..."
if "$INSTALL_DIR/quadlet-monitor.sh"; then
    echo "Initial state captured successfully."
else
    echo "WARNING: initial state capture failed. Check podman is running."
    echo "The monitor will capture state on its next run."
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Script:    $INSTALL_DIR/quadlet-monitor.sh"
echo "  Config:    $CONFIG_DIR/quadlet-monitor.conf"
echo "  State:     $STATE_DIR/state.json"
echo "  Service:   quadlet-monitor.service  (runs after podman-auto-update)"
echo "  Timer:     quadlet-monitor.timer    (fallback, every 5 min)"
echo ""
echo "  NTFY_URL:  $NTFY_URL"
echo ""
echo "Uninstall:   sudo $INSTALL_DIR/uninstall.sh"
echo ""
echo "Check status:  systemctl status quadlet-monitor.timer quadlet-monitor.service"
echo "View logs:     journalctl -u quadlet-monitor.service"
