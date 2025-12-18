#!/bin/bash

# disable_services.sh - Disable unnecessary services for minimal Firefox/VSCode/Chrome setup
# Keeps only essential network, DNS, and monitoring services

set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Exiting."
  exit 1
fi

echo "[*] Disabling unnecessary services for minimal browser/IDE setup..."
echo "[!] Keeping: NetworkManager, DNS, D-Bus, systemd core, logging services"
echo ""

# Network Services to disable
echo "[*] Disabling network services..."
NETWORK_SERVICES=(
  ModemManager.service
  bluetooth.service
  networkd-dispatcher.service
)

for service in "${NETWORK_SERVICES[@]}"; do
  if systemctl is-enabled "$service" >/dev/null 2>&1 || systemctl is-active "$service" >/dev/null 2>&1; then
    echo "  -> Disabling $service"
    systemctl disable --now "$service" 2>/dev/null || echo "     (already disabled or not found)"
  fi
done

# Cloud/Updates Services to disable
echo "[*] Disabling cloud and update services..."
CLOUD_SERVICES=(
  unattended-upgrades.service
  cloud-init-main.service
  cloud-init-network.service
  snapd.service
  snapd.socket
  snapd.apparmor.service
  snapd.autoimport.service
  snapd.core-fixup.service
  snapd.recovery-chooser-trigger.service
  snapd.seeded.service
  snapd.system-shutdown.service
)

for service in "${CLOUD_SERVICES[@]}"; do
  if systemctl is-enabled "$service" >/dev/null 2>&1 || systemctl is-active "$service" >/dev/null 2>&1; then
    echo "  -> Disabling $service"
    systemctl disable --now "$service" 2>/dev/null || echo "     (already disabled or not found)"
  fi
done

# Hardware/Power Management Services to disable
echo "[*] Disabling hardware/power management services..."
HARDWARE_SERVICES=(
  thermald.service
  power-profiles-daemon.service
  switcheroo-control.service
  fwupd.service
)

for service in "${HARDWARE_SERVICES[@]}"; do
  if systemctl is-enabled "$service" >/dev/null 2>&1 || systemctl is-active "$service" >/dev/null 2>&1; then
    echo "  -> Disabling $service"
    systemctl disable --now "$service" 2>/dev/null || echo "     (already disabled or not found)"
  fi
done

# Printer/Accessory Services to disable
echo "[*] Disabling printer and accessory services..."
PRINTER_SERVICES=(
  legacy-printer-app.service
  colord.service
  udisks2.service
  cups.service
  cups-browsed.service
)

for service in "${PRINTER_SERVICES[@]}"; do
  if systemctl is-enabled "$service" >/dev/null 2>&1 || systemctl is-active "$service" >/dev/null 2>&1; then
    echo "  -> Disabling $service"
    systemctl disable --now "$service" 2>/dev/null || echo "     (already disabled or not found)"
  fi
done

# Other Miscellaneous Services to disable
echo "[*] Disabling miscellaneous services..."
OTHER_SERVICES=(
  accounts-daemon.service
  rtkit-daemon.service
  upower.service
  anacron.service
  apport.service
)

for service in "${OTHER_SERVICES[@]}"; do
  if systemctl is-enabled "$service" >/dev/null 2>&1 || systemctl is-active "$service" >/dev/null 2>&1; then
    echo "  -> Disabling $service"
    systemctl disable --now "$service" 2>/dev/null || echo "     (already disabled or not found)"
  fi
done

# Ensure DNS is enabled (critical for browsers)
echo "[*] Ensuring DNS resolver is enabled..."
if ! systemctl is-active systemd-resolved.service >/dev/null 2>&1; then
  echo "  -> Enabling and starting systemd-resolved.service"
  systemctl enable --now systemd-resolved.service
else
  echo "  -> systemd-resolved.service is already running"
fi

echo ""
echo "[✓] Service cleanup complete!"
echo ""
echo "KEPT RUNNING (essential):"
echo "  - NetworkManager (network connectivity)"
echo "  - systemd-resolved (DNS resolution)"
echo "  - dbus (inter-process communication)"
echo "  - systemd-logind (session management)"
echo "  - gdm/display manager (GUI)"
echo "  - rsyslog/cron/sysstat (monitoring)"
echo ""
echo "To verify active services: systemctl list-units --type=service --state=running"
