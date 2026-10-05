#!/usr/bin/env python3
"""Build the card test disks: CardTest.dsk (140K floppy) and hdd1.po (2 MB hard disk).

    python3 mkdisks.py BASE.dsk cardtest.sys OUTDIR

BASE.dsk is a 140K ProDOS disk whose ProDOS runs on a 6502 IIe (8 v2.4.x), such as
"IP65 Net Tools (6502).dsk"; its ProDOS and boot blocks are reused. cardtest.sys is
the AppleSingle file cl65 writes (see build.sh). Both disks boot straight into
CARDTEST.SYSTEM. hdd1.po is named so a2hostd mounts it as hard disk 1 by itself;
the volume is /HDTEST, the name cardtest looks for before its block write test.
"""
import os
import sys
from prodos_disk import Disk, applesingle_data

HDD_BLOCKS = 4096          # one bitmap block


def set_volume_name(d, name):
    h = d.header()
    h[4] = 0xF0 | len(name)
    h[5:20] = name.encode().ljust(15, b'\0')
    d.wr(2, h)


class PoDisk(Disk):
    """A blank ProDOS-order volume of any size up to 4096 blocks."""

    def __init__(self, nblocks, name, boot_blocks):
        self.path, self.dos = None, False
        self.img = bytearray(nblocks * 512)
        self.wr(0, boot_blocks[0])
        self.wr(1, boot_blocks[1])
        for n in range(2, 6):                       # volume directory, blocks 2-5
            b = bytearray(512)
            b[0:2] = (n - 1 if n > 2 else 0).to_bytes(2, 'little')
            b[2:4] = (n + 1 if n < 5 else 0).to_bytes(2, 'little')
            self.wr(n, b)
        h = self.rd(2)
        h[0x22], h[0x23], h[0x24] = 0xC3, 0x27, 0x0D    # access, entry length, entries per block
        h[0x27:0x29] = (6).to_bytes(2, 'little')         # bitmap block
        h[0x29:0x2B] = nblocks.to_bytes(2, 'little')
        self.wr(2, h)
        set_volume_name(self, name)
        bm = bytearray(b'\xff' * (nblocks // 8))
        for n in range(7):                          # boot, directory, bitmap in use
            bm[n // 8] &= ~(0x80 >> (n % 8)) & 0xFF
        self.wr(6, bm)


def main(base, sysfile, outdir):
    prog = applesingle_data(open(sysfile, 'rb').read())
    src = Disk(base)
    _, _, ent = src.find('PRODOS')
    prodos = src.read_file(ent)

    flop = Disk(base)
    for _, _, e in list(flop.entries()):
        name = e[1:1 + (e[0] & 15)].decode()
        if name != 'PRODOS':
            flop.delete(name)
    flop.add('CARDTEST.SYSTEM', 0xFF, 0x2000, prog)
    set_volume_name(flop, 'CARDTEST')
    problems, count_ok, free = flop.check()
    assert not problems and count_ok, (problems, count_ok)
    flop.path = os.path.join(outdir, 'CardTest.dsk')
    flop.save()
    print('%s: PRODOS + CARDTEST.SYSTEM (%d bytes), %d blocks free' % (flop.path, len(prog), free))

    hdd = PoDisk(HDD_BLOCKS, 'HDTEST', (src.rd(0), src.rd(1)))
    hdd.add('PRODOS', 0xFF, 0x0000, prodos)
    hdd.add('CARDTEST.SYSTEM', 0xFF, 0x2000, prog)
    problems, count_ok, free = hdd.check()
    assert not problems and count_ok, (problems, count_ok)
    hdd.path = os.path.join(outdir, 'hdd1.po')
    hdd.save()
    print('%s: /HDTEST, %d blocks, PRODOS + CARDTEST.SYSTEM, %d blocks free' % (hdd.path, HDD_BLOCKS, free))


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
