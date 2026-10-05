#!/usr/bin/env python3
"""Run the hard disk card's firmware (hdl/disk/hdd_rom.hex) on a 6502 emulator.

The ROM sits at $C600 (slot 6) with a fake card behind $C0E0-$C0EB that keeps a
few blocks in memory and answers like hdd.sv does with a2hostd serving it. The
scenarios cover what the Apple actually does with the card:

  - the power-up boot scan must pass over it (no $3C at $Cn07), while ProDOS
    must still see a block device ($20/$00/$03 and the $CnFF entry),
  - booting it (PR#n or the disk menu's jump): block 0 lands at $0800, X = $60,
  - booting it with no image, a read error or button 0 held: back to the Apple's
    own boot scan from slot 7 (SLOOP at $FABA with LOC1 = $C8), never a fixed slot,
  - the ProDOS block driver: READ, WRITE and STATUS, and READ with no image.

    python3 -m venv venv && venv/bin/pip install py65
    venv/bin/python hdd_rom_sim.py [hdd_rom.hex]     (default: the one in hdl/disk)
"""
import os
import sys

from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

HERE = os.path.dirname(os.path.abspath(__file__))
HDL = os.path.join(HERE, '..', '..', 'hdl', 'disk')


def load_hex(path):
    return [int(t, 16) for t in open(path).read().split()]


ROM = load_hex(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HDL, 'hdd_rom.hex'))
DISKII = load_hex(os.path.join(HDL, 'diskii.hex'))
assert len(ROM) == 256
SLOT = 6
BASE = 0xC080 + SLOT * 16
SLOOP, OS, BUTTON0 = 0xFABA, 0x0801, 0xC061
fails = 0


def check(ok, what):
    global fails
    print(('  ok    ' if ok else '  FAIL  ') + what)
    if not ok:
        fails += 1


def autostart_bootable(rom):
    """The IIe power-up scan: $Cn07,$Cn05,$Cn03,$Cn01 must read $3C,$03,$00,$20."""
    return [rom[7], rom[5], rom[3], rom[1]] == [0x3C, 0x03, 0x00, 0x20]


class Card:
    """hdd.sv as the firmware sees it, with a2hostd answering every request."""

    def __init__(self, mounted=True, blocks=64, read_error=False):
        self.mounted, self.blocks, self.read_error = mounted, blocks, read_error
        self.disk = {b: bytes((b * 7 + i) & 0xFF for i in range(512)) for b in range(blocks)}
        self.buf = bytearray(512)
        self.ptr = 0
        self.regs = [0] * 12
        self.busy = 0
        self.err = 0
        self.result = 0
        self.log = []

    def read(self, a):
        off = a - BASE
        if off == 0:                                   # EXECUTE
            self.ptr = 0
            cmd, unit = self.regs[2], self.regs[3] >> 7
            blk = self.regs[6] | self.regs[7] << 8
            self.log.append((cmd, unit, blk))
            if not self.mounted or unit:
                self.err, self.result = 1, 0x28        # no device
            elif cmd == 0:
                self.err, self.result = 0, 0
            elif cmd == 1:
                self.busy = 3                          # a2hostd takes a moment
                if self.read_error:
                    self.err, self.result = 1, 0x27    # I/O error
                else:
                    self.buf[:] = self.disk[blk]
                    self.err, self.result = 0, 0
            elif cmd == 2:
                self.busy = 3
                self.disk[blk] = bytes(self.buf)
                self.err, self.result = 0, 0
            return 0
        if off == 1:                                   # STATUS
            b = (0x80 if self.busy else 0) | self.err
            if self.busy:
                self.busy -= 1
            return b
        if off == 8:                                   # NEXTBYTE
            v = self.buf[self.ptr]
            self.ptr = (self.ptr + 1) & 0x1FF
            return v
        if off == 9:
            return self.blocks & 0xFF
        if off == 10:
            return self.blocks >> 8
        if off == 11:
            return self.result
        return self.regs[off]

    def write(self, a, v):
        off = a - BASE
        if off == 2:
            self.ptr = 0
        if off == 8:
            self.buf[self.ptr] = v
            self.ptr = (self.ptr + 1) & 0x1FF
        elif off not in (0, 1):                        # STATUS/EXECUTE writes: the ROR/ROL dummy writes
            self.regs[off] = v
        return None


def machine(card, button0=False):
    mem = ObservableMemory()
    mem.write(0xC600, ROM)
    mem.subscribe_to_read(range(BASE, BASE + 12), card.read)
    mem.subscribe_to_write(range(BASE, BASE + 12), card.write)
    mem.subscribe_to_read([BUTTON0], lambda a: 0x80 if button0 else 0x00)
    mem[0x00], mem[0x01] = 0x5A, 0xC6                  # whatever the boot scan left there
    mpu = MPU(memory=mem)
    mpu.sp, mpu.p = 0xEF, 0x24
    return mpu, mem


def run(mpu, stops, limit=200000):
    for _ in range(limit):
        if mpu.pc in stops:
            return True
        mpu.step()
    check(False, 'stopped (still at $%04X after %d steps)' % (mpu.pc, limit))
    return False


print('signature')
check(not autostart_bootable(ROM), 'power-up boot scan passes over the card ($Cn07=$%02X)' % ROM[7])
check(autostart_bootable(DISKII), 'and still boots the Disk II (sanity check of the scan model)')
check([ROM[1], ROM[3], ROM[5]] == [0x20, 0x00, 0x03], 'ProDOS block device signature $20 $00 $03')
check(ROM[7] != 0x00, '$Cn07 is not $00 (would claim SmartPort)')
check(ROM[0xFF] == 0x0A, 'ProDOS driver entry $CnFF = $%02X' % ROM[0xFF])

print('boot with an image (PR#6, or the disk menu jumping to $C600)')
card = Card()
mpu, mem = machine(card)
mpu.pc = 0xC600
if run(mpu, {OS, SLOOP}):
    check(mpu.pc == OS, 'runs block 0 at $0801 (pc=$%04X)' % mpu.pc)
    check(mpu.x == 0x60, 'X = slot*16 = $%02X' % mpu.x)
    check(bytes(mem[0x0800:0x0A00]) == card.disk[0], 'block 0 is at $0800-$09FF')
    check(card.log == [(0, 0, 0), (1, 0, 0)], 'card saw STATUS then READ block 0: %s' % card.log)
    check(mem[0x00] == 0x5A, 'zero page $00 restored after the slot trick')

print('boot with no image')
card = Card(mounted=False)
mpu, mem = machine(card)
mpu.pc = 0xC600
if run(mpu, {OS, SLOOP} | {0xC500, 0xC400}):
    check(mpu.pc == SLOOP, 'resumes the Apple boot scan at $FABA (pc=$%04X)' % mpu.pc)
    check(mem[0x00] == 0x00 and mem[0x01] == 0xC8, 'from slot 7 down (LOC0/LOC1 = $%02X/$%02X)' % (mem[0x00], mem[0x01]))

print('boot with a read error')
card = Card(read_error=True)
mpu, mem = machine(card)
mpu.pc = 0xC600
if run(mpu, {OS, SLOOP}):
    check(mpu.pc == SLOOP and mem[0x01] == 0xC8, 'boot scan from slot 7 (pc=$%04X)' % mpu.pc)

print('boot with button 0 held')
card = Card()
mpu, mem = machine(card, button0=True)
mpu.pc = 0xC600
if run(mpu, {OS, SLOOP}):
    check(mpu.pc == SLOOP and mem[0x01] == 0xC8, 'boot scan from slot 7, the floppy wins (pc=$%04X)' % mpu.pc)


def prodos_call(card, command, block=0, buf=0x2000, prefill=None):
    mpu, mem = machine(card)
    mem.write(0x0300, [0x20, 0x0A, 0xC6, 0xEA])        # JSR $C60A ; NOP
    mem[0x42], mem[0x43] = command, 0x60               # unit: slot 6, drive 1
    mem[0x44], mem[0x45] = buf & 0xFF, buf >> 8
    mem[0x46], mem[0x47] = block & 0xFF, block >> 8
    if prefill is not None:
        mem.write(buf, list(prefill))
    mpu.pc = 0x0300
    ok = run(mpu, {0x0303})
    return ok, mpu, mem


print('ProDOS driver')
card = Card()
ok, mpu, mem = prodos_call(card, 1, block=5)
if ok:
    check(not (mpu.p & 1) and mpu.a == 0, 'READ block 5: C=0, A=$%02X' % mpu.a)
    check(bytes(mem[0x2000:0x2200]) == card.disk[5], 'block 5 is at $2000')
data = bytes((255 - i) & 0xFF for i in range(512))
ok, mpu, mem = prodos_call(card, 2, block=7, buf=0x3000, prefill=data)
if ok:
    check(not (mpu.p & 1), 'WRITE block 7: C=0')
    check(card.disk[7] == data, 'the card got the 512 bytes from $3000')
ok, mpu, mem = prodos_call(card, 0)
if ok:
    check(not (mpu.p & 1) and mpu.x == 64 and mpu.y == 0, 'STATUS: C=0, size X/Y = %d/%d blocks' % (mpu.x, mpu.y))
ok, mpu, mem = prodos_call(Card(mounted=False), 1, block=0)
if ok:
    check((mpu.p & 1) and mpu.a == 0x28, 'READ with no image: C=1, A=$%02X (no device)' % mpu.a)

print('RESULT fails=%d' % fails)
sys.exit(1 if fails else 0)
