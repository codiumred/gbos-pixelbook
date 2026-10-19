# Booting and installing on the Pixelbook

Read this whole page first. Replacing a Chromebook's firmware or operating system can leave it unbootable, and the
recovery tools differ depending on which firmware route you take.

## 1. Firmware: two routes

The Pixelbook's stock firmware only boots ChromeOS. [MrChromebox](https://docs.mrchromebox.tech) provides UEFI
firmware for it (board name **EVE**). Both routes below have been used with this project.

| | RW_LEGACY | Full UEFI ROM |
|---|---|---|
| What changes | Adds a UEFI boot payload next to ChromeOS's firmware | Replaces the whole firmware |
| Write protection | Stays on | Must be disabled first ([MrChromebox: disabling write protection](https://docs.mrchromebox.tech/docs/firmware/wp/disabling.html); on EVE it is controlled by the Cr50 security chip) |
| Every boot | Developer-mode warning screen, press **CTRL+L** | Boots straight from the selected disk |
| Risk | Pressing Space on the warning screen starts a wipe back to ChromeOS | Small risk of an unbootable device during flashing; keep the stock-firmware backup the script offers |
| Going back to ChromeOS | ChromeOS is still there | Restore the stock firmware backup, then a ChromeOS recovery USB |

Both are installed with MrChromebox's firmware utility script, run from a ChromeOS developer shell (VT2, after
enabling developer mode). Follow [MrChromebox's instructions](https://docs.mrchromebox.tech/docs/getting-started.html).
**Do the firmware step while ChromeOS is still installed**: the script and the write-protection tools run from it.

If you choose the full ROM: when the script offers to back up the stock firmware, save the backup to a USB stick and
copy it to another computer. It contains your device's own data (serial number, hardware ID) and is the only way back
to stock firmware without special hardware.

### Disabling write protection on EVE without opening it

The Pixelbook's write protection is held by its Cr50 security chip. From ChromeOS, without a cable or disassembly
([MrChromebox: gsctool method](https://docs.mrchromebox.tech/docs/firmware/wp/disabling.html)), keeping the charger
connected throughout:

1. In developer mode, open VT2 (CTRL+ALT+F2, or CTRL+ALT+→ on the top row), log in as `chronos`.
2. `sudo gsctool -a -o`, then press the power button each time it says "Press PP button now!" (a few minutes of
   prompts). It ends with "PP Done!" and the Pixelbook reboots into verified mode: enable developer mode again
   (this wipes ChromeOS's user data) and return to VT2.
3. `sudo gsctool -a -w disable`, press the power button when asked.
4. Check: `sudo gsctool -a -w` must print `Flash WP: forced disabled`.
5. Without powering off, run MrChromebox's firmware utility script, pick **Install/Update UEFI (Full ROM) Firmware**
   and save the stock firmware backup when asked.

This disable lasts until the security chip next reboots (a full power-off). That is fine: it only has to hold until
the flash is done. After the full ROM is installed, ChromeOS's `gsctool` is gone with ChromeOS.

## 2. Write the image to a USB stick

Use a 32 GB USB stick (the image is 28.7 GB). A faster stick helps, but app data lives in RAM by default anyway,
because cheap sticks manage less than one random write per second.

- **Windows**: [Rufus](https://rufus.ie), select the `.img`/`.raw` file, choose **DD image** mode when asked.
- **Linux**: `sudo dd if=eve.raw of=/dev/sdX bs=16M conv=fsync status=progress` (check the device name twice).

Later updates only need the partitions that changed: `windows/update_usb.ps1 -DiskNumber N -Image <new image>
-Base <image currently on the stick> -Write` (Administrator PowerShell) writes about 0.9 GB instead of 28.7 GB and
verifies what it wrote. Keep the image you flashed: it is the `-Base` for the next update.

## 3. Boot

Plug the stick in, power on, then:

- RW_LEGACY: press **CTRL+L** at the developer-mode screen, then pick the USB stick in the boot menu (Esc).
- Full ROM: press **Esc** at the logo for the boot menu and pick the USB stick.

GRUB shows three entries:

1. **Googlebook OS on Pixelbook** - the normal boot.
2. **Audio crash test** - turns on every lockup detector and makes the system reboot itself after a freeze, so the
   kernel's last messages survive in RAM (ramoops) for the next boot's logs. Only for debugging.
3. **Serial console (QEMU)** - for virtual machine tests.

The screen stays black until Android draws, about a minute. The first boot and setup take around 20 minutes on a
USB stick: app data is in RAM, so Android compiles apps on every boot and nothing persists between boots. That is
by design for now: each boot is a fresh device, convenient for trying different accounts.

## 4. Logs

The image keeps logs on its own small partition (GBLOG). On Windows, `windows/dump_usb_logs.ps1 -Out <new folder>`
(Administrator PowerShell) copies them off the stick. The logs never contain what you type: the keyboard trace only
records keys that are not letters, digits or punctuation.

## 5. Installing to the internal eMMC

Not available yet. It is the next planned step: persistent app data on the internal disk and an updater that keeps
your data. Until then the USB stick is the way to run it.
