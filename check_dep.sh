#!/bin/bash
# Dependency checker & installer for openSUSE security/forensics environment
# Run with sudo/root

set -euo pipefail

MODE="check"   # default
FULL=false     # default: do not install extra forensic tools

if [[ $# -gt 0 ]]; then
  case "$1" in
    --install) MODE="install" ;;
    --check)   MODE="check" ;;
    --full)    MODE="install"; FULL=true ;;
    *)
      echo "Usage: $0 [--check|--install|--full]"
      echo "  --check    : only report missing commands"
      echo "  --install  : install missing core tools"
      echo "  --full     : install core + optional forensic/security tools"
      exit 1
      ;;
  esac
fi

# Map commands to openSUSE package names
declare -A pkgs=(
  # Core system triage tools
  [ps]="procps"
  [ss]="iproute2"
  [lsof]="lsof"
  [tar]="tar"
  [sha256sum]="coreutils"
  [df]="coreutils"
  [mount]="util-linux"
  [lsblk]="util-linux"
  [systemctl]="systemd"
  [journalctl]="systemd"
  [who]="util-linux"
  [w]="procps"
  [last]="util-linux"
  [lastlog]="util-linux"
  [ip]="iproute2"
  [ausearch]="audit"
  [aureport]="audit"
  [auditctl]="audit"
  [aide]="aide"
  [rpm]="rpm"
  [chkrootkit]="chkrootkit"
  [rkhunter]="rkhunter"
  [tcpdump]="tcpdump"
  [jq]="jq"
  [curl]="curl"
  [wget]="wget"
  [python3]="python3"
  [strings]="binutils"
  [netstat]="net-tools"
  [crontab]="cron"      # cron jobs
  [logger]="util-linux" # log writing
)

# Optional forensic/security tools (installed only in --full mode)
declare -A pkgs_full=(
  [nmap]="nmap"
  [iftop]="iftop"
  [nethogs]="nethogs"
  [tripwire]="tripwire"
  [clamdscan]="clamav"
  [gpg]="gpg2"
  [strace]="strace"
  [file]="file"
  [rsyslogd]="rsyslog"
  [syslog-ng]="syslog-ng"
  [logrotate]="logrotate"
)

# Commands we deliberately skip (always present)
skip_list=("bash" "awk" "sed" "grep" "cut" "uniq" "sort" "ls" "uname" "free" "find" "stat")

echo "[*] Checking dependencies on openSUSE (mode: $MODE, full=$FULL)..."

check_and_install() {
  local cmd=$1
  local pkg=$2

  if [[ " ${skip_list[*]} " == *" $cmd "* ]]; then
    echo "[+] Skipping built-in: $cmd"
    return
  fi

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[+] Found: $cmd"
  else
    if [[ -z "$pkg" ]]; then
      echo "[!] $cmd missing but no package mapping for openSUSE — skipping."
      return
    fi

    if [[ "$MODE" == "check" ]]; then
      echo "[MISSING] $cmd → package: $pkg"
    elif [[ "$MODE" == "install" ]]; then
      echo "[INSTALL] Missing: $cmd → installing package: $pkg"
      sudo zypper --non-interactive install "$pkg"
    fi
  fi
}

# Core tools
for cmd in "${!pkgs[@]}"; do
  check_and_install "$cmd" "${pkgs[$cmd]}"
done

# Full forensic/security tools if requested
if $FULL; then
  echo "[*] Checking optional forensic/security tools..."
  for cmd in "${!pkgs_full[@]}"; do
    check_and_install "$cmd" "${pkgs_full[$cmd]}"
  done
fi

echo "[✓] Dependency check complete."
