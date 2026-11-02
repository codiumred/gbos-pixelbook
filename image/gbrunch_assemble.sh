#!/bin/bash
# Assemble gbrunch's locally built Android image (compatibility partition, derived vendor, software
# KeyMint/Gatekeeper) from the official recovery, using gbrunch's own V7 asset kit and assembler,
# then pull the generated initrd and kernel command line out of its EFI partition so the image can
# be booted with a different kernel (see qemu/qemu_gbrunch_boot.sh). Run inside Linux/WSL.
#
#   image/gbrunch_assemble.sh <inputs dir> <work dir>
# Needs: python3 qemu-system-x86 qemu-utils mtools lz4. Reads the 19 GB recovery twice; the
# vendor derivation runs in gbrunch's isolated tool VM under TCG and takes several minutes.
set -euo pipefail
IN="${1:?inputs dir}"; W="${2:?work dir}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/pins.sh"     # RECOVERY_RAW_SHA: which official recovery build this repository is built for
KIT="$IN/gbrunch/dist/gbrunch-compatibility-assets-v7.tar.gz"
SRC="$IN/recovery/ruby-recovery.raw"
mkdir -p "$W"
if [ ! -d "$W/kit" ]; then
	mkdir -p "$W/kit" && tar -xzf "$KIT" -C "$W/kit" --strip-components=1
fi
if [ ! -f "$W/recovery.raw" ]; then
	echo "copying recovery image into the work dir (sparse)..."
	cp --sparse=always "$SRC" "$W/recovery.raw.part" && mv "$W/recovery.raw.part" "$W/recovery.raw"
fi
if [ ! -f "$W/native.raw" ]; then
	(cd "$W/kit/assets" && RECOVERY_RAW_SHA="$RECOVERY_RAW_SHA" python3 "$HERE/assemble_with_pin.py" --recovery-raw "$W/recovery.raw" \
		--output "$W/native.raw" --cache "$W/cache" --format raw)
fi
# EFI system partition offset from the GPT, then the files gbrunch's GRUB would load.
OFF="$(python3 - "$W/native.raw" "$W/kit/assets" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from inspect_recovery import gpt
with open(sys.argv[1], "rb") as f:
    parts = gpt(f)
print(next(p["offset"] for p in parts if p["type_guid"] == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"))
PY
)"
mcopy -n -o -i "$W/native.raw@@$OFF" ::/EFI/GBRUNCH/initrd.gz "$W/gbrunch-initrd.gz"
mcopy -n -o -i "$W/native.raw@@$OFF" ::/EFI/GBRUNCH/grub.cfg "$W/gbrunch-grub.cfg"
grep -m1 -o 'linux /EFI/GBRUNCH/kernel .*' "$W/gbrunch-grub.cfg" | cut -d' ' -f3- > "$W/gbrunch-cmdline.txt"
ls -la "$W/native.raw" "$W/gbrunch-initrd.gz"
echo "cmdline: $(cut -c1-200 "$W/gbrunch-cmdline.txt")..."
