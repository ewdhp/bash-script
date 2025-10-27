#!/usr/bin/env bash
# Burst writer for USB: write ISO in 1GB chunks, pause between bursts
# Use: sudo ./burst-writer.sh <iso-file> <device>

set -euo pipefail
ISO="$1"
DEVICE="$2"
BLOCK_SIZE=$((1024*1024*1024))  # 1 GiB
PAUSE=10                         # seconds between bursts

if [[ $# -ne 2 ]]; then
  echo "Usage: sudo $0 <iso-file> <device>"
  exit 1
fi

if [[ ! -f "$ISO" ]]; then
  echo "❌ ISO not found: $ISO"
  exit 1
fi

ISO_SIZE=$(stat -c%s "$ISO")
FULL_BLOCKS=$((ISO_SIZE / BLOCK_SIZE))
REMAINDER=$((ISO_SIZE % BLOCK_SIZE))

echo "💾 Burst writing $ISO → $DEVICE"
echo "   Size: $ISO_SIZE bytes (${FULL_BLOCKS}x1GB + ${REMAINDER}B remainder)"
echo

read -rp "⚠️  This will erase all data on $DEVICE. Continue? [y/N]: " c
[[ "$c" =~ ^[Yy]$ ]] || exit 0

start=$(date +%s)

for ((i=0; i<FULL_BLOCKS; i++)); do
  echo "📦 Writing 1GB chunk $((i+1)) of $FULL_BLOCKS ..."
  dd if="$ISO" of="$DEVICE" bs=$BLOCK_SIZE skip=$i seek=$i count=1 conv=fsync,noerror status=progress

  echo "🕐 Pausing $PAUSE s to let USB flush internal cache..."
  sync
  sleep $PAUSE

  # Optional unmount/mount cycle (can help some controllers)
  if mount | grep -q "$DEVICE"; then
    umount "$DEVICE" || true
  fi
done

if (( REMAINDER > 0 )); then
  echo "🧩 Writing remainder (${REMAINDER} bytes)..."
  dd if="$ISO" of="$DEVICE" bs=1 count=$REMAINDER skip=$((FULL_BLOCKS * BLOCK_SIZE)) seek=$((FULL_BLOCKS * BLOCK_SIZE)) conv=fsync,noerror status=progress
fi

sync
end=$(date +%s)
echo
echo "✅ Done in $((end - start)) seconds!"
