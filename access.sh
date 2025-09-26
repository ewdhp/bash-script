#!/bin/bash

# isolate-system.sh - Harden and isolate openSUSE system from remote access
# Version: 2.0

set -euo pipefail

echo "[*] Disabling remote access services..."

SERVICES=(
  sshd
  avahi-daemon
  cups
  rpcbind
  nfs-server
  smb
  nmb
  vsftpd
  telnet.socket
)

for service in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^$service"; then
    echo "  -> Disabling and stopping $service"
    systemctl disable --now "$service" || true
  else
    echo "  -> $service not found, skipping"
  fi
done

echo "[*] Disabling lingering socket and path units..."

SOCKETS_AND_PATHS=(
  avahi-daemon.socket
  cups.socket
  cups.path
)

for unit in "${SOCKETS_AND_PATHS[@]}"; do
  if systemctl list-unit-files | grep -q "^$unit"; then
    echo "  -> Disabling and stopping $unit"
    systemctl disable --now "$unit" || true
  fi
done

echo "[*] Configuring firewall to block all incoming connections..."

if systemctl is-active --quiet firewalld; then
  echo "  -> Using firewalld"
  firewall-cmd --set-default-zone=drop
  firewall-cmd --reload
else
  echo "  -> firewalld not found, using iptables"

  iptables -F
  iptables -X
  iptables -Z

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi

echo "[*] (Optional) Disabling IPv6..."

read -p "Do you want to disable IPv6 system-wide? [y/N]: " disable_ipv6
if [[ "$disable_ipv6" =~ ^[Yy]$ ]]; then
  echo "  -> Writing IPv6 disable config to /etc/sysctl.d/99-disable-ipv6.conf"

  cat <<EOF >/etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

  echo "  -> Reloading sysctl settings"
  sysctl --system

  echo "[*] Checking for YAST IPv6 override..."
  if grep -q "disable_ipv6 = 0" /etc/sysctl.d/70-yast.conf 2>/dev/null; then
    echo "⚠️  YAST config may override IPv6 settings: /etc/sysctl.d/70-yast.conf"
    echo "    Consider renaming it:"
    echo "    sudo mv /etc/sysctl.d/70-yast.conf /etc/sysctl.d/70-yast.conf.bak"
  else
    echo "  -> No YAST IPv6 override found."
  fi
else
  echo "  -> Skipping IPv6 disable"
fi

echo "[✓] Isolation complete. System should now be unreachable from remote hosts."

# Disable CUPS and Postfix
sudo systemctl disable --now cups.service cups.socket cups.path
sudo systemctl disable --now postfix

# Optional: Remove packages if not needed
sudo zypper remove cups postfix

# (Optional) Disable chronyd
# sudo systemctl disable --now chronyd

