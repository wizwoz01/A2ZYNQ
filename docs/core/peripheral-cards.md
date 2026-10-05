# Peripheral Card Emulation

The catalog of virtual Apple II cards the core provides — what each emulates, the upstream cores it
reuses, and where the HDL lives. How cards attach to the bus and how to add one is in
[bus-interface.md](bus-interface.md); the sound mixing is in [audio.md](audio.md). This page is the
per-card reference.

Each card is a slave on [`a2bus_if`](../../hdl/bus/a2bus_if.sv) + [`slot_if`](../../hdl/slots/slot_if.sv)
with an 8-bit card **ID**, assigned to a slot by [`slots.hex`](../../hdl/slots/slots.hex) (and
reconfigurable at runtime by the coprocessor). Default assignment:

| Card | ID | Default slot | Emulates |
|---|---|---|---|
| SuperSprite | 1 | 7 | Synetix SuperSprite (TMS9918A VDP + AY-3-8910) |
| Mockingboard | 2 | 4 | Sweet Micro Systems Mockingboard (2× AY-3-8910 + 2× 6522) |
| Super Serial Card | 3 | 2 | Apple Super Serial Card (6551 ACIA) |
| Disk II | 4 | 5 | Apple Disk II controller (RAMDISK) — **not currently built, see below** |
| Uthernet II | 5 | 3 | a2RetroSystems Uthernet II (WIZnet W5100) — a2n20v2-Enhanced only; FPGA front-end + BL616 MACRAW bridge, see [boards/a2n20v2-Enhanced/docs/UTHERNET2.md](https://github.com/a2fpga/a2fpga_core/blob/main/boards/a2n20v2-Enhanced/docs/UTHERNET2.md) |

## SuperSprite — [`supersprite.sv`](../../hdl/supersprite/supersprite.sv)

Emulates the Synetix SuperSprite: a **TMS9918A VDP** plus an **AY-3-8910** PSG (the original's
TMS5220 speech synth is not implemented). The VDP is the **F18A** core ([`hdl/f18a/`](../../hdl/f18a),
`f18a.sv` + the VHDL core), a TMS9918A-compatible implementation. The PSG is the shared
[`YM2149`](../../hdl/support/YM2149.sv) core; its three channels sum to a 10-bit mono output that feeds
the [audio mix](audio.md).

The card composites its VDP output **over** the Apple video: it takes the Apple RGB in and emits
`ssp_r/g/b` with the sprite/VDP layer overlaid (transparency or external-video mode), which then
goes to HDMI. The [`f18a_gpu_if`](../../hdl/f18a/f18a_gpu_if.sv) (the F18A's on-VDP GPU) is wired but
held idle — present for future use, not driven today.

## Mockingboard — [`mockingboard.sv`](../../hdl/mockingboard/mockingboard.sv)

Emulates the Mockingboard: **two AY-3-8910 PSGs** (two [`YM2149`](../../hdl/support/YM2149.sv)
instances), each driven by a **6522 VIA** ([`via6522.vhd`](../../hdl/support/via6522.vhd)). The left
VIA/PSG and right VIA/PSG are split by `addr[7]`, giving stereo (`audio_l_o`/`audio_r_o`, 10-bit
each → the [audio mix](audio.md)). `irq_n_o` is asserted when either VIA raises an interrupt. The
Votrax SC-01 speech chip is not implemented.

## Super Serial Card — [`super_serial_card.sv`](../../hdl/ssc/super_serial_card.sv)

Emulates the Apple Super Serial Card: a **6551 ACIA** ([`uart_6551.v`](../../hdl/support/uart_6551.v))
plus the card's **2 KB firmware ROM** ([`ssc_rom.vhd`](../../hdl/ssc/ssc_rom.vhd)). The UART occupies
the slot's device register space; the ROM maps into the card's I/O/C8 ROM space when `INTCXROM` is
inactive (it reads `a2mem_if` for that). The UART's TX/RX connect to the board's host serial line
(over USB), giving **ADTPro**-compatible serial — including bootstrapping from it.

**Smart-Zynq:** the board's USB UART carries the Linux console, so the serial line goes to the
network instead: [`ssc_net_bridge.sv`](../../hdl/ssc/ssc_net_bridge.sv) is the far end of the cable
(the core's own `uart_rx`/`uart_tx` at the baud in the 6551 control register, 512-byte FIFOs each
way), and `a2hostd` relays it to TCP port 6551 (settings `ssc_port`, `ssc_cr_delay_ms`). Host
access is all in SPI memory SPACE 5 (the HDMI notice line uses only writes below 0x40): a read
below 0x100 is the status byte {room for 256 more, bytes waiting 0-127}, reads at 0x100+ pop
received bytes, writes at 0x100+ queue bytes; reg `0x06` bit 4 = present. Register 0x7F must
never be used: it is the protocol's XFER opcode, so a "read" of it starts a transfer.
`tests/bus_timing ./run.sh sscnet` checks both directions at two bauds.

## Disk II — [`apple_disk.sv`](../../hdl/disk/apple_disk.sv) (built on A2ZYNQ)

A Disk II controller emulation that serves disk images from a **RAMDISK** in SDRAM, with the disk
images supplied by the coprocessor over [`drive_volume_if`](../../hdl/disk/drive_volume_if.sv) (block
I/O for two drives). 

**Upstream status:** not instantiated on the upstream boards. It was wired through the on-FPGA PicoSoC
RAMDISK path, which has been removed; the BL616 path currently stubs the disk signals
(`// no DiskII controller yet with BL616`). The `hdl/disk/` modules remain as the basis for
re-enabling Disk II on the BL616/ESP32 coprocessor path — see the
[coprocessor interface](coprocessor-interface.md) (`drive_volume_if`) and the board TODOs.

**On A2ZYNQ (Smart Zynq):** Disk II is built (track-on-demand from `a2hostd`) and has a **boot menu**.
The boot ROM (`diskii.hex`) calls `diskmenu.a65` in the card's 2 KB `$C800` RAM from `$Cn21`
(`BIT $CFFF` / `JSR $C800`; the stock seek/boot code from `$Cn2F` and the `$Cn5C` sector reader
are unchanged). `a2hostd` (`boards/a2n20v2-SmartZynq/src/a2hostd/src/disk_menu.cpp`) reaches that RAM over SPI memory
space 4, lists the 5.25" images under `/media/a2`, draws the screen, and mounts the pick before
telling the Apple to boot. Without `a2hostd` the menu code returns at once (stock behaviour).
ESC leaves without booting (`CMD=3`): the menu makes the power-up byte valid again and goes where
Ctrl-Reset would, which after power-up is the BASIC prompt; `PR#n` brings the menu back.
Settings: `disk_menu=0` turns it off, `disk_menu_timeout=N` boots drive 1 after N seconds
without a key; the last picks are kept as `disk1_image` / `disk2_image`. A disk swap clears the
drive's `mounted` bit first, so `drive_ii` writes back a dirty track and drops its cached one;
written tracks are also flushed as soon as the drive stops. A save reads the drive's own copy of
the track (`nib_mem`) over SPI memory SPACE 6 (drive*0x2000 + byte; reg `0x2E` bit 7 = present):
the SDRAM window never held the loaded track, so every save from it failed to decode. In write
mode the head stores one nibble per `$C0nC` access, noted during PHI0 and stored at the cycle's
end (storing on every Q3 tick wrote each nibble twice on the red card: `tests/bus_timing`
`./run.sh drvwr`). On A2ZYNQ the hard disk is booted only from the menu (hard disk images are
listed with `HD`; RETURN mounts one as unit 1 and sends `CMD=2` with `TARGET` = the hard disk
card's `$Cn00`) or by `PR#n`: `hdd_rom.a65` carries the ProDOS signature but not the autostart
`$3C` at `$Cn07`, so the IIe's power-up scan passes over it, and with no disk it resumes that scan
(`JMP $FABA`) instead of assuming the Disk II is in slot 5. The ProDOS hard disk card (`hdd.sv`, `HOST_BUF`) likewise moves blocks
straight between a2hostd and its 512-byte sector buffer over SPACE 7 (reg `0x06` bit 2 =
present) instead of its SDRAM window (`./run.sh hdd`). `tests/cardtest` (CardTest.dsk) checks
slots 2-7 on the real Apple, including an 8 KB file write on the boot disk. The Disk II **follows the slot the
card is plugged into** (4-7): `hdl/slots/phys_slot_detect.sv` watches the card's own /IOSEL and
/DEVSEL (FPGA pins AA14 / V14) and reports the slot in reg `0x2E` [6:4]; the menu probes
`$Cn00/$Cn01` of slots 4-7 and `$C0n0` (twice) of slots 1-3 so a slot the boot scan skipped is
still seen (no `$Cnxx` reads for 1-3: a card there, the SSC, or the IIe 80-column firmware would
take `$C800` from the running menu). When a menu hello comes
from another slot, `a2hostd` holds `/RES`, swaps the Disk II with that slot's card (slot 6 → the
HDD moves to 5), and releases; the menu spoiled the power-up byte so this is a cold start. If the
reset does not take, `CMD=2` makes the menu `JMP ($CE05)` to the new slot's `$Cn00` itself. The
detected slot is kept as `card_slot`; `disk_slot=4..7` pins the drive instead. With the card in
slots 1-3 the Disk II uses slot 6 (a IIe never boots slot 3: its 80-column firmware owns `$C3xx`
after reset) and the menu title names the card's slot without DISK: `SLOT 3 MENU` (with the card
in 4-7 it is `SLOT n DISK MENU`). With the card in slot 1 a power-up boots nothing: the menu still
probes and says hello with `COLD=1` (`$CE0C`: the reset vector is still the monitor's `$E000`, so
the boot scan brought it there), `a2hostd` answers `CMD=4` before the ack, and the 6502 code does
what the boot scan does when it finds no disk (power-up byte valid, reset vector to `$E003`,
`JMP $E000`) before touching the screen, video switches or keyboard: the IIe shows its own
"Apple ][" and the BASIC prompt. `PR#6` then enters with `COLD=0` and gets the menu
(`SLOT 1 MENU`). Moving the card out of slot 1 brings the menu back at the next boot.
**Mid-game disk swaps** (multi-disk games): the board's KEY1 (next) / KEY2 (previous) (PS EMIO
GPIO 61/62 = Linux GPIO 115/116, read by `a2hostd`) put the next disk of the set in drive 1
(I tried a keyboard hotkey and dropped it: the game sees the key too).
The set is the images in the same folder whose names differ only in a
short tail (`ultima31`/`ultima32`, `OREGON_A`/`OREGON_B`, `... Disk 1 of 3`), else every image in
the folder. The new disk is named for 4 s on a line under the Apple picture
(`hdl/video/osd_line.sv`, SPI space 5: byte 0 bit 0 = show, bytes 1-40 = text). The menu opens on
the disk booted last (`boot_image`), not on whatever a swap left in drive 1. Rebuild the image with
`python3 asm65.py diskmenu.a65 diskmenu.hex --size 2048 --bin diskmenu.bin` and regenerate
`boards/a2n20v2-SmartZynq/src/a2hostd/include/disk_menu_code.h`; `tests/bus_timing/run.sh menu` checks the card side and
`tests/menu6502/menu_sim.py` runs the menu code on a 6502 emulator (py65: probes, boot, slot move, ESC).

## CardROM — [`cardrom.sv`](https://github.com/a2fpga/a2fpga_core/blob/main/hdl/cardrom/cardrom.sv) (not a slot card)

CardROM is the A2FPGA's own **$F000–$FFFF ROM presence**, not a slotted peripheral. At power-up it
asserts the Apple **INH** line to inhibit the internal monitor ROM and hold the machine in a known
state until the FPGA is ready. Once the top level signals readiness (`req_rom_release_i` → an
internal `fpga_done` flag) **and** the Apple fetches the reset vector at **`$FFFC`**, it releases
INH and normal operation proceeds. Reads in `$F800–$FFFF` return the card ROM (from the
board-independent `cardrom.hex`); reads below that return the `fpga_done` status bit so monitor
code can poll FPGA readiness. This is the ROM-side counterpart to the a2bridge power-on-reset hold
described in [bus-interface.md](bus-interface.md).

## Reused cores

The card logic is built on established open cores (full attributions in the top-level
[README.md](../../README.md) credits):

| Core | File | Used by | Upstream |
|---|---|---|---|
| F18A (TMS9918A VDP) | [`hdl/f18a/`](../../hdl/f18a) | SuperSprite | Matthew Hagerty (dnotq), Tang port by Felipe Antoniosi |
| YM2149 (AY-3-8910 PSG) | [`hdl/support/YM2149.sv`](../../hdl/support/YM2149.sv) | SuperSprite, Mockingboard | MikeJ / Sorgelig (MiSTer) |
| 6522 VIA | [`hdl/support/via6522.vhd`](../../hdl/support/via6522.vhd) | Mockingboard | Gideon Zweijtzer |
| 6551 UART | [`hdl/support/uart_6551.v`](../../hdl/support/uart_6551.v) | Super Serial Card | Gary Becker (CoCo3_MiSTer) |

## Enabling cards & board differences

Each card has an `*_ENABLE` (and `*_ID`) parameter in `top.sv` (`SUPERSPRITE_ENABLE`,
`MOCKINGBOARD_ENABLE`, `SUPERSERIAL_ENABLE`, …). Resource-limited boards drop cards: **a2n9**
(Tang Nano 9K) omits SuperSprite (the F18A VDP doesn't fit). Mockingboard is enabled across the
board family. Slot assignment is via [`slots.hex`](../../hdl/slots/slots.hex) at build time and the
coprocessor's `slotmaker_config_if` at runtime.

> Adding a new card (the `a2bus_if`/`slot_if` slave pattern, the data/IRQ mux, registering it in
> `slots.hex`) is covered in [bus-interface.md](bus-interface.md#adding-a-new-virtual-card).

## See also

- [bus-interface.md](bus-interface.md) — how cards attach to the bus and how to add one.
- [audio.md](audio.md) — how the Mockingboard / SuperSprite / Ensoniq audio is mixed.
- [coprocessor-interface.md](coprocessor-interface.md) — disk volume I/O and runtime slot config.
- [README.md](../../README.md) — the cards as user-facing features, and the full open-core credits.
