# SPI host interface

How `a2hostd` on the Zynq's ARM side talks to the A2FPGA core in the PL.

The short version: it's the same SPI protocol the BL616 microcontroller uses
on the a2n20v2-Enhanced card, so the core's `bl616_spi_connector` works almost
unchanged. The difference is that the SPI master is now a small piece of logic
in the PL (`rtl/axi_spi_master.sv`) that Linux drives over AXI, instead of a
separate chip on the other end of four wires.

```
 a2hostd (Linux, user space)
    |  mmap /dev/uioN  (UIO, generic-uio driver)
    v
 axi_spi_master  @ 0x43C40000   (AXI4-Lite on M_AXI_GP0)
    |  CS#, SCLK, MOSI, MISO  (inside the FPGA)
    v
 bl616_spi_connector  (hdl/bl616)  ->  128 registers + 8 memory spaces
```

## The AXI side: axi_spi_master

`a2hostd` maps the UIO region (256 KB at `0x43C40000`, declared in the device
tree by `tools/merge_dtb.py`) and talks to these registers:

| Offset | Register | Use |
|--------|----------|-----|
| `0x00` | CTRL | start a transfer, busy flag |
| `0x04` | LEN | bytes in this transfer (up to 8 KB) |
| `0x08` | DIV | SCLK divider (`a2hostd` sets 16) |
| `0x0C` | HOST_READY | bit 0: Linux is up and serving. Until this is set the bus PHY keeps the Apple side quiet |
| `0x10000` | TX buffer | bytes to send |
| `0x20000` | RX buffer | bytes received, same positions |

A transfer is one CS# frame: `a2hostd` fills the TX buffer, writes LEN and
CTRL, waits for busy to clear, and reads the RX buffer. The SPI mode is 1
(CPOL=0, CPHA=1), the same as the BL616.

One detail cost me a broken build: CS# is released on the trailing edge of the
last data bit, and the slave has to finish that last byte even though CS# has
already gone high. An earlier version raced on it and lost bit 0 of every
register write. If you touch this, check it by writing odd values to register
`0x07` and reading them back.

## The protocol

Every frame starts with an opcode byte:

| First byte | Meaning | Frame |
|------------|---------|-------|
| `0x00`-`0x7E` | register write | `[reg, value]` |
| `0x80`-`0xFE` | register read | `[0x80 \| reg, 0xFF]`, value comes back in byte 2 |
| `0x7F` (or `0xFF`) | **XFER**: memory space read/write | see below |

XFER frames:

```
write: 0x7F, ctl, addr[7:0], addr[15:8], addr[23:16], len[7:0], len[15:8], data...
read:  0x7F, ctl, addr[7:0], addr[15:8], addr[23:16], len[7:0], len[15:8], dummy, data...
ctl  = 0x10 | (space << 1) | (1 for read, 0 for write)
```

`a2hostd` splits transfers into 512-byte chunks.

> **Register `0x7F` does not exist and must never be used.** Since `0x7F` and
> `0xFF` are the XFER opcode, a "register read" of `0x7F` sends `0xFF 0xFF`
> and starts a read transfer instead. I learned this the hard way: my first
> SSC bridge build put a status register at `0x7F`, and `a2hostd` ended up
> streaming zeros to the network. All new host ports share an existing memory
> space by address instead.

## Registers A2ZYNQ uses

Most of the 128 registers are upstream's and documented in the upstream
`BL616_SPI_PROTOCOL.md`. These are the ones that matter on this port, and the
ones I added or changed:

| Reg | Dir | Contents |
|-----|-----|----------|
| `0x00`-`0x05` | R | device ID, protocol version, capabilities |
| `0x06` | R | status: bit 7 = 1, bit 6 = memory init done, bit 5 = Apple not in reset, **bit 4 = SSC network bridge present**, bit 3 = 0, **bit 2 = hard disk host buffer present (SPACE 7)**, bits 1:0 = SDRAM write/read pending |
| `0x07`, `0x0C`-`0x0F`, `0x6F` | R/W | scratch registers, used here for the **bus drive timing** (see below) |
| `0x08`-`0x0B` | R | free-running time counter |
| `0x10`-`0x25` | R/W | video mode, colours, keyboard |
| `0x26`-`0x2D` | R/W | ProDOS hard disk, two units: request (rd/wr), block number, size, ack |
| `0x2E` | R/W | **A2ZYNQ control**: bit 0 = release the Apple from reset (host ready; the power-on hold only applies while DIP switch 3 is ON), bit 1 = force /RES (always works), bit 2 = self-test ROM, bit 3 = slot 7 test ROM; read: bits 6:4 = **slot the card is plugged into** (0 = not seen yet), **bit 7 = Disk II track read-back present (SPACE 6)** |
| `0x2F` | R | the SSC 6551 control register (baud rate in bits 3:0) |
| `0x30`-`0x3E` | R/W | bus ready, CardROM, Apple reset and control lines |
| `0x3F` | R/W | build date: write a digit index 0-13, read that ASCII digit (`20261002030000`) |
| `0x40`-`0x4E` | R/W | Disk II drive 1: ready, active, mounted, read-only, size, requested track/LBA, rd/wr |
| `0x50`-`0x5E` | R/W | Disk II drive 2, same layout |
| `0x60`-`0x67` | R/W | **slot map**: card ID for slots 0-7 |
| `0x7A` | R/W | Uthernet II command doorbell (write 1 to clear) |

The slot map card IDs (as `a2hostd` writes them): `0` = empty, `1` =
SuperSprite, `2` = Mockingboard, `3` = Super Serial, `4` = Disk II, `5` =
Uthernet II, `6` = ProDOS hard disk. With the card in slot 1 the map is
`{0, 0, 3, 5, 2, 6, 4, 1}` for slots 0-7.

### Bus drive timing

The proto card's data bus is an SN74LVC245A whose direction and enable come
from the FPGA. When and how the FPGA drives it is set by a few registers that
`a2hostd` loads from the settings file at start:

| Reg | Setting | Meaning |
|-----|---------|---------|
| `0x07` | `bus_drive_fine` | bit 7 = early start, bits 6:0 = fine delay |
| `0x0D` | `bus_data_count` | bit 6 = soft landing, bit 5 = order, bit 7 = late pass off |
| `0x0E` | `bus_write_count` | bits 7:4 = step, bit 3 = open at commit |
| `0x6F` | `bus_drive_release` | bit 0 = early release, bits 5:1 = delay, bit 6 = open drain, bit 7 = weak-first order |

The values in the shipped defaults are what my IIe is happy with. You
shouldn't need to change them; if you do, `tests/bus_timing` has
simulations of every option.

## Memory spaces

All eight XFER spaces are taken, which is why new features share a space by
address:

| Space | What | Notes |
|-------|------|-------|
| 0 | local | upstream |
| 1 | memory window (DDR) | upstream "SDRAM". Disk II track loads go to `0x200000 + drive*0x2000` and are copied into the drive's nibble RAM as they pass through |
| 2 | bus event FIFO | upstream bus capture |
| 3 | W5100 | the Uthernet II chip's 32 KB of registers and buffers |
| 4 | Disk II `$C800` RAM | **A2ZYNQ**: the boot menu's code, screen and mailbox |
| 5 | HDMI notice line + SSC bridge | **A2ZYNQ**: writes below `0x40` = notice line (byte 0 bit 0 = show, bytes 1-40 = text); reads below `0x100` = SSC status, reads at `0x100`+ = bytes from the Apple, writes at `0x100`+ = bytes to the Apple |
| 6 | Disk II track read-back | **A2ZYNQ**, read only: `drive*0x2000 + byte`, the drive's own copy of the current track |
| 7 | hard disk sector buffer | **A2ZYNQ**, read/write: the controller's 512-byte buffer |

Spaces 6 and 7 exist because the upstream path (move everything through the
SDRAM window) wasn't reliable on this port. The details are in
[storage.md](storage.md). Space 5's SSC part is in
[serial-over-network.md](serial-over-network.md).

## The menu mailbox (space 4)

The disk menu is 6502 code that runs from the Disk II card's 2 KB `$C800`
RAM. `a2hostd` uploads the code (from `src/a2hostd/include/disk_menu_code.h`,
built from `hdl/disk/diskmenu.a65`) and both sides talk through a few bytes
at `$CE00`:

| Address | Name | Who writes | Meaning |
|---------|------|------------|---------|
| `$CE00`/`01` | MAGIC | host | `$A5 $5A` when `a2hostd` is serving the menu |
| `$CE02` | FRAME | host | bumped after each screen update |
| `$CE03` | CMD | host | `1` boot the floppy, `2` draw the last frame and jump to TARGET (the hard disk card picked in the menu, or the Disk II's new slot after a move), `3` exit to BASIC (ESC), `4` power-up in slot 1: go to BASIC |
| `$CE04` | ACK | host | acknowledges the Apple's last event |
| `$CE05`/`06` | TARGET | host | address to jump to for CMD 2 |
| `$CE08` | SEQ | Apple | event counter |
| `$CE09` | EVT | Apple | event type: `1` hello (menu started), `2` key |
| `$CE0A` | KEY | Apple | the key pressed |
| `$CE0B` | MSLOT | Apple | slot the menu is running from, times 16 (`$60` for slot 6) |
| `$CE0C` | COLD | Apple | 1 = entered from the power-up boot scan (reset vector still `$E000`) |

`tests/menu6502/menu_sim.py` runs the real menu binary on a 6502 emulator
against a fake host and checks each of these paths.
