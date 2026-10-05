#!/usr/bin/env python3
"""Minimal two-pass 6502 assembler for the card firmware (ACME-style subset).

    asm65.py SRC.a65 OUT.hex [--size N] [--fill 0xNN] [--bin OUT.bin]

Syntax: `* = $addr`, `name = expr`, labels at column 0 (optional ':'),
`!byte e,...`, `!word e,...`, `!fill n[,v]`, `!text "..."` (high bit set),
`;` comments. Expressions: $hex, %bin, decimal, 'c', labels, * , + - * / & |,
<expr / >expr (low/high byte), parentheses via [ ] are not needed.
Zero-page addressing is used when an operand's value is known (defined
earlier) and < $100; forward references assemble as absolute.
The .hex output is one byte per line (for $readmemh), padded to --size.
"""
import re
import sys

OPS = {
    'adc': {'imm': 0x69, 'zp': 0x65, 'zpx': 0x75, 'abs': 0x6D, 'absx': 0x7D, 'absy': 0x79, 'indx': 0x61, 'indy': 0x71},
    'and': {'imm': 0x29, 'zp': 0x25, 'zpx': 0x35, 'abs': 0x2D, 'absx': 0x3D, 'absy': 0x39, 'indx': 0x21, 'indy': 0x31},
    'asl': {'acc': 0x0A, 'zp': 0x06, 'zpx': 0x16, 'abs': 0x0E, 'absx': 0x1E},
    'bit': {'zp': 0x24, 'abs': 0x2C},
    'bpl': {'rel': 0x10}, 'bmi': {'rel': 0x30}, 'bvc': {'rel': 0x50}, 'bvs': {'rel': 0x70},
    'bcc': {'rel': 0x90}, 'bcs': {'rel': 0xB0}, 'bne': {'rel': 0xD0}, 'beq': {'rel': 0xF0},
    'brk': {'imp': 0x00},
    'cmp': {'imm': 0xC9, 'zp': 0xC5, 'zpx': 0xD5, 'abs': 0xCD, 'absx': 0xDD, 'absy': 0xD9, 'indx': 0xC1, 'indy': 0xD1},
    'cpx': {'imm': 0xE0, 'zp': 0xE4, 'abs': 0xEC},
    'cpy': {'imm': 0xC0, 'zp': 0xC4, 'abs': 0xCC},
    'dec': {'zp': 0xC6, 'zpx': 0xD6, 'abs': 0xCE, 'absx': 0xDE},
    'eor': {'imm': 0x49, 'zp': 0x45, 'zpx': 0x55, 'abs': 0x4D, 'absx': 0x5D, 'absy': 0x59, 'indx': 0x41, 'indy': 0x51},
    'clc': {'imp': 0x18}, 'sec': {'imp': 0x38}, 'cli': {'imp': 0x58}, 'sei': {'imp': 0x78},
    'clv': {'imp': 0xB8}, 'cld': {'imp': 0xD8}, 'sed': {'imp': 0xF8},
    'inc': {'zp': 0xE6, 'zpx': 0xF6, 'abs': 0xEE, 'absx': 0xFE},
    'jmp': {'abs': 0x4C, 'ind': 0x6C},
    'jsr': {'abs': 0x20},
    'lda': {'imm': 0xA9, 'zp': 0xA5, 'zpx': 0xB5, 'abs': 0xAD, 'absx': 0xBD, 'absy': 0xB9, 'indx': 0xA1, 'indy': 0xB1},
    'ldx': {'imm': 0xA2, 'zp': 0xA6, 'zpy': 0xB6, 'abs': 0xAE, 'absy': 0xBE},
    'ldy': {'imm': 0xA0, 'zp': 0xA4, 'zpx': 0xB4, 'abs': 0xAC, 'absx': 0xBC},
    'lsr': {'acc': 0x4A, 'zp': 0x46, 'zpx': 0x56, 'abs': 0x4E, 'absx': 0x5E},
    'nop': {'imp': 0xEA},
    'ora': {'imm': 0x09, 'zp': 0x05, 'zpx': 0x15, 'abs': 0x0D, 'absx': 0x1D, 'absy': 0x19, 'indx': 0x01, 'indy': 0x11},
    'tax': {'imp': 0xAA}, 'txa': {'imp': 0x8A}, 'dex': {'imp': 0xCA}, 'inx': {'imp': 0xE8},
    'tay': {'imp': 0xA8}, 'tya': {'imp': 0x98}, 'dey': {'imp': 0x88}, 'iny': {'imp': 0xC8},
    'rol': {'acc': 0x2A, 'zp': 0x26, 'zpx': 0x36, 'abs': 0x2E, 'absx': 0x3E},
    'ror': {'acc': 0x6A, 'zp': 0x66, 'zpx': 0x76, 'abs': 0x6E, 'absx': 0x7E},
    'rti': {'imp': 0x40}, 'rts': {'imp': 0x60},
    'sbc': {'imm': 0xE9, 'zp': 0xE5, 'zpx': 0xF5, 'abs': 0xED, 'absx': 0xFD, 'absy': 0xF9, 'indx': 0xE1, 'indy': 0xF1},
    'sta': {'zp': 0x85, 'zpx': 0x95, 'abs': 0x8D, 'absx': 0x9D, 'absy': 0x99, 'indx': 0x81, 'indy': 0x91},
    'stx': {'zp': 0x86, 'zpy': 0x96, 'abs': 0x8E},
    'sty': {'zp': 0x84, 'zpx': 0x94, 'abs': 0x8C},
    'txs': {'imp': 0x9A}, 'tsx': {'imp': 0xBA}, 'pha': {'imp': 0x48}, 'pla': {'imp': 0x68},
    'php': {'imp': 0x08}, 'plp': {'imp': 0x28},
}
SIZE = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'zpx': 2, 'zpy': 2, 'rel': 2, 'indx': 2, 'indy': 2,
        'abs': 3, 'absx': 3, 'absy': 3, 'ind': 3}


class AsmError(Exception):
    pass


def split_args(s):
    out, cur, q = [], '', None
    for ch in s:
        if q:
            cur += ch
            if ch == q:
                q = None
        elif ch in '"\'':
            q = ch
            cur += ch
        elif ch == ',':
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


class Asm:
    def __init__(self):
        self.sym = {}

    def value(self, expr, pc, final):
        """Evaluate expr; returns None if it uses an unknown symbol (pass 1)."""
        e = expr.strip()
        if e.startswith('<'):
            v = self.value(e[1:], pc, final)
            return None if v is None else v & 0xFF
        if e.startswith('>'):
            v = self.value(e[1:], pc, final)
            return None if v is None else (v >> 8) & 0xFF
        toks = re.findall(r"\$[0-9A-Fa-f]+|%[01]+|\d+|'.'|[A-Za-z_][A-Za-z0-9_.]*|[-+*/&|()]", e)
        if ''.join(toks) != e.replace(' ', ''):
            raise AsmError('bad expression: %s' % expr)
        py = []
        unknown = False
        prev_operand = False
        for t in toks:
            if t.startswith('$'):
                py.append(str(int(t[1:], 16))); prev_operand = True
            elif t.startswith('%'):
                py.append(str(int(t[1:], 2))); prev_operand = True
            elif t.isdigit():
                py.append(t); prev_operand = True
            elif t.startswith("'"):
                py.append(str(ord(t[1]))); prev_operand = True
            elif t == '*' and not prev_operand:
                py.append(str(pc)); prev_operand = True
            elif re.match(r'[A-Za-z_]', t):
                k = t.lower()
                if k in self.sym:
                    py.append(str(self.sym[k]))
                else:
                    if final:
                        raise AsmError('undefined symbol: %s' % t)
                    unknown = True
                    py.append('0')
                prev_operand = True
            else:
                py.append('//' if t == '/' else t)
                prev_operand = t == ')'
        if unknown:
            return None
        return int(eval(''.join(py))) & 0xFFFF  # noqa: S307 - own sources only

    def operand(self, mn, arg, pc, final):
        modes = OPS[mn]
        a = arg.strip()
        if a == '' or a.lower() == 'a':
            mode = 'acc' if 'acc' in modes else 'imp'
            return mode, None
        if a.startswith('#'):
            return 'imm', self.value(a[1:], pc, final)
        m = re.fullmatch(r'\((.*)\)\s*,\s*[yY]', a)
        if m:
            return 'indy', self.value(m.group(1), pc, final)
        m = re.fullmatch(r'\((.*)\s*,\s*[xX]\s*\)', a)
        if m:
            return 'indx', self.value(m.group(1), pc, final)
        m = re.fullmatch(r'\((.*)\)', a)
        if m and 'ind' in modes:
            return 'ind', self.value(m.group(1), pc, final)
        idx = None
        m = re.fullmatch(r'(.*),\s*([xXyY])', a)
        if m:
            a, idx = m.group(1), m.group(2).lower()
        v = self.value(a, pc, final)
        if 'rel' in modes:
            return 'rel', v
        zp_ok = v is not None and v < 0x100 and self.known_early(a)
        if idx is None:
            mode = 'zp' if zp_ok and 'zp' in modes else 'abs'
        else:
            zm, am = 'zp' + idx, 'abs' + idx
            mode = zm if zp_ok and zm in modes else am
            if mode not in modes:
                mode = zm
        if mode not in modes:
            raise AsmError('bad addressing mode for %s: %s' % (mn, arg))
        return mode, v

    def known_early(self, expr):
        # zero page only for operands whose symbols are defined earlier in the
        # source, so both passes pick the same instruction size
        for t in re.findall(r'[A-Za-z_][A-Za-z0-9_.]*', expr):
            if t.lower() not in self.seen:
                return False
        return True

    def run(self, lines):
        self.pass1 = {}
        for final in (False, True):
            if final:
                self.pass1 = dict(self.sym)
            pc = 0
            out = {}
            self.seen = set()
            for n, raw in enumerate(lines, 1):
                line = raw.split(';', 1)[0].rstrip() if '"' not in raw else self.strip_comment(raw)
                if not line.strip():
                    continue
                try:
                    pc = self.line(line, pc, out, final)
                except AsmError as e:
                    raise AsmError('line %d: %s\n  %s' % (n, e, raw.rstrip()))
        return out

    @staticmethod
    def strip_comment(raw):
        q = False
        for i, ch in enumerate(raw):
            if ch == '"':
                q = not q
            elif ch == ';' and not q:
                return raw[:i].rstrip()
        return raw.rstrip()

    def define(self, name, v, final):
        k = name.lower()
        if k in self.seen and self.sym.get(k) != v:
            raise AsmError('symbol redefined: %s' % name)
        if final and self.pass1.get(k, v) != v:
            raise AsmError('phase error: %s moved from $%04X to $%04X' % (name, self.pass1[k], v))
        self.sym[k] = v
        self.seen.add(k)

    def line(self, line, pc, out, final):
        m = re.match(r'\s*\*\s*=\s*(.+)$', line)
        if m:
            return self.value(m.group(1), pc, True)
        m = re.match(r'([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.+)$', line)
        if m:
            v = self.value(m.group(2), pc, final)
            if v is None:
                raise AsmError('constant must be defined before use: %s' % m.group(1))
            self.define(m.group(1), v, final)
            return pc
        if not line[0].isspace():
            m = re.match(r'([A-Za-z_][A-Za-z0-9_.]*):?(.*)$', line)
            self.define(m.group(1), pc, final)
            line = m.group(2)
            if not line.strip():
                return pc
        parts = line.strip().split(None, 1)
        op = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ''
        if op.startswith('!'):
            return self.directive(op, arg, pc, out, final)
        if op not in OPS:
            raise AsmError('unknown mnemonic: %s' % op)
        mode, v = self.operand(op, arg, pc, final)
        code = OPS[op][mode]
        size = SIZE[mode]
        if final:
            b = [code]
            if mode == 'rel':
                d = v - (pc + 2)
                if not -128 <= d <= 127:
                    raise AsmError('branch out of range (%d)' % d)
                b.append(d & 0xFF)
            elif size == 2:
                if v > 0xFF:
                    raise AsmError('operand does not fit a byte: $%X' % v)
                b.append(v)
            elif size == 3:
                b += [v & 0xFF, v >> 8]
            for i, x in enumerate(b):
                out[pc + i] = x
        return pc + size

    def directive(self, op, arg, pc, out, final):
        if op == '!byte':
            for e in split_args(arg):
                if final:
                    v = self.value(e, pc, True)
                    if v > 0xFF:
                        raise AsmError('byte out of range: %s' % e)
                    out[pc] = v
                pc += 1
            return pc
        if op == '!word':
            for e in split_args(arg):
                if final:
                    v = self.value(e, pc, True)
                    out[pc], out[pc + 1] = v & 0xFF, v >> 8
                pc += 2
            return pc
        if op == '!fill':
            a = split_args(arg)
            n = self.value(a[0], pc, True)
            v = self.value(a[1], pc, True) if len(a) > 1 else 0
            if final:
                for i in range(n):
                    out[pc + i] = v
            return pc + n
        if op == '!text':
            s = arg.strip()
            if len(s) < 2 or s[0] != '"' or s[-1] != '"':
                raise AsmError('!text needs a quoted string')
            for ch in s[1:-1]:
                if final:
                    out[pc] = ord(ch) | 0x80
                pc += 1
            return pc
        raise AsmError('unknown directive: %s' % op)


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        sys.exit(2)
    src, dst = args[0], args[1]
    size, fill, binout = None, 0, None
    i = 2
    while i < len(args):
        if args[i] == '--size':
            size = int(args[i + 1], 0); i += 2
        elif args[i] == '--fill':
            fill = int(args[i + 1], 0); i += 2
        elif args[i] == '--bin':
            binout = args[i + 1]; i += 2
        else:
            raise SystemExit('unknown option ' + args[i])
    a = Asm()
    try:
        out = a.run(open(src).read().splitlines())
    except AsmError as e:
        raise SystemExit('%s: %s' % (src, e))
    base = min(out)
    end = max(out) + 1
    if size is None:
        size = end - base
    if end - base > size:
        raise SystemExit('%s: image is %d bytes, larger than --size %d' % (src, end - base, size))
    img = [out.get(base + i, fill) for i in range(size)]
    with open(dst, 'w') as f:
        for v in img:
            f.write('%02X\n' % v)
    if binout:
        open(binout, 'wb').write(bytes(img))
    code_end = max(k for k in out if k < base + size)
    print('%s: $%04X-$%04X, %d bytes image' % (src, base, code_end, size))


if __name__ == '__main__':
    main()
