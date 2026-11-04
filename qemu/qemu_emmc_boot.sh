#!/bin/bash
# Boot an internal install (a disk image written by install/install_to_disk.sh) the way the Pixelbook would: from an
# eMMC behind an SDHCI PCI controller, under UEFI, on a Kaby Lake-class CPU model (QEMU TCG). Exercises the boot
# menu's boot-disk lookup, the first-stage eMMC driver (sdhci-pci from the initrd) and /data on disk.
#   qemu/qemu_emmc_boot.sh <disk image> <log> [seconds]
# The disk image is modified (Android writes to /data), so a second run shows whether data persisted.
set -euo pipefail
DISK="${1:?disk image}"; LOG="${2:?log}"; SECS="${3:-420}"
CPU="${CPU:-Skylake-Client-noTSX-IBRS}"
VARS="$(dirname "$DISK")/OVMF_VARS.emmc.fd"
[ -f "$VARS" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
timeout "$SECS" qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu "$CPU" -smp "${SMP:-4}" -m "${MEM:-4096}" \
	-display none -vga none -serial stdio -monitor none -no-reboot -nic none \
	-drive "if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd" -drive "if=pflash,format=raw,unit=1,file=$VARS" \
	-device sdhci-pci,id=sdhci -drive "if=none,id=mmc,format=raw,file=$DISK" -device emmc,drive=mmc \
	> "$LOG" 2>&1 || true
echo "log: $LOG ($(wc -c < "$LOG") bytes)"
for m in "GRUB" "Linux version" "Loaded kernel module /lib/modules/sdhci-pci.ko" "mmcblk0: mmc" "init second stage started" \
	"starting service 'zygote'" "starting service 'surfaceflinger'"; do
	printf '  %-50s %s\n' "$m" "$(grep -a -m1 -c "$m" "$LOG" || true)"
done
grep -ao 'androidboot.boot_part_uuid=[^ ]*\|androidboot.gbdata=[^ ]*' "$LOG" | sort -u | sed 's/^/  /'
grep -a -E '__mount\(source=[^,]*userdata|mount.*/data|Formatting|tmpfs /data' "$LOG" | head -4 | cut -c1-200 | sed 's/^/  /'
echo "  kernel panics: $(grep -a -c 'Kernel panic' "$LOG" || true)"
