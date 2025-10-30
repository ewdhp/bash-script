#!/usr/bin/env bash
set -euo pipefail

# === SETTINGS (edit these if needed) ===
LUKS_DEV="/dev/nvme0n1p2"               # your encrypted partition (change if different)
USB_DEV="/dev/sda1"                     # the block device for the USB partition that will be formatted (BE CAREFUL)
USB_LABEL="GRUBKEY"                     # label for the USB filesystem
KEYFILE_NAME="grub-luks.key"
KEYFILE_LOCAL="/root/${KEYFILE_NAME}"
GRUB_CUSTOM="/etc/grub.d/05_usb_unlock"

# === FUNCTIONS ===
function error_exit {
  echo "❌ ERROR: $1" >&2
  exit 1
}

function command_exists {
  command -v "$1" >/dev/null 2>&1
}

# === 0. Require root ===
if [[ $EUID -ne 0 ]]; then
  error_exit "This script must be run as root (sudo)."
fi


# === 1. Check required commands and install missing packages on Ubuntu ===
REQUIRED_CMDS=(cryptsetup lsblk blkid grub-mkconfig mkfs.vfat mount umount dd sync grep sed)
REQUIRED_PKGS=(cryptsetup grub-common dosfstools)

# Detect Ubuntu and install missing packages
if grep -qi ubuntu /etc/os-release; then
  echo "[*] Detected Ubuntu. Checking required packages..."
  for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      echo "[*] Installing missing package: $pkg"
      apt-get update && apt-get install -y "$pkg"
    fi
  done
fi

# Check required commands
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command_exists "$cmd"; then
    error_exit "Required command '$cmd' not found. Please install it."
  fi
done

# === 2. Check LUKS device existence and type ===
if [[ ! -b "$LUKS_DEV" ]]; then
  error_exit "LUKS device $LUKS_DEV not found."
fi

if ! cryptsetup isLuks "$LUKS_DEV" >/dev/null 2>&1; then
  error_exit "Device $LUKS_DEV is not a valid LUKS volume."
fi

LUKS_UUID=$(blkid -s UUID -o value "$LUKS_DEV")
if [[ -z "$LUKS_UUID" ]]; then
  error_exit "Could not determine UUID of $LUKS_DEV"
fi
echo "[*] Found LUKS device: $LUKS_DEV (UUID: $LUKS_UUID)"

# === 3. Check USB device existence & not mounted ===
if [[ ! -b "$USB_DEV" ]]; then
  error_exit "USB device $USB_DEV not found."
fi

if mount | grep -q "^${USB_DEV}"; then
  error_exit "USB device $USB_DEV is currently mounted. Please unmount before running."
fi

# Confirm the user really wants to format the USB block device
echo "⚠ WARNING: USB device $USB_DEV will be FORMATTED and ALL DATA LOST!"
read -rp "Type 'YES' to confirm formatting $USB_DEV: " confirm
if [[ "$confirm" != "YES" ]]; then
  error_exit "User aborted formatting."
fi

# === 4. Create local keyfile if missing ===
if [[ ! -f "$KEYFILE_LOCAL" ]]; then
  echo "[*] Creating keyfile $KEYFILE_LOCAL ..."
  dd if=/dev/urandom of="$KEYFILE_LOCAL" bs=4096 count=1 status=none
  chmod 0400 "$KEYFILE_LOCAL"
else
  echo "[*] Using existing keyfile $KEYFILE_LOCAL"
fi

# === 5. Check if keyfile already valid for LUKS (test) ===
if cryptsetup open --test-passphrase --key-file "$KEYFILE_LOCAL" "$LUKS_DEV" >/dev/null 2>&1; then
  echo "[*] Keyfile is valid for LUKS device."
else
  echo "[*] Adding keyfile to LUKS keyslots..."
  cryptsetup luksAddKey "$LUKS_DEV" "$KEYFILE_LOCAL"
fi

# === 6. Format USB and copy keyfile ===
echo "[*] Formatting $USB_DEV as FAT32 with label $USB_LABEL ..."
# Use mkfs.vfat; label is set with -n
mkfs.vfat -n "$USB_LABEL" "$USB_DEV"

mountpoint="/mnt/usbkey-$$"
mkdir -p "$mountpoint"

echo "[*] Mounting $USB_DEV to $mountpoint ..."
mount "$USB_DEV" "$mountpoint"

echo "[*] Copying keyfile to USB ..."
cp "$KEYFILE_LOCAL" "$mountpoint/$KEYFILE_NAME"
sync

echo "[*] Unmounting USB ..."
umount "$mountpoint"
rmdir "$mountpoint"


# === 7. Enable GRUB cryptodisk in /etc/default/grub if not already ===
if ! grep -q '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub 2>/dev/null; then
  echo "[*] Enabling GRUB_ENABLE_CRYPTODISK=y in /etc/default/grub"
  echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
else
  echo "[*] GRUB_ENABLE_CRYPTODISK already enabled."
fi

# === 8. Write early GRUB unlock script to /etc/grub.d/05_usb_unlock (debug version) ===
echo "[*] Writing GRUB USB unlock (debug) snippet to $GRUB_CUSTOM ..."
cat > "$GRUB_CUSTOM" <<'EOF'
#!/bin/sh
exec tail -n +3 $0
# Debugging GRUB USB unlock — verbose output for troubleshooting

# Print GRUB internal debug info
set debug=all

# load modules we need
insmod part_gpt
insmod usb
insmod usbms
insmod fat
insmod ext2
insmod cryptodisk
insmod luks
insmod gcry_rijndael
insmod gcry_sha256

echo "DEBUG: GRUB debug enabled. Waiting for USB enumeration..."
# Give firmware/GRUB time to detect USB devices (increase if necessary)
sleep 10

echo "DEBUG: top-level device list (ls):"
ls || true

# Print possible disk/partition nodes (may show (hd0) (hd1,gpt1) etc)
echo "DEBUG: listing potential devices:"
for d in `ls 2>/dev/null`; do
  echo "DEBUG: device -> $d"
  ls $d || true
done

# Attempt to find the USB by filesystem label (label substituted by generator)
echo "DEBUG: searching for label: '"${USB_LABEL}"'"
search --no-floppy --label ${USB_LABEL} --set=usbdev || true

echo "DEBUG: usbdev variable (raw): \$usbdev"
if [ -n "$usbdev" ]; then
  echo "🔑 USB key found at \$usbdev — root listing:"
  ls (\${usbdev})/ || true

  echo "DEBUG: checking for keyfile (\${usbdev})/${KEYFILE_NAME}"
  if ls (\${usbdev})/${KEYFILE_NAME} >/dev/null 2>&1; then
    echo "DEBUG: keyfile present. Attempting cryptomount..."
    if cryptomount -u ${LUKS_UUID} -k (\${usbdev})/${KEYFILE_NAME}; then
      echo "✅ LUKS unlocked successfully via USB key."
      # If desired: early exit or continue to menu (leave as-is)
    else
      echo "❌ cryptomount failed using the USB key. Falling back to manual passphrase."
    fi
  else
    echo "❌ keyfile not found on \$usbdev. Falling back to manual passphrase."
  fi
else
  echo "⚠ USB key not detected (usbdev empty). Falling back to manual passphrase."
fi

# keep GRUB menu timeout long enough to inspect messages
set timeout=30
EOF

chmod 0755 "$GRUB_CUSTOM"

echo
echo "✅ Setup complete!"
echo
echo "Notes:"
echo "- The USB key should contain the keyfile ${KEYFILE_NAME} at its root and be labeled ${USB_LABEL}."
echo "- On boot, if the USB key is present GRUB will try to unlock UUID ${LUKS_UUID} automatically."
echo "- If the USB key is not present or cannot unlock, GRUB will fall back to asking for the passphrase."
echo

echo "Reminder: Keep the USB key and your passphrase safe. Test the keyfile locally before rebooting if you haven't already:"
echo "  sudo cryptsetup open --test-passphrase --key-file ${KEYFILE_LOCAL} ${LUKS_DEV}"

echo "If you are on Ubuntu, regenerate your GRUB config with:"
echo "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
