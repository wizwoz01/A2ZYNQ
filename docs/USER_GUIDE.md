# A2ZYNQ user guide

How to use every card A2ZYNQ provides, with examples you can type in. I wrote
this for my own unenhanced Apple IIe (6502, 64K, no 80-column card), so
everything here works on the most basic IIe. If you have more machine than
that, more software will work.

The card plugs into one slot but gives you seven peripheral cards. It watches
the whole Apple bus and answers for the empty slots; the Linux side of the
Smart Zynq (`a2hostd`) serves the disk images, the network and the serial
port.

Throughout this guide, `<board-ip>` is the Smart Zynq's address on your
network (find it in your router's client list, or type `ip addr show eth0`
on the board's serial console).

## Contents

1. [Slots at a glance](#1-slots-at-a-glance)
2. [Everyday use: power-up, the disk menu, BASIC](#2-everyday-use-power-up-the-disk-menu-basic)
3. [Disk II (two 5.25" drives) and the disk menu](#3-disk-ii-two-525-drives-and-the-disk-menu)
4. [ProDOS hard disk and Total Replay](#4-prodos-hard-disk-and-total-replay)
5. [Super Serial Card (slot 2), over the network](#5-super-serial-card-slot-2-over-the-network)
6. [Uthernet II (slot 3), the network card](#6-uthernet-ii-slot-3-the-network-card)
7. [Mockingboard (slot 4)](#7-mockingboard-slot-4)
8. [SuperSprite (slot 7)](#8-supersprite-slot-7)
9. [The Smart Zynq board: HDMI, buttons, files, settings](#9-the-smart-zynq-board-hdmi-buttons-files-settings)
10. [Power](#10-power)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Slots at a glance

With the card in slot 1 (how I run it):

| Slot | Card | What it gives you |
|------|------|-------------------|
| 1 | *(the physical card)* | nothing virtual here |
| 2 | Super Serial Card | a serial port, reached from your PC on TCP port 6551 |
| 3 | Uthernet II | Ethernet for IP65 programs (DHCP, web, time) |
| 4 | Mockingboard | two AY-3-8910 sound chips, stereo, on the HDMI audio |
| 5 | ProDOS hard disk | two drives up to 32 MB each |
| 6 | Disk II + disk menu | two 5.25" drives fed from the board's SD card |
| 7 | SuperSprite | TMS9918 graphics over the Apple picture, plus sound |

Slots 2, 3, 4 and 7 never move. The Disk II follows the card:

| Card in slot | Disk II | Hard disk | Moves to slot 5 | At power-up you get |
|--------------|---------|-----------|-----------------|---------------------|
| 1 | 6 | 5 | - | BASIC `]` (`PR#6` = menu) |
| 2 or 3 | 6 | 5 | - | the menu, titled `SLOT 2 MENU` / `SLOT 3 MENU` |
| 4 | 4 | 6 | Mockingboard | `SLOT 4 DISK MENU` |
| 5 | 5 | 6 | - | `SLOT 5 DISK MENU` |
| 6 | 6 | 5 | - | `SLOT 6 DISK MENU` |
| 7 | 7 | 6 | SuperSprite | `SLOT 7 DISK MENU` |

**Always switch the Apple off and unplug the board before moving the card.**

---

## 2. Everyday use: power-up, the disk menu, BASIC

**Power-up order:** power the board first (USB-C), wait for the HDMI picture
(about 40 seconds after a cold start), then switch the Apple on. With DIP switch 3 ON
(the usual setting) the board holds the Apple in reset until it's ready, so
switching the Apple on early is harmless; you just wait a bit longer.

With the card in slot 1 the IIe starts like a IIe with no disk drive:
`Apple ][` and the BASIC prompt `]`. From there:

| Type | What happens |
|------|--------------|
| `PR#6` | open the disk menu (Disk II in slot 6) and boot a floppy or a hard disk |
| `PR#5` | boot hard disk 1 directly (whatever was last picked in the menu, e.g. Total Replay) |
| `PR#2` | send everything printed to the serial port (your PC). `PR#0` = back |
| `IN#2` | take keyboard input from the serial port (your PC). `IN#0` = back |

In any other slot, the menu comes up by itself at power-up. The hard disk
never boots on its own, in any slot: you pick it in the menu (or type `PR#5`).

Restarting:

| Keys | What happens |
|------|--------------|
| Ctrl-Reset | stop the running program (usually back to BASIC) |
| Ctrl-Open Apple-Reset | full restart, as if switched off and on: back to the menu (BASIC with the card in slot 1) |

---

## 3. Disk II (two 5.25" drives) and the disk menu

### How it works

Two virtual 5.25" drives. Disk images live on the board's SD card in the
folder `/media/a2`. When the Apple moves the head to a track, `a2hostd` reads
that track from the image and hands it to the FPGA. When the Apple writes,
the changed track is written back into the image as soon as the drive stops
or moves to another track. Game saves and files you write are kept.

### Floppy image types

| Extension | What it is |
|-----------|------------|
| `.dsk`, `.do` | DOS 3.3 order (`.dsk` is auto-detected, ProDOS order works too) |
| `.po` | ProDOS order, 140K |
| `.nib` | raw nibbles |
| `.2mg` | 2IMG wrapper around a 140K disk |

Bigger images (`.hdv`, a big `.po`) are hard disks. They show in the same
menu with `HD` at the right: see [section 4](#4-prodos-hard-disk-and-total-replay).

### The menu

The screen lists `/media/a2`: folders first, then disks, floppies and hard
disks together (hard disks have `HD` at the right). The top four lines show
what's in floppy drives 1 and 2 and hard disks 1 and 2, and the cursor starts
on the disk you booted last. A `1` or `2` in front of a name means that disk
is in drive (or hard disk) 1 or 2.

| Key | Does |
|-----|------|
| Up / Down | move one line |
| Left / Right | page up / page down |
| `A`..`Z`, `0`..`9` | jump to the next entry starting with that character |
| `RETURN` | boot it: a floppy from drive 1, a hard disk from hard disk 1 (or open the folder; `..` goes back up) |
| `TAB` | put it in drive 2 (floppy) or hard disk 2 (hard disk), stay in the menu; on the disk already there, take it out |
| `ESC` | leave the menu, boot nothing (BASIC prompt) |

Make folders in `/media/a2` (over FTP, [section 9](#9-the-smart-zynq-board-hdmi-buttons-files-settings))
to sort your disks, for example `Games`, `Utilities`, `Ultima`.

### Multi-disk games (board buttons)

**KEY1** on the Smart Zynq puts the **next** disk of the set into drive 1,
**KEY2** the **previous** one. The disk's name appears on the HDMI picture
for 4 seconds. A "set" is the disks in the same folder whose names differ
only at the end (`ultima31.dsk` / `ultima32.dsk`, `OREGON_A` / `OREGON_B`,
`... Disk 1 of 3`).

**Example: Ultima III**

1. `PR#6`, pick `ultima31.dsk`, `RETURN`.
2. When the game asks for the Player disk, press **KEY1** on the board. The
   HDMI line says `DRIVE 1: ULTIMA32.DSK`. Press `RETURN` or space in the
   game as it asks.
3. When it wants disk 1 back, press **KEY2**.

**Example: a data disk in drive 2 (DOS 3.3)**

In the menu, put your data disk in drive 2 with `TAB`, then boot a DOS 3.3
disk with `RETURN`. At the prompt:

```
]CATALOG,D2
]RUN MYPROG,D2
```

**Example: DOS 3.3 programming**

```
]10 PRINT "HELLO"
]SAVE HELLO          (writes into the disk image on the SD card)
]CATALOG
]RUN HELLO
```

**Example: ProDOS (BASIC.SYSTEM)**

```
]CAT                 list the current folder
]PREFIX /HDTEST      switch to another volume (here, a hard disk)
]-PROGRAM.SYSTEM     run a system program
```

Settings ([section 9](#9-the-smart-zynq-board-hdmi-buttons-files-settings)):
`disk_menu=0` turns the menu off, `disk_menu_timeout=10` boots drive 1 after
10 seconds without a key, `disk_slot=6` keeps the Disk II in slot 6.

---

## 4. ProDOS hard disk and Total Replay

### How it works

A ProDOS block device with two drives. Each drive is one image file of up to
32 MB (65,535 blocks, the ProDOS limit). Blocks go straight between the image
and the card's 512-byte buffer. ProDOS sees it as "slot 5, drive 1" and "slot
5, drive 2" (slot 6 if the card is in slot 4, 5 or 7).

### Picking and booting a hard disk

Hard disk images live in `/media/a2` (any folder) next to the floppies and
show in the disk menu with `HD` at the right:

- **RETURN** on a hard disk image puts it in hard disk 1 and boots it.
- **TAB** puts it in hard disk 2 without booting (a data volume next to the
  boot volume). TAB on the one already in hard disk 2 takes it out.
- `PR#5` from BASIC boots whatever is in hard disk 1.

The hard disk **never boots by itself** at power-up or after Ctrl-Open
Apple-Reset, whatever slot it's in; you always get the menu first. The board
remembers your picks and mounts them again when it starts, so a ProDOS floppy
sees the same volumes. A `.po` of exactly 140K is a floppy; any other `.po`
(800K disks included) is a hard disk. New images uploaded over FTP show up
the next time the menu opens.

### Total Replay: hundreds of Apple II games on one disk

[Total Replay](https://github.com/a2-4am/4cade) by 4am and qkumba is free.
Download `Total.Replay.hdv` from its releases and upload it to `/media/a2`. It
checks your machine at start: games that need 128K or a joystick are hidden
on a 64K IIe without a joystick.

| | |
|--|--|
| Boot | pick `Total.Replay.hdv` in the disk menu (RETURN), or `PR#5` once it's hard disk 1 |
| Type letters | find a game (`ka` finds Karateka) |
| `<` `>` or arrows | browse |
| `RETURN` | play the game shown |
| Space | watch a preview |
| `ESC` | back / screensaver |
| Ctrl-Reset | quit a game, back to the list |
| Ctrl-C | cheat mode (if the game has one) |
| Ctrl-P | joystick setup |

### Other hard disk images

Any ProDOS-order image works: `.hdv`, `.po`, `.2mg`. On an unenhanced IIe,
check that it runs on a 64K 6502 machine with 40 columns first (ProDOS 8
2.0.x and many newer programs need an enhanced IIe).

---

## 5. Super Serial Card (slot 2), over the network

### How it works

The card's 6551 serial chip works exactly like the real one. Instead of a
cable, its serial line goes to the board, and the board offers it on your
network at **`<board-ip>`, TCP port 6551**.

Whatever your PC sends to that port arrives in the Apple as if it came in on
the serial port, and whatever the Apple sends comes out on the PC. The baud
rate only matters on the Apple side; the PC side is plain bytes, so you never
set a baud rate on the PC. The default is 9600 baud, 8 data bits, no parity
(the usual SSC setting); programs can change it.

One PC connection at a time; a new one replaces the old. There's no
password: anyone on your home network can connect, so keep it off the
internet.

### Connecting from the PC

```bash
# Linux / macOS, simple (sends a line when you press Enter):
nc <board-ip> 6551

# Linux / macOS, every key sent immediately (exit with Ctrl-]):
socat -,raw,echo=0,escape=0x1d TCP:<board-ip>:6551
```

Windows: PuTTY, connection type "Raw", host `<board-ip>`, port `6551`.

The Apple ends lines with CR only. If lines overwrite each other on the PC,
pipe the output through `tr '\r' '\n'`.

### Example 1: print from the Apple to the PC

```
PC:      nc <board-ip> 6551
Apple:   ]PR#2
         ]PRINT "HELLO FROM THE APPLE IIE"
         ]PR#0
```

The text appears on the PC.

### Example 2: save a BASIC listing as a file on the PC

```
PC:      nc <board-ip> 6551 | tr '\r' '\n' > listing.txt
Apple:   ]LOAD MYPROG        (or type a program)
         ]PR#2
         ]LIST
         ]PR#0
```

Press Ctrl-C on the PC when the listing is done; `listing.txt` has it.

### Example 3: type into the Apple from the PC

```
Apple:   ]IN#2
PC:      nc <board-ip> 6551      then type  PRINT 2+2  and Enter
```

The Apple runs it as if typed on its keyboard. To go back, type `IN#0` on
the PC while `IN#2` is active, or press Ctrl-Reset on the Apple.

### Example 4: send a whole BASIC program from the PC

The Apple needs a moment after each line, so turn on the pause after each
carriage return in the settings ([section 9](#9-the-smart-zynq-board-hdmi-buttons-files-settings)):
`ssc_cr_delay_ms=150`. Then:

```
PC:      tr '\n' '\r' < prog.bas > prog.cr          (CR line ends)
Apple:   ]NEW
         ]IN#2
PC:      (cat prog.cr; sleep 2) | nc <board-ip> 6551
Apple:   type IN#0 (or Ctrl-Reset), then LIST / RUN / SAVE
```

### Example 5: the Apple as a terminal for a telnet BBS

Bridge the Apple's serial port to a BBS from the PC:

```bash
socat TCP:<board-ip>:6551 TCP:bbs.example.com:23
```

and run a 40-column terminal program on the Apple, set to the SSC in slot 2.

### Example 6: ADTPro

ADTPro's PC server talks to a serial port. On Linux, make a virtual one that
ends at the Apple:

```bash
socat pty,link=$HOME/ttyA2,raw,echo=0 TCP:<board-ip>:6551
```

and point ADTPro at `~/ttyA2`. For just moving disk images, the board's FTP
is simpler ([section 9](#9-the-smart-zynq-board-hdmi-buttons-files-settings)).

Settings: `ssc_port=6551` (`0` turns it off), `ssc_cr_delay_ms` (default 0).

---

## 6. Uthernet II (slot 3), the network card

### How it works

A WIZnet W5100 network chip in "raw Ethernet" mode. The Apple's network
frames go out of the board's Ethernet port as if the Apple had its own
cable: the Apple gets its own address from your router (DHCP), separate from
the board's. IP65 programs use the MAC address `00:08:DC:A2:A2:A2`.

It works with programs that bring their own TCP/IP stack (IP65). Programs
that use the chip's own TCP/UDP "hardware sockets" (like WGET65) don't work.
Contiki and the official IP65 C programs are built for the 65C02 and lock up
an unenhanced IIe.

### A 6502 network test disk

The IP65 releases build their C apps for the enhanced IIe. I rebuilt the two
I use for the plain 6502 with cc65:

```bash
cl65 -t apple2 -C apple2-system.cfg apple2-iobuf-0800.o -D __APPLE2_SYS__ ...
```

and put them on a ProDOS disk ("IP65 Net Tools (6502).dsk") with
`tools/prodos_disk.py`. Boot it from the menu, then at `]`:

| Program | What it does |
|---------|--------------|
| `-DATE65.SYSTEM` | gets an address by DHCP, looks up a time server, shows the date and time. The quickest "is the network working" test |
| `-HFS65.SYSTEM` | a web server: the Apple shows `Starting server on 192.168.x.y`. Open that address in a browser on your PC to browse and download the files on the Apple's disks. Each request is listed on the Apple's screen. One browser tab at a time; if it gets stuck, Ctrl-Reset and start again. Pages are sent without HTTP headers, so with curl use `curl --http0.9` |
| `-TELNET65` | a telnet client. Needs an 80-column card, so on a plain IIe only every second character is visible |

From the PC you can also `ping` the Apple's address while one of them runs.

---

## 7. Mockingboard (slot 4)

### How it works

Two AY-3-8910 sound chips, each driven by a 6522 interface chip: the left
pair at `$C400`, the right pair at `$C480`. Each chip has 3 tone channels
plus noise and an envelope; together they give stereo on the HDMI audio. (The
speech chip of some Mockingboard models isn't included.)

### Using it

Games and demos that support the Mockingboard look for it in slot 4 (the
usual place) and play much richer music and sound with it. Ultima III, IV and
V are well-known examples. If a game asks which slot, answer 4.

### Example: play a scale from BASIC

```basic
10 B = 49152 + 4 * 256 : REM $C400 = LEFT CHIP (RIGHT CHIP IS B + 128)
20 POKE B + 3,255 : POKE B + 2,7 : REM PORT A OUT, PORT B LINES 0-2 OUT
30 POKE B,0 : POKE B,4 : REM RESET THE AY CHIP
40 R = 7 : V = 62 : GOSUB 100 : REM MIXER: TONE ON CHANNEL A ONLY
50 R = 8 : V = 15 : GOSUB 100 : REM CHANNEL A VOLUME (0-15)
60 FOR N = 1 TO 8 : READ P : R = 0 : V = P : GOSUB 100
65 R = 1 : V = 0 : GOSUB 100 : FOR D = 1 TO 300 : NEXT D : NEXT N
70 R = 8 : V = 0 : GOSUB 100 : END
80 DATA 244,217,193,183,163,145,129,122 : REM C D E F G A B C
100 POKE B + 1,R : POKE B,7 : POKE B,4 : POKE B + 1,V : POKE B,6 : POKE B,4
110 RETURN
```

Line 100 writes value V into AY register R. The 6522's port B pulses the
chip's control lines: 7 = latch the register number, 6 = write, 4 = idle.

| AY registers | |
|--------------|--|
| 0-1 | tone A period |
| 2-3 | tone B period |
| 4-5 | tone C period |
| 6 | noise period |
| 7 | mixer |
| 8-10 | volumes A-C |
| 11-13 | envelope |

Tone period = 1023000 / 16 / frequency. Change B to `49152 + 4 * 256 + 128`
to hear it on the right.

---

## 8. SuperSprite (slot 7)

### How it works

A TMS9918A video chip (the one in the ColecoVision and MSX) with its own 16K
of video memory, plus an AY-3-8910 sound chip. Its picture is mixed over the
Apple's on HDMI: its transparent pixels let the Apple screen show through.

| Port (slot 7) | |
|---------------|--|
| `$C0F0` | video data |
| `$C0F1` | video register / address / status |
| `$C0F5` | Apple picture only |
| `$C0F6` | mix the sprite picture over the Apple |
| `$C0FE` | sound: select register / read it |
| `$C0FC` | sound: write value |

(The speech chip of the original card isn't included.)

### Using it

Software written for the Synetix SuperSprite or Ciarcia's EZ-Color card.

### Example: a green box over the Apple screen from BASIC

The video chip takes two-byte commands, and Applesoft's `POKE` reads the
address before writing it (a 6502 quirk), which would spoil them. So two tiny
machine-code helpers do the writes: `CALL 768` sends `PEEK(6)` to `$C0F1`,
`CALL 774` sends it to `$C0F0`.

```basic
10 FOR I = 768 TO 779 : READ X : POKE I,X : NEXT
20 DATA 165,6,141,241,192,96,165,6,141,240,192,96
30 R = 1 : V = 128 : GOSUB 100 : REM DISPLAY OFF WHILE SETTING UP
40 R = 0 : V = 0 : GOSUB 100 : R = 2 : V = 14 : GOSUB 100 : R = 3 : V = 128 : GOSUB 100
45 R = 4 : V = 0 : GOSUB 100 : R = 5 : V = 118 : GOSUB 100 : R = 7 : V = 0 : GOSUB 100
50 A = 0 : GOSUB 200 : FOR I = 1 TO 16 : D = 255 * (I > 8) : GOSUB 300 : NEXT
60 A = 8192 : GOSUB 200 : FOR I = 1 TO 32 : D = 48 : GOSUB 300 : NEXT
70 A = 15104 : GOSUB 200 : D = 208 : GOSUB 300
80 A = 14336 : GOSUB 200 : FOR Y = 0 TO 23 : FOR X = 0 TO 31
85 D = (Y > 7 AND Y < 16 AND X > 7 AND X < 24) : GOSUB 300 : NEXT X,Y
90 POKE 49398,0 : R = 1 : V = 192 : GOSUB 100 : REM MIX ON, DISPLAY ON
95 END
100 POKE 6,V : CALL 768 : POKE 6,128 + R : CALL 768 : RETURN
200 POKE 6,A - INT (A / 256) * 256 : CALL 768 : POKE 6,64 + INT (A / 256) : CALL 768 : RETURN
300 POKE 6,D : CALL 774 : RETURN
```

Line 100 sets video register R to V; 200 starts writing video memory at
address A; 300 writes byte D. Pattern 1 is a solid block, colour 48 is light
green on transparent, and the name table at 14336 places the block. To remove
it:

```basic
R = 1 : V = 128 : GOSUB 100 : POKE 49397,0
```

If the card is in slot 7, the SuperSprite moves to slot 5: in line 20 use
`209,192` and `208,192` instead of `241,192` and `240,192`, and `49366` /
`49365` instead of `49398` / `49397`.

---

## 9. The Smart Zynq board: HDMI, buttons, files, settings

### HDMI

The Apple picture, regenerated, plus the speaker, Mockingboard and
SuperSprite sound. The top line shows the bitstream's build date (like
`20261002030000`) and a few debug values. DIP switch 4 ON hides them. The line under the picture shows
disk swaps (KEY1 / KEY2).

### Buttons

KEY1 = next disk of the set into drive 1, KEY2 = previous
([section 3](#multi-disk-games-board-buttons)).

### DIP switches (on the proto card)

| Switch | ON means |
|--------|----------|
| 1 | scanlines on HDMI (read when the board starts) |
| 2 | Apple speaker on the HDMI audio (read when the board starts) |
| 3 | Power-on-Reset hold: the Apple waits in reset after power-on until the board is ready (keep it ON) |
| 4 | hide the debug numbers along the top of the HDMI picture (works right away) |

A switch that's OFF, or not wired, counts as off. On the original A2N20v2,
switch 4 selects Apple IIgs mode; here it hides the debug numbers instead,
since one switch can't do both. The details, and how to get IIgs mode back,
are in the [board README](../boards/a2n20v2-SmartZynq/README.md#dip-switches).

### Files from your PC (FTP, no password, any user name)

Windows Explorer or FileZilla: `ftp://<board-ip>/`

Linux / macOS with curl:

```bash
curl ftp://<board-ip>/ --user a2:                                        # list
curl -T "Game.dsk" "ftp://<board-ip>/Game.dsk" --user a2:                # upload
curl "ftp://<board-ip>/Game.dsk" --user a2: -o Game.dsk                  # download
curl ftp://<board-ip>/ --user a2: -Q "DELE Game.dsk"                     # delete
curl ftp://<board-ip>/ --user a2: -Q "RNFR old.dsk" -Q "RNTO new.dsk"    # rename
curl ftp://<board-ip>/ --user a2: -Q "MKD Games"                         # new folder
```

A space in a name is `%20` in the URL. New floppies show in the menu the next
time it opens; hard disk images need a board restart
([section 4](#4-prodos-hard-disk-and-total-replay)).

### Console (for settings and logs)

The board's USB-C socket marked UART/JTAG (not the OTG one) is a serial
console at 115200 baud (Linux: usually `/dev/ttyUSB1`, the second of the two
ports; Windows: the higher-numbered COM port in PuTTY). You're logged in as
root.

```bash
journalctl -u a2hostd -f        # watch what the board is doing (Ctrl-C ends)
systemctl restart a2hostd       # restart it (only with the Apple OFF)
```

### Settings

`/var/lib/a2host/settings.ini`, one `name=value` per line. `a2hostd`
rewrites this file, so change it only while it's stopped, with the Apple off:

```bash
systemctl stop a2hostd
vi /var/lib/a2host/settings.ini        # or: echo "ssc_cr_delay_ms=150" >> /var/lib/a2host/settings.ini
systemctl start a2hostd
```

| Setting | |
|---------|--|
| `disk_menu=0` | no disk menu (boots drive 1 like a plain Disk II) |
| `disk_menu_timeout=N` | boot drive 1 after N seconds without a key |
| `disk_slot=4..7` | keep the Disk II in that slot (default: follow the card) |
| `ssc_port=6551` | serial port TCP number (`0` = off) |
| `ssc_cr_delay_ms=0` | pause after each CR sent to the Apple |
| `ftp_port`, `telnet_port` | board services (21 / 23) |
| `bus_*` | bus timing, don't change |

Network services on the board: FTP (21), a small command console over telnet
(23: `status`, `rescan`, `fpga`), and the serial card (6551). None has a
password; keep them on your home network.

---

## 10. Power

Today the board runs on USB-C and the Apple on its own supply, with only the
grounds connected. That's the safe setup, and what the
[proto card wiring notes](../hardware/RED_PROTO_CARD_WIRING.md) call for.

Running the board from the Apple's +5V is possible, but only with a Schottky
diode (or an ideal-diode module) in the line, after checking the board's
current and the voltage under load. Without the diode, a USB charger plugged
into the board would try to power the whole Apple when the Apple is off. The
details are in
[boards/a2n20v2-SmartZynq/docs/power.md](../boards/a2n20v2-SmartZynq/docs/power.md).

**Never plug or unplug the card or the ribbon cables with power on.**

---

## 11. Troubleshooting

**A program locks up right after it starts.**
It probably needs an enhanced IIe (65C02). ProDOS 8 2.0.x says "REQUIRES
ENHANCED APPLE IIE OR LATER"; Contiki and the official IP65 C programs just
freeze. Use 6502 versions.

**Every second character is missing or the text looks squashed.**
The program uses 80 columns, and the IIe has no 80-column card.

**The menu doesn't come up at power-on.**
With the card in slot 1 that's intended: type `PR#6`. In other slots, check
that `a2hostd` is running (`systemctl status a2hostd` on the console).

**A floppy change didn't stick.**
Run `CardTest.dsk` from the menu: it must end with `0 FAILED`. The board log
(`journalctl -u a2hostd`) lists every saved track.

**Checking all the cards.**
`CardTest.dsk` tests slots 2 to 7 (about 15 seconds, two tones, a green box)
and saves `CARDTEST.LOG` on its disk. How to build it is in
[tests/cardtest](../tests/README.md#cardtest-the-apple-side-test).
