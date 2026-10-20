#!/bin/bash
# End-to-end test of the built-in installer: a copy of the image as the USB stick and an empty eMMC, booted the way
# GRUB's "Install to the internal eMMC" entry boots after the user typed ERASE (our kernel + installer.gz, from the
# image's own EFI partition). The installer powers the VM off on success, which ends QEMU.
#   qemu/qemu_installer_test.sh <image> <work dir> [update]
# Leaves <work dir>/stick.raw (with install-result.txt on its EFI partition) and <work dir>/emmc.img.
# With "update", the existing <work dir>/emmc.img is updated in place instead of a fresh install.
set -euo pipefail
IMG="${1:?image}"; T="${2:?work dir}"; MODE="${3:-}"
mkdir -p "$T"
cp --sparse=always "$IMG" "$T/stick.raw"
[ "$MODE" = update ] || { rm -f "$T/emmc.img"; truncate -s 64G "$T/emmc.img"; }
OFF=$(sfdisk -d "$T/stick.raw" | sed -nE 's/.*start= *([0-9]+),.*type=C12A7328.*/\1/p'); OFF=$((OFF * 512))
mcopy -n -i "$T/stick.raw@@$OFF" ::/EFI/GBRUNCH/kernel "$T/kernel"
mcopy -n -i "$T/stick.raw@@$OFF" ::/EFI/GBRUNCH/installer.gz "$T/installer.gz"
UUID=$(sfdisk -d "$T/stick.raw" | sed -nE 's/.*uuid=([0-9A-F-]+), name="boot_a".*/\1/p' | tr 'A-Z' 'a-z')
EXTRA=""; [ "$MODE" = update ] && EXTRA="gb_install=update"
start=$(date +%s)
timeout "${SECS:-5400}" qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu max -smp 4 -m 2048 \
	-display none -vga none -serial stdio -monitor none -no-reboot -nic none \
	-kernel "$T/kernel" -initrd "$T/installer.gz" \
	-append "rdinit=/init androidboot.boot_part_uuid=$UUID $EXTRA console=ttyS0,115200 loglevel=4" \
	-device qemu-xhci,id=xhci -drive "if=none,id=stick,format=raw,file=$T/stick.raw" -device usb-storage,bus=xhci.0,drive=stick \
	-device sdhci-pci -drive "if=none,id=mmc,format=raw,file=$T/emmc.img" -device emmc,drive=mmc \
	> "$T/installer-console.log" 2>&1 || true
echo "QEMU ran $(( $(date +%s) - start )) s"
echo "--- install-result.txt on the stick"
mcopy -n -i "$T/stick.raw@@$OFF" ::/EFI/GBRUNCH/install-result.txt - 2>&1 | head -30
