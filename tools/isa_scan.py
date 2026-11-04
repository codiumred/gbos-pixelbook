#!/usr/bin/env python3
r"""
ISA compatibility scanner for Googlebook OS vs. Kaby Lake (Pixelbook 2017).

Scans every ELF in the extracted ramdisk tree AND all ELFs inside the
ext4 partitions embedded in the recovery image (system_b, vendor_a,
product_a, system_ext_a, system_dlkm_a, vendor_dlkm_a).

Uses the GNU objdump from C:\msys64\ucrt64\bin\objdump.exe to disassemble
each .text section and histograms instructions that Kaby Lake cannot execute:

  - gf2p8*          GFNI  (Ice Lake+)
  - vpdp*           AVX-VNNI  (Alder Lake+)
  - vaes*           VAES  (Ice Lake+) -- ymm/zmm only matters; xmm ok on KBL
  - vpclmulqdq      VPCLMULQDQ -- ymm/zmm form (xmm is KBL-safe)
  - %zmm            Any AVX-512 register use  (Knights Landing+ on client)
  - avx512*         Any explicit AVX-512 mnemonic prefix

Outputs JSON to evidence/critical-userspace-isa-scan.json with:
  - per-binary hit counts
  - aggregate totals
  - ELF source (ramdisk/partition name)

Usage:
  python tools/isa_scan.py [--recovery PATH] [--out PATH]

Requires:
  - C:\\msys64\\ucrt64\\bin\\objdump.exe  (binutils 2.40+ for EVEX decoding)
  - Python 3.10+, no extra packages
"""
import argparse, hashlib, json, os, re, struct, subprocess, sys, tempfile
import pathlib, time
from typing import Iterator

OBJDUMP = r"C:\msys64\ucrt64\bin\objdump.exe"

# ---------------------------------------------------------------------------
# Kaby Lake ISA-incompatibility regexes
# ---------------------------------------------------------------------------
# Each tuple: (category, regex_on_mnemonic_or_full_line)
ISA_PATTERNS = [
    ("gf2p8",      re.compile(r"^(v?gf2p8)", re.I)),
    ("avx_vnni",   re.compile(r"^vpdp", re.I)),
    ("vaes_wide",  re.compile(r"^vaes", re.I)),   # vaesenc/vaesd/vaeskeygenassist with ymm/zmm
    ("vpclmul_wide", re.compile(r"^vpclmulqdq", re.I)),
    ("avx512",     re.compile(r"^(v[a-z0-9]+(?:512|[bwdq]z\b)|k[a-z]+[bwdq]?\b)", re.I)),
]
ZMM_RE = re.compile(r"%zmm\d")          # any zmm register in the full line
YMM_RE = re.compile(r"%ymm\d")

def objdump_mnemonics(path: str) -> Iterator[tuple[str, str]]:
    """Yield (mnemonic, full_line) for each decoded instruction."""
    try:
        proc = subprocess.run(
            [OBJDUMP, "-d", "--no-show-raw-insn", path],
            capture_output=True, timeout=120
        )
        for raw_line in proc.stdout.decode(errors="replace").splitlines():
            # Typical line: "   1234:  mov    %rax,%rbx"
            m = re.match(r"^\s+[0-9a-f]+:\s+([a-z][a-z0-9]*)\s*(.*)", raw_line)
            if m:
                yield m.group(1).lower(), raw_line
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"  [WARN] objdump failed on {path}: {e}", file=sys.stderr)

def scan_elf(path: str) -> dict:
    """Return hit counts for this ELF binary."""
    counts = {cat: 0 for cat, _ in ISA_PATTERNS}
    counts["zmm_any"] = 0
    counts["bad_insn"] = 0
    total_insn = 0

    for mnemonic, line in objdump_mnemonics(path):
        total_insn += 1
        if "(bad)" in line:
            counts["bad_insn"] += 1
            continue
        if ZMM_RE.search(line):
            counts["zmm_any"] += 1
        for cat, pat in ISA_PATTERNS:
            if pat.match(mnemonic):
                # Extra filter: vaes/vpclmul in xmm-only form is fine on KBL
                # (Kaby Lake has PCLMULQDQ and AES-NI for xmm)
                if cat in ("vaes_wide", "vpclmul_wide"):
                    if not (ZMM_RE.search(line) or YMM_RE.search(line)):
                        continue  # xmm form — KBL-safe, skip
                counts[cat] += 1
                break

    counts["total_insn"] = total_insn
    return counts


# ---------------------------------------------------------------------------
# ELF detection
# ---------------------------------------------------------------------------
ELF_MAGIC = b"\x7fELF"

def is_elf64_x86(data: bytes) -> bool:
    """Return True if data is a 64-bit x86 ELF (ET_EXEC or ET_DYN)."""
    if len(data) < 19:
        return False
    if data[:4] != ELF_MAGIC:
        return False
    if data[4] != 2:   # EI_CLASS = ELFCLASS64
        return False
    if data[18] not in (62, 0):  # e_machine EM_X86_64 = 62
        return False
    return True


# ---------------------------------------------------------------------------
# Lightweight ext4 reader (read-only, no mount)
# ---------------------------------------------------------------------------
# We need: superblock → block size, inodes per group, inode size.
# Then: walk directory tree from root inode, read file extents.
# This is a minimal implementation sufficient to locate ELFs.

EXT4_SUPERBLOCK_OFFSET = 1024
EXT4_SUPER_MAGIC = 0xEF53

def _u16(b, o): return struct.unpack_from("<H", b, o)[0]
def _u32(b, o): return struct.unpack_from("<I", b, o)[0]
def _u64(b, o): return struct.unpack_from("<Q", b, o)[0]

class Ext4Error(Exception): pass

class Ext4FS:
    """Minimal read-only ext4 walker over a file-like object with a base offset."""

    def __init__(self, fobj, base_offset: int, size: int):
        self.f = fobj
        self.base = base_offset
        self.size = size
        self._read_superblock()

    def _read(self, offset: int, length: int) -> bytes:
        self.f.seek(self.base + offset)
        return self.f.read(length)

    def _read_superblock(self):
        sb = self._read(EXT4_SUPERBLOCK_OFFSET, 1024)
        if _u16(sb, 56) != EXT4_SUPER_MAGIC:
            raise Ext4Error("Not an ext4 filesystem")
        self.block_size  = 1024 << _u32(sb, 24)
        self.inode_size  = _u16(sb, 88)
        self.inodes_per_group = _u32(sb, 40)
        self.blocks_per_group = _u32(sb, 32)
        self.first_data_block = _u32(sb, 20)
        self.total_inodes = _u32(sb, 0)
        self.total_blocks = _u32(sb, 4)
        # 64-bit feature check
        self.feat_incompat = _u32(sb, 96)
        self.desc_size = _u16(sb, 254) if (self.feat_incompat & 0x80) else 32
        self.feature_extents = bool(self.feat_incompat & 0x40)
        self.feature_64bit   = bool(self.feat_incompat & 0x80)
        # Group descriptor table starts at next block after superblock
        gdt_block = self.first_data_block + 1
        self.gdt_offset = gdt_block * self.block_size

    def _read_block(self, block_num: int) -> bytes:
        return self._read(block_num * self.block_size, self.block_size)

    def _get_group_desc(self, group: int) -> bytes:
        return self._read(self.gdt_offset + group * self.desc_size, self.desc_size)

    def _inode_table_block(self, group: int) -> int:
        gd = self._get_group_desc(group)
        lo = _u32(gd, 8)
        hi = _u32(gd, 40) if self.desc_size >= 64 else 0
        return (hi << 32) | lo

    def _read_inode(self, inode_num: int) -> bytes:
        """Read raw inode bytes for 1-based inode_num."""
        group = (inode_num - 1) // self.inodes_per_group
        local = (inode_num - 1) % self.inodes_per_group
        table_block = self._inode_table_block(group)
        offset = table_block * self.block_size + local * self.inode_size
        return self._read(offset, self.inode_size)

    def _inode_size_bytes(self, raw: bytes) -> int:
        lo = _u32(raw, 4)
        hi = _u32(raw, 108)
        return (hi << 32) | lo

    def _inode_mode(self, raw: bytes) -> int:
        return _u16(raw, 0)

    def _read_extent_data(self, raw_inode: bytes, size: int) -> bytes:
        """Read file data using ext4 extents (not block maps)."""
        extent_hdr = raw_inode[40:40+12]
        magic = _u16(extent_hdr, 0)
        if magic != 0xF30A:
            # Might be inline data or block map — skip for now
            return b""
        result = bytearray(size)
        self._walk_extent_tree(extent_hdr, raw_inode[40:], result, size)
        return bytes(result)

    def _walk_extent_tree(self, hdr: bytes, node: bytes, out: bytearray, max_bytes: int):
        magic   = _u16(hdr, 0)
        entries = _u16(hdr, 2)
        depth   = _u16(hdr, 6)
        if magic != 0xF30A:
            return
        for k in range(entries):
            entry = node[12 + k * 12: 24 + k * 12]
            if depth == 0:
                ee_block = _u32(entry, 0)
                ee_len   = _u16(entry, 4)
                if ee_len > 32768:       # uninitialized extent
                    ee_len -= 32768
                ee_start = (_u16(entry, 6) << 32) | _u32(entry, 8)
                lo = ee_block * self.block_size
                if lo >= max_bytes:
                    continue
                want = min(ee_len * self.block_size, max_bytes - lo)
                out[lo:lo + want] = self._read(ee_start * self.block_size, want)
            else:
                leaf_blk = (_u16(entry, 8) << 32) | _u32(entry, 4)
                idx_data = self._read_block(leaf_blk)
                self._walk_extent_tree(idx_data[:12], idx_data, out, max_bytes)

    def _read_file(self, inode_num: int) -> bytes:
        raw = self._read_inode(inode_num)
        size = self._inode_size_bytes(raw)
        if size == 0:
            return b""
        if not self.feature_extents:
            return b""  # block map not implemented
        return self._read_extent_data(raw, size)

    def _iter_dir(self, inode_num: int) -> Iterator[tuple[str, int, int]]:
        """Yield (name, child_inode, file_type) for a directory inode."""
        raw = self._read_inode(inode_num)
        mode = self._inode_mode(raw)
        if (mode & 0xF000) != 0x4000:  # not a directory
            return
        size = self._inode_size_bytes(raw)
        data = self._read_extent_data(raw, size)
        pos = 0
        while pos + 8 <= len(data):
            child_ino = _u32(data, pos)
            rec_len   = _u16(data, pos + 4)
            name_len  = data[pos + 6]
            file_type = data[pos + 7]
            if rec_len == 0:
                break
            if child_ino != 0 and name_len > 0:
                name = data[pos+8:pos+8+name_len].decode(errors="replace")
                if name not in (".", ".."):
                    yield name, child_ino, file_type
            pos += rec_len

    ROOT_INODE = 2

    def walk_elfs(self, prefix: str = "") -> Iterator[tuple[str, int]]:
        """Walk entire tree, yield (virtual_path, inode_num) for ELF files."""
        yield from self._walk_dir(self.ROOT_INODE, prefix)

    def _walk_dir(self, inode_num: int, path: str) -> Iterator[tuple[str, int]]:
        try:
            for name, child_ino, ftype in self._iter_dir(inode_num):
                child_path = f"{path}/{name}"
                if ftype == 2:  # directory
                    yield from self._walk_dir(child_ino, child_path)
                elif ftype in (1, 0):  # regular file or unknown
                    # Peek at first 4 bytes to check ELF magic
                    raw = self._read_inode(child_ino)
                    size = self._inode_size_bytes(raw)
                    if size >= 20:
                        header = self._read_extent_data(raw, 20)
                        if is_elf64_x86(header):
                            yield child_path, child_ino
        except Exception as e:
            pass  # skip unreadable dirs

    def extract_to_temp(self, inode_num: int, suffix: str = "") -> str | None:
        """Extract inode content to a temp file; return path or None on failure."""
        try:
            data = self._read_file(inode_num)
            if not data:
                return None
            fd, tmp = tempfile.mkstemp(suffix=suffix)
            os.write(fd, data)
            os.close(fd)
            return tmp
        except Exception as e:
            return None


# ---------------------------------------------------------------------------
# Scan already-extracted ramdisk tree
# ---------------------------------------------------------------------------
def scan_extracted(root: pathlib.Path) -> list[dict]:
    results = []
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix in (".json", ".txt", ".img", ".cpio", ".ko"):
            continue
        # Read first 20 bytes for ELF header detection (needs e_machine at offset 18-19)
        try:
            header = p.read_bytes()[:20]
        except Exception:
            continue
        if not is_elf64_x86(header):
            continue
        rel = str(p.relative_to(root))
        print(f"  [ramdisk] {rel}")
        counts = scan_elf(str(p))
        counts["path"] = rel
        counts["source"] = "ramdisk"
        counts["sha256"] = hashlib.sha256(p.read_bytes()).hexdigest()
        results.append(counts)
    return results


# ---------------------------------------------------------------------------
# Scan ext4 partition inside recovery image
# ---------------------------------------------------------------------------
def scan_partition(image_path: str, offset: int, size: int, part_name: str) -> list[dict]:
    results = []
    print(f"\n  Scanning partition {part_name} @ offset {offset:#x} ({size // 1024 // 1024} MiB)")
    try:
        with open(image_path, "rb") as f:
            fs = Ext4FS(f, offset, size)
            for vpath, ino in fs.walk_elfs():
                print(f"    [ext4:{part_name}] {vpath}")
                tmp = fs.extract_to_temp(ino, suffix=".elf")
                if tmp is None:
                    print(f"      [WARN] could not extract {vpath}")
                    continue
                try:
                    tmp_data = open(tmp, "rb").read()
                    counts = scan_elf(tmp)
                    counts["path"] = vpath
                    counts["source"] = part_name
                    counts["sha256"] = hashlib.sha256(tmp_data).hexdigest()
                    results.append(counts)
                finally:
                    try:
                        os.unlink(tmp)
                    except Exception:
                        pass
    except Ext4Error as e:
        print(f"  [WARN] {part_name}: {e}")
    except Exception as e:
        print(f"  [ERROR] {part_name}: {e}")
    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
RECOVERY_DEFAULT = r"recovery_ruby\android-desktop_signed_recovery_image.bin"
SUPER_JSON_DEFAULT = r"recovery_ruby\inspect_recovery\super.json"
RAMDISK_ROOT_DEFAULT = r"recovery_ruby\inspect_recovery"
OUT_DEFAULT = r"evidence\critical-userspace-isa-scan.json"

# Partitions of interest (slot _a only; _b has the full Google userspace)
# Actually system_b is the FULL OS, system_a is recovery-minimal.
# From super.json slot 0: system_b @ 1882193920, vendor_a @ 6289358848, etc.
# BUT looking carefully: the partitions map as:
#   slot 0 = _a partitions (recovery/minimal), _b = full Google OS
# Actually from REPORT.md §2: "system_b" is the full Android userspace shipped
# with the device. We should scan it.
PARTITIONS_OF_INTEREST = [
    # name pattern to match in super.json
    "system_b",
    "vendor_a",
    "product_a",
    "system_ext_a",
    "system_dlkm_a",
    "vendor_dlkm_a",
]

def load_partition_map(super_json_path: str) -> dict[str, dict]:
    """Load super.json and return a map of partition name → extent info for slot 0."""
    data = json.loads(pathlib.Path(super_json_path).read_text())
    result = {}
    slot0 = data["slots"][0]
    for p in slot0["partitions"]:
        if p["extents"]:
            result[p["name"]] = {
                "offset": p["extents"][0]["absolute_offset"],
                "bytes":  p["bytes"],
            }
    return result


def aggregate(results: list[dict]) -> dict:
    total = {cat: 0 for cat, _ in ISA_PATTERNS}
    total["zmm_any"] = 0
    total["bad_insn"] = 0
    total["total_insn"] = 0
    affected_binaries = set()
    for r in results:
        for k in total:
            total[k] += r.get(k, 0)
        any_hit = any(r.get(cat, 0) > 0 for cat, _ in ISA_PATTERNS if cat not in ("vaes_wide",))
        any_hit = any_hit or r.get("zmm_any", 0) > 0
        if any_hit:
            affected_binaries.add(f"{r['source']}:{r['path']}")
    total["affected_binary_count"] = len(affected_binaries)
    return total


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--recovery", default=RECOVERY_DEFAULT, help="Path to recovery .bin image")
    p.add_argument("--super-json", default=SUPER_JSON_DEFAULT)
    p.add_argument("--ramdisk-root", default=RAMDISK_ROOT_DEFAULT)
    p.add_argument("--out", default=OUT_DEFAULT)
    p.add_argument("--ramdisk-only", action="store_true", help="Only scan extracted ramdisk (fast mode)")
    p.add_argument("--partitions", nargs="*", default=PARTITIONS_OF_INTEREST,
                   help="Which partition names to scan (from super.json)")
    args = p.parse_args()

    if not pathlib.Path(OBJDUMP).exists():
        print(f"ERROR: objdump not found at {OBJDUMP}", file=sys.stderr)
        sys.exit(1)

    all_results = []
    t0 = time.time()

    # 1) Scan extracted ramdisk tree
    ramdisk_root = pathlib.Path(args.ramdisk_root)
    print(f"\n=== Scanning extracted ramdisk tree: {ramdisk_root} ===")
    all_results += scan_extracted(ramdisk_root)

    # 2) Scan ext4 partitions inside the recovery image
    if not args.ramdisk_only:
        if not pathlib.Path(args.recovery).exists():
            print(f"\n[WARN] Recovery image not found: {args.recovery} — skipping partition scan")
        else:
            part_map = load_partition_map(args.super_json)
            for part_name in args.partitions:
                if part_name not in part_map:
                    print(f"  [WARN] {part_name} not in super.json, skipping")
                    continue
                info = part_map[part_name]
                all_results += scan_partition(
                    args.recovery,
                    info["offset"],
                    info["bytes"],
                    part_name,
                )

    # 3) Output
    totals = aggregate(all_results)
    elapsed = time.time() - t0

    output = {
        "scan_tool": "isa_scan.py (objdump 2.46 + Python ext4 reader)",
        "objdump": OBJDUMP,
        "elapsed_seconds": round(elapsed, 1),
        "kaby_lake_incompatible_features": {
            "gf2p8": "GFNI (Ice Lake+)",
            "avx_vnni": "AVX-VNNI / vpdp (Alder Lake+)",
            "vaes_wide": "VAES ymm/zmm (Ice Lake+; xmm form safe on KBL)",
            "vpclmul_wide": "VPCLMULQDQ ymm/zmm (Ice Lake+; xmm safe on KBL)",
            "avx512": "AVX-512 mnemonics",
            "zmm_any": "Any zmm register use",
        },
        "totals": totals,
        "binaries": all_results,
    }

    out_path = pathlib.Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2) + "\n")
    print(f"\n=== Done in {elapsed:.0f}s ===")
    print(f"Scanned {len(all_results)} ELFs, {totals['affected_binary_count']} with incompatible hits")
    print(f"Output: {out_path}")
    for cat in list(dict(ISA_PATTERNS)) + ["zmm_any"]:
        n = totals.get(cat, 0)
        if n:
            print(f"  {cat}: {n} hits")


if __name__ == "__main__":
    main()
