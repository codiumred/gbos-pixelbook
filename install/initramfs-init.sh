#!/bin/bash
# /init of the installer initramfs (install/build_installer_initramfs.sh). Started by GRUB's "Install to the internal
# eMMC" entry after the user typed ERASE there. Google's kernel has no text console on the screen, so this runs
# without output: the screen keeps showing GRUB's last message. The result goes to the USB stick's EFI partition
# (/EFI/GBRUNCH/install-result.txt and install-log.txt), which the stick's boot menu shows on its next start.
# Success: power off. Failure: restart (into the stick's menu, which then shows what went wrong).
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t tmpfs -o mode=0755 tmpfs /dev
mdev -s
LOG=/tmp/install.log
log() { echo "$(date -u +%T) $*" >> "$LOG"; }
log "installer started: $(cat /proc/cmdline)"

# the eMMC controller driver (Google's vendor modules, not built into the kernel)
for m in cqhci sdhci-uhs2 sdhci-pci; do insmod "/modules/$m.ko" >> "$LOG" 2>&1 || log "insmod $m failed"; done

want="$(sed -n 's/.*androidboot\.boot_part_uuid=\([^ ]*\).*/\1/p' /proc/cmdline | tr 'A-Z' 'a-z')"
SRC=""; TGT=""
for i in $(seq 1 30); do	# USB and eMMC devices appear asynchronously
	mdev -s
	for d in /sys/block/*; do
		n="${d##*/}"
		case "$n" in loop*|ram*|zram*|mmcblk*boot*|mmcblk*rpmb) continue ;; esac
		[ -b "/dev/$n" ] || continue
		u="$(sfdisk -d "/dev/$n" 2>/dev/null | sed -nE 's/^[^ ]*[^0-9]13 : .*uuid=([0-9A-Fa-f-]+).*/\1/p' | tr 'A-Z' 'a-z')"
		[ -n "$want" ] && [ "$u" = "$want" ] && SRC="/dev/$n"
	done
	if [ -b /dev/mmcblk0 ] && [ "$(cat /sys/block/mmcblk0/device/type 2>/dev/null)" = MMC ]; then TGT=/dev/mmcblk0; fi
	[ -n "$SRC" ] && [ -n "$TGT" ] && break
	sleep 1
done
log "source=$SRC target=$TGT"

result() {	# <text>: write result and log to the stick's EFI partition
	[ -n "$SRC" ] || return
	local esp
	esp=$(( $(sfdisk -d "$SRC" | sed -nE 's/.*start= *([0-9]+),.*type=C12A7328.*/\1/p') * 512 ))
	printf '%s\n' "$1" > /tmp/install-result.txt
	tail -n 25 "$LOG" >> /tmp/install-result.txt
	mcopy -o -i "$SRC@@$esp" /tmp/install-result.txt ::/EFI/GBRUNCH/install-result.txt
	mcopy -o -i "$SRC@@$esp" "$LOG" ::/EFI/GBRUNCH/install-log.txt
	sync
}

if [ -z "$SRC" ] || [ -z "$TGT" ]; then
	log "could not find the USB stick ($want) or the internal eMMC"
	result "INSTALL FAILED: the USB stick or the internal eMMC was not found. Nothing was written."
	sleep 3; reboot -f
fi
if [ "$SRC" = "$TGT" ]; then
	result "INSTALL FAILED: started from the internal eMMC itself. Nothing was written."
	sleep 3; reboot -f
fi

MODE=""; grep -q "gb_install=update" /proc/cmdline && MODE=--update
log "mode: ${MODE:-fresh install}"
if INSTALL_LOG=/tmp/install-steps.log bash /installer/install_to_disk.sh --yes $MODE "$SRC" "$TGT" >> "$LOG" 2>&1; then
	cat /tmp/install-steps.log >> "$LOG" 2>/dev/null
	result "INSTALL SUCCEEDED $(date -u '+%F %T UTC'): Googlebook OS is on the internal eMMC. Remove the USB stick and turn the Pixelbook on."
	sync; sleep 2; poweroff -f
else
	cat /tmp/install-steps.log >> "$LOG" 2>/dev/null
	result "INSTALL FAILED $(date -u '+%F %T UTC'): see the lines below and /EFI/GBRUNCH/install-log.txt on this USB stick."
	sleep 3; reboot -f
fi
