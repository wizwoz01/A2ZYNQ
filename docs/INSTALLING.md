# Installing A2ZYNQ

How to get from a built bitstream and `a2hostd` to a Smart Zynq that runs
your Apple: the SD card, first boot, putting disk images on it, and updating
it later. If you haven't built anything yet, start with
[BUILDING.md](BUILDING.md).

## What ends up where

The Smart Zynq boots everything from its microSD card:

| Partition | Contents |
|-----------|----------|
| 1 (FAT) | `boot.bin` (from the Xillinux kit), `devicetree.dtb` (A2ZYNQ), `xillydemo.bit` (the A2ZYNQ bitstream), `uImage` (the Xillinux kernel) |
| 2 (ext4) | Xillinux (Ubuntu 16.04), plus: |
| | `/usr/local/sbin/a2hostd` (the service) |
| | `/etc/systemd/system/a2hostd.service` (starts it at boot) |
| | `/etc/modules-load.d/a2-uio.conf` (loads the UIO driver) |
| | `/media/a2/` (**your disk images**) |
| | `/var/lib/a2host/settings.ini` (settings, created on first run) |

At power-on, `boot.bin` loads the bitstream into the FPGA and starts the
kernel; systemd then starts `a2hostd`, which finds the FPGA through UIO,
sets up the cards, and lets the Apple out of reset.

## 1. Write a new SD card

You need, all on a Linux PC:

- the Xillinux kit in `third_party/` (see [third_party/README.md](../third_party/README.md)),
- the Xillinux SD image, `xillinux-2.0a.img.gz` from xillybus.com, in
  `third_party/` (or set `A2ZYNQ_XILLINUX_IMG`),
- `boards/a2n20v2-SmartZynq/build/xillydemo.bit` and
  `boards/a2n20v2-SmartZynq/build/a2hostd` ([BUILDING.md](BUILDING.md)),
- a microSD card of 4 GB or more (everything on it will be erased),
- `udisksctl` (standard on Ubuntu desktops), `sudo`, `dtc`.

Find the card's device name. Plug it in and look for it:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN
```

It'll be something like `/dev/sdb` (USB reader) or `/dev/mmcblk0` (built-in
reader). **Make sure it's the SD card and not one of your disks.** Then:

```bash
boards/a2n20v2-SmartZynq/tools/write_sd_card.sh /dev/sdX
```

The script:

1. builds the device tree from the kit's stock one,
2. copies the Xillinux image to `boards/a2n20v2-SmartZynq/build/a2zynq-sd.img`
   (3.6 GB, done once and reused),
3. puts `boot.bin`, `devicetree.dtb` and `xillydemo.bit` on the image's FAT
   partition,
4. installs `a2hostd`, its service and the UIO module list on the root
   partition (this part asks for your sudo password),
5. shows you the target disk and asks you to type its name again,
6. writes the image with `dd` and ejects the card.

It refuses to write the disk your PC is running from, and anything smaller
than 4 GB.

## 2. Put some disk images on it

You can copy images onto the card's root partition right away (into
`/media/a2`, with sudo, while it's still in the PC), but it's easier to do
it over the network once the board is running ([step 4](#4-copy-disk-images-over-ftp)).

Good things to start with:

- a DOS 3.3 system master or any `.dsk` game you own,
- [Total Replay](https://github.com/a2-4am/4cade) as `hdd1.hdv` (hundreds of
  games on one hard disk image, runs on a 64K IIe),
- the card test disk from [tests/cardtest](../tests/README.md#cardtest-the-apple-side-test).

## 3. First boot

1. **Everything off.** Plug the proto card into the Apple (slot 1 is how I
   run it; see the [slot map](../boards/a2n20v2-SmartZynq/README.md#slot-map)),
   connect both ribbon cables and the ground bundle, HDMI and Ethernet. Set
   DIP switch 3 (Power-on-Reset hold) ON, and the others OFF for now; see the
   [DIP switch table](../boards/a2n20v2-SmartZynq/README.md#dip-switches).
2. Put the SD card in the Smart Zynq.
3. Connect the board's **UART/JTAG** USB-C socket to your PC and open a
   terminal at 115200 baud (`picocom -b 115200 /dev/ttyUSB1` on Linux; the
   board shows up as two ports, the console is the second one). This also
   powers the board.
4. Watch it boot. After about 40 seconds you get a root prompt, and
   ```bash
   systemctl status a2hostd
   journalctl -u a2hostd -n 30
   ```
   should show `a2hostd` running, the cards set up and the FPGA's build date.
5. The HDMI screen shows the Apple picture area with a status line at the top.
6. **Switch the Apple on.** With the card in slot 1 you get `Apple ][` and
   `]`; type `PR#6` for the disk menu. In other slots the menu comes up by
   itself.

Find the board's IP address (you'll need it for FTP and the serial bridge):

```bash
ip addr show eth0
```

## 4. Copy disk images over FTP

`a2hostd` has an FTP server with its root at `/media/a2`. Any user name, no
password:

```bash
curl -T "Oregon Trail.dsk" "ftp://<board-ip>/Oregon%20Trail.dsk" --user a2:
curl -T Total.Replay.hdv   "ftp://<board-ip>/hdd1.hdv"            --user a2:
curl ftp://<board-ip>/ --user a2: -Q "MKD Games"
```

Or drag and drop in Windows Explorer (`ftp://<board-ip>/`) or FileZilla.
Floppies show up the next time the menu opens; hard disks after the next
board restart (Apple off).

## 5. Updating a running board

When you've built a new bitstream or `a2hostd`, you don't need a new SD card.
**Switch the Apple off first.**

Upload the files over FTP:

```bash
curl -T boards/a2n20v2-SmartZynq/build/xillydemo.bit ftp://<board-ip>/xillydemo.bit --user a2:
curl -T boards/a2n20v2-SmartZynq/build/a2hostd       ftp://<board-ip>/a2hostd       --user a2:
```

Then, on the board's serial console:

```bash
# keep the old versions, just in case
mount /dev/mmcblk0p1 /mnt
\cp /mnt/xillydemo.bit /root/xillydemo.bit.prev
\cp /usr/local/sbin/a2hostd /root/a2hostd.prev

# new bitstream (loaded at the next boot)
\cp /media/a2/xillydemo.bit /mnt/xillydemo.bit && sync
umount /mnt

# new a2hostd (a running program can't be overwritten, so copy and rename)
systemctl stop a2hostd
\cp /media/a2/a2hostd /usr/local/sbin/a2hostd.new
chmod 755 /usr/local/sbin/a2hostd.new
mv /usr/local/sbin/a2hostd.new /usr/local/sbin/a2hostd

rm /media/a2/xillydemo.bit /media/a2/a2hostd
reboot
```

(The backslash in `\cp` skips Xillinux's `cp -i` alias, which would
otherwise ask before every overwrite.)

If you only changed `a2hostd`, you can skip the bitstream part and use
`systemctl start a2hostd` instead of rebooting. Check that it came up with
`journalctl -u a2hostd -n 30`, then switch the Apple on.

To go back to the old version, copy the `.prev` files back the same way.

### Without a network

If the board isn't on your network, `tools/board_push.py` sends a file over
the serial console (compressed, checked with md5). It's slow, about a minute
per megabyte, but it needs nothing but the USB cable:

```bash
python3 tools/board_push.py boards/a2n20v2-SmartZynq/build/a2hostd /root/a2hostd.new
```

Close any terminal program that has the port open first. See
[tools/README.md](../tools/README.md).

## Rules worth repeating

- **Restart `a2hostd` only with the Apple off.** While it restarts the card
  stops answering and a running Apple crashes.
- **Never plug or unplug the card or the ribbon cables with power on**, on
  either side.
- **Don't connect the Apple's +5V to the board's 5V** without a diode; see
  [power.md](../boards/a2n20v2-SmartZynq/docs/power.md).
- `settings.ini` is rewritten by `a2hostd`, so only edit it while `a2hostd`
  is stopped.
