#!/usr/bin/env python3
"""Boot Google's unmodified ruby userland on a Kaby Lake-class CPU model with a given kernel.

Purpose: ISA validation of the patched kernel (isa_emu). QEMU TCG with -cpu Skylake-Client
raises #UD for GFNI/AVX-VNNI/VAES-256/VPCLMULQDQ-256/SHA exactly like the Pixelbook's CPU.
The recovery image is opened as a disposable snapshot; nothing is written to it.

  python qemu/qemu_ruby_boot.py --kernel build/pixelbook/bzImage --seconds 300 --name ruby-isaemu
  python qemu/qemu_ruby_boot.py --seconds 60 --name ruby-stock        (stock kernel: control)
Cmdline and ramdisk composition follow gbrunch tools/run_android_probe.py.
"""
import argparse, gzip, hashlib, json, os, pathlib, re, subprocess, time

R = pathlib.Path(__file__).resolve().parents[1]
I = R / "recovery_ruby/inspect_recovery"
Q = pathlib.Path(os.environ.get("QEMU_DIR", r"C:\Program Files\qemu"))


def newc(ino, name, data, mode=0o100644):
    nm = name.encode() + bytes(1)
    h = b"070701" + b"".join(f"{v:08x}".encode() for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0)) + nm
    h += bytes(-len(h) % 4) + data
    return h + bytes(-len(h) % 4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", default=str(I / "boot_a/kernel"))
    ap.add_argument("--seconds", type=int, default=300)
    ap.add_argument("--name", default="ruby-isaemu")
    ap.add_argument("--cpu", default="Skylake-Client-noTSX-IBRS")
    ap.add_argument("--smp", type=int, default=4)
    ap.add_argument("--mem", type=int, default=6144)
    ap.add_argument("--no-modules", action="store_true", help="empty first-stage modules.load (as gbrunch does)")
    ap.add_argument("--extra", action="append", default=[])
    a = ap.parse_args()

    build = R / "build/pixelbook"; build.mkdir(parents=True, exist_ok=True)
    cpio = (I / "vendor_boot_a/fragment-0-platform.cpio").read_bytes()
    cpio += (I / "vendor_boot_a/fragment-2-dlkm.cpio").read_bytes()
    cpio += (I / "init_boot_a/ramdisk.cpio").read_bytes()
    if a.no_modules:
        cpio += newc(900000, "lib/modules/modules.load", b"# no board-specific early modules\n")
        cpio += newc(0, "TRAILER!!!", b"", 0)
    initrd = build / f"{a.name}-initrd.gz"
    initrd.write_bytes(gzip.compress(cpio, 1, mtime=0))

    vb = (I / "vbmeta_a.img").read_bytes()
    size = 256 + int.from_bytes(vb[12:20], "big") + int.from_bytes(vb[20:28], "big")
    digest = hashlib.sha256(vb[:size]).hexdigest()
    boot_uuid = next(p["guid"] for p in json.loads((I / "gpt.json").read_text()) if p["name"] == "boot_a")
    cmdline = " ".join([
        "console=ttyS0,115200", "earlycon=uart8250,io,0x3f8,115200", "8250.nr_uarts=4",
        "panic=0", "root=/dev/ram0", "loglevel=7", "printk.devkmsg=on",
        "androidboot.init_log_level=debug",
        "androidboot.hardware=android-desktop", "androidboot.hardware.platform=android-desktop",
        "androidboot.slot_suffix=_a", "androidboot.force_normal_boot=1",
        "androidboot.boot_devices=pci0000:00/0000:00:03.0",
        f"androidboot.boot_part_uuid={boot_uuid}",
        f"androidboot.vbmeta.size={size}", "androidboot.vbmeta.hash_alg=sha256",
        f"androidboot.vbmeta.digest={digest}", "androidboot.vbmeta.device_state=unlocked",
        "androidboot.verifiedbootstate=orange", "androidboot.veritymode=enforcing",
        "androidboot.hypervisor.protected_vm.supported=0",
        "androidboot.vendor.apex.com.android.hardware.keymint.strongbox.desktop=none",
        *a.extra,
    ])
    disk = R / "recovery_ruby/android-desktop_signed_recovery_image.bin"
    args = [str(Q / "qemu-system-x86_64.exe"), "-L", str(Q / "share"),
            "-machine", "q35", "-accel", "tcg,thread=multi", "-cpu", a.cpu, "-m", str(a.mem), "-smp", str(a.smp),
            "-vga", "none", "-display", "none", "-serial", "stdio", "-monitor", "none", "-nic", "none", "-no-reboot",
            "-kernel", a.kernel, "-initrd", str(initrd), "-append", cmdline,
            "-drive", f"if=none,id=os,format=raw,snapshot=on,file={disk}",
            "-device", "nvme,drive=os,serial=GBRUNCHANDROID,addr=03.0"]
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
    totals = re.findall(r"isa_emu: total=(\d+)", out)
    res = {
        "kernel": a.kernel, "cpu": a.cpu, "seconds": round(time.monotonic() - t0), "timeout": timed_out, "exit_code": code,
        "log": str(log_path), "log_bytes": len(out),
        "invalid_opcode_traps": out.count("trap invalid opcode"),
        "sigill_services": len(re.findall(r"received SIGILL|signal 4 \(SIGILL\)", out)),
        "kernel_panics": out.count("Kernel panic"),
        "isa_emu_total": int(totals[-1]) if totals else None,
        "milestones": {k: (k in out) for k in (
            "init first stage started", "Switching root to '/system'", "init second stage started",
            "apexd: Started", "starting service 'zygote'", "starting service 'surfaceflinger'")},
    }
    (R / "evidence" / (a.name + ".json")).write_text(json.dumps(res, indent=2) + "\n")
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
