#!/usr/bin/env bash
set -euo pipefail

DEVICE="/dev/sda"
ISO="ubuntu-25.10-desktop-amd64.iso"
CRYPT_NAME="tools_crypt"
MOUNT_POINT="/mnt/tools"

# Safety checks
if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "Device $DEVICE not found."
  exit 1
fi

if [[ ! -f "$ISO" ]]; then
  echo "ISO file not found: $ISO"
  exit 1
fi

# Calculate ISO size
ISO_SIZE_BYTES=$(stat -c%s "$ISO")
ISO_SIZE_MB=$((ISO_SIZE_BYTES / 1024 / 1024 + 100))  # Add 100MB buffer
echo "ISO size: ${ISO_SIZE_MB}MB (with buffer)"

echo "WARNING: THIS WILL ERASE ALL DATA ON $DEVICE"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

echo "[1/7] Unmounting existing partitions..."
umount ${DEVICE}?* 2>/dev/null || true

echo "[2/7] Wiping partition table..."
wipefs -a "$DEVICE"
sgdisk --zap-all "$DEVICE"

echo "[3/7] Creating partition table..."
parted -s "$DEVICE" mklabel gpt

# ISO partition (sized to fit ISO)
parted -s "$DEVICE" mkpart iso 1MiB "${ISO_SIZE_MB}MiB"

# Encrypted tools partition (rest of disk)
parted -s "$DEVICE" mkpart tools ext4 "${ISO_SIZE_MB}MiB" 100%

partprobe "$DEVICE"
sleep 2

ISO_PART="${DEVICE}1"
TOOLS_PART="${DEVICE}2"

echo "[4/7] Writing Ubuntu ISO to first partition..."
dd if="$ISO" of="$ISO_PART" bs=4M status=progress oflag=sync

sync

echo "[5/7] Setting up LUKS encryption on tools partition..."
cryptsetup luksFormat "$TOOLS_PART"
cryptsetup open "$TOOLS_PART" "$CRYPT_NAME"

echo "[6/7] Formatting encrypted partition..."
mkfs.ext4 "/dev/mapper/$CRYPT_NAME"

mkdir -p "$MOUNT_POINT"
mount "/dev/mapper/$CRYPT_NAME" "$MOUNT_POINT"

echo "Encrypted tools partition mounted at $MOUNT_POINT"

echo "[7/7] Cleaning up..."
umount "$MOUNT_POINT"
cryptsetup close "$CRYPT_NAME"

echo "DONE."
echo "Bootable Ubuntu ISO written to: $ISO_PART"
echo "Encrypted tools partition: $TOOLS_PART"