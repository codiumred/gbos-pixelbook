#!/usr/bin/env python3
"""Path A smoke test: boot the unmodified AOSP Cuttlefish donor userland under QEMU TCG with a
Kaby Lake-class CPU model (Skylake-Client). Purpose is ISA validation only: does an image with no
GFNI/AVX-VNNI run on a CPU model that also lacks them? No Google recovery bits are involved.

  python tools/qemu_donor_boot.py --seconds 900 --name donor-kbl-boot
Inputs:  donor_cuttlefish/x/{super.raw,vbmeta*.img,boot.img,...} and donor_cuttlefish/x/inspect/*
Outputs: build/donor-boot/disk.img (GPT, sparse), evidence/<name>.log + .json
"""
import argparse, binascii, hashlib, json, pathlib, struct, subprocess, sys, time, uuid, zipfile

R = pathlib.Path(__file__).resolve().parents[1]
X = R / "donor_cuttlefish/x"
INS = X / "inspect"
QEMU = pathlib.Path(r"C:\Users\you\qemu")
MiB = 1 << 20
ZIP = R / "donor_cuttlefish/aosp_cf_img-16373615.zip"


def gpt_disk(path, parts):
    """parts: list of (name, size_bytes, src_path|None). Writes a GPT disk with 1 MiB alignment."""
    ss = 512
    entries = []
    off = 1 * MiB
    for name, size, src in parts:
        size = (size + MiB - 1) // MiB * MiB
        entries.append((name, off, size, src))
        off += size
    total = off + 1 * MiB
    with open(path, "wb") as f:
        f.truncate(total)
        for name, o, size, src in entries:
            if src is None:
                continue
            f.seek(o)
            with open(src, "rb") as s:
                while True:
                    b = s.read(8 * MiB)
                    if not b:
                        break
                    if b.count(0) != len(b):
                        f.write(b)
                    else:
                        f.seek(len(b), 1)
        # GPT
        n = 128
        arr = bytearray()
        for name, o, size, _ in entries:
            e = (uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4").bytes_le + uuid.uuid4().bytes_le +
                 struct.pack("<QQQ", o // ss, (o + size) // ss - 1, 0) + name.encode("utf-16le").ljust(72, b"\0"))
            arr += e
        arr = bytes(arr).ljust(n * 128, b"\0")
        last = total // ss - 1
        crc_arr = binascii.crc32(arr) & 0xFFFFFFFF
        def hdr(cur, backup, first, lastu, arr_lba):
            h = bytearray(92)
            h[0:8] = b"EFI PART"
            struct.pack_into("<IIIIQQQQ", h, 8, 0x00010000, 92, 0, 0, cur, backup, first, lastu)
            h[56:72] = uuid.uuid4().bytes_le if hdr.guid is None else hdr.guid
            hdr.guid = bytes(h[56:72])
            struct.pack_into("<QIII", h, 72, arr_lba, n, 128, crc_arr)
            struct.pack_into("<I", h, 16, binascii.crc32(bytes(h)) & 0xFFFFFFFF)
            return bytes(h).ljust(ss, b"\0")
        hdr.guid = None
        mbr = bytearray(512)
        mbr[446 + 4] = 0xEE
        struct.pack_into("<II", mbr, 446 + 8, 1, min(total // ss - 1, 0xFFFFFFFF))
        mbr[510:512] = b"\x55\xaa"
        f.seek(0); f.write(mbr)
        f.seek(ss); f.write(hdr(1, last, 34, last - 33, 2))
        f.seek(2 * ss); f.write(arr)
        f.seek((last - 32) * ss); f.write(arr)
        f.seek(last * ss); f.write(hdr(last, 1, 34, last - 33, last - 32))
    return entries


def cpio_trailer_concat(*cpios):
    return b"".join(cpios)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=900)
    ap.add_argument("--name", default="donor-kbl-boot")
    ap.add_argument("--cpu", default="Skylake-Client-noTSX-IBRS")
    ap.add_argument("--mem", type=int, default=4096)
    ap.add_argument("--smp", type=int, default=4)
    ap.add_argument("--rebuild-disk", action="store_true")
    ap.add_argument("--kernel", help="override kernel (e.g. Google ruby 6.18 GKI); switches the disk to NVMe, drops binder.impl=rust")
    ap.add_argument("--extra", action="append", default=[], help="extra kernel cmdline words")
    a = ap.parse_args()

    build = R / "build/donor-boot"; build.mkdir(parents=True, exist_ok=True)
    disk = build / "disk.img"
    z = zipfile.ZipFile(ZIP)
    for n in ("vbmeta.img", "vbmeta_system.img", "vbmeta_system_dlkm.img", "vbmeta_vendor_dlkm.img",
              "boot.img", "init_boot.img", "vendor_boot.img"):
        if not (X / n).exists():
            z.extract(n, X)
    if a.rebuild_disk or not disk.exists():
        zero = None
        parts = [
            ("boot_a", 64 * MiB, X / "boot.img"),
            ("init_boot_a", 8 * MiB, X / "init_boot.img"),
            ("vendor_boot_a", 64 * MiB, X / "vendor_boot.img"),
            ("vbmeta_a", 1 * MiB, X / "vbmeta.img"),
            ("vbmeta_system_a", 1 * MiB, X / "vbmeta_system.img"),
            ("vbmeta_system_dlkm_a", 1 * MiB, X / "vbmeta_system_dlkm.img"),
            ("vbmeta_vendor_dlkm_a", 1 * MiB, X / "vbmeta_vendor_dlkm.img"),
            ("misc", 1 * MiB, zero),
            ("metadata", 64 * MiB, zero),
            ("super", (X / "super.raw").stat().st_size, X / "super.raw"),
            ("userdata", 6 * 1024 * MiB, zero),
        ]
        t = time.time(); gpt_disk(disk, parts); print(f"disk built in {time.time()-t:.0f}s")

    vb = (X / "vbmeta.img").read_bytes()
    size = 256 + int.from_bytes(vb[12:20], "big") + int.from_bytes(vb[20:28], "big")
    digest = hashlib.sha256(vb[:size]).hexdigest()
    cpio = (INS / "vendor_boot/fragment-0-platform.cpio").read_bytes() + (INS / "init_boot/ramdisk.cpio").read_bytes()
    import gzip
    if a.kernel:  # donor modules are built for 6.12; an empty list avoids fatal first-stage insmod failures
        def newc(ino, name, data):
            nm = name.encode() + b"\x00"
            h = b"070701" + b"".join(f"{v:08x}".encode() for v in (ino, 0o100644, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0)) + nm
            h += bytes(-len(h) % 4) + data
            return h + bytes(-len(h) % 4)
        data = b"# modules intentionally not loaded (kernel mismatch test)\n"
        trailer = newc(0, "TRAILER!!!", b"")
        cpio += newc(900000, "lib/modules/modules.load", data) + trailer
    initrd = build / "initrd.gz"; initrd.write_bytes(gzip.compress(cpio, mtime=0))
    cmdline = " ".join([
        "console=ttyS0,115200", "earlycon=uart8250,io,0x3f8,115200", "8250.nr_uarts=1",
        "printk.devkmsg=on", "audit=1", "panic=-1", *([] if a.kernel else ["binder.impl=rust"]), "cma=0",
        "firmware_class.path=/vendor/etc/", "loop.max_part=7", "init=/init", "loglevel=7",
        "androidboot.hardware=cutf_cvm", "androidboot.console=ttyS0",
        "androidboot.slot_suffix=_a", "androidboot.force_normal_boot=1",
        "androidboot.boot_devices=pci0000:00/0000:00:04.0",
        f"androidboot.vbmeta.size={size}", "androidboot.vbmeta.hash_alg=sha256",
        f"androidboot.vbmeta.digest={digest}", "androidboot.vbmeta.device_state=unlocked",
        "androidboot.verifiedbootstate=orange", "androidboot.veritymode=enforcing",
        "androidboot.init_log_level=debug", *a.extra, "androidboot.fstab_suffix=cf.ext4.hctr2",
        "androidboot.vendor.apex.com.android.hardware.gatekeeper=com.android.hardware.gatekeeper.nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.keymint=com.android.hardware.keymint.rust_nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.graphics.composer=com.android.hardware.graphics.composer.drm_hwcomposer.apex",
    ])
    args = [str(QEMU / "qemu-system-x86_64.exe"), "-L", str(QEMU / "share"),
            "-machine", "q35", "-accel", "tcg,thread=multi", "-cpu", a.cpu, "-m", str(a.mem), "-smp", str(a.smp),
            "-display", "none", "-vga", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot", "-nic", "none",
            "-kernel", a.kernel or str(INS / "boot/kernel"), "-initrd", str(initrd), "-append", cmdline,
            "-drive", f"if=none,id=d0,format=raw,file={disk},snapshot=on,cache=unsafe",
            *(["-device", "nvme,drive=d0,serial=GBDONOR,addr=04.0"] if a.kernel else ["-device", "virtio-blk-pci,drive=d0,addr=04.0"])]
    log_path = R / "evidence" / (a.name + ".log")
    t0 = time.monotonic()
    with log_path.open("wb") as log:
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = p.wait(timeout=a.seconds); timed_out = False
        except subprocess.TimeoutExpired:
            p.terminate()
            try: code = p.wait(timeout=10)
            except subprocess.TimeoutExpired: p.kill(); code = p.wait()
            timed_out = True
    out = log_path.read_text(errors="replace")
    res = {"cpu": a.cpu, "seconds": round(time.monotonic() - t0), "timeout": timed_out, "exit_code": code,
           "log_bytes": len(out), "invalid_opcode_traps": out.count("trap invalid opcode"),
           "sigill": out.count("SIGILL"), "log": str(log_path), "qemu_args": args[1:]}
    (R / "evidence" / (a.name + ".json")).write_text(json.dumps(res, indent=2) + "\n")
    print(json.dumps({k: v for k, v in res.items() if k != "qemu_args"}, indent=2))


if __name__ == "__main__":
    main()
