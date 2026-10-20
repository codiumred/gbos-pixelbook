#!/bin/bash
# Build the installer initramfs that GRUB's "Install to the internal eMMC" entry boots with our kernel: a minimal
# Linux userland (busybox for mount/mdev/power, and the build machine's bash, util-linux, e2fsprogs, mtools and
# coreutils with their libraries) plus install_to_disk.sh and the eMMC controller modules. Run inside Linux/WSL.
#   install/build_installer_initramfs.sh <output .gz> <directory with cqhci.ko sdhci-uhs2.ko sdhci-pci.ko>
set -euo pipefail
OUT="${1:?output initramfs}"; GM="${2:?module directory}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v busybox >/dev/null && file -L "$(command -v busybox)" | grep -q "statically linked" \
	|| { echo "needs a static busybox (apt install busybox-static)"; exit 1; }
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
mkdir -p "$R"/{bin,dev,proc,sys,tmp,etc,modules,installer}

cp "$(command -v busybox)" "$R/bin/busybox"
for a in sh mount umount mdev insmod poweroff reboot sleep mkdir ls; do ln -s busybox "$R/bin/$a"; done

copy_with_libs() {	# <binary path> <name in /bin>
	local real
	real="$(readlink -f "$1")"
	cp "$real" "$R/bin/$2"
	ldd "$real" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | while read -r lib; do
		[ -e "$R$lib" ] || { mkdir -p "$R$(dirname "$lib")"; cp -L "$lib" "$R$lib"; }
	done
}
for t in bash sfdisk wipefs lsblk blkid mke2fs tune2fs mcopy mmd dd sha256sum gzip readlink stat sort seq tr id date \
	cmp cut sync awk sed grep blockdev rm cat wc head tail tee; do
	# Ubuntu 25.10+ ships the Rust coreutils, whose every tool is a copy of one 11 MB binary; prefer the GNU
	# versions (installed as gnu<name>) when present, they are about 100 KB each.
	p="$(command -v "gnu$t" || command -v "$t")" || { echo "missing $t"; exit 1; }
	copy_with_libs "$p" "$t"
done
[ -f /etc/mke2fs.conf ] && cp /etc/mke2fs.conf "$R/etc/"
for m in cqhci sdhci-uhs2 sdhci-pci; do cp "$GM/$m.ko" "$R/modules/"; done
install -m 0755 "$HERE/initramfs-init.sh" "$R/init"
install -m 0755 "$HERE/install_to_disk.sh" "$R/installer/install_to_disk.sh"
(cd "$R" && find . | LC_ALL=C sort | cpio -o -H newc --quiet | gzip -9n) > "$OUT"
echo "installer initramfs: $(stat -c %s "$OUT") bytes, $(cd "$R" && find . -type f | wc -l) files"
