# Building A2ZYNQ

There are two things to build: the **bitstream** (the FPGA design, Vivado)
and **a2hostd** (the Linux service, an ARM cross compile). You can also
assemble the 6502 disk menu and run the test benches. Everything here is from
a Linux PC; I use Ubuntu.

## What you need

| Tool | Version I use | For |
|------|---------------|-----|
| [Vivado](https://www.xilinx.com/support/download.html) | **2024.2** (the free Standard edition covers the XC7Z020) | the bitstream, and the `xsim` simulator for the tests |
| Xillinux kit for the Smart Zynq SP | `xillinux-eval-SmartZynq-SP-1.0b` | the Zynq PS setup the build starts from, see [third_party/README.md](../third_party/README.md) |
| [Arm GNU Toolchain](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads) | 13.3.rel1, x86_64 host, `arm-none-linux-gnueabihf` | a2hostd |
| Python 3 | 3.10+ | device tree, menu assembler, tools |
| `dtc` (device-tree-compiler) | any | the device tree (Vivado ships one too) |
| [cc65](https://cc65.github.io) | 2.19+ | only for the Apple-side card test |
| [py65](https://github.com/mnaberez/py65) | any | only for the menu emulator test |

Other versions of Vivado may work, but 2024.2 is the one the build scripts
are tuned for (see [Vivado quirks](#vivado-20242-quirks) below). A full build
peaks at about 3-4 GB of RAM.

## 1. The bitstream

### Get the Xillinux kit

Download the Smart Zynq SP demo bundle from Xillybus and unzip it into
`third_party/`, so that `third_party/xillinux-eval-SmartZynq-SP-1.0b/verilog/xillydemo-vivado.tcl`
exists. Or keep it anywhere and set `A2ZYNQ_XILLINUX` to its folder.
[third_party/README.md](../third_party/README.md) has the details.

### Full build

From the repository root:

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
vivado -mode batch -source boards/a2n20v2-SmartZynq/vivado/build.tcl
```

It takes 30-40 minutes on my machine. What it does:

1. Restores the kit's original block design (saving a `.pristine` copy the
   first time), deletes any old project, and runs the kit's own
   `xillydemo-vivado.tcl` to create the stock Xillinux project.
2. Adds the Smart Zynq wrapper (`boards/a2n20v2-SmartZynq/rtl/`), the A2FPGA
   core (`hdl/`) and the board top level (`boards/a2n20v2-SmartZynq/hdl/`),
   using the file list in `vivado/sources.tcl`.
3. Adds the constraints: pins and Apple bus I/O rules
   (`smart_zynq_sp_a2_vectors.xdc`), SPI/AXI timing, synthesis stability.
4. Patches the block design (`vivado/scripts/patch_exact_xillinux_bd.tcl`):
   the Xillybus demo comes out, the A2 application goes in, connected to
   `M_AXI_GP0` (SPI transport at `0x43C40000`) and `S_AXI_HP2` (Apple memory
   in DDR at `0x1E000000`).
5. Runs synthesis and implementation and writes the bitstream.

When it finishes you'll see `A2ZYNQ_BUILD_OK` and these files in
`boards/a2n20v2-SmartZynq/build/`:

| File | |
|------|--|
| `xillydemo.bit` | the bitstream (the name is what the Xillinux boot loader looks for) |
| `timing_summary.rpt` | timing; check it (below) |
| `utilization.rpt` | how much of the XC7Z020 is used |
| `drc.rpt` | design rule checks |

The Vivado project itself is inside the kit at `verilog/vivado/xillydemo.xpr`
if you want to open it in the GUI.

### Check timing

```bash
grep -A3 "Design Timing Summary" boards/a2n20v2-SmartZynq/build/timing_summary.rpt
```

WNS (worst negative slack) and WHS (worst hold slack) must both be positive.
My last builds have been around +0.07 to +0.2 ns. If a change makes it
negative, don't load it on the Apple; timing failures in this design show up
as random bus errors that are very hard to tell apart from wiring problems.

### Quicker rebuilds

After the first full build, if you only changed HDL in existing files:

```bash
vivado -mode batch -source boards/a2n20v2-SmartZynq/vivado/rebuild.tcl
```

It reopens the project and reruns synthesis and implementation (about 20-25
minutes). Use the full build after adding or removing files.

### Build options

| Environment variable | Default | |
|----------------------|---------|--|
| `A2ZYNQ_XILLINUX` | `third_party/xillinux-eval-SmartZynq-SP-1.0b` | where the kit is |
| `A2_VIVADO_THREADS` | `2` | Vivado threads (don't use 1, see below) |
| `A2_IMPL_JOBS` | `4` | parallel implementation jobs |

### The build date

The date on the HDMI status line (and in register `0x3F`) comes from
`boards/a2n20v2-SmartZynq/hdl/datetime.svh`. I update it by hand before each
build I intend to keep, so I can tell bitstreams apart on the screen:

```bash
echo "\`define BUILD_DATETIME \"$(date +%Y%m%d%H%M%S)\"" > boards/a2n20v2-SmartZynq/hdl/datetime.svh
```

### Vivado 2024.2 quirks

The build script already handles these, but if you build some other way:

- **Synthesis crashes** (a segfault in the mux restructuring pass) on this
  design. `vivado/scripts/synth_pre.tcl` turns that pass off
  (`earlyMuxRestructuring false`) inside the synthesis process.
- **One thread deadlocks.** Keep `general.maxThreads` at 2 or more.
- **FSM extraction off.** An early run crashed inside FSM inference, and
  the design doesn't need it.
- **Global synthesis for the block design** (`synth_checkpoint_mode None`).
  The Apple bus tri-states only merge into the pad IOBUFs when the
  application is synthesized in the same netlist as the top-level ports.
- **Post-route physical optimization on.** The SPI master's 100 MHz logic
  runs close to its limit and placement shifts a little with every change;
  one build missed by 0.04 ns without it. `build.tcl` and `rebuild.tcl` turn
  it on, and move the Xillinux kit's timing check (`showstopper.tcl`, which
  the kit hooks onto routing) to after that step, so the check still stops a
  bitstream that really fails timing.
- The SPI transport is a module reference in the block design; if you change
  `rtl/axi_spi_master.sv`, `rebuild.tcl` refreshes it, and a full build
  always does.

## 2. a2hostd

```bash
export A2ZYNQ_TOOLCHAIN=$HOME/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin
boards/a2n20v2-SmartZynq/tools/build_a2hostd.sh
```

This builds a **static** ARM binary (so it runs on Xillinux's old Ubuntu
16.04 libraries without caring about them), strips it, and puts it at
`boards/a2n20v2-SmartZynq/build/a2hostd`. It builds in a temporary copy, so
the source tree stays clean. It's plain C++14 with no dependencies beyond
the C++ standard library and pthreads.

If you'd rather build it by hand:

```bash
cd boards/a2n20v2-SmartZynq/src/a2hostd
make CXX=arm-none-linux-gnueabihf-g++ CC=arm-none-linux-gnueabihf-gcc \
     CXXFLAGS="-std=c++14 -O2 -Wall -Wextra -pthread -static"
```

There's also a `CMakeLists.txt` for a native build on a PC, which is handy
for checking that it compiles (it only runs on the board, where the UIO
device is).

## 3. The disk menu (6502)

The menu that runs on the Apple is `hdl/disk/diskmenu.a65`, assembled by a
small assembler in the same folder (`asm65.py`, no other tools needed). After
changing it:

```bash
python3 boards/a2n20v2-SmartZynq/tools/update_menu_code.py
boards/a2n20v2-SmartZynq/tools/build_a2hostd.sh
```

That reassembles `diskmenu.hex`/`diskmenu.bin` and regenerates
`src/a2hostd/include/disk_menu_code.h`. `a2hostd` uploads the code into the
card's RAM when it starts, so a menu change only needs a new `a2hostd`, not a
new bitstream. (The bitstream has its own power-on copy, which the next FPGA
build picks up.) The menu code has 512 bytes; it currently uses 339.

Test it without an Apple on the 6502 emulator:

```bash
python3 -m venv .venv && .venv/bin/pip install py65
.venv/bin/python tests/menu6502/menu_sim.py
```

The hard disk card's firmware (`hdl/disk/hdd_rom.a65`) is assembled with
[ACME](https://sourceforge.net/projects/acme-crossass/) (also on GitHub as
`meonwax/acme`; `make` in its `src/` folder builds it). The assembled
`hdd_rom.hex` is in the repo, so you only need ACME if you change it:

```bash
python3 boards/a2n20v2-SmartZynq/tools/update_hdd_rom.py /path/to/acme
.venv/bin/python tests/menu6502/hdd_rom_sim.py
```

Unlike the menu, this ROM is part of the bitstream: rebuild it afterwards.

## 4. The device tree

```bash
python3 boards/a2n20v2-SmartZynq/tools/merge_dtb.py
```

Takes the kit's stock `bootfiles/devicetree.dtb`, adds the UIO node for the
SPI transport and the reserved DDR window, disables the Xillybus demo nodes,
and writes `boards/a2n20v2-SmartZynq/build/devicetree.dtb`. The SD card
script runs it for you.

## 5. Tests

See [tests/README.md](../tests/README.md). The quick version:

```bash
cd tests/bus_timing
./run.sh drvwr && ./run.sh hdd && ./run.sh sscnet && ./run.sh menu && ./run.sh disk && ./run.sh u2
```

Each ends with a `RESULT_...` line; `errors=0` means it passed, and any
failure is printed above it with a `FAIL` line. They need Vivado's `xsim`
(the script sources `/tools/Xilinx/Vivado/2024.2/settings64.sh`).

## Next

Put it on an SD card: [INSTALLING.md](INSTALLING.md).
