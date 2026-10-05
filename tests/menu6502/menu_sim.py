#!/usr/bin/env python3
"""Run diskmenu.bin on a 6502 emulator (py65) with a fake a2hostd on the mailbox.

The menu is entered as the Disk II boot ROM calls it (JSR $C800 from $C624, slot 6),
the fake host acks every event and answers a key with a command, and each scenario
stops where the menu hands over: HOME ($FC58) for ESC, the return into the boot ROM
for a boot, (TARGET) for a slot move.

    python3 -m venv venv && venv/bin/pip install py65
    venv/bin/python menu_sim.py [diskmenu.bin]     (default: the one in hdl/disk)
"""
import os
import sys
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

DEFAULT_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           '..', '..', 'hdl', 'disk', 'diskmenu.bin')
BIN = open(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BIN, 'rb').read()
assert len(BIN) == 2048
MAGIC0, MAGIC1, FRAME, CMD, ACK, TARGET, SEQ, EVT, KEY, MSLOT, COLD = (
    0xCE00, 0xCE01, 0xCE02, 0xCE03, 0xCE04, 0xCE05, 0xCE08, 0xCE09, 0xCE0A, 0xCE0B, 0xCE0C)
HOME, RET_TO_ROM, BASIC = 0xFC58, 0xC627, 0xE000   # JSR $C800 at $C624 returns to $C627
PROBES = [0xC090, 0xC090, 0xC0A0, 0xC0A0, 0xC0B0, 0xC0B0,
          0xC400, 0xC401, 0xC500, 0xC501, 0xC600, 0xC601, 0xC700, 0xC701]
fails = 0


def check(ok, what):
    global fails
    print(('  ok    ' if ok else '  FAIL  ') + what)
    if not ok:
        fails += 1


def run(name, softev, answer, magic=True, target=0xC500, hello_answer=None):
    """answer: the command the fake host sends after the ESC/RETURN key (3 exit, 1 boot, 2 move);
    hello_answer: a command set before the hello ack instead (4 = card in slot 1 at power-up)"""
    print(name)
    mem = ObservableMemory()
    mem.write(0xC800, list(BIN))
    if magic:
        mem[MAGIC0], mem[MAGIC1] = 0xA5, 0x5A
    mem[0x03F2], mem[0x03F3] = softev & 0xFF, softev >> 8
    mem[0x03F4] = (softev >> 8) ^ 0xA5                 # valid power-up byte on entry
    mem[TARGET], mem[TARGET + 1] = target & 0xFF, target >> 8
    st = {'key': 0, 'reads': [], 'events': [], 'spoiled': None, 'screen': 0, 'switches': [], 'strobe': 0}

    def io_read(a):
        if 0xC090 <= a <= 0xC0FF or 0xC100 <= a <= 0xC7FF:
            st['reads'].append(a)
            return 0xFF
        if a == 0xC000:
            return st['key']
        if a == 0xC010:
            st['strobe'] += 1
            st['key'] &= 0x7F
            return 0
        return 0

    def screen_write(a, v):
        st['screen'] += 1
        if st.pop('press', False):
            st['key'] = 0x9B                           # the menu is on screen: the user presses ESC
        return None

    def switch_write(a, v):
        st['switches'].append(a)
        return None

    def seq_write(a, v):
        evt = mem[EVT]
        st['events'].append((evt, mem[KEY]))
        if evt == 1:
            st['spoiled'] = mem[0x03F4]
            st['cold'] = mem[COLD]
            if hello_answer is not None:
                mem[CMD] = hello_answer
            else:
                st['press'] = True                     # ESC once the menu shows
        mem[ACK] = v                                   # ack first, as a2hostd does
        if evt == 2:
            if answer in (1, 2):                       # boot / jump: a last frame, then the command
                mem[FRAME] = (mem[FRAME] + 1) & 0xFF
            st['screen_at_cmd'] = st['screen']
            mem[CMD] = answer
        return None

    mem.subscribe_to_read(range(0xC000, 0xC800), io_read)
    mem.subscribe_to_write([SEQ], seq_write)
    mem.subscribe_to_write(range(0x0400, 0x0800), screen_write)
    mem.subscribe_to_write(range(0xC000, 0xC090), switch_write)
    mpu = MPU(memory=mem)
    mem[0x01FF], mem[0x01FE] = 0xC6, 0x26              # JSR $C800 at $C624 (slot 6)
    mpu.sp, mpu.pc = 0xFD, 0xC800
    mpu.p = 0x24                                       # I set, as after RESET
    stops = {HOME, RET_TO_ROM, BASIC, target}
    for _ in range(300000):
        if mpu.pc in stops:
            break
        mpu.step()
    else:
        check(False, 'menu handed over (still at $%04X after 300000 steps)' % mpu.pc)
        return None
    return mpu, mem, st


# 1. power-up boot, ESC: BASIC's cold start, later resets go to its warm start
r = run('ESC at power-up (reset vector still $E000)', 0xE000, 3)
if r:
    mpu, mem, st = r
    check(st['reads'] == PROBES, 'slot probes: ' + ' '.join('%04X' % a for a in st['reads']))
    check(mem[MSLOT] == 0x60, 'reports slot 6 (MSLOT=$%02X)' % mem[MSLOT])
    check(st['events'] == [(1, 0), (2, 0x9B)], 'events: hello, then key ESC')
    check(st['spoiled'] is not None and st['spoiled'] != 0x45, 'power-up byte spoiled while in the menu')
    check(mpu.pc == HOME, 'jumps to HOME ($%04X)' % mpu.pc)
    ret = (mem[0x100 + mpu.sp + 1] | mem[0x100 + mpu.sp + 2] << 8) + 1
    check(ret == 0xE000, "HOME's RTS goes to $%04X (want $E000, BASIC cold start)" % ret)
    check(mem[0x03F2] == 0x03 and mem[0x03F3] == 0xE0, 'reset vector now $%02X%02X (want $E003)' % (mem[0x03F3], mem[0x03F2]))
    check(mem[0x03F4] == 0xE0 ^ 0xA5, 'power-up byte valid again ($%02X)' % mem[0x03F4])
    check(mpu.p & 0x04, 'interrupts still off, as on entry')

# 2. menu reached by PR#6 with DOS 3.3 loaded: ESC goes where Ctrl-Reset would
r = run('ESC with DOS 3.3 in memory (reset vector $9DBF)', 0x9DBF, 3)
if r:
    mpu, mem, st = r
    ret = (mem[0x100 + mpu.sp + 1] | mem[0x100 + mpu.sp + 2] << 8) + 1
    check(mpu.pc == HOME and ret == 0x9DBF, 'HOME, then RTS to $%04X (want $9DBF)' % ret)
    check(mem[0x03F2] == 0xBF and mem[0x03F3] == 0x9D, 'reset vector unchanged')
    check(mem[0x03F4] == 0x9D ^ 0xA5, 'power-up byte valid again ($%02X)' % mem[0x03F4])

# 3. a vector ending in $00 (borrow into the high byte)
r = run('ESC with reset vector $BE00', 0xBE00, 3)
if r:
    mpu, mem, st = r
    ret = (mem[0x100 + mpu.sp + 1] | mem[0x100 + mpu.sp + 2] << 8) + 1
    check(mpu.pc == HOME and ret == 0xBE00, 'HOME, then RTS to $%04X (want $BE00)' % ret)
    check(mem[0x03F2] == 0x00 and mem[0x03F3] == 0xBE, 'reset vector unchanged')

# 4. RETURN (boot) still returns into the boot ROM with X = slot*16
r = run('RETURN: boot', 0xE000, 1)
if r:
    mpu, mem, st = r
    check(mpu.pc == RET_TO_ROM and mpu.x == 0x60 and mpu.sp == 0xFF,
          'back in the boot ROM at $%04X, X=$%02X, SP=$%02X' % (mpu.pc, mpu.x, mpu.sp))

# 5. CMD 2: boot the hard disk card picked in the menu (or the Disk II after a
#    slot move whose reset did not take): draw the last frame, then JMP (TARGET)
r = run('hard disk picked: jump to its card (CMD 2)', 0xE000, 2, target=0xC500)
if r:
    mpu, mem, st = r
    check(mpu.pc == 0xC500, 'jumps to (TARGET) = $%04X' % mpu.pc)
    check(st['screen'] > st.get('screen_at_cmd', st['screen']), '"BOOTING ..." frame drawn before the jump')
    check(mpu.p & 0x04, 'interrupts as on entry')

# 6. card in slot 1, power-up: no menu, nothing boots - BASIC, as when the scan finds no disk
r = run('card in slot 1 at power-up: hello answered with 4', 0xE000, 0, hello_answer=4)
if r:
    mpu, mem, st = r
    check(st['cold'] == 1, 'hello says power-up entry (COLD=%d)' % st['cold'])
    check(st['reads'] == PROBES, 'slots still probed (so a move out of slot 1 is seen)')
    check(mpu.pc == BASIC, 'BASIC cold start ($%04X)' % mpu.pc)
    check(st['events'] == [(1, 0)], 'only the hello was sent')
    check(st['screen'] == 0, 'screen untouched ("Apple ][" stays): %d writes' % st['screen'])
    check(not st['switches'], 'no video switches flipped: %s' % ' '.join('%04X' % a for a in st['switches']))
    check(st['strobe'] == 0, 'keyboard strobe left alone')
    check(mem[0x03F2] == 0x03 and mem[0x03F3] == 0xE0, 'reset vector now $%02X%02X (want $E003)' % (mem[0x03F3], mem[0x03F2]))
    check(mem[0x03F4] == 0xE0 ^ 0xA5, 'power-up byte valid ($%02X): Ctrl-Reset stays in BASIC' % mem[0x03F4])
    check(mpu.p & 0x04, 'interrupts as on entry')

# 6b. card in slot 1, PR#6 typed in BASIC afterwards: the hello says so, the menu shows
r = run('card in slot 1, PR#6 from BASIC (reset vector $E003)', 0xE003, 3)
if r:
    mpu, mem, st = r
    check(st['cold'] == 0, 'hello says not a power-up entry (COLD=%d)' % st['cold'])
    check(st['screen'] > 0, 'menu drawn (%d screen writes)' % st['screen'])
    ret = (mem[0x100 + mpu.sp + 1] | mem[0x100 + mpu.sp + 2] << 8) + 1
    check(mpu.pc == HOME and ret == 0xE003, 'ESC: HOME, then back to BASIC at $%04X' % ret)

# 7. no a2hostd: straight back to the boot ROM, nothing probed
r = run('no a2hostd (no magic)', 0xE000, 0, magic=False)
if r:
    mpu, mem, st = r
    check(mpu.pc == RET_TO_ROM and mpu.x == 0x60 and not st['reads'], 'returns at once, X=$%02X' % mpu.x)

print('RESULT fails=%d' % fails)
sys.exit(1 if fails else 0)
