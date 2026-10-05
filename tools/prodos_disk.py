#!/usr/bin/env python3
"""Minimal ProDOS tool for 140K Apple II disk images (.dsk in DOS order, or .po).

    python3 prodos_disk.py DISK list
    python3 prodos_disk.py DISK check
    python3 prodos_disk.py DISK delete NAME [NAME...]
    python3 prodos_disk.py DISK add NAME TYPE AUX FILE     (TYPE/AUX in hex, e.g. FF 2000;
                                                            FILE may be an AppleSingle file)

Only the volume directory is handled (no subdirectories), and files up to 256
blocks (seedling/sapling). Every change rewrites the image in place.
"""
import sys

DOS_OF = [(0, 14), (13, 12), (11, 10), (9, 8), (7, 6), (5, 4), (3, 2), (1, 15)]
TYPES = {0xFF: 'SYS', 0x06: 'BIN', 0xFC: 'BAS', 0x04: 'TXT', 0x0F: 'DIR'}


class Disk:
    def __init__(self, path):
        self.path = path
        self.img = bytearray(open(path, 'rb').read())
        assert len(self.img) == 143360, 'expected a 140K image'
        self.dos = True
        if not self._looks_prodos():
            self.dos = False
            assert self._looks_prodos(), 'no ProDOS volume found'

    def _offs(self, n):
        if not self.dos:
            return n * 512, n * 512 + 256
        t, j = divmod(n, 8)
        a, b = DOS_OF[j]
        return (t * 16 + a) * 256, (t * 16 + b) * 256

    def rd(self, n):
        a, b = self._offs(n)
        return bytearray(self.img[a:a + 256] + self.img[b:b + 256])

    def wr(self, n, d):
        a, b = self._offs(n)
        d = bytes(d) + bytes(512 - len(d))
        self.img[a:a + 256] = d[:256]
        self.img[b:b + 256] = d[256:512]

    def _looks_prodos(self):
        b = self.rd(2)
        return (b[4] >> 4) == 0xF and b[0x23] == 0x27 and b[0x24] == 0x0D

    # --- volume directory -------------------------------------------------
    def dir_blocks(self):
        n, out = 2, []
        while n:
            out.append(n)
            n = int.from_bytes(self.rd(n)[2:4], 'little')
        return out

    def entries(self):
        """(block, offset, entry bytes) for every active file entry"""
        out = []
        for i, n in enumerate(self.dir_blocks()):
            b = self.rd(n)
            for e in range(1 if i == 0 else 0, 13):
                o = 4 + e * 39
                if b[o] >> 4:
                    out.append((n, o, bytes(b[o:o + 39])))
        return out

    def find(self, name):
        for n, o, ent in self.entries():
            if ent[1:1 + (ent[0] & 15)].decode() == name.upper():
                return n, o, ent
        return None

    def header(self):
        return self.rd(2)

    def bitmap_block(self):
        return int.from_bytes(self.header()[0x27:0x29], 'little')

    def total_blocks(self):
        return int.from_bytes(self.header()[0x29:0x2B], 'little')

    # --- block allocation ---------------------------------------------------
    def _bitmap(self):
        return self.rd(self.bitmap_block())

    def is_free(self, n):
        bm = self._bitmap()
        return bool(bm[n // 8] & (0x80 >> (n % 8)))

    def set_free(self, n, free):
        bb = self.bitmap_block()
        bm = self.rd(bb)
        if free:
            bm[n // 8] |= 0x80 >> (n % 8)
        else:
            bm[n // 8] &= ~(0x80 >> (n % 8)) & 0xFF
        self.wr(bb, bm)

    def alloc(self, count):
        got = [n for n in range(self.total_blocks()) if self.is_free(n)][:count]
        if len(got) < count:
            raise SystemExit('disk full: need %d blocks, %d free' % (count, len(got)))
        for n in got:
            self.set_free(n, False)
        return got

    def file_blocks(self, ent):
        st, key = ent[0] >> 4, int.from_bytes(ent[0x11:0x13], 'little')
        if st == 1:
            return [key]
        if st == 2:
            ix = self.rd(key)
            used = int.from_bytes(ent[0x13:0x15], 'little') - 1
            return [key] + [ix[i] | ix[256 + i] << 8 for i in range(256) if (ix[i] | ix[256 + i] << 8)][:used]
        raise SystemExit('storage type %d not supported' % st)

    def read_file(self, ent):
        st, key = ent[0] >> 4, int.from_bytes(ent[0x11:0x13], 'little')
        eof = int.from_bytes(ent[0x15:0x18], 'little')
        if st == 1:
            return bytes(self.rd(key)[:eof])
        ix = self.rd(key)
        data = b''.join(bytes(self.rd(ix[i] | ix[256 + i] << 8)) for i in range((eof + 511) // 512))
        return data[:eof]

    # --- operations ---------------------------------------------------------
    def delete(self, name):
        hit = self.find(name)
        if not hit:
            raise SystemExit('%s: not found' % name)
        n, o, ent = hit
        for blk in self.file_blocks(ent):
            self.set_free(blk, True)
        b = self.rd(n)
        b[o:o + 39] = bytes(39)
        self.wr(n, b)
        h = self.rd(2)
        h[0x25:0x27] = (int.from_bytes(h[0x25:0x27], 'little') - 1).to_bytes(2, 'little')
        self.wr(2, h)

    def add(self, name, ftype, aux, data):
        name = name.upper()
        assert 1 <= len(name) <= 15 and self.find(name) is None, 'bad or duplicate name'
        nblocks = max(1, (len(data) + 511) // 512)
        assert nblocks <= 256, 'files over 128 KB not supported'
        # directory slot
        slot = None
        for i, n in enumerate(self.dir_blocks()):
            b = self.rd(n)
            for e in range(1 if i == 0 else 0, 13):
                if not b[4 + e * 39] >> 4:
                    slot = (n, 4 + e * 39)
                    break
            if slot:
                break
        if not slot:
            raise SystemExit('directory full')
        if nblocks == 1:
            (key,) = self.alloc(1)
            self.wr(key, data)
            storage, used = 1, 1
        else:
            blocks = self.alloc(nblocks + 1)
            key, datab = blocks[0], blocks[1:]
            ix = bytearray(512)
            for i, blk in enumerate(datab):
                ix[i], ix[256 + i] = blk & 0xFF, blk >> 8
                self.wr(blk, data[i * 512:(i + 1) * 512])
            self.wr(key, ix)
            storage, used = 2, nblocks + 1
        ent = bytearray(39)
        ent[0] = storage << 4 | len(name)
        ent[1:1 + len(name)] = name.encode()
        ent[0x10] = ftype
        ent[0x11:0x13] = key.to_bytes(2, 'little')
        ent[0x13:0x15] = used.to_bytes(2, 'little')
        ent[0x15:0x18] = len(data).to_bytes(3, 'little')
        ent[0x1E] = 0xC3                              # access: destroy/rename/write/read
        ent[0x1F:0x21] = aux.to_bytes(2, 'little')
        ent[0x25:0x27] = (2).to_bytes(2, 'little')    # header pointer: volume directory
        n, o = slot
        b = self.rd(n)
        b[o:o + 39] = ent
        self.wr(n, b)
        h = self.rd(2)
        h[0x25:0x27] = (int.from_bytes(h[0x25:0x27], 'little') + 1).to_bytes(2, 'little')
        self.wr(2, h)

    def check(self):
        """bitmap must match the blocks actually in use"""
        used = {0, 1, self.bitmap_block()} | set(self.dir_blocks())
        for _, _, ent in self.entries():
            for blk in self.file_blocks(ent):
                assert blk not in used, 'block %d used twice' % blk
                used.add(blk)
        problems = [n for n in range(self.total_blocks()) if self.is_free(n) == (n in used)]
        count = int.from_bytes(self.header()[0x25:0x27], 'little')
        return problems, len(self.entries()) == count, self.total_blocks() - len(used)

    def save(self):
        open(self.path, 'wb').write(bytes(self.img))


def applesingle_data(blob):
    if blob[:4] != b'\x00\x05\x16\x00':
        return blob
    for i in range(blob[24] << 8 | blob[25]):
        e = blob[26 + i * 12:38 + i * 12]
        if int.from_bytes(e[0:4], 'big') == 1:
            off, ln = int.from_bytes(e[4:8], 'big'), int.from_bytes(e[8:12], 'big')
            return blob[off:off + ln]
    raise SystemExit('AppleSingle file has no data fork')


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    d = Disk(argv[1])
    cmd = argv[2]
    if cmd == 'list':
        for _, _, ent in d.entries():
            name = ent[1:1 + (ent[0] & 15)].decode()
            print('%-16s %-4s %6d  aux=$%04X  blocks=%d' % (
                name, TYPES.get(ent[0x10], '$%02X' % ent[0x10]), int.from_bytes(ent[0x15:0x18], 'little'),
                int.from_bytes(ent[0x1F:0x21], 'little'), int.from_bytes(ent[0x13:0x15], 'little')))
    elif cmd == 'check':
        problems, count_ok, free = d.check()
        print('bitmap mismatches: %s; file count ok: %s; free blocks: %d' % (problems or 'none', count_ok, free))
        sys.exit(1 if problems or not count_ok else 0)
    elif cmd == 'delete':
        for name in argv[3:]:
            d.delete(name)
        d.save()
    elif cmd == 'add':
        name, ftype, aux, src = argv[3], int(argv[4], 16), int(argv[5], 16), argv[6]
        d.add(name, ftype, aux, applesingle_data(open(src, 'rb').read()))
        d.save()
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
