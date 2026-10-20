#!/bin/bash
# Install Googlebook OS from the USB stick (or a built image file) onto another disk, normally the Pixelbook's
# internal eMMC, with persistent app data. Run as root on Linux: from a Linux live USB on the Pixelbook, or through
# the installer boot entry (install/initramfs).
#
#   install/install_to_disk.sh [--yes] [--update] <source> <target>
#     source   the Googlebook USB stick (e.g. /dev/sda) or an image file built by build.sh (eve.raw)
#     target   the disk to ERASE and install to (on the Pixelbook: /dev/mmcblk0)
#     --update the target already holds an install made by this script: replace only the system partitions with the
#              source's and keep everything else (partition table and IDs, app data, metadata, security stores, logs).
#              Refused unless both have the same partition layout.
#
# What it does, in order (nothing is written before the confirmation):
#   1. reads the source partition table and checks it is a Googlebook image from this project
#   2. writes the same partition table to the target with fresh partition UUIDs, and userdata grown to the end
#   3. copies every partition except userdata (and two unused leftovers of gbrunch's layout); partitions written
#      at run time (metadata, misc, security stores, logs) get their pristine contents instead of the stick's
#   4. formats userdata the way Android's own first boot does
#   5. writes /EFI/GBRUNCH/install.cfg on the target's EFI partition: /data on disk instead of in RAM
#   6. reads everything back and compares checksums
# Environment: INSTALL_ALLOW_FILE_TARGET=1 lets <target> be a regular file (tests); MIN_DATA_GIB (default 16).
set -euo pipefail
YES=0; UPDATE=0
while [ $# -gt 0 ]; do
	case "$1" in --yes) YES=1; shift ;; --update) UPDATE=1; shift ;; *) break ;; esac
done
SRC="${1:?usage: install_to_disk.sh [--yes] [--update] <source> <target>}"; DST="${2:?target disk}"
MIN_DATA_GIB="${MIN_DATA_GIB:-16}"
LOG="${INSTALL_LOG:-/tmp/googlebook-install.log}"
say() { echo "$*" | tee -a "$LOG"; }
die() { say "ERROR: $*"; exit 1; }
: > "$LOG" 2>/dev/null || LOG=/dev/null

[ "$(id -u)" = 0 ] || die "run as root"
for t in sfdisk dd sha256sum gzip mcopy mke2fs tune2fs blockdev; do command -v $t >/dev/null || die "missing tool: $t"; done
[ -e "$SRC" ] || die "source $SRC not found"
[ -e "$DST" ] || die "target $DST not found"
[ "$(readlink -f "$SRC")" != "$(readlink -f "$DST")" ] || die "source and target are the same"
if [ -b "$DST" ]; then
	grep -qE "^$(readlink -f "$DST")(p?[0-9]+)? " /proc/mounts && die "$DST (or one of its partitions) is mounted"
	TSIZE=$(blockdev --getsize64 "$DST")
elif [ "${INSTALL_ALLOW_FILE_TARGET:-0}" = 1 ] && [ -f "$DST" ]; then
	TSIZE=$(stat -c %s "$DST")
else
	die "target must be a disk (block device)"
fi

# --- 1. source layout ---------------------------------------------------------------------------------------------
TABLE="$(sfdisk -d "$SRC")" || die "cannot read the partition table of $SRC"
# one line per partition: number start size name, in partition-number order
PARTS="$(echo "$TABLE" | sed -nE 's/^[^ ]*[^0-9]([0-9]+) : start= *([0-9]+), size= *([0-9]+),.*name="([^"]+)".*/\1 \2 \3 \4/p' | sort -n)"
pstart() { echo "$PARTS" | awk -v n="$1" '$4 == n {print $2}'; }
psize()  { echo "$PARTS" | awk -v n="$1" '$4 == n {print $3}'; }
pnum()   { echo "$PARTS" | awk -v n="$1" '$4 == n {print $1}'; }
for n in EFI-SYSTEM super boot_a GBRUNCH GBVENDOR GBLOG userdata; do [ -n "$(pstart $n)" ] || die "source has no $n partition: not a Googlebook image"; done
[ "$(pnum boot_a)" = 13 ] || die "boot_a is not partition 13 (the boot menu relies on it)"
COUNT=$(echo "$PARTS" | wc -l)
[ "$(echo "$PARTS" | awk '{print $1}' | tr '\n' ' ')" = "$(seq -s ' ' 1 "$COUNT") " ] || die "partition numbers are not 1..$COUNT"
UD_START=$(pstart userdata)
[ "$UD_START" = "$(echo "$PARTS" | awk '{print $2}' | sort -n | tail -1)" ] || die "userdata is not the last partition"
DATA_BYTES=$(( TSIZE - UD_START * 512 - 1024 * 1024 ))
[ $UPDATE = 1 ] || [ $DATA_BYTES -ge $(( MIN_DATA_GIB << 30 )) ] || die "target too small: $((TSIZE >> 30)) GiB (needs $(( (UD_START * 512 >> 30) + MIN_DATA_GIB )) GiB)"
ESP_SRC=$(( $(pstart EFI-SYSTEM) * 512 ))
mcopy -i "$SRC@@$ESP_SRC" ::/EFI/GBRUNCH/pristine/metadata.img.gz - > /dev/null 2>&1 \
	|| die "source has no pristine runtime partitions (/EFI/GBRUNCH/pristine): built before installer support"

tparts() { sfdisk -d "$DST" 2>/dev/null | sed -nE 's/^[^ ]*[^0-9]([0-9]+) : start= *([0-9]+), size= *([0-9]+),.*name="([^"]+)".*/\1 \2 \3 \4/p' | sort -n; }
if [ $UPDATE = 1 ]; then
	# same entries at the same places; only userdata may differ in size (it was grown to fill the disk)
	TPARTS="$(tparts)"
	[ -n "$TPARTS" ] || die "target has no partition table: use a fresh install instead of --update"
	[ "$(echo "$TPARTS" | awk '$4 != "userdata" {print $1, $2, $3, $4}')" = "$(echo "$PARTS" | awk '$4 != "userdata" {print $1, $2, $3, $4}')" ] \
		&& [ "$(echo "$TPARTS" | awk '$4 == "userdata" {print $1, $2}')" = "$(echo "$PARTS" | awk '$4 == "userdata" {print $1, $2}')" ] \
		|| die "target layout differs from the source: an update cannot keep its data; a fresh install is needed"
fi

# --- confirmation ---------------------------------------------------------------------------------------------------
say "source: $SRC"
say "target: $DST  ($((TSIZE / 1000000000)) GB)"
[ -b "$DST" ] && command -v lsblk >/dev/null && lsblk -dno MODEL,SIZE,TRAN "$DST" 2>/dev/null | sed 's/^/        /' | tee -a "$LOG"
if [ $UPDATE = 1 ]; then
	say "UPDATE: the system partitions on $DST are replaced; app data and settings are kept."
	WORD=UPDATE
else
	say "app data (userdata): $((DATA_BYTES >> 30)) GiB on the target"
	say "EVERYTHING ON $DST WILL BE ERASED."
	WORD=ERASE
fi
if [ $YES != 1 ]; then
	printf 'Type %s to continue: ' "$WORD"; read -r answer
	[ "$answer" = "$WORD" ] || die "cancelled"
fi

# --- 2. partition table ---------------------------------------------------------------------------------------------
# Same entries, types, names and attributes; no uuid/label-id so sfdisk creates fresh ones (an internal disk with the
# stick's UUIDs would confuse Android's boot-device lookup whenever the stick is plugged in). userdata gets no size:
# it fills the disk. Lines without a device name are numbered in order, which is the source's order.
SCRIPT="$(echo "$TABLE" | grep -E '^(label|unit|first-lba|sector-size):' ; \
	echo "$TABLE" | grep -E '^[^ ]* : start=' | sed -E 's/^[^:]*: //; s/, uuid=[0-9A-Fa-f-]+//' | \
	sed -E '/name="userdata"/ s/, size= *[0-9]+//')"
if [ $UPDATE = 1 ]; then
	say "keeping the partition table"
elif [ -b "$DST" ]; then
	say "writing partition table"
	wipefs -a -q "$DST" 2>/dev/null || true
	echo "$SCRIPT" | sfdisk -q --wipe always "$DST" >> "$LOG" 2>&1 || die "sfdisk failed (see $LOG)"
	blockdev --rereadpt "$DST" 2>/dev/null || true
else
	say "writing partition table"
	echo "$SCRIPT" | sfdisk -q "$DST" >> "$LOG" 2>&1 || die "sfdisk failed (see $LOG)"
fi
TPARTS="$(tparts)"
[ "$(echo "$TPARTS" | awk '$4 != "userdata" {print $1, $2, $3, $4}')" = "$(echo "$PARTS" | awk '$4 != "userdata" {print $1, $2, $3, $4}')" ] \
	|| die "new partition table does not match the source layout"
[ "$(echo "$TPARTS" | awk '$4 == "boot_a" {print $1}')" = 13 ] || die "boot_a did not end up as partition 13"
TUD_SIZE=$(echo "$TPARTS" | awk '$4 == "userdata" {print $3}')

# --- 3. copy ----------------------------------------------------------------------------------------------------------
copy() {	# <start sector> <sectors>
	dd if="$SRC" of="$DST" bs=4M iflag=skip_bytes,count_bytes oflag=seek_bytes conv=notrunc,fsync status=none \
		skip=$(( $1 * 512 )) seek=$(( $1 * 512 )) count=$(( $2 * 512 ))
}
zero() {
	dd if=/dev/zero of="$DST" bs=4M oflag=seek_bytes iflag=count_bytes conv=notrunc,fsync status=none \
		seek=$(( $1 * 512 )) count=$(( $2 * 512 ))
}
RUNTIME_ZERO="misc desktop_security_persist desktop_security_storage frp_persist"
RUNTIME_PRISTINE="metadata GBLOG"
SKIP="userdata userdata_old GBVENDOR_OLD"
if [ $UPDATE = 1 ]; then	# keep the target's run-time state
	SKIP="$SKIP $RUNTIME_ZERO $RUNTIME_PRISTINE"; RUNTIME_ZERO=""; RUNTIME_PRISTINE=""
fi
total=0; for p in $(echo "$PARTS" | awk '{print $4}'); do case " $SKIP $RUNTIME_ZERO $RUNTIME_PRISTINE " in *" $p "*) ;; *) total=$(( total + $(psize $p) )); esac; done
done_s=0
while read -r num start size name; do
	case " $SKIP " in *" $name "*) continue ;; esac
	case " $RUNTIME_ZERO " in
		*" $name "*) say "  $name: zeroed (pristine state)"; zero "$start" "$size"; continue ;;
	esac
	case " $RUNTIME_PRISTINE " in
		*" $name "*)
			say "  $name: pristine copy"
			zero "$start" "$size"
			mcopy -i "$SRC@@$ESP_SRC" "::/EFI/GBRUNCH/pristine/$name.img.gz" - | gzip -dc | \
				dd of="$DST" bs=4M oflag=seek_bytes conv=notrunc,fsync status=none seek=$(( start * 512 ))
			continue ;;
	esac
	done_s=$(( done_s + size ))
	say "  $name: $(( size / 2048 )) MiB  [$(( done_s * 100 / total ))%]"
	copy "$start" "$size"
done <<< "$PARTS"

# --- 4. userdata -----------------------------------------------------------------------------------------------------
if [ $UPDATE = 1 ]; then
	say "keeping userdata ($(( TUD_SIZE / 2097152 )) GiB)"
else
say "formatting userdata ($(( TUD_SIZE / 2097152 )) GiB)"
FEATS="has_journal,ext_attr,dir_index,filetype,extent,casefold,sparse_super,large_file,huge_file,uninit_bg,dir_nlink,extra_isize,quota,project,verity,^resize_inode,^flex_bg,^metadata_csum,^64bit,^orphan_file"
mke2fs -F -q -t ext4 -b 4096 -I 512 -i 16384 -m 2 -J size=64 -O "$FEATS" \
	-E "encoding=utf8,offset=$(( UD_START * 512 )),quotatype=usrquota:grpquota:prjquota" "$DST" $(( TUD_SIZE / 8 )) >> "$LOG" 2>&1 \
	|| die "mke2fs failed (see $LOG)"
tune2fs -g 1065 "$DST?offset=$(( UD_START * 512 ))" > /dev/null 2>&1 || true	# Android's reserved-blocks group (best effort)
fi

# --- 5. boot settings ------------------------------------------------------------------------------------------------
ESP_DST=$(( $(echo "$TPARTS" | awk '$4 == "EFI-SYSTEM" {print $2}') * 512 ))
printf '# written by install_to_disk.sh on %s: this disk keeps app data on its userdata partition\nset gb_data=disk\n' "$(date -u +%F)" > /tmp/gb-install.cfg
mcopy -o -i "$DST@@$ESP_DST" /tmp/gb-install.cfg ::/EFI/GBRUNCH/install.cfg || die "cannot write install.cfg"
rm -f /tmp/gb-install.cfg

# --- 6. verify ----------------------------------------------------------------------------------------------------------
say "verifying"
sync
hash_range() { dd if="$1" bs=4M iflag=skip_bytes,count_bytes status=none skip=$(( $2 * 512 )) count=$(( $3 * 512 )) | sha256sum | cut -d' ' -f1; }
while read -r num start size name; do
	case " $SKIP $RUNTIME_ZERO $RUNTIME_PRISTINE EFI-SYSTEM " in *" $name "*) continue ;; esac
	[ "$(hash_range "$SRC" "$start" "$size")" = "$(hash_range "$DST" "$start" "$size")" ] || die "verification failed for $name"
done <<< "$PARTS"
mcopy -i "$DST@@$ESP_DST" ::/EFI/GBRUNCH/kernel - | sha256sum | cut -d' ' -f1 > /tmp/gb-k1
mcopy -i "$SRC@@$ESP_SRC" ::/EFI/GBRUNCH/kernel - | sha256sum | cut -d' ' -f1 > /tmp/gb-k2
cmp -s /tmp/gb-k1 /tmp/gb-k2 || die "verification failed for the EFI partition"
rm -f /tmp/gb-k1 /tmp/gb-k2
if [ $UPDATE = 1 ]; then
	say "done: Googlebook OS on $DST updated, data kept. Remove the USB stick and restart."
else
	say "done: Googlebook OS installed on $DST. Remove the USB stick and restart."
fi
