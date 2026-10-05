#!/usr/bin/env bash
# Build the card test and its two disk images.
#
#   tests/cardtest/build.sh BASE.dsk [OUTDIR]
#
# BASE.dsk is any 140K ProDOS disk whose ProDOS runs on a plain 6502 IIe
# (ProDOS 8 2.4.x, for example); its ProDOS and boot blocks are reused. Needs
# cc65 (cl65) on the PATH.
#
# Output in OUTDIR (default tests/cardtest/build):
#   CardTest.dsk  140K floppy, boots straight into CARDTEST.SYSTEM
#   hdd1.po       2 MB hard disk, volume /HDTEST (mounted as hard disk 1 by name)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${1:?usage: build.sh BASE.dsk [OUTDIR]}"
OUT="${2:-$HERE/build}"
mkdir -p "$OUT"
cd "$HERE"
cl65 -t apple2 -O -C apple2-system.cfg apple2-iobuf-0800.o -D __APPLE2_SYS__ \
     -o "$OUT/cardtest.sys" -m "$OUT/cardtest.map" cardtest.c io.s
rm -f ./*.o
python3 mkdisks.py "$BASE" "$OUT/cardtest.sys" "$OUT"
ls -l "$OUT"
