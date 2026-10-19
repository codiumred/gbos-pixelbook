# Component reference

Experimental. Goal: run Googlebook OS on a 2017 Pixelbook (i5-7Y57), whose CPU lacks instructions the
OS userland uses unconditionally. Status and evidence are tracked in
`docs/engineering-notes.md`; this file only describes what the code here does.

No Google images or binaries are stored here. Inputs (recovery image, donor, kernel tree) come from `scripts/fetch_inputs.sh`
and live outside the repository.

## `isa_emu/`: instruction emulation

| File | Purpose |
|---|---|
| `isa_emu/isa_emu_core.h` | Freestanding decoder + arithmetic for GFNI, AVX-VNNI, AVX-IFMA, VAES, VPCLMULQDQ (VEX) and SHA-NI / GFNI (legacy SSE). 64-bit mode only. Shared verbatim by the kernel and the tester. |
| `isa_emu/test/difftest.c` | Differential tester. On a CPU that has the instructions it compares the core with native execution over random operands, registers, addressing modes and prefixes, then fuzzes mutated encodings to prove the decoder never accepts something the CPU rejects. As `/init` in a guest it compares the kernel emulator with the core and checks memory-operand fault behaviour. |
| `isa_emu/test/run_guest.sh` | Boots a patched kernel under QEMU TCG (`-cpu Skylake-Client`) with `difftest` as PID 1. |
| `isa_emu/isa_emu_fastpath.h`, `isa_emu_fastpath_table.h` | Whole-function fast paths. On CPUs without SHA-NI almost every trap comes from two BoringSSL functions: the SHA-256 block function (about 56 traps per 64-byte block, dominant during boot) and the SHA-NI path of the SHA-1 block function (80 traps per block, 90% of all traps once the system runs). The kernel recognises those functions by a hash of their bytes and hashes the whole call natively. The table holds offsets, 8 opcode bytes and a hash per variant, no code. |
| `isa_emu/gen_fastpath.py` | Finds both functions in a recovery image (only variants with the exact loop structure the kernel relies on) and regenerates the table; `--dump-dir` also dumps the raw functions for `fptest` (local use only). |
| `isa_emu/test/fptest.c`, `run_guest_fp.sh` | Calls the real function with random inputs and fault cases and compares with a C reference: natively as the oracle, then in a guest with the fast path on and off. |

```sh
make -C isa_emu/test test                      # host: needs GFNI/AVX-VNNI/VAES/VPCLMULQDQ/SHA
isa_emu/test/run_guest.sh <bzImage> <kernel out dir> guest.log
```

Limits, by design: no EVEX (AVX-512) forms, no AVX-VNNI-INT8/INT16, no AMX. AVX-IFMA is checked
against an independent reference only, because the development host cannot execute it. AES rounds are
table-based C, so they are not constant-time.

## `kernel/`: kernel changes

| File | Purpose |
|---|---|
| `kernel/isa_emu.c` | `arch/x86/kernel/isa_emu.c`: user-mode `#UD` hook (same shape as UMIP emulation). Reads the instruction, faults in the memory operand like a normal access, updates the live YMM register under `fpregs_lock()`, advances RIP. Boot parameter `isa_emu=off\|on\|profile`; counters in `/proc/isa_emu`, per-site profile in `/proc/isa_emu_sites` and the kernel log. |
| `kernel/apply.sh` | Applies the changes to AOSP `kernel/common` at tag `android17-6.18-2026-06_r52` (commit `3938c8d97142`, the source of the shipped `6.18.21-android17-5` kernel). Also relaxes the GKI protected-symbol checks so Google's prebuilt modules, whose signing key a rebuilt kernel cannot verify, still load. |
| `kernel/build.sh` | Builds with the shipped config, the shipped release string and stable gendwarfksyms CRCs (method from fukayatti/gbos-x86-port). `CONFIG_FRAGMENTS` merges extra driver options. |
| `kernel/config_diff.py` | Prints config options that differ from the shipped config. |
| `kernel/build_avs_module.sh` | Rebuilds Google's `snd-soc-avs.ko` (Intel AVS audio DSP driver) from the patched tree with the fix for the array overrun that froze the machine when the speaker opened; refuses a module whose imports, parameters or functions differ from Google's. |
| `kernel/pixelbook-kernel.patch` | The complete kernel diff produced by `apply.sh`, for review. `apply.sh` is what the build uses. |
| `kernel/eve.config` | Extra kernel options for this board (i915 as a module). |

```sh
kernel/apply.sh ~/gb/kernel/common
kernel/build.sh ~/gb/kernel/common ~/gb/kernel/out ~/gb/ruby/shipped.config
```

## Boot tests and image assembly

| File | Purpose |
|---|---|
| `qemu/qemu_ruby_boot.py` | Boots Google's unmodified `ruby` ramdisk and partitions with a chosen kernel on a Kaby Lake-class CPU model (Windows host QEMU, snapshot disk). With the stock kernel PID 1 dies on the first GFNI instruction; with the patched kernel it runs until the hardware key store is needed. |
| `gbrunch_assemble.sh` | Runs gbrunch's own V7 assembler and asset kit (compatibility partition, derived vendor, software KeyMint) in Linux/WSL and extracts the initrd and kernel command line it generates. |
| `qemu/qemu_gbrunch_boot.sh` | Boots that image with a chosen kernel under QEMU TCG. Reaches zygote and SurfaceFlinger; stops there because the VM has no GPU the Android graphics stack supports. |
| `kernel/eve.config` | Config fragment for the Pixelbook: `CONFIG_DRM_I915=m`. Every other driver the board needs is already in Google's vendor module set. |
| `build_eve_image.sh` | Pixelbook image: gbrunch's image with the rebuilt kernel, `i915` and Kaby Lake GPU firmware in the initrd, and an ungated GRUB entry. Writes a regular file only. |
| `qemu/qemu_eve_uefi_boot.sh` | Boots that image the way the device would (UEFI firmware, GRUB, USB storage) on a Kaby Lake-class CPU model. |
| `audio/` | Audio HAL configuration for the Pixelbook's three AVS cards (`audio_default.xml` replaces Google's fallback, `avs_eve/` is the config directory); applied by `build_eve_image.sh` through `vendor_overlay.py`. |
| `patch_oem.sh` | Edits the OEM partition of an assembled image: no AICore copy, `/data` in RAM, board firmware (including `intel/avs/*` from the owner's own ChromeOS copy), zram module load, and the improved logger (touchpad and function-key traces, emulation profile, swap/backlight/sound captures). |
| `vendor_overlay.py` | Adds or replaces files in the derived vendor partition (creates missing directories, keeps SELinux labels). |
| `policy/rules.txt`, `policy/build_policy_tool.sh` | The extra SELinux allow rules (one so far) added to the vendor's precompiled policy, and the build of the tool that adds them (libsepol 3.11, checksum-pinned). |
| `windows/update_usb.ps1` | Updates the USB stick in place: writes only the partitions that differ from the image flashed last time (plus the ones Android writes at runtime) instead of all 28.7 GB, and verifies them; `-PlanOnly` compares two images. |
| `windows/dump_usb_logs.ps1` | Copies the log partitions off the stick (read-only). |

Typical order (inside WSL; `~/gb` is the work area):

```sh
kernel/apply.sh ~/gb/kernel/common
image/gbrunch_assemble.sh "$PWD" ~/gb/gbrunch
image/build_eve_image.sh "$PWD" ~/gb/gbrunch ~/gb/kernel/common ~/gb/kernel/out-eve ~/gb/ruby/shipped.config
qemu/qemu_eve_uefi_boot.sh ~/gb/gbrunch eve-uefi.log
```

Nothing here has run on a real Pixelbook yet. QEMU has no Intel GPU, so `i915`, its firmware and the
Android graphics stack on this GPU generation are untested.

## Prior art

The trap-and-emulate idea and the kernel build recipe come from
[fukayatti/gbos-x86-port](https://github.com/fukayatti/gbos-x86-port) (`module/gfni_emu.c`, GPL-2.0), which
runs Googlebook OS on a Zen 2 laptop. Differences here: built into the trap path instead of a die-notifier
module (so PID 1 is covered without an initramfs wrapper, memory operands can be paged in, and no CFI
workaround is needed), SHA-NI and AVX-IFMA are added (Kaby Lake has no SHA-NI; Zen 2 does), and the
arithmetic is verified against hardware.
