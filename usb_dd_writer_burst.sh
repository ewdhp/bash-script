#!/usr/bin/env bash
# Burst USB writer — write ISO in large chunk bursts with pauses to improve
# transfer rate on flaky USB controllers. Safe defaults and explicit prompts.

set -euo pipefail

ISO=""
DEVICE=""
BLOCK_SIZE=$((1024*1024*1024)) # 1 GiB
# Pause (seconds) between bursts. Default 1s — reduce by default to avoid long delays.
# Set to 0 to disable pauses entirely.
PAUSE=1
PAUSE_SET=0
BS_OUTPUT=4M

# Cycle behaviour: after writing CYCLE_BYTES, unmount the device, wait CYCLE_SLEEP seconds,
# then (optionally) attempt to mount again and continue writing where left off.
# Default: 2 GiB and 10 seconds (10s)
CYCLE_BYTES=$((2*1024*1024*1024))
CYCLE_SLEEP=10
CYCLE_SET=0

usage() {
  cat <<EOF
Usage: $0 <iso-file> <device>
Example: sudo $0 /home/user/Downloads/ubuntu.iso /dev/sdb

Options:
  -b <bytes>   chunk block size (default 1GiB)
  -p <seconds> pause between bursts (default 1)
  -c <bytes>   cycle threshold in bytes (default 2GiB) — unmount/mount after this many bytes written
  -w <seconds> wait time after unmount (default 10 = 10s)
  -h           show this help
EOF
}

while getopts ":b:p:nh:c:w:h" opt; do
  case "$opt" in
    b) BLOCK_SIZE="$OPTARG" ;;
    p) PAUSE="$OPTARG" ; PAUSE_SET=1 ;;
    c) CYCLE_BYTES="$OPTARG" ; CYCLE_SET=1 ;;
    w) CYCLE_SLEEP="$OPTARG" ; CYCLE_SET=1 ;;
    h) usage; exit 0 ;;
    n) PAUSE=0 ; PAUSE_SET=1 ;;
    \?) echo "Invalid option: -$OPTARG"; usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

ISO="$1"
DEVICE="$2"

if [[ ! -f "$ISO" ]]; then
  echo "❌ ISO not found: $ISO" >&2
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "❌ Target is not a block device: $DEVICE" >&2
  exit 1
fi

# If the target is not a USB transport device, pause is usually unnecessary;
# disable pauses by default unless the user explicitly set -p.
TRAN=$(lsblk -no TRAN -d "$DEVICE" 2>/dev/null || true)
if [[ "$TRAN" != "usb" && $PAUSE_SET -eq 0 ]]; then
  PAUSE=0
fi

# helper: time a command and print throughput
run_and_time() {
  local bytes="$1"; shift
  local start end elapsed mb speed
  start=$(date +%s.%N)
  "$@"
  local rc=$?
  end=$(date +%s.%N)
  elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN{el=e-s; if(el<=0) el=0.000001; printf "%.6f", el}')
  mb=$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1024/1024}')
  speed=$(awk -v b="$bytes" -v e="$elapsed" 'BEGIN{printf "%.2f", (b/e)/1024/1024}')
  >&2 echo "   ✅ Completed: ${mb} MiB in ${elapsed}s (${speed} MiB/s)"
  return $rc
}

ISO_SIZE=$(stat -c%s "$ISO")
FULL_BLOCKS=$((ISO_SIZE / BLOCK_SIZE))
REMAINDER=$((ISO_SIZE % BLOCK_SIZE))

# Track how many bytes we've written so far so we can perform unmount/mount cycles
total_written=0

echo "💾 Burst writing $ISO → $DEVICE"
echo "   Size: $ISO_SIZE bytes (${FULL_BLOCKS}x$(numfmt --to=iec $BLOCK_SIZE) + ${REMAINDER}B remainder)"
echo

read -rp "⚠️  This will erase all data on $DEVICE. Continue? [y/N]: " c
[[ "$c" =~ ^[Yy]$ ]] || exit 0

# Unmount any mounted partitions of the target device (safer explicit unmounts)
for part in $(lsblk -ln -o NAME "$DEVICE" | tail -n +2 2>/dev/null || true); do
  if mount | grep -q "/dev/$part"; then
    echo "Unmounting /dev/$part"
    umount "/dev/$part" || true
  fi
done

start_time=$(date +%s)

for ((i=0; i<FULL_BLOCKS; i++)); do
  echo "📦 Writing chunk $((i+1)) of $FULL_BLOCKS (bs=$(numfmt --to=iec $BLOCK_SIZE)) ..."
  # dd uses skip/seek in blocks (we use block size = BLOCK_SIZE)
  run_and_time $BLOCK_SIZE dd if="$ISO" of="$DEVICE" bs=$BLOCK_SIZE skip=$i seek=$i count=1 conv=fsync,noerror status=progress

  # update counters and check if we need to perform a cycle (unmount/wait/mount)
  total_written=$((total_written + BLOCK_SIZE))
  if (( CYCLE_BYTES > 0 && total_written >= CYCLE_BYTES )); then
    echo "🔁 Cycle threshold reached (${total_written} bytes >= ${CYCLE_BYTES}). Performing unmount -> wait -> remount cycle..."
    # Unmount child partitions
    for part in $(lsblk -ln -o NAME "$DEVICE" | tail -n +2 2>/dev/null || true); do
      if mount | grep -q "/dev/$part"; then
        echo "Unmounting /dev/$part"
        umount "/dev/$part" || true
      fi
    done

    echo "⏱ Sleeping for ${CYCLE_SLEEP} seconds..."
    sleep "$CYCLE_SLEEP"

    # Try to re-probe and mount the first partition (best-effort)
    echo "🔎 Re-probing device and attempting to mount first partition (if any)"
    sudo partprobe "$DEVICE" || true
    first_part=$(lsblk -ln -o NAME "$DEVICE" | sed -n '2p' || true)
    if [[ -n "$first_part" ]]; then
      if command -v udisksctl >/dev/null 2>&1; then
        echo "Attempting to mount /dev/$first_part using udisksctl"
        udisksctl mount -b "/dev/$first_part" || echo "udisksctl mount failed (continuing)"
      else
        echo "udisksctl not found — skipping automatic mount"
      fi
    fi

    # reset the cycle counter so this happens again only if more bytes accumulate
    total_written=0
  fi

  if (( PAUSE > 0 )); then
    echo "🕐 Pausing $PAUSE s to let USB controller flush internal cache..."
    sync
    sleep $PAUSE
  fi
done

if (( REMAINDER > 0 )); then
  echo "🧩 Writing remainder (${REMAINDER} bytes)..."
  # Copy remainder efficiently using dd byte flags
  run_and_time $REMAINDER dd if="$ISO" of="$DEVICE" bs=$BS_OUTPUT iflag=skip_bytes,count_bytes oflag=seek_bytes skip=$((FULL_BLOCKS * BLOCK_SIZE)) count=$REMAINDER conv=fsync,noerror status=progress
  total_written=$((total_written + REMAINDER))
  if (( CYCLE_BYTES > 0 && total_written >= CYCLE_BYTES )); then
    echo "🔁 Cycle threshold reached after remainder (${total_written} bytes) — performing unmount/wait/remount..."
    for part in $(lsblk -ln -o NAME "$DEVICE" | tail -n +2 2>/dev/null || true); do
      if mount | grep -q "/dev/$part"; then
        echo "Unmounting /dev/$part"
        umount "/dev/$part" || true
      fi
    done
    echo "⏱ Sleeping for ${CYCLE_SLEEP} seconds..."
    sleep "$CYCLE_SLEEP"
    sudo partprobe "$DEVICE" || true
    first_part=$(lsblk -ln -o NAME "$DEVICE" | sed -n '2p' || true)
    if [[ -n "$first_part" && command -v udisksctl >/dev/null 2>&1 ]]; then
      udisksctl mount -b "/dev/$first_part" || true
    fi
    total_written=0
  fi
fi

sync
end_time=$(date +%s)
echo
echo "✅ Done in $((end_time - start_time)) seconds!"

exit 0
