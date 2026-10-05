# a2n20v2-SmartZynq: A2FPGA on the Smart Zynq SP

This is the board folder for A2ZYNQ: the A2FPGA **a2n20v2-Enhanced** design,
ported from the Tang Nano 20K + BL616 to the **Smart Zynq SP** (Xilinx
XC7Z020, dual Cortex-A9, 512 MB DDR3, HDMI, gigabit Ethernet, microSD).

On the original card, a BL616 microcontroller serves the disks, runs the
on-screen menu and bridges the network. Here the Zynq's FPGA fabric (PL) runs
the A2FPGA core and the Zynq's ARM side (PS) runs Linux (Xillinux, Ubuntu
16.04) with a service called **a2hostd** that does the BL616's job. The two
halves talk over the same SPI protocol the BL616 used, through a little SPI
master in the PL that Linux drives as a UIO device.

The Apple side connects through a hand-wired proto card (five SN74LVC245A and
a few NPN transistors) and two 40-pin ribbon cables to the Smart Zynq's
expansion headers. See [hardware/](../../hardware/) for the card.

> **Status: working hobby build.** Everything below runs on my unenhanced
> Apple IIe and passes the card test. It has not been tried on a IIgs, an
> enhanced IIe or a II+. Open items are in [TODO.md](TODO.md).

## Contents

- [What the card provides](#what-the-card-provides)
- [Slot map](#slot-map)
- [Disk image support](#disk-image-support)
- [What you need](#what-you-need)
- [Installing and updating](#installing-and-updating)
- [First boot: what to expect](#first-boot-what-to-expect)
- [The disk menu](#the-disk-menu)
- [Multi-disk games: the board buttons](#multi-disk-games-the-board-buttons)
- [Hard disks](#hard-disks)
- [Copying disk images over the network (FTP)](#copying-disk-images-over-the-network-ftp)
- [Telnet console](#telnet-console)
- [Serial over the network (Super Serial Card)](#serial-over-the-network-super-serial-card)
- [Networking the Apple (Uthernet II)](#networking-the-apple-uthernet-ii)
- [Settings](#settings)
- [DIP switches](#dip-switches)
- [Power](#power)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [How this folder is laid out](#how-this-folder-is-laid-out)
- [Documentation](#documentation)

## What the card provides

Virtual peripheral cards, with the physical card in slot 1:

| Slot | Card | Notes |
|------|------|-------|
| 2 | Super Serial Card (6551) | Bridged to TCP port 6551 on the board: the serial port is on your network, no cable |
| 3 | Uthernet II (WIZnet W5100) | MAC-raw mode bridged to the board's Ethernet; works with IP65 programs |
| 4 | Mockingboard | Two AY-3-8910 + 6522, stereo over HDMI |
| 5 | ProDOS hard disk | Two block devices, up to 32 MB each, bootable (`PR#5`) |
| 6 | Disk II + boot menu | Two 5.25" drives fed from images on the SD card, read and write |
| 7 | SuperSprite | TMS9918A (F18A core) mixed over the Apple picture, plus an AY-3-8910 |

Also:

- **HDMI** video for the Apple II/IIe modes, with the Apple speaker,
  Mockingboard and SuperSprite on the HDMI audio. Text and hires are served
  from block RAM shadows, so there's no DDR ghosting.
- A **disk menu that runs on the Apple** (folders, letter jump, drive 2, ESC
  to BASIC).
- **KEY1 / KEY2** on the Smart Zynq swap disks mid-game, with a notice line
  under the Apple picture.
- **FTP** and a **telnet console** on the board.
- **Bus drive timing** that can be tuned from Linux without a rebuild (you
  shouldn't need to, but it's there).
- **DIP switch 4** hides the HDMI debug numbers (see [DIP switches](#dip-switches)).

## Slot map

Slots 2, 3, 4 and 7 never move. The Disk II follows the slot you plug the
card into, because that's the slot a IIe boots from:

| Card in slot | Disk II | Hard disk | Displaced card | At power-up |
|--------------|---------|-----------|----------------|-------------|
| 1 | 6 | 5 | - | BASIC prompt, nothing boots. `PR#6` opens the menu (`SLOT 1 MENU`) |
| 2 or 3 | 6 | 5 | - | the menu, titled `SLOT 2 MENU` / `SLOT 3 MENU` |
| 4 | 4 | 6 | Mockingboard moves to 5 | `SLOT 4 DISK MENU` |
| 5 | 5 | 6 | - | `SLOT 5 DISK MENU` |
| 6 | 6 | 5 | - | `SLOT 6 DISK MENU` |
| 7 | 7 | 6 | SuperSprite moves to 5 | `SLOT 7 DISK MENU` |

How it works: the FPGA watches the card's own /IOSEL and /DEVSEL pins, so it
knows which slot it's in, and `a2hostd` remembers it (`card_slot`). When the
menu says hello from a different slot than last time, `a2hostd` holds the
Apple in reset, moves the Disk II to the new slot and lets it go. With the
card in slots 1-3 the Disk II stays in slot 6: a IIe never boots slot 3 (its
80-column firmware owns `$C3xx`), and in slot 1 I wanted the machine to come
up like a plain IIe with no disk.

The hard disk never boots by itself, wherever it sits. Its firmware leaves
out the byte the IIe's power-up scan looks for (`$3C` at `$Cn07`), so the
scan passes over it and always reaches the Disk II and the menu, even with
the hard disk in a higher slot (card in 4, 5 or 7). You boot a hard disk by
picking its image in the menu, or with `PR#n` from BASIC. Ctrl-Open
Apple-Reset brings you back to the menu.

You can pin the Disk II to a slot with `disk_slot=4..7` in the
[settings](#settings).

**Always switch the Apple off and unplug the board before moving the card.**

## Disk image support

All images live on the board's SD card under **`/media/a2`**, in any folders
you like.

Floppy drives (Disk II), read **and** write:

| Format | Size | Notes |
|--------|------|-------|
| `.dsk` | 143,360 bytes | Sector order detected from the content (DOS 3.3 or ProDOS order both work) |
| `.do` | 143,360 bytes | DOS 3.3 order |
| `.po` | 143,360 bytes | ProDOS order (a bigger `.po` is a hard disk) |
| `.2mg` | 140K payload | 2IMG container, DOS, ProDOS or nibble payload |
| `.nib` | 232,960 bytes | Raw nibbles, served as they are |

Hard disks (ProDOS block devices), read and write, picked in the menu (they
show with `HD` at the right):

| Format | Notes |
|--------|-------|
| `.hdv` | Raw ProDOS blocks, up to 32 MB (65,535 blocks) |
| `.po` | Any size other than 140K (800K disks too), raw blocks |
| `.2mg` | ProDOS-order payload bigger than a floppy |

Tracks and blocks are read from the SD card on demand, so image size isn't
limited by FPGA memory. When the Apple writes a track, the changed track is
written back into the image as soon as the drive stops or the head moves.
`.woz` isn't supported.

## What you need

- **Smart Zynq SP** board (XC7Z020-1CLG484) and a USB-C power supply. The
  board takes power on either USB-C socket; use the one marked UART/JTAG so
  you get the serial console on the same cable.
- The **red proto card**, wired per
  [hardware/RED_PROTO_CARD_WIRING.md](../../hardware/RED_PROTO_CARD_WIRING.md),
  with **SN74LVC245A** on the data bus (U5). Not TXB0108 or TXS0108E, see
  [docs/lessons-learned.md](docs/lessons-learned.md).
- Two 40-pin ribbon cables (Smart Zynq U12 to JZ1, U13 to JZ2) and a separate
  ground bundle of at least four wires.
- A **microSD card**, 4 GB or bigger.
- An **HDMI** monitor or TV.
- **Ethernet** to your router, if you want FTP, the serial bridge or Uthernet.
- A PC with a USB-C cable for the serial console (any terminal program at
  115200 baud).

## Installing and updating

The full walk-through is in [docs/INSTALLING.md](../../docs/INSTALLING.md).
Short version:

**New SD card** (from a Linux PC, after building, see below):

```bash
# needs the Xillinux kit + image in third_party/, a bitstream and a2hostd in build/
boards/a2n20v2-SmartZynq/tools/write_sd_card.sh /dev/sdX
```

**Updating a running board** (Apple switched **off**):

```bash
# from the PC: upload the new files into /media/a2 over FTP
curl -T boards/a2n20v2-SmartZynq/build/xillydemo.bit ftp://<board-ip>/xillydemo.bit --user a2:
curl -T boards/a2n20v2-SmartZynq/build/a2hostd       ftp://<board-ip>/a2hostd       --user a2:
```

then on the board's serial console:

```bash
# new bitstream: it lives on the FAT boot partition, loaded at boot
mount /dev/mmcblk0p1 /mnt && \cp /media/a2/xillydemo.bit /mnt/ && sync && umount /mnt

# new a2hostd: copy beside the old one, then rename (a running binary can't be overwritten)
systemctl stop a2hostd
\cp /media/a2/a2hostd /usr/local/sbin/a2hostd.new && chmod 755 /usr/local/sbin/a2hostd.new
mv /usr/local/sbin/a2hostd.new /usr/local/sbin/a2hostd
rm /media/a2/xillydemo.bit /media/a2/a2hostd
reboot
```

(The backslash in `\cp` skips Xillinux's `cp -i` alias.) If the board isn't on
your network, [tools/board_push.py](../../tools/README.md) sends files over the
serial console instead. It's slow (a minute per megabyte) but it works.

## First boot: what to expect

1. Power the board (USB-C). After about 40 seconds Linux is up, the bitstream
   is loaded, and `a2hostd` is running. The HDMI screen shows the (empty)
   Apple picture with a status line on top that includes the bitstream's
   build date, like `20261002030000`.
2. Switch the Apple on. With DIP switch 3 ON the board holds the Apple in
   reset until `a2hostd` is ready, so switching on early is harmless (see
   [DIP switches](#dip-switches)).
3. With the card in slots 2-7 the IIe's boot scan finds the Disk II and the
   **disk menu** comes up. In slot 1 you get `Apple ][` and the BASIC prompt;
   type `PR#6`.
4. If no menu shows and the Apple hangs at the boot screen, see
   [Troubleshooting](#troubleshooting).

The board keeps the detected slot across Apple power cycles (it has its own
power), so it only re-detects when you move the card.

## The disk menu

The menu is a small 6502 program that lives in the Disk II card's `$C800`
RAM. The boot ROM calls it before it starts reading the disk. `a2hostd`
fills the screen over SPI, reads your keys from a mailbox in the same RAM, and
mounts the disk you pick before telling the Apple to go. A floppy boots from
the Disk II; a hard disk image goes in hard disk 1 and the menu jumps to the
hard disk card, the same as `PR#n`. If `a2hostd` isn't running, the menu
returns at once and the Disk II boots like a normal one.

```
 SLOT 6 DISK MENU                          <- inverse bar
DRIVE 1: Oregon Trail.dsk
DRIVE 2: (EMPTY)
HARD DISK 1: Total.Replay.hdv
HARD DISK 2: hdd2.po
/media/a2/                            4/9
  Games/
  Ultima/
  CardTest.dsk
2 hdd2.po                             HD   <- "2" = in hard disk 2
  IP65 Net Tools (6502).dsk
1 OREGON TRAIL.DSK                         <- highlighted (inverse), "1" = in drive 1
1 Total.Replay.hdv                    HD   <- "1" = in hard disk 1
  ...

RETURN:BOOT  TAB:DRIVE 2  ESC:EXIT
IN GAME: BOARD KEY1=NEXT KEY2=PREV DISK
```

Lines 1-4 show what's in the two floppy drives and the two hard disks. The
next line is the folder you're in and your position in the list. Hard disk
images have `HD` at the right. A `1` or `2` in front of a name means that
image is in drive 1 or 2 (floppies) or hard disk 1 or 2 (hard disks). Inside a
folder, the first entry is `..` to go back up.

| Key | Does |
|-----|------|
| Up / Down | move one line |
| Left / Right | page up / page down |
| `A`-`Z`, `0`-`9` | jump to the next entry starting with that character |
| `RETURN` | floppy: put it in drive 1 and boot it. Hard disk: put it in hard disk 1 and boot it. Folder: open it (`..` goes up) |
| `TAB` | floppy: put it in drive 2. Hard disk: put it in hard disk 2. Pressed on the disk already there, it takes it out. You stay in the menu |
| `ESC` | leave without booting: you land at the BASIC prompt (or wherever Ctrl-Reset would take you) |

The cursor starts on the disk you booted last (floppy or hard disk). Folders
come first, then disk images, sorted by name.

Settings: `disk_menu=0` turns the menu off (drive 1 boots like a plain Disk
II), `disk_menu_timeout=N` boots drive 1 after N seconds without a key.

## Multi-disk games: the board buttons

**KEY1** on the Smart Zynq puts the **next** disk of the set into drive 1,
**KEY2** the **previous** one. The new disk's name shows on a line under the
Apple picture on HDMI for 4 seconds.

A "set" is the images in the same folder whose names differ only in a short
tail after a common start: `ultima31.dsk` / `ultima32.dsk`,
`OREGON_A.dsk` / `OREGON_B.dsk`, `Game (Disk 1 of 3).dsk` / `Game (Disk 2 of 3).dsk`.
If nothing in the folder looks like a set, the buttons step through every
image in the folder.

There's no keyboard hotkey on purpose: I tried one, and the game sees the key
too.

Before a swap, any track the Apple wrote is saved to the old image first, so
swapping in the middle of a save is safe once the drive light would have gone
out.

## Hard disks

The ProDOS hard disk card has two units, hard disk 1 and hard disk 2. Each is
one image file anywhere under `/media/a2`, picked in the [disk menu](#the-disk-menu):
RETURN on a hard disk image puts it in hard disk 1 and boots it, TAB puts it
in hard disk 2 (handy for a data volume next to a boot volume). The picks are
remembered (`hdd1_image`, `hdd2_image`) and mounted again when the board
starts. With nothing picked yet, `hdd1.hdv`/`.po`/`.2mg` and
`hdd2.hdv`/`.po`/`.2mg` are used if they exist.

ProDOS sees them as slot 5 (or 6, see the [slot map](#slot-map)), drives 1
and 2, whichever disk ProDOS booted from. The hard disk is **never booted by
the power-up scan**: only by the menu, or by `PR#5` (`PR#6`) from BASIC.
New images uploaded over FTP show up the next time the menu opens.

What I keep on mine:

- **[Total Replay](https://github.com/a2-4am/4cade)**, hundreds of games on
  one 32 MB volume, with a menu, previews and search. It checks the machine
  at start and hides games that need more than a 64K IIe or a joystick.
  Download `Total.Replay.hdv` from its releases page, upload it to
  `/media/a2`, and pick it in the menu.
- **`hdd2.po`** = `/HDTEST`, the card test's hard disk volume
  ([tests/cardtest](../../tests/cardtest)).

Hard disk blocks go straight between the image and the controller's 512-byte
sector buffer (SPI memory space 7). The upstream path through SDRAM could
return a block before it had landed, which the card test caught.

## Copying disk images over the network (FTP)

`a2hostd` runs a small FTP server on port 21. Any user name, no password, and
its root is `/media/a2`.

- **Windows:** type `ftp://<board-ip>/` in Explorer's address bar, then drag
  and drop.
- **FileZilla:** host `<board-ip>`, user `a2`, empty password, plain FTP.
- **curl:**

```bash
curl ftp://<board-ip>/ --user a2:                                        # list
curl -T "Oregon Trail.dsk" "ftp://<board-ip>/Oregon%20Trail.dsk" --user a2:   # upload
curl "ftp://<board-ip>/Game.dsk" --user a2: -o Game.dsk                  # download
curl ftp://<board-ip>/ --user a2: -Q "DELE Game.dsk"                     # delete
curl ftp://<board-ip>/ --user a2: -Q "RNFR old.dsk" -Q "RNTO new.dsk"    # rename
curl ftp://<board-ip>/ --user a2: -Q "MKD Games"                         # new folder
```

New floppies show up the next time the menu opens. It supports the basics
(LIST, RETR, STOR, DELE, RNFR/RNTO, MKD, CWD, passive mode), which is enough
for every client I tried. It doesn't do NLST, so `mget` in the old command
line `ftp` won't work.

Find the board's address in your router's client list, or on the serial
console with `ip addr show eth0`.

## Telnet console

Port 23 has a tiny command console (not a Linux shell):

```
$ telnet <board-ip>
status      which image is in each of the four drives (JSON)
rescan      look for images by name again (disk1.*, hdd1.*, ...) and mount any empty drive
fpga        dump the FPGA's floppy state to the a2hostd log (for debugging)
```

## Serial over the network (Super Serial Card)

The Super Serial Card in slot 2 has no cable. Its 6551's transmit and receive
lines run into a small bridge in the FPGA (`hdl/ssc/ssc_net_bridge.sv`) at
whatever baud rate the Apple sets, and `a2hostd` offers the other end on
**TCP port 6551**. Anything a PC sends to that port arrives at the Apple's
serial port, and anything the Apple sends comes out on the PC.

```bash
nc <board-ip> 6551                                     # simple, line at a time
socat -,raw,echo=0,escape=0x1d TCP:<board-ip>:6551      # every key at once, Ctrl-] quits
```

On the Apple:

```
]PR#2
]PRINT "HELLO FROM THE APPLE IIE"
]PR#0
```

and the text appears on the PC. `IN#2` takes keyboard input from the PC. The
baud rate only matters on the Apple side; the PC side is plain bytes. One
client at a time (a new connection replaces the old one), and there's no
password, so keep it on your home network. More examples (saving a listing
to a file, sending a BASIC program, using the Apple as a terminal) are in the
[user guide](../../docs/USER_GUIDE.md#5-super-serial-card-slot-2-over-the-network).

How the FPGA and `a2hostd` share the bridge is in
[docs/serial-over-network.md](docs/serial-over-network.md).

## Networking the Apple (Uthernet II)

The Uthernet II in slot 3 runs the W5100 in MAC-raw mode: the Apple's
Ethernet frames go out of the board's Ethernet port as if the Apple had its
own cable, and it gets its own address from your router. IP65 programs use
the MAC address `00:08:DC:A2:A2:A2`.

What works: programs that bring their own TCP/IP stack, like the IP65 tools.
`DATE65.SYSTEM` (DHCP, DNS, time) is the quickest "is it working" test, and
`HFS65.SYSTEM` turns the Apple into a little web server you can browse from
your PC. What doesn't: programs that use the W5100's own hardware TCP/UDP
sockets (WGET65), and anything built for the 65C02 (Contiki, the C versions
of the IP65 apps) on an unenhanced IIe.

## Settings

`a2hostd` reads `/var/lib/a2host/settings.ini` (one `name=value` per line) at
start and rewrites it when it exits, so edit it only while it's stopped, with
the Apple off:

```bash
systemctl stop a2hostd
vi /var/lib/a2host/settings.ini
systemctl start a2hostd
```

| Setting | Default | What it does |
|---------|---------|--------------|
| `disk_menu` | `1` | `0` = no menu, drive 1 boots like a plain Disk II |
| `disk_menu_timeout` | `0` | boot drive 1 after N seconds without a key (`0` = wait forever) |
| `disk_slot` | `auto` | `4`-`7` pins the Disk II to that slot; `auto` follows the card |
| `card_slot` | (detected) | the slot the card was last seen in, kept between boots |
| `boot_image`, `disk1_image`, `disk2_image` | (last used) | what the menu opens on and what's in the floppy drives |
| `hdd1_image`, `hdd2_image` | (last picked) | what's in hard disk 1 and 2 (`none` = empty) |
| `ssc_port` | `6551` | TCP port for the serial bridge, `0` = off |
| `ssc_cr_delay_ms` | `0` | pause after each carriage return sent to the Apple (for pasting BASIC programs) |
| `ftp_port` | `21` | FTP server port |
| `telnet_port` | `23` | telnet console port |
| `bus_addr_count`, `bus_data_count`, `bus_write_count`, `bus_drive_fine`, `bus_drive_release` | tuned | Apple bus drive timing. Leave these alone unless you're chasing bus errors on different hardware; see [docs/lessons-learned.md](docs/lessons-learned.md) |

## DIP switches

The proto card has a four-position DIP switch (SW1) wired to U13 pins 15-18.
Each switch connects its pin to **ground when ON**. The card has no pull-up
resistors; the FPGA's internal pull-ups hold an OFF switch high, so a switch
that's OFF, or not wired at all, simply means "off".

| Switch | ON means | Read |
|--------|----------|------|
| 1 | scanlines on HDMI (every other line dimmed) | when the board starts |
| 2 | Apple speaker on the HDMI audio | when the board starts |
| 3 | **Power-on-Reset hold**: after power-on the Apple waits in reset until the board is running and the cards are set up | live, matters at power-on |
| 4 | **hide the HDMI debug numbers** (the build date and status values along the top) | live, takes effect as soon as you flip it |

Switches 1 and 2 are read once when the FPGA starts, so after changing one,
switch the Apple off and power-cycle the board.

**Keep switch 3 ON** unless you have a reason not to. With it ON you can
switch the Apple on before the board has finished booting: the Apple sits in
reset (blank screen) until `a2hostd` has the cards ready, then starts and its
boot scan finds the Disk II and the menu. With it OFF the Apple starts right
away; if the board isn't ready yet, the Apple sees empty slots and goes to
BASIC, and the cards appear once `a2hostd` is up (`PR#6` then brings up the
menu). Once you power the board from the Apple's +5V
([docs/power.md](docs/power.md)), switch 3 ON is what makes it work, since
the board then always starts at the same moment as the Apple. Either way, the
FPGA can't hold anything during the first few seconds after the board powers
up, before the bitstream is loaded.

Upstream, switch 4 puts the card in **Apple IIgs mode**. One switch can't do
both jobs separately, and I don't have a IIgs, so on this build switch 4
controls the debug numbers and IIgs mode stays off. None of the IIgs code
was removed: set `DIP4_IIGS_MODE = 1` near the top of [hdl/top.sv](hdl/top.sv)
and rebuild, and switch 4 is the IIgs switch again (the debug numbers then
always show).

## Power

Right now I power the board from USB-C and the Apple from its own supply,
with only the grounds tied together. That's what the proto card wiring notes
say to do: **never connect the Apple's +5V straight to the Smart Zynq's 5V.**
Running the board from the Apple's supply is possible with a Schottky diode
in the line and a couple of checks, all written up in
[docs/power.md](docs/power.md).

Never plug or unplug the card or the ribbon cables with either side powered.

## Troubleshooting

**The Apple hangs at the boot screen / no menu.**
Is `a2hostd` running? On the serial console: `systemctl status a2hostd` and
`journalctl -u a2hostd -n 50`. The log shows the card slot it detected, every
menu hello and every track it served. If the board's HDMI picture is there
but the Apple sees nothing, check the ribbon cables (pin 1 to pin 1) and the
ground bundle.

**The menu shows up, but a program locks up right after it starts.**
It probably needs an enhanced IIe (65C02). ProDOS 8 2.x says so on screen;
Contiki and the C IP65 apps just freeze. Use 6502 versions of things.

**Every second character is missing.**
The program is in 80 columns, and the IIe has no 80-column card.

**With the card in slot 1, nothing happens at power-up.**
That's on purpose: type `PR#6`.

**A floppy save didn't stick.**
Boot `CardTest.dsk` from the menu ([tests/cardtest](../../tests/cardtest)); it
writes and reads back an 8 KB file and must end with `0 FAILED`. The board log
lists every track it saves (`journalctl -u a2hostd | grep save`).

**Random wrong bytes, especially values like `$BD` reading as `$FF`.**
Check U5 on the proto card. It must be an SN74LVC245A. The auto-direction
translators (TXB0108, TXS0108E) give exactly that pattern.

**I restarted `a2hostd` and the Apple crashed.**
Expected: while it restarts, the card stops answering. Only restart it with
the Apple off. If the Apple is stuck after that, power-cycle it (a crashed
6502 doesn't always come back from the card's reset).

**A hard disk image doesn't show in the menu.**
It needs a `.hdv`, `.po` or `.2mg` name and a size that's a multiple of 512
bytes. A `.po` of exactly 140K is a floppy, so it shows without `HD`.

**The Apple goes straight into a program at power-up instead of the menu.**
That was the hard disk being booted by the power-up scan; the hard disk
firmware no longer allows it. If it still happens, check the HDMI build date:
the bitstream needs to be `20261003235416` or newer.

## Building from source

Everything is in [docs/BUILDING.md](../../docs/BUILDING.md). In short:

```bash
# 1. put the Xillinux kit in third_party/ (see third_party/README.md)
# 2. bitstream, about 30-40 minutes:
vivado -mode batch -source boards/a2n20v2-SmartZynq/vivado/build.tcl
# 3. a2hostd:
A2ZYNQ_TOOLCHAIN=/path/to/arm-gnu-toolchain/bin boards/a2n20v2-SmartZynq/tools/build_a2hostd.sh
```

The bitstream and reports land in `boards/a2n20v2-SmartZynq/build/`.

## How this folder is laid out

```
a2n20v2-SmartZynq/
  hdl/                 board top level from a2n20v2-Enhanced, ported
    top.sv             the A2FPGA core wiring: cards, video, audio, memory, SPI connector
    bl616/             SPI connector, register map and host memory spaces (+ my additions)
    gowin/             the Gowin-specific pieces upstream used (mostly replaced on Xilinx)
    datetime.svh       build date shown on HDMI
  rtl/                 Smart Zynq wrapper
    smart_zynq_board_top.v          real top: pins, IOBUFs, block design
    smart_zynq_a2_application.sv    the core + DDR bridge + SPI transport
    a2_bus_phy.sv                   245 DIR/OE control and drive timing
    a2_clocking_xilinx.sv           MMCM clocks from the board's 50 MHz oscillator
    a2_mem_port_arb_safe.sv         memory arbiter that never drops a request
    mem_port_axi_async.sv           core memory -> HP2 AXI (DDR3) across clocks
    axi_spi_master.sv               SPI master the Linux side drives (AXI-Lite, UIO)
    tmds_oserdes10.sv               HDMI serializers
    generated/                      bus binding wrappers
  vivado/
    build.tcl          full build from the Xillinux kit
    rebuild.tcl        re-run synthesis + implementation in an existing project
    sources.tcl        the HDL file list
    constraints/       pins (smart_zynq_sp_a2_vectors.xdc), SPI/AXI timing, synthesis rules
    scripts/           block design patch, synthesis pre-hook
  device_tree/         PetaLinux-style fragment (the real DTB is generated by tools/merge_dtb.py)
  src/
    a2hostd/           the Linux service, C++14 (Makefile and CMake)
    systemd/           a2hostd.service
  tools/
    build_a2hostd.sh   cross-compile a2hostd (static ARM binary)
    merge_dtb.py       make the A2ZYNQ device tree from the Xillinux one
    write_sd_card.sh   build and write a bootable SD card
    update_menu_code.py   reassemble the 6502 disk menu, refresh a2hostd's copy
    update_hdd_rom.py     reassemble the hard disk firmware (needs ACME)
  docs/                how the port works inside
  TODO.md              what's left
```

## Documentation

| Document | What's in it |
|----------|--------------|
| [docs/USER_GUIDE.md](../../docs/USER_GUIDE.md) | Every card, with examples you can type in |
| [docs/spi-host-interface.md](docs/spi-host-interface.md) | The SPI protocol, registers and memory spaces `a2hostd` uses |
| [docs/storage.md](docs/storage.md) | How floppy tracks and hard disk blocks move, and the write-path fixes |
| [docs/serial-over-network.md](docs/serial-over-network.md) | The SSC network bridge, FPGA and Linux sides |
| [docs/power.md](docs/power.md) | Powering the board, and running it from the Apple's +5V safely |
| [docs/lessons-learned.md](docs/lessons-learned.md) | The bugs, the measurements, and what I'd tell myself at the start |
| [TODO.md](TODO.md) | Open items |
| [docs/core/](../../docs/core/) | The A2FPGA core documentation |
