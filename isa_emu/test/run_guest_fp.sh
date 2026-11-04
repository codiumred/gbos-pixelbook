#!/bin/bash
# Run fptest as /init under QEMU TCG with a Kaby Lake-class CPU model.
#   run_guest_fp.sh <bzImage> <kernel out dir> <fp dir with sha256_fn.bin, sha256_ktab.bin, sha1_fn.bin, sha1_bswap.bin> <log> [extra cmdline]
# Run it twice to compare: default (fast path on) and with "isa_emu_fast=0".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BZ="${1:?bzImage}"; OUT="${2:?kernel out dir}"; FP="${3:?fp dir}"; LOG="${4:?log file}"; EXTRA="${5:-}"
CPU="${CPU:-Skylake-Client-noTSX-IBRS}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

gcc -O2 -static -o "$W/init" "$HERE/fptest.c"
cp "$FP/sha256_fn.bin" "$FP/sha256_ktab.bin" "$FP/sha1_fn.bin" "$FP/sha1_bswap.bin" "$W/"
cat > "$W/spec" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
dir /proc 0755 0 0
dir /fp 0755 0 0
file /fp/sha256_fn.bin $W/sha256_fn.bin 0644 0 0
file /fp/sha256_ktab.bin $W/sha256_ktab.bin 0644 0 0
file /fp/sha1_fn.bin $W/sha1_fn.bin 0644 0 0
file /fp/sha1_bswap.bin $W/sha1_bswap.bin 0644 0 0
file /init $W/init 0755 0 0
EOF
"$OUT/usr/gen_init_cpio" "$W/spec" | gzip -1 > "$W/initrd.gz"

timeout "${TIMEOUT:-900}" qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu "$CPU" -smp 2 -m 2048 \
	-display none -vga none -serial stdio -monitor none -no-reboot -nic none \
	-kernel "$BZ" -initrd "$W/initrd.gz" \
	-append "console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200 8250.nr_uarts=1 panic=-1 loglevel=6 rdinit=/init $EXTRA" \
	> "$LOG" 2>&1 || true
grep -a -E "isa_emu:|function:|known answer|random states|SIGSEGV|throughput|/proc/isa_emu|FAIL|ISA_FP_TEST|Kernel panic|sha1" "$LOG" | cut -c1-200 | head -60
