#!/bin/bash
# End-to-end test of the kernel #UD emulator: boot the patched kernel under QEMU TCG with a
# Kaby Lake-class CPU model (no GFNI/VNNI/VAES/VPCLMULQDQ/SHA) and run difftest as /init.
# Inside the guest every tested instruction traps and is emulated by the kernel; difftest
# compares the result with the same core running in userspace (which was itself verified
# against real hardware by running difftest on the host).
#   run_guest.sh <bzImage> <kernel out dir (for usr/gen_init_cpio)> <log> [iters] [extra cmdline]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BZ="${1:?bzImage}"; OUT="${2:?kernel out dir}"; LOG="${3:?log file}"; ITERS="${4:-100000}"; EXTRA="${5:-}"
CPU="${CPU:-Skylake-Client-noTSX-IBRS}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

gcc -O2 -static -o "$W/init" "$HERE/difftest.c"
cat > "$W/spec" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
dir /proc 0755 0 0
file /init $W/init 0755 0 0
EOF
"$OUT/usr/gen_init_cpio" "$W/spec" | gzip -1 > "$W/initrd.gz"

timeout "${TIMEOUT:-900}" qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu "$CPU" -smp 4 -m 2048 \
	-display none -vga none -serial stdio -monitor none -no-reboot -nic none \
	-kernel "$BZ" -initrd "$W/initrd.gz" \
	-append "console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200 8250.nr_uarts=1 panic=-1 loglevel=6 rdinit=/init $EXTRA -- $ITERS" \
	> "$LOG" 2>&1 || true
grep -a -E "isa_emu:|glue:|FAIL|ISA_EMU_TEST|native oracle|guest mode|Kernel panic|invalid opcode" "$LOG" | cut -c1-200 | head -60
