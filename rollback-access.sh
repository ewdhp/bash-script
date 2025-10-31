#!/bin/bash
# Rollback changes made by access.sh
set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Exiting."
  exit 1
fi

echo "[*] Detecting distribution and package manager..."
. /etc/os-release || true
DIST_ID=${ID:-unknown}
DIST_LIKE=${ID_LIKE:-}

PKG_MANAGER=""
if command -v apt-get >/dev/null 2>&1 || [[ "$DIST_ID" == "ubuntu" || "$DIST_LIKE" =~ debian ]]; then
  PKG_MANAGER="apt"
elif command -v zypper >/dev/null 2>&1 || [[ "$DIST_ID" =~ suse|opensuse ]]; then
  PKG_MANAGER="zypper"
fi
echo "  -> Detected: $DIST_ID (pkg mgr: ${PKG_MANAGER:-none})"

# 1) Restore iptables from latest backup if present
echo "[*] Restoring iptables from latest backup (if any)..."
LATEST_BACKUP=$(ls -1t /root/iptables-backup-*.rules 2>/dev/null | head -n1 || true)
if [[ -n "$LATEST_BACKUP" ]]; then
  echo "  -> Found backup: $LATEST_BACKUP"
  if command -v iptables-restore >/dev/null 2>&1; then
    if iptables-restore < "$LATEST_BACKUP"; then
      echo "  -> iptables restored from $LATEST_BACKUP"
    else
      echo "  -> Warning: iptables-restore failed"
    fi
  else
    echo "  -> iptables-restore not available; skipping"
  fi
else
  echo "  -> No iptables backup found in /root. Skipping restore."
fi

# 2) Unmask and enable common services disabled by access.sh
echo "[*] Re-enabling previously disabled services..."
SERVICES_COMMON=(
  ssh sshd avahi-daemon cups rpcbind nfs-server nfs-kernel-server smbd nmbd samba vsftpd telnet postfix exim4 openssh-server
)
SERVICES_EXTRA=(NetworkManager cloud-init cloud-init-local cloud-config cloud-final snapd)

for s in "${SERVICES_COMMON[@]}" "${SERVICES_EXTRA[@]}"; do
  for unit in "${s}" "${s}.service" "${s}.socket" "${s}.path"; do
    if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qw "^${unit}$" || systemctl status "$unit" >/dev/null 2>&1; then
      echo "  -> Unmasking and enabling $unit"
      systemctl unmask "$unit" >/dev/null 2>&1 || true
      systemctl enable --now "$unit" >/dev/null 2>&1 || true
    fi
  done
done

# 3) Remove IPv6-disable sysctl and reload
SYSCTL_FILE="/etc/sysctl.d/99-disable-ipv6.conf"
if [[ -f "$SYSCTL_FILE" ]]; then
  echo "[*] Removing $SYSCTL_FILE and reloading sysctl"
  rm -f "$SYSCTL_FILE" || true
  sysctl --system || true
else
  echo "[*] No $SYSCTL_FILE found; skipping IPv6 restore step"
fi

# 4) Restore firewall defaults
echo "[*] Restoring firewall defaults (ufw/firewalld/iptables fallback)..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "  -> firewalld active: setting default zone to public and reloading"
  firewall-cmd --set-default-zone=public || true
  firewall-cmd --reload || true
fi

if command -v ufw >/dev/null 2>&1; then
  echo "  -> Resetting ufw and allowing common defaults (SSH)"
  ufw --force reset || true
  ufw default allow outgoing || true
  ufw default deny incoming || true
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw --force enable || true
fi

# If iptables restore didn't run and no ufw/firewalld change, set permissive OUTPUT
if ! systemctl is-active --quiet firewalld 2>/dev/null && ! command -v ufw >/dev/null 2>&1 && [[ -z "$LATEST_BACKUP" ]]; then
  echo "  -> No firewall manager detected and no iptables backup; applying permissive OUTPUT policy"
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -F 2>/dev/null || true
fi

# 5) Optionally reinstall common packages
read -r -p "Do you want to reinstall common network packages removed earlier (cups, postfix, samba, avahi-daemon, vsftpd)? [y/N]: " reinstall_pkgs
if [[ "$reinstall_pkgs" =~ ^[Yy]$ ]]; then
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get update -y || true
    apt-get install -y cups postfix samba avahi-daemon vsftpd || true
  elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    zypper -n in cups postfix samba avahi || true
  else
    echo "  -> No supported package manager detected; please reinstall packages manually."
  fi
else
  echo "  -> Skipping package reinstall"
fi

# 6) Bring up non-loopback interfaces
read -r -p "Bring up non-loopback network interfaces now? [Y/n]: " bringup
if [[ -z "$bringup" || "$bringup" =~ ^[Yy]$ ]]; then
  echo "[*] Bringing up non-loopback interfaces"
  ip -o link show | awk -F': ' '{print $2}' | grep -v lo | while read -r iface; do
    echo "  -> ip link set $iface up"
    ip link set "$iface" up || true
  done
else
  echo "[*] Leaving interfaces as-is"
fi

echo "[✓] Rollback complete. Manual checks recommended:"
echo "  - Verify services that must run are active (systemctl status <service>)"
echo "  - Verify networking and firewall rules (iptables -L -n, ufw status, firewall-cmd --list-all)"
echo "  - If you need to revert specific changes differently, edit and run this script as needed."
exit 0
