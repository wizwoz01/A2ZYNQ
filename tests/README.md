# Tests

Three kinds of tests, from "no hardware at all" to "on the real Apple":

| Folder | Runs on | What it checks |
|--------|---------|----------------|
| [bus_timing/](bus_timing/) | your PC, Vivado `xsim` | the HDL: bus capture and drive timing, Disk II, hard disk, menu RAM, Uthernet, SSC bridge, HDMI notice line |
| [menu6502/](menu6502/) | your PC, Python + py65 | the 6502 disk menu and the hard disk firmware, against a fake `a2hostd` / card |
| [cardtest/](cardtest/) | the Apple II | every virtual card in slots 2-7, from the 6502's side, including real disk writes |

Every bug in [lessons-learned](../boards/a2n20v2-SmartZynq/docs/lessons-learned.md)
has a test here that fails on the old code.

## bus_timing: HDL simulations

Each mode builds a small testbench around the real HDL from `hdl/` and
`boards/a2n20v2-SmartZynq/rtl/` and runs it in `xsim`. The script sources
`/tools/Xilinx/Vivado/2024.2/settings64.sh`; edit that line if Vivado lives
somewhere else. Work files go in `bus_timing/work/` (ignored by git).

```bash
cd tests/bus_timing
./run.sh drvwr
```

| Mode | Testbench | What it checks |
|------|-----------|----------------|
| `drvwr` | `tb_drvwr.sv` | the Disk II write head stores exactly one nibble per `$C0nC` access (the old code moved the head 16 for 8 writes) |
| `hdd` | `tb_hdd.sv` | the ProDOS hard disk card moves blocks through the host sector buffer (SPI space 7), both directions |
| `sscnet` | `tb_sscnet.sv` | Super Serial Card 6551 to network bridge, both directions, at two baud rates |
| `menu` | `tb_menu.sv` | the Disk II `$C800` menu RAM, the slot probes, drive swaps and write-back flushes |
| `disk` | `tb_disk.sv` | the Disk II boot ROM's read loop against a real GCR track (built from `mktrack.c` + `gcr_dsk.c`) |
| `u2` | `tb_u2.sv` | Uthernet II W5100 indirect data reads never return the next byte (the DHCP bug) |
| `osd` | `tb_osd.sv` | the HDMI notice line under the Apple picture |
| `bus` | `tb_bus.sv` | random bus cycles against a ROM card: address capture, data timing |
| `phy` | `tb_phy.sv` | `a2_bus_phy` drive start/stop, soft landing and early release options |
| `loop` | `tb_loop.sv` | the IIe `LDA $C505` test loop, cycle by cycle, with the drive timing |

Every testbench ends with a `RESULT_...` line; `errors=0` means it passed.
Failures are printed above it as `FAIL ...` lines.

Testbench parameters can be set from the command line, for example
`./run.sh u2 EARLY_DEF=1 FINE=3` or `./run.sh disk ADDR_N=14 DATA_N=11 WRITE_N=2`.
The names are the `parameter`s at the top of each testbench.

To run everything I usually check before a build:

```bash
for m in drvwr hdd sscnet menu disk u2 osd; do ./run.sh $m 2>&1 | grep RESULT; done
```

`a2sweep.py` is different: it runs **on the board** and sweeps bus timing
registers through `a2hostd`'s debug command file while the Apple runs a test
loop. I used it during the level-translator hunt; the register notes in its
header are from those builds, so check them against
[spi-host-interface.md](../boards/a2n20v2-SmartZynq/docs/spi-host-interface.md)
before relying on them.

## menu6502: the disk menu and hard disk firmware on an emulator

Runs the real menu binary (`hdl/disk/diskmenu.bin`) on the
[py65](https://github.com/mnaberez/py65) 6502 emulator, with a fake host on
the mailbox. It enters the menu the way the Disk II boot ROM does (`JSR $C800`
from `$C624`) and checks each way out: boot, ESC to BASIC, moving to another
slot, and the slot 1 power-up that goes straight to BASIC.

`hdd_rom_sim.py` does the same for the hard disk card's firmware
(`hdl/disk/hdd_rom.hex`) at `$C600`, with a fake card that keeps a few blocks:
the power-up scan must skip it while ProDOS still sees a block device; booting
it puts block 0 at `$0800` with X = `$60`; no disk, a read error or button 0
held go back to the IIe's own boot scan (`$FABA` from slot 7, never a fixed
slot); and the ProDOS driver's READ, WRITE and STATUS work.

```bash
python3 -m venv .venv && .venv/bin/pip install py65
.venv/bin/python tests/menu6502/menu_sim.py              # or pass another diskmenu.bin
.venv/bin/python tests/menu6502/hdd_rom_sim.py           # or pass another hdd_rom.hex
```

## cardtest: the Apple-side test

`CARDTEST.SYSTEM` is a ProDOS program (C + a little assembly, built with
[cc65](https://cc65.github.io) for the plain 6502) that tests every virtual
card from the Apple:

- finds the Disk II and hard disk by their ROMs (they move with the card),
- checks the registers of the SSC, Uthernet II, Mockingboard and SuperSprite,
- plays a tone on each sound chip and shows a green box on the SuperSprite,
- writes an 8 KB file on its own boot disk and reads it back,
- writes and reads back a block on the hard disk volume `/HDTEST`,
- prints `n FAILED` at the end and saves everything it printed to
  `CARDTEST.LOG` on the boot disk.

It takes about 15 seconds. All I/O goes through absolute `STA`/`LDA` helpers
in `io.s`, so 6502 dummy reads can't confuse the cards.

### Building it

You need cc65 and a 140K ProDOS disk whose ProDOS runs on a 6502 (ProDOS 8
2.4.x works); the script reuses its ProDOS and boot blocks.

```bash
tests/cardtest/build.sh /path/to/prodos_base.dsk
```

That makes, in `tests/cardtest/build/`:

| File | |
|------|--|
| `CardTest.dsk` | 140K floppy that boots straight into the test |
| `hdd1.po` | 2 MB hard disk, volume `/HDTEST`. Named so `a2hostd` mounts it as hard disk 1 by itself; rename it to `hdd2.po` to keep something else on drive 1 |

Copy both to `/media/a2` on the board, boot `CardTest.dsk` from the menu, and
look for `0 FAILED`. Afterwards you can copy `CardTest.dsk` back over FTP and
read the log on the PC, or check the disk with
`python3 tools/prodos_disk.py CardTest.dsk check`.

`mkdisks.py` and `prodos_disk.py` are the small Python tools the build uses
to put the program on the disks.
