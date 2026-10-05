# Storage: how disk data moves

This page is about the path a floppy track or a hard disk block takes between
the SD card and the Apple, and the three bugs I had to fix before writes
actually stuck. If you only want to use the disks, the
[board README](../README.md#disk-image-support) is enough.

## Floppies (Disk II)

The Disk II emulation (`hdl/disk/drive_ii.sv`, two drives inside
`apple_disk.sv`) keeps one whole track per drive in a block RAM (`nib_mem`,
6656 bytes of nibbles). The Apple's boot ROM and DOS read and write that RAM
through the normal `$C0nX` soft switches, at the speed of a real drive.

### Reading a track

1. The Apple steps the head. The drive's requested track shows up in the
   volume registers (`0x48`-`0x4B` for drive 1, `0x58`-`0x5B` for drive 2) with
   the read flag set.
2. `a2hostd` sees the request, reads the 16 sectors for that track from the
   image and turns them into a 6656-byte nibble track with the 6-and-2 GCR
   encoder (`src/a2hostd/src/gcr_dsk.c`, ported from AppleWin). `.nib`
   images are already nibbles and go as they are.
3. It writes the track over SPI into memory space 1 at
   `0x200000 + drive*0x2000`. On the way past, `bl616_spi_connector` copies the
   bytes straight into the drive's `nib_mem` (reading them back out of DDR
   used to return empty words, and the boot ROM spun on track 0 forever).
4. `a2hostd` acks, the drive marks the track resident, and the Apple's reads
   start returning real nibbles.

### Writing a track

1. In write mode (`$C0nF` then `$C0nD`/`$C0nC`), each write the Apple's RWTS
   does through `$C0nC` stores one nibble at the head position and moves the
   head on. The drive marks the track dirty.
2. When the drive stops, or the head moves to another track, or you swap the
   disk, the dirty track has to go back to the image. The drive raises the
   write flag for that track.
3. `a2hostd` reads the track back over **memory space 6**, which is a read
   port straight into the drive's `nib_mem` (`drive*0x2000 + byte`).
4. It decodes the nibbles back into 16 sectors (finding the address and data
   fields, checking the checksums) and writes only the sectors that decoded
   into the image file.
5. It logs what it did: how many bytes changed, in how many ranges, and which
   sectors decoded (`journalctl -u a2hostd | grep save`). For debugging it
   also keeps `/tmp/a2_wb_d<drive>_t<track>.nib` (what came back) and
   `_served.nib` (what it originally sent).

### Bug 1: saves read the wrong copy

Upstream, the host reads a written track back from the SDRAM window. On this
port that window never held the loaded track (step 3 of reading writes it
straight into `nib_mem`), so every save decoded garbage and failed with
status 8. The Apple never sees an error from this: DOS thinks the write worked
and the data is just gone.

Fix: memory space 6 reads the drive's own copy. Register `0x2E` bit 7 tells
`a2hostd` the bitstream has it; on an older bitstream it logs a warning that
saves won't work.

### Bug 2: every nibble written twice

With bug 1 fixed, saves "succeeded" but the image didn't change. The dumps
showed why: `D5 D5 AA AA AD AD` where `D5 AA AD` should be. The write head
stored each nibble twice.

The cause is bus timing on the proto card. The FPGA sees the `$C0nC` select
already at the start of PHI0, and the original head logic stored on every Q3
tick while the select was active. That's two Q3 ticks per access, so two
stores and two head moves per nibble. On the original A2N20v2 card's timing it
apparently only hit once.

Fix: the drive notes the access during PHI0 (`q6l_seen_r`) and stores once,
at the end of the cycle (`phi1_posedge`). The data register still latches on
Q3 as before. `tests/bus_timing/run.sh drvwr` reproduces the old bug (the head
moves 16 positions for 8 writes) and checks the fix (8 for 8).

The general rule I took from this: **act on a bus access once, at the end of
the cycle.** See [lessons-learned.md](lessons-learned.md).

## Hard disks (ProDOS block device)

The hard disk controller (`hdl/disk/hdd.sv`, firmware `hdl/disk/hdd_rom.a65`)
is a ProDOS block device: the Apple asks for block N of unit 1 or 2, and the
card has a 512-byte sector buffer the 6502 reads or fills one byte at a time.

### Bug 3: stale reads

Upstream, the host writes the block into the SDRAM window, acks, and the card
copies it from SDRAM into its sector buffer. On this port the ack could reach
the card before the block had finished draining into DDR, so the card copied
part old data. The card test caught it: the volume `/HDTEST` read back as
`/HDT`, with the wrong block count.

Fix: `hdd.sv` got a `HOST_BUF` option (on in this build) that gives the host
direct access to the sector buffer as **memory space 7**. Now:

- **Read:** the card raises a read request with the block number (registers
  `0x26`-`0x28` / `0x2A`-`0x2C`). `a2hostd` reads 512 bytes from the image,
  writes them into space 7, and acks. The card answers the 6502 straight from
  the buffer.
- **Write:** the 6502 fills the buffer and the card raises a write request.
  `a2hostd` reads the 512 bytes from space 7, writes them into the image, and
  acks.

Register `0x06` bit 2 tells `a2hostd` the bitstream has the host buffer.
`tests/bus_timing/run.sh hdd` checks both directions.

## Checking it all on a real Apple

[tests/cardtest](../../../tests/cardtest) builds `CardTest.dsk`, a ProDOS
program that, among the other card tests, writes an 8 KB file to its own boot
disk and reads it back, writes and reads a block on the hard disk, and saves
its log as `CARDTEST.LOG`. If it ends with `0 FAILED`, the floppy and hard
disk write paths are good. On the board you can then copy the disk image off
over FTP and check that `CARDTEST.LOG` really is in it, or run
`tools/prodos_disk.py CardTest.dsk check` to verify the ProDOS bitmap.

## Why not just use DDR?

The core's memory system works fine for video and the Apple's own memory
shadows. For storage it was the wrong place: the data has to make a round
trip through a clock-domain crossing and an AXI port, and the protocol had no
way to know when it had landed. Both fixes do the same thing: put the host
directly on the RAM the card actually uses, and take DDR out of the storage
path.
