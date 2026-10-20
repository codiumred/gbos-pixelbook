# Googlebook OS on the 2017 Google Pixelbook

Scripts and kernel patches that build Google's **Googlebook OS** (Android 17 for laptops) for the original
**Google Pixelbook (2017, board EVE, Intel Core i5/i7 Kaby Lake-Y)** and boot it on the real hardware.

Googlebook OS is built for 2024-and-newer CPUs. The Pixelbook's Kaby Lake CPU lacks instructions that Google's
build uses everywhere (GFNI, AVX-VNNI, SHA-NI, wide VAES), its GPU has no driver in Google's kernel, and its audio
DSP trips a bug in Google's audio driver. This project fixes each of those without modifying Google's system
partitions. It builds on [gbrunch](https://github.com/danbyumagic/gbrunch), which runs Googlebook OS on an HP Envy.

> **No Google software is in this repository.** You download Google's official recovery image yourself and the build
> runs on your own machine. The resulting disk image contains Google's software: do not share it.

## Status (October 2026)

Working on the device: boot to desktop, Google sign-in and Play Store, GPU rendering (i915 + Vulkan), Wi-Fi,
Bluetooth, touchscreen, touchpad, keyboard with the top-row keys, screen brightness, webcam, internal speakers.

Internal install with persistent data: available in v13, tested in a virtual machine, not yet on a Pixelbook.

Not working, or limits: Continue On and phone-assisted setup (they need Google-registered hardware attestation keys,
see [docs/STATUS.md](docs/STATUS.md)); suspend (lid close keeps the machine awake); no over-the-air updates.
It is slower than ChromeOS because missing CPU instructions are emulated by the kernel.

Full list: [docs/STATUS.md](docs/STATUS.md).

## How it works

[docs/how-it-works.html](docs/how-it-works.html) is an interactive walk-through (open it in a browser): the layer
stack, the instruction emulator, the boot sequence and the bugs found at each stage. The short version:

| Layer | What this project does |
|---|---|
| Firmware | Boots through MrChromebox's UEFI firmware (RW_LEGACY or full ROM). |
| Kernel | Rebuilds Google's exact kernel source (`android17-6.18-2026-06_r52`) with the same configuration, so Google's 643 prebuilt modules load unchanged, and adds: a trap-and-emulate handler for missing CPU instructions with SHA-256/SHA-1 whole-function fast paths, the i915 graphics driver, a touchpad fix and a fixed AVS audio driver. |
| Drivers | Loads modules Google's image never triggers on this hardware (DMA-BUF heap, zram), adds GPU, Wi-Fi and Bluetooth firmware from linux-firmware and the audio DSP firmware from ChromeOS. |
| Android | gbrunch's compatibility layer (derived vendor partition, software KeyMint), plus Pixelbook audio routing, key map, touchpad tuning, a few SELinux rules and startup tweaks. Google's system partitions stay byte-for-byte unchanged. |

The engineering log with every finding and its evidence is [docs/engineering-notes.md](docs/engineering-notes.md);
[docs/components.md](docs/components.md) describes each script.

## Getting started

1. **Build** the image on a Linux or Windows (WSL2) PC: [docs/BUILD.md](docs/BUILD.md). About 10 GB of downloads,
   130 GB of work space, an hour or more. If you plan to replace ChromeOS, first copy the Pixelbook's audio firmware
   from it (docs/BUILD.md explains how).
2. **Firmware**: MrChromebox's RW_LEGACY or full UEFI ROM, installed from ChromeOS ([docs/INSTALL.md](docs/INSTALL.md)).
3. **Boot it from a 32 GB USB stick** to try it: app data stays in RAM, every boot is a fresh device.
4. **Install it to the internal eMMC** from the stick's boot menu, for a laptop that keeps its apps and data
   ([docs/INSTALL.md](docs/INSTALL.md), section 5). Later versions update it in place from the stick.

## Repository layout

| Path | Contents |
|---|---|
| `build.sh` | Builds everything end to end. |
| `scripts/fetch_inputs.sh` | Downloads and hash-checks Google's recovery, the AOSP Cuttlefish donor, the kernel source and gbrunch. |
| `kernel/` | Kernel changes (`apply.sh`), build script, extra config, the instruction emulator, the rebuilt audio module. |
| `isa_emu/` | Instruction decoder/emulator core shared by the kernel and its differential tests. |
| `image/` | Image assembly: gbrunch base image, kernel/initrd swap, vendor overlay, compatibility partition patches. |
| `audio/`, `input/`, `policy/` | Pixelbook audio configuration, keyboard and touchpad files, SELinux rule additions. |
| `qemu/` | QEMU boot tests (early boot only; QEMU has no usable GPU for Android). |
| `windows/` | PowerShell tools: update a USB stick in place, copy logs off the stick. |
| `tools/` | Analysis tools used during development (instruction scanner, EROFS reader, trace analysers). |

## Credits and licences

See [CREDITS.md](CREDITS.md). Scripts and configuration are MIT-licensed ([LICENSE](LICENSE)). Kernel code and
the instruction emulator (`kernel/`, `isa_emu/`, files marked `SPDX-License-Identifier: GPL-2.0`) are GPL-2.0
([LICENSES/GPL-2.0.txt](LICENSES/GPL-2.0.txt)). Googlebook OS is proprietary Google software and is not covered by
either licence.

This is an independent hobby project, not affiliated with or endorsed by Google, Lenovo or Intel. Flashing
firmware and replacing the operating system can make a device unbootable; you do it at your own risk.
