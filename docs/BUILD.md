# Building the image

The build runs on Linux or on Windows through WSL2. It was developed on Ubuntu 26.04 under WSL2 on an x86-64 PC.

## What you need

- About **10 GB of downloads** and **130 GB of free disk space** in the Linux file system (not under `/mnt/c` on
  WSL: the kernel build is many times slower there).
- 8 GB RAM or more; the kernel build uses every CPU core.
- The **Pixelbook's audio firmware**, taken from ChromeOS (see below). Everything else is downloaded.

Packages (Ubuntu):

```sh
sudo apt-get install -y build-essential clang lld llvm bc bison flex libelf-dev libssl-dev libdw-dev zlib1g-dev \
  dwarves cpio kmod lz4 zstd erofs-utils e2fsprogs fdisk mtools attr python3 git curl rsync ca-certificates \
  libclang-dev pkg-config qemu-system-x86 qemu-utils nasm grub-common grub-efi-amd64-bin
```

The kernel contains Rust code, so it also needs the Rust version Google built it with:

```sh
curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.91.1 --component rust-src
. ~/.cargo/env
cargo install --locked bindgen-cli --version 0.72.1
```

Tested versions: clang 21.1.8, rustc 1.91.1, bindgen 0.72.1. A different clang may still work; a different rustc
will not (the kernel records its exact version).

**On WSL**, keep a terminal with `wsl.exe` open during the build: WSL stops the Linux VM when no Windows process is
attached, which kills long builds started in the background.

## The audio firmware

The Pixelbook's audio DSP needs Intel's AVS firmware and ChromeOS's topology files for this board. Google ships them in
ChromeOS, not in linux-firmware. Put them in `<inputs>/chromeos/lib/firmware/intel/avs/` before building, one of:

- **From ChromeOS on the Pixelbook** (before you replace ChromeOS): in a ChromeOS developer shell, copy
  `/lib/firmware/intel/avs` with symlinks resolved to a USB stick, e.g. `cp -rL /lib/firmware/intel/avs /media/removable/<stick>/`,
  then place it at `<inputs>/chromeos/lib/firmware/intel/avs`.
- **From the official EVE ChromeOS recovery image**: `scripts/extract_chromeos_firmware.sh <eve recovery .bin> <inputs>/chromeos`
  (untested so far).

Without it the build still succeeds and the system boots, but internal audio is off.

## Build

```sh
git clone <this repository> && cd googlebook-pixelbook
./build.sh
```

`build.sh` runs these steps; each can also be run on its own:

1. `scripts/fetch_inputs.sh` downloads gbrunch at a pinned commit, Google's Lenovo "ruby" recovery (build 16452207),
   the AOSP Cuttlefish build 16373615 and the kernel source (tag `android17-6.18-2026-06_r52`), and checks each
   against a pinned SHA-256 or commit. Reruns reuse what is there.
2. `kernel/apply.sh` applies the kernel changes to the source tree (idempotent).
3. `image/gbrunch_assemble.sh` builds gbrunch's base image from the recovery. This starts gbrunch's isolated tool VM
   under QEMU and takes a while.
4. The shipped kernel configuration is extracted from Google's own kernel on that image.
5. `image/build_eve_image.sh` builds the kernel and the fixed audio module, then produces the Pixelbook image: our
   kernel and initrd, GPU/Wi-Fi/Bluetooth firmware, the vendor overlay (audio, input, SELinux), the compatibility
   partition patches and the boot menu.

Paths can be changed with `WORK=...` (work area, default `~/googlebook-pixelbook`) and `INPUTS=...`.

The result is `$WORK/gbrunch-work/eve.raw` (28.7 GB, sparse). It contains Google's software: keep it to yourself.

## Checks

- `qemu/qemu_eve_uefi_boot.sh <work dir> <log> [seconds]` boots the image under QEMU with a Kaby Lake-class CPU
  model. QEMU has no GPU the Android graphics stack accepts, so it stops after SurfaceFlinger starts; it proves the
  early boot, the module loads and that no missing-instruction faults reach programs.
- `make -C isa_emu/test test` runs the emulator's differential tests on a CPU that has the emulated instructions
  (any recent Intel or AMD), comparing every result with the real hardware.
- The kernel build fails rather than producing a kernel whose symbol versions differ from what Google's modules
  expect, and `kernel/build_avs_module.sh` refuses an audio module that differs from Google's in its imports,
  parameters or function list.
