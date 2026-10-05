#!/usr/bin/env python3
"""Assemble the hard disk card's firmware and refresh the hex the bitstream loads.

    python3 boards/a2n20v2-SmartZynq/tools/update_hdd_rom.py [path/to/acme]

hdl/disk/hdd_rom.a65 is written for the ACME assembler
(https://sourceforge.net/projects/acme-crossass/, also on GitHub as
meonwax/acme; `make` in its src/ folder builds it). This runs it and writes
hdl/disk/hdd_rom.hex (256 bytes, 16 per line) for the ROM in hdd.sv. The ROM
is part of the bitstream, so rebuild that afterwards. Test the result first
with tests/menu6502/hdd_rom_sim.py.
"""
import os
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[3]
DISK = REPO / "hdl/disk"
acme = sys.argv[1] if len(sys.argv) > 1 else (os.environ.get("ACME") or shutil.which("acme"))
if not acme:
    sys.exit("ACME not found: put it on the PATH, set ACME=/path/to/acme, or pass its path")

subprocess.run([acme, "hdd_rom.a65"], cwd=DISK, check=True)
binfile = DISK / "hdd_rom.bin"
rom = binfile.read_bytes()
binfile.unlink()
if len(rom) != 256:
    sys.exit("hdd_rom.bin is %d bytes, expected 256" % len(rom))
(DISK / "hdd_rom.hex").write_text(
    "".join(" ".join("%02X" % b for b in rom[i:i + 16]) + "\n" for i in range(0, 256, 16)))
print("wrote hdl/disk/hdd_rom.hex ($Cn01/03/05/07 = %02X %02X %02X %02X, $CnFF = %02X)"
      % (rom[1], rom[3], rom[5], rom[7], rom[255]))
