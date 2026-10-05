# TODO: a2n20v2-SmartZynq

What's done, what's next, and things I've decided to leave for later.
Newest notes at the top of each section.

## Next up

- [ ] **Test the SSC network bridge on the real Apple.** It passes in
      simulation (`tests/bus_timing/run.sh sscnet`) and the board side is
      deployed. Still to do: `PR#2` / `IN#2` with `nc <board-ip> 6551`, a
      BASIC listing saved to a file on the PC, and a program pasted in with
      `ssc_cr_delay_ms=150`. Then try a real terminal program on the Apple.
- [ ] **Power from the Apple's +5V**, with a Schottky (or ideal diode) in the
      line, after measuring the board's current on USB. See
      [docs/power.md](docs/power.md). Update the wiring notes when done.

## Later / ideas

- [ ] Board security. FTP, the telnet console and the serial bridge have no
      passwords, and stock Xillinux runs printer and name discovery services
      (cups-browsed, avahi) that nothing here uses. Fine on my home network,
      but worth doing before it goes anywhere else: turn off the unused
      services, add an optional password file for FTP and telnet, and a
      simple firewall that only allows the LAN.
- [ ] A small web page on the board for uploading disks and changing settings
      from a browser, instead of FTP and editing `settings.ini`.
- [ ] `.woz` image support in `a2hostd` (copy-protected originals).
- [ ] A prebuilt release: bitstream + `a2hostd` + a ready-to-write SD image,
      so people without Vivado can try it. (The SD image includes Xillinux, so
      check Xillybus's terms first.)
- [ ] Try the IIgs. M2SEL and M2B0 are wired on the card, and the core
      supports it upstream, but I don't have one to test. Needs
      `DIP4_IIGS_MODE = 1` in `hdl/top.sv` first (switch 4 hides the debug
      numbers on this build).
- [ ] Try an enhanced IIe and a II+.
- [ ] Recovery from a crashed 6502. The card's /RES output doesn't reliably
      restart a CPU that hit a JAM opcode, and /INH never worked on this card.
      Look into whether that's the open-collector stage or the timing.
- [ ] Get TELNET65 and other 80-column software readable on a 40-column IIe
      (or just get an 80-column card).
- [ ] Fix the one critical warning in the build: `smart_zynq_sp_a2_vectors.xdc`
      wraps its false paths for the Apple bus ports in an `if`, which XDC
      files don't support, so those false paths are never applied. Timing
      passes without them (the bus is asynchronous anyway), but the warning
      should go: move them into a `.tcl` constraint file or drop the `if`.
- [ ] Clean up the debug registers and the bus capture commands in `a2hostd`
      once nothing needs them.

## Done

- [x] The hard disk never boots by itself: its firmware no longer carries the
      power-up scan's `$3C` byte, so the IIe always reaches the Disk II and
      the menu, whatever slot the hard disk is in (it autobooted Total Replay
      with the card in slots 4 and 5). Hard disk images are picked in the menu
      (RETURN = hard disk 1 and boot, TAB = hard disk 2) and remembered.
- [x] Fixed the hard disk firmware jumping to `$C500` when it had no disk:
      with the card in slot 4 that's the Mockingboard (Ctrl-Open Apple-Reset
      ended at `C505-` in the monitor). It now runs the IIe's own boot scan.
- [x] After an Apple reset, a2hostd no longer drops the hard disk's mounted
      bit or re-runs the slot setup while the boot scan reads the cards.
- [x] DIP switch 3 = Power-on-Reset hold, as on the original A2N20v2 (ON = the
      Apple waits in reset after power-on until `a2hostd` has set up the
      cards; OFF = it starts right away). Read live.
- [x] DIP switch 4 hides the HDMI debug numbers (live). IIgs mode, which
      upstream puts on switch 4, is kept behind `DIP4_IIGS_MODE` in
      `hdl/top.sv`. FPGA pull-ups on all four switch pins, so OFF or unwired
      switches read as off.
- [x] SSC network bridge: 6551 serial line to TCP 6551, FPGA bridge with
      512-byte FIFOs, `a2hostd` listener, CR pause setting. (Status moved out
      of register `0x7F`, which is the XFER opcode.)
- [x] Card test disk for slots 2-7: **0 failed** on the real IIe, including an
      8 KB floppy file write and a hard disk block write.
- [x] Floppy saves read the drive's own track copy (SPI space 6).
- [x] Disk II write head stores one nibble per access (was two).
- [x] Hard disk blocks go straight to the sector buffer (SPI space 7).
- [x] Card in slot 1: power-up goes to BASIC, `PR#6` brings up the menu.
- [x] ESC in the menu exits to BASIC without booting.
- [x] Menu title: `SLOT n DISK MENU` in slots 4-7, `SLOT n MENU` in slots 1-3.
- [x] Disk II follows the card's physical slot; slots 1-3 use slot 6.
- [x] Board KEY1/KEY2 swap disks mid-game, with a notice line on HDMI. (A
      keyboard hotkey was tried and dropped: the game sees the key too.)
- [x] Uthernet II: W5100 address increment moved to the end of the access
      (fixed IP65 DHCP). DATE65, HFS65 and ping work.
- [x] Hires video moved to block RAM (DDR shadow was painting neighbour
      bytes).
- [x] Disk menu with folders, letter jump, drive 2, last-booted memory.
- [x] Disk II boot on the real IIe (after replacing the TXB0108/TXS0108E with
      an SN74LVC245A).
- [x] SPI master: last-bit race fixed.
- [x] Port from Gowin to Xilinx: clocks, HDMI serializers, tri-states,
      memories; SDRAM replaced by DDR3 over HP2; BL616 replaced by `a2hostd`.
