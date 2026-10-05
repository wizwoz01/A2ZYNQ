#!/usr/bin/env bash
# Write a bootable A2ZYNQ SD card for the Smart Zynq SP.
#
#   boards/a2n20v2-SmartZynq/tools/write_sd_card.sh /dev/sdX
#
# What it does:
#   1. Makes a working copy of the Xillinux 2.0 SD image (FAT boot partition +
#      Ubuntu 16.04 root filesystem).
#   2. Puts the Smart Zynq boot.bin (from the Xillinux kit), the A2ZYNQ device
#      tree and the A2ZYNQ bitstream on the FAT partition.
#   3. Installs a2hostd, its systemd service and the UIO module autoload on the
#      root filesystem, and creates /media/a2 (your disk images) and
#      /var/lib/a2host (settings).
#   4. Writes the result to the SD card with dd.
#
# Before running it you need:
#   - the Xillinux kit in third_party/ (or A2ZYNQ_XILLINUX), see third_party/README.md
#   - the Xillinux image: third_party/xillinux-2.0a.img (or .img.gz), or set
#     A2ZYNQ_XILLINUX_IMG=/path/to/xillinux-2.0a.img
#   - boards/a2n20v2-SmartZynq/build/xillydemo.bit  (vivado/build.tcl)
#   - boards/a2n20v2-SmartZynq/build/a2hostd        (tools/build_a2hostd.sh)
#   - udisksctl (for mounting the image without root), sudo, python3, dtc
#
# It refuses to touch the disk your PC boots from, and asks you to type the
# device name before it erases anything.
set -euo pipefail

BOARD="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$BOARD/../.." && pwd)"
KIT="${A2ZYNQ_XILLINUX:-$REPO/third_party/xillinux-eval-SmartZynq-SP-1.0b}"
BOOTFILES="$KIT/bootfiles"
OUT="$BOARD/build"
BIT="$OUT/xillydemo.bit"
DTB="$OUT/devicetree.dtb"
HOSTD="$OUT/a2hostd"
WORK_IMG="$OUT/a2zynq-sd.img"

usage() {
    cat <<EOF
Usage: $0 /dev/sdX

Writes Xillinux + the A2ZYNQ bitstream, device tree and a2hostd to an SD card
(4 GB or larger). Everything on the card is erased.
EOF
    exit 1
}

DEVICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        /dev/*) DEVICE="$1"; shift ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "$DEVICE" ] || usage

# Find the Xillinux image.
STOCK_IMG="${A2ZYNQ_XILLINUX_IMG:-}"
if [ -z "$STOCK_IMG" ]; then
    for c in "$REPO/third_party/xillinux-2.0a.img" "$REPO/third_party/xillinux-2.0a.img.gz"; do
        [ -f "$c" ] && { STOCK_IMG="$c"; break; }
    done
fi
[ -n "$STOCK_IMG" ] && [ -f "$STOCK_IMG" ] || {
    echo "Xillinux image not found. Put xillinux-2.0a.img(.gz) in third_party/" >&2
    echo "or set A2ZYNQ_XILLINUX_IMG." >&2
    exit 1
}
[ -f "$BOOTFILES/boot.bin" ] || { echo "missing $BOOTFILES/boot.bin (see third_party/README.md)" >&2; exit 1; }
[ -f "$BIT" ] || { echo "missing $BIT (run vivado/build.tcl first)" >&2; exit 1; }
if [ ! -f "$HOSTD" ]; then
    echo "missing $HOSTD (run tools/build_a2hostd.sh first)" >&2
    exit 1
fi

# Safety checks on the target.
if [ ! -b "$DEVICE" ]; then
    echo "not a block device: $DEVICE" >&2
    echo "USB card readers often change letter after a replug. Current disks:" >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,TRAN,MOUNTPOINT >&2
    exit 1
fi
ROOT_SRC="$(findmnt -no SOURCE / || true)"
case "$ROOT_SRC" in
    ${DEVICE}*) echo "refusing to write $DEVICE: your PC boots from it" >&2; exit 1 ;;
esac
SIZE_B="$(lsblk -bno SIZE "$DEVICE" | head -1 | tr -d ' ')"
if [ "${SIZE_B:-0}" -lt $((3800 * 1000 * 1000)) ]; then
    echo "$DEVICE is too small; the Xillinux image needs a 4 GB card." >&2
    exit 1
fi

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

echo "Building the device tree..."
python3 "$BOARD/tools/merge_dtb.py"

mkdir -p "$OUT"
echo "Preparing the working image (copies about 3.6 GB the first time)..."
case "$STOCK_IMG" in
    *.gz)
        if [ ! -f "$WORK_IMG" ] || [ "$STOCK_IMG" -nt "$WORK_IMG" ]; then
            gzip -dc "$STOCK_IMG" > "$WORK_IMG"
        fi ;;
    *)
        if [ ! -f "$WORK_IMG" ] || [ "$STOCK_IMG" -nt "$WORK_IMG" ]; then
            cp --reflink=auto --sparse=always "$STOCK_IMG" "$WORK_IMG"
        fi ;;
esac

echo "Attaching the working image..."
LOOP_LINE="$(udisksctl loop-setup -f "$WORK_IMG" --no-user-interaction)"
LOOP="$(printf '%s\n' "$LOOP_LINE" | sed -n 's/.*as \(.*\)\.$/\1/p')"
[ -n "$LOOP" ] || { echo "loop-setup failed: $LOOP_LINE" >&2; exit 1; }
cleanup() {
    udisksctl unmount -b "${LOOP}p1" >/dev/null 2>&1 || true
    udisksctl unmount -b "${LOOP}p2" >/dev/null 2>&1 || true
    udisksctl loop-delete -b "$LOOP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

M1=""; M2=""
for _ in $(seq 1 10); do
    M1="$(lsblk -no MOUNTPOINT "${LOOP}p1" 2>/dev/null | head -1)"
    M2="$(lsblk -no MOUNTPOINT "${LOOP}p2" 2>/dev/null | head -1)"
    if [ -z "$M1" ]; then udisksctl mount -b "${LOOP}p1" >/dev/null 2>&1 || true; fi
    if [ -z "$M2" ]; then udisksctl mount -b "${LOOP}p2" >/dev/null 2>&1 || true; fi
    [ -n "$M1" ] && [ -n "$M2" ] && break
    sleep 1
done
[ -n "$M1" ] && [ -n "$M2" ] || { echo "could not mount the image partitions" >&2; lsblk "$LOOP" >&2; exit 1; }

echo "Boot partition ($M1): boot.bin, devicetree.dtb, xillydemo.bit"
cp -f "$BOOTFILES/boot.bin" "$M1/boot.bin"
cp -f "$DTB" "$M1/devicetree.dtb"
cp -f "$BIT" "$M1/xillydemo.bit"
sync

echo "Root filesystem ($M2): a2hostd and its service (needs sudo)"
as_root mkdir -p \
    "$M2/usr/local/sbin" "$M2/etc/systemd/system/multi-user.target.wants" \
    "$M2/etc/modules-load.d" "$M2/media/a2" "$M2/var/lib/a2host"
as_root install -m 0755 "$HOSTD" "$M2/usr/local/sbin/a2hostd"
as_root install -m 0644 "$BOARD/src/systemd/a2hostd.service" "$M2/etc/systemd/system/a2hostd.service"
as_root ln -sfn /etc/systemd/system/a2hostd.service \
    "$M2/etc/systemd/system/multi-user.target.wants/a2hostd.service"
printf 'uio\nuio_pdrv_genirq\n' | as_root tee "$M2/etc/modules-load.d/a2-uio.conf" >/dev/null
sync
ls -lh "$M1"
cleanup
trap - EXIT

echo
echo "About to write the image to $DEVICE:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,MOUNTPOINT "$DEVICE"
echo
echo "EVERYTHING on $DEVICE will be erased."
read -r -p "Type the device name again to continue ($DEVICE): " CONFIRM
[ "$CONFIRM" = "$DEVICE" ] || { echo "Stopped, nothing written."; exit 1; }

for p in $(lsblk -lnpo NAME "$DEVICE" | tail -n +2); do
    udisksctl unmount -b "$p" >/dev/null 2>&1 || true
done
as_root dd if="$WORK_IMG" of="$DEVICE" bs=4M status=progress conv=fsync
sync
eject "$DEVICE" 2>/dev/null || true
echo
echo "Done. Put the card in the Smart Zynq and power it up."
echo "Serial console: 115200 8N1 on the UART/JTAG USB-C port. HDMI shows the Apple, not Linux."
