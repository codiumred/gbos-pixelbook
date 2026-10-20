#!/bin/bash
# Adjust gbrunch's compatibility partition (GBRUNCH, mounted as /oem) inside an assembled image:
#   1. Do not import Google's cppreopts.rc. It would copy a 3.7 GB AICore model from system_b into /data on
#      first boot (preloads_copy.sh). The replacement block below keeps the useful part (copying pre-optimised
#      app code) and drops the model copy.
#   2. EVE_DATA=ram  (default) mount /data as a 4 GiB tmpfs instead of the ext4 userdata partition. The USB
#      stick used for development does ~1 random 4 KiB write per second, which is far too slow for Android's
#      /data; with RAM there, everything else can be exercised. Nothing in /data survives a reboot.
#      EVE_DATA=disk keeps the ext4 userdata (use with a fast drive or the internal storage).
# Needs root (loop mount). Edits files in place so their SELinux labels are kept.
#   image/patch_oem.sh <image.raw> [ram|disk]
set -euo pipefail
IMG="${1:?image}"; MODE="${2:-${EVE_DATA:-ram}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFF_SIZE="$(python3 - "$IMG" "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
import vendor_overlay as v
with open(sys.argv[1], "rb") as f:
    mbr, hdr, t, tl, c, es = v.read_gpt(f)
    for i, n, a, b in v.entries(t, c, es):
        if n == "GBRUNCH":
            print(a * 512, (b - a + 1) * 512)
PY
)"
set -- $OFF_SIZE "$IMG" "$MODE"
OFF="$1"; SIZE="$2"; IMG="$3"; MODE="$4"
M="$(mktemp -d)"
cleanup() { umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true; }
trap cleanup EXIT
mount -o loop,offset="$OFF",sizelimit="$SIZE" "$IMG" "$M"

python3 - "$M" "$MODE" <<'PY'
import os, pathlib, re, sys
oem, mode = pathlib.Path(sys.argv[1]), sys.argv[2]

def rewrite(path, fn):
    p = oem / path
    old = p.read_text()
    new = fn(old)
    if new != old:
        with open(p, "r+") as f:          # same inode: keeps owner, mode and SELinux label
            f.seek(0); f.write(new); f.truncate()
        print("patched", path)
    else:
        print("unchanged", path)

CPP = """
# --- gbrunch/pixelbook: Google's cppreopts.rc without the AICore model copy (see image/patch_oem.sh) ---
service cppreopts /system/bin/cppreopts.sh /postinstall
    oneshot
    disabled
    user root
    priority -20
    ioprio rt 0
    task_profiles ProcessCapacityHigh
    capabilities

on property:sys.cppreopt=requested && property:ro.postinstall.fstab.prefix=/system
    mount_all /system/etc/fstab.postinstall
    exec_start cppreopts
    umount_all /system/etc/fstab.postinstall
    setprop sys.cppreopt finished

on property:sys.cppreopt=requested && property:ro.postinstall.fstab.prefix=/product
    mount_all /product/etc/fstab.postinstall
    exec_start cppreopts
    umount_all /product/etc/fstab.postinstall
    setprop sys.cppreopt finished
"""

ZRAM = """
# --- pixelbook: zram swap. Google's mmd_setup (started at boot_completed) builds the swap device from
# /vendor/etc/fstab.zram, but zram.ko and zsmalloc.ko live in system_dlkm and nothing loads them here, so the
# first image had no swap at all (8 GB RAM, 4 GiB of it a tmpfs /data). ---
on post-fs-data
    insmod /system/lib/modules/zsmalloc.ko
    insmod /system/lib/modules/zram.ko
"""

HEAP = """
# --- pixelbook: DMA-BUF system heap. Google lists system_heap.ko in vendor_dlkm's modules.load, but on this image
# modules are loaded by ueventd on hardware aliases and this one has none, so /dev/dma_heap never appeared and the
# camera HAL failed every capture with V4L2Device(BufferAllocation) (the webcam itself allocates buffers fine). ---
on init
    insmod /vendor/lib/modules/system_heap.ko

# again in case /vendor/lib/modules was not reachable yet (a second load just fails with "File exists")
on post-fs-data
    insmod /vendor/lib/modules/system_heap.ko
"""

BACKLIGHT = """
# --- pixelbook: the sysfs backlight is root-only by default, but Android's lights HAL and the HWC run as
# "system" and just want to write brightness. In the first run the slider reached the HAL ("scaled brightness
# 52") and nothing happened. The node exists once i915 has bound the panel (first stage), so boot is late enough;
# boot_completed repeats it in case the panel was probed late. ---
on boot
    chown system system /sys/class/backlight/intel_backlight/brightness
    chmod 0664 /sys/class/backlight/intel_backlight/brightness

on property:sys.boot_completed=1
    chown system system /sys/class/backlight/intel_backlight/brightness
    chmod 0664 /sys/class/backlight/intel_backlight/brightness
"""

LIBZ = """
# --- pixelbook: Google's libz.so uses AVX-VNNI in its Adler-32 loop, which this CPU can only emulate (about
# 300k traps/s while data is (de)compressed). A baseline build of the same zlib (from the Cuttlefish donor,
# same exported symbols; checked at build time) is bind-mounted over the system copy, which stays untouched
# and verity-protected. If the file is missing the mount simply fails and Google's libz is used. ---
on init
    mount none /oem/overlay/system/lib64/libz.so /system/lib64/libz.so bind
"""

AVSMOD = """
# --- pixelbook: fixed AVS audio DSP driver. Google's snd-soc-avs.ko overruns an array in avs_path_set_constraint()
# with the Pixelbook speaker topology; its UBSAN trap killed the audio HAL thread inside the PCM open and the machine
# froze (usb-dump11-audio). The rebuilt module (same source plus the fix, same symbol versions) is bind-mounted over
# Google's file here, before init.rc starts ueventd, which loads it by alias a second later. If the file is missing
# the mount fails and Google's module is used. ---
on early-init
    mount none /oem/overlay/vendor/lib/modules/snd-soc-avs.ko /vendor/lib/modules/snd-soc-avs.ko bind
"""

AUDIO = """
# --- pixelbook: audio safe mode. /vendor/etc/audio_config.xml is the Pixelbook's audio configuration. Booting with
# androidboot.gbaudio=0 (GRUB's "safe mode" entry) bind-mounts a placeholder over it: Google's dras HAL then starts
# its stub module and leaves the sound cards alone. A way back if a driver or firmware change breaks audio again
# (v10-v11 froze the machine whenever the speaker opened, see kernel/apply.sh). ---
on init && property:ro.boot.gbaudio=0
    mount none /oem/overlay/vendor/etc/audio_config.xml /vendor/etc/audio_config.xml bind
"""

DATAMODE = """# --- pixelbook: where /data lives. fstab.android-desktop puts /data in RAM (tmpfs, the default: a USB stick is far
# too slow for Android's small writes). Booting with androidboot.gbdata=disk, which the internal-disk installer sets
# in the EFI partition's install.cfg, mounts fstab.android-desktop.disk over it instead: /data is then the ext4
# userdata partition and survives reboots. This block must stay ahead of gbrunch's early-init action, which binds
# the fstab into /vendor/etc; actions with the same trigger run in file order. ---
on early-init && property:ro.boot.gbdata=disk
    mount none /oem/fstab.android-desktop.disk /oem/fstab.android-desktop bind

"""

NOSUSPEND = """
# --- pixelbook: no system suspend for now. Closing the lid let Android suspend the machine (S3), which never
# resumed on this kernel/firmware (usb-dump8 ends at "automatic system suspend enabled"; only a forced power-off
# recovered). A kernel wake lock keeps the system running: the screen still turns off on lid close and comes back
# on lid open or a key press, at the cost of battery while the lid is closed. Remove once resume works. ---
on boot
    write /sys/power/wake_lock pixelbook_no_suspend
"""

PBMIXER = """
# --- pixelbook: headset and microphone routing. Google's dras HAL applies mixer paths only to the primary (speaker)
# card; the headset codec (avsrt5663) and the internal microphones (avsrt5514) are separate cards whose routing
# switches start off. pbmixer (audio/pbmixer.c) sets them once, to ChromeOS's values (audio/pbmixer.conf). It runs in
# the audio HAL's SELinux domain and group, which may open the sound devices, and logs to the kernel log. ---
service pbmixer /oem/overlay/vendor/bin/pbmixer /oem/overlay/vendor/etc/pbmixer.conf
    user audioserver
    group audio
    seclabel u:r:hal_audio_default:s0
    stdio_to_kmsg
    oneshot
    disabled

on property:init.svc.vendor.audio-hal-aidl=running
    start pbmixer
"""

SUSPENDTEST = """
# --- pixelbook: suspend test. androidboot.gbsuspend=1 (GRUB's suspend-test entries) releases the keep-awake lock
# taken above, so closing the lid suspends the machine again. Those entries also choose the sleep state
# (mem_sleep_default=deep or s2idle) and keep the console alive through suspend, so a failed resume leaves its kernel
# log in ramoops for the next boot's logs. ---
on boot && property:ro.boot.gbsuspend=1
    write /sys/power/wake_unlock pixelbook_no_suspend
"""

LEGACYCAM = """
# --- pixelbook: Google's legacy camera provider finds no camera HAL module on this hardware and exits; init then
# restarts it every 5 seconds forever (seen live over adb). The Pixelbook camera is a USB camera served by the
# USB provider, so stop the legacy one once it is caught in that loop. ---
on property:init.svc.vendor.camera-provider-2-7-legacy-wrapper=restarting
    stop vendor.camera-provider-2-7-legacy-wrapper
"""

def rc(text):
    lines = [l for l in text.split("\n") if l.strip() != "import /system/etc/init/cppreopts.rc"]
    text = "\n".join(lines)
    if "Google's cppreopts.rc without the AICore model copy" not in text:
        text = text.rstrip("\n") + "\n" + CPP
    if "pixelbook: zram swap" not in text:
        text = text.rstrip("\n") + "\n" + ZRAM
    if "pixelbook: DMA-BUF system heap" not in text:
        text = text.rstrip("\n") + "\n" + HEAP
    if "pixelbook: the sysfs backlight" not in text:
        text = text.rstrip("\n") + "\n" + BACKLIGHT
    if os.environ.get("EVE_SUSPEND", "off") != "on" and "pixelbook: no system suspend" not in text:
        text = text.rstrip("\n") + "\n" + NOSUSPEND
    if ovl and os.path.isfile(os.path.join(ovl, "vendor/bin/pbmixer")) and "pixelbook: headset and microphone routing" not in text:
        text = text.rstrip("\n") + "\n" + PBMIXER
    if "pixelbook: no system suspend" in text and "pixelbook: suspend test" not in text:
        text = text.rstrip("\n") + "\n" + SUSPENDTEST      # after NOSUSPEND: same trigger, runs later
    if "pixelbook: Google's legacy camera provider" not in text:
        text = text.rstrip("\n") + "\n" + LEGACYCAM
    ovl = os.environ.get("EVE_OVERLAY_DIR", "")
    if ovl and os.path.isfile(os.path.join(ovl, "system/lib64/libz.so")) and "pixelbook: Google's libz.so" not in text:
        text = text.rstrip("\n") + "\n" + LIBZ
    if ovl and os.path.isfile(os.path.join(ovl, "vendor/lib/modules/snd-soc-avs.ko")) and "pixelbook: fixed AVS audio DSP driver" not in text:
        text = text.rstrip("\n") + "\n" + AVSMOD
    if ovl and os.path.isfile(os.path.join(ovl, "vendor/etc/audio_config.xml")) and "pixelbook: audio safe mode" not in text:
        text = text.rstrip("\n") + "\n" + AUDIO
    if "pixelbook: where /data lives" not in text:
        first = text.index("\non early-init\n") + 1     # gbrunch's own early-init action
        text = text[:first] + DATAMODE + text[first:]
    # the logger must be able to read /dev/input/event* (group input) for the touchpad and function-key traces
    stanza = re.search(r"service gbrunch\.persistlogs .*?\n\n", text, re.S)
    if stanza and "readproc input" not in stanza.group(0):
        new = stanza.group(0).replace("group shell system log readproc", "group shell system log readproc input", 1)
        text = text.replace(stanza.group(0), new, 1)
    return text

rewrite("init.gbrunch.rc", rc)

TMPFS = "tmpfs /data tmpfs rw,nodev,noatime,nosuid,mode=0771,size=4g latemount"

def fstab(text):
    out = []
    for l in text.split("\n"):
        if l.startswith("tmpfs /data "):
            continue                       # idempotent
        if mode == "ram" and l.startswith("/dev/block/by-name/userdata /data "):
            out.append(TMPFS)              # the first entry that mounts wins
        out.append(l)
    return "\n".join(out)

rewrite("fstab.android-desktop", fstab)

# the disk variant: gbrunch's fstab as it was (ext4 userdata for /data), selected at boot by androidboot.gbdata=disk
disk = oem / "fstab.android-desktop.disk"
src = (oem / "fstab.android-desktop").read_text()
disk.write_text("\n".join(l for l in src.split("\n") if not l.startswith("tmpfs /data ")))
os.chmod(disk, 0o644)
os.chown(disk, 0, 0)
os.setxattr(disk, "security.selinux", b"u:object_r:vendor_configs_file:s0")
print("wrote fstab.android-desktop.disk")
PY
# 3a. a more useful logger: bigger budget (the 24 MiB default stopped the snapshots after ~10), more snapshots,
#     bigger logcat ring (an error flood overwrote the first failure), plus input, emulation and ANR state.
python3 - "$M" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "gbrunch-logger.sh"
t = p.read_text()
if "PIXELBOOK_LOGGER_EXTRAS" not in t:
    # 224 MiB of the 256 MiB log partition; a 12 x 8 MiB logcat ring holds about an hour (the first run's
    # 8 x 4 MiB lasted 25 minutes and lost the start of every session, where the setup wizard runs).
    t = t.replace("budget_kib=24576", "budget_kib=229376")
    t = t.replace('-f "$run/live-logcat.txt" -r 1024 -n 3 &', '-f "$run/live-logcat.txt" -r 8192 -n 12 &')
    t = t.replace("rotation=3x1024KiB", "rotation=12x8192KiB")
    t = t.replace("for n in 01 02 03 04 05 06 07 08 09 10; do", "for n in " + " ".join("%02d" % i for i in range(1, 61)) + "; do")
    t = t.replace('[ "$n" = 10 ]', '[ "$n" = 60 ]').replace('"$n" = 10 ]', '"$n" = 60 ]')
    t = t.replace("    sleep 20\n", "    sleep 30\n")
    # The big dumps (dumpsys activity 0.65 MB, wifi 0.35 MB, kernel-errors 0.2 MB per snapshot) used 30% of the
    # last run's budget; every fifth snapshot is enough for them.
    for old in ('    capture "$n-wifi.txt" dumpsys -t 5 wifi', '    capture "$n-kernel-errors.txt"'):
        assert old in t, old
        t = t.replace(old, '    [ "$heavy" = 1 ] && ' + old.lstrip(), 1)
    # The stock script runs under "ulimit -f 8192" (512-byte blocks = 4 MiB). A 4096 KiB logcat rotation file hits
    # exactly that, so logcat was killed at its first rotation (SIGXFSZ) and everything after the first 84 s of
    # boot, including the ANR, was lost. The log partition is 256 MiB; the budget check below is the real limit.
    t = t.replace("ulimit -f 8192", "ulimit -f 4194304")
    extra = """    # PIXELBOOK_LOGGER_EXTRAS
    # /proc/isa_emu is unreadable for the shell domain under SELinux; with isa_emu=profile the kernel prints the
    # counters and the hottest sites to the kernel log every 10 s instead.
    capture "$n-isa-emu.txt" sh -c 'dmesg | grep "isa_emu:" | tail -n 120'
    capture "$n-kernel-tail.txt" sh -c 'dmesg | tail -c 150000'
    capture "$n-dumpsys-input.txt" dumpsys -t 5 input
    capture "$n-anr.txt" sh -c 'for f in /data/anr/*; do [ -f "$f" ] && { echo "== $f"; head -c 80000 "$f"; }; done'
    capture "$n-swap.txt" sh -c 'cat /proc/swaps; df -k /data; getprop | grep -E "mmd|zram|ram_based"; grep -E "^(Shmem|SwapTotal|SwapFree|MemAvailable):" /proc/meminfo'
    capture "$n-cpufreq.txt" sh -c 'for c in /sys/devices/system/cpu/cpu[0-3]; do echo "$c $(cat $c/cpufreq/scaling_governor) cur=$(cat $c/cpufreq/scaling_cur_freq) max=$(cat $c/cpufreq/scaling_max_freq)"; done; for z in /sys/class/thermal/thermal_zone*; do echo "$z $(cat $z/type) $(cat $z/temp)"; done'
    if [ "$n" = 02 ] || [ "$n" = 10 ] || [ "$n" = 30 ]; then
        capture "$n-audio-log.txt" sh -c 'logcat -b all -d -v threadtime | grep -E " dras |AudioFlinger|audioserver|AudioPolicy|AlsaCard|tinyalsa" | tail -n 400'
        capture "$n-sound.txt" sh -c 'ls -l /dev/snd; cat /proc/asound/cards /proc/asound/pcm; dmesg | grep -iE "avs|snd_|asoc|rt5663|rt5514|max98927|hdaudio" | tail -n 120'
    fi
    if [ "$n" = 02 ] || [ "$n" = 22 ]; then
        capture "$n-features.txt" sh -c 'pm list features; dumpsys -t 5 bluetooth_manager | head -c 40000; dumpsys -t 5 wifip2p | head -c 20000'
    fi
    if [ "$n" = 02 ]; then
        capture "$n-input-devices.txt" sh -c 'cat /proc/bus/input/devices; getevent -lp'
        capture "$n-audio.txt" sh -c 'dumpsys -t 5 media.audio_policy | head -c 60000'
    fi
"""
    t = t.replace('    for service in activity window display power SurfaceFlinger; do', extra + '    for service in activity window display power SurfaceFlinger; do', 1)
    t = t.replace('    for service in activity window display power SurfaceFlinger; do', '    for service in $heavy_services; do', 1)
    # Raw input traces, started once before the snapshot loop. Touchpad: every event (finger positions only).
    # Keyboard: only keys that are not letters, digits, punctuation, space, enter, shift/ctrl/alt or keypad, so a
    # typed password never reaches the log; this is for finding what the function row sends.
    trace = """# PIXELBOOK_INPUT_TRACE
tp=$(getevent -p 2>/dev/null | awk '/^add device/ {d=$4} /name:.*18D1:5028/ {print d; exit}')
if [ -n "$tp" ]; then
    ( getevent -lt "$tp" | head -c 12000000 > "$run/touchpad-events.txt" ) &
    echo "TOUCHPAD_TRACE $tp" >> "$status"
else
    echo "TOUCHPAD_TRACE none" >> "$status"
fi
kb=$(getevent -p 2>/dev/null | awk '/^add device/ {d=$4} /name:.*AT Translated/ {print d; exit}')
if [ -n "$kb" ]; then
    ( getevent -lt "$kb" | while read -r l; do
        case "$l" in
            *EV_KEY*" KEY_"[A-Z0-9]" "*|*" KEY_SPACE "*|*" KEY_ENTER "*|*" KEY_BACKSPACE "*|*" KEY_TAB "*) ;;
            *" KEY_MINUS "*|*" KEY_EQUAL "*|*" KEY_LEFTBRACE "*|*" KEY_RIGHTBRACE "*|*" KEY_SEMICOLON "*) ;;
            *" KEY_APOSTROPHE "*|*" KEY_GRAVE "*|*" KEY_BACKSLASH "*|*" KEY_COMMA "*|*" KEY_DOT "*|*" KEY_SLASH "*) ;;
            *" KEY_LEFTSHIFT "*|*" KEY_RIGHTSHIFT "*|*" KEY_LEFTCTRL "*|*" KEY_RIGHTCTRL "*|*" KEY_LEFTALT "*) ;;
            *" KEY_RIGHTALT "*|*" KEY_CAPSLOCK "*|*" KEY_KP"*|*" KEY_102ND "*) ;;
            *EV_KEY*) echo "$l" >> "$run/function-keys.txt" ;;
        esac
    done ) &
    echo "KEYBOARD_TRACE $kb (function keys only)" >> "$status"
fi
# PIXELBOOK_PSTORE: Google's chromeos_pstore keeps the kernel console in RAM (ramoops); after a panic and warm
# reboot the previous boot's last kernel messages are here (needs the shell pstorefs rule in policy/rules.txt).
for f in /sys/fs/pstore/*; do
    [ -f "$f" ] && cp "$f" "$run/pstore-${f##*/}.txt" && echo "PSTORE ${f##*/}" >> "$status"
done
"""
    loop = "for n in " + " ".join("%02d" % i for i in range(1, 61)) + "; do"
    assert loop in t, "snapshot loop not found"
    heavy = """
    case "$n" in
        02|07|12|17|22|27|32|37|42|47|52|57) heavy=1; heavy_services="activity window display power SurfaceFlinger" ;;
        *) heavy=0; heavy_services="" ;;
    esac"""
    t = t.replace(loop, trace + loop + heavy, 1)
    p.write_text(t)
    print("logger patched")
else:
    print("logger already patched")
PY
# 3. board firmware. gbrunch's init.gbrunch.rc points firmware_class.path at /oem/firmware at early-init, which
#    overrides the kernel command line, so anything the kernel must load later has to live there, not in /vendor.
if [ -n "${EVE_FW_DIR:-}" ] && [ -d "$EVE_FW_DIR" ]; then
	(cd "$EVE_FW_DIR" && find . -type f | sort) | while read -r f; do
		f="${f#./}"
		mkdir -p "$M/firmware/$(dirname "$f")"
		install -m 0644 -o 0 -g 0 "$EVE_FW_DIR/$f" "$M/firmware/$f"
		setfattr -n security.selinux -v "u:object_r:vendor_firmware_file:s0" "$M/firmware/$f"
		d="$(dirname "$f")"
		while [ "$d" != "." ] && [ "$d" != "/" ]; do	# every directory on the way, e.g. intel/avs/skl
			setfattr -n security.selinux -v "u:object_r:vendor_firmware_file:s0" "$M/firmware/$d"
			d="$(dirname "$d")"
		done
		echo "firmware /oem/firmware/$f"
	done
fi
# 4. files that are bind-mounted over read-only system files at boot (see LIBZ in the rc patch above). The label
#    of the file is what processes see after the mount, so it has to be the one of the file it replaces.
if [ -n "${EVE_OVERLAY_DIR:-}" ] && [ -d "$EVE_OVERLAY_DIR" ]; then
	(cd "$EVE_OVERLAY_DIR" && find . -type f | sort) | while read -r f; do
		f="${f#./}"
		mkdir -p "$M/overlay/$(dirname "$f")"
		case "$f" in vendor/bin/*) mode=0755 ;; *) mode=0644 ;; esac
		install -m $mode -o 0 -g 0 "$EVE_OVERLAY_DIR/$f" "$M/overlay/$f"
		case "$f" in
			system/lib64/*.so) lbl="u:object_r:system_lib_file:s0" ;;
			vendor/etc/*.xml|vendor/etc/*.conf) lbl="u:object_r:vendor_configs_file:s0" ;;
			vendor/bin/pbmixer) lbl="u:object_r:hal_audio_default_exec:s0" ;;	# runs in the audio HAL's domain
			vendor/lib/modules/*.ko) lbl="u:object_r:vendor_kernel_modules:s0" ;;
			*) echo "no label rule for overlay file $f"; exit 1 ;;
		esac
		setfattr -n security.selinux -v "$lbl" "$M/overlay/$f"
		d="$(dirname "$f")"
		setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$M/overlay"
		while [ "$d" != "." ] && [ "$d" != "/" ]; do
			setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$M/overlay/$d"
			d="$(dirname "$d")"
		done
		echo "overlay /oem/overlay/$f ($lbl)"
	done
fi
grep -n "cppreopt" "$M/init.gbrunch.rc" | head -5
grep -n "/data " "$M/fstab.android-desktop"
sync
