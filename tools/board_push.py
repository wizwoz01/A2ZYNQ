#!/usr/bin/env python3
"""Send a file to the board over the serial console (xz + base64, one line per prompt).

    python3 board_push.py LOCAL_FILE REMOTE_PATH

For when the board is not on your network; with the network, FTP is much faster.

Echo is switched off on the board during the transfer; the result is checked with md5sum.
"""
import base64
import hashlib
import lzma
import sys
import time
import serial

import os
PORT = os.environ.get('A2ZYNQ_SERIAL', '/dev/ttyUSB1')   # the board's UART/JTAG USB-C, channel B
BAUD, PROMPT = 115200, b'root@localhost:~#'
CHUNK = 1500
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, 'rb').read()
b64 = base64.b64encode(lzma.compress(raw, preset=9)).decode()
lines = [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]
print('%s: %d bytes, %d base64 chars, %d lines' % (src, len(raw), len(b64), len(lines)), flush=True)

s = serial.Serial(PORT, BAUD, timeout=0.05)


def cmd(c, wait=10.0):
    s.reset_input_buffer()
    s.write(c.encode() + b'\r')
    out, end = b'', time.time() + wait
    while time.time() < end:
        out += s.read(4096)
        if out.rstrip().endswith(PROMPT):
            return out
    raise SystemExit('no prompt after: %s\n%r' % (c[:60], out[-200:]))


cmd('')
cmd('stty -echo; rm -f /tmp/push.b64')
t0 = time.time()
for i, ln in enumerate(lines):
    cmd("printf '%s' '" + ln + "' >> /tmp/push.b64")
    if i % 50 == 0:
        print('  %d/%d lines, %.0f s' % (i, len(lines), time.time() - t0), flush=True)
out = cmd("base64 -d /tmp/push.b64 | xz -dc > %s && md5sum %s; rm -f /tmp/push.b64; stty echo" % (dst, dst), 60)
want = hashlib.md5(raw).hexdigest()
got = want in out.decode('ascii', 'replace')
print('sent in %.0f s; md5 %s %s' % (time.time() - t0, want, 'OK' if got else 'MISMATCH'))
print(out.decode('ascii', 'replace').replace('\r', '')[-200:])
s.close()
sys.exit(0 if got else 1)
