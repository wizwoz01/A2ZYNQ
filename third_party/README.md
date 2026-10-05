# third_party

This folder is empty on purpose. The bitstream build needs one thing I can't
put in the repo: the **Xillinux evaluation kit for the Smart Zynq SP**. It
belongs to Xillybus and comes with its own license, so you download it
yourself and drop it here.

## What to download

From the Xillinux page on [xillybus.com](https://xillybus.com/xillinux):

| File | What it is | Where it goes |
|------|------------|---------------|
| `xillinux-eval-SmartZynq-SP-1.0b.zip` | The Smart Zynq SP demo bundle: Vivado block design (Zynq PS setup, DDR, clocks, Ethernet), boot files (`boot.bin`, `devicetree.dtb`) and the stock demo | unzip it here, so you end up with `third_party/xillinux-eval-SmartZynq-SP-1.0b/` |
| `xillinux-2.0a.img.gz` | The Xillinux 2.0 SD card image (Ubuntu 16.04 for Zynq) | anywhere; only the SD card script needs it |

Make sure it's the **SP** bundle (not SP2, Zedboard, etc.). The pin
constraints and the DDR settings are different on every board, and the build
checks for the SP files.

When you're done the folder should look like this:

```
third_party/
  README.md                          <- this file
  xillinux-eval-SmartZynq-SP-1.0b/
    bootfiles/        boot.bin, devicetree.dtb, xillydemo.bit
    cores/
    verilog/          xillydemo-vivado.tcl, src/
    vivado-essentials/vivado_system/vivado_system.bd
    README.txt
```

## Keeping the kit somewhere else

If you'd rather keep one copy of the kit outside the repo, point the build at
it:

```bash
export A2ZYNQ_XILLINUX=/path/to/xillinux-eval-SmartZynq-SP-1.0b
```

## What the build does to the kit

The build script uses the kit's own `verilog/xillydemo-vivado.tcl` to create
the stock Xillinux project, then swaps the A2 application into the block
design in place of the Xillybus demo. Two things to know:

- The Vivado project is created inside the kit at `verilog/vivado/` and is
  deleted and recreated on every full build.
- The first build saves the kit's original block design as
  `vivado_system.bd.pristine` next to it, and every build after that starts
  from the pristine copy. If you ever want the kit back exactly as you
  downloaded it, copy `vivado_system.bd.pristine` over `vivado_system.bd` (or
  just unzip the kit again).

Everything in here is ignored by git (see `.gitignore`), so the kit never ends
up in a commit by accident.
