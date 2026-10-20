#!/bin/bash
# Build the Pixelbook (EVE, Kaby Lake-Y) variant of the gbrunch image. Run inside Linux/WSL.
#
#   image/build_eve_image.sh <inputs dir> <work dir> <kernel tree> <kernel out dir> <shipped config>
# (build.sh at the repository root runs this with the default paths; scripts/fetch_inputs.sh fills <inputs dir>)
#
# Starts from gbrunch's assembled image (image/gbrunch_assemble.sh), keeps every partition as
# it is and replaces only what its EFI partition boots:
#   kernel      rebuilt 6.18.21-android17-5 with the ISA emulator (kernel/)
#   initrd      gbrunch's initrd + i915 and its dependencies + Kaby Lake GPU firmware,
#               with the first-stage module list switched from Xe to i915
#   grub.cfg    no HP-only gate; adds the options this board needs
# Output: <work dir>/eve.raw (a regular file; this script never writes to a device) plus
# eve-initrd.gz / eve-cmdline.txt for direct-kernel QEMU tests.
# The result contains Google-derived partitions: local use only, do not publish it.
set -euo pipefail
IN="${1:?inputs dir}"; W="${2:?work dir}"; K="${3:?kernel tree}"; O="${4:?kernel out dir}"; CFG="${5:?shipped config}"
IMG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$(cd "$IMG/.." && pwd)"
IN="$(cd "$IN" && pwd)"
export GBRUNCH_TOOLS="$IN/gbrunch/tools"	# for lp_offset.py
FWURL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/i915"
FW="kbl_dmc_ver1_04.bin kbl_guc_70.1.1.bin kbl_huc_4.0.0.bin"
MODS="intel-gtt.ko i2c-algo-bit.ko wmi.ko video.ko drm_buddy.ko drm_display_helper.ko i915.ko"

[ -f "$W/native.raw" ] || { echo "run gbrunch_assemble.sh first"; exit 1; }
mkdir -p "$W/eve/fw/i915"

# 1. GPU firmware (redistributable Intel blobs from linux-firmware; not kept in this repository)
for f in $FW; do
	[ -s "$W/eve/fw/i915/$f" ] || curl -sSfL --retry 3 -o "$W/eve/fw/i915/$f" "$FWURL/$f"
done
(cd "$W/eve/fw" && sha256sum i915/*) | tee "$W/eve/firmware.sha256"

# 2. the kernel itself (bzImage and modules; incremental, nothing to do when the tree is unchanged), then stripped,
#    signed modules from that build. Without this step the image would silently carry whatever bzImage was last built.
CONFIG_FRAGMENTS="$HERE/kernel/eve.config" bash "$HERE/kernel/build.sh" "$K" "$O" "$CFG" > "$W/eve/kernel_build.log" 2>&1 \
	|| { tail -n 30 "$W/eve/kernel_build.log"; exit 1; }
rm -rf "$W/eve/staging"
CONFIG_FRAGMENTS="$HERE/kernel/eve.config" bash "$HERE/kernel/build.sh" "$K" "$O" "$CFG" \
	INSTALL_MOD_PATH="$W/eve/staging" INSTALL_MOD_STRIP=1 modules_install > "$W/eve/modules_install.log" 2>&1
REL="$(ls "$W/eve/staging/lib/modules")"

# 3. initrd = gbrunch initrd + overlay (later cpio members replace earlier ones).
#    The eMMC controller driver joins the first stage too: the MMC core, block layer and SDHCI are built into the
#    kernel, but the Pixelbook's controller (8086:9d2b) needs sdhci-pci.ko, a Google vendor module that lives in
#    vendor_dlkm. On an internal install vendor_dlkm is itself on the eMMC, so the first stage must bring it.
GMODS="cqhci.ko sdhci-uhs2.ko sdhci-pci.ko"
rm -rf "$W/eve/gmods"; mkdir -p "$W/eve/gmods"
DLKM0="$(python3 "$IMG/lp_offset.py" "$W/native.raw" vendor_dlkm_a | cut -d' ' -f1)"
for m in $GMODS modules.dep; do
	dump.erofs --offset="$DLKM0" --cat --path="/lib/modules/$m" "$W/native.raw" > "$W/eve/gmods/$m"
	[ -s "$W/eve/gmods/$m" ] || { echo "vendor_dlkm has no $m"; exit 1; }
done
bash "$HERE/install/build_installer_initramfs.sh" "$W/eve/installer.gz" "$W/eve/gmods"
python3 - "$W" "$REL" "$MODS" "$FW" "$GMODS" <<'PY'
import gzip, pathlib, sys
W, rel, mods, fws = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3].split(), sys.argv[4].split()
gmods = sys.argv[5].split()
stage = W / "eve/staging/lib/modules" / rel
gdir = W / "eve/gmods"

def entry(name, data, mode, ino):
    n = name.encode() + bytes(1)
    h = b"070701" + b"".join(f"{v:08x}".encode() for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0)) + n
    h += bytes(-len(h) % 4) + data
    return h + bytes(-len(h) % 4)

found = {p.name: p for p in stage.rglob("*.ko")}
dep = {}
for line in (stage / "modules.dep").read_text().splitlines():
    k, _, v = line.partition(":")
    dep[k.rsplit("/", 1)[-1]] = [d.rsplit("/", 1)[-1] for d in v.split()]
files, ino = [], 980000
for m in mods:
    files.append((f"lib/modules/{m}", found[m].read_bytes(), 0o100644))
for line in (gdir / "modules.dep").read_text().splitlines():
    k, _, v = line.partition(":")
    if k.rsplit("/", 1)[-1] in gmods:
        dep[k.rsplit("/", 1)[-1]] = [d.rsplit("/", 1)[-1] for d in v.split()]
for m in gmods:
    assert all(d in gmods for d in dep.get(m, [])), (m, dep.get(m))
    files.append((f"lib/modules/{m}", (gdir / m).read_bytes(), 0o100644))
mods = mods + gmods
deps = "".join(f"/lib/modules/{m}:" + "".join(f" /lib/modules/{d}" for d in dep.get(m, [])) + "\n" for m in mods)
load = "".join(m + "\n" for m in mods)
alias = "".join(l + "\n" for l in (stage / "modules.alias").read_text().splitlines()
                if l.split()[-1] in {m[:-3].replace("-", "_") for m in mods})
for name, text in (("modules.load", load), ("modules.load.recovery", load), ("modules.dep", deps),
                   ("modules.alias", alias), ("modules.softdep", "\n"), ("modules.options", "\n")):
    files.append((f"lib/modules/{name}", text.encode(), 0o100644))
for f in fws:
    files.append((f"lib/firmware/i915/{f}", (W / "eve/fw/i915" / f).read_bytes(), 0o100644))
# first-stage fstab = gbrunch's, with a gentler /metadata mount: on a slow flash drive "data=journal,commit=1"
# means a synchronous journal write every second.
fst = (W / "kit/assets/fstab.android-desktop").read_text()
fst = fst.replace("noatime,nosuid,nodev,discard,data=journal,commit=1", "noatime,nosuid,nodev,commit=30")
files.append(("first_stage_ramdisk/fstab.android-desktop", fst.encode(), 0o100644))
overlay = b""
for name, data, mode in files:
    overlay += entry(name, data, mode, ino); ino += 1
overlay += entry("TRAILER!!!", b"", 0, ino)
base = gzip.decompress((W / "gbrunch-initrd.gz").read_bytes())
(W / "eve-initrd.gz").write_bytes(gzip.compress(base + overlay, 6, mtime=0))
print("initrd:", (W / "eve-initrd.gz").stat().st_size, "bytes; first-stage modules:", " ".join(mods))
PY

# 4. kernel command line: gbrunch's, minus the PC serial console, plus board options
# androidboot.boot_part_uuid names the boot_a partition of the disk Android should use. It is removed here and set by
# the menu at boot time instead (see grub.cfg below), so the same menu works on the USB stick and on an internal
# install whose partitions have fresh UUIDs.
BASE="$(sed -E 's/ ?console=ttyS0,115200//; s/ ?earlycon=[^ ]+//; s/ ?androidboot\.boot_part_uuid=[^ ]+//' "$W/gbrunch-cmdline.txt")"
UUID0="$(grep -o 'androidboot\.boot_part_uuid=[^ ]*' "$W/gbrunch-cmdline.txt" | cut -d= -f2)"
# module_blacklist: keep Google's userland away from the Pixelbook's Cr50 TPM (ChromeOS owns it) during
# these experiments, and skip cros_ec_debugfs as Google's own command line does.
# snd_intel_dspcfg.dsp_driver=4 selects the AVS driver for the Kaby Lake audio DSP. The shipped kernel has
# CONFIG_SND_SOC_INTEL_AVS unset, so its built-in DSP selection forces "legacy" for 8086:9d71 and Google's
# snd_soc_avs.ko refuses to probe (no sound card at all). isa_emu=profile logs the hottest emulated sites
# to the kernel log every 10 s (the logger cannot read /proc/isa_emu under SELinux).
# snd_soc_avs.obsolete_card_names=1: ChromeOS's AVS topologies and UCM files (the only ones for this board) assume
# the old behaviour: card names avs_<codec> and PCM device numbers handed out in order. With the new default
# every PCM that has no explicit id lands on device 0, which makes the speaker and HDMI cards fail with -EBUSY
# (error -16 in the first AVS boot). libmodprobe applies "module.param=value" from the command line.
# i915.enable_dpcd_backlight=1: the Pixelbook panel is dimmed over the eDP AUX channel (DPCD), not by the PWM output
# i915 picks from the VBT; ChromeOS boots EVE with exactly this option (eve-dmesg.txt). Without it the lights HAL
# writes intel_backlight/brightness and nothing changes on screen.
DEV="$BASE intel_iommu=igfx_off firmware_class.path=/vendor/firmware isa_emu=profile snd_intel_dspcfg.dsp_driver=4 snd_soc_avs.obsolete_card_names=1 i915.enable_dpcd_backlight=1 module_blacklist=tpm,tpm_tis_core,tpm_tis,tpm_tis_spi,tpm_tis_i2c_cr50,cros_ec_debugfs"
echo "$DEV" > "$W/eve-cmdline.txt"
# Crash capture for the audio test entry: every lockup detector panics, a panic reboots after 10 s (overrides
# gbrunch's panic=0), and Google's chromeos_pstore (ramoops in the ACPI-reserved RAM region) keeps the kernel console
# across that warm reboot; the logger copies /sys/fs/pstore into the next run's log folder. The RCU stall detector
# runs on the other CPU, so it also fires when one CPU is stuck on a hung device access.
# Suspend tests: keep the console running through suspend (so ramoops records a hang during resume) and log every
# PM step.
SUSPENDDBG="no_console_suspend pm_debug_messages"
CRASH="panic=10 panic_on_oops=1 softlockup_panic=1 hardlockup_panic=1 nmi_watchdog=1 watchdog_thresh=5 rcupdate.rcu_cpu_stall_timeout=10 sysctl.kernel.panic_on_rcu_stall=1 hung_task_panic=1 hung_task_timeout_secs=60"
cat > "$W/eve/grub.cfg" <<EOF
set timeout=5
set default=0
insmod regexp
insmod probe
insmod smbios
# The disk this menu was loaded from: \$root is e.g. hd1,gpt12 (GRUB 2.14 prints no parentheses), so gb_disk is hd1. Android's first stage uses the
# disk whose boot_a partition (GPT entry 13) has the UUID passed as androidboot.boot_part_uuid.
regexp --set=1:gb_disk '^[(]?([^,()]+),' "\$root"
probe --set=gb_boot_uuid --part-uuid "(\$gb_disk,gpt13)"
if [ -z "\$gb_boot_uuid" ]; then set gb_boot_uuid=$UUID0; fi
# /data in RAM unless this disk was set up by the internal installer, which writes "set gb_data=disk" here
set gb_data=ram
# result of the last run of the internal installer started from this USB stick
if [ -f /EFI/GBRUNCH/install-result.txt ]; then
 cat /EFI/GBRUNCH/install-result.txt
 echo
 echo 'The menu follows in 15 seconds (any key: now).'
 sleep --interruptible 15
fi
if [ -f /EFI/GBRUNCH/install.cfg ]; then source /EFI/GBRUNCH/install.cfg; fi
# submenus start a new environment that only sees exported variables
export gb_boot_uuid
export gb_data
smbios --type=1 --get-string=4 --set=system_vendor
if [ "\$system_vendor" = "QEMU" ]; then
 serial --unit=0 --speed=115200
 terminal_output console serial
 set default="debug>qemu"
fi
menuentry 'Googlebook OS' {
 echo 'Starting. The screen stays black until Android draws (about a minute).'
 linux /EFI/GBRUNCH/kernel $DEV androidboot.boot_part_uuid=\$gb_boot_uuid androidboot.gbdata=\$gb_data
 initrd /EFI/GBRUNCH/initrd.gz
}
menuentry 'Googlebook OS, safe mode: internal audio off' {
 linux /EFI/GBRUNCH/kernel $DEV androidboot.boot_part_uuid=\$gb_boot_uuid androidboot.gbdata=\$gb_data androidboot.gbaudio=0
 initrd /EFI/GBRUNCH/initrd.gz
}
if [ "\$gb_data" = ram ]; then
menuentry 'Install to the internal eMMC (erases ChromeOS and everything on it)' {
 echo 'This copies Googlebook OS from this USB stick to the Pixelbook internal storage (eMMC).'
 echo 'EVERYTHING on the internal storage is erased, including ChromeOS and its data.'
 echo 'App data then lives on the internal storage and survives restarts.'
 echo
 echo 'The install takes about 10 to 20 minutes and the screen does not change while it runs.'
 echo 'Keep the charger connected. When it is done the Pixelbook turns itself off:'
 echo 'then remove the USB stick and turn it on. If it restarts instead, the next start'
 echo 'of this USB stick shows what went wrong.'
 echo
 echo -n 'Type ERASE and press Enter to start, or press Enter to go back: '
 read gb_answer
 if [ "\$gb_answer" = ERASE ]; then
  echo
  echo 'Installing. Do not turn the Pixelbook off.'
  linux /EFI/GBRUNCH/kernel rdinit=/init androidboot.boot_part_uuid=\$gb_boot_uuid loglevel=3
  initrd /EFI/GBRUNCH/installer.gz
  boot
 fi
}
menuentry 'Update the internal eMMC from this USB stick (keeps apps and data)' {
 echo 'This replaces the system on the internal storage with the one on this USB stick.'
 echo 'Apps, accounts, settings and files on the internal storage are kept.'
 echo 'It only works on an internal install made by this installer (same partition layout).'
 echo
 echo 'It takes about 10 minutes and the screen does not change while it runs.'
 echo 'Keep the charger connected. When it is done the Pixelbook turns itself off.'
 echo
 echo -n 'Type UPDATE and press Enter to start, or press Enter to go back: '
 read gb_answer
 if [ "\$gb_answer" = UPDATE ]; then
  echo
  echo 'Updating. Do not turn the Pixelbook off.'
  linux /EFI/GBRUNCH/kernel rdinit=/init androidboot.boot_part_uuid=\$gb_boot_uuid gb_install=update loglevel=3
  initrd /EFI/GBRUNCH/installer.gz
  boot
 fi
}
fi
submenu 'Debug and test options' --id debug {
 menuentry 'Crash capture (reboots itself after a freeze and keeps the kernel log)' {
  echo 'If it freezes it should reboot within a minute. If not, press Refresh+Power (not a long power press).'
  linux /EFI/GBRUNCH/kernel $DEV androidboot.boot_part_uuid=\$gb_boot_uuid androidboot.gbdata=\$gb_data $CRASH
  initrd /EFI/GBRUNCH/initrd.gz
 }
 menuentry 'Suspend test: allow sleep on lid close, S3 (deep)' {
  echo 'Lid close suspends the machine. If it does not wake up on lid open or a key press,'
  echo 'press Refresh+Power, then copy the logs: the kernel log of the failed resume is kept.'
  linux /EFI/GBRUNCH/kernel $DEV androidboot.boot_part_uuid=\$gb_boot_uuid androidboot.gbdata=\$gb_data androidboot.gbsuspend=1 mem_sleep_default=deep $SUSPENDDBG $CRASH
  initrd /EFI/GBRUNCH/initrd.gz
 }
 menuentry 'Suspend test: allow sleep on lid close, s2idle' {
  echo 'Lid close suspends the machine. If it does not wake up on lid open or a key press,'
  echo 'press Refresh+Power, then copy the logs: the kernel log of the failed resume is kept.'
  linux /EFI/GBRUNCH/kernel $DEV androidboot.boot_part_uuid=\$gb_boot_uuid androidboot.gbdata=\$gb_data androidboot.gbsuspend=1 mem_sleep_default=s2idle $SUSPENDDBG $CRASH
  initrd /EFI/GBRUNCH/initrd.gz
 }
 menuentry 'Serial console and emulation profiling (QEMU)' --id qemu {
  linux /EFI/GBRUNCH/kernel $DEV androidboot.boot_part_uuid=\$gb_boot_uuid androidboot.gbdata=\$gb_data console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200 isa_emu=profile
  initrd /EFI/GBRUNCH/initrd.gz
 }
}
menuentry 'UEFI firmware settings' { fwsetup }
EOF

grub-script-check "$W/eve/grub.cfg" || { echo "grub.cfg has a syntax error"; exit 1; }

# GRUB itself: gbrunch's prebuilt loader finds its menu by a FAT volume serial, which would be ambiguous with the
# USB stick and an internal install connected at once. This core image has the prefix /EFI/GBRUNCH without a device,
# so GRUB fills in the partition it was itself loaded from and reads that partition's grub.cfg: each disk always
# boots its own menu. (A grub-mkstandalone image does not work here: its $cmdpath is empty.) All modules the menu
# uses are built in; nothing is loaded from the EFI partition.
GRUB_MODS="part_gpt part_msdos fat normal configfile echo test regexp probe smbios search search_fs_uuid search_fs_file
	search_label linux efi_gop all_video gfxterm font terminal serial efifwsetup reboot halt ls cat sleep read"
grub-mkimage -O x86_64-efi -p /EFI/GBRUNCH -o "$W/eve/BOOTX64.EFI" $GRUB_MODS

# 5. image: copy of gbrunch's, with the three boot files replaced on the EFI partition
rm -f "$W/eve.raw"
cp --sparse=always "$W/native.raw" "$W/eve.raw.part" && mv "$W/eve.raw.part" "$W/eve.raw"

# 6. board firmware that Google's vendor partition lacks, added to GBVENDOR /firmware
#    (Intel Wireless 7265 = iwlwifi 7265D API 29; its Bluetooth part 8087:0a2a = btintel ibt-hw-37.8 patches)
LF="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"
# entries are <path the kernel requests>|<path in the linux-firmware repository>
VFWSRC="iwlwifi-7265D-29.ucode|intel/iwlwifi/iwlwifi-7265D-29.ucode intel/ibt-hw-37.8.bseq|intel/ibt-hw-37.8.bseq
	intel/ibt-hw-37.8.10-fw-1.10.2.27.d.bseq|intel/ibt-hw-37.8.10-fw-1.10.2.27.d.bseq
	intel/ibt-hw-37.8.10-fw-1.10.3.11.e.bseq|intel/ibt-hw-37.8.10-fw-1.10.3.11.e.bseq
	intel/ibt-hw-37.8.10-fw-22.50.19.14.f.bseq|intel/ibt-hw-37.8.10-fw-22.50.19.14.f.bseq"
ARGS=(); VFW=""
for e in $VFWSRC; do
	f="${e%%|*}"; src="${e#*|}"; VFW="$VFW $f"
	mkdir -p "$(dirname "$W/eve/vfw/$f")"
	[ -s "$W/eve/vfw/$f" ] || curl -sSfL --retry 3 -o "$W/eve/vfw/$f" "$LF/$src"
	ARGS+=("firmware/$f=$W/eve/vfw/$f")
done
(cd "$W/eve/vfw" && sha256sum $VFW) | tee "$W/eve/vendor-firmware.sha256"

# 6b. audio firmware. It comes from the owner's own ChromeOS install (inputs/chromeos, copied off the
#     device; never published): the AVS driver wants intel/avs/skl/dsp_basefw.bin (plus its module libraries) and
#     the *-tplg.bin topologies. ChromeOS keeps some of them as symlinks, which are materialised here.
#     patch_oem.sh copies everything under $W/eve/vfw into /oem/firmware.
AVSSRC="$IN/chromeos/lib/firmware/intel/avs"
if [ -d "$AVSSRC" ]; then
	rm -rf "$W/eve/vfw/intel/avs"; mkdir -p "$W/eve/vfw/intel/avs"
	cp -rL "$AVSSRC/." "$W/eve/vfw/intel/avs/"
	(cd "$W/eve/vfw" && find intel/avs -type f | sort | xargs sha256sum) | tee "$W/eve/avs-firmware.sha256"
else
	echo "NOTE: $AVSSRC missing: the image will have no audio firmware"
fi

# 6c. vendor overlay files: the audio HAL configuration for this board (audio_default.xml is what Google's dras HAL
#     falls back to when no hardware match exists; replacing it plus one new config directory is all it takes).
#     The panel backlight is left to the display composer (HWC), as in Google's own image: the HWC associates
#     intel_backlight with the panel and receives every brightness change. v7-v9 also enabled the lights HAL's
#     backlight (ro.vendor.lights.backlight.enabled=true); with two writers the panel flashed to full brightness
#     on brightness-key presses, so that switch stays at Google's value (false).
CFGLBL="u:object_r:vendor_configs_file:s0"
mkdir -p "$W/eve/vcfg"
extract_vendor() {	# <path in vendor> <output file>, read from the GBVENDOR partition of the image being built
	local off
	off="$(sfdisk -d "$W/eve.raw" | awk -F'[=, ]+' '/name="GBVENDOR"/ {for(i=1;i<=NF;i++) if($i=="start") print $(i+1)*512}')"
	[ -n "$off" ] || { echo "GBVENDOR not found"; return 1; }
	dump.erofs --offset="$off" --cat --path="$1" "$W/eve.raw" > "$2"
}
extract_vendor /etc/audio/sof-rt5682_alc5682ivs_tas2563/volume_curves.xml "$W/eve/vcfg/volume_curves.xml"
ARGS+=("etc/data/hal_configs/audio_default.xml=$HERE/audio/audio_default.xml:$CFGLBL"
	"etc/audio/avs_eve/audio_config.xml=$HERE/audio/avs_eve/audio_config.xml:$CFGLBL"
	"etc/audio/avs_eve/mixer_paths.xml=$HERE/audio/avs_eve/mixer_paths.xml:$CFGLBL"
	"etc/audio/avs_eve/volume_curves.xml=$W/eve/vcfg/volume_curves.xml:$CFGLBL"
	# dras only resolves <audio-config-dir> when it also knows the board model (it does not here: "Both card_name,
	# model should be provided") and then reads these fixed paths instead (seen in usb-dump8: "Failed to read
	# /vendor/etc/audio_config.xml" after finding card avsmax98927). Same files, default location.
	# (v10-v12 shipped a placeholder here while the speaker froze the machine; the AVS driver fix ended that.)
	"etc/audio_config.xml=$HERE/audio/avs_eve/audio_config.xml:$CFGLBL"
	"etc/mixer_paths.xml=$HERE/audio/avs_eve/mixer_paths.xml:$CFGLBL"
	"etc/volume_curves.xml=$W/eve/vcfg/volume_curves.xml:$CFGLBL")

# 6d. input configuration and a baseline zlib.
#  - Keyboard: top row mapped to the functions printed on the keys (generated from the image's own Generic.kl).
#  - Touchpad: gesture settings for the Pixelbook pad (the hover/jump problem itself is fixed in the kernel).
#  - zlib: Google's libz.so was compiled for a newer CPU and its Adler-32 loop uses AVX-VNNI (vpdpwssd), which this
#    CPU emulates at ~300k traps/s while anything inflates or deflates data. The Cuttlefish donor's libz.so is the
#    same zlib for baseline x86-64. It replaces /vendor/lib64/libz.so here and is bind-mounted over
#    /system/lib64/libz.so at boot (see patch_oem.sh; /system itself is verity-protected and stays untouched).
SYSOFF="$(python3 "$IMG/lp_offset.py" "$W/eve.raw" system_a | cut -d' ' -f1)"
dump.erofs --offset="$SYSOFF" --cat --path=/system/usr/keylayout/Generic.kl "$W/eve.raw" > "$W/eve/vcfg/Generic.kl"
python3 "$HERE/input/make_eve_keylayout.py" "$W/eve/vcfg/Generic.kl" "$W/eve/vcfg/AT_Translated_Set_2_keyboard.kl"
ARGS+=("usr/keylayout/AT_Translated_Set_2_keyboard.kl=$W/eve/vcfg/AT_Translated_Set_2_keyboard.kl:u:object_r:vendor_keylayout_file:s0"
	"usr/idc/Vendor_18d1_Product_5028.idc=$HERE/input/Vendor_18d1_Product_5028.idc:u:object_r:vendor_idc_file:s0")

DONOR="${DONOR_SUPER:-$IN/donor/super.raw}"
rm -rf "$W/eve/oemfiles"; mkdir -p "$W/eve/oemfiles/system/lib64" "$W/eve/oemfiles/vendor/etc" "$W/eve/oemfiles/vendor/lib/modules"
# headset and microphone routing on the two cards dras does not configure (audio/pbmixer.c, run once at boot)
mkdir -p "$W/eve/oemfiles/vendor/bin"
gcc -O2 -Wall -static -o "$W/eve/oemfiles/vendor/bin/pbmixer" "$HERE/audio/pbmixer.c"
install -m 0644 "$HERE/audio/pbmixer.conf" "$W/eve/oemfiles/vendor/etc/pbmixer.conf"
# audio safe mode: this placeholder is bind-mounted over the real config with androidboot.gbaudio=0 (patch_oem.sh)
install -m 0644 "$HERE/audio/audio_config.off.xml" "$W/eve/oemfiles/vendor/etc/audio_config.xml"
# Fixed AVS audio DSP driver (array overrun in avs_path_set_constraint crashed the machine when the speaker opened;
# see kernel/apply.sh), built from the patched tree with the same symbol versions as Google's prebuilt and
# bind-mounted over /vendor/lib/modules/snd-soc-avs.ko before ueventd loads it (patch_oem.sh).
DLKMOFF="$(python3 "$IMG/lp_offset.py" "$W/eve.raw" vendor_dlkm_a | cut -d' ' -f1)"
dump.erofs --offset="$DLKMOFF" --cat --path=/lib/modules/snd-soc-avs.ko "$W/eve.raw" > "$W/eve/vcfg/snd-soc-avs.google.ko"
bash "$HERE/kernel/build_avs_module.sh" "$K" "$O" "$W/eve/vcfg/snd-soc-avs.google.ko" "$W/eve/avs-module"
install -m 0644 "$W/eve/avs-module/snd-soc-avs.ko" "$W/eve/oemfiles/vendor/lib/modules/snd-soc-avs.ko"
if [ -f "$DONOR" ]; then
	DOFF="$(python3 "$IMG/lp_offset.py" "$DONOR" system_a | cut -d' ' -f1)"
	dump.erofs --offset="$SYSOFF" --cat --path=/system/lib64/libz.so "$W/eve.raw" > "$W/eve/vcfg/libz.google.so"
	dump.erofs --offset="$DOFF" --cat --path=/system/lib64/libz.so "$DONOR" > "$W/eve/vcfg/libz.baseline.so"
	# gates: same soname, every symbol Google's libz exports, and none of the instructions that need emulation
	[ "$(readelf -d "$W/eve/vcfg/libz.baseline.so" | grep -c 'SONAME.*\[libz.so\]')" = 1 ]
	nm -D --defined-only "$W/eve/vcfg/libz.google.so" | awk '{print $3}' | sort > "$W/eve/vcfg/libz.google.syms"
	nm -D --defined-only "$W/eve/vcfg/libz.baseline.so" | awk '{print $3}' | sort > "$W/eve/vcfg/libz.baseline.syms"
	[ -z "$(comm -23 "$W/eve/vcfg/libz.google.syms" "$W/eve/vcfg/libz.baseline.syms")" ] || { echo "donor libz lacks symbols"; exit 1; }
	[ "$(objdump -d "$W/eve/vcfg/libz.baseline.so" | grep -cE 'vpdp|gf2p8|vaes|vpclmulqdq.*ymm|sha1|sha256')" = 0 ] || { echo "donor libz needs emulated instructions"; exit 1; }
	ARGS+=("lib64/libz.so=$W/eve/vcfg/libz.baseline.so:u:object_r:same_process_hal_file:s0")
	install -m 0644 "$W/eve/vcfg/libz.baseline.so" "$W/eve/oemfiles/system/lib64/libz.so"
	sha256sum "$W/eve/vcfg/libz.google.so" "$W/eve/vcfg/libz.baseline.so" | tee "$W/eve/libz.sha256"
else
	echo "NOTE: donor image $DONOR not found: libz stays Google's (about 300k emulation traps/s whenever data is compressed)"
fi
# 6e. SELinux: add exactly the rules in policy/rules.txt (libz bind mount, read-only backlight diagnostics) to the vendor's precompiled policy, which already carries gbrunch's additions.
TOOL="$W/eve/extend-vendor-policy"
[ -x "$TOOL" ] || bash "$HERE/policy/build_policy_tool.sh" "$TOOL" "$IN/gbrunch"
extract_vendor /etc/selinux/precompiled_sepolicy "$W/eve/vcfg/precompiled_sepolicy.in"
RULES=()
while read -r s t c p _; do
	case "$s" in ''|'#'*) continue ;; esac
	RULES+=("$s" "$t" "$c" "$p")
done < "$HERE/policy/rules.txt"
"$TOOL" "$W/eve/vcfg/precompiled_sepolicy.in" "$W/eve/vcfg/precompiled_sepolicy" "${RULES[@]}" | tee "$W/eve/policy-changes.txt"
ARGS+=("etc/selinux/precompiled_sepolicy=$W/eve/vcfg/precompiled_sepolicy:u:object_r:vendor_configs_file:s0")
python3 "$IMG/vendor_overlay.py" "$W/eve.raw" "$W/eve/vendor" "${ARGS[@]}"

# 7. a roomy /data. Google's userdata is 4.1 GiB and the first boot copies a ~3.7 GB AICore model into it.
python3 "$IMG/grow_userdata.py" "$W/eve.raw" --gib "${USERDATA_GIB:-8}"

# 8. no AICore model copy on first boot; /data in RAM (EVE_DATA=ram, default) or on the ext4 partition (EVE_DATA=disk)
EVE_FW_DIR="$W/eve/vfw" EVE_OVERLAY_DIR="$W/eve/oemfiles" bash "$IMG/patch_oem.sh" "$W/eve.raw" "${EVE_DATA:-ram}"
OFF="$(python3 - "$W/eve.raw" "$W/kit/assets" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from inspect_recovery import gpt
with open(sys.argv[1], "rb") as f:
    print(next(p["offset"] for p in gpt(f) if p["type_guid"] == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"))
PY
)"
mcopy -o -i "$W/eve.raw@@$OFF" "$O/arch/x86/boot/bzImage" ::/EFI/GBRUNCH/kernel
mcopy -o -i "$W/eve.raw@@$OFF" "$W/eve-initrd.gz" ::/EFI/GBRUNCH/initrd.gz
mcopy -o -i "$W/eve.raw@@$OFF" "$W/eve/grub.cfg" ::/EFI/GBRUNCH/grub.cfg
mcopy -o -i "$W/eve.raw@@$OFF" "$W/eve/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -o -i "$W/eve.raw@@$OFF" "$W/eve/installer.gz" ::/EFI/GBRUNCH/installer.gz
# Pristine copies of the two runtime partitions that are not all zeros (an empty ext4 /metadata and an empty FAT log
# partition, ~100 KB compressed), taken from the freshly assembled image: the installer (install/install_to_disk.sh)
# writes these instead of whatever state a used USB stick has accumulated.
mkdir -p "$W/eve/pristine"
for p in metadata GBLOG; do
	read -r ps pz < <(sfdisk -d "$W/native.raw" | sed -nE "s/.*start= *([0-9]+), size= *([0-9]+),.*name=\"$p\".*/\1 \2/p")
	dd if="$W/native.raw" bs=512 skip="$ps" count="$pz" status=none | gzip -9n > "$W/eve/pristine/$p.img.gz"
done
mmd -D s -i "$W/eve.raw@@$OFF" ::/EFI/GBRUNCH/pristine 2>/dev/null || true
mcopy -o -i "$W/eve.raw@@$OFF" "$W/eve/pristine/metadata.img.gz" "$W/eve/pristine/GBLOG.img.gz" ::/EFI/GBRUNCH/pristine/
ls -la "$W/eve/pristine"
mdir -i "$W/eve.raw@@$OFF" ::/EFI/GBRUNCH | sed -n 4,12p
ls -la "$W/eve.raw"
sha256sum "$O/arch/x86/boot/bzImage" "$W/eve-initrd.gz" | sed "s#$W/##; s#$O/##" | tee "$W/eve/boot-files.sha256"
