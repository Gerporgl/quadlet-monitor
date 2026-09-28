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
