# Credits

This project stands on the work of others. Thank you.

- **[gbrunch](https://github.com/danbyumagic/gbrunch)** (MIT) by danbyumagic: the base this builds on. Its image
  assembler, compatibility partition, derived vendor partition, software KeyMint/Gatekeeper integration, persistent
  logger and SELinux policy tool are fetched at a pinned commit and used unchanged.
- **[gbos-x86-port](https://github.com/fukayatti/gbos-x86-port)** (GPL-2.0) by fukayatti: showed that Googlebook OS
  can run on CPUs without the newer instructions by emulating them in the kernel, and the method for rebuilding
  Google's kernel with matching symbol versions (stable gendwarfksyms). This project's emulator is a separate
  implementation of the same idea.
- **[MrChromebox](https://mrchromebox.tech)**: the UEFI firmware that lets a Pixelbook boot anything but ChromeOS.
- **Android Open Source Project**: the Cuttlefish build used as the source of a baseline zlib, and the kernel source.
- **Linux kernel developers**, in particular the Intel AVS audio driver and i915 graphics driver authors.
- **linux-firmware**: GPU, Wi-Fi and Bluetooth firmware.
- **ChromeOS**: the Pixelbook's audio DSP firmware and topologies (taken from your own device, not redistributed),
  and its audio configuration files, which this project's mixer settings follow.
- Other Googlebook OS ports consulted along the way: [gbos-vm](https://github.com/skylartaylor/gbos-vm),
  [gbos-x86](https://github.com/linuxkid473/gbos-x86), [Googlebook-asus](https://github.com/paulst8/Googlebook-asus),
  [GooglebookOS-ASUS](https://github.com/ReUnknown/GooglebookOS-ASUS), [OpenBook](https://github.com/Mhsbrian/OpenBook),
  [googlebook-anywhere](https://github.com/akari-sora/googlebook-anywhere).

Googlebook OS, Android and Pixelbook are trademarks of Google LLC. This project is not affiliated with Google.
