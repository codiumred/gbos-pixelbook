#!/bin/bash
# Build the Pixelbook (EVE) Googlebook OS image from scratch. Run inside Linux or WSL2 (tested: Ubuntu 26.04).
#
#   ./build.sh
#
# Environment (all optional):
#   WORK     work area, needs ~130 GB free             (default ~/googlebook-pixelbook)
#   INPUTS   downloaded inputs, see scripts/fetch_inputs.sh (default $WORK/inputs)
#   JOBS     parallel compile jobs                       (default: all CPUs)
#
# Output: $WORK/gbrunch-work/eve.raw, a 28.7 GB disk image for a 32 GB USB stick (docs/INSTALL.md).
# It contains Google's software: keep it for yourself, never publish it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HOME/googlebook-pixelbook}"
INPUTS="${INPUTS:-$WORK/inputs}"
GW="$WORK/gbrunch-work"
K="$INPUTS/kernel/common"
KOUT="$WORK/kernel-out"
CFG="$WORK/shipped.config"
mkdir -p "$WORK" "$GW"

missing=""
for t in git curl python3 make gcc clang ld.lld llvm-ar bc flex bison pahole cpio kmod lz4 zstd \
	dump.erofs mkfs.erofs debugfs sfdisk mcopy setfattr qemu-system-x86_64 qemu-img grub-mkstandalone rustc bindgen; do
	command -v "$t" >/dev/null || { [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"; command -v "$t" >/dev/null; } || missing="$missing $t"
done
if [ -n "$missing" ]; then
	echo "missing tools:$missing"
	echo "see docs/BUILD.md (Ubuntu packages, plus rustc 1.91.1 and bindgen-cli 0.72.1 via rustup/cargo)"
	exit 1
fi

bash "$ROOT/scripts/fetch_inputs.sh" "$INPUTS"
bash "$ROOT/kernel/apply.sh" "$K"
bash "$ROOT/image/gbrunch_assemble.sh" "$INPUTS" "$GW"

# The kernel is built with exactly the configuration Google shipped. gbrunch keeps Google's kernel on the
# image's EFI partition; its embedded config (CONFIG_IKCONFIG) is the reference.
if [ ! -s "$CFG" ]; then
	OFF="$(python3 - "$GW/native.raw" "$GW/kit/assets" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from inspect_recovery import gpt
with open(sys.argv[1], "rb") as f:
    print(next(p["offset"] for p in gpt(f) if p["type_guid"] == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"))
PY
)"
	mcopy -n -o -i "$GW/native.raw@@$OFF" ::/EFI/GBRUNCH/kernel "$WORK/google-kernel"
	"$K/scripts/extract-ikconfig" "$WORK/google-kernel" > "$CFG.part"
	grep -q '^CONFIG_X86_64=y' "$CFG.part" || { echo "no kernel config found in Google's kernel"; exit 1; }
	mv "$CFG.part" "$CFG"
fi

bash "$ROOT/image/build_eve_image.sh" "$INPUTS" "$GW" "$K" "$KOUT" "$CFG"
echo
echo "image: $GW/eve.raw"
sha256sum "$GW/eve.raw"
