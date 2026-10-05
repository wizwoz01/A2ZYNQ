# hardware

Everything about the **proto card**: the board that sits in the Apple II
slot and connects the Apple bus to the Smart Zynq.

It's deliberately simple. The card only translates voltages and connects
wires; all of the timing, address capture, decoding and every virtual card
live in the FPGA. That's what makes it buildable by hand on a generic Apple
II prototyping card (mine is a red one, hence the name).

There's now also a PCB version in [pcb/](pcb/): same circuit, Apple II card
outline, and the Smart Zynq sits right on top of it instead of on ribbon
cables.

## What's on it

| Part | Qty | Job |
|------|-----|-----|
| SN74LVC245A (U1-U4) | 4 | fixed-direction inputs: A0-A15, R/W, the selects, clocks, SYNC, and the shared control lines |
| SN74LVC245A (U5) | 1 | D0-D7, bidirectional, with DIR and OE# driven by the FPGA |
| 2N3904 / 2N2222A (Q1-Q6) | 6 | open-collector drivers for /IRQ, /NMI, /RDY, /DMA, /INH, /RES (the FPGA never drives them high) |
| 2N3904 / 2N2222A (Q7) | 1 | inverting level shifter that lets the FPGA see the Apple's /RES |
| resistors, capacitors | | base resistors and pull-downs, safe-default pull-ups on OE#/DIR, decoupling, a 15k/22k divider so the FPGA can see the Apple's +5V |
| 2x20 headers (JZ1, JZ2) | 2 | ribbon cables to the Smart Zynq's U12 and U13 headers |
| DIP switch (SW1) | 1 | four feature switches: scanlines, Apple speaker on HDMI, Power-on-Reset hold, hide the HDMI debug numbers |

The full parts list is in [BOM.csv](BOM.csv).

## Files

| File | What's in it |
|------|--------------|
| [RED_PROTO_CARD_WIRING.md](RED_PROTO_CARD_WIRING.md) | **Start here.** The electrical rules, IC placement, how each '245 is wired, the transistor stages, cable orientation and bring-up order |
| [BOM.csv](BOM.csv) | parts list |
| [apple_slot_pinout.csv](apple_slot_pinout.csv) | every Apple slot pin: signal, direction at the card, which part it goes to |
| [smart_zynq_u12_u13_pinmap.csv](smart_zynq_u12_u13_pinmap.csv) | every Smart Zynq header pin used: FPGA ball, signal name, direction |
| [transceiver_netlist.csv](transceiver_netlist.csv) | the five '245s, channel by channel: Apple pin to Zynq pin |
| [open_collector_netlist.csv](open_collector_netlist.csv) | Q1-Q6: which FPGA pin drives which Apple control line |
| [discrete_input_netlist.csv](discrete_input_netlist.csv) | Q7, the /RES sense stage |
| [schematics/](schematics/) | the schematic as a PDF ([red_proto_card_schematic.pdf](schematics/red_proto_card_schematic.pdf)) |
| [pcb/](pcb/) | the same circuit as a real PCB the Smart Zynq plugs straight onto: Gerbers, BOM, KiCad board (rev 1.0, not built yet) |

## The rules I won't bend

The wiring notes have the full list. The ones that matter most:

1. **Real SN74LVC245A parts.** Not HC/HCT/LS, and above all not
   auto-direction translators (TXB0108, TXS0108E) on the data bus. I tried
   both and they corrupt data on the Apple bus; see
   [lessons-learned](../boards/a2n20v2-SmartZynq/docs/lessons-learned.md#1-the-level-translator-on-the-data-bus).
2. The '245s run from the Smart Zynq's **3.3 V**. No Apple 5 V signal goes
   straight to the Smart Zynq headers.
3. **Ground only** between the Apple and the Smart Zynq. Never wire the
   Apple's +5V to the board's 5V without a diode
   ([power.md](../boards/a2n20v2-SmartZynq/docs/power.md)). Leave +12V, -12V
   and -5V alone.
4. The shared lines (/IRQ, /NMI, /RDY, /DMA, /INH, /RES) are only ever pulled
   low by the transistors.
5. Pull-ups keep every '245 disabled until the FPGA is configured.
6. A separate ground bundle, at least four wires.
7. **Nothing gets plugged or unplugged with power on**, on either side.

## Building one

- Lay out the five '245s with short runs to the slot fingers, and put a
  100 nF capacitor right across each one's pins 10 and 20.
- Check the header orientation with a meter before crimping the ribbon
  cables (U12 goes to JZ1, U13 to JZ2), and use keyed connectors.
- Before the card goes anywhere near the Apple: with the Smart Zynq powered
  and the card unplugged from the Apple, check 3.3 V on every '245, check that
  OE# and DIR sit high, and check every Apple-side pin for shorts to its
  neighbours and to ground.
- Wire the DIP switch with one row of pins to **ground**, each switch's other
  pin to JZ2/U13 pin 15-18. No pull-up resistors needed; the FPGA has them.
  Diagram in [RED_PROTO_CARD_WIRING.md](RED_PROTO_CARD_WIRING.md#dip-switch-sw1);
  what each switch does is in the
  [board README](../boards/a2n20v2-SmartZynq/README.md#dip-switches).
- First power-up in the Apple: board first, then the Apple, and watch the
  `a2hostd` log for the detected card slot.
