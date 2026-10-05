# Power

How the Smart Zynq and the proto card are powered, what's safe, and how to
run the board from the Apple's own +5V if you want a single power switch.

## How I run it today

- The **Smart Zynq** is powered from USB-C (the UART/JTAG socket, so the
  serial console comes on the same cable).
- The **Apple** runs on its own supply.
- The two share **ground only**, through the separate ground bundle (four or
  more wires between the Smart Zynq's ground and the Apple's pin 26 / card
  ground bus).
- The proto card's five SN74LVC245A run from the Smart Zynq's **3.3 V**
  (header pins 37/38). Their A side faces the Apple's 5 V signals, which is
  fine because LVC parts are 5 V tolerant on their inputs.
- The Apple's +5V (slot pin 25) goes only to a 15k/22k divider into one FPGA
  input, so the FPGA can tell whether the Apple is switched on.
- The header 5V pins (39/40) are **left unconnected**, and so are the Apple's
  +12V, -12V and -5V.

That's what [hardware/RED_PROTO_CARD_WIRING.md](../../../hardware/RED_PROTO_CARD_WIRING.md)
says to do, and it's the safe default.

Power-up order: board first, wait about 40 seconds for Linux, then the Apple.
With DIP switch 3 (Power-on-Reset hold) ON, the board holds the Apple in
reset until `a2hostd` is ready, so the other order works too; you just wait
at a blank screen.

**Never plug or unplug the card or the ribbon cables with either side
powered.** That includes moving the card between slots with the board still
running on USB.

## Running the board from the Apple's +5V

Once the card is soldered for good, it's tempting to feed the board from the
Apple so one power switch does everything. It can be done, but not with a
plain wire.

### What's on the Smart Zynq side

On the Smart Zynq SP schematic, pins 39 and 40 of both 40-pin headers (U12
and U13) are tied straight to the board's main 5V rail (`5V_DC`), which feeds
all of its regulators (TPS563201 bucks, which need at least about 4.5 V in).
The two USB-C sockets feed that same rail through SS24 Schottky diodes (D22
for the UART/JTAG socket, D25 for the OTG socket), so the board never pushes
power back out of a USB port.

### Why a plain wire is a bad idea

If you wire Apple slot pin 25 straight to header pin 39/40, the board does
run from the Apple. But the link works in both directions:

- With USB-C plugged in and the Apple switched off, the USB charger now tries
  to power the **whole Apple** through D22 (a 2 A diode). A 3 A USB-C charger
  can overload it.
- With both on, whichever supply is higher carries the board, and if it's
  the USB side it's also feeding the Apple's +5V rail through D22.

### Doing it properly

1. **Put a Schottky diode in the wire.** Cathode (the band) toward the Smart
   Zynq pin 39/40, anode toward the Apple's +5V. Use a 3 A or bigger part with
   a low forward drop: SS54, SB540 or 1N5822. Even better, an "ideal diode"
   module rated for 3 A or more (a MOSFET with a controller such as the
   LTC4412), which drops only tens of millivolts. Now either side can power the board and neither can
   feed the other, the same way the USB sockets already work.
2. **Check the current first.** Power the board from USB-C through a USB power
   meter, with HDMI and Ethernet connected and the Apple running, and note
   the current. A IIe supply gives roughly 2.5 A on +5V for everything, and
   the motherboard alone takes about 1 A. All of the board's current comes
   through the card's single +5V slot finger. If the board takes much more
   than about 1 A, stay on USB-C.
3. **Check the voltage under load.** With the Apple on and the board running
   from it, measure pin 39/40 to ground. It should be 4.6 V or more. A
   Schottky drops around 0.3-0.5 V, and the slot finger and wire add more. If
   it's low, use shorter and thicker wire or the ideal diode module.
4. **Expect a slower start.** The board now boots (about 40 seconds of Linux
   and FPGA start-up) every time the Apple is switched on, and the Apple waits
   in reset until it's ready. **DIP switch 3 must be ON** for that; with it
   OFF the Apple would start long before the cards exist. If the board's restart doesn't take the Apple
   with it and you land at the BASIC prompt instead of the menu, press
   Ctrl-Open Apple-Reset.

With the diode in place you can still plug in USB-C for the serial console;
the higher of the two supplies runs the board and nothing flows back into the
Apple.

The wiring notes still say "ground only" because that's the configuration
that can't go wrong. If you add the 5V link, add the diode, and update your
own copy of the notes so the next person working on the card knows it's
there.
