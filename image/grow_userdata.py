#!/usr/bin/env python3
"""Give the Pixelbook image a roomy /data partition.

Google's recovery image ships a 4.1 GiB `userdata`. On first boot the platform copies about 3.7 GB of
AICore model files from system_b into /data/preloads (system/bin/preloads_copy.sh, started by
sys.cppreopt=requested), which fills the partition; every later write then fails (zero-length
anr/tombstone/dropbox files) and system_server restarts forever. A real Googlebook grows userdata to
the whole disk during setup; this image does not have that step.

  grow_userdata.py <image.raw> [--gib 8]

Renames the existing `userdata` GPT entry to `userdata_old` (new unique GUID) and appends a new, empty
`userdata` partition of the requested size after the last partition, then rewrites both GPT copies
and extends the file. The partition is formatted here with the same ext4 features Android's own first-boot mke2fs
produced on the device (an unformatted partition was not auto-formatted when tested in QEMU). Regular image files only; nothing else in the image changes.
"""
import argparse, pathlib, shutil, subprocess, sys, uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import vendor_overlay as v

SECTOR, MIB = 512, 1 << 20


def format_ext4(image, offset, size):
    """Format like Android's own first-boot mke2fs did on the device (features copied from the
    filesystem it created: 512-byte inodes, casefold, quota+project, verity, no flex_bg/resize_inode),
    because fs_mgr only auto-formats a blank userdata in some situations and we want a mountable one."""
    if not shutil.which("mke2fs"):
        sys.exit("mke2fs not found (apt install e2fsprogs)")
    feats = ("has_journal,ext_attr,dir_index,filetype,extent,casefold,sparse_super,large_file,huge_file,"
             "uninit_bg,dir_nlink,extra_isize,quota,project,verity,"
             "^resize_inode,^flex_bg,^metadata_csum,^64bit,^orphan_file")
    subprocess.run(["mke2fs", "-F", "-q", "-t", "ext4", "-b", "4096", "-I", "512", "-i", "16384", "-m", "2",
                    "-J", "size=64", "-O", feats,
                    "-E", f"encoding=utf8,offset={offset},quotatype=usrquota:grpquota:prjquota",
                    str(image), str(size // 4096)], check=True)
    dev = f"{image}?offset={offset}"
    subprocess.run(["tune2fs", "-g", "1065", dev], check=True, stdout=subprocess.DEVNULL)  # Android's reserved gid
    info = subprocess.run(["debugfs", "-R", "stats", dev], capture_output=True, text=True).stdout
    feat = next((l for l in info.splitlines() if "features" in l), "")
    print("formatted:", feat.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", type=pathlib.Path)
    ap.add_argument("--gib", type=float, default=8.0, help="size of the new userdata partition")
    ap.add_argument("--no-format", action="store_true", help="leave the new partition blank")
    a = ap.parse_args()
    if not a.image.is_file() or str(a.image).startswith("/dev/"):
        sys.exit("refusing: not a regular image file")
    with a.image.open("r+b") as f:
        mbr, hdr, table, tlba, count, esz = v.read_gpt(f)
        ents = {n: (i, s, e) for i, n, s, e in v.entries(table, count, esz)}
        if "userdata_old" in ents:
            sys.exit("already grown: userdata_old exists")
        idx, first, last = ents["userdata"]
        end = max(e for _, _, e in ents.values()) + 1
        start = (end * SECTOR + MIB - 1) // MIB * MIB // SECTOR
        size = int(a.gib * (1 << 30)) // MIB * MIB
        old = bytearray(table[idx * esz:(idx + 1) * esz])
        new = bytearray(old)
        old[16:32] = uuid.uuid4().bytes_le
        old[56:128] = "userdata_old".encode("utf-16le").ljust(72, b"\0")
        table[idx * esz:(idx + 1) * esz] = old
        slot = next(i for i in range(count) if not any(table[i * esz:i * esz + 16]))
        import struct
        new[16:32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQ", new, 32, start, start + size // SECTOR - 1)
        new[56:128] = "userdata".encode("utf-16le").ljust(72, b"\0")
        table[slot * esz:(slot + 1) * esz] = new
        ts = (len(table) + SECTOR - 1) // SECTOR
        last_lba = start + size // SECTOR + ts
        f.seek((start + size // SECTOR) * SECTOR)
        f.write(bytes(SECTOR))                     # make sure the file really extends over the new partition
        v.write_gpt(f, mbr, hdr, table, tlba, last_lba)
    if not a.no_format:
        format_ext4(a.image, start * SECTOR, size)
    print(f"userdata: new {size / (1 << 30):.1f} GiB partition at byte {start * SECTOR}, "
          f"old entry kept as userdata_old; image is now {(last_lba + 1) * SECTOR / 1e9:.2f} GB")


if __name__ == "__main__":
    main()
