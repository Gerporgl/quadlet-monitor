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
