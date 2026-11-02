#!/usr/bin/env python3
"""Control for qemu_donor_boot.py: boot Google's unmodified ruby kernel+ramdisk on the same Kaby Lake-class
CPU model. Expect first-stage init to die on GFNI (#UD). Evidence only; no disk is written (snapshot)."""
import gzip, os, pathlib, subprocess, sys
R = pathlib.Path(__file__).resolve().parents[1]
I = R / "recovery_ruby/inspect_recovery"; Q = pathlib.Path(os.environ.get("QEMU_DIR", r"C:\Program Files\qemu"))
cpu = sys.argv[1] if len(sys.argv) > 1 else "Skylake-Client-noTSX-IBRS"
cpio = (I/"vendor_boot_a/fragment-0-platform.cpio").read_bytes() + (I/"vendor_boot_a/fragment-2-dlkm.cpio").read_bytes() + (I/"init_boot_a/ramdisk.cpio").read_bytes()
out = R/"build/ruby-control"; out.mkdir(parents=True, exist_ok=True)
(out/"initrd.gz").write_bytes(gzip.compress(cpio, mtime=0))
cmd = ["console=ttyS0,115200", "earlycon=uart8250,io,0x3f8,115200", "8250.nr_uarts=4", "panic=0", "loglevel=7",
       "printk.devkmsg=on", "androidboot.hardware=android-desktop", "androidboot.slot_suffix=_a",
       "androidboot.force_normal_boot=1", "androidboot.init_log_level=debug", "rdinit=/init"]
args = [str(Q/"qemu-system-x86_64.exe"), "-L", str(Q/"share"), "-machine", "q35", "-accel", "tcg", "-cpu", cpu,
        "-m", "2048", "-smp", "2", "-display", "none", "-vga", "none", "-serial", "stdio", "-monitor", "none",
        "-no-reboot", "-nic", "none", "-kernel", str(I/"boot_a/kernel"), "-initrd", str(out/"initrd.gz"), "-append", " ".join(cmd)]
log = R/"evidence"/f"ruby-control-{cpu}.log"
with log.open("wb") as f:
    p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT)
    try: p.wait(timeout=90)
    except subprocess.TimeoutExpired: p.kill(); p.wait()
t = log.read_text(errors="replace")
for k in ("invalid opcode", "SIGILL", "Illegal instruction", "Kernel panic", "init first stage"):
    print(k, t.count(k))
