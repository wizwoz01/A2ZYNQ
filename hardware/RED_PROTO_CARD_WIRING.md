# Red Apple II proto-card assembly — five SN74LVC245A, no CPLD

This revision is explicitly designed around **five** SN74LVC245A devices. It retains every Apple-bus signal that the original A2N20v2 schematic actually connects to its CPLD, while leaving Apple pins 23, 24, 27, and 28 unconnected exactly as shown by the original schematic's no-connect marks.

The card is a voltage-domain and connector adapter only. All Apple timing, address capture, multiplexing, decode, virtual-card, video, audio, memory-client, and service logic is in the Zynq PL. Storage, USB, network, menu, configuration, and update services are in the Zynq PS.

## Why five 245s are enough

Four devices provide 32 fixed-direction input channels and one device provides the eight bidirectional data bits:

- U1: A0-A7
- U2: A8-A15
- U3: R/W, /IOSEL, /IOSTRB, /DEVSEL, PHI0, PHI1, 7M, Q3
- U4: SYNC, M2SEL, M2B0, /RDY, /DMA, /NMI, /IRQ, /INH
- U5: D0-D7 bidirectional

The one remaining original connected input, `/RES`, uses Q7 as a discrete 5-V-to-3.3-V NPN inverter. This is appropriate for the slow reset signal and avoids sacrificing any timing signal. Q1-Q6 remain the open-collector assertion drivers for the six shared active-low Apple lines.

## Non-negotiable electrical rules

1. Use exact **SN74LVC245A** parts, preferably `SN74LVC245AN` PDIP-20. Do not substitute HC/HCT/LS/ABT devices.
2. Power U1-U5 from Smart Zynq 3.3 V. Pin 20 is 3.3 V and pin 10 is ground.
3. Never connect an Apple 5 V bus signal directly to U12/U13.
4. Never connect Apple +5 V to Smart Zynq 5 V. The systems share ground only.
5. Leave Apple +12 V, -12 V, and -5 V isolated.
6. `/IRQ`, `/NMI`, `/RDY`, `/DMA`, `/INH`, and `/RES` are asserted only by Q1-Q6 open-collector stages. The PL never actively drives them high.
7. U1-U4 `OE#` has an external 10 kΩ pull-up to 3.3 V so all fixed-input translators are disabled before PL configuration.
8. U5 data `OE#` and `DIR` each have an external 10 kΩ pull-up; this disables the bus and selects Apple-to-Zynq receive direction while disabled.
9. Use a separate ground bundle with at least four conductors between Smart Zynq ground and Apple pin 26/card ground bus.
10. Do not insert/remove the card or either ribbon cable with either system powered.

## IC placement

Place U5 adjacent to Apple D0-D7 fingers, U1/U2 adjacent to the address fingers, U3 adjacent to clocks/selects, U4 adjacent to shared controls, Q1-Q7 adjacent to their corresponding Apple control fingers, and JZ1/JZ2 at the top edge. Run a continuous ground bus across the card. Put each 100 nF capacitor directly across U1-U5 pins 20 and 10 with the shortest possible leads.

## Common 245 wiring

- U1-U4: pin 1 `DIR` to 3.3 V. Pin 19 `OE#` to U13 pin 13 and a 10 kΩ pull-up to 3.3 V.
- U5 data bus: pin 1 `DIR` to U12 pin 9 and 10 kΩ pull-up to 3.3 V. Pin 19 `OE#` to U12 pin 10 and 10 kΩ pull-up to 3.3 V.
- U1-U5: pin 20 to 3.3 V, pin 10 to ground, 100 nF directly from pin 20 to pin 10.

The full channel-level wiring is in `transceiver_netlist.csv`.

## Q1-Q6 shared-line assertion stages

For each shared active-low output: Zynq header output -> 2.2 kΩ -> NPN base; 10 kΩ base-to-emitter; emitter to ground; collector to the Apple line. A Zynq logic high turns the transistor on and asserts the Apple line low. A low or unpowered Zynq releases it.

See `open_collector_netlist.csv` for the exact pin assignments.

## Q7 /RES sense level shifter

Q7 is **not** an open-collector Apple output. It is a separate input level shifter for sensing Apple `/RES` with only five 245s:

- Apple pin 31 `/RES` -> 15 kΩ -> Q7 base.
- Q7 base -> 100 kΩ -> ground.
- Q7 emitter -> ground.
- Q7 collector -> U13 pin 20 (J5[19]).
- Q7 collector -> 4.7 kΩ -> Smart Zynq 3.3 V.

Behavior:

- Apple `/RES` high/inactive -> Q7 ON -> U13-20 low.
- Apple `/RES` low/asserted -> Q7 OFF -> U13-20 high.

Therefore U13-20 is named `a2_reset_asserted_sense` and is active high. The PL inverts it once to reconstruct the original active-low `bus_reset_n`.

Q6 still has its collector on Apple pin 31 and asserts reset low when requested by the PL. Q6 and Q7 can share the Apple `/RES` node safely because Q6 is an open-collector pull-down and Q7 is only a resistively limited sense input.

## Apple daisy-chain pins

Leave these **unconnected** on the red card:

- pin 23 `/INTOUT`
- pin 24 `/DMAOUT`
- pin 27 `/DMAIN`
- pin 28 `/INTIN`

This is not a feature reduction relative to the original A2N20v2 card: the original schematic marks all four of these pins no-connect. The PL wrapper ties the corresponding optional internal chain inputs inactive and ignores its outputs.

## Apple 5 V presence sense

Apple pin 25 -> 15 kΩ -> U13 pin 14 -> 22 kΩ -> ground. This yields about 2.97 V from a nominal 5.0 V rail and is sense-only.

## DIP switch SW1

A 4-position DIP switch is 4 separate on/off contacts. Each position joins the two pins facing each other across the body when it is ON (an 8-pin switch: position 1 joins pins 1 and 8, position 2 pins 2 and 7, position 3 pins 3 and 6, position 4 pins 4 and 5).

- Tie one whole row of pins together and connect it to the card's ground bus.
- Connect the facing pin of each position to its own JZ2 pin, which the ribbon carries to the same U13 pin:

| SW1 position | JZ2 / U13 pin | FPGA ball | Signal | ON means |
|--------------|---------------|-----------|--------|----------|
| 1 | 15 | B22 | `switch1_n` | scanlines on HDMI (read when the board starts) |
| 2 | 16 | B21 | `switch2_n` | Apple speaker on the HDMI audio (read when the board starts) |
| 3 | 17 | B17 | `switch3_n` | Power-on-Reset hold: the Apple waits in reset after power-on until `a2hostd` is ready (keep ON) |
| 4 | 18 | B16 | `switch4_n` | hide the HDMI debug numbers (read live) |

```
               SW1, top view                      JZ2 (2x20, card end of the U13 ribbon)
          +-----------------------+
   ON ->  |  [1]   [2]   [3]   [4]|                 pin 15  o o  pin 16
          +-----------------------+                 pin 17  o o  pin 18
           p8    p7    p6    p5     -- each to:    15    16    17    18
           p1    p2    p3    p4     -- all together to the card ground bus
```

The switches pull to ground, never to a supply: U13 is a 3.3 V bank, so never wire these pins to 3.3 V or 5 V through a switch. No pull-up resistors are needed; the FPGA's own pull-ups (set in `smart_zynq_sp_a2_vectors.xdc`) hold an OFF switch high, so an open or missing switch reads OFF. With no switch fitted, the Power-on-Reset hold is off; a wire from JZ2 pin 17 to ground keeps it on permanently.

Check with a meter, board running and card out of the Apple: each of JZ2 pins 15-18 reads about 3.3 V to ground with its switch OFF and 0 V with it ON. On the HDMI picture, switch 4 ON makes the numbers along the top disappear at once.

## Cable orientation

The exact Xillinux mapping defines J6=U12 and J5=U13. Only physical GPIO pins 1-34 are GPIO. Pins 35/36 are ground, pins 37/38 are 3.3 V and pins 39/40 are 5 V on the board schematic. Establish orientation with a meter before making the cable; key both connectors. Leave all 5 V header pins disconnected.

## Bring-up gates

Do not enable `bus_input_oe_n` or `data_oe_n` until 3.3 V, common ground, Apple 5 V sense, and PL clock lock are valid. First boot must use a capture-only image with U5 disabled and all Q1-Q6 assertion bases low. Validate Q7 reset sense, clocks/address/control with ILA before enabling data receive, then one selected read, then shared outputs one at a time.
