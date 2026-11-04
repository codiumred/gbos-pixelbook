#!/usr/bin/env python3
"""Minimal read-only EROFS reader (pure Python + lz4) for scanning Android partitions on Windows.

Supports: compact/extended inodes; flat plain, flat inline, chunk-based, and
compressed (full + compact index) data with LZ4 clusters. Not supported: LZMA/
deflate/zstd, fragments, packed inodes, multi-device.

  python tools/erofs_read.py IMAGE --offset N [--ls PATH | --cat PATH | --walk]
"""
import argparse, struct, sys
import lz4.block

MAGIC = 0xE0F5E1E2
S_IFMT, S_IFDIR, S_IFREG, S_IFLNK = 0xF000, 0x4000, 0x8000, 0xA000


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]


class Inode:
    __slots__ = ("nid", "fmt", "layout", "mode", "size", "iu", "isize", "xsize", "base", "ino", "nlink")


class Erofs:
    def __init__(self, f, offset=0):
        self.f, self.off = f, offset
        sb = self.rd(1024, 128)
        if u32(sb, 0) != MAGIC:
            raise ValueError("not EROFS")
        self.blkbits = sb[0x0C]
        self.bsz = 1 << self.blkbits
        self.root_nid = u16(sb, 0x0E)
        self.meta_blk = u32(sb, 0x28)
        self.incompat = u32(sb, 0x50)
        self.blocks = u32(sb, 0x24)
        self.volume = sb[0x40:0x50].rstrip(b"\0").decode(errors="replace")
        if self.incompat & ~0x3F:
            pass  # unknown incompat bits; reads may fail loudly

    def rd(self, pos, n):
        self.f.seek(self.off + pos)
        return self.f.read(n)

    def inode(self, nid):
        base = self.meta_blk * self.bsz + nid * 32
        h = self.rd(base, 64)
        i = Inode()
        i.nid, i.base = nid, base
        i.fmt = u16(h, 0)
        i.layout = (i.fmt >> 1) & 7
        xcnt = u16(h, 2)
        i.mode = u16(h, 4)
        if i.fmt & 1:
            i.isize = 64
            i.size = u64(h, 8)
            i.nlink = u32(h, 44)
        else:
            i.isize = 32
            i.size = u32(h, 8)
            i.nlink = u16(h, 6)
        i.iu = u32(h, 16)
        i.ino = u32(h, 20)
        i.xsize = 12 + (xcnt - 1) * 4 if xcnt else 0
        return i

    # ---- data -----------------------------------------------------------
    def data(self, i, limit=None):
        size = i.size if limit is None else min(i.size, limit)
        if size == 0:
            return b""
        L = i.layout
        if L == 0:
            return self.rd(i.iu * self.bsz, size)
        if L == 2:  # flat inline: full blocks then tail inline after inode+xattr
            nfull = i.size // self.bsz
            out = self.rd(i.iu * self.bsz, nfull * self.bsz) if nfull else b""
            tail = i.size - nfull * self.bsz
            if tail:
                out += self.rd(i.base + i.isize + i.xsize, tail)
            return out[:size]
        if L == 4:
            return self._chunk(i)[:size]
        if L in (1, 3):
            return self._z(i)[:size]
        raise ValueError(f"datalayout {L}")

    def _chunk(self, i):
        fmtbits = i.iu & 0x1F
        indexes = bool(i.iu & 0x20)
        csz = 1 << (self.blkbits + fmtbits)
        n = (i.size + csz - 1) // csz
        pos = (i.base + i.isize + i.xsize + 3) & ~3
        esz = 8 if indexes else 4
        tab = self.rd(pos, n * esz)
        out = bytearray()
        for k in range(n):
            blk = u32(tab, k * esz + (4 if indexes else 0))
            want = min(csz, i.size - k * csz)
            out += b"\0" * want if blk == 0xFFFFFFFF else self.rd(blk * self.bsz, want)
        return bytes(out)

    # ---- compressed ------------------------------------------------------
    def _z(self, i):
        hpos = (i.base + i.isize + i.xsize + 7) & ~7
        h = self.rd(hpos, 8)
        advise = u16(h, 4)
        if h[6] != 0:
            raise ValueError(f"unsupported compression algorithm byte {h[6]:#x}")
        if advise & (0x08 | 0x20):
            raise ValueError(f"unsupported advise {advise:#x} (inline/fragment pcluster)")
        lbits = (h[7] & 7) + self.blkbits
        lsz = 1 << lbits
        nl = (i.size + lsz - 1) // lsz
        ebase = hpos + 8
        heads = self._heads_full(ebase, nl, lsz) if i.layout == 1 else             self._heads_compact(ebase, nl, lbits, advise)
        out = bytearray()
        for n, (start, typ, pblk, cblk) in enumerate(heads):
            end = heads[n + 1][0] if n + 1 < len(heads) else i.size
            want = end - start
            if want <= 0:
                continue
            raw = self.rd(pblk * self.bsz, cblk * self.bsz)
            if typ == 0:
                out += raw[:want]
            else:
                k = 0
                while k < len(raw) and raw[k] == 0:  # LZ4_0PADDING
                    k += 1
                out += lz4.block.decompress(raw[k:], uncompressed_size=want)
        return bytes(out)

    def _heads_full(self, ebase, nl, lsz):
        tab = self.rd(ebase, nl * 8)
        heads, last = [], None
        for k in range(nl):
            adv, cofs, di = struct.unpack_from("<HHI", tab, k * 8)
            t = adv & 3
            if t == 2:
                if last is not None and k == last[0] + 1 and (di & 0xFFFF) & 0x800:
                    heads[-1][3] = (di & 0xFFFF) & 0x7FF
            else:
                heads.append([k * lsz + cofs, t, di, 1])
                last = (k,)
        return heads

    def _heads_compact(self, ebase, nl, lbits, advise):
        lobits = max(lbits, 12)
        lsz = 1 << lbits
        big = bool(advise & 0x02)
        init = ((32 - ebase % 32) // 4) & 7
        if init > nl:
            init = nl
        n2 = ((nl - init) // 16) * 16 if advise & 0x01 else 0
        raw = self.rd(ebase, init * 4 + n2 * 2 + (nl - init - n2) * 4 + 64)

        def locate(lcn):
            if lcn < init:
                return 0, 2, lcn
            lcn -= init
            if lcn < n2:
                return init * 4, 1, lcn
            return init * 4 + n2 * 2, 2, lcn - n2

        def dec(in_off, enc, i):
            bit = enc * i
            v = int.from_bytes(raw[in_off + (bit >> 3):in_off + (bit >> 3) + 4], "little") >> (bit & 7)
            return v & ((1 << lobits) - 1), (v >> lobits) & 3

        def load(lcn):
            reg, sh, rel = locate(lcn)
            vcnt = 2 if sh == 2 else 16
            psz = vcnt << sh
            off = reg + rel * (1 << sh)
            babs = ((ebase + off) // psz) * psz
            base = babs - ebase
            i = (ebase + off - babs) >> sh
            enc = (psz - 4) * 8 // vcnt
            lo, t = dec(base, enc, i)
            if t == 2:
                return t, None, lo, None
            nblk = 0 if big else 1
            j = i
            if not big:
                while j > 0:
                    j -= 1
                    l2, t2 = dec(base, enc, j)
                    if t2 == 2:
                        j -= l2
                    if j >= 0:
                        nblk += 1
            else:
                while j > 0:
                    j -= 1
                    l2, t2 = dec(base, enc, j)
                    if t2 == 2:
                        if l2 & 0x800:
                            j -= 1
                            nblk += l2 & ~0x800
                            continue
                        if l2 <= 1:
                            raise ValueError("bad big-pcluster d0")
                        j -= l2 - 2
                        continue
                    nblk += 1
            trailer = u32(raw, base + psz - 4)
            return t, lo, None, trailer + nblk

        heads = []
        for k in range(nl):
            t, cofs, d0, pblk = load(k)
            if t == 2:
                if big and heads and heads[-1][4] == k - 1 and d0 is not None and d0 & 0x800:
                    heads[-1][3] = d0 & ~0x800
                continue
            heads.append([k * lsz + cofs, t, pblk, 1, k])
        return [tuple(h[:4]) for h in heads]


def dirents(fs, i):
    data = fs.data(i)
    out = []
    for b in range(0, len(data), fs.bsz):
        blk = data[b:b + fs.bsz]
        n = u16(blk, 8) // 12
        offs = [u16(blk, k * 12 + 8) for k in range(n)]
        for k in range(n):
            end = offs[k + 1] if k + 1 < n else len(blk)
            nm = blk[offs[k]:end]
            if k + 1 == n:
                nm = nm.split(b"\0")[0]
            out.append((nm.decode(errors="replace"), u64(blk, k * 12), blk[k * 12 + 10]))
    return [e for e in out if e[0] not in (".", "..")]


def walk(fs, nid=None, path=""):
    """Yield (path, inode) for every non-directory entry."""
    nid = fs.root_nid if nid is None else nid
    i = fs.inode(nid)
    if i.mode & S_IFMT == S_IFDIR:
        for nm, cn, _ in dirents(fs, i):
            yield from walk(fs, cn, f"{path}/{nm}")
    else:
        yield path, i


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--offset", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--probe", action="store_true")
    a = ap.parse_args()
    with open(a.image, "rb") as f:
        fs = Erofs(f, a.offset)
        print("blkbits", fs.blkbits, "root_nid", fs.root_nid, "vol", fs.volume, "incompat", hex(fs.incompat))
        r = fs.inode(fs.root_nid)
        print("root layout", r.layout, "size", r.size, "mode", oct(r.mode))


if __name__ == "__main__":
    main()
