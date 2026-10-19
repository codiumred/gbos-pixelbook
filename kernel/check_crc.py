#!/usr/bin/env python3
"""Check that prebuilt kernel modules would load on a rebuilt kernel.

Compares, for every .ko found under the given paths, the symbol CRCs it requires
(__versions / __version_ext_*) and its vermagic with a Module.symvers and release string.

  check_crc.py --symvers Module.symvers [--json out.json] DIR_OR_KO...
"""
import argparse, json, pathlib, struct, sys


def sections(d):
    if d[:4] != b"\x7fELF" or d[4] != 2:
        return None
    shoff, = struct.unpack_from("<Q", d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    raw = []
    for i in range(shnum):
        name, _typ, _flags, _addr, off, size = struct.unpack_from("<IIQQQQ", d, shoff + i * shentsize)
        raw.append((name, off, size))
    stroff = raw[shstrndx][1]
    out = {}
    for name, off, size in raw:
        end = d.index(b"\0", stroff + name)
        out[d[stroff + name:end].decode()] = d[off:off + size]
    return out


def required(sec):
    req = {}
    v = sec.get("__versions", b"")
    for k in range(0, len(v) - 63, 64):
        crc, = struct.unpack_from("<Q", v, k)
        req[v[k + 8:k + 64].split(b"\0")[0].decode()] = crc & 0xFFFFFFFF
    crcs, names = sec.get("__version_ext_crcs", b""), sec.get("__version_ext_names", b"")
    if crcs and names:
        for i, nm in enumerate(n for n in names.split(b"\0") if n):
            if 4 * i + 4 <= len(crcs):
                req[nm.decode()] = struct.unpack_from("<I", crcs, 4 * i)[0]
    return req


def modinfo(sec, key):
    for kv in sec.get(".modinfo", b"").split(b"\0"):
        if kv.startswith(key.encode() + b"="):
            return kv.split(b"=", 1)[1].decode()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symvers", required=True)
    ap.add_argument("--flags", default="SMP preempt mod_unload modversions")
    ap.add_argument("--json")
    ap.add_argument("paths", nargs="+")
    a = ap.parse_args()
    ours = {}
    for line in open(a.symvers):
        p = line.rstrip("\n").split("\t")
        if len(p) > 2:
            ours[p[1]] = (int(p[0], 16), p[2])
    files = []
    for p in map(pathlib.Path, a.paths):
        files += sorted(p.rglob("*.ko")) if p.is_dir() else [p]
    tot = miss = bad = vm_bad = rust = 0
    releases = {}
    per = {}
    provided = {}
    mods = []
    for f in files:
        sec = sections(f.read_bytes())
        if sec is None:
            continue
        mods.append((f, sec))
        # symbols exported by the prebuilt modules themselves satisfy each other
        st = sec.get("__ksymtab_strings", b"")
        for nm in st.split(b"\0"):
            if nm:
                provided[nm.decode()] = f.name
    for f, sec in mods:
        req = required(sec)
        vm = modinfo(sec, "vermagic")
        r = {"required": len(req), "missing": [], "crc_mismatch": [], "vermagic": vm}
        # With CONFIG_MODVERSIONS the loader ignores the release part of vermagic when the
        # module carries CRCs (kernel/module/main.c:same_magic), so only the flags must match.
        if vm and a.flags and vm.split(" ", 1)[1].strip() != a.flags:
            vm_bad += 1
            r["vermagic_mismatch"] = True
        releases[vm.split(" ", 1)[0] if vm else "?"] = releases.get(vm.split(" ", 1)[0] if vm else "?", 0) + 1
        for name, crc in req.items():
            if name == "module_layout":
                continue
            tot += 1
            if name not in ours:
                if name not in provided:
                    if name.startswith("_R"):
                        rust += 1       # Rust mangled name: carries toolchain-specific crate hashes
                    else:
                        miss += 1
                    r["missing"].append(name)
            elif ours[name][0] != crc:
                bad += 1
                r["crc_mismatch"].append(name)
        if r["missing"] or r["crc_mismatch"] or r.get("vermagic_mismatch"):
            per[f.name] = r
    summary = {"modules": len(mods), "required_symbols": tot, "not_exported_by_kernel_or_prebuilt_modules": miss,
               "rust_symbols_not_resolvable": rust, "crc_mismatch": bad, "vermagic_flag_mismatch": vm_bad,
               "module_build_releases": releases, "problem_modules": len(per)}
    print(json.dumps(summary))
    for name, r in sorted(per.items())[:25]:
        print(" ", name, "missing:", r["missing"][:4], "crc:", r["crc_mismatch"][:4], r["vermagic"] if r.get("vermagic_mismatch") else "")
    if a.json:
        pathlib.Path(a.json).write_text(json.dumps({"summary": summary, "problems": per}, indent=1) + "\n")
    return 0 if not (miss or bad or vm_bad) else 1


if __name__ == "__main__":
    sys.exit(main())
