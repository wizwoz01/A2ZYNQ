#!/usr/bin/env python3
"""Run one shell command on the board's serial console and print the output.

    python3 board_shell.py "command" [timeout_seconds]

Reads until the root prompt comes back after the command (or the timeout).
"""
import sys
import time
import serial

import os
PORT = os.environ.get('A2ZYNQ_SERIAL', '/dev/ttyUSB1')   # the board's UART/JTAG USB-C, channel B
BAUD, PROMPT = 115200, b'root@localhost:~#'
cmd = sys.argv[1]
timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 10

s = serial.Serial(PORT, BAUD, timeout=0.2)
s.reset_input_buffer()
s.write(b'\r')
time.sleep(0.3)
s.read(4096)                       # drop the old prompt
s.write(cmd.encode() + b'\r')
out, end = b'', time.time() + timeout
while time.time() < end:
    chunk = s.read(4096)
    out += chunk
    # the echo contains no prompt; the prompt after the output means done
    if out.count(PROMPT) >= 1 and out.rstrip().endswith(PROMPT.rstrip()) and len(out) > len(cmd):
        break
s.close()
sys.stdout.write(out.decode('utf-8', 'replace').replace('\r', ''))
