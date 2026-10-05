# Lessons learned

The things that cost me the most time on this port, roughly in the order I
hit them. Most of them aren't specific to the Zynq; if you're building any
Apple II card on an FPGA, a few of these might save you a week.

## 1. The level translator on the data bus

**Symptom:** the IIe wouldn't boot from the Disk II. The boot ROM ran, but
the bytes it read from the card were wrong often enough that nothing worked.
Reading a known byte over and over in a loop (`LDA $C505`) showed the
pattern: isolated 0 bits between 1s read back as 1. Values like `$BD`, `$7E`
and `$F8` were wrong 40-85% of the time, D1 and D6 were the worst bits, and
even after every timing trick I could think of in the FPGA there was a floor
of about 0.2% errors.

**What it was:** the proto card's U5 (D0-D7) was an auto-direction translator,
first a TXB0108, then a TXS0108E. Both have edge accelerators (one-shots that
speed up rising edges), and on the Apple bus, with its long traces and the
6502's weak drivers, they fire on edges that aren't really there and hold
bits high. Extra ground wires and different slots made no difference.

**Fix:** an **SN74LVC245A**, with the FPGA driving DIR and OE#. The IIe booted
Oregon Trail on the first try after the swap.

I didn't want to believe it was the chip and spent a long time on FPGA timing
first. If you see that pattern (0s reading as 1s, worst on a couple of bits),
**check the part on U5 before you touch anything else.**

## 2. Driving the bus: when to start and when to let go

With a '245 in place, the FPGA decides exactly when the card drives D0-D7.
Drive too early and you fight whatever was on the bus. Let go too late and you
fight the IIe's own video circuitry, which drives the data bus during PHI1 to
read screen memory.

The bus PHY (`rtl/a2_bus_phy.sv`) ended up with a handful of knobs, all
settable from Linux without a rebuild (registers `0x07`, `0x0D`, `0x0E`,
`0x6F`; see [spi-host-interface.md](spi-host-interface.md#bus-drive-timing)):

- a "soft landing": the data byte is presented MSB first over a few clocks
  instead of all bits switching at once,
- the write data latch opens at the commit point,
- an **early release**: the '245 turns back to receive about 45 ns into PHI1,
  well before the IIe starts driving the bus for video.

`tests/bus_timing` has simulations of the PHY (`./run.sh phy`, `./run.sh loop`)
that sweep these settings against a model of the IIe's bus timing.

## 3. The SPI bit that went missing

One bitstream lost bit 0 of every register write. Writing `0x07` read back as
`0x06`. The SPI master raised CS# on the same clock as the last bit, and
whether the slave saw the last bit depended on placement. The fix was a tail
state in `rtl/axi_spi_master.sv` and making the slave finish the last byte
even if CS# is already gone.

**Quick check after any change to the SPI path:** write odd values to register
`0x07` and read them back, and read the slot map (`0x60`-`0x67`).

## 4. 6502 dummy reads are real bus cycles

`STA $C0n0,X`, `STA ($nn),Y`, and anything Applesoft's `POKE` does, all read
the target address one cycle before they write it. For RAM that doesn't
matter. For an I/O register with a side effect on read, it does:

- The Uthernet II's W5100 data register auto-increments its address on every
  access. The card was advancing the address on a strobe that fired about 11
  clocks into PHI0, while it was still driving the byte, so a data read could
  return the **next** byte. IP65 still detected the chip, but a 342-byte DHCP
  offer got misaligned, and IP65's option parser looped forever on zeros. The
  Apple sat at "Obtaining IP address" with no error. The fix: advance on the
  falling edge of the select, at the end of PHI0. `tests/bus_timing/run.sh u2`
  went from 63 of 64 reads wrong to 0.
- The SuperSprite's TMS9918 takes two-byte commands on its control port, and
  reading that port resets the two-byte sequence. A `POKE` reads the port
  right before it writes, so every command gets cut in half. The BASIC
  examples in the user guide use two tiny machine-code helpers with plain
  `STA abs` for exactly this reason, and the card test does the same
  (`tests/cardtest/io.s`).

## 5. Act on an access once, at the end of the cycle

This one bit me twice. On the proto card, the FPGA sees a card select already
at the start of PHI0. Logic that does something "while the select is active,
on each Q3 tick" runs twice per access. The Disk II's write head did exactly
that and stored every nibble twice (`D5 D5 AA AA AD AD`).

The rule I follow now: note the access during PHI0, and **act on it once, at
the end of the cycle** (the PHI1 rising edge). Never use a data-in strobe for
an auto-increment or clear-on-read. Details in [storage.md](storage.md).

## 6. Keep storage data out of DDR

The upstream design moves disk data through an SDRAM window. On this port
that window went through a clock crossing and an AXI port with no way to
know when data had landed, and it lost data silently in both directions:
floppy saves read a copy that never had the track, and hard disk reads could
come back stale. Both fixes put the host directly on the block RAM the card
uses (SPI spaces 6 and 7). The Apple never reports an error for any of this;
the data is just gone. **Test writes, not just reads.** That's what the card
test is for.

## 7. Video shadow and byte enables

The DDR video shadow ignored byte enables, so every write to screen memory
also painted the neighbouring byte. In hires text that showed up as every
character drawn twice. Text was already served from block RAM; I moved the
hires pages (`$2000`-`$5FFF`) into a 32 KB block RAM as well
(`hires_vram` in `hdl/memory/apple_memory_sdram.sv`), and enabled the aux
lanes so 80-column text and double hires have somewhere to go.

## 8. Don't restart the host service under a running Apple

When `a2hostd` stops, the card stops answering: no disk, no menu, and the
bus PHY goes quiet. A running 6502 that was in the middle of reading the
Disk II crashes. Worse, the card's /RES output doesn't reliably bring a
crashed 6502 back (a CPU that hit a JAM opcode never restarts), and /INH
never worked on this card, so there is no automatic recovery.

So: **restart `a2hostd` only with the Apple off.** And never pause it (SIGSTOP)
or poke the SPI UIO from another process while it runs; its SPI timeout fires
when it resumes, it exits, and systemd's restart drops the host-ready bit
under the Apple.

## 9. An unenhanced IIe is a 6502, not a 65C02

When a new program "hangs" right after loading, check this first. Anything
built for the 65C02 (cc65's `apple2enh` target, ProDOS 8 2.x, Contiki, the
official IP65 apps) uses opcodes that are JAM on an NMOS 6502. The bus
capture shows endless reads of `$FFFF` returning `$FF`: that's the JAM
signature, and it isn't the card. ProDOS 8 2.0.x at least says so on screen
("REQUIRES ENHANCED APPLE IIE OR LATER"). For the Uthernet test disk I rebuilt
DATE65 and HFS65 for the plain 6502 (`cl65 -t apple2`).

## 10. Card firmware must not assume slots, and only one card should autoboot

The hard disk firmware came from a design where the Disk II always sat in
slot 5, so when it had no disk to boot it did `JMP $C500`. On this port the
Disk II follows the card. With the card in slot 4, `$C500` is the
Mockingboard: Ctrl-Open Apple-Reset ran the 6502 into its registers and
stopped in the monitor at `C505-`. With the card in slot 5 the same jump
happened to land on the Disk II, which hid the bug.

The same firmware also carried the full autostart signature (`$3C` at
`$Cn07`). The IIe boots the first card it finds from slot 7 down, so with the
hard disk in slot 6 and the Disk II in 4 or 5, Total Replay booted and the
menu never ran. Now the hard disk has only the ProDOS signature (`$20 $00
$03`), the menu boots it on request, and when it can't boot it hands back to
the IIe's own scan (`JMP $FABA`, SLOOP, from slot 7) instead of guessing a
slot.

One more trap from the same session: this ROM is assembled at `$0000` so it
runs in any slot, which means a `JMP` to one of its own labels goes to page
zero. Only branches and jumps to fixed ROM addresses are safe in it.
`tests/menu6502/hdd_rom_sim.py` runs it on an emulator and caught exactly that.

## 11. Simulate what you can, but test on the Apple

The xsim testbenches in `tests/bus_timing` caught a lot, and every bug above
now has one that fails on the old code. But the first Disk II testbench did
**not** reproduce the double nibble store, because its bus model didn't
present the select as early as the real card sees it. The card test on the
real IIe is what found the three storage bugs. Both are worth having.
