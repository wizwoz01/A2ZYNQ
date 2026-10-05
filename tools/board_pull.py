#!/usr/bin/env python3
"""Copy a file from the board over the serial console (gzip + base64), checked with md5.

    python3 board_pull.py REMOTE_PATH LOCAL_FILE
"""
import base64
import hashlib
import gzip
import re
import sys
import time
import serial

import os
PORT = os.environ.get('A2ZYNQ_SERIAL', '/dev/ttyUSB1')   # the board's UART/JTAG USB-C, channel B
BAUD, PROMPT = 115200, b'root@localhost:~#'
src, dst = sys.argv[1], sys.argv[2]
s = serial.Serial(PORT, BAUD, timeout=0.05)


def cmd(c, wait=120.0):
    s.reset_input_buffer()
    s.write(c.encode() + b'\r')
    out, end = b'', time.time() + wait
    while time.time() < end:
        out += s.read(65536)
        if out.rstrip().endswith(PROMPT) and b'PULL-END' in out:
            return out
    raise SystemExit('timeout: %r' % out[-300:])


q = "'" + src.replace("'", "'\\''") + "'"
out = cmd("stty -echo; md5sum %s | cut -c1-32; echo PULL-BEGIN; gzip -9c %s | base64 -w 1000; echo PULL-END; stty echo" % (q, q))
text = out.decode('ascii', 'replace').replace('\r', '')
want = re.search(r'([0-9a-f]{32})\s*\nPULL-BEGIN', text).group(1)
body = text.split('PULL-BEGIN\n', 1)[1].split('PULL-END', 1)[0]
data = gzip.decompress(base64.b64decode(''.join(body.split())))
open(dst, 'wb').write(data)
got = hashlib.md5(data).hexdigest()
print('%s: %d bytes, md5 %s %s' % (dst, len(data), got, 'OK' if got == want else 'MISMATCH (want %s)' % want))
s.close()
sys.exit(0 if got == want else 1)
