#!/bin/bash
# Download (or reuse) everything the build needs that this repository does not contain, and verify each item
# against a pinned hash. Run inside Linux/WSL. Nothing here is redistributed: each user fetches Google's and
# AOSP's files from their official hosts.
#
#   scripts/fetch_inputs.sh [inputs dir]        (default: $INPUTS, else ~/googlebook-pixelbook/inputs)
#
# Result:
#   <inputs>/gbrunch/                     gbrunch at a pinned commit (compatibility kit, assembler, policy tool)
#   <inputs>/recovery/ruby-recovery.raw   Google's Lenovo "ruby" Googlebook recovery, build 16452207 (19 GB, sparse)
#   <inputs>/donor/super.raw              AOSP Cuttlefish build 16373615 super partition (baseline zlib source)
#   <inputs>/kernel/common/               AOSP kernel/common at the commit of the shipped 6.18.21-android17-5 kernel
#   <inputs>/chromeos/lib/firmware/intel/avs/   Pixelbook audio DSP firmware (see the note at the end)
#
# Already present files are reused after their hash is checked; a hash that does not match stops the script.
# Downloads: about 7.8 GB (recovery ZIP) + 1.2 GB (donor ZIP) + 0.3 GB (kernel source). Needs ~45 GB free.
set -euo pipefail
IN="${1:-${INPUTS:-$HOME/googlebook-pixelbook/inputs}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$IN"; IN="$(cd "$IN" && pwd)"

GBRUNCH_URL="${GBRUNCH_URL:-https://github.com/danbyumagic/gbrunch.git}"
GBRUNCH_COMMIT=4523889706b598d4f8c7380cb74bbac68ef3ac4e
GBRUNCH_KIT_SHA=ba6eac2e2c1482bb3b0e4f4c1aee658b1dc488cce54e5ccbb2726e01fa3376c3

RECOVERY_URL=https://dl.google.com/device/recovery/ruby-user/16452207/recovery.zip
RECOVERY_ZIP_SHA=3c4dc7f636f29a1207e71d001fd2864aa20ce8354faecd2ef1ae47582b977f6c
RECOVERY_RAW_SHA=4f4490415d4db0721fa99ad10abd64b1b05c284b6c0e413907da948561de8c9e

DONOR_URL="https://androidbuildinternal.googleapis.com/android/internal/build/v3/builds/16373615/aosp_cf_x86_64_only_phone-userdebug/attempts/latest/artifacts/aosp_cf_x86_64_only_phone-img-16373615.zip/url"
DONOR_ZIP_BYTES=1163638742
DONOR_ZIP_SHA=601d55e3197a2a612becc6931f111fd00caac5cbc70e0fa8261fbdb4cb22c695

KERNEL_URL=https://android.googlesource.com/kernel/common
KERNEL_TAG=android17-6.18-2026-06_r52
KERNEL_COMMIT_PREFIX=3938c8d97142     # the "g3938c8d97142" in the shipped kernel's release string

say() { printf '\n== %s\n' "$*"; }
# sha256 of a big file, remembered in <file>.sha256ok next to it (keyed by size and mtime) so reruns are fast
checked() {	# <file> <expected sha256>
	local f="$1" want="$2" stamp="$1.sha256ok" key
	key="$(stat -L -c '%s %Y' "$f") $want"
	if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then return 0; fi
	echo "verifying $(basename "$f") ..."
	[ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$want" ] || { echo "SHA-256 mismatch: $f"; return 1; }
	echo "$key" > "$stamp"
}

say "gbrunch $GBRUNCH_COMMIT"
if [ ! -d "$IN/gbrunch/.git" ]; then
	git init -q "$IN/gbrunch"
	git -C "$IN/gbrunch" fetch -q --depth 1 "$GBRUNCH_URL" "$GBRUNCH_COMMIT"
	git -C "$IN/gbrunch" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
[ "$(git -C "$IN/gbrunch" rev-parse HEAD)" = "$GBRUNCH_COMMIT" ] || { echo "gbrunch checkout is not at $GBRUNCH_COMMIT"; exit 1; }
checked "$IN/gbrunch/dist/gbrunch-compatibility-assets-v7.tar.gz" "$GBRUNCH_KIT_SHA"

say "Googlebook recovery (ruby, 16452207)"
mkdir -p "$IN/recovery"
RAW="$IN/recovery/ruby-recovery.raw"
if [ ! -e "$RAW" ]; then
	ZIP="$IN/recovery/ruby-recovery.zip"
	if [ ! -e "$ZIP" ]; then
		curl -fL --retry 3 -C - -o "$ZIP.part" "$RECOVERY_URL"
		mv "$ZIP.part" "$ZIP"
	fi
	checked "$ZIP" "$RECOVERY_ZIP_SHA"
	echo "extracting the raw image (sparse) ..."
	python3 - "$ZIP" "$RAW.part" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = [n for n in z.namelist() if n.endswith(".bin")]
assert len(names) == 1, names
with z.open(names[0]) as f, open(sys.argv[2], "wb") as out:
    total = 0
    while True:
        b = f.read(1 << 20)
        if not b:
            break
        if b.strip(b"\0"):
            out.write(b)
        else:
            out.seek(len(b), 1)
        total += len(b)
    out.truncate(total)
PY
	mv "$RAW.part" "$RAW"
fi
checked "$RAW" "$RECOVERY_RAW_SHA"

say "AOSP Cuttlefish donor (16373615)"
mkdir -p "$IN/donor"
if [ ! -e "$IN/donor/super.raw" ]; then
	DZ="$IN/donor/aosp_cf_img-16373615.zip"
	if [ ! -e "$DZ" ]; then
		# ci.android.com serves this file through a signed redirect that only honours ranged requests reliably
		: > "$DZ.part"; s=0; C=67108864
		while [ $s -lt $DONOR_ZIP_BYTES ]; do
			e=$((s + C - 1)); [ $e -ge $DONOR_ZIP_BYTES ] && e=$((DONOR_ZIP_BYTES - 1))
			for try in 1 2 3 4 5; do
				curl -sSL -r $s-$e -o "$IN/donor/chunk.tmp" "$DONOR_URL" && [ "$(stat -c %s "$IN/donor/chunk.tmp")" -eq $((e - s + 1)) ] && break
				sleep 3
			done
			[ "$(stat -c %s "$IN/donor/chunk.tmp")" -eq $((e - s + 1)) ] || { echo "donor download failed at byte $s"; exit 1; }
			cat "$IN/donor/chunk.tmp" >> "$DZ.part"; s=$((e + 1))
		done
		rm -f "$IN/donor/chunk.tmp"; mv "$DZ.part" "$DZ"
	fi
	checked "$DZ" "$DONOR_ZIP_SHA"
	python3 - "$DZ" "$IN/donor/super.img" <<'PY'
import shutil, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, z.open("super.img") as f, open(sys.argv[2], "wb") as out:
    shutil.copyfileobj(f, out, 1 << 20)
PY
	python3 "$ROOT/tools/unsparse.py" "$IN/donor/super.img" "$IN/donor/super.raw.part"
	mv "$IN/donor/super.raw.part" "$IN/donor/super.raw"; rm -f "$IN/donor/super.img"
fi
[ -s "$IN/donor/super.raw" ]

say "kernel/common $KERNEL_TAG"
if [ "${ALLOW_LOCAL_KERNEL_TREE:-0}" = 1 ] && [ -d "$IN/kernel/common" ]; then
	echo "using the existing tree at $IN/kernel/common without checking its commit (ALLOW_LOCAL_KERNEL_TREE=1)"
elif [ ! -d "$IN/kernel/common/.git" ]; then
	mkdir -p "$IN/kernel"
	git init -q "$IN/kernel/common"
	git -C "$IN/kernel/common" fetch -q --depth 1 "$KERNEL_URL" "refs/tags/$KERNEL_TAG"
	git -C "$IN/kernel/common" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
if [ "${ALLOW_LOCAL_KERNEL_TREE:-0}" != 1 ]; then
	case "$(git -C "$IN/kernel/common" rev-parse 'HEAD^{commit}')" in
		"$KERNEL_COMMIT_PREFIX"*) ;;
		*) echo "kernel tree is not at $KERNEL_COMMIT_PREFIX"; exit 1 ;;
	esac
fi

say "Pixelbook audio firmware"
if [ -d "$IN/chromeos/lib/firmware/intel/avs" ]; then
	(cd "$IN/chromeos/lib/firmware" && find intel/avs -type f -o -type l | sort | wc -l | xargs echo "files:")
else
	cat <<EOF
MISSING: $IN/chromeos/lib/firmware/intel/avs
The audio DSP firmware and topologies for this board are not in linux-firmware in the form ChromeOS uses.
Get them from ChromeOS itself, one of:
  - on a Pixelbook still running ChromeOS: copy /lib/firmware/intel/avs to a USB stick (see docs/BUILD.md)
  - from the official EVE ChromeOS recovery image: scripts/extract_chromeos_firmware.sh <recovery.bin> $IN/chromeos
Without them the image builds and boots, but has no internal audio.
EOF
fi
say "done: $IN"
