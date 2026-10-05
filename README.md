# A2ZYNQ

**One Apple II slot, seven peripheral cards, running on a Smart Zynq SP.**

A2ZYNQ is my port of the [A2FPGA](https://github.com/a2fpga/a2fpga_core)
Multicard core to the **Smart Zynq SP**, a small Xilinx Zynq-7020 board with
a dual-core ARM, DDR3, HDMI, Ethernet and an SD card slot. A hand-wired proto
card sits in an Apple II slot and connects the Apple bus to the Zynq with a
pair of ribbon cables. The FPGA side runs the A2FPGA core (the same one the
A2N20v2 card uses) and answers for every empty slot in the machine. The ARM
side runs Linux and a small service program, `a2hostd`, that serves disk
images from the SD card, does the networking and runs the boot menu.

The end result: I boot my **Apple IIe** (plain NMOS 6502, 64K, 40
columns) into a disk menu, pick a game from a folder on an SD card, swap disks
with a button on the board, play Total Replay off a 32 MB hard disk, hear the
Mockingboard over HDMI, put the IIe on my home network, and drag disk images
onto it from my PC over FTP. One card does all of it.

```
 Apple IIe slot                          Smart Zynq SP
+--------------------+   2x 40-pin    +-----------------------------------------+
|  proto card        |   ribbons      |  PL (FPGA)                PS (ARM)      |
|  5x SN74LVC245A    |===============>|  A2FPGA core      SPI     Linux         |
|  6x NPN open-coll. |<===============|  - Disk II        over    a2hostd       |
|  /RES sense        |   + ground     |  - ProDOS HDD     AXI <=> - disk images |
+--------------------+   bundle       |  - SSC, Uthernet          - disk menu   |
                                      |  - Mockingboard           - FTP, telnet |
                                      |  - SuperSprite            - SSC bridge  |
                                      |  - HDMI video/audio       - Ethernet    |
                                      +-----------------------------------------+
                                           |HDMI          |SD card   |Ethernet
```

## Why I built this

I wanted an A2FPGA for my IIe, and I already had a Smart Zynq SP on my bench.
The A2N20v2-Enhanced design pairs a Gowin FPGA with a BL616 microcontroller
that serves disks, runs the menu and bridges the network. The Zynq has both
halves on one chip: a decent FPGA, and ARM cores that can run real Linux. So
instead of building another card, I ported the Enhanced design over. The FPGA
logic stays the A2FPGA core, and the BL616's job moves to a Linux program
that speaks the same SPI protocol the BL616 did.

It turned into a much longer project than I expected. The core had to come
off Gowin primitives and onto Xilinx ones, the SDRAM had to become Zynq DDR,
and the Apple bus turned out to be a lot less forgiving than the datasheets
make it look. Along the way I found and fixed a stack of things: an SPI bit
race, a Disk II write path that stored every nibble twice, a hard disk read
that could return stale data, a video shadow that painted neighbour bytes, and
one level translator chip that simply can't do this job (more on that below).
It all works now on my IIe, and the card test disk in this repo passes every
slot.

## What the card provides

With the card in slot 1 (how I run it):

| Slot | Card | What you get |
|------|------|--------------|
| 1 | *(the physical card)* | nothing virtual here, the IIe powers up to BASIC |
| 2 | Super Serial Card | a 6551 serial port, bridged to **TCP port 6551** on the board, so the Apple's serial port shows up on your network |
| 3 | Uthernet II (W5100) | Ethernet for IP65 programs; Apple frames go straight out the board's Ethernet port, and the Apple gets its own address from your router |
| 4 | Mockingboard | two AY-3-8910 sound chips + 6522 VIAs, stereo over HDMI |
| 5 | ProDOS hard disk | two drives up to 32 MB each (`hdd1.hdv`, `hdd2.po`), bootable with `PR#5` |
| 6 | Disk II + disk menu | two 5.25" drives fed from disk images on the SD card, with a boot menu, read **and** write |
| 7 | SuperSprite | TMS9918A video chip with sprites, mixed over the Apple picture on HDMI, plus an AY sound chip |

The Disk II follows the card: put the card in slot 6 and the Disk II answers
in slot 6 and boots at power-up, the hard disk moves to slot 5. Slots 2, 3, 4
and 7 never move. The full table is in the
[board README](boards/a2n20v2-SmartZynq/README.md#slot-map).

Plus:

- **HDMI out** with the Apple picture regenerated (text, lores, hires; the
  core also does 80 columns and double hires, which I can't test without an
  80-column card), with the Apple speaker, Mockingboard and SuperSprite sound
  all on the HDMI audio.
- **A disk menu that runs on the Apple itself.** Folders, arrow keys,
  jump by first letter, `RETURN` boots, `TAB` puts a disk in drive 2, `ESC`
  drops you at BASIC. It remembers the last disk you booted.
- **Disk swapping with board buttons.** `KEY1` on the Smart Zynq puts the next
  disk of a set into drive 1 (`ultima31.dsk` -> `ultima32.dsk`), `KEY2` the
  previous one. A line under the Apple picture on HDMI tells you what's in
  the drive. No keyboard hotkey, nothing a game can trip over.
- **Writes are saved.** DOS 3.3 `SAVE`, ProDOS files, game saves: changed
  tracks are written back into the image on the SD card.
- **FTP server** on the board, so copying games over is drag and drop from
  Windows Explorer, FileZilla or `curl`.
- **Telnet console** with `status`, `rescan` and an FPGA dump command.
- **A card test disk** ([tests/cardtest](tests/cardtest)) that exercises
  every virtual card from the Apple side and writes a log back to the disk.

## Status

This is a working hobby build, not a product. What I've tested on my own
unenhanced IIe:

| | |
|--|--|
| Disk II boot, menu, folders, ESC, drive 2 | works |
| Floppy writes (DOS 3.3 and ProDOS) | works, verified with the card test (0 failed) |
| Multi-disk swap with KEY1/KEY2 | works |
| ProDOS hard disk read/write, Total Replay | works |
| Mockingboard, SuperSprite | works (card test tones and green box) |
| Uthernet II with IP65 (DHCP, DATE65, HFS65 web server) | works |
| Super Serial Card registers | works (card test) |
| SSC over the network (TCP 6551) | works in simulation, real-Apple test still on my list |
| Apple IIgs, enhanced IIe, II+ | not tested. The IIgs signals (M2SEL, M2B0) are wired on the card, but I've never tried it. IIgs mode is off by default because DIP switch 4 hides the HDMI debug numbers instead (one setting in `top.sv` swaps it back) |
| Powering the board from the Apple's +5V | not done yet, see [the power notes](boards/a2n20v2-SmartZynq/docs/power.md) first |

Known limits on an unenhanced IIe (these are the machine, not the card):
anything built for the 65C02 (ProDOS 8 2.x, Contiki, the C versions of the
IP65 apps) locks up, and 80-column programs show every second character
without an 80-column card.

The open items are in [boards/a2n20v2-SmartZynq/TODO.md](boards/a2n20v2-SmartZynq/TODO.md).

## What you need

- An Apple II with a free slot. Mine is a IIe.
- A **Smart Zynq SP** board (XC7Z020-1CLG484) and a USB-C cable/charger for it.
- The **red proto card**, hand-wired per [hardware/RED_PROTO_CARD_WIRING.md](hardware/RED_PROTO_CARD_WIRING.md):
  five SN74LVC245A, seven 2N3904s, a few resistors, two 2x20 headers and two
  40-pin ribbon cables. Parts list in [hardware/BOM.csv](hardware/BOM.csv).
  **Use real SN74LVC245A for the data bus.** Auto-direction translators
  (TXB0108, TXS0108E) do not work, I tried both.
- A microSD card (4 GB or bigger) for Linux and your disk images.
- An HDMI monitor, and an Ethernet cable if you want FTP and networking.
- To build from source: a Linux PC with **Vivado 2024.2** (the free
  Standard edition covers the XC7Z020) and an ARM cross compiler.

## Getting started

1. **Build or grab the bitstream.** [docs/BUILDING.md](docs/BUILDING.md)
   walks through it: download the Xillinux kit into `third_party/`, run one
   Vivado script, wait half an hour.
2. **Make the SD card.** [docs/INSTALLING.md](docs/INSTALLING.md) covers
   writing Xillinux, putting the bitstream, device tree and `a2hostd` on it,
   and updating a running board later over the network.
3. **Wire the proto card**, check it with a meter before anything goes near
   the Apple, and plug it in with everything powered off.
4. **Power up**: board first (USB-C), wait about 40 seconds, then the Apple.
5. **Use it**: [docs/USER_GUIDE.md](docs/USER_GUIDE.md) explains every card
   with examples you can type in.

## Repository layout

This follows the same layout as `a2fpga_core`, so anyone who knows the
upstream tree will find their way around.

```
A2ZYNQ/
  README.md            you are here
  LICENSE              layered license (MIT + GPL parts), same terms as A2FPGA
  LICENSES/            full GPL-2.0 and GPL-3.0 texts
  hdl/                 the A2FPGA core, with my fixes (disk, hdd, video, ssc bridge...)
  boards/
    a2n20v2-SmartZynq/ everything specific to the Smart Zynq SP
      README.md        the board guide: slots, menu, images, FTP, troubleshooting
      TODO.md          what's left
      hdl/             the a2n20v2-Enhanced top level and SPI connector, ported
      rtl/             Smart Zynq wrapper: board top, bus PHY, clocking, DDR, SPI master
      vivado/          build.tcl, rebuild.tcl, sources.tcl, constraints, BD patch
      device_tree/     merged Xillinux device tree with the A2 UIO node
      src/a2hostd/     the Linux service (C++14): disks, menu, network, SSC bridge
      src/systemd/     a2hostd.service
      tools/           SD card writer, a2hostd cross build, device tree merge
      docs/            how the Zynq side works: SPI map, storage, power, lessons
  docs/
    USER_GUIDE.md      how to use every card, with examples
    BUILDING.md        building the bitstream and a2hostd
    INSTALLING.md      SD card, first boot, updating
    core/              A2FPGA core documentation (from upstream, with my notes)
  hardware/            proto card wiring, BOM, pin maps, schematics (PDF + KiCad)
  tests/
    bus_timing/        xsim testbenches for the bus, Disk II, HDD, menu, SSC bridge...
    cardtest/          Apple II test program for slots 2-7 (cc65)
    menu6502/          runs the disk menu code on a 6502 emulator
  tools/               serial console and file transfer helpers, ProDOS disk builder
  third_party/         where the Xillinux kit goes (not included, see its README)
```

## How it differs from a2n20v2-Enhanced

If you know the upstream board, here's the short version of what changed:

- **BL616 -> Linux.** `a2hostd` on the Zynq ARM takes over everything the
  BL616 firmware did. It talks to the FPGA with the same SPI protocol, through
  a small AXI SPI master in the PL that Linux drives through UIO, so the
  core's `bl616_spi_connector` barely had to change.
- **SDRAM -> DDR3.** The core's memory clients share an arbiter that is
  bridged across clock domains into the Zynq's HP2 AXI port, using a reserved
  8 MiB window at `0x1E000000`.
- **Gowin -> Xilinx.** Clocking (MMCM), HDMI TMDS serializers (OSERDESE2),
  tri-states and a few memories were rewritten or wrapped for Vivado.
- **CPLD -> five 245s.** The original card captures the bus with a CPLD; the
  proto card uses five SN74LVC245A and puts all the capture and timing logic
  in the FPGA, with drive timing you can tune from Linux.
- **Storage paths I added.** Floppy saves read the track straight back out of
  the drive's nibble memory, and hard disk blocks go straight to and from the
  controller's sector buffer. The upstream SDRAM round trip wasn't reliable on
  this port (the card test caught it).
- **Extras:** the 6502 disk menu with folders and ESC, the Disk II following
  the card's slot, board-button disk swaps with an HDMI notice line, the SSC
  network bridge, FTP/telnet on the board, and BRAM shadows for text and
  hires video.

## Things I learned the hard way

- **Auto-direction level shifters don't belong on the Apple data bus.**
  TXB0108 and TXS0108E both read isolated 0 bits as 1 (things like `$BD`
  became `$FF` 40-85% of the time) and no amount of FPGA timing fixed it. An
  SN74LVC245A with the FPGA driving DIR and OE# fixed it on the first boot.
- **6502 dummy reads are real bus cycles.** `STA abs,X`, `STA (zp),Y` and
  Applesoft's `POKE` all read the address before they write it. Any register
  with a read side effect (auto-increment, clear-on-read) gets hit twice. The
  Uthernet II DHCP bug I chased was exactly this.
- **Act at the end of the bus cycle.** The card sees selects at the start of
  PHI0, so anything that "fires on select" can fire twice per access. That's
  what made the Disk II write every nibble twice.
- **Don't restart the host service under a running Apple.** If `a2hostd`
  drops out, the card stops answering and the 6502 crashes. Restart it only
  with the Apple switched off.

The long version, with the measurements, is in
[boards/a2n20v2-SmartZynq/docs/lessons-learned.md](boards/a2n20v2-SmartZynq/docs/lessons-learned.md).

## Documentation

| Document | What's in it |
|----------|--------------|
| [boards/a2n20v2-SmartZynq/README.md](boards/a2n20v2-SmartZynq/README.md) | The board guide: slot map, disk images, first boot, menu, FTP, network, troubleshooting |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | Every card explained with examples (BASIC listings, PC commands) |
| [docs/BUILDING.md](docs/BUILDING.md) | Building the bitstream and `a2hostd`, running the tests |
| [docs/INSTALLING.md](docs/INSTALLING.md) | SD card, first boot, updating the board |
| [boards/a2n20v2-SmartZynq/docs/](boards/a2n20v2-SmartZynq/docs/) | How the Zynq port works inside: SPI host interface, storage, SSC bridge, power, lessons learned |
| [hardware/RED_PROTO_CARD_WIRING.md](hardware/RED_PROTO_CARD_WIRING.md) | Wiring the proto card, the electrical rules, bring-up checks |
| [docs/core/](docs/core/) | The A2FPGA core docs: architecture, bus interface, memory, video, audio, peripheral cards |

## Credits

This project stands on other people's work, and I want to be clear about that.

- **[A2FPGA](https://github.com/a2fpga/a2fpga_core)** by Ed Anuff and the
  A2FPGA contributors. The core, the virtual cards, the video pipeline and the
  a2n20v2-Enhanced design I ported all come from there. My port started from
  upstream commit `f97dc342`.
- The open cores inside A2FPGA: the 6522 VIA by Gideon Zweijtzer
  (1541ultimate), the IIR filter by Sorgelig (MiSTer), the F18A/TMS9918 core,
  the YM2149 (AY-3-8910) and 6551 cores, the TMS5220, and the AppleWin team, whose HDD
  firmware and 6-and-2 GCR code live on in the hard disk ROM and in `a2hostd`.
- **[Xillybus](https://xillybus.com)** for Xillinux and the Smart Zynq SP
  demo bundle that the build starts from.
- **[Total Replay](https://github.com/a2-4am/4cade)** by 4am and qkumba, which
  is what I keep on hard disk 1.
- **[IP65](https://github.com/cc65/ip65)** for the Uthernet test disk.
- **[cc65](https://cc65.github.io)** for building the card test, and
  **[py65](https://github.com/mnaberez/py65)** for testing the menu code
  without an Apple.

## License

Same terms as A2FPGA: MIT for the A2FPGA and A2ZYNQ files, with a few GPL
components that make the bitstream as a whole GPL-3.0. Details in
[LICENSE](LICENSE). The Xillinux kit is Xillybus's and is not included.

Apple, Apple II and ProDOS are trademarks of Apple Inc. This is a hobby
project with no connection to Apple, AMD/Xilinx, Xillybus or the Smart Zynq
maker.
