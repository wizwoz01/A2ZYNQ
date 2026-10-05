# tools

Small helpers I use from the PC. Build and install scripts for the board
itself are in [boards/a2n20v2-SmartZynq/tools](../boards/a2n20v2-SmartZynq/tools/).

## Serial console helpers

For when the board isn't on the network, or you need a shell without opening
a terminal program. They talk to the board's serial console (the UART/JTAG
USB-C socket, 115200 baud) and expect the root prompt. They need
[pyserial](https://pypi.org/project/pyserial/) (`pip install pyserial`).

The port defaults to `/dev/ttyUSB1` (the console is the second of the two
ports the board's FT2232H shows up as). Set `A2ZYNQ_SERIAL` to use another
one. Close any terminal program (picocom, minicom, PuTTY) that has the port
open first.

| Script | Usage | What it does |
|--------|-------|--------------|
| `board_shell.py` | `python3 board_shell.py "command" [timeout]` | runs one shell command on the board and prints the output |
| `board_push.py` | `python3 board_push.py LOCAL_FILE REMOTE_PATH` | sends a file to the board: xz-compressed, base64, one line per prompt with echo off, checked with md5 at the end |
| `board_pull.py` | `python3 board_pull.py REMOTE_PATH LOCAL_FILE` | copies a file from the board (gzip + base64, checked with md5) |

Examples:

```bash
python3 tools/board_shell.py "systemctl status a2hostd" 5
python3 tools/board_shell.py "journalctl -u a2hostd -n 40 --no-pager" 10
python3 tools/board_push.py boards/a2n20v2-SmartZynq/build/a2hostd /root/a2hostd.new
python3 tools/board_pull.py /media/a2/CardTest.dsk CardTest.dsk
```

Speed is about a minute per megabyte, so with the network up, FTP is much
faster. `board_pull.py` uses gzip because `xz -9` runs out of memory on the
board.

## prodos_disk.py

A minimal tool for 140K ProDOS disk images (`.dsk` in DOS order, or `.po`).
I wrote it to clean up and patch disks without needing an Apple or a big
disk utility.

```bash
python3 tools/prodos_disk.py DISK.dsk list                      # catalog
python3 tools/prodos_disk.py DISK.dsk check                     # check the volume bitmap
python3 tools/prodos_disk.py DISK.dsk delete NAME [NAME...]     # delete files
python3 tools/prodos_disk.py DISK.dsk add NAME TYPE AUX FILE    # add a file
```

For `add`, TYPE and AUX are hex (`FF 2000` for a SYSTEM program loaded at
`$2000`), and FILE can be a raw binary or an AppleSingle file like the ones
cc65 writes. Only the volume directory is handled (no subdirectories), files
up to 256 blocks, and every change rewrites the image in place, so keep a
copy.

## Debugging on the board

Not a script here, but worth knowing: `a2hostd` has a small bus logic
analyzer built on the FPGA's bus event FIFO. Write commands into
`/run/a2trace.cmd` on the board (numbers in hex) and `a2hostd` picks them up:

| Command | |
|---------|--|
| `arm 0` | rolling capture of the last 512 bus cycles (`arm 1` = I/O space only) |
| `trig C0EC [mask] [mode]` | capture that freezes on the first cycle matching the address |
| `dump` | stop and write the capture to `/run/a2trace.out` |
| `rd 2E [n]` / `wr 07 05` | raw FPGA register access, results in `/run/a2reg.out` |

```bash
echo "arm 0" > /run/a2trace.cmd; sleep 1; echo dump > /run/a2trace.cmd; sleep 1; head /run/a2trace.out
```

When an Apple program "hangs", this is the first thing I look at: endless
reads of `$FFFF` returning `$FF` mean the 6502 hit an illegal opcode
(usually 65C02 code on a 6502), not a card problem.
