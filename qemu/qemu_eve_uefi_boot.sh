#!/bin/bash
# Boot the Pixelbook image the way the device would: UEFI firmware -> GRUB on the EFI partition ->
# kernel + initrd, from a USB mass-storage device, on a Kaby Lake-class CPU model (QEMU TCG).
#   qemu/qemu_eve_uefi_boot.sh <gbrunch work dir> <log> [seconds]
# The image is opened as a throwaway snapshot. QEMU has no Intel GPU, so i915 loads but binds to
# nothing and Android's display services cannot start; everything before that is exercised.
set -euo pipefail
W="${1:?gbrunch work dir}"; LOG="${2:?log}"; SECS="${3:-420}"
CPU="${CPU:-Skylake-Client-noTSX-IBRS}"
CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
VARS="$W/eve/OVMF_VARS.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
export TMPDIR="${TMPDIR:-$W/tmp}"; mkdir -p "$TMPDIR"

timeout "$SECS" qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu "$CPU" -smp "${SMP:-4}" -m "${MEM:-4096}" \
	-display none -vga none -serial stdio -monitor none -no-reboot -nic none \
	-drive "if=pflash,format=raw,unit=0,readonly=on,file=$CODE" -drive "if=pflash,format=raw,unit=1,file=$VARS" \
	-device qemu-xhci,id=xhci \
	-drive "if=none,id=os,format=raw,snapshot=on,file=$W/eve.raw" -device usb-storage,bus=xhci.0,drive=os \
	> "$LOG" 2>&1 || true

echo "log: $LOG ($(wc -c < "$LOG") bytes)"
for m in "Linux version" "isa_emu: user-mode emulation enabled" "init first stage started" "Loaded kernel module /lib/modules/i915.ko" \
	 "init second stage started" "apexd: Started" "starting service 'keystore2'" "starting service 'zygote'" "starting service 'surfaceflinger'"; do
	printf '  %-44s %s\n' "$m" "$(grep -a -m1 -c "$m" "$LOG" || true)"
done
echo "  module load problems:                        $(grep -a -c -E 'disagrees about version|Unknown symbol|Failed to insmod ./lib/modules' "$LOG" || true)"
echo "  invalid opcode traps:                        $(grep -a -c 'trap invalid opcode' "$LOG" || true)"
echo "  SIGILL deliveries:                           $(grep -a -c -E 'received SIGILL|signal 4 \(SIGILL\)' "$LOG" || true)"
echo "  kernel panics:                               $(grep -a -c 'Kernel panic' "$LOG" || true)"
grep -a "isa_emu: total" "$LOG" | tail -n 1 | sed -E 's/^.*isa_emu: /  isa_emu: /' | cut -c1-240
