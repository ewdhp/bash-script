#!/bin/bash
# Simple script to create a Windows bootable USB (like WoeUSB CLI)

set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <windows.iso> <usb_device>"
    echo "Example: $0 Win10.iso /dev/sdb"
    exit 1
fi

ISO="$1"
USB="$2"

# Safety check
echo "WARNING: This will ERASE all data on $USB"
read -p "Type 'YES' to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# Unmount any mounted partitions
sudo umount ${USB}?* || true

# Create new partition table and single NTFS partition
sudo parted --script "$USB" mklabel msdos
sudo parted --script "$USB" mkpart primary ntfs 0% 100%

# Format partition
PART="${USB}1"
sudo mkfs.ntfs -f "$PART"

# Mount ISO and USB
mkdir -p /tmp/iso /tmp/usb
sudo mount -o loop "$ISO" /tmp/iso
sudo mount "$PART" /tmp/usb

# Copy files
sudo rsync -avh --progress /tmp/iso/ /tmp/usb/

# Install bootloader (for BIOS systems)
sudo grub-install --target=i386-pc --boot-directory=/tmp/usb/boot "$USB"

# Cleanup
sudo umount /tmp/iso /tmp/usb
rmdir /tmp/iso /tmp/usb

echo "✅ Bootable Windows USB created on $USB"
