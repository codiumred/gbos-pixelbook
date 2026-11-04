#!/bin/bash
# Get the Pixelbook audio DSP firmware without a working ChromeOS Pixelbook: download Google's public ChromeOS recovery
# image for the Pixelbook ("eve"), take /lib/firmware/intel/avs out of it, and check the result against a pinned hash.
# Nothing here is redistributed: you fetch the file from Google's own download host, like the other inputs.
#
#   scripts/extract_chromeos_firmware.sh [inputs dir] [recovery .zip or .bin]
#                                             (default inputs: $INPUTS, else ~/googlebook-pixelbook/inputs)
#
# Result: <inputs>/chromeos/lib/firmware/intel/avs/   (the same files as copying them from a running Pixelbook)
# Downloads about 1.8 GB. Needs ~6 GB free while it runs (temporary files are removed at the end).
# If you already have the ZIP or the extracted .bin, pass it as the second argument and nothing is downloaded.
# Needs python3 and debugfs (package e2fsprogs).
set -euo pipefail
IN="${1:-${INPUTS:-$HOME/googlebook-pixelbook/inputs}}"
SRC="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$IN"; IN="$(cd "$IN" && pwd)"

. "$ROOT/scripts/pins.sh"     # EVE_RECOVERY_URL, EVE_RECOVERY_ZIP_SHA, EVE_AVS_SHA

say() { printf '\n== %s\n' "$*"; }
# sha256 over the sorted per-file hashes of a directory tree (file contents and relative names only)
tree_sha() { (cd "$1" && LC_ALL=C find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1); }

command -v debugfs >/dev/null || { echo "debugfs is missing. Install it: sudo apt install e2fsprogs"; exit 1; }
DEST="$IN/chromeos/lib/firmware/intel/avs"

if [ -d "$DEST" ] && [ "$(tree_sha "$DEST")" = "$EVE_AVS_SHA" ]; then
	echo "$DEST is already in place and matches the pinned hash."
	exit 0
fi

# temporary files go next to the inputs, not into /tmp (on WSL /tmp is a small RAM disk)
W="$(mktemp -d "$IN/.eve-firmware.XXXXXX")"
trap 'rm -rf "$W"' EXIT

say "ChromeOS recovery image for the Pixelbook (eve)"
if [ -z "$SRC" ]; then
	SRC="$IN/eve-recovery.zip"
	if [ ! -e "$SRC" ]; then
		curl -fL --retry 3 -C - -o "$SRC.part" "$EVE_RECOVERY_URL" || {
			echo "Download failed: $EVE_RECOVERY_URL"
			echo "Google may have replaced this build. Copy the firmware from a running Pixelbook instead (docs/BUILD.md)."
			exit 1; }
		mv "$SRC.part" "$SRC"
	fi
fi
case "$SRC" in
	*.zip) if [ -n "$EVE_RECOVERY_ZIP_SHA" ]; then
		echo "verifying $(basename "$SRC") ..."
		[ "$(sha256sum < "$SRC" | cut -d' ' -f1)" = "$EVE_RECOVERY_ZIP_SHA" ] || { echo "SHA-256 mismatch: $SRC"; exit 1; }
	fi ;;
esac

say "ROOT-A partition"
# Stream the .bin out of the ZIP (or read it directly) and keep only the ROOT-A partition, found through the GPT.
python3 -I - "$SRC" "$W/root-a.img" <<'PY'
import struct, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
if src.endswith(".zip"):
    z = zipfile.ZipFile(src)
    names = [n for n in z.namelist() if n.endswith(".bin")]
    assert len(names) == 1, names
    f = z.open(names[0])
else:
    f = open(src, "rb")
head = f.read(1 << 16)                                  # protective MBR, GPT header (LBA 1), entries (LBA 2..)
assert head[512:520] == b"EFI PART", "not a GPT disk image"
entries_lba = struct.unpack("<Q", head[512 + 72:512 + 80])[0]
count, size = struct.unpack("<II", head[512 + 80:512 + 88])
assert (entries_lba * 512 + count * size) <= len(head), "partition table is larger than expected"
start = length = None
for i in range(count):
    e = head[entries_lba * 512 + i * size:][:size]
    if e[:16] == b"\0" * 16:
        continue
    first, last = struct.unpack("<QQ", e[32:48])
    if e[56:128].decode("utf-16le").rstrip("\0") == "ROOT-A":
        start, length = first * 512, (last - first + 1) * 512
assert start is not None, "no ROOT-A partition"
pos = len(head)
while pos < start:                                      # skip to the partition (the stream cannot seek)
    pos += len(f.read(min(1 << 20, start - pos)) or sys.exit("image ends before ROOT-A"))
with open(out, "wb") as o:
    left = length
    while left:
        b = f.read(min(1 << 20, left))
        if not b:
            sys.exit("image ends inside ROOT-A")
        if b.strip(b"\0"):
            o.write(b)
        else:
            o.seek(len(b), 1)
        left -= len(b)
    o.truncate(length)
print("ROOT-A: %d MiB" % (length >> 20))
PY

say "intel/avs"
mkdir "$W/rdump"
debugfs -R "rdump /lib/firmware/intel/avs $W/rdump" "$W/root-a.img" >/dev/null 2>&1 || true
[ -d "$W/rdump/avs" ] || {
	echo "This ChromeOS build has no /lib/firmware/intel/avs. Builds before about 16000 use the older audio driver."
	echo "Use a newer Pixelbook build (see EVE_RECOVERY_URL in scripts/pins.sh)."
	exit 1; }
# ChromeOS links a few of these files to each other; copy the files themselves, like "cp -rL" on the Pixelbook does
rm -rf "$DEST"; mkdir -p "$DEST"
cp -rL "$W/rdump/avs/." "$DEST/"
chmod -R u+rwX,go+rX "$DEST"

GOT="$(tree_sha "$DEST")"
if [ -z "$EVE_AVS_SHA" ]; then
	echo "note: no pinned hash for the firmware tree; its hash is $GOT"
elif [ "$GOT" != "$EVE_AVS_SHA" ]; then
	echo "The firmware does not match the pinned hash."
	echo "  expected $EVE_AVS_SHA"
	echo "  got      $GOT"
	rm -rf "$DEST"; exit 1
fi
(cd "$DEST" && find . -type f | sort | sed 's#^\./#  #')
say "done: $DEST"
