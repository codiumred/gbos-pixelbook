#!/usr/bin/env python3
"""Convert an Android sparse image to a raw (sparse-on-disk) file: unsparse.py IN OUT"""
import struct, sys
def main(src, dst):
    f = open(src, 'rb'); o = open(dst, 'wb')
    magic, major, minor, fh, ch, bsz, tblk, nch, crc = struct.unpack('<IHHHHIIII', f.read(28))
    assert magic == 0xED26FF3A
    f.seek(fh); pos = 0
    for _ in range(nch):
        t, _, n, tsz = struct.unpack('<HHII', f.read(12)); size = n * bsz
        if t == 0xCAC1:
            o.seek(pos); o.write(f.read(size))
        elif t == 0xCAC2:
            fill = f.read(4); o.seek(pos); o.write(fill * (size // 4))
        elif t == 0xCAC3: pass
        elif t == 0xCAC4: f.read(4)
        else: raise ValueError(hex(t))
        pos += size
    o.truncate(tblk * bsz); o.close()
main(*sys.argv[1:3])
