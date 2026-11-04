#!/usr/bin/env python3
"""Find BoringSSL's SHA-NI SHA-256 and SHA-1 block functions in a Googlebook recovery image and emit the
fast-path table used by the kernel emulator (isa_emu/isa_emu_fastpath_table.h).

Why: on CPUs without SHA-NI every SHA instruction traps. Two functions account for almost all traps:
sha256_block_data_order_hw (about 56 traps per 64-byte block, dominant during boot) and the SHA-NI path of
sha1_block_data_order (80 traps per block; 90% of all traps once the system runs: package and download
verification). The kernel recognises those exact functions by a hash of their bytes and, at their first
trapping instruction, hashes all remaining blocks natively and returns to the function's `ret`.

The table holds no code: per variant only the function length, three offsets, the 8 opcode bytes at the trap
site (a cheap prefilter) and an FNV-1a hash of the function bytes with the RIP-relative displacement masked
out. A variant is only accepted if the structure the kernel relies on is present byte for byte (where the
working state lives at the trap site, how the loop advances, how the state is stored before `ret`).

  python isa_emu/gen_fastpath.py --recovery recovery_ruby/android-desktop_signed_recovery_image.bin \
      --super-json recovery_ruby/inspect_recovery/super.json --tree recovery_ruby/inspect_recovery/init_boot_a \
      --out-header isa_emu/isa_emu_fastpath_table.h --out-json evidence/isa-emu-fastpath-ruby.json \
      [--dump-dir build/pixelbook/fp]     # raw functions + constants for the fptest harness (not for the repo)
Requires: iced-x86, pyelftools, lz4 (same environment as tools/isa_scan2.py).
"""
import argparse, collections, io, json, pathlib, re, struct, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
import erofs_read as E          # noqa: E402
import isa_scan2 as S           # noqa: E402
from iced_x86 import Decoder, Mnemonic, Code  # noqa: E402

FNV_OFF, FNV_PRIME = 0xCBF29CE484222325, 0x100000001B3

# --- SHA-256: lea rcx,[rip+K256+0x80]; movdqu xmm1,[rdi]; movdqu xmm2,[rdi+0x10]; movdqa xmm7,[rcx+0x180]
SHA256_PROLOGUE = re.compile(rb"\x48\x8d\x0d(....)\xf3\x0f\x6f\x0f\xf3\x0f\x6f\x57\x10\x66\x0f\x6f\xb9\x80\x01\x00\x00", re.S)

# --- SHA-1 (BoringSSL sha1-x86_64 "shaext" path)
# movdqu xmm0,[rdi]; movd xmm1,[rdi+0x10]; movdqa xmm3,[rip+BSWAP]; movdqu xmm4,[rsi]
SHA1_PROLOGUE = re.compile(rb"\xf3\x0f\x6f\x07\x66\x0f\x6e\x4f\x10\x66\x0f\x6f\x1d(....)\xf3\x0f\x6f\x26", re.S)
SHA1_DISP_OFF = 13          # offset of the RIP-relative displacement in the function
SHA1_DISP_NEXT = 17         # offset of the instruction after it (RIP base)
# loop head, ending exactly at the trap site:
#   dec rdx; lea r8,[rsi+0x40]; paddd xmm1,xmm4; cmovne rsi,r8; prefetcht0 [rsi+0x200]; movdqa xmm8,xmm0
SHA1_HEAD = bytes.fromhex("48ffca" "4c8d4640" "660ffecc" "490f45f0" "0f188e00020000" "66440f6fc0")
SHA1_TRAP = bytes.fromhex("0f38c9e5")                      # sha1msg1 xmm4,xmm5
SHA1_E_COPY = bytes.fromhex("66440f6fc9")                  # movdqa xmm9,xmm1 (E kept in xmm9)
# loop tail: paddd xmm0,xmm8; movdqa xmm9,xmm1; jne <loop head>
SHA1_TAIL_A = bytes.fromhex("66410ffec0" "66440f6fc9" "0f85")
# after the loop: pshufd xmm0,xmm0,0x1b; pshufd xmm1,xmm1,0x1b; movdqu [rdi],xmm0; movd [rdi+0x10],xmm1; ret
SHA1_TAIL_B = bytes.fromhex("660f70c01b" "660f70c91b" "f30f7f07" "660f7e4f10" "c3")


def fnv1a_masked(b, mask_off, mask_len):
    h = FNV_OFF
    for i, x in enumerate(b):
        if mask_off <= i < mask_off + mask_len:
            x = 0
        h = ((h ^ x) * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return h


def decode_to_ret(blob, start, limit=2048):
    """Instructions from start up to and including the first ret, or None if anything fails to decode."""
    out = []
    for ins in Decoder(64, blob[start:start + limit], ip=0):
        if ins.code == Code.INVALID:
            return None
        out.append(ins)
        if ins.mnemonic == Mnemonic.RET:
            return out
    return None


def find_sha256(blob):
    for m in SHA256_PROLOGUE.finditer(blob):
        start = m.start()
        insns = decode_to_ret(blob, start)
        if not insns:
            continue
        rnds = [i.ip for i in insns if i.mnemonic == Mnemonic.SHA256RNDS2]
        ret_off = insns[-1].ip
        if len(rnds) != 32:
            continue
        fn = blob[start:ret_off + 1 + start]
        # the trap site must be `sha256rnds2 xmm2, xmm1` (0f 38 cb d1): state ABEF in xmm1, CDGH in xmm2
        if fn[rnds[0]:rnds[0] + 4] != b"\x0f\x38\xcb\xd1":
            continue
        yield {"kind": "ISA_FP_SHA256_BLOCKS", "file_off": start, "len": ret_off + 1, "trap_off": rnds[0],
               "ret_off": ret_off, "mask_off": 3, "mask_len": 4, "head": fn[rnds[0]:rnds[0] + 8].hex(),
               "hash": fnv1a_masked(fn, 3, 4), "disp": struct.unpack("<i", m.group(1))[0], "fn": fn}


def find_sha1(blob):
    for m in SHA1_PROLOGUE.finditer(blob):
        start = m.start()
        insns = decode_to_ret(blob, start)
        if not insns:
            continue
        ret_off = insns[-1].ip
        fn = blob[start:start + ret_off + 1]
        if sum(1 for i in insns if i.mnemonic == Mnemonic.SHA1RNDS4) != 20:
            continue
        trap = next((i.ip for i in insns if i.mnemonic == Mnemonic.SHA1MSG1), None)
        if trap is None or fn[trap:trap + 4] != SHA1_TRAP:
            continue
        head = trap - len(SHA1_HEAD)
        if head <= 0 or fn[head:trap] != SHA1_HEAD:
            continue
        # E must be copied to xmm9 before the loop, and only there and at the loop tail
        if fn.find(SHA1_E_COPY, 0, head) < 0 or fn.count(SHA1_E_COPY) != 2:
            continue
        tail_b = len(fn) - len(SHA1_TAIL_B)
        if fn[tail_b:] != SHA1_TAIL_B:
            continue
        tail_a = tail_b - 4 - len(SHA1_TAIL_A)
        if fn[tail_a:tail_a + len(SHA1_TAIL_A)] != SHA1_TAIL_A:
            continue
        rel = struct.unpack("<i", fn[tail_b - 4:tail_b])[0]
        if tail_b + rel != head:                              # jne goes back to the loop head
            continue
        yield {"kind": "ISA_FP_SHA1_BLOCKS", "file_off": start, "len": len(fn), "trap_off": trap,
               "ret_off": ret_off, "mask_off": SHA1_DISP_OFF, "mask_len": 4, "head": fn[trap:trap + 8].hex(),
               "hash": fnv1a_masked(fn, SHA1_DISP_OFF, 4), "disp": struct.unpack("<i", m.group(1))[0], "fn": fn}


def elf_maps(blob):
    from elftools.elf.elffile import ELFFile
    ef = ELFFile(io.BytesIO(blob))
    loads = [s for s in ef.iter_segments() if s["p_type"] == "PT_LOAD"]

    def va2off(va):
        for s in loads:
            if s["p_vaddr"] <= va < s["p_vaddr"] + s["p_filesz"]:
                return va - s["p_vaddr"] + s["p_offset"]

    def off2va(off):
        for s in loads:
            if s["p_offset"] <= off < s["p_offset"] + s["p_filesz"]:
                return off - s["p_offset"] + s["p_vaddr"]
    return va2off, off2va


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--recovery")
    ap.add_argument("--super-json")
    ap.add_argument("--partitions", nargs="*", default=["system_a", "vendor_a", "product_a", "system_ext_a"])
    ap.add_argument("--tree", action="append", default=[])
    ap.add_argument("--out-header")
    ap.add_argument("--out-json")
    ap.add_argument("--dump-dir")
    a = ap.parse_args()

    variants = collections.OrderedDict()
    dumped = set()

    def dump(kind, f, blob):
        """Raw material for fptest: the function and the constants it addresses (from /system/lib64/libcrypto.so)."""
        d = pathlib.Path(a.dump_dir)
        d.mkdir(parents=True, exist_ok=True)
        va2off, off2va = elf_maps(blob)
        if kind == "ISA_FP_SHA256_BLOCKS":
            (d / "sha256_fn.bin").write_bytes(f["fn"])
            # rcx = start + 7 + disp points at K256 + 0x80; the function reads rcx-0x80 .. rcx+0x190
            rcx = off2va(f["file_off"]) + 7 + f["disp"]
            toff = va2off(rcx - 0x80)
            (d / "sha256_ktab.bin").write_bytes(blob[toff:toff + 0x300])
        else:
            (d / "sha1_fn.bin").write_bytes(f["fn"])
            mask = off2va(f["file_off"]) + SHA1_DISP_NEXT + f["disp"]
            moff = va2off(mask)
            (d / "sha1_bswap.bin").write_bytes(blob[moff:moff + 16])

    def handle(label, path, blob):
        if S.is_x86_64_elf(blob):
            for finder in (find_sha256, find_sha1):
                for f in finder(blob):
                    key = (f["kind"], f["hash"])
                    v = variants.setdefault(key, {k: f[k] for k in ("kind", "len", "trap_off", "ret_off", "mask_off",
                                                                    "mask_len", "head", "hash")} | {"files": []})
                    v["files"].append(f"{label}:{path}")
                    if a.dump_dir and f["kind"] not in dumped and path.endswith("/system/lib64/libcrypto.so"):
                        dump(f["kind"], f, blob)
                        dumped.add(f["kind"])
        elif path.lower().endswith((".apex", ".capex")):
            for p2, b2 in S.iter_apex(path, blob):
                handle(label, p2, b2)

    for t in a.tree:
        root = pathlib.Path(t)
        for p in root.rglob("*"):
            if p.is_file() and p.stat().st_size > 64:
                handle("tree:" + root.name, str(p.relative_to(root)).replace("\\", "/"), p.read_bytes())
    if a.recovery:
        parts = {p["name"]: p["extents"][0]["absolute_offset"]
                 for p in json.load(open(a.super_json))["slots"][0]["partitions"] if p["extents"]}
        with open(a.recovery, "rb") as f:
            for name in a.partitions:
                fs = E.Erofs(f, parts[name])
                for path, blob in S.iter_erofs(fs, ""):
                    handle(name, path, blob)

    vs = list(variants.values())
    for v in vs:
        print(f"{v['kind']}: len={v['len']} trap_off={v['trap_off']} ret_off={v['ret_off']} hash={v['hash']:#018x} "
              f"in {len(v['files'])} ELFs")
    if a.out_json:
        pathlib.Path(a.out_json).write_text(json.dumps({"variants": vs}, indent=1) + "\n")
    if a.out_header:
        lines = ["/* SPDX-License-Identifier: GPL-2.0 */",
                 "/* Generated by isa_emu/gen_fastpath.py. Contains no code: offsets, 8 opcode bytes at the",
                 " * trap site and a hash per known variant of BoringSSL sha256_block_data_order_hw and of the SHA-NI",
                 " * path of sha1_block_data_order. */",
                 "static const struct isa_fastpath isa_fastpaths[] = {"]
        for v in vs:
            head = ", ".join(f"0x{v['head'][i:i + 2]}" for i in range(0, 16, 2))
            lines.append(f"\t{{ {v['kind']}, {{ {head} }}, {v['len']}, {v['trap_off']}, {v['ret_off']}, "
                         f"{v['mask_off']}, {v['mask_len']}, 0x{v['hash']:016x}ULL }},\t/* {len(v['files'])} ELFs */")
        lines.append("};")
        pathlib.Path(a.out_header).write_text("\n".join(lines) + "\n", newline="\n")


if __name__ == "__main__":
    main()
