# Step 2: Build the image

You build the image on your own PC. The build downloads Google's official files and combines them with the patches in this
repository. It needs Linux. On Windows, you use WSL2, which runs Linux inside Windows.

The first build takes about 2 hours. A fast PC with a fast disk is quicker.

## What you need

- About **10 GB** of downloads and **130 GB** of free disk space.
- 8 GB of RAM or more. The kernel build uses every processor core.
- Linux (tested: Ubuntu 26.04) or Windows 10/11 with WSL2.
- The Pixelbook's **audio firmware**, copied from ChromeOS (see [below](#the-audio-firmware)).

## Windows only: install Linux (WSL2)

1. Open **PowerShell** as Administrator.
2. Run this command:

   ```powershell
   wsl --install -d Ubuntu
   ```

3. Restart the PC if Windows asks. Open **Ubuntu** from the Start menu. Create a user name and a password.
4. Keep a window open while the build runs. WSL stops Linux when no window is open, and a stopped Linux kills the build.
5. Do all the work **inside the Linux file system** (for example `/root`), not in `/mnt/c`. Builds on `/mnt/c` are many times slower.

## Install the build tools

The build mounts disk images, so it needs root. In Ubuntu, run `sudo -i` and do **all** the following steps in that root shell.

```sh
apt-get update
apt-get install -y build-essential clang lld llvm bc bison flex libelf-dev libssl-dev libdw-dev zlib1g-dev \
  dwarves cpio kmod lz4 zstd erofs-utils e2fsprogs fdisk mtools attr python3 git curl rsync ca-certificates \
  libclang-dev pkg-config qemu-system-x86 qemu-utils nasm grub-common grub-efi-amd64-bin busybox-static
```

The kernel contains Rust code. It needs the exact Rust version that Google used:

```sh
curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.91.1 --component rust-src
. ~/.cargo/env
cargo install --locked bindgen-cli --version 0.72.1
```

Tested versions: clang 21.1.8, rustc 1.91.1, bindgen 0.72.1. A different clang can work. A different Rust version does not,
because the kernel records the exact version.

## The audio firmware

The Pixelbook's audio chip needs firmware files that only ChromeOS has. Copy them **before** you remove ChromeOS.
Without them the build works, but the Pixelbook has no sound.

1. On the Pixelbook, sign in to ChromeOS. **Guest mode** works. ChromeOS mounts a USB stick only after sign-in.
2. Insert a USB stick. Open VT2 (see [FIRMWARE.md](FIRMWARE.md#open-a-command-window)). Find the stick's name with
   `ls /media/removable`.
3. Run this command. Replace `STICK` with the name:

   ```sh
   sudo cp -rL /lib/firmware/intel/avs /media/removable/STICK/
   ```

4. On your build PC, copy the folder `avs` to `<inputs>/chromeos/lib/firmware/intel/avs/`.
   The default `<inputs>` folder is `~/googlebook-pixelbook/inputs`.

Keep a second copy of the folder somewhere safe. After you remove ChromeOS, you cannot get the files again.

## Run the build

```sh
git clone https://github.com/codiumred/gbos-pixelbook.git
cd gbos-pixelbook
./build.sh
```

The result is `~/googlebook-pixelbook/gbrunch-work/eve.raw` (28.7 GB, sparse). It contains Google's software. **Do not share it.**
Continue with [Step 3](INSTALL.md) to write it to a USB stick.

To use other folders, set `WORK=...` (work area) and `INPUTS=...` before you run `./build.sh`.

## What the build does

`build.sh` runs these steps. You can also run each step alone.

1. `scripts/fetch_inputs.sh` downloads and checks Google's recovery image, gbrunch, the AOSP donor image and the kernel
   source. Each file has a pinned hash or commit. A second run reuses the files.
2. `kernel/apply.sh` applies the kernel changes to the source tree. It is safe to run twice.
3. `image/gbrunch_assemble.sh` builds gbrunch's base image from the recovery image. This starts a small virtual machine and
   takes a while.
4. The build reads the kernel configuration from Google's own kernel in that image.
5. `image/build_eve_image.sh` builds our kernel and the fixed audio driver. It then makes the final image: the kernel,
   the first-stage boot files, the firmware, the audio and input files, the security rules, the boot menu and the installer.

## Use a different Google build

Google releases new recovery builds. The pinned build is in `scripts/pins.sh`.

1. Download the new recovery image from Google. Extract the `.bin` file.
2. Calculate its SHA-256 hash.
3. Put the build number, URL and hash in `scripts/pins.sh`.
4. Run `./build.sh` again.

gbrunch's assembler accepts only one image. The script `image/assemble_with_pin.py` replaces that one check with your pinned
hash. All other checks stay: the assembler still checks Google's kernel and its own modules. If a new build changes the kernel,
the build stops with a clear message.

## Checks

- `qemu/qemu_eve_uefi_boot.sh <work dir> <log> [seconds]` starts the image in a virtual machine with a Kaby Lake-like CPU.
  The virtual machine has no usable GPU, so Android stops after SurfaceFlinger starts. The test proves the early start-up,
  the module loading and the instruction emulation.
- `make -C isa_emu/test test` compares the emulator with a real processor. It needs a CPU with the emulated instructions.
- The kernel build stops if a symbol version differs from what Google's modules expect.
  `kernel/build_avs_module.sh` refuses an audio module that differs from Google's in its imports, parameters or functions.
