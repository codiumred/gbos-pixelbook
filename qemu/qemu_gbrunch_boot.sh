#!/bin/bash
# Boot the gbrunch-assembled image (see gbrunch_assemble.sh) with a chosen kernel on a Kaby
# Lake-class CPU model under QEMU TCG. The disk is opened as a throwaway snapshot.
#   qemu/qemu_gbrunch_boot.sh <bzImage> <gbrunch work dir> <log> [seconds] [extra cmdline]
# There is no GPU the Android graphics stack can use in this VM, so the display services are
# expected to restart; the purpose is to exercise as much userland as possible and to profile
# which instructions the kernel has to emulate.
set -euo pipefail
BZ="${1:?bzImage}"; W="${2:?gbrunch work dir}"; LOG="${3:?log}"; SECS="${4:-600}"; EXTRA="${5:-isa_emu=profile}"
CPU="${CPU:-Skylake-Client-noTSX-IBRS}"
CMD="$(cat "$W/gbrunch-cmdline.txt") $EXTRA"
export TMPDIR="${TMPDIR:-$W/tmp}"; mkdir -p "$TMPDIR"

timeout "$SECS" qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu "$CPU" -smp "${SMP:-4}" -m "${MEM:-4096}" \
	-display none -vga none -serial stdio -monitor none -no-reboot -nic none \
	-kernel "$BZ" -initrd "$W/gbrunch-initrd.gz" -append "$CMD" \
	-drive "if=none,id=os,format=raw,snapshot=on,file=$W/native.raw" \
	-device nvme,drive=os,serial=GBRUNCHANDROID > "$LOG" 2>&1 || true

echo "log: $LOG ($(wc -c < "$LOG") bytes)"
for m in "init first stage started" "init second stage started" "apexd: Started" "starting service 'keystore2'" \
	 "starting service 'zygote'" "starting service 'surfaceflinger'" "Starting phase" "Boot is finished" "sys.boot_completed"; do
	printf '  %-36s %s\n' "$m" "$(grep -a -m1 -c "$m" "$LOG" || true)"
done
echo "  invalid opcode traps:               $(grep -a -c 'trap invalid opcode' "$LOG" || true)"
echo "  SIGILL deliveries:                  $(grep -a -c -E 'received SIGILL|signal 4 \(SIGILL\)' "$LOG" || true)"
echo "  kernel panics:                      $(grep -a -c 'Kernel panic' "$LOG" || true)"
grep -a "isa_emu: total" "$LOG" | tail -n 1 | sed -E 's/^.*isa_emu: /  isa_emu: /' | cut -c1-260
