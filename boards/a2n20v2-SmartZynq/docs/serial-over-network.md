# Serial over the network: the Super Serial Card bridge

The Super Serial Card in slot 2 has no connector on this build, so instead of
a cable its serial port goes to the network: `a2hostd` listens on **TCP port
6551** (named after the chip) and everything a client sends lands in the
Apple's serial port, and the other way round. How to use it, with examples,
is in the [user guide](../../../docs/USER_GUIDE.md#5-super-serial-card-slot-2-over-the-network).
This page is about how it works.

```
 Apple program            FPGA                                    Linux
 PR#2 / IN#2 / ...   +--------------------------------------+   +-------------------+
  $C0A8-$C0AB  ----> | uart_6551 (the SSC's 6551 core)      |   | a2hostd SscNet    |
                     |   TX line ---> uart_rx --> rx FIFO --+-->| poll, send to the |---> TCP 6551
                     |   RX line <--- uart_tx <-- tx FIFO <-+---| client            |<--- (one client)
                     |       ssc_net_bridge.sv (512 B each) |   |                   |
                     +--------------------------------------+   +-------------------+
                                   SPI memory space 5, addresses 0x000-0x1FF
```

## Why a real serial line inside the FPGA

The easy way would have been to grab bytes straight out of the 6551's
registers. I didn't, because then the card's status flags and timing would
stop behaving like a real 6551 with a cable attached, and serial software on
the Apple is picky about that (transmit-empty timing, receive-full flags,
overruns at a given baud rate).

So the 6551 core (`hdl/support/uart_6551.v`) is left completely alone. It
still makes and takes a real serial bit stream at whatever baud rate the
Apple program sets. `hdl/ssc/ssc_net_bridge.sv` is the far end of the cable:

- `uart_rx` decodes the card's TX line into a 512-byte FIFO.
- A second 512-byte FIFO feeds `uart_tx`, which drives the card's RX line.
- Both use the baud rate from the 6551's control register (bits 3:0, the same
  table as the 6551 core) and 8N1, so whatever the Apple sets up, the bridge
  follows.

The PC side doesn't have a baud rate at all; TCP just carries bytes. The baud
rate only decides how fast bytes trickle in and out on the Apple side.

## The host side: memory space 5

All eight SPI memory spaces were taken, and register `0x7F` can't be used (it
is the XFER opcode, see [spi-host-interface.md](spi-host-interface.md)), so
the bridge shares space 5 with the HDMI notice line, split by address:

| Access | Address | Meaning |
|--------|---------|---------|
| write | `0x000`-`0x03F` | HDMI notice line (unchanged) |
| read | `0x000`-`0x0FF` | status byte: bit 7 = room for 256 more bytes to the Apple, bits 6:0 = bytes waiting from the Apple (0-127, capped) |
| read | `0x100`+ | pop bytes the Apple sent, one per address |
| write | `0x100`+ | push bytes for the Apple |

Register `0x06` bit 4 says the bitstream has the bridge. `a2hostd` only starts
the TCP listener when it sees it, so a new `a2hostd` on an old bitstream
doesn't read garbage.

## The a2hostd side

`class SscNet` in `src/a2hostd/src/main.cpp`, called from the main loop:

1. Accept a new client if there is one. A new connection replaces the old one
   (handy when a terminal window died without closing the socket).
2. Read the status byte. If the Apple sent anything, pop that many bytes and
   send them to the client. With nobody connected, they're dropped, the same
   as a serial port with no cable.
3. Read whatever the client sent into a pending buffer (up to 8 KB).
4. If the FPGA has room for 256 bytes, push the next chunk.

There's no telnet negotiation and no line-ending conversion: raw bytes both
ways. The Apple ends lines with CR only, so on Linux you may want
`tr '\r' '\n'` on the output.

### The pause after carriage return

The Apple's keyboard input routines are slow. Pasting a BASIC program
through `IN#2` at full speed loses characters while Applesoft is busy
tokenizing the previous line. With `ssc_cr_delay_ms=150` in the settings,
`a2hostd` stops after each CR it sends and waits that long before the next
line. It's off (0) by default, so binary transfers aren't slowed down.

## Settings

| Setting | Default | |
|---------|---------|--|
| `ssc_port` | `6551` | TCP port; `0` turns the bridge off |
| `ssc_cr_delay_ms` | `0` | pause after each CR sent to the Apple |

## Security

There is no password and no encryption. Anyone on the same network can
connect and type into the Apple. That's fine on a home network, but don't
forward the port to the internet.

## Testing

- `tests/bus_timing/run.sh sscnet` simulates the 6551 core plus the bridge:
  bytes from the "Apple" come out of the host FIFO and bytes pushed by the
  "host" arrive in the 6551's receive register, at two baud rates.
- On the board: connect with `nc <board-ip> 6551`, then on the Apple
  `PR#2`, `PRINT "HELLO"`, `PR#0`. The `a2hostd` log shows the connection and
  a byte count when the client disconnects.

My first try put the status in register `0x7F`. That register doesn't exist:
`0xFF 0xFF` on the wire is an XFER read, so every poll started a read of
space 7 and `a2hostd` streamed zeros to the client. The fix was to move the
status into space 5. If you add another host port, share a space by address.
