#!/usr/bin/env python3
"""CPUID-feature scan of every x86-64 ELF in Googlebook recovery partitions (EROFS + APEX).

Unlike tools/isa_scan.py (objdump regexes, ramdisk only), this decodes executable
sections with iced-x86, maps each instruction to its CPUID feature, and reports
features Kaby Lake (Pixelbook i5-7Y57) lacks, per ELF and per containing symbol.
Output is a JSON summary (no raw disassembly).

  python -I tools/isa_scan2.py --recovery recovery_ruby/android-desktop_signed_recovery_image.bin \
      --super-json recovery_ruby/inspect_recovery/super.json --out evidence/isa-scan2-ruby.json
  python -I tools/isa_scan2.py --tree recovery_ruby/inspect_recovery/vendor_boot_a --out ...
Requires: pip install iced-x86 pyelftools lz4
"""
import argparse, bisect, collections, hashlib, io, json, pathlib, struct, sys, time, zipfile
from iced_x86 import Decoder, CpuidFeature, Code, Mnemonic, OpKind, Register
from elftools.elf.elffile import ELFFile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import erofs_read as E

CF = CpuidFeature
_NAMES = {getattr(CF, n): n for n in dir(CF) if n.isupper() and not n.startswith("_")}
NOT_KBL = {n for n in _NAMES.values() if n.startswith(("AVX512", "AMX", "AVX_VNNI", "SM3", "SM4", "KL", "WIDE_KL"))} | {
    "AVX_IFMA", "AVX_NE_CONVERT", "GFNI", "VAES", "VPCLMULQDQ", "SHA", "SHA512", "RDPID", "CLWB", "CLDEMOTE",
    "MOVDIR64B", "MOVDIRI", "ENQCMD", "WAITPKG", "SERIALIZE", "UINTR", "CMPCCXADD", "RAO_INT", "PREFETCHITI",
    "HRESET", "PCONFIG", "PTWRITE", "TSXLDTRK", "LKGS", "FRED", "MSRLIST", "WRMSRNS", "WBNOINVD", "AESKLE"}
_code_feats = {}
_CODE = {getattr(Code, n): n for n in dir(Code) if n.isupper() and not n.startswith('_')}
_MN = {getattr(Mnemonic, n): n.lower() for n in dir(Mnemonic) if n.isupper() and not n.startswith('_')}


def feats_of(code, instr):
    r = _code_feats.get(code)
    if r is None:
        r = tuple(n for n in (_NAMES[f] for f in instr.cpuid_features()) if n in NOT_KBL)
        _code_feats[code] = r
    return r


def is_x86_64_elf(b):
    return len(b) >= 20 and b[:4] == b"\x7fELF" and b[4] == 2 and struct.unpack_from("<H", b, 18)[0] == 62


def scan_elf(b):
    res = {"feat": collections.Counter(), "insn": 0, "bad": 0, "cpuid_insn": 0, "hits": []}
    ef = ELFFile(io.BytesIO(b))
    ifuncs = 0
    syms = []
    for secname in (".dynsym", ".symtab"):
        s = ef.get_section_by_name(secname)
        if s is None or not hasattr(s, "iter_symbols"):
            continue
        for sy in s.iter_symbols():
            if sy["st_info"]["type"] in ("STT_FUNC", "STT_GNU_IFUNC") and sy["st_value"]:
                syms.append((sy["st_value"], sy["st_size"], sy.name, sy["st_info"]["type"] == "STT_GNU_IFUNC"))
                ifuncs += sy["st_info"]["type"] == "STT_GNU_IFUNC"
    syms.sort()
    starts = [s[0] for s in syms]
    res["ifunc_symbols"] = ifuncs
    per_sym = collections.Counter()
    mnem = collections.Counter()
    forms = collections.Counter()
    for sec in ef.iter_sections():
        if not (sec["sh_flags"] & 4) or sec["sh_type"] != "SHT_PROGBITS":
            continue
        data = sec.data()
        dec = Decoder(64, data, ip=sec["sh_addr"])
        for ins in dec:
            if ins.code == Code.INVALID:
                res["bad"] += 1
                continue
            res["insn"] += 1
            code = ins.code
            fs = _code_feats.get(code)
            if fs is None:
                fs = feats_of(code, ins)
            if fs:
                for f in fs:
                    res["feat"][f] += 1
                mnem[_MN.get(ins.mnemonic, str(ins.mnemonic))] += 1
                form = _CODE.get(code, str(code))
                if any(ins.op_kind(i) == OpKind.MEMORY for i in range(ins.op_count)):
                    form += "|mem"
                    if ins.segment_prefix != Register.NONE:
                        form += "|seg"
                    if ins.memory_base == Register.RIP:
                        form += "|rip"
                    if ins.memory_base in (Register.EIP,) or (ins.memory_base != Register.NONE and ins.memory_base != Register.RIP and Register.EAX <= ins.memory_base <= Register.R15D):
                        form += "|a32"
                forms[form] += 1
                k = bisect.bisect_right(starts, ins.ip) - 1
                nm = "?"
                if k >= 0 and syms[k][0] <= ins.ip < syms[k][0] + max(syms[k][1], 1):
                    nm = syms[k][2]
                per_sym[nm] += 1
    res["mnemonics"] = dict(mnem)
    res["forms"] = dict(forms)
    res["top_symbols"] = per_sym.most_common(12)
    res["hit_symbols"] = len(per_sym)
    res["unnamed_hits"] = per_sym.get("?", 0)
    del res["hits"]
    res["feat"] = dict(res["feat"])
    return res


def iter_erofs(fs, prefix):
    for path, i in E.walk(fs):
        if i.mode & E.S_IFMT != E.S_IFREG or i.size < 64:
            continue
        head = fs.data(i, 64)
        low = path.lower()
        if is_x86_64_elf(head) or low.endswith((".apex", ".capex")):
            yield prefix + path, fs.data(i)


def iter_apex(label, blob):
    try:
        z = zipfile.ZipFile(io.BytesIO(blob))
    except zipfile.BadZipFile:
        return
    names = z.namelist()
    if "original_apex" in names:  # .capex wrapper
        yield from iter_apex(label, z.read("original_apex"))
        return
    if "apex_payload.img" not in names:
        return
    img = z.read("apex_payload.img")
    f = io.BytesIO(img)
    try:
        fs = E.Erofs(f, 0)
    except ValueError:
        fs = None
    if fs is not None:
        for p, b in iter_erofs(fs, label + "!"):
            yield p, b
        return
    try:
        import ext4_lite
        yield from ext4_lite.iter_elfs(img, label + "!")
    except Exception as e:  # noqa
        print(f"  [WARN] APEX {label}: payload not EROFS and ext4 reader failed: {e}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--recovery")
    ap.add_argument("--super-json")
    ap.add_argument("--partitions", nargs="*",
                    default=["system_a", "system_b", "vendor_a", "product_a", "system_ext_a", "system_dlkm_a", "vendor_dlkm_a"])
    ap.add_argument("--tree", action="append", default=[], help="directory of extracted files")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    results, t0 = [], time.time()
    seen = set()

    def handle(label, path, blob):
        if is_x86_64_elf(blob):
            h = hashlib.sha256(blob).hexdigest()
            r = {"source": label, "path": path, "sha256": h, "size": len(blob)}
            if h in seen:
                r["duplicate_of_earlier"] = True
            seen.add(h)
            try:
                r.update(scan_elf(blob))
            except Exception as e:
                r["error"] = repr(e)[:120]
            results.append(r)
        elif path.lower().endswith((".apex", ".capex")):
            for p2, b2 in iter_apex(path, blob):
                handle(label, p2, b2)

    for t in a.tree:
        root = pathlib.Path(t)
        for p in root.rglob("*"):
            if p.is_file() and p.stat().st_size > 64:
                handle("tree:" + root.name, str(p.relative_to(root)), p.read_bytes())
    if a.recovery:
        parts = {p["name"]: p["extents"][0]["absolute_offset"]
                 for p in json.load(open(a.super_json))["slots"][0]["partitions"] if p["extents"]}
        with open(a.recovery, "rb") as f:
            for name in a.partitions:
                fs = E.Erofs(f, parts[name])
                n0 = len(results)
                for path, blob in iter_erofs(fs, ""):
                    handle(name, path, blob)
                print(f"{name}: {len(results) - n0} ELFs ({time.time() - t0:.0f}s)", flush=True)

    tot = collections.Counter()
    mtot = collections.Counter()
    ftot = collections.Counter()
    affected = 0
    for r in results:
        if r.get("feat"):
            affected += 1
            tot.update(r["feat"])
            mtot.update(r["mnemonics"])
            ftot.update(r.get("forms", {}))
    out = {"tool": "isa_scan2.py (iced-x86 CPUID features; target = Kaby Lake)",
           "not_kbl_features": sorted(NOT_KBL), "elapsed_s": round(time.time() - t0),
           "elf_count": len(results), "elf_with_hits": affected, "feature_totals": dict(tot), "mnemonic_totals": dict(mtot), "form_totals": dict(ftot), "binaries": results}
    p = pathlib.Path(a.out)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(out, indent=1))
    print(f"{len(results)} ELFs, {affected} with non-Kaby-Lake instructions; totals: {dict(tot)}")


if __name__ == "__main__":
    main()
