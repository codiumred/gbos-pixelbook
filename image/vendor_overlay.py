#!/usr/bin/env python3
"""Add files to the gbrunch-derived vendor partition (GBVENDOR) of an assembled image.

  vendor_overlay.py <image.raw> <work dir> <dest path in vendor>=<local file>[:<selinux label>] ...

1. Reads the GBVENDOR EROFS image out of the disk image.
2. Appends the files with mkfs.erofs --incremental (the same method gbrunch uses), each carrying
   uid/gid 0, mode 0644 and its SELinux label as an xattr (default vendor_firmware_file).
3. Writes the result back in place if it still fits; otherwise renames the old GPT entry to
   GBVENDOR_OLD, appends a new GBVENDOR partition at the end of the image (keeping the original
   unique GUID) and rewrites both GPT copies. fstab mounts by name, so nothing else changes.
Operates on a regular image file only.
"""
import hashlib, io, os, pathlib, struct, subprocess, sys, tarfile, uuid, zlib

SECTOR = 512
MIB = 1 << 20
LINUX_DATA = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")


def read_gpt(f):
    f.seek(0)
    mbr = bytearray(f.read(SECTOR))
    hdr = bytearray(f.read(SECTOR))
    assert hdr[:8] == b"EFI PART", "no GPT"
    tlba, count, esz = struct.unpack_from("<QII", hdr, 72)
    f.seek(tlba * SECTOR)
    table = bytearray(f.read(count * esz))
    return mbr, hdr, table, tlba, count, esz


def entries(table, count, esz):
    for i in range(count):
        e = table[i * esz:(i + 1) * esz]
        if any(e[:16]):
            name = e[56:128].decode("utf-16le").split("\0")[0]
            first, last = struct.unpack_from("<QQ", e, 32)
            yield i, name, first, last


def write_gpt(f, mbr, hdr, table, tlba, last_lba):
    ts = (len(table) + SECTOR - 1) // SECTOR
    struct.pack_into("<Q", hdr, 32, last_lba)             # backup header LBA
    struct.pack_into("<Q", hdr, 48, last_lba - ts - 1)    # last usable LBA
    struct.pack_into("<I", hdr, 88, zlib.crc32(table))
    struct.pack_into("<I", hdr, 16, 0)
    struct.pack_into("<I", hdr, 16, zlib.crc32(hdr[:92]))
    bak = bytearray(hdr)
    struct.pack_into("<QQ", bak, 24, last_lba, 1)
    struct.pack_into("<Q", bak, 72, last_lba - ts)
    struct.pack_into("<I", bak, 16, 0)
    struct.pack_into("<I", bak, 16, zlib.crc32(bak[:92]))
    struct.pack_into("<I", mbr, 458, min(last_lba, 0xFFFFFFFF))
    for pos, b in ((0, mbr), (SECTOR, hdr), (tlba * SECTOR, table),
                   ((last_lba - ts) * SECTOR, table), (last_lba * SECTOR, bak)):
        f.seek(pos)
        f.write(b)
    f.truncate((last_lba + 1) * SECTOR)


def main():
    img, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    specs = []
    for a in sys.argv[3:]:
        dest, _, rest = a.partition("=")
        local, _, label = rest.partition(":")
        specs.append((dest.lstrip("/"), pathlib.Path(local), label or "u:object_r:vendor_firmware_file:s0"))
    work.mkdir(parents=True, exist_ok=True)

    with img.open("r+b") as f:
        mbr, hdr, table, tlba, count, esz = read_gpt(f)
        parts = {n: (i, a, b) for i, n, a, b in entries(table, count, esz)}
        idx, first, last = parts["GBVENDOR"]
        f.seek(first * SECTOR)
        sb = f.read(2048)
        blocks = struct.unpack_from("<I", sb, 1024 + 0x24)[0]
        bsz = 1 << sb[1024 + 0x0C]
        f.seek(first * SECTOR)
        vendor = work / "vendor.erofs"
        vendor.write_bytes(f.read(blocks * bsz))

    # Parent directories must be in the tar with their original metadata and labels, or the
    # incremental build recreates them unlabeled (method from gbrunch tools/build_vendor_view.py).
    parents = sorted({"/".join(pathlib.PurePosixPath(d).parts[:i])
                      for d, _, _ in specs for i in range(1, len(pathlib.PurePosixPath(d).parts))})
    dmeta = {}
    existing = set()          # parents that are already in the image (checked for label drift afterwards)
    (work / "meta").mkdir(parents=True, exist_ok=True)

    def dir_meta(d):
        """(mode, uid, gid, label) of a directory in the image; a directory that does not exist yet
        inherits from its nearest existing ancestor."""
        x = work / "meta" / d.replace("/", "_")
        subprocess.run(["rm", "-rf", str(x)], check=True)
        r = subprocess.run(["fsck.erofs", "--xattrs", f"--extract={x}", f"--path=/{d}", str(vendor)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode != 0 or not os.path.isdir(x):
            return dir_meta(str(pathlib.PurePosixPath(d).parent))[0], False
        st = os.lstat(x)
        return (st.st_mode & 0o7777, st.st_uid, st.st_gid,
                os.getxattr(x, "security.selinux", follow_symlinks=False).rstrip(b"\0").decode()), True

    for d in parents:
        dmeta[d], there = dir_meta(d)
        if there:
            existing.add(d)
        else:
            # A directory this run creates is labelled like the files placed in it (as the platform's
            # file_contexts does for /vendor/etc/audio/*, /vendor/usr/keylayout/*), not like its parent.
            new_label = next((lbl for dest, _, lbl in specs if dest.startswith(d + "/")), None)
            if new_label:
                dmeta[d] = dmeta[d][:3] + (new_label,)
    sb_raw = vendor.read_bytes()[:4096]
    meta_blk, root_nid = struct.unpack_from("<I", sb_raw, 1024 + 0x28)[0], struct.unpack_from("<H", sb_raw, 1024 + 0x0E)[0]
    root_off = meta_blk * bsz + root_nid * 32
    with vendor.open("rb") as v:
        v.seek(root_off)
        oldroot = v.read(64)

    tar = work / "overlay.tar"
    with tarfile.open(tar, "w", format=tarfile.PAX_FORMAT) as t:
        ti = tarfile.TarInfo(".")
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 1230768000
        t.addfile(ti)
        for d in parents:
            mode, uid, gid, label = dmeta[d]
            ti = tarfile.TarInfo(d)
            ti.type, ti.mode, ti.uid, ti.gid, ti.mtime = tarfile.DIRTYPE, mode, uid, gid, 1230768000
            ti.pax_headers = {"SCHILY.xattr.security.selinux": label}
            t.addfile(ti)
        for dest, local, label in specs:
            data = local.read_bytes()
            ti = tarfile.TarInfo(dest)
            ti.size, ti.mode, ti.uid, ti.gid, ti.mtime = len(data), 0o644, 0, 0, 1230768000
            ti.pax_headers = {"SCHILY.xattr.security.selinux": label}
            t.addfile(ti, io.BytesIO(data))
    subprocess.run(["mkfs.erofs", "--incremental=data", "--tar=f", "-x0", "-b4096", "-T1230768000", "-zlz4hc",
                    str(vendor), str(tar)], check=True, stdout=subprocess.DEVNULL)
    # The rebuilt root inode loses its shared-xattr (SELinux label) reference: restore it from the
    # original root and re-sign the superblock (CRC32C), as gbrunch/gbos-vm do.
    with vendor.open("r+b") as v:
        v.seek(root_off)
        newroot = v.read(64)
        assert oldroot[2:4] == newroot[2:4] and not (oldroot[0] & 1 or newroot[0] & 1), "root inode layout changed"
        v.seek(root_off + 32)
        v.write(oldroot[32:48])
        v.seek(1024)
        b = bytearray(v.read(bsz - 1024))
        b[4:8] = bytes(4)
        crc = 0xFFFFFFFF
        for value in b:
            crc ^= value
            for _ in range(8):
                crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
        v.seek(1028)
        v.write(struct.pack("<I", crc))
    subprocess.run(["fsck.erofs", str(vendor)], check=True, stdout=subprocess.DEVNULL)
    for d in parents:
        x = work / "meta" / ("after_" + d.replace("/", "_"))
        if d not in existing:
            # a directory this run created: it must exist and carry the label it inherited
            subprocess.run(["rm", "-rf", str(x)], check=True)
            subprocess.run(["fsck.erofs", "--xattrs", f"--extract={x}", f"--path=/{d}", str(vendor)],
                           check=True, stdout=subprocess.DEVNULL)
            got = os.getxattr(x, "security.selinux", follow_symlinks=False).rstrip(b"\0").decode()
            assert got == dmeta[d][3], f"label of new /{d} is {got}"
            continue
        subprocess.run(["rm", "-rf", str(x)], check=True)
        subprocess.run(["fsck.erofs", "--xattrs", f"--extract={x}", f"--path=/{d}", str(vendor)],
                       check=True, stdout=subprocess.DEVNULL)
        got = os.getxattr(x, "security.selinux", follow_symlinks=False).rstrip(b"\0").decode()
        assert got == dmeta[d][3], f"label of /{d} changed: {got}"
    new = vendor.read_bytes()
    slot = (last - first + 1) * SECTOR
    print(f"vendor: {blocks * bsz} -> {len(new)} bytes (partition slot {slot})")

    with img.open("r+b") as f:
        mbr, hdr, table, tlba, count, esz = read_gpt(f)
        if len(new) <= slot:
            f.seek(first * SECTOR)
            f.write(new + bytes(slot - len(new)))
            print("written in place")
        else:
            end = max(b for _, _, _, b in entries(table, count, esz)) + 1
            start = (end * SECTOR + MIB - 1) // MIB * MIB // SECTOR
            size = (len(new) + MIB - 1) // MIB * MIB
            old = table[idx * esz:(idx + 1) * esz]
            # old entry: renamed, fresh unique GUID; new entry inherits the original GUID
            o = bytearray(old)
            o[16:32] = uuid.uuid4().bytes_le
            o[56:128] = "GBVENDOR_OLD".encode("utf-16le").ljust(72, b"\0")
            table[idx * esz:(idx + 1) * esz] = o
            slot_i = next(i for i in range(count) if not any(table[i * esz:i * esz + 16]))
            e = bytearray(esz)
            e[:16] = LINUX_DATA.bytes_le
            e[16:32] = old[16:32]
            struct.pack_into("<QQQ", e, 32, start, start + size // SECTOR - 1, 0)
            e[56:128] = "GBVENDOR".encode("utf-16le").ljust(72, b"\0")
            table[slot_i * esz:(slot_i + 1) * esz] = e
            f.seek(start * SECTOR)
            f.write(new + bytes(size - len(new)))
            ts = (len(table) + SECTOR - 1) // SECTOR
            write_gpt(f, mbr, hdr, table, tlba, start + size // SECTOR + ts)
            print(f"relocated: new GBVENDOR at {start * SECTOR} ({size} bytes), old entry renamed GBVENDOR_OLD")
    print("vendor sha256", hashlib.sha256(new).hexdigest())


if __name__ == "__main__":
    main()
