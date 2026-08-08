#!/bin/bash
# Create 4G zstd zram swap backed by an 8G disk image for cold-page writeback.
# Idempotent: no-op if zram swap is already active.
#
# IMPORTANT: use raw sysfs writes, NOT `zramctl -a zstd -s 4G`.
# zramctl resets the device when setting the algorithm+size, which DROPS the
# backing_dev we just attached. Raw writes preserve it:
#   comp_algorithm -> backing_dev -> disksize -> writeback limits
set -e

BACKING_IMG=/var/lib/zram-writeback/backing.img
BACKING_LOOP=/dev/loop0
SIZE_BYTES=4294967296          # 4 GiB
WRITEBACK_LIMIT_BYTES=2147483648  # auto-writeback when compressed data > 2 GiB

if swapon --show --noheadings 2>/dev/null | grep -q /dev/zram; then
  exit 0
fi

# Ensure backing file + loop device exist
if [ ! -f "$BACKING_IMG" ]; then
  fallocate -l 8G "$BACKING_IMG" 2>/dev/null || dd if=/dev/zero of="$BACKING_IMG" bs=1M count=8192 2>/dev/null
  chmod 600 "$BACKING_IMG"
fi
if ! losetup -a 2>/dev/null | grep -q "$BACKING_IMG"; then
  losetup "$BACKING_LOOP" "$BACKING_IMG"
fi

# Create zram node WITHOUT initializing (backing must be attached first)
dev=$(zramctl -f 2>/dev/null)
[ -b "$dev" ] || exit 0
devn=$(basename "$dev")

# 1. Algorithm (zstd) — raw write so the device is not reset
echo zstd > /sys/block/$devn/comp_algorithm

# 2. Attach backing device BEFORE disksize init (kernel requires this order)
echo "$BACKING_LOOP" > /sys/block/$devn/backing_dev

# 3. Initialize: 4G capacity (raw sysfs write preserves backing_dev)
echo "$SIZE_BYTES" > /sys/block/$devn/disksize

# 4. Writeback: auto-writeback when compressed data exceeds 2G
#    (idle aging handled separately by zram-idle-writeback.timer)
echo "$WRITEBACK_LIMIT_BYTES" > /sys/block/$devn/writeback_limit
echo 1 > /sys/block/$devn/writeback_limit_enable

mkswap "$dev" >/dev/null 2>&1 && swapon -p 100 "$dev"
