#!/usr/bin/env python3
"""Assemble the disk menu and refresh both copies of it.

    python3 boards/a2n20v2-SmartZynq/tools/update_menu_code.py

The 6502 disk menu (hdl/disk/diskmenu.a65) lives in two places:

  - hdl/disk/diskmenu.hex / diskmenu.bin: the 2 KB $C800 RAM image the
    bitstream starts with (picked up by the next FPGA build),
  - src/a2hostd/include/disk_menu_code.h: the first 512 bytes, which a2hostd
    uploads into that RAM at start, so menu changes work without an FPGA build.

This runs asm65.py and rewrites the header from the new binary. Rebuild
a2hostd afterwards (tools/build_a2hostd.sh); rebuild the bitstream only if you
want the power-on copy to match too.
"""
import pathlib
import subprocess
import sys

BOARD = pathlib.Path(__file__).resolve().parents[1]
REPO = BOARD.parents[1]
DISK = REPO / "hdl/disk"
HEADER = BOARD / "src/a2hostd/include/disk_menu_code.h"
CODE_BYTES = 0x200

subprocess.run([sys.executable, "asm65.py", "diskmenu.a65", "diskmenu.hex",
                "--size", "2048", "--bin", "diskmenu.bin"], cwd=DISK, check=True)
code = (DISK / "diskmenu.bin").read_bytes()[:CODE_BYTES]

lines = [
    "// Generated from hdl/disk/diskmenu.a65 ($C800-$C9FF of diskmenu.bin):",
    "//   python3 asm65.py diskmenu.a65 diskmenu.hex --size 2048 --bin diskmenu.bin",
    "// Included inside a namespace by disk_menu.cpp. Keep in step with the bitstream copy.",
    "const std::uint8_t kDiskMenuCode[0x200] = {",
]
for i in range(0, CODE_BYTES, 16):
    lines.append("    " + ", ".join("0x%02X" % b for b in code[i:i + 16]) + ",")
lines.append("};")
HEADER.write_text("\n".join(lines) + "\n")
used = len(code.rstrip(b"\0"))
print("wrote %s (%d of %d code bytes used)" % (HEADER.relative_to(REPO), used, CODE_BYTES))
