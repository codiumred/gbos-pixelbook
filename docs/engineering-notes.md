# Pixelbook (EVE, Kaby Lake-Y) feasibility notes — static phase

Date: 2026-10-13. Scope: CLAUDE.md work-plan steps 0–2 plus what could be learned for step 4 without
building anything. No kernel/QEMU builds, no downloads, no device access.
Tags: VERIFIED (evidence path given), INFERRED, UNKNOWN.

## 1. Tooling built

| Tool | Purpose |
|---|---|
| `tools/erofs_read.py` | Pure-Python read-only EROFS reader (compact/extended inodes; flat plain/inline, chunk, compressed full+compact index, LZ4 incl. 0-padding and big pclusters). Needed because the host is Windows with no WSL distro and no erofs-utils. |
| `tools/isa_scan2.py` | Decodes executable sections of every x86-64 ELF with iced-x86, maps each instruction to its CPUID feature, reports features Kaby Lake lacks, per ELF, with mnemonic histogram and containing-symbol top list. Walks EROFS partitions and into APEX payloads (EROFS payloads only; ext4 payload fallback is unimplemented). |

VERIFIED: `erofs_read.py` extracted all 7 slot-0 partitions of `ruby` (and the same layout of lapis/moonstone)
with zero decode errors; every file decompressed to its declared size and `.so/.ko` files carried ELF magic
(validated on vendor_dlkm_a and system_ext_a; the full scans ran without exceptions).
Only 2 APEX payloads were skipped (`com.android.apex.cts.shim`, `widevine`) because they are ext4, not EROFS.

## 2. Corrections to earlier claims

1. VERIFIED: the earlier "AVX-VNNI = 0" was a scanner artifact. objdump prints `{vex} vpdpwssd`, so `^vpdp`
   never matched. `ramdisk-files/init` contains 12 `vpdpwssd`; recovery `init` 14; `linker64` 16.
2. VERIFIED: partitions are EROFS (LZ4, compact index), not ext4, so the old ext4 walker could never have
   scanned them; the old JSON covers only the 180 ramdisk ELFs.
3. VERIFIED: `system_a` (1,081 MiB) is the real system (1,575 ELFs, many in APEX payloads);
   `system_b` (4.2 GiB, 161 ELFs) is the system-other/precompiled-artifact partition.
4. VERIFIED: the "liblzma VAES" counts are real VAES-256 (`AesCtr_Code_HW_256`, `AesCbc_Decode_HW_256`), plus
   `Sha256_UpdateBlocks_HW`; all named HW paths in xz (almost certainly CPUID-gated, INFERRED).

## 3. Static ISA results (`evidence/isa-scan2-*.json`)

| Image | ELFs | ELFs with non-KBL insns | GFNI | AVX-VNNI | AVX-512F | SHA | VAES |
|---|---|---|---|---|---|---|---|
| ruby (Lenovo) | 3,253 | 297 (266 unique by hash) | 7,513 | 16,993 | 169,652 | 3,912 | 6,992 |
| lapis (ASUS) | 3,434 | 318 | 7,835 | 17,123 | 170,081 | 4,152 | 7,320 |
| moonstone (Acer) | 3,408 | 320 | 8,082 | 17,838 | 192,374 | 4,152 | 7,320 |

(lapis/moonstone counts include their ramdisk trees; core binaries are identical across all three:
`init` 40 GFNI + 12 VNNI + 56 SHA, `libc.so` 13 GFNI, `linker64` 24 GFNI + 16 VNNI.)

Findings:

- VERIFIED: 259 of 266 unique hit-ELFs contain GFNI and/or AVX-VNNI. Instruction mix is dominated by
  `vgf2p8affineqb` (7,508 of 7,513 GFNI) and `vpdpwssd`/`vpdpbusd` (14,792 / 4,694). That is a small family of
  instructions, which is what makes emulation tractable.
- INFERRED: these are compiler-emitted (the whole userland appears built with a Panther/Arrow-Lake class
  `-march`: GFNI from vector bit-reverse/byte-shift lowering, `vpdpwssd` from fused pmaddwd+add).
  Evidence: sites spread across init, libc, linker64, libz, libpng, protobuf, etc., with no CPUID gate.
- VERIFIED: libc's ifunc resolvers do not select by CPU. `strrchr_resolver` is `lea rax,[portable_simd_strrchr_avx2]; ret`.
  The `_avx2` variants themselves contain ymm `vgf2p8affineqb` (strrchr 6 sites, strchrnul 1, strspn/strcspn
  drivers 4, `__sched_cpucount` 1). Kaby Lake has AVX2 but not GFNI, so selection cannot save it. Every process
  that calls `strrchr` takes #UD.
- VERIFIED zero hits (good news): libc++, libbase, libcutils, libutils, libbinder, libgui, libui, liblog, libm,
  libdl, servicemanager, app_process64.
- VERIFIED hits on the boot path: init, linker64 (bootstrap+runtime APEX), libc, libz (12), libart (8 GFNI),
  libhwui (75), surfaceflinger (72), vold (3), libcrypto, protobuf libs, libjpeg-class libs, Bluetooth/statsd.
- INFERRED CPUID-gated (unverified individually): AVX-512, VAES, VPCLMULQDQ, SHA live in libcrypto/xz/libjxl/
  libhttpengine/openvino. libcrypto's SHA path in init is the stock OpenSSL `sha256_block_data_order_shaext`
  (legacy-SSE form) beside 8 CPUID sites. The HP (Meteor Lake, no AVX-512) boots, so AVX-512 gating works there.
  Not proven for each ELF.
- VERIFIED: AMX / AVX-VNNI-INT8 / AVX512-FP16 appear only in ML/camera/audio vendor libs
  (libcros_ml_core_internal, openvino plugin, libcamera_internal). Not boot-critical (INFERRED).

## 4. GPU userspace (new, cheap, relevant)

- VERIFIED: vendor ships Mesa ANV Vulkan at `/lib64/hw/vulkan.intel.so` (25.6 MB). Its device table includes
  `HD Graphics 620/630 (KBL GT2)`, `HD Graphics (KBL GT1.5)`, `HD Graphics 520 (SKL GT2)`, WHL/CFL, etc.
  Graphics stack is ANGLE (GLES over Vulkan) + minigbm gralloc + generic `hwc3-service.drm`, not Xe-specific.
  UNKNOWN: whether gfx9 is actually functional in this build (strings only).
- VERIFIED: `vulkan.intel.so` itself has 3,395 AVX-512F and 44 GFNI sites (likely dispatched / compiler).
- VERIFIED: vendor `/firmware/i915/` has only `xe2lpd_dmc`, `xe3lpd_dmc`, `xe3lpd_3002_dmc`. No KBL DMC/GuC/HuC;
  they would have to come from linux-firmware.
- INFERRED: the kernel side, not userspace, is the GPU blocker. See hypothesis H3.

## 5. Updated blocker picture

1. ISA baseline (GFNI + AVX-VNNI in compiler-generated code throughout): emulation of ~7 mnemonics via #UD
   trap would cover essentially everything; binary patching/rebuilding is not realistic. Cost depends on
   dynamic counts (UNKNOWN, step 3).
2. Kaby Lake GPU: needs i915.ko. Userspace appears to support gfx9. Firmware must be sourced separately.
3. Everything else unchanged (Wi-Fi 8265 firmware, EC/keyboard, audio) and unverified.
4. Not yet assessed: AVB/vbmeta handling on a Chromebook (non-Google-signed derived partitions, as gbrunch does),
   verity on modified partitions, and ART `pantherlake` variant artifacts (system_b odex may contain
   ISA-specific code; see Section 6).

## 6. Hypotheses added

- **H3 (cheap, could avoid replacing the kernel for graphics):** build only `i915.ko` out-of-tree against the
  stock `6.18.21-android17-5` GKI artifacts (vendor_dlkm already ships `drm_buddy`, `drm_display_helper`, etc. for
  Xe). If the stock vmlinux exports every symbol i915 needs, no custom kernel is required for GPU. Still needs
  the matching ACK source and Module.symvers. Check by listing `__ksymtab` / using `check_kmi.py` against
  i915's undefined symbols.
- **H4:** trap-and-emulate may be done without a kernel rebuild only if a vendor module can hook #UD. This is
  not generally possible; the emulator realistically needs a kernel patch (that is the "custom kernel" step).
- **H5 (UNKNOWN, worth one scan):** `.odex/.oat` AOT code in system_b/framework oat dirs may carry
  `pantherlake`-specific instructions. They are not ELF `.text` in the usual sense (oat is an ELF with
  `.text`, so the existing scanner can decode them, but they were not selected because the filter keys off
  `.so/.apex`). Not scanned yet; a plain ELF scan of `*.oat`/`*.odex` is a follow-up.

## 7. Cuttlefish donor scan (build 16373615, `aosp_cf_x86_64_only_phone-userdebug`)

Downloaded to `donor_cuttlefish/` (git-ignored; 1,163,638,742 bytes via the androidbuildinternal `.../url` endpoint,
the ci.android.com URL serves an HTML viewer to GET). `super.img` unsparsed with `tools/unsparse.py`, LP parsed
with `tools/inspect_recovery.py::liblp`, scanned with `isa_scan2.py` (`evidence/isa-scan2-cuttlefish-donor.json`).

- VERIFIED: 2,710 ELFs (system_a, vendor_a, product_a, system_ext_a, system_dlkm_a, all APEX payloads incl. ext4
  ones), 0 scan errors. **GFNI = 0, AVX-VNNI = 0, AVX-IFMA = 0.**
- VERIFIED zero hits: `init`, bootstrap + runtime-APEX `libc.so`, `linker64`, `libz`, `libart.so`,
  `libandroid_runtime`, `surfaceflinger`, `app_process64`, `libc++`.
- VERIFIED remaining non-Kaby-Lake instructions are only AVX-512 / VAES / VPCLMULQDQ / SHA in 54 ELFs, the same
  library-dispatched families as Google's image (libcrypto, liblzma, libjxl, libyuv, libstagefright, libhwui 24
  AVX-512F sites), plus `CLDEMOTE` (NOP-encoded on older CPUs) and `CLWB` in a Trusty VM ELF.
- INFERRED: the donor is built for a generic x86-64 baseline, so it is the Kaby Lake-compatible userland that
  Google's `ruby` image is not. The libcrypto/libhwui AVX-512 paths are the same code that already runs on the
  HP (no AVX-512), so they are presumably CPUID-gated.
- Corollary (INFERRED): `ruby` binaries are what carry the GFNI/VNNI; the AOSP donor does not. Swapping
  Google's init/libc/linker/runtime/ART/system libs for the donor's is a plausible alternative to #UD emulation, but
  ABI (Android 17 desktop vs Cuttlefish phone), SELinux policy, vendor interface, VNDK and AVB/verity effects are UNKNOWN.
  Only the Google-specific pieces with GFNI (desktop services, vendor HALs, libhwui/surfaceflinger versions)
  would still need Google's binaries.

Tooling fixes made along the way: `tools/isa_scan.py` ext4 walker now handles file reads correctly (20-byte ELF
header peek, extent placement by logical block, uninitialized extents); `tools/ext4_lite.py` wraps it for APEX
payloads. The 826 earlier "past EOF" errors were that bug, not bad data.

## 8. `.odex/.oat` follow-up

VERIFIED: no separate scan was needed. `isa_scan2.py` selects ELFs by magic, so ruby's 161 system_b `.odex` plus
system_a `.odex/.oat` were already decoded: only 1 `CLDEMOTE` (NOP-encoded) in `KeyChain.odex` and
`desktop-services.odex`. The AOT code carries no unusual ISA; the `pantherlake` variant issue is a runtime
instruction-set-feature/oat-header compatibility check (INFERRED), not an instruction-set blocker.

## 9. Decision gate status (step 4)

Static data does not trigger the stop condition and the donor makes a non-emulation path plausible:
- Path A (donor swap): fastest to test; unknown ABI/SELinux/verity cost. Can be prototyped in QEMU TCG with
  *stock* QEMU and a Skylake-Client CPU model, so no patched-QEMU build is required to answer "does it boot on a
  KBL-feature CPU".
- Path B (#UD emulation): required for any Google binary kept; needs dynamic counts via patched QEMU.
Remaining blockers are unchanged: GPU (kernel i915 + KBL firmware), then device bring-up.

## 10. Environment state / approvals still needed

- MSYS2 is installed at `C:\msys64` (objdump present) but has no compiler/QEMU build deps yet; a QEMU build needs a
  `pacman` install of toolchain + deps (order of 1-2 GB) and a long build. Not started.
- Stock QEMU for Windows (binary installer) is enough for Path A smoke tests and not yet installed.

## 11. Path A smoke test: donor userland on a Kaby Lake-class CPU model (2026-10-13)

Tooling: QEMU 11.1.0 (stock, installed under `C:/Users/you/qemu`), `tools/qemu_donor_boot.py`, `tools/qemu_ruby_control.py`.
Emulation is used purely as an ISA oracle (TCG `-cpu Skylake-Client-noTSX-IBRS` rejects GFNI/VNNI/AVX-512 the way
the Pixelbook's CPU would). The end goal remains bare metal.

- VERIFIED (control, `evidence/ruby-control-Skylake-Client-noTSX-IBRS.log`): Google's unmodified ruby kernel + ramdisk:
  `traps: init[1] trap invalid opcode ip:2e3160 ... Attempted to kill init!` within 2.2 s. This reproduces the
  blocker with stock QEMU, no patches.
- VERIFIED (`evidence/donor-kbl-loop.log`, 600 s): the unmodified AOSP donor (build 16373615) boots through
  first-stage init, AVB/verity mounts of all EROFS partitions, SELinux policy load, second-stage init, apexd-bootstrap,
  zygote start (44 s), surfaceflinger, servicemanager and dozens of HALs on the same CPU model.
  **0 invalid-opcode traps and 0 SIGILL in ~8.8 MB of kernel/init log.** (Needed only Cuttlefish-launcher cmdline
  items: `androidboot.fstab_suffix=cf.ext4.hctr2` and `androidboot.vendor.apex.<module>=<apex>` selectors.)
- VERIFIED: it did not reach a stable framework. zygote and many HALs are SIGKILL/SIGABRT-looped (~108 restarts).
  Not ISA related (no SIGILL). Probable causes, UNINVESTIGATED: no virtio-gpu/vsock/net/input devices wired up in
  my QEMU command line, no Cuttlefish launcher services. Not needed to answer the ISA question.
- VERIFIED: the donor's kernel is `6.12.74-android16`, not the `6.18.21-android17-5` Google ships. Donor userland
  therefore cannot be assumed to pair with Google's 6.18 kernel and vendor modules; that is a kernel/ABI question,
  not an ISA problem.

Conclusion (INFERRED): the AOSP userland stack, including bionic, ART, surfaceflinger and the APEX set, is
Kaby Lake-compatible as built. The ISA blocker is specific to Google's desktop build flags.

## 12. Step 1: donor userland on Google's own kernel (2026-10-13)

`tools/qemu_donor_boot.py --kernel recovery_ruby/inspect_recovery/boot_a/kernel` (NVMe disk, donor module list
emptied because donor `.ko` files are 6.12 builds and first-stage init treats an insmod failure as fatal).

- VERIFIED (`evidence/donor-on-ruby-kernel.log`, 400 s): Google's `6.18.21-android17-5-g3938c8d97142-ab16302624`
  kernel runs the unmodified donor userland through first-stage init, AVB/verity mounts, second-stage init, apexd,
  zygote and HAL startup on the Skylake-Client CPU model. 0 invalid-opcode traps, 0 SIGILL, no kernel panic.
  Same non-ISA restart loops as on the donor's own kernel (zygote/HALs; no graphics/virtio devices wired).
- Consequence (INFERRED): Google's GKI kernel + AOSP userland + (eventually) Google's Intel vendor modules is a
  workable combination, so the "custom kernel" may reduce to an out-of-tree i915 module (H3) plus whatever
  desktop-specific services must be reconstructed on top of the donor.
- Kernel provenance (VERIFIED from `git ls-remote`): `android17-6.18` branches and `android17-6.18-2026-0{4,6,9}_rN`
  tags are public on android.googlesource.com/kernel/common. The version string's trailing `ab16302624` is a CI
  build id, consistent with a publicly built GKI artifact. Not yet confirmed: which tag corresponds to
  `6.18.21-android17-5`, and whether a prebuilt for it can be fetched (build-listing API is rate-limited).
  No `android17-6.18-desktop` branch is visible (earlier releases have `-desktop` branches).

## 13. Scoping pass + review of related repos (2026-10-14)

Cloned as siblings of this repo: `../gbos-vm`, `../AluminiumOS`, `../GooglebookOS-x86`, `../Googlebook-asus`,
`../gbos-x86-port`, `../gist-236a` (the gist). Third-party content; claims below are theirs unless marked VERIFIED.

### Most important: `gbos-x86-port` (fukayatti) already did our "step 3 + step 5" on real hardware
- Claim: Googlebook OS (`lapis`, build 16452207) reaches the setup wizard and desktop on bare metal on a
  Ryzen 7 5700U (Zen 2, which lacks GFNI/VNNI/VAES/AVX-512), booting from USB SSD with GRUB.
  Working: amdgpu, Wi-Fi (rtw88), Bluetooth, brightness, suspend. Not done: audio, fingerprint, OTA.
- Method: `module/gfni_emu.c` (GPL-2.0, 580 lines): a loadable module hooking `register_die_notifier`, trapping #UD from user
  mode, emulating GFNI, VPCLMULQDQ, AVX-VNNI and VAES on saved YMM state. Needs `cfi=norand`. Author cross-checked
  the affine transform against simde (100k cases) and fixed a transposed-matrix bug.
- Measured dynamic cost (their numbers, Zen 2): ~330,000 traps/s steady state, all from `libz.so` Adler-32
  (`vpdpwssd`, 8 sites). Fix: rebuild zlib at a baseline CPU and overlay it into the system EROFS, giving <10k/s.
  Residual: ~100k/s peak during the first-boot package scan (130-310 s), attributed to BoringSSL in libcrypto.
- Kernel: they rebuild `android17-6.18` from source, same config, plus drivers as modules.
- Independent confirmations of our findings (they used objdump/own scanners): init 40 GFNI, linker64 24 GFNI + 16 VNNI,
  libc++/libandroid_runtime/libhwui 0, totals ~6,800 GFNI / ~16,700 VNNI. Their conclusion also: the whole OS is built
  for a Panther Lake-class baseline. Also: KVM cannot emulate missing instructions; QEMU TCG then lacked GFNI.

### Facts that change our plan
1. VERIFIED: tag `android17-6.18-2026-06_r52` peels to commit `3938c8d97142d5cf...`, exactly the shipped
   `6.18.21-android17-5-g3938c8d97142`. Public, reproducible kernel source for the shipped binary.
2. VERIFIED (shipped config as extracted by gbos-x86-port, `../gbos-x86-port/kernel/shipped_kernel_config.txt`):
   `MODULE_SIG=y`, `MODULE_SIG_PROTECT=y`, `TRIM_UNUSED_KSYMS=y` with whitelist `abi_symbollist.raw`,
   `DRM_I915`/`DRM_XE` unset, `DRM_DISPLAY_HELPER`/`DRM_BUDDY`/`DRM_EXEC`/`DRM_SCHED` absent, no `CHROME_PLATFORMS`
   or `CROS_EC*`, no `I2C_HID_ACPI`, no `PINCTRL_SUNRISEPOINT`/`MFD_INTEL_LPSS`, no `TOUCHSCREEN_ATMEL_MXT`, no
   `SND_HDA_INTEL`/Skylake/AVS audio, `SIMPLEDRM` and `FB` off, `RUST=y`, `KVM_INTEL=y`.
   => **H3 is refuted**: exports are trimmed to the ABI list and protected symbols require Google-signed modules, so an
   out-of-tree `i915.ko` cannot load on the stock kernel. A rebuilt kernel is required (they also patch
   `kernel/module/main.c` to drop the protected-symbol check). The "custom kernel" step is real but well-trodden.
3. INFERRED config deltas for the Pixelbook (Kaby Lake-Y / Sunrise Point-LP PCH): DRM_I915 (+ display helper, buddy),
   CHROME_PLATFORMS + CROS_EC(_LPC) + KEYBOARD_CROS_EC (keyboard/EC), I2C_HID_ACPI + I2C_DESIGNWARE + MFD_INTEL_LPSS +
   PINCTRL_SUNRISEPOINT (touchpad/touchscreen), ATMEL_MXT (if applicable), iwlwifi (8265), audio via SND_SOC_INTEL_SKYLAKE
   or AVS (the hard one). Exact PCI/ACPI IDs UNKNOWN until `lspci`/ACPI dump from the device.
4. UNVERIFIED RISK specific to us: Zen 2 has SHA-NI, Kaby Lake does not. `init` contains 56 SHA instructions (OpenSSL
   shaext). Likely CPUID-gated, but this path was never exercised on a CPU without SHA. Our Skylake-Client TCG
   harness can test it directly.
5. VERIFIED (gist-236a): the virtio device modules for this exact kernel build are published on ci.android.com
   (`kernel_virt_x86_64` build 16302624), with matching vermagic and `vmlinux.symvers`. Useful for QEMU tests with
   Google's real userland and a virtual GPU; also proof that build-16302624 kernel artifacts exist for download.
   The gist's `isa_census.py`/`extract_lapis.py`/`make_initrd_x86.py`/`boot_serial.sh` overlap our tooling.

### Other repos
- `GooglebookOS-x86` (ReUnknown): installer for Alder Lake+ (CPU gate `gfni`,`sha_ni`,`avx_vnni`), tested on one laptop.
  Not useful for pre-Alder-Lake CPUs; useful as a reference for ADL-P `i915/adlp_*` firmware names and installer safety design.
- `Googlebook-asus` (paulst8): Ubuntu GRUB-based install on ASUS TUF F16; docs on vendor rebuild (software KeyMint
  from Cuttlefish, crash-looping Trusty services stopped, firmware copied from host). Same technique as gbrunch.
- `AluminiumOS` (DangerousAndroid): runs the arm64 image under full-system QEMU emulation on x86; unrelated to native
  boot. Note: the repo is 2.7 GB and appears to bundle Google binaries; do not copy from it.
- `gbos-vm` (skylartaylor): ARM/Apple Silicon; already known; its mapper5 Mesa patch is referenced by gbos-x86-port.

### Revised plan
The #UD emulator exists as a prototype, so the spike shrinks to: (a) review and differential-test `gfni_emu.c`
(including VEX 256-bit memory operands, fault handling in the die notifier, and register state); (b) reproduce
their kernel build (`kmake.sh`: LLVM, rustc 1.91.1, `KBUILD_GENDWARFKSYMS_STABLE=1`) with `i915` etc. as modules;
(c) boot Google's unmodified ruby userland under QEMU TCG `Skylake-Client` with the patched kernel + module, count traps,
and check the SHA path; (d) only then hardware. Needs a Linux build environment (no WSL distro installed yet).

## 14. Kernel spike: #UD emulator built, verified and booted (2026-10-14)

Environment: WSL2 Ubuntu 26.04 on the dev host (i7-13700, which natively has GFNI, AVX-VNNI, VAES, VPCLMULQDQ
and SHA-NI, so it is a hardware oracle), clang/lld 21.1.8, rustc 1.91.1 + bindgen 0.72.1. Code is in `pixelbook/`
(see `pixelbook/README.md`). Kernel tree: ACK tag `android17-6.18-2026-06_r52` fetched as a tarball of commit
`3938c8d97142d5cf...`.

### 14.1 What must be emulated (VERIFIED, `evidence/isa-scan2-ruby-forms.json`)
Scan of 3,505 ELFs by exact encoding. Excluding EVEX (AVX-512, 189,367 of 230,995 hits, unreachable without
AVX-512 state) and AVX-512 mask / AMX ops, the non-Kaby-Lake forms are all VEX or legacy SSE with plain or
RIP-relative memory operands (no segment overrides, no 32-bit addressing):
VPDPWSSD/VPDPBUSD(S) xmm+ymm, VGF2P8AFFINEQB xmm+ymm, VGF2P8MULB, VAESENC/ENCLAST/DEC/DECLAST ymm, VPCLMULQDQ ymm,
SHA1*/SHA256* (legacy), VPMADD52LUQ xmm (AVX-IFMA, one site each in about 15 Rust binaries incl. libinput.so),
VPDPBSSD ymm (AVX-VNNI-INT8, only in ML/camera/audio vendor libs).

### 14.2 SHA-NI is unconditional (VERIFIED): a Kaby Lake-specific problem
`SHA256_Transform` in Google's `libcrypto.so` tail-calls straight into the SHA-NI block function; the donor's
build of the same function first tests `OPENSSL_ia32cap` bit 29. BoringSSL resolves capability checks at compile
time when the build baseline defines the feature macro. Zen 2 has SHA-NI, so gbos-x86-port never saw this; Kaby
Lake does not. The same mechanism explains the VAES/VPCLMULQDQ-256 traps (AES-GCM) reported by gbrunch.

### 14.3 Emulator design (`pixelbook/isa_emu/isa_emu_core.h`, `pixelbook/kernel/isa_emu.c`)
Built into the user-mode #UD path (`exc_invalid_op`), like UMIP emulation, instead of a die-notifier module:
PID 1 is covered without an initramfs wrapper; memory operands are read with a normal sleeping `copy_from_user`
(a not-present page is faulted in, an unmapped one raises SIGSEGV); vector state is read/written on the live
registers under `fpregs_lock()`; no CFI workaround or `cfi=norand`. Review of gbos-x86-port's `gfni_emu.c` found
two issues this avoids: operand reads with page faults disabled turn a not-yet-mapped constant page into a
spurious SIGILL, and VPDPWSSDS sums the two products in 32 bits before saturating (wrong when both products are
2^30). Not covered by design: EVEX, AVX-VNNI-INT8/16, AMX.

### 14.4 Verification
- VERIFIED (`evidence/isa-emu-difftest-soak-i7-13700.log`): core vs native execution on the i7-13700, 3 seeds x
  (60M random cases + 15M mutated encodings) = 225M cases, 0 failures. Covers both encodings, VEX.128/256,
  register and memory forms, every addressing mode, REX/VEX high registers, FS/GS and 0x67 prefixes. About 36% of
  mutated encodings are accepted by the decoder and every one matched hardware (no false accepts; for example
  hardware really does #UD on VEX.W0 GF2P8AFFINEQB). Four injected bugs were all caught.
- NOT hardware-verified: VPMADD52LUQ/HUQ (host lacks AVX-IFMA); checked against an independent limb-based
  reference only.
- VERIFIED (`evidence/isa-emu-guest-e2e-skylake-client.log`): patched kernel under QEMU TCG `Skylake-Client`,
  difftest as PID 1, 4 concurrent processes: about 394k trapped instructions, 0 mismatches against the core; an
  unmapped operand gives SIGSEGV at the operand address; never-touched anonymous and file-backed operand pages
  work. Control with `isa_emu=off` fails every case (`evidence/isa-emu-guest-e2e-control-off.log`).

### 14.5 Kernel build (`pixelbook/kernel/build.sh`)
- VERIFIED: the shipped config extracted from our ruby image (`evidence/ruby-kernel-6.18.21.config`) is identical
  to gbos-x86-port's copy from lapis. Rebuild delta is toolchain version strings plus our two options
  (`evidence/pixelbook-kernel-config-delta.txt`). Release string matches the shipped kernel exactly. Compile takes
  about 6 minutes on this host. The build produces exactly the 100 GKI modules shipped in system_dlkm.
- Two inputs Kleaf normally generates had to be reproduced: `abi_symbollist.raw` (from `gki/x86_64/symbols/*`, which
  includes a roughly 3,700-symbol `desktop` list) and `protected_module_names_list` (from the shipped system_dlkm
  module names).
- VERIFIED (`evidence/pixelbook-kernel-crc-check.json`): all 643 prebuilt modules (system_dlkm, vendor_dlkm,
  vendor_boot ramdisk), 37,252 symbol references, 0 CRC mismatches, 0 missing non-Rust symbols. Vendor modules
  were built against a different tree (`ga3bbc4527b7b-ab16320342`); with MODVERSIONS the loader ignores the release
  part of vermagic. Exception: the shipped `rust_binder.ko` needs 51 Rust symbols whose mangled names carry
  Google-toolchain crate hashes, so it cannot link against a rebuilt kernel. Google's cmdline has `binder.impl=rust`;
  the C binder is built in and is what these tests used. UNKNOWN whether userspace depends on Rust-binder-only
  behaviour; the alternative is shipping our own `rust_binder.ko`.
- VERIFIED in the boot log: Google's signed modules load on the rebuilt kernel (8250_dw, intel-lpss, pinctrl-intel,
  i2c-i801, intel_pmc_core and others). This needs the protected-symbol relaxation in `apply.sh` because a rebuilt
  kernel cannot verify Google's module signatures.

### 14.6 Google's unmodified userland on a Kaby Lake-class CPU (VERIFIED, `evidence/ruby-isaemu-1.{log,json}`)
`pixelbook/qemu_ruby_boot.py --kernel build/pixelbook/bzImage --extra isa_emu=profile`, 240 s, Skylake-Client TCG:
first-stage init, module loading, AVB/verity mounts, SELinux, second-stage init (26 s), apexd (46 APEXes
activated), ueventd, servicemanager, vold, trusty launcher. 0 invalid-opcode traps, 0 SIGILL, 0 panics. It then
waits forever for keystore2/KeyMint/secretkeeper, the hardware-security dependency gbrunch already solves with the
Cuttlefish software KeyMint and a derived vendor partition. That is not an ISA issue.

Trap profile (20,391,247 emulated instructions): SHA-256 20.27M (99.4%: sha256rnds2 11.59M, msg1 4.35M, msg2
4.35M), GFNI 76k, SHA-1 29k, AES 1.2k, PCLMULQDQ 0.9k. The hot sites are one function, `libcrypto.so+0x1357eb..`.
About 362k SHA-256 blocks (23 MiB) were hashed, at 60-190k traps/s under TCG.
- INFERRED: most of it is BoringSSL's per-process integrity self-check at library load (each libcrypto-using
  process start costs on the order of 1M traps), which is why second-stage init takes 23 s here and each early
  service start takes about 12 s. On real hardware a trap is far cheaper than under TCG, but this is still likely
  around a second per process start. UNKNOWN until measured on the device.
- Consequence: on SHA-less CPUs the dominant cost is SHA-256, not GFNI/VNNI. Options: (a) a kernel fast path that
  recognises the well-known SHA-NI block function and hashes whole calls natively, (b) burst-interpreting the
  surrounding SSE instructions so one trap covers a whole block, (c) overlaying the donor's `libcrypto.so` (and the
  copies inside APEXes). (a) and (b) keep Google's bytes untouched and survive updates.

### 14.7 Pixelbook drivers: almost everything is already shipped (VERIFIED names/aliases, INFERRED hardware match)
`evidence/ruby-dlkm-file-lists.json`, `evidence/ruby-vendor-dlkm-modules.alias`,
`evidence/pixelbook-eve-module-alias-check.json`. Google's vendor_dlkm (484 modules, built for this kernel) is a
ChromeOS-heritage superset. It has module aliases for: Chrome EC over LPC (`cros_ec_lpcs`, GOOG0004), EC keyboard
(`cros_ec_keyb`), keyboard backlight, tablet-mode switch, Cr50 TPM, `chromeos_acpi`, I2C-HID, `atmel_mxt_ts`,
`pinctrl_sunrisepoint` (INT344B), `intel_lpss_pci` (Sunrise Point-LP I2C/SPI), `sdhci_pci` (9D2B eMMC), `iwlwifi`
plus `iwlmvm` (8086:24FD = 8265), `snd_soc_avs` / `snd_sof_pci_intel_skl` for the KBL-LP audio device (8086:9D71)
with `snd_soc_rt5663`, `snd_soc_rt5514`, `snd_soc_max98927` and the matching AVS board modules, and the IPU3 camera
(`ipu3_cio2`, `ipu3_imgu`). There is no alias for the GPU (8086:591E). The device IDs checked come from public
knowledge of the EVE board, NOT from the device: confirm with `lspci -nn` and an ACPI dump.

### 14.8 i915 for Kaby Lake builds and keeps the ABI (VERIFIED)
`pixelbook/kernel/eve.config` (`CONFIG_DRM_I915=m`), `evidence/pixelbook-kernel-eve-config-delta.txt`,
`evidence/pixelbook-i915-modinfo.txt`, `evidence/pixelbook-kernel-eve-crc-check.json`.
`i915.ko` builds from the same tree; it carries aliases for 8086:591E (HD 615) and 8086:87C0 (Amber Lake-Y),
depends on `intel-gtt`, `drm_buddy`, `drm_display_helper`, `video`, `i2c-algo-bit` (built alongside), and names
`i915/kbl_dmc_ver1_04.bin`, `kbl_guc_70.1.1.bin`, `kbl_huc_4.0.0.bin` (not shipped by Google; linux-firmware has
them). Enabling it turns on two built-in options (`RELAY`, `VMAP_PFN`); the resulting kernel still has 0 CRC
mismatches against all 643 prebuilt modules. UNKNOWN: runtime behaviour (never loaded on hardware), whether
Google's own `drm_display_helper.ko`/`drm_buddy.ko` could be used instead of ours, and Android userspace
(minigbm/ANV) on gen9.

### 14.9 Updated picture
The two original blockers each now have a working answer in software: ISA (emulator, verified) and the GPU driver
(builds, ABI-compatible, untested on hardware). Peripheral drivers are mostly Google's own. Remaining work, in
order: (1) SHA-256 trap cost; (2) get past KeyMint/keystore2 using gbrunch's existing compat/vendor machinery so
the framework and UI can be reached under QEMU; (3) decide on Rust binder; (4) hardware: `lspci`/ACPI facts,
firmware (mrchromebox UEFI), boot media layout, KBL firmware blobs, then first boot. Steps 1-3 need no hardware.

## 15. Device facts, SHA-256 fast path, gbrunch userland on our kernel, Pixelbook image (2026-10-14)

### 15.1 Device facts from the owner (VERIFIED, `evidence/pixelbook-eve-device-facts.txt`)
ChromeOS `cpuinfo` and `lspci` from the actual Pixelbook: i5-7Y57 with avx2/fma/bmi2/adx/aes/pclmulqdq and none of
gfni, vaes, vpclmulqdq, avx_vnni, avx512, sha_ni, rdpid; `pti` active; ChromeOS runs it with hyper-threading off
(2 logical CPUs). HD Graphics 615, Sunrise Point-LP PCH (I2C #0/#1/#2/#4, UART #0/#2, SPI #0, HD Audio, xHCI),
SD host controller 8086:9d2b (eMMC; there is no NVMe), and **Intel Wireless 7265** (not 8265 as assumed).
No IPU3 devices, so the camera is not IPU3. Re-check of Google's vendor module aliases with these facts:
`iwlwifi` claims 8086:095A/095B (7265), `sdhci_pci` 9D2B, `intel_lpss_pci` the LPSS I2C/UART/SPI IDs,
`i2c_i801` SMBus, `snd_soc_avs`/`snd_sof_pci_intel_skl`/`snd_hda_intel` both 9D70 and 9D71, `btusb` by USB class.
`lspci` was run without `-nn`, so most numeric IDs and all ACPI IDs remain INFERRED.

### 15.2 SHA-256 fast path (VERIFIED)
`pixelbook/isa_emu/isa_emu_fastpath.h`, `gen_fastpath.py`, `test/fptest.c`; kernel side in `isa_emu.c`.
- `gen_fastpath.py` found BoringSSL's `sha256_block_data_order_hw` 40 times in the ruby image (22 ELFs: every
  `libcrypto.so` copy, first-stage `init`, `libring`, `libnetd_resolv`, ...) and all are byte-identical apart from
  one RIP-relative displacement: one table entry (829 bytes, FNV-1a hash) covers them
  (`evidence/isa-emu-fastpath-ruby.json`). The table holds offsets, 8 opcode bytes and a hash, no code.
- At the function's first SHA256RNDS2 the kernel verifies the hash, takes the working state from xmm1/xmm2, hashes
  all remaining blocks with the kernel's own SHA-256, stores the state and resumes at the function's `ret`. Any
  mismatch or inaccessible user memory leaves everything untouched and falls back to per-instruction emulation.
- `fptest` runs the real function bytes (dumped locally from the image, not in the repository): natively on the
  i7-13700 it matches a C reference for 3,000 random calls, a known answer, and fault cases
  (2.3 GiB/s). In the Skylake-Client guest with the fast path: same tests pass, 3,060 calls / 2.37M blocks handled
  natively, 29 MiB/s (`evidence/isa-emu-guest-fastpath-on.log`); with `isa_emu_fast=0`: same tests pass at
  0.12 MiB/s (`evidence/isa-emu-guest-fastpath-off.log`). Fault semantics are identical in both modes (message
  running into an unmapped page and read-only state both give SIGSEGV with the state untouched).
- Effect on the unmodified ruby boot (`evidence/ruby-isaemu-2-fastpath.{log,json}` vs `ruby-isaemu-1`):
  emulated instructions 20,391,247 -> 107,759; second-stage init 26.0 s -> 4.2 s, vold 83.9 s -> 11.4 s,
  keystore2 start 199.7 s -> 25.5 s. BoringSSL's own integrity check and AVB hashing pass on the fast path.

### 15.3 gbrunch's compatibility layer with our kernel (VERIFIED, `evidence/gbrunch-image-isaemu-kernel-boot-1.log`)
`pixelbook/gbrunch_assemble.sh` runs gbrunch's own V7 assembler and asset kit in WSL (our recovery image hash
equals the one gbrunch pins; the kit's expected Google kernel hash equals ours). `pixelbook/qemu_gbrunch_boot.sh`
boots the result with the patched kernel, Skylake-Client TCG, 600 s:
keystore2 starts at 10 s (the KeyMint stall is gone: gbrunch's software KeyMint/Gatekeeper work on our kernel),
zygote at 20 s, surfaceflinger at 23 s. 22 kernel modules load, 0 module errors, 0 invalid-opcode traps, 0 SIGILL,
0 panics. Then `vendor.graphics.allocator` exits and surfaceflinger aborts, restarting zygote about every 5 s:
this VM has no GPU that Google's graphics stack (minigbm + ANV) can use. That is the limit of what QEMU can show;
it is the same boundary gbrunch documents for QEMU.
- Trap profile over the 600 s: 2.94M emulated instructions (about 4.9k/s): GFNI 958k (hottest sites
  `linker64+0x9911f` and `libc.so+0xa06ed`), SHA-1 1.83M, AES 82k, PCLMULQDQ 60k. The SHA-256 fast path took 81,139
  calls covering 22.65M blocks (1.45 GB), which would otherwise have been about 1.27 billion traps.
- gbrunch's command line has no `binder.impl=rust`, and its HP result (home screen on Google's kernel) used the
  built-in C binder, so the Rust binder module is not needed (INFERRED from gbrunch's result; consistent here).
- SHA-1 (`sha1_block_data_order_hw`) is now the largest remaining trap source; the same fast-path mechanism would
  apply. Not done: at about 3k traps/s it is not worth the complexity yet.

### 15.4 Pixelbook image (VERIFIED in QEMU only, `evidence/eve-image-uefi-usb-boot-1.log`)
`pixelbook/build_eve_image.sh` copies gbrunch's image and replaces only the three boot files on its EFI partition:
kernel = rebuilt kernel with `CONFIG_DRM_I915=m`; initrd = gbrunch's plus stripped, signed `intel-gtt`,
`i2c-algo-bit`, `wmi`, `video`, `drm_buddy`, `drm_display_helper`, `i915` and `i915/kbl_{dmc_ver1_04,guc_70.1.1,
huc_4.0.0}.bin` from linux-firmware, with the first-stage module list switched from Xe to i915; `grub.cfg` without
gbrunch's HP-only gate, adding `intel_iommu=igfx_off isa_emu=on`. Image `~/gb/gbrunch/eve.raw` in WSL, 19.8 GB,
userdata 4.1 GiB.
`pixelbook/qemu_eve_uefi_boot.sh`: OVMF -> GRUB -> kernel from an emulated USB storage device, Skylake-Client:
the whole i915 module chain loads in first stage with no errors, then the same milestones as 15.3 (keystore2,
zygote, surfaceflinger), 0 faults. i915 binds to nothing in QEMU, so the driver itself, the DMC firmware load,
minigbm's i915 backend and ANV on gen9 are all UNTESTED.

### 15.5 Booting it on the device: what is known (docs.mrchromebox.tech, fetched 2026-10-14)
- VERIFIED from the supported-devices table: Pixelbook (EVE) supports both RW_LEGACY and UEFI Full ROM; write
  protection is controlled by Cr50 (SuzyQ cable or battery disconnect).
- VERIFIED from the firmware-script page: RW_LEGACY replaces only the RW_LEGACY region, keeps ChromeOS, does not
  need write protection disabled, and is booted with CTRL+L from the developer-mode screen; it is not offered for
  devices past their auto-update expiry. UEFI Full ROM replaces the whole firmware, needs write protection
  disabled, and ChromeOS no longer boots afterwards; a stock-firmware backup is recommended.
- UNKNOWN: whether RW_LEGACY on EVE is a legacy-BIOS (SeaBIOS) or UEFI (edk2) payload. Our image currently has
  only a UEFI boot loader; a legacy-BIOS GRUB would have to be added for SeaBIOS.
- The recovery image itself carries a ChromeOS-format kernel partition (KERN-A), so Googlebooks boot through
  ChromeOS-style firmware. A third route is therefore developer-mode USB boot of a ChromeOS-format kernel
  partition signed with developer keys (no firmware change at all), which needs the initramfs built into the
  kernel and depends on depthcharge's kernel size limit on EVE (UNKNOWN).
- Every route requires developer mode, which wipes the ChromeOS user data on the device.

### 15.6 gbos-x86-port update (6 commits up to 6c426cf, reviewed 2026-10-14)
- Mostly AMD/Realtek-specific: analog audio for an ALC257 HD-Audio codec, a btrtl NULL-pointer fix, and a WIP installer
  (`gbos detect|kconfig|initrd|esp|plan|install`). The emulator module is unchanged (still no SHA-NI, no AVX-IFMA).
- Useful for us later: Google's audio HAL (`dras`) picks its card from `/vendor/etc/data/hal_configs/audio_*.xml`
  (`<soundcard>` = ALSA card id, `<audio-config-dir>`), and only Intel SOF boards ship configs. Pixelbook audio (AVS,
  rt5663/rt5514/max98927) will need its own config dir the same way. Also: init expands `$` in rc arguments (use `$$`).
- Their CPU verdict (`tools/gbos_detect.py`) only lists GFNI/VAES/VPCLMULQDQ/AVX-VNNI as emulatable, so it would call a
  Kaby Lake "emulated" although their module cannot run SHA-NI code: worth reporting upstream with our 14.2 finding.
- VERIFIED (MrChromebox `firmware.sh`, fetched 2026-10-14): on Kaby Lake boards including EVE, RW_LEGACY asks
  "L for Legacy BIOS (SeaBIOS), U for UEFI (edk2/Tianocore)". Choosing U gives a UEFI payload, which our image already
  boots with; ChromeOS stays and write protection stays on.

## 16. ChromeOS baseline and the first device image (2026-10-14)

### 16.1 Baseline from ChromeOS on the device (VERIFIED, `evidence/pixelbook-eve-baseline-chromeos.txt`)
The owner typed the collection command by hand and its line breaks were lost, so `/proc/bus/input/devices`, the
`dmesg` excerpt and most of the firmware listing are missing. What it does establish:
- PCI IDs: GPU 8086:591e, HD Audio 8086:9d71, eMMC 8086:9d2b, Wi-Fi 8086:095a (7265), xHCI 9d2f, LPSS I2C
  9d60/9d61/9d62/9d64, UART 9d27/9d66, SPI 9d29, SMBus 9d23, MEI 9d3a.
- USB: Bluetooth 8087:0a2a (Intel, 7265 family), webcam 0bda:564b (Realtek, UVC; UVC is built into the kernel).
- ACPI HIDs include 10EC5514, 10EC5663, MX98927 x2 (codecs), ACPI0C50 (I2C HID), WCOM50C1 (Wacom, I2C HID via
  its PNP0C50 compatible ID), PRP0001 (device-tree-compatible device; Google's vendor aliases map PRP0001 to
  `atmel_mxt_ts` among others), GOOG0002/0003/0004/0005/0006/0008/9999, GGL0001, INT344B, INT3400/INT3403, PNP0303,
  PNP0C0D (lid), PNP0C0C (power button).
- The keyboard is a PS/2 keyboard behind the EC's 8042 interface (PNP0303), not `cros_ec_keyb`. Google's kernel
  has `SERIO_I8042=y` and `KEYBOARD_ATKBD=y` built in, so it needs no module (VERIFIED from the shipped config).
- ChromeOS drives audio with the AVS driver: cards `avs_max98927`, `avs_rt5663`, `avs_rt5514` and HDMI
  `hdaudioB0D2`, all named Google-Eve-1.0. Google's vendor_dlkm ships these AVS board modules. Google's audio HAL will
  still need its own config for these cards (see 15.6). Not done.
- ChromeOS's `/lib/firmware/i915` on EVE holds only `skl_*` files; the `intel/avs` directory exists but its
  contents were not listed.

### 16.2 Board firmware added to the vendor partition (VERIFIED in QEMU)
`pixelbook/vendor_overlay.py` appends files to gbrunch's derived vendor EROFS with `mkfs.erofs --incremental`,
using gbrunch's method for keeping the labels of parent directories and the root inode's shared-xattr reference.
A first attempt without that left the vendor root unlabeled, apexd could not read it, and init rebooted; this was
caught by the QEMU boot test and fixed, and the tool now re-checks the parent labels after the build. The result
outgrows the old slot by 0.2 MiB, so the tool renames the old GPT entry `GBVENDOR_OLD` and appends a new
`GBVENDOR` (same unique GUID) at the end of the image. Added, with label `vendor_firmware_file`:
`iwlwifi-7265D-29.ucode` (linux-firmware moved it to `intel/iwlwifi/`; the kernel still requests it at the root)
and the Intel `ibt-hw-37.8*` Bluetooth patch files. The command line gains `firmware_class.path=/vendor/firmware`
(as in Google's own vendor command line).
`evidence/eve-image-uefi-usb-boot-3.log`: OVMF -> GRUB -> USB storage boot reaches keystore2, zygote and
surfaceflinger again, with 0 faults and no new SELinux denials (35 pre-existing denials on other partitions, the
same count as before).

### 16.3 Image handed over
`build/pixelbook/pixelbook-googlebook-eve.img` (20,168,327,680 bytes, git-ignored), SHA-256 `e5ac27f6...c9aac9`,
verified after the copy to Windows. It contains Google-derived partitions: local use only, never publish it.
Untested anywhere: i915 on real hardware, the DMC firmware load, minigbm/ANV on gen9, Wi-Fi, Bluetooth, touch, audio.

### 16.4 Complete ChromeOS baseline (VERIFIED, `evidence/pixelbook-eve-{dmesg,input,firmware}-chromeos.txt`)
- ChromeOS kernel 6.6.119 loads `i915/kbl_dmc_ver1_04.bin` (the file our initrd carries), `7265D-29.ucode` with
  iwlmvm, and Bluetooth patch `intel/ibt-hw-37.8.10-fw-22.50.19.14.f.bseq`: both are in the image's vendor partition.
- The Cr50 TPM is on I2C (`cr50_i2c`, GOOG0005). The eMMC is a 116 GiB DURM4R. ChromeOS runs SMT on.
- Inputs: PS/2 keyboard (`isa0060/serio0`), Google touchpad over I2C-HID (`ACPI0C50:00 18D1:5028`), and the Wacom
  WCOM50C1 digitizer that provides both finger touch and stylus. There is no separate Atmel touchscreen device.
- Audio: `snd_soc_avs` with DSP base firmware `intel/avs/skl/dsp_basefw.bin`, a Maxim DSM library, and topologies
  `intel/avs/{max98927,rt5663,rt5514,hda-8086280b}-tplg.bin`. These, the ALSA UCM files and the CRAS board/DSP
  configs were copied from the device into `build/pixelbook/eve-chromeos/` (git-ignored; device files, local use only)
  for the later audio-HAL work. The panel is eDP 2400x1600.
- Safety change: gbrunch's layer already keeps GSC/Trusty/firmware-update services from starting (none ran in the QEMU
  boot), and `vpd`/`flashrom`/`futility` are stubbed in its vendor. Google's kernel has no built-in TPM support, so
  the image's command line now adds `module_blacklist=tpm,tpm_tis_core,tpm_tis,tpm_tis_spi,tpm_tis_i2c_cr50,cros_ec_debugfs`,
  keeping Googlebook userland away from the Pixelbook's Cr50 (ChromeOS owns it) during these experiments.
  Rebuilt image SHA-256 `5bdeecb3...f5fe08a`; QEMU boot test `evidence/eve-image-uefi-usb-boot-4.log` unchanged.

## 17. First boot on the real Pixelbook (2026-10-15, VERIFIED from the device's own logs)

Logs: `evidence/pixelbook-first-boot-logs/` (gbrunch logger: kernel log, logcat, process list, SurfaceFlinger dump).
The owner saw the Googlebook boot animation and then a frozen-looking logo for about 10 minutes; the logs show a
**slow but progressing first boot**, powered off before it finished.

What worked on the device, first time:
- Our kernel booted through UEFI/GRUB from the USB drive; `isa_emu` was active (`gfni=0 avx_vnni=0 vaes=0
  vpclmulqdq=0 sha_ni=0`); no invalid-opcode crash anywhere in Google's userland.
- i915 bound the Kaby Lake GPU (`Found kabylake/ulx (device ID 591e) ... display version 9.00`), loaded
  `kbl_dmc_ver1_04.bin`, exposed card0 + renderD128, and drm_hwcomposer attached eDP-1 (Sharp LQ123P1JX32,
  2400x1600 @ 59.98 Hz) with the intel_backlight.
- SurfaceFlinger initialised Vulkan on the Intel GPU and runs "SkiaVk (Graphite)" (ANV on gen9, via minigbm gralloc),
  i.e. real GPU rendering, not a software fallback. The boot animation drew through it.
- Keyboard (i8042), Wacom digitizer (WCOM50C1, finger+stylus) and the Google touchpad (ACPI0C50 18D1:5028) all bound
  to `hid-multitouch` over LPSS I2C; the 7265 Wi-Fi driver (`iwlmvm`) and Bluetooth (`btusb`/`btintel`) loaded; the AVS
  audio DSP stack, EC (`cros_ec_lpcs`, sensors, charger, backlight LEDs) and sdhci loaded.
- keystore2 / KeyMint came up; zygote at +3.5 min; system_server entered at 03:27:32.

Where it was when powered off (system_server 4 min into its work): PackageManagerService first-boot scan, at
`/product/priv-app/T...`, i.e. reading and certifying hundreds of APKs. Time budget before that: kernel 03:23:57,
zygote 03:27:24, `cppreopt did not finish!` after a fixed 100 s wait (first boot only), scan start 03:29:32.
- The system is storage-bound: `/proc/pressure/io` full avg60 = 90%, CPU 60% iowait, zygote/bootanimation in D state.
  USB was a Kingston DataTraveler 3.0 (SuperSpeed, usb-storage) behind a hub, with dm-verity + EROFS on top.
- Not yet known: how long the scan + remaining boot takes, because the owner stopped after ~10 minutes.

Minor items seen (all non-fatal so far): `touchpad-inhibitor: No touchpad device found` (a ChromeOS-style helper
looking for a specific device; the touchpad exists as input10), keymint/gatekeeper HAL SELinux denials on
"unlabeled" root dirs of other partitions (same 35 as in QEMU), `gsc`/`snapshot`/`video_chat` AIDL services missing
(expected: gbrunch masks hardware services), Uprobestats BPF load failures, camera HAL module absent.

### 17.1 Second run: a restart loop (2026-10-15, VERIFIED from `evidence/pixelbook-second-boot-logs/`)
The second boot ran 6,185+ s (snapshots 01-07). It never reached boot completion, and the first-boot scan never
finished: `system_server` and `zygote` restart about every 75 s (80 `init: ... onrestart (<Service 'zygote'>)` entries;
new PIDs at every snapshot). I/O pressure stayed at 75-85% for the whole run (`full avg300` 72-79%), CPU 8% user,
12% sys, 200% iowait, `system_server` in D state, 4.9 GB page cache (so reads are being served from RAM; the
waits are for something else, most plausibly synchronous writes: the drive reports `Write cache: disabled`, /data
is ext4 with `checkpoint=block`, /metadata is `data=journal,commit=1`).
The watchdog is the likeliest killer (`system_server` blocked >60 s repeatedly) but the logcat ring was flooded by a
secondary feedback loop (`No service published for: dropbox` -> `am_wtf` -> DropBox -> same error, ~80,000 lines/s)
so the first cause was overwritten; `userdata` (which keeps /data/system, /data/anr, tombstones) is needed to see it.
ChromeOS on the Pixelbook, other dongle: 512 MiB direct sequential read 37.9 MB/s (a USB 2.0-class rate; the same
stick does 136 MB/s on the PC) and 300 random 4 KiB reads in 2.4 s total: reads are not the problem.

### 17.2 Root cause of the restart loop: /data was full (VERIFIED, `userdata` dump, 2026-10-15)
Reading the `userdata` partition from the second run: free blocks 25,273 of 1,058,810, i.e. 96% full, about 98 MB
free. 3.7 GB of that is `/data/preloads/aicore` (26 files, an on-device AI model dated 2026-04-23). Source: the
`system_b` ("system-other") partition holds `/preloads/aicore` (4,092 MiB across 65 files); on first boot the
platform sets `sys.cppreopt=requested`, `cppreopts.rc` mounts system_b at /postinstall and runs
`/system/bin/preloads_copy.sh`, which `cp -rn`s everything into /data/preloads. The recovery image's userdata is
only 4.1 GiB (a real Googlebook grows it during setup; this image had no such step). Once full, every write fails:
all `/data/anr`, `/data/tombstones` and `/data/system/dropbox` files are 0 bytes, PackageManager cannot persist
its state, system_server dies, zygote restarts (80 times in 6,000 s), and the DropBox/wtf feedback loop floods
logcat. It also explains the first boot's 3.7 GB of extra reads and writes on a USB stick.
Fix (`pixelbook/grow_userdata.py`, step 7 of `build_eve_image.sh`): rename the old entry `userdata_old`, append a new
8 GiB `userdata` after the last partition and format it with ext4 features identical to the filesystem Android's own
mke2fs created on the device (an unformatted partition was NOT auto-formatted by fs_mgr in QEMU, the original one was
because it had been formatted earlier by Android on the device; unexplained difference, so we format ourselves).
QEMU: fs mounts as sda35 with journaled quota, no reformat. Image is 28.76 GB, fits 32 GB sticks (28.87 GiB).
Open: the 3.7 GB AICore copy will still happen once (read 3.9 GB + write 3.7 GB through the USB stick). It is of no
use on this machine; avoiding it would need a change to the first-boot trigger or the system_b contents.

### 17.3 The stick cannot take Android's writes (VERIFIED, owner's benchmark, 2026-10-16)
`pixelbook/windows/bench_usb_write.ps1` on the Kingston DataTraveler 3.0 (unused area, 4 KiB blocks):
random write 0.7-0.8 IOPS (1.2-1.5 s per write, 0.003 MB/s), 64 KiB random flushed write 0.7 IOPS (0.043 MB/s),
1 MiB sequential write 8.2 MB/s. Reads are fine (9 MB/s at 4 KiB random, 136 MB/s sequential; 37.9 MB/s direct on
the Pixelbook through a different USB 2-speed dongle). Any workload that writes small files and syncs them (ext4
journal commits, packages.xml, SQLite, Settings) therefore stalls for seconds per operation, longer than the 60 s
system_server watchdog allows, so the restart loop continues after the /data-full bug (17.2) was fixed: the third
run (new 8 GiB userdata) still looped (owner report: pointer returned to screen centre after ~20 min).
Changes made for the next test: GBRUNCH `/oem` patched by `pixelbook/patch_oem.sh`
- Google's `cppreopts.rc` is no longer imported; a copy without `preloads_copy.sh` replaces it (no 3.7 GB AICore model
  copy, odex copy kept).
- `/data` is a 4 GiB tmpfs (EVE_DATA=ram, default) so no small writes reach the stick; `EVE_DATA=disk` keeps ext4.
- first-stage `/metadata` mount: `commit=30` instead of `data=journal,commit=1`.
QEMU: tmpfs mounts as /data (`__mount(source=tmpfs,target=/data,type=tmpfs)=0`), init continues through post-fs-data.
Consequence: no persistence in this mode (everything in /data is lost at power-off) until storage with usable
random-write performance is used (a USB SSD, or the internal 116 GiB eMMC).

### 17.4 Comparison with linuxkid473/gbos-x86 (gbOS86), reviewed 2026-10-16 (clone at ../gbos-x86, 38 commits)
Claims in its README, not verified by us: Googlebook OS (`lapis`) boots to the desktop with sign-in and Play Store on a
Dell Latitude 5300 (Whiskey Lake i5-8365U, which lacks the same instructions Kaby Lake lacks), from USB or internal NVMe;
Wi-Fi, Bluetooth, sound, touchpad work there. No LICENSE file in the repository (all rights reserved by default), and
`usb/patched/` plus `usb/libkm_compat.so` are modified copies of Google's libraries committed to the repository.
Same ideas as ours: kernel #UD emulator (GFNI, AVX-VNNI, SHA-NI, VAES/VPCLMUL 256, AVX-IFMA) with known-answer tests,
rebuilt android17-6.18 kernel, software Gatekeeper/KeyMint. Different: replaces the boot chain with its own "stage0"
initramfs and its own `super.img`; avoids SHA-NI/Adler hot spots by binary-patching `libcrypto.so`/`libz.so`
(hash-gated) where we recognise the SHA-256 function in the kernel and leave Google's bytes alone; live mode uses tmpfs for
/data and /metadata (as our new RAM mode does); an NVMe installer; hardware auto-detection for other laptops.
Their notes also record: Rust ashmem missing when building without Rust, i915 ignoring HWC gamma tables (kernel patch
"#29") to fix a white veil, vold running fsck on the mounted stick (remove `voldmanaged=usb`), screen density.

## 18. RAM-mode boot works on the Pixelbook; Wi-Fi firmware path bug (2026-10-16)
Owner report (VERIFIED by the owner, no logs yet): with `/data` in RAM and no AICore copy, the Pixelbook boots to
Google's setup flow, which shows the Wi-Fi screen with "IP address / MAC address unavailable".
Cause, from the earlier boots' kernel logs (`evidence/pixelbook-second-boot-logs/startup-kernel.txt`): at 3.83 s
`iwlwifi 0000:01:00.0: Direct firmware load for iwlwifi-7265D-29.ucode failed with error -2 ... no suitable firmware
found!` and the same for Bluetooth (`intel/ibt-hw-37.8.10-fw-22.50.19.14.f.bseq`); i915 only worked because its
firmware is in the initrd. gbrunch's `init.gbrunch.rc` runs `write /sys/module/firmware_class/parameters/path
/oem/firmware` at early-init, replacing the `firmware_class.path=/vendor/firmware` I had put on the command line,
so the files I added to GBVENDOR were never searched. The driver probes once, so no wlan0 existed.
Fix: `patch_oem.sh` now copies the Wi-Fi and Bluetooth firmware into `/oem/firmware` (label `vendor_firmware_file`).
Also noted: `cfg80211: loaded regulatory.db is malformed or signature is missing/invalid` (the world regulatory domain
is used; Wi-Fi still works, 5 GHz is more restricted).
Image rebuilt (`build/pixelbook/pixelbook-googlebook-eve.img`). In RAM mode Wi-Fi credentials and the account do not
survive a reboot.

## 19. Setup works; "isn't responding" dialogs; touchpad jumps (2026-10-16, owner report + `usb-dump5`)
Owner report: on the old-firmware image with /data in RAM, setup completes when signed in manually (phone-assisted
setup failed late with "something went wrong"); the owner's phone detected the Googlebook; Wi-Fi absent (the firmware
fix in 18 was not yet installed, USB tethering over Ethernet worked); "System UI isn't responding" and similar
dialogs for Chrome and others appear often although the UI seems usable; touchpad pointer sometimes jumps to where
the finger lands instead of sliding, and two-finger scroll is unreliable.
Evidence (`evidence/pixelbook-ramdata-boot-logs/`, run 18:13): the Wi-Fi and Bluetooth firmware failures are the old ones.
CPU is saturated during setup: snapshot 03 `400%cpu 135%user 281%sys 19%idle` with `bootanimation` at 230% and
`dex2oat64` compiling gmssystem; snapshot 06 `255%user 48%nice 86%sys 3%idle`, `system_server` at 182%; snapshot 10
(after setup) 396% idle. High *sys* time is consistent with instruction emulation (every trap runs in the kernel); the
per-instruction counters were not logged (profile mode was not used). /data is RAM, so every boot recompiles apps (dex2oat)
and rebuilds caches. The "Close app" button press is visible in the log (`am_process_crashed_too_much ... user request
after error`), so the dialogs are ANRs, not crashes. The audio policy fails (`AudioSystem ... error -19 NO_INIT`, 240
lines), a possible additional cause of UI threads blocking; unproven.
Hypotheses (unproven): (1) CPU saturation = emulation overhead + RAM-mode recompilation + 4 hardware threads on 2
cores; (2) audio binder calls failing/retrying. The touchpad (`ACPI0C50 18D1:5028`, hid-multitouch) likely needs an
Android input device configuration; nothing measured yet.
Changes in the image for the next boot: logger budget 24 MiB -> 160 MiB, 60 snapshots every 30 s instead of 10 every 20 s
(the old budget silently stopped capturing), bigger logcat ring (8 x 4 MiB), and new per-snapshot captures:
`/proc/isa_emu` (trap counters), `dumpsys input`, kernel tail, `/data/anr` traces, plus input devices (`getevent -lp`)
and audio policy at snapshot 02.


## 20. Wi-Fi works; why there is no sound, no swap, no brightness; logger bugs (2026-10-16, owner report + `usb-dump6`)
Owner report on the image with the Wi-Fi/Bluetooth firmware fix: Wi-Fi works; the "System UI isn't responding" dialog is gone
from normal use but came back once while Chrome played a YouTube video (video buggy, no sound); the touchpad pointer still jumps
to where the finger lands; phone-assisted setup still fails with "problem connecting to the other device" (the phone does see the
Googlebook); brightness and Assistant keys do nothing. Logs: `build/pixelbook/usb-dump6` (31 snapshots, 20 min; extracted to
WSL `~/gb/logs/dump6`).

### 20.1 Audio: no sound card at all (VERIFIED)
- `dras` (Google's audio HAL) starts, looks for a card named `sofrt5682` (from `/vendor/etc/data/hal_configs/audio_default.xml`,
  the Lenovo's SOF board), retries 100 times, then runs a stub module: every `AudioSystem` call returns -19 (NO_INIT).
  `/dev/snd` contains only `timer`.
- The Pixelbook has no SOF card. ChromeOS uses the AVS driver (`avs_max98927`, `avs_rt5663`, `avs_rt5514`, HDMI). In our boot the
  AVS and SOF modules load but neither probes (no log line from either).
- Root cause: the shipped kernel config has `# CONFIG_SND_SOC_INTEL_AVS is not set`, so the built-in `snd_intel_dspcfg`
  (`sound/hda/core/intel-dsp-config.c`) takes its `#else /* AVS disabled; force to legacy */` branch for 8086:9d71, and
  `avs_pci_probe` accepts only ANY/SST/AVS. DMI is still "Google Eve/Eve" (RW_LEGACY keeps the stock SMBIOS), so it is not a
  vendor-string problem. Fix with no kernel rebuild: `snd_intel_dspcfg.dsp_driver=4` on the command line (built-in parameter,
  returned verbatim by the probe function).
- Still needed after that (INFERRED, untested): AVS firmware `intel/avs/skl/dsp_basefw.bin` (+ module libraries) and the four
  topologies, taken from the owner's ChromeOS install into `/oem/firmware`; an HAL config for the three-card layout
  (`pixelbook/audio/`: replaces `audio_default.xml`, adds `/vendor/etc/audio/avs_eve/`). Speaker = `hw:avsmax98927,1`,
  headset = `hw:avsrt5663,1` (jack `avs_rt5663 Headset Jack`), internal mic = `hw:avsrt5514,1` (from ChromeOS UCM). Whether dras
  accepts PCMs of several cards is UNKNOWN. `vendor_overlay.py` can replace files (tested: same dirent, new content).

### 20.2 No swap (VERIFIED), memory pressure (VERIFIED)
- `Swap: 0K`. Google's `mmd_setup` builds zram from `/vendor/etc/fstab.zram` (`zramsize=150%`) but `zram.ko`/`zsmalloc.ko` are in
  system_dlkm and nothing loads them in this boot flow. Fix: `insmod` both in `/oem/init.gbrunch.rc` at post-fs-data.
- RAM: MemAvailable 6.2 GB (snapshot 02) -> 3.8 GB (15) -> 1.4 GB (31); Shmem (the 4 GiB tmpfs `/data`) 0.2 -> 1.0 -> 2.6 GB.
  Page cache for the USB-backed system partitions is squeezed, and with dm-verity + EROFS decompression that means kernel
  (sys) time: whole-system CPU split over the last third of the run was user 23%, nice 16%, sys 40%, idle 17%.
- Top CPU users in the busy snapshots (22-28): `com.android.vending:background` at ~100% of a core for most of the run (4:40
  CPU-minutes), `com.google.android.inputmethod.latin` 60%+, `com.google.android.apps.restore`, `dex2oat64` for GMS splits,
  Chrome sandboxed processes. Whether emulated instructions are involved is UNKNOWN: the counters were not readable (below).

### 20.3 The logger lost most of the data (VERIFIED)
- `ulimit -f 8192` in `android_persistlogs.sh` is 4 MiB; `live-logcat.txt` is exactly 4,194,304 bytes (84 s of boot), so logcat died
  of SIGXFSZ at its first rotation; the restart files cover only 17:04-17:06 local. The SystemUI ANR (17:04:21; SystemUI then
  restarted at 17:04:31) is mostly missing. Fixed in `patch_oem.sh`.
- `cat /proc/isa_emu`: `avc: denied { read } ... tcontext=u:object_r:proc:s0` for the shell domain (the file is 0444), and
  `/dev/input/event*` is denied by group (shell lacks `input`). Fixes: image now boots with `isa_emu=profile` (counters and hottest
  sites go to the kernel log every 10 s, captured as `NN-isa-emu.txt`), logger service gets group `input`, and it records a
  touchpad event trace (all events, 12 MB cap) and a function-key-only keyboard trace (letters, digits, punctuation, space,
  enter, modifiers are filtered out so passwords are not logged). New per-snapshot captures: swap/zram, cpufreq/thermal,
  backlight, sound cards and an audio-HAL log.
- Not a problem: `intel_pstate` with HWP is active (CPU frequency is hardware-managed).

### 20.4 Brightness and keys (VERIFIED facts, fix UNTESTED)
- Android shows `mBacklight=null`. The lights HAL (`android.hardware.lights-service.android-desktop`) can drive
  `/sys/class/backlight/intel_backlight` but is gated by `ro.vendor.lights.backlight.enabled`, which Google's Lenovo image sets
  to `false` in `/vendor/build.prop`. The new image sets it to `true` (overlay replaces `build.prop`). Whether i915 registers
  `intel_backlight` on this panel is logged for the next run.
- ChromeOS's kernel input capabilities for the Pixelbook keyboard (`eve-input.txt`) list F1-F12, BACK, FORWARD, REFRESH,
  SYSRQ, MUTE, VOLUME, SEARCH, HOMEPAGE, ASSISTANT; no BRIGHTNESSUP/DOWN. So brightness arrives as a plain function key (or
  an unmapped code) and must be remapped with an Android key layout (`/vendor/usr/keylayout/`, which does not exist yet; the
  framework searches vendor before system). The function-key trace in the next run will show the exact codes.

### 20.5 Touchpad, phone setup, video (UNKNOWN causes)
- Touchpad `ACPI0C50 18D1:5028` is handled by Android's `TouchpadInputMapper` (ChromeOS libgestures, relative motion), the same
  stack as ChromeOS, with normal ranges (13184x8704, 128 units/mm; ChromeOS shows pressure and touch major/minor axes). A
  correct stack should not jump on re-touch, so the suspects are input latency/timestamps under CPU saturation or a gesture
  property difference; only a raw event trace can tell. The new image records one.
- Phone setup: the logcat for that period is among what was lost; Quick Start uses Bluetooth LE and Wi-Fi Direct; no usable
  error found. Re-test with the fixed logger.
- Video: Chrome decodes in software on a saturated CPU; `c2-cros-codecs` logged only seccomp warnings.

### 20.6 The v7 image and what QEMU could and could not check (VERIFIED in QEMU, device untested)
`build/pixelbook/pixelbook-googlebook-eve.img`, SHA-256 `d75de3392c2277eaab295f84c6511e0860ea1237f8abd5cee4c591e4348bf49d` (matches in WSL and
on Windows); the previous image is kept as `...-v6-previous.img`. Contents beyond v6: `snd_intel_dspcfg.dsp_driver=4`, `isa_emu=profile`,
AVS firmware in `/oem/firmware/intel/avs` (11 files from the owner's ChromeOS copy, SELinux label on every directory level), GBVENDOR overlay
(`audio_default.xml` replaced, `etc/audio/avs_eve/*` added, `build.prop` backlight flag true), zram insmod, logger fixes.
QEMU (Skylake-Client, UEFI/GRUB/USB, on a throwaway copy that keeps its logs): boots to zygote/surfaceflinger, 0 SIGILL, 0 panics, 0 module
problems. Confirmed in the guest: dras now reports `primary_soundcard_name: Some("avsmax98927")` (the replaced `audio_default.xml` is read);
`zram`/`zsmalloc` are loaded; `ro.vendor.lights.backlight.enabled=true` and the lights service starts; the logger runs with groups
`...,1004(input),...`, with no stderr, and its keyboard trace starts; `NN-isa-emu.txt` carries the profile.
Not checkable in QEMU (no AVS card, no panel, no touchpad, no boot_completed): AVS probe and firmware, any sound, zram swap actually
activating (`mmd_setup` runs at boot_completed), `intel_backlight`, the touchpad trace.
Profile from the QEMU boot (same userland as on the device, so indicative; the device log will give the real ranking): the hottest sites are
GFNI `gf2p8affineqb` in `linker64+0x9911f` (~830k hits in 800 s), `linker64+0x99306`, `libc.so+0xa06ed`, then SHA-1 in `libcrypto.so+0x130f..-0x1310..`
(`sha1rnds4/nexte/msg1/msg2`, ~600k each; the SHA-1 whole-function fast path from the open items), then AES and PCLMUL. The SHA-256 fast path
covers ~100k calls / 27M blocks. The `NN-kernel-errors.txt` capture times out under load (8 s limit on a large dmesg); harmless.
Tool for the next logs: `tools/analyze_touchpad_trace.py` (jumps of one contact, lift-to-touch gaps, read gaps).


## 21. v7 on the device (usb-dump7, 2026-10-16): touchpad root cause, audio card names, key map, traps (owner report + logs)
Owner report: phone setup (QR) still fails ("problem connecting to the other device" on the phone; the Pixelbook shows only the QR code);
brightness still not changeable; touchpad trace and a press of every top-row key recorded; no sound (settings notification sounds);
"Continue On" cross-device feature unavailable (unknown whether our fault or a Workspace-account limit). Owner decision: keep `/data` in RAM
for now (repeated setups with different accounts) and keep booting from USB. `usb-dump7` is 46 snapshots / 34 minutes with the full touchpad
trace and function-key trace; the logcat ring (8 x 4 MiB) again lost the first 10 minutes.

### 21.1 Touchpad: VERIFIED root cause
`touchpad-events.txt` (164k lines, 293 contacts, analysed with `tools/analyze_touchpad_trace.py`): the first report of every new contact is
a **hover-only frame at exactly the pad centre (6592, 4352)** with `ABS_MT_DISTANCE=1`, no pressure, but `BTN_TOUCH DOWN`; the real position
arrives ~115 ms later (221 "new contact shortly after the previous ended" cases, 127 same-contact jumps up to 5.9k units). 18d1:5028 is
`USB_DEVICE_ID_GOOGLE_TOUCH_ROSE`, which `hid-multitouch` handles with `MT_CLS_GOOGLE` including `MT_QUIRK_HOVERING`: hovering contacts are
reported as contacts (ChromeOS user space ignores distance>0; Android's touchpad mapper does not), so every touch starts at the centre and then
slides to the finger. Fix (kernel, built in, `pixelbook/kernel/apply.sh`): remove `MT_QUIRK_HOVERING` from `MT_CLS_GOOGLE`; without it
`active = tip_state` and the hover frame releases the slot. Second finding: pressure is 0-45 (median 21), 46% of contacts peak below
libgestures' default Tap Minimum Pressure of 25, so light taps would be dropped: `pixelbook/input/Vendor_18d1_Product_5028.idc` sets it to 6.
Untested on the device. INFERRED: no click events (`BTN_LEFT`) were recorded, the pad was used by tapping.

### 21.2 Audio: second root cause (VERIFIED in the log, fix UNTESTED)
The v7 fixes worked as far as they went: `snd_soc_avs` binds 00:1f.3, firmware and topologies load, `/dev/snd` has controlC0/C1 and two capture
PCMs. But the speaker card (`avs_max98927`) fails with `ASoC: failed to register soundcard -16` and the HDMI card with `control ELD already
present` / `-16`; HDMI converters are all "mapped to PCM 0". Cause: `snd_soc_avs` has a module parameter `obsolete_card_names`
(default from `CONFIG_SND_SOC_INTEL_AVS_CARDNAME_OBSOLETE`) which also sets `use_dai_pcm_id = !obsolete_card_names`; with the new behaviour
every DAI link without an explicit id gets PCM 0 (`soc-core.c`). ChromeOS's topologies/UCM (our only ones for this board) assume the obsolete
numbering and card names `avs_<codec>` (the new names are "AVS I2S ALC5663" etc.). Fix: `snd_soc_avs.obsolete_card_names=1` on the kernel
command line (libmodprobe passes `module.param=value` from /proc/cmdline to the module). Then card ids are `avsmax98927`, `avsrt5663`,
`avsrt5514`, exactly what `pixelbook/audio/avs_eve/audio_config.xml` uses. Still UNKNOWN: whether dras accepts PCMs from several cards.

### 21.3 Brightness (VERIFIED facts; fix UNTESTED)
`intel_backlight` exists (`/sys/class/backlight/intel_backlight` -> card0-eDP-1), the lights HAL is called on every slider move
(`setLightState: brightness = 9, scaled brightness 52`) and logs no error, but the node is `root:root 0644` while the HAL and the HWC run as
`system`, and nothing in the image chowns it. INFERRED: the writes fail on permissions. Fix: init `chown system system` + `chmod 0664` on
`brightness` at boot and boot_completed (`patch_oem.sh`). `mBacklight=null` in `dumpsys display` is expected with the SurfaceControl path.

### 21.4 Keys (VERIFIED from `function-keys.txt`)
Pressed in order: Esc -> KEY_ESC, F1..F10 -> KEY_F1..KEY_F10, hamburger -> KEY_F13, side power button -> KEY_POWER. Printed functions
(owner): Back, Refresh, Full screen, Show desktops/overview, Brightness down, Brightness up, Play/pause, Mute, Volume down, Volume up.
`pixelbook/input/make_eve_keylayout.py` derives `AT_Translated_Set_2_keyboard.kl` from the image's own Generic.kl (F1 BACK, F2 REFRESH, F3
FULLSCREEN, F4 RECENT_APPS, F5/F6 BRIGHTNESS_DOWN/UP, F7 MEDIA_PLAY_PAUSE, F8 VOLUME_MUTE, F9/F10 VOLUME_DOWN/UP); it fails the build if
Generic.kl changes shape. F13 is left alone. Consequence: real F1-F10 are not reachable (ChromeOS uses Search+key; Android key layouts have
no chords). Google already ships `AT_Translated_Set_2_keyboard.idc` (keyboard backlight node); the Assistant key (KEY_ASSISTANT 583) is
already `ASSIST` in Generic.kl.

### 21.5 Emulation cost: where the CPU goes (VERIFIED, from `NN-isa-emu.txt`)
34 minutes: **1.67 billion traps** (about 800k per second on average, 3-16M per 10 s), kernel (sys) time 23-45% of all CPU time, one process
(`com.android.vending:background`) used 16 CPU-minutes. By instruction: `sha1rnds4`/`sha1nexte` 333M each, `sha1msg1`/`sha1msg2` 266M each
(1.2 billion, 72%; `libcrypto.so+0x130f..-0x1311..`, BoringSSL's SHA-NI SHA-1 block function), `vpdpwssd` 260M (16%; eight sites in
`libz.so+0x11145..0x111ea`, the Adler-32 loop), `aesenc` 136M + `aesenclast` 15M (VAES 256-bit), `vpclmulqdq` 53M, `gf2p8affineqb` 6.6M.
- libz: gbos-x86-port found the same (about 330k traps/s) and ships a baseline rebuild. Here the Cuttlefish donor's `/system/lib64/libz.so`
  is a drop-in (same soname, same 99 exported symbols, 0 VNNI/GFNI instructions, 134272 bytes). Only two copies matter: `/system/lib64/libz.so`
  and `/vendor/lib64/libz.so` (47 APEX payloads scanned; only the face-unlock HAL bundles its own). v8 replaces the vendor copy through the
  overlay and bind-mounts the donor file over the system one from `/oem/overlay` (`patch_oem.sh`); the build checks soname, symbol superset and
  absence of emulated instructions.
- SHA-1: same structure as the SHA-256 fast path. At the first emulated instruction of the loop (`sha1msg1 xmm5,xmm4` at function+0x6b)
  `xmm0` holds A,B,C,D (reversed dwords), `xmm9` holds E, `rdx` is already decremented, `rsi` points at the next block (or the same one if
  last), state is written back through `rdi` and the function ends with `ret` at +0x27a. Plan (not started): table entry + `isa_fast_sha1`
  using the kernel's `sha1_update`, generator and `fptest` modes, guest test. It removes ~72% of all traps.
- AES (VAES ymm) and PCLMUL are next in size but small by comparison.

### 21.6 Other
- Zram works: 12 GB swap, 1.8 GB used at the end; MemAvailable still falls to 2 GB (4 GiB tmpfs `/data`, Chrome, Play).
- Other images (verified from their vendor partitions, same build 16452207): lapis (ASUS) and moonstone (Acer) set
  `ro.vendor.lights.backlight.enabled=false` as well and use SoundWire audio configs (`sof-soundwire_*`); only ruby uses I2S codecs like the
  Pixelbook. No advantage in switching.
- Phone setup: the attempt falls into the lost part of the logcat. BLE is up (LE address manager registers, "high power advertising
  endpoint" entries); `ch_d2d: isDeviceSupport: false` appears in Settings. Logger now keeps ~1 hour of logcat and captures `pm list
  features`, `dumpsys bluetooth_manager` and `wifip2p` at snapshots 02 and 22. Retry with a clean boot and start the phone setup early.
- Logger: dump7 used 138 MB of the 160 MB budget (dumpsys activity 30 MB, wifi 16 MB, kernel-errors 9 MB); heavy dumps now every 5th
  snapshot, budget 224 MiB, logcat ring 12 x 8 MiB.
- Git: work is on local branch `pixelbook` (never pushed), tag `usb-boot-v7`; `.gitattributes` pins LF for scripts (a Windows-side Python
  edit once turned `patch_oem.sh` into CRLF and broke it in WSL: edit with LF-preserving tools).

### 21.7 The v8 image (VERIFIED in QEMU, device untested)
`build/pixelbook/pixelbook-googlebook-eve.img`, SHA-256 `88e026f00d89d946c3a6b2d320b3000cd3363372d13b62575a76893df886395a` (WSL and Windows
agree); v7 and v6 are kept as `...-v7-previous.img` / `...-v6-previous.img`. Beyond v7: kernel with the touchpad patch (rebuilt in under two
minutes; the image script now always runs the kernel build, before it silently shipped the last bzImage), `snd_soc_avs.obsolete_card_names=1`,
generated keyboard layout, Pixelbook touchpad idc, baseline `libz.so` (vendor overlay + bind mount over `/system/lib64/libz.so`), sysfs backlight
chown, bigger logger budget. QEMU: boots to zygote/surfaceflinger, 0 SIGILL/panics/module problems; guest mount table shows
`/dev/block/sda11 /system/lib64/libz.so ext4 ro`. First attempt failed with `avc: denied { mounton } ... tcontext=system_lib_file` (gbrunch's
policy additions allow `init` mounton only on `system_file`/`vendor_configs_file`); fixed by one allow rule, `init system_lib_file:file mounton`,
listed in `pixelbook/policy/rules.txt` and added to the vendor's precompiled policy by `tools/extend_vendor_policy.c`. That tool needs libsepol
3.11 (Ubuntu's 3.9 rejects the policy: "Invalid policy capability"); `pixelbook/policy/build_policy_tool.sh` builds it from the upstream tarball
(SHA-256 pinned) and the image script runs it when the tool is missing. If the mount fails the system silently uses Google's libz.
Not checkable in QEMU: touchpad, AVS cards, backlight, keys, the effect on the trap rate.


## 22. v8 on the device (usb-dump8, 2026-10-16) and the v9 image: SHA-1 fast path, audio paths, DPCD backlight, no suspend
Owner report on v8: touchpad "WAY better" (hover fix confirmed); brightness and volume keys work (key layout confirmed), but the panel does not
dim; no sound; phone-assisted setup still fails on the phone ("Something went wrong. There was a problem connecting to your other device"; the
Pixelbook keeps showing the QR code); Continue On / app sharing setup says "You're offline" although Wi-Fi works, Quick Share works; touchscreen
works well; camera shows a black picture; Bluetooth lists unexpected devices; closing the lid gives a black screen that only a forced power-off
ends. usb-dump8: 40 snapshots / 26 minutes, full logcat from boot (the larger ring works), libz bind mount active (`/dev/block/sdc11
/system/lib64/libz.so`).

### 22.1 Emulation (VERIFIED)
`vpdpwssd` traps fell from 260M (v7) to 0.67M: the baseline libz works. Remaining: 1.06 billion traps in 26 minutes, of which SHA-1 is 954M
(90%: sha1rnds4/sha1nexte 265M each, sha1msg1/msg2 212M each, all in `libcrypto.so+0x130f4b..0x131098`), AES 77M, PCLMUL 27M, GFNI 3M; kernel time
still 42-44% of all CPU in the busy half. SHA-1 fast path implemented (design in 21.5): `gen_fastpath.py` now also finds the SHA-NI path of
`sha1_block_data_order` and accepts a variant only if its loop head (dec rdx; lea r8,[rsi+0x40]; paddd; cmovne rsi,r8; prefetch; movdqa
xmm8,xmm0) ends at the trap `sha1msg1 xmm4,xmm5`, E is copied to xmm9 exactly before the loop and at the tail, and the tail is paddd xmm0,xmm8;
movdqa xmm9,xmm1; jne <head>; pshufd x2; store; ret. One variant, 25 ELFs (the SHA-256 entry is unchanged, 39 ELFs; the previous table said
40, a counting difference only). Kernel: `isa_fast_sha1` takes A..D from xmm0 and E from xmm9 (valid at every iteration; memory is stale after
the first block), data = rsi-64 unless rdx is 0, blocks = rdx+1, `sha1_update`, stores h[0..4] at rdi, resumes at `ret`; any mismatch or fault
changes nothing. Tests: `fptest` natively on the host (SHA-NI) agrees with the C reference (known answer, 3000 random calls, unmapped tail,
read-only state); in a QEMU guest without SHA-NI both with the fast path (84 MiB/s, all 3169 calls fast) and without (0.097 MiB/s per-instruction
emulation, about 870x slower). The v9 Android boot in QEMU: `fast_sha1=26591 calls/26594 blocks`, no SHA-1 instruction left to emulate,
total traps 1.27M vs 2.9M for v8 on the same test.

### 22.2 Audio (VERIFIED cause, fix UNTESTED)
With `obsolete_card_names=1` all four cards register: card0 HDMI (pcmC0D1p-D3p), card1 avsmax98927 (D1p speaker, D2c), card2 avsrt5663
(D1p/D1c headset), card3 avsrt5514 (D1c mics). dras now finds the primary card and fails with `fail to create internal card avsmax98927:
Failed to read /vendor/etc/audio_config.xml`: it uses `<audio-config-dir>` only when it also knows the board model ("Both card_name, model
should be provided") and otherwise reads `/vendor/etc/{audio_config,mixer_paths,volume_curves}.xml`. v9 installs the same files there.
Still UNKNOWN: whether dras accepts PCMs of other cards in one audio_config.xml (headset, mic).

### 22.3 Brightness (VERIFIED cause, fix UNTESTED)
The permission fix works (lights HAL writes 600, 305, 841 ... of max 1500 without errors; HWC associates `intel_backlight` with display 0) but the
panel does not change: the Pixelbook panel is dimmed over eDP AUX (DPCD). ChromeOS boots EVE with `i915.enable_dpcd_backlight=1`
(`eve-dmesg.txt`); v9 adds it.

### 22.4 Lid / suspend (VERIFIED)
Lid close -> Android sleeps -> `android.system.suspend-service: automatic system suspend enabled` -> the log ends; nothing resumed. v9 holds a
kernel wake lock from boot (`write /sys/power/wake_lock pixelbook_no_suspend`, `EVE_SUSPEND=on` builds without it); the screen still turns off.
No init failure or denial in QEMU. Suspend/resume itself (S3 via coreboot RW_LEGACY, or s2idle) is a separate investigation.

### 22.5 Phone setup, Continue On (VERIFIED facts, INFERRED causes; not fixable in software as far as known)
- Quick Start does start (TargetQuickStartActivity, Nearby advertising over BLUETOOTH and BLE, GATT and L2CAP servers listening), but the
  controller has one LE advertising instance (`LE_GET_VENDOR_CAPABILITIES` unknown to it, no extended advertising): 33 x `allocate_advertiser:
  Number of max instances 1 reached` / `ADVERTISE_FAILED_TOO_MANY_ADVERTISERS`, and setting the long Nearby device name fails at the controller
  (`WRITE_LOCAL_NAME ... INVALID_HCI_COMMAND_PARAMETERS`). INFERRED: the phone cannot complete the connection because of these. A newer Bluetooth
  controller (USB, BT 5.x with extended advertising) is the only fix I can see; not tested.
- Continue On / Cast My Apps: the network is validated (NetworkMonitor 204 on both probes), so "You're offline" is a generic message. KeyMint is
  the software one (`keymint-hal-nonsecure`), keystore2 cannot get an attestation key from RKPD, `TrustedTime.API is not available`. The
  Googlebook-asus project documents the same: companion secure-channel attestation fails, RKPD answers "Device not registered". INFERRED:
  these features need hardware-backed, Google-registered keys and cannot work on this kind of port.
- Camera: the internal camera is USB (UVC 0bda:564b). Google's USB camera HAL opens it and fails at `V4L2Device(BufferAllocation)`; also
  `/data/vendor/camera/cache` cannot be created. Not investigated further.

### 22.6 Feedback loop
- `pixelbook/windows/update_usb.ps1`: updates the stick in place, writing only partitions that differ from the image flashed last time
  (plus the runtime-written ones) and verifying them: v8 -> v9 is 866 MB instead of 27.4 GB (plan computed in 20 s on the host).
- Wireless debugging (adb over Wi-Fi) would allow live logcat and interactive checks without dumping the stick; not tried yet.

v9 image: `build/pixelbook/pixelbook-googlebook-eve.img`, SHA-256 `37e7eaacf728173a2eea4ac17164afc9ab48eb387e41fadd3a2a29b3e5d5004f`; v8 kept as
`pixelbook-googlebook-eve-v8.img` (the `-Base` for the first in-place update).


## 23. v9 on the device, first live session over adb (2026-10-17)
Owner report: brightness works (DPCD backlight confirmed), but the panel flashes to full brightness for a moment on brightness-key presses;
`update_usb.ps1` refused the stick ("does not hold the base image"), so v9 was flashed with Rufus. Wireless debugging enabled: adb from the
Windows host works (`C:\Users\you\platform-tools\adb.exe`, paired once with the 6-digit code; mDNS shows `_adb-tls-connect` at
<device-ip>:<port>). Pushing small scripts to `/data/local/tmp` and running them avoids PowerShell/adb quoting problems. The shell user
reads `/oem/logs` (the logger's GBLOG partition) directly, so boot-time logs are available even after logcat rotated.

### 23.1 Verified live
- SHA-1 fast path on hardware: 328,297 calls / 20.6M blocks handled natively in 34 minutes, no SHA-1 instruction left in the trap counters;
  idle trap rate ~2k per 10 s. Remaining traps during network use: AES-GCM in `libcrypto_httpengine.so` (`aesenc` 296M, `aesenclast` 33M,
  `pclmulqdq` 114M, all VEX-256 forms) - the next whole-function fast-path candidate.
- Swap in use: 3.6 GB of 12 GB zram after 35 minutes.
- Audio: dras now reads `/vendor/etc/audio_config.xml` and fails with `custom: missing field 'IntrinsicSensitivity'` (InternalMic). The schema
  (from `libdras.dylib.so`): AudioConfig{SoundCardName, AudioEffect}; sections Speaker, InternalMic{CapturePCM, IntrinsicSensitivity,
  CaptureChannelMap}, Headphone{JackDev, JackSwitch, ...}, LineOut, Mic{CaptureGainDb}, SCOLineOut/In, USBOutSection, SpeakerDeepBuffer,
  HeadphoneDeepBuffer, Lineout, RearMic, HDMI1-4, USBIn, SpeakerSafe; fields PlaybackPCM, PlaybackMixerElem, DspLatency, PlaybackChannelMap,
  PlaybackRate, UseSoftwareVolume, CaptureChannels, CaptureRate, BeamformingModelPath, InputChannels. Volume curves now load.
- Brightness: each key press produces exactly one lights-HAL write with the right value (42 -> 5396, 27 -> 3469 of max 32767 with DPCD) and
  opens the brightness dialog. Two writers own the backlight since v7 (lights HAL via `ro.vendor.lights.backlight.enabled=true`, and the HWC,
  which associates `intel_backlight` and receives every brightness change through SurfaceControl). INFERRED: the flash is the HWC re-applying
  its own value when the dialog appears. Google's image uses the HWC alone; v10 reverts the property.
- Camera: the USB HAL configures MJPG 1280x720 and fails at `V4L2Device(BufferAllocation)` on every request; the shell cannot open
  `/dev/video*` (SELinux), so a static V4L2 probe (REQBUFS with MMAP/USERPTR/DMABUF) could not run yet.
- `vendor.camera-provider-2-7-legacy-wrapper` is restarted by init every 5 s forever (no camera HAL module); the only crash-looping service.
- `update_usb.ps1`: the check compared the raw primary GPT bytes; something rewrites them after boot (not identified; header fields or
  partition attributes). The script now compares partition entries (name, type, unique GUID, place, size), reports header/attribute
  differences, and always rewrites both partition tables from the new image.

### 23.2 v10 changes
`IntrinsicSensitivity` (-2600, the Lenovo value) in audio_config.xml; lights-HAL backlight left at Google's `false`; SELinux diagnostics rules
(shell may read sysfs_leds, and open/ioctl `/dev/video*`) in `policy/rules.txt`, applied independent of the donor; legacy camera provider
stopped when it is caught restarting.

## 24. v10 freeze, v10b on the device, second live session (2026-10-17)

- **v10 freeze** (usb-dump10, VERIFIED in both runs): the machine stops the moment AudioFlinger opens the speaker output through dras.
  v10b ships a placeholder `/vendor/etc/audio_config.xml` (dras starts its stub module, as in v9) and bind-mounts the real file from
  `/oem/overlay/vendor/etc` on request. Live reproduction over adb (`setprop debug.pixelbook.audio 1`, VERIFIED): mount OK, HAL and
  audioserver restart, last lines 16:46:48.285 `openOutputStream ... bufferSizeFrames: 480` and
  `alsa::driver_controller: get_best_device_for_audio_device ... device=Speaker`; everything (adb, Wi-Fi) stops ~60 ms later, so it is a
  kernel-level hang while the speaker PCM (avsmax98927, 48 kHz, 2 ch) is opened or started. `dmesg -w` is not supported by this toybox
  (it dumps and exits), so no kernel lines from the hang. ChromeOS runs the same AVS firmware/topologies on kernel 6.6 (eve-dmesg.txt);
  its max98927 topology loads the Maxim DSM library (`dsp_lib_dsm_core`) on the DSP (INFERRED suspect, untested).
- **ramoops already works** (VERIFIED, boot log): Google's `chromeos_pstore.ko` binds the GOOG9999 device, `ramoops: using 0x100000@0x7a99a000`.
  v11's second GRUB entry boots with audio on and all lockup detectors set to panic, `panic=10` (overrides gbrunch's `panic=0`); the
  logger copies `/sys/fs/pstore/*` into the next run's folder (`pstore-*.txt`, needs the shell pstorefs dir rule).
- **Camera** (VERIFIED): the webcam (uvcvideo, 0bda:564b) accepts MJPG 1280x720 and REQBUFS MMAP/USERPTR/DMABUF with a static V4L2 probe;
  the camera HAL fails with `V4L2Device(BufferAllocation)` after configuring the same mode. `/dev/dma_heap` does not exist: vendor_dlkm's
  `modules.load` lists `system_heap.ko`, but only alias-matched modules are loaded here (144 of 484). v11 insmods it at `on init`
  (QEMU: the post-fs-data retry reports "File exists", i.e. loaded). Googlebook-asus also carries system_heap.ko. Camera itself untested.
- **Brightness** (VERIFIED): manual 255 -> `intel_backlight` 32767/32767 (hardware maximum); adaptive brightness (cros-ec light sensor) held
  it at 27032. Slider mapping is non-linear (128 -> 28567, 1 -> 1795).
- **Continue On / app casting** (VERIFIED parts): GMS on user 10 has CrossDeviceState ENABLED, Nearby Presence advertising, 0 linked
  devices, MultideviceSyncState DISABLED, DTDI `receiver` delegate "Feature flag is disabled"; Nearby flags
  `connections_dct_validate_remote_device_integrity=true`, `enable_device_integrity_exchange=true`. Play Store's integrity service:
  "Integrity key attestation record generation failed" (`OUT_OF_KEYS_PERMANENT_ERROR`; RKP server: 444 "Device not registered").
  INFERRED: device integrity fails, so the phone side will not link. No legitimate fix (needs factory-registered hardware attestation keys).
- Lid close/open with the wake lock works (owner); Bluetooth scanning/pairing works.

### 24.1 Audio freeze root cause (usb-dump11-audio, ramoops) and the v12 fix
The v11 crash-test entry worked: the boot panicked and rebooted, and the next run saved `pstore-dmesg-ramoops-{0,1}.txt`. VERIFIED:
`traps: UBSAN: unrecognized failure code at avs_path_set_constraint+0x36d/0x510 [snd_soc_avs]`, `Oops: invalid opcode`, in
`binder:441_1` (audio HAL), call chain `avs_dai_startup <- avs_dai_fe_startup <- snd_soc_dai_startup <- __soc_pcm_open <- dpcm_fe_dai_open
<- snd_pcm_playback_open`. The trap site is the clang bounds check on `rlist[i] = ...` (remaining kcalloc size < 4). The function
sizes rlist/clist/slist by the number of paths but stores one entry per I2S/DMIC copier; the Pixelbook speaker topology has more.
Fix (kernel/apply.sh): size by the number of modules. `kernel/build_avs_module.sh` builds snd-soc-avs.ko out of tree with
`CONFIG_SND_SOC_INTEL_AVS=m` and Google's HDA options (`SND_HDA_DSP_LOADER`, `SND_HDA_I915`, `SND_HDA_COMPONENT`, deduced from Google's
snd-hda-core exports; without them the HDA headers stub out firmware loading and change struct hdac_stream), takes CRCs of the 62
vendor-module symbols from Google's module, and gates on identical symbol versions (268), parameters and function list. patch_oem.sh
bind-mounts it over `/vendor/lib/modules/snd-soc-avs.ko` in gbrunch's early-init, which runs before init.rc starts ueventd
(3.983 s vs 4.001 s; ueventd loads the module at 4.8 s). QEMU: mount active, boot unchanged. Device: untested.
Other repos (2026-10-17): OpenBook (Zen 5, AOSP-built) also needed the system DMA-BUF heap; googlebook-continue-on and
googlebook-projects say Continue On needs an Android 17 phone and offer scrcpy mirroring instead; googlebook-anywhere (Alder Lake) uses
software KeyMint too. None addresses attestation.

## 25. v13: internal-disk support, persistent data, installer (2026-10-19, QEMU only so far)

- **Boot disk at boot time** (VERIFIED in QEMU). Android's first stage picks the disk whose `boot_a` partition has the
  PARTUUID in `androidboot.boot_part_uuid`; gbrunch's command line hard-coded the stick's. The menu now computes it:
  GRUB 2.14 prints `$root` as `hd0,gpt12` (no parentheses), `regexp '^[(]?([^,()]+),'` gives the disk, and
  `probe --part-uuid (hdN,gpt13)` the UUID; a fresh-UUID eMMC install booted with its own `5d7b1863-...`.
- **Own GRUB loader.** gbrunch's prebuilt `BOOTX64.EFI` finds its menu by FAT volume serial, which a stick and an
  internal copy share. A `grub-mkstandalone` image does not help: its `$cmdpath` is empty (VERIFIED). A `grub-mkimage`
  core with prefix `/EFI/GBRUNCH` and no device works: GRUB fills in the partition it was loaded from (VERIFIED, USB and
  eMMC under OVMF).
- **eMMC driver in the first stage.** MMC core, block and SDHCI are built in, but the Pixelbook's controller (8086:9d2b)
  needs Google's `sdhci-pci.ko` (+ `cqhci.ko`, `sdhci-uhs2.ko`) from vendor_dlkm, which on an internal install is on the
  eMMC itself. The three are now in the initrd's first-stage list. QEMU 10.2 `-device sdhci-pci -device emmc`: first
  stage loads them, `mmcblk0` shows 35 partitions, all mounts succeed, boot reaches zygote and SurfaceFlinger.
- **/data mode at boot.** `androidboot.gbdata=disk` bind-mounts `/oem/fstab.android-desktop.disk` (gbrunch's fstab
  without the tmpfs line) over the RAM variant in an early-init action placed before gbrunch's own (which binds the
  fstab into /vendor/etc). The installer sets it through `/EFI/GBRUNCH/install.cfg`. Persistence VERIFIED over two
  boots: same filesystem (creation time), same inodes, keystore `persistent.sqlite` kept, no keystore/KeyMint errors.
  gbrunch's userdata has no `fileencryption=`, so /data is not file-encrypted.
- **Installer** (`install/install_to_disk.sh`): same GPT with fresh UUIDs and userdata to the end of the disk; copies
  all partitions except userdata/userdata_old/GBVENDOR_OLD; run-time partitions get pristine state (misc, both
  desktop_security stores and frp_persist are all-zero in the assembled image; metadata is an empty ext4 and GBLOG an
  empty FAT, both stored gzip'ed on the ESP, 66 KB and 261 KB); mke2fs like Android's first boot; read-back
  verification. File-target run: 1 min 46 s for a 64 GiB target. `--update` keeps table, data and run-time state.
- **Installer boot entry**: Google's kernel has no text console (no VT/fbcon), so GRUB shows the explanation and reads
  the confirmation (`read`), then boots our kernel with `installer.gz` (busybox + the build host's bash, util-linux,
  e2fsprogs, mtools, GNU coreutils; Ubuntu 26.04's Rust coreutils are an 11 MB binary per tool, 189 MB in total, so
  the `gnu*` builds are used: 10 MB compressed). Result and log go to the stick's ESP; the stick's menu shows them.
- Audio is on by default again (real `audio_config.xml` in vendor); `androidboot.gbaudio=0` (safe-mode entry)
  bind-mounts the placeholder. Debug SELinux rules for camera/ALSA/backlight removed; pstore read kept for the logger.
- **Headset and microphones**: dras's strings show per-card mixer-path controllers, but "Not supported loading mixer paths
  for sound card" (INFERRED: only the primary card gets mixer_paths.xml). `audio/pbmixer.c` sets ChromeOS's UCM values
  on avsrt5663 and avsrt5514 once the audio HAL runs, as audioserver in the hal_audio_default domain (file label
  hal_audio_default_exec), logging to logcat through /dev/socket/logdw (init's `stdio_to_kmsg` needs a debuggable build).
  All 15 control names and both mux items exist in the 6.18 rt5663/rt5514/AVS board sources (VERIFIED); effect on the
  device untested. QEMU: starts, no SELinux denials, logs "card ... not found" (no cards in QEMU).
- **GRUB pitfalls** found in QEMU: `set default=debug>qemu` is a syntax error without quotes; submenus only see
  `export`ed variables (entries inside got an empty boot UUID and the kernel panicked); `grub-script-check` now runs in
  the build.
- **Logger**: 10 snapshots by default (VERIFIED `SNAPSHOTS 10`), 60 with `gblog=full` (debug entries).
- **Installer speed in QEMU**: emulated SDHCI writes 3-6 MB/s even with KVM; `mke2fs` discarded the whole data partition
  first, which QEMU turns into writing zeros, so the installer formats with `nodiscard` (Android trims during idle).
- **Shared work dir**: another session built `eve-attestation.raw` in `~/gb/gbrunch` at 23:19 and rebuilt the shared
  kernel output; the kernel tree was unchanged (its diff equals kernel/pixelbook-kernel.patch). Builds of this repo now use
  `~/gbp-work` (native.raw hard-linked).
- **Built-in installer, end to end** (VERIFIED in QEMU, KVM, emulated USB stick + empty 64 GiB eMMC, booted exactly as
  the GRUB entry boots it): the init found `/dev/sda` (by boot_a UUID) and `/dev/mmcblk0`, installed, verified, wrote
  `INSTALL SUCCEEDED` with the step log to the stick's `/EFI/GBRUNCH/install-result.txt`, and powered off (4598 s, the
  emulated SDHCI's 3-6 MB/s; a real eMMC and USB stick should take about 10 minutes).
- **Update mode** (VERIFIED in QEMU): "Update the internal eMMC" path on the installed eMMC, from a fresh stick copy:
  system partitions replaced and verified, partition table and UUIDs kept, userdata untouched (same filesystem UUID,
  creation time and entries), `install.cfg` still `gb_data=disk`. Fresh-install eMMC boot also VERIFIED: own boot_a
  UUID, /data on ext4, zygote and SurfaceFlinger. (v13's result line says "INSTALL SUCCEEDED" for updates too; fixed in
  the source for the next build.)
