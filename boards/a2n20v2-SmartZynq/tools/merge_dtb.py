#!/usr/bin/env python3
"""Build the A2ZYNQ device tree from the stock Xillinux one.

The Xillinux kit ships a devicetree.dtb for the Smart Zynq SP. This script
decompiles it and makes the changes A2ZYNQ needs:

  - boot arguments with the UIO driver bound to "generic-uio",
  - an 8 MiB reserved-memory window at 0x1E000000 for the FPGA's Apple memory,
  - a UIO node for the SPI transport at 0x43C40000 (a2hostd talks to the
    FPGA through it),
  - the Xillybus demo nodes disabled (their hardware is not in the bitstream).

device_tree/system-user.dtsi has the same changes as a PetaLinux fragment, for
reference; it can't be compiled on its own against the Xillinux tree.

Usage:  python3 boards/a2n20v2-SmartZynq/tools/merge_dtb.py
Output: boards/a2n20v2-SmartZynq/build/devicetree.dtb (+ smart_zynq_a2.dts)
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys

import os

BOARD = pathlib.Path(__file__).resolve().parents[1]
REPO = BOARD.parents[1]
KIT = pathlib.Path(
    os.environ.get("A2ZYNQ_XILLINUX")
    or REPO / "third_party/xillinux-eval-SmartZynq-SP-1.0b"
)
STOCK_DTB = KIT / "bootfiles/devicetree.dtb"
OUT_DTS = BOARD / "build/smart_zynq_a2.dts"
OUT_DTB = BOARD / "build/devicetree.dtb"

# Keep the stock 512 MiB memory node. U-Boot places the DTB near the top of
# RAM (this board: 0x1fb51000). Shrinking memory@0 below that address makes
# Linux unmap the FDT and hang at "Starting kernel ...".
# The PL 8 MiB window is excluded with reserved-memory / no-map instead.
NEW_BOOTARGS = (
    "console=ttyPS0,115200n8 consoleblank=0 "
    "root=/dev/mmcblk0p2 rw rootwait earlyprintk "
    "uio_pdrv_genirq.of_id=generic-uio"
)

RESERVED = """
	reserved-memory {
		#address-cells = <0x01>;
		#size-cells = <0x01>;
		ranges;

		a2-pl-ddr@1e000000 {
			no-map;
			reg = <0x1e000000 0x00800000>;
		};
	};
"""

UIO_NODE = """
		a2-spi-transport@43c40000 {
			compatible = "generic-uio";
			reg = <0x43c40000 0x00040000>;
			status = "okay";
		};
"""


def find_dtc() -> str:
    for candidate in (
        shutil.which("dtc"),
        "/tools/Xilinx/Vivado/2024.2/bin/dtc",
        "/usr/bin/dtc",
    ):
        if candidate and pathlib.Path(candidate).is_file():
            return candidate
    raise SystemExit("dtc not found (install device-tree-compiler or use Vivado)")


def decompile(dtc: str, dtb: pathlib.Path) -> str:
    result = subprocess.run(
        [dtc, "-I", "dtb", "-O", "dts", "-o", "-", str(dtb)],
        check=True,
        capture_output=True,
        text=True,
    )
    # dtc warnings go to stderr; ignore them.
    return result.stdout


def patch(src: str) -> str:
    src = re.sub(
        r'bootargs = "[^"]*";',
        f'bootargs = "{NEW_BOOTARGS}";',
        src,
        count=1,
    )
    if "reserved-memory" not in src:
        src = src.replace("\tamba@0 {", RESERVED + "\n\tamba@0 {", 1)
    if "a2-spi-transport@43c40000" not in src:
        src = src.replace("\t\txillyvga@50001000 {", UIO_NODE + "\n\t\txillyvga@50001000 {", 1)
    for node in ("xillyvga@50001000", "xillybus@50000000", "xillybus_lite@50002000"):
        src = re.sub(
            rf"(\t\t{re.escape(node)} \{{)",
            r'\1\n\t\t\tstatus = "disabled";',
            src,
            count=1,
        )
    return src


def compile_dtb(dtc: str, dts: pathlib.Path, dtb: pathlib.Path) -> None:
    subprocess.run(
        [dtc, "-q", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stock-dtb", type=pathlib.Path, default=STOCK_DTB)
    parser.add_argument("--out-dts", type=pathlib.Path, default=OUT_DTS)
    parser.add_argument("--out-dtb", type=pathlib.Path, default=OUT_DTB)
    args = parser.parse_args()
    if not args.stock_dtb.is_file():
        raise SystemExit(f"missing stock DTB: {args.stock_dtb} (see third_party/README.md)")
    dtc = find_dtc()
    patched = patch(decompile(dtc, args.stock_dtb))
    args.out_dts.parent.mkdir(parents=True, exist_ok=True)
    args.out_dts.write_text(patched)
    compile_dtb(dtc, args.out_dts, args.out_dtb)
    print(f"wrote {args.out_dts}")
    print(f"wrote {args.out_dtb} ({args.out_dtb.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
