#!/usr/bin/env python3
# Board-side apple_bus timing sweep, driven through a2hostd's command file.
#   a2sweep.py show                 current counts + counters
#   a2sweep.py addr 10 18 [secs]    sweep the address sample count (reg 0x0C)
#   a2sweep.py data 6 14 [secs]     sweep the data sample count (reg 0x0D)
#   a2sweep.py set A D W [H]        set counts (0 = bitstream default), drive hold H
#   a2sweep.py loop [secs]          CPU error rate of the Apple test loop
#                                   (300:A0 00 B9 00 C5 99 00 C9 C8 D0 F7 F0 F3)
#   a2sweep.py hold 0 15 / addrloop 10 22   sweep hold / addr count by loop errors
#   a2sweep.py mode early|normal    early (bitstream default) or PHI0-only timing (reg 0x0F[3]=1)
# bt9+: reg 0x0D = {late-pass off, half-clock drive, data count[5:0]},
# reg 0x0E = {drive start delay (clocks after the fast PHI0 edge), late-pass count}.
# Counters (reg 0x0F[2:0] select, read at 0x7B-0x7E): 0 cycles, 1 addr
# mismatches, 2 data mismatches, 3 strobes, 4 {write,data,addr,hold:A}.
# reg 0x0F[7:4] is the drive hold, so selects are written as (hold<<4)|sel.
import os, sys, time

CMD, OUT = '/run/a2trace.cmd', '/run/a2reg.out'
ROM = bytes.fromhex('A220A000A203863C8A0A243CF010053C49FF297EB0084AD0FB989D5603C8E810E52058FFBABD00010A0A0A0A852BAABD8EC0BD8CC0BD8AC0BD89C0A050BD80C09829030A052BAABD81C0A95620A8FC8810EB8526853D8541A90885271808BD8CC010FB49D5D0F7BD8CC010FBC9AAD0F3EABD8CC010FBC996F0092890DF49ADF025D0D9A0038540BD8CC010FB2A853CBD8CC010FB253C88D0EC28C53DD0BEA540C541D0B8B0B7A056843CBC8CC010FB59D602A43C88990003D0EE843CBC8CC010FB59D602A43C9126C8D0EFBC8CC010FB59D602D087A000A256CA30FBB1265E00032A5E00032A9126C8D0EEE627E63DA53DCD0008A62B90DB4C01080000000000')
R0F_HI = None   # reg 0x0F bits [7:3] = drive hold [7:4] + early mode [3]

def r0f_hi():
    global R0F_HI
    if R0F_HI is None:
        R0F_HI = run(['rd 0F 1'])[0x0F][0] & 0xF8
    return R0F_HI

def hold_now():
    return (r0f_hi() >> 4) & 15

def run(lines, wait=0.8):
    try: os.remove(OUT)
    except FileNotFoundError: pass
    with open(CMD + '.tmp', 'w') as f: f.write('\n'.join(lines) + '\n')
    os.rename(CMD + '.tmp', CMD)
    reads = any(l.startswith('rd') for l in lines)
    for _ in range(40):
        time.sleep(wait / 4)
        if not os.path.exists(CMD) and (not reads or os.path.exists(OUT)): break
    time.sleep(0.3)
    vals = {}
    if not reads: return vals
    with open(OUT) as f:
        for ln in f:
            r, v = ln.strip().split('=')
            vals.setdefault(int(r, 16), []).append(int(v, 16))
    return vals

def counters():
    lines = []
    for sel in range(5):
        lines += ['wr 0F %02X' % (r0f_hi() | sel), 'rd 7B 4']
    for sel in (5, 6, 7):
        lines += ['wr 0F %02X' % (r0f_hi() | sel), 'rd 7B 4']
    lines += ['wr 0F %02X' % r0f_hi()]
    vals = run(lines)
    out = []
    for i in range(8):
        b = [vals[0x7B + k][i] for k in range(4)]
        out.append(b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24)
    return out  # cycles, addr_bad, data_bad, strobes, cfg, fast_edges, lag_long, lagstat

def rates(secs):
    a = counters(); time.sleep(secs); b = counters()
    d = [(b[i] - a[i]) & 0xFFFFFFFF for i in range(4)]
    d += [(b[5] - a[5]) & 0xFFFFFFFF, (b[6] - a[6]) & 0xFFFFFFFF, b[7]]
    return d, b[4]

def cfg_str(cfg):
    if cfg & 7 == 6:   # bt10: {window delay:4, at-commit, late count:3, data, addr, hold:4, early, 110}
        return 'addr=%d data=%d late=%d window=%d at_commit=%d hold=%d early=%d' % ((cfg >> 8) & 255, (cfg >> 16) & 255,
                (cfg >> 24) & 7, (cfg >> 28) & 15, (cfg >> 27) & 1, (cfg >> 4) & 15, (cfg >> 3) & 1)
    return 'addr=%d data=%d write=%d hold=%d early=%d' % ((cfg >> 8) & 255, (cfg >> 16) & 255,
                                                (cfg >> 24) & 255, (cfg >> 4) & 15, (cfg >> 3) & 1)

def set_hold(h):
    global R0F_HI
    R0F_HI = ((h & 15) << 4) | (r0f_hi() & 0x08)
    run(['wr 0F %02X' % R0F_HI])

def set_early(e):
    global R0F_HI
    R0F_HI = (r0f_hi() & 0xF0) | ((e & 1) << 3)
    run(['wr 0F %02X' % R0F_HI])

def loop_errors(secs=1.0, show_bits=True):
    # rolling I/O capture while the test loop runs; CPU writes to $C9xx carry
    # the byte it received from $C5xx
    run(['arm 1'])
    time.sleep(secs)
    try: os.remove('/run/a2trace.out')
    except FileNotFoundError: pass
    run(['dump'], wait=2.0)
    for _ in range(20):
        if os.path.exists('/run/a2trace.out'): break
        time.sleep(0.3)
    time.sleep(0.5)
    tot = bad = 0; bits = [0] * 8
    with open('/run/a2trace.out') as f:
        for ln in f:
            p = ln.split()
            if len(p) < 4 or p[0].startswith('#') or p[1] != 'W': continue
            a = int(p[0], 16)
            if 0xC900 <= a <= 0xC9FF:
                d = int(p[2], 16); e = ROM[a & 0xFF]; tot += 1
                if d != e:
                    bad += 1
                    for b in range(8):
                        if (d ^ e) >> b & 1: bits[b] += 1
    if show_bits:
        print('  loop: %d CPU writes checked, %d wrong (%.2f%%)  bit errors D0..D7=%s' %
              (tot, bad, 100.0 * bad / max(tot, 1), bits))
    return tot, bad

def show(secs=1.0):
    d, cfg = rates(secs)
    cyc = max(d[0], 1)
    print('%s  cycles=%d  addr_bad=%d (%.3f%%)  data_bad=%d (%.3f%%)  strobes=%d (%.1f%%)' %
          (cfg_str(cfg), d[0], d[1], 100.0 * d[1] / cyc, d[2], 100.0 * d[2] / cyc, d[3], 100.0 * d[3] / cyc))
    print('  PHI edges: fast=%d (%.2f per cycle)  early addr corrected by late pass=%d (%.3f%%)  denoise lag min=%d max=%d' %
          (d[4], d[4] / cyc, d[5], 100.0 * d[5] / cyc, (d[6] >> 8) & 255, (d[6] >> 16) & 255))

if __name__ == '__main__':
    op = sys.argv[1] if len(sys.argv) > 1 else 'show'
    if op == 'show':
        show(float(sys.argv[2]) if len(sys.argv) > 2 else 1.0)
    elif op == 'set':
        a, d, w = (int(x) for x in sys.argv[2:5])
        run(['wr 0C %02X' % a, 'wr 0D %02X' % d, 'wr 0E %02X' % w, 'rd 0C 3'])
        if len(sys.argv) > 5: set_hold(int(sys.argv[5]))
        show()
    elif op == 'mode':
        set_early(1 if sys.argv[2].startswith('n') else 0); show()
    elif op == 'loop':
        secs = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
        show(); loop_errors(secs)
    elif op == 'hold':
        lo, hi = int(sys.argv[2]), int(sys.argv[3])
        saved = hold_now()
        for h in range(lo, hi + 1):
            set_hold(h); print('hold=%d' % h); loop_errors(1.0)
        set_hold(saved); print('restored hold = %d' % saved)
    elif op == 'addrloop':
        lo, hi = int(sys.argv[2]), int(sys.argv[3])
        saved = run(['rd 0C 1'])[0x0C][0]
        for n in range(lo, hi + 1):
            run(['wr 0C %02X' % n]); time.sleep(0.2); print('addr=%d' % n); loop_errors(1.0)
        run(['wr 0C %02X' % saved]); print('restored reg 0C = %d' % saved)
    elif op in ('addr', 'data'):
        reg = '0C' if op == 'addr' else '0D'
        lo, hi = int(sys.argv[2]), int(sys.argv[3])
        secs = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
        saved = run(['rd %s 1' % reg])[int(reg, 16)][0]
        for n in range(lo, hi + 1):
            run(['wr %s %02X' % (reg, n)])
            time.sleep(0.2)
            show(secs)
        run(['wr %s %02X' % (reg, saved)])
        print('restored reg %s = %d' % (reg, saved))
