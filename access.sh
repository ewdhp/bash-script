#!/bin/bash

# isolate-system.sh - Harden and isolate system from remote access
# Version: 2.1 (updated for Ubuntu/Debian/openSUSE + improved handling)

set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Exiting."
  exit 1
fi

echo "[*] Detecting distribution and package manager..."
# minimal detection
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

echo "[*] Disabling remote access services..."

# Base list (try to cover common names across distros)
SERVICES_COMMON=(
  ssh
  sshd
  avahi-daemon
  cups
  rpcbind
  nfs-server
  nfs-kernel-server
  smbd
  nmbd
  samba
  vsftpd
  telnet
  telnet.socket
  postfix
)

# extra candidates to consider on Ubuntu
SERVICES_UBUNTU=(
  exim4
  openssh-server
)

# extra candidates for openSUSE
# Note: wickedd and NetworkManager are intentionally excluded to preserve network management
SERVICES_OPENSUSE=(
  sshd
  SuSEfirewall2
  SuSEfirewall2_init
  display-manager
)

# merge according to distro
SERVICES=("${SERVICES_COMMON[@]}")
if [[ "$PKG_MANAGER" == "apt" ]]; then
  SERVICES+=("${SERVICES_UBUNTU[@]}")
elif [[ "$PKG_MANAGER" == "zypper" ]]; then
  SERVICES+=("${SERVICES_OPENSUSE[@]}")
fi

# helper to try disabling unit with and without .service suffix
disable_unit() {
  local u="$1"
  # try a few variants
  for candidate in "$u" "${u}.service" "${u}.socket" "${u}.path"; do
    if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qw "^${candidate}$"; then
      echo "  -> Disabling and stopping ${candidate}"
      systemctl disable --now "$candidate" || true
      systemctl mask "$candidate" || true
      return 0
    fi
  done
  # last-ditch: try systemctl status (some units may not appear in list-unit-files)
  if systemctl status "$u" >/dev/null 2>&1; then
    echo "  -> Disabling and stopping $u (detected by status)"
    systemctl disable --now "$u" || true
    systemctl mask "$u" || true
    return 0
  fi

  return 1
}

for service in "${SERVICES[@]}"; do
  if disable_unit "$service"; then
    : # disabled
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
  if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qw "^${unit}$"; then
    echo "  -> Disabling and stopping $unit"
    systemctl disable --now "$unit" || true
    systemctl mask "$unit" || true
  fi
done

echo "[*] Configuring firewall to block incoming connections..."

# Prefer firewalld (default on openSUSE), then ufw (common on Ubuntu), then fallback to iptables
if command -v firewall-cmd >/dev/null 2>&1 && (systemctl is-active --quiet firewalld 2>/dev/null || systemctl is-enabled --quiet firewalld 2>/dev/null); then
  echo "  -> Using firewalld (starting if needed)"
  systemctl start firewalld 2>/dev/null || true
  firewall-cmd --set-default-zone=drop || true
  firewall-cmd --reload || true
  echo "  -> Firewalld configured with drop zone (all incoming blocked)"
elif command -v ufw >/dev/null 2>&1; then
  echo "  -> Using ufw (Ubuntu/Debian)"
  # set defaults then allow loopback and established
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  # ensure loopback
  ufw allow in on lo
  ufw allow out on lo
  ufw allow proto tcp from 127.0.0.0/8 to any port 1:65535 comment 'loopback' || true
  ufw --force enable
else
  echo "  -> No firewalld/ufw found, using iptables (fallback)"
  # flush then set restrictive policies
  iptables -F || true
  iptables -X || true
  iptables -Z || true

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi

echo "[*] (Optional) Disabling IPv6..."
read -r -p "Do you want to disable IPv6 system-wide? [y/N]: " disable_ipv6
if [[ "$disable_ipv6" =~ ^[Yy]$ ]]; then
  echo "  -> Writing IPv6 disable config to /etc/sysctl.d/99-disable-ipv6.conf"
  cat <<EOF >/etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  echo "  -> Reloading sysctl settings"
  sysctl --system || true

  echo "[*] Checking for distro-specific IPv6 overrides..."
  if [[ -f /etc/sysctl.d/70-yast.conf ]] && grep -q "disable_ipv6 = 0" /etc/sysctl.d/70-yast.conf 2>/dev/null; then
    echo "⚠️  YAST config may override IPv6 settings: /etc/sysctl.d/70-yast.conf"
    echo "    Consider renaming it:"
    echo "    mv /etc/sysctl.d/70-yast.conf /etc/sysctl.d/70-yast.conf.bak"
  else
    echo "  -> No YAST IPv6 override found (or not relevant on this distro)."
  fi
else
  echo "  -> Skipping IPv6 disable"
fi

# Additional hardening steps
echo "[*] Performing additional hardening steps..."

# Disable common services (already attempted above, but ensure these are handled)
# Note: NetworkManager is intentionally NOT disabled to maintain network connectivity
if [[ "$PKG_MANAGER" == "zypper" ]]; then
  echo "  -> Disabling cloud-init, snapd (if present) - openSUSE"
  echo "  -> Note: Wicked and NetworkManager are preserved for network management"
  for s in cloud-init cloud-init-local cloud-config cloud-final snapd; do
    if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qw "^${s}.service$" || systemctl status "$s" >/dev/null 2>&1; then
      systemctl disable --now "$s" || true
      systemctl mask "$s" || true
    fi
  done
  
  # openSUSE-specific: disable online update services
  echo "  -> Disabling YaST online updates and automatic refresh"
  for s in packagekitd zypp-refresh.service zypp-refresh.timer; do
    systemctl disable --now "$s" 2>/dev/null || true
    systemctl mask "$s" 2>/dev/null || true
  done
else
  echo "  -> Disabling cloud-init, snapd (if present)"
  echo "  -> Note: NetworkManager is preserved for network management"
  for s in cloud-init cloud-init-local cloud-config cloud-final snapd; do
    if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qw "^${s}.service$" || systemctl status "$s" >/dev/null 2>&1; then
      systemctl disable --now "$s" || true
      systemctl mask "$s" || true
    fi
  done
fi

# Offer package removal (destructive) using detected package manager
read -r -p "Do you want to remove common network-exposing packages (cups, postfix, samba, avahi)? [y/N]: " remove_pkgs
if [[ "$remove_pkgs" =~ ^[Yy]$ ]]; then
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get update -y || true
    apt-get remove -y --purge cups postfix samba avahi-daemon telnetd vsftpd || true
    apt-get autoremove -y || true
  elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    echo "  -> Removing packages with zypper (openSUSE)"
    # openSUSE package names: cups, postfix, samba, avahi, vsftpd, telnet-server
    zypper -n rm --clean-deps cups postfix samba samba-client avahi avahi-utils vsftpd telnet-server 2>/dev/null || true
    echo "  -> Package removal complete"
  else
    echo "  -> No known package manager detected; please remove packages manually."
  fi
else
  echo "  -> Skipping package removal"
fi

# Offer to bring down non-loopback interfaces (very disruptive)
read -r -p "Do you want to bring down all non-loopback network interfaces now? This will disconnect you immediately if over SSH. [y/N]: " down_ifaces
if [[ "$down_ifaces" =~ ^[Yy]$ ]]; then
  echo "  -> Bringing down non-loopback interfaces"
  echo "  -> WARNING: NetworkManager/Wicked will remain running but interfaces will be down"
  
  ip -o link show | awk -F': ' '{print $2}' | grep -v lo | while read -r iface; do
    echo "    -> ip link set $iface down"
    ip link set "$iface" down || true
  done
else
  echo "  -> Leaving interfaces up"
fi

echo "[*] Final cleanup: mask any remaining sockets and prevent automatic restarts"
# mask potentially dangerous targets
for m in cups.socket cups.path avahi-daemon.socket postfix.service; do
  if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qw "^${m}$"; then
    systemctl mask "$m" || true
  fi
done

echo "[✓] Isolation complete. System should now be unreachable from remote hosts (unless you kept interfaces up)."
echo "Note: If you are connected remotely (SSH), be careful—bringing interfaces down or removing ssh packages can cut your access."
if [[ "$PKG_MANAGER" == "zypper" ]]; then
  echo "[openSUSE] Remember: YaST may re-enable some services. Use 'systemctl mask' to prevent this."
  echo "[openSUSE] Firewalld is the default firewall. Use 'firewall-cmd' to manage rules."
fi

# NEW: Restrict outbound to only Firefox and VSCode (practical approach)
read -r -p "Restrict outbound network so only Firefox and VSCode can access network? This will DROP other outbound traffic and may disconnect remote sessions. [y/N]: " restrict_apps
if [[ "$restrict_apps" =~ ^[Yy]$ ]]; then
  # determine the non-root interactive user (default)
  TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  if [[ -z "$TARGET_USER" ]]; then
    read -r -p "Could not detect a local user. Enter username to allow (processes of this user will be allowed): " TARGET_USER
  fi

  echo "  -> Restricting outbound to processes owned by user: ${TARGET_USER}"

  # backup current iptables
  iptables-save >/root/iptables-backup-$(date +%s).rules || true

  # Apply strict iptables: block outbound by default, allow loopback and established,
  # then allow outbound TCP 80/443 and UDP 53 for the chosen user's processes.
  iptables -F || true
  iptables -X || true
  iptables -Z || true

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP

  # loopback + related/established
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  # Allow DNS (UDP 53) for the user (so apps can resolve names)
  if id -u "$TARGET_USER" >/dev/null 2>&1; then
    UID_NUM=$(id -u "$TARGET_USER")
    # HTTP/HTTPS for browser & VSCode
    iptables -A OUTPUT -m owner --uid-owner "$UID_NUM" -p tcp --dport 80 -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$UID_NUM" -p tcp --dport 443 -j ACCEPT
    # DNS (UDP) — allow to any (common resolvers) for that user
    iptables -A OUTPUT -m owner --uid-owner "$UID_NUM" -p udp --dport 53 -j ACCEPT
    # allow DNS over TCP as fallback
    iptables -A OUTPUT -m owner --uid-owner "$UID_NUM" -p tcp --dport 53 -j ACCEPT

    echo "  -> Applied owner-based rules for UID $UID_NUM (user $TARGET_USER)."
    echo "     Allows TCP 80/443 and DNS for that user's processes (practical allow for Firefox/VSCode)."
  else
    echo "  -> Could not determine UID for user '$TARGET_USER'. No owner-based rules applied."
  fi

  echo "  -> Restriction applied. Reminder: this allows any process run by $TARGET_USER to access ports 80/443 (approx. Firefox/VSCode)."
  echo "     If you are connected remotely (SSH), you may be disconnected. Have local access available."
fi

