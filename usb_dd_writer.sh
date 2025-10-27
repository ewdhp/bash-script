#!/usr/bin/env bash
# Universal USB Utility — Flash ISO or Secure Erase
# Ubuntu-compatible, safe for removable drives

set -e

echo "🔍 Detecting removable USB drives..."
echo

USB_LIST=$(lsblk -S -o NAME,TRAN,SIZE,MODEL,TYPE | awk '/usb/{print $1}')

if [ -z "$USB_LIST" ]; then
  echo "❌ No removable USB device found."
  exit 1
fi

echo "Available USB drives:"
i=1
for dev in $USB_LIST; do
  info=$(lsblk -S -o NAME,SIZE,MODEL | grep "$dev")
  echo "  $i) /dev/$info"
  ((i++))
done

echo
read -p "Select the number of the drive: " choice

index=1
for dev in $USB_LIST; do
  if [ "$index" -eq "$choice" ]; then
    DEVICE="/dev/$dev"
    break
  fi
  ((index++))
done

if [ -z "$DEVICE" ]; then
  echo "❌ Invalid selection."
  exit 1
fi

lsblk "$DEVICE"
echo
echo "Choose action:"
echo "  1) Flash ISO image"
echo "  2) Secure erase (overwrite/zero/random)"
read -p "Select option [1/2]: " ACTION

case $ACTION in
  1)
    read -rp "Enter full path to ISO image: " ISO_PATH
    if [ ! -f "$ISO_PATH" ]; then
      echo "❌ ISO file not found."
      exit 1
    fi
    echo "⚠️  This will erase all data on $DEVICE!"
    read -rp "Continue? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    echo
    echo "🧭 Writing ISO to $DEVICE..."
    if command -v pv &>/dev/null; then
      pv "$ISO_PATH" | dd of="$DEVICE" bs=4M conv=fsync,noerror status=progress
    else
      dd if="$ISO_PATH" of="$DEVICE" bs=4M conv=fsync,noerror status=progress
    fi
    ;;
  2)
    echo
    echo "Secure erase methods:"
    echo "  1) Zero fill (fast)"
    echo "  2) Random fill (secure, slow)"
    echo "  3) Shred (multi-pass + zero pass)"
    echo "  4) blkdiscard (instant TRIM if supported)"
    read -p "Choose erase method [1-4]: " ERASE

    echo "⚠️  This will destroy ALL data on $DEVICE!"
    read -rp "Continue? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    case $ERASE in
      1)
        echo "Zero filling $DEVICE..."
        dd if=/dev/zero of="$DEVICE" bs=4M status=progress conv=fsync,noerror
        ;;
      2)
        echo "Random overwriting $DEVICE..."
        dd if=/dev/urandom of="$DEVICE" bs=4M status=progress conv=fsync,noerror
        ;;
      3)
        echo "Shredding $DEVICE (3 passes + zero)..."
        shred -v -n 3 -z "$DEVICE"
        ;;
      4)
        echo "Attempting blkdiscard on $DEVICE..."
        blkdiscard "$DEVICE" || echo "blkdiscard failed (device may not support TRIM)"
        ;;
      *)
        echo "Invalid selection."
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Invalid option."
    exit 1
    ;;
esac

sync
echo
echo "✅ Operation complete on $DEVICE"
