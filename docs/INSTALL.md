# Step 3: Run Googlebook OS on your Pixelbook

You now have an image file from [Step 2](BUILD.md), and new firmware from [Step 1](FIRMWARE.md). This guide shows two ways to
use the image:

| | **A. Run from a USB stick** | **B. Install to the Pixelbook** |
|---|---|---|
| What happens | The Pixelbook starts from the stick. The Pixelbook's own storage stays as it is. | The installer copies Googlebook OS to the Pixelbook's storage and erases ChromeOS. |
| Your apps and files | Do not survive a restart. Every start is a fresh device. | Survive restarts. |
| Speed | Slow. USB sticks are slow. | Faster. |
| Good for | Trying it. Testing a new image. | Daily use. |
| Needs | A 32 GB USB stick. | The same stick, once. |

Always do **A** first. Install only after A works on your Pixelbook.

---

## Write the image to a USB stick

Use a USB stick with 32 GB or more. **The stick is erased.**

**On Windows**

1. Download and open [Rufus](https://rufus.ie).
2. Insert the USB stick. Check that Rufus shows the right stick under **Device**.
3. Click **SELECT**. Choose the image file. Set the file filter to **All files** if you cannot see it.
   If the file is named `eve.raw`, rename it to `eve.img` first.
4. Click **START**.
5. If Rufus asks, choose **Write in DD Image mode**. Click **OK**.
6. Wait about 10 to 20 minutes. Do not remove the stick until Rufus says **READY**.

**On Linux or macOS**

```sh
sudo dd if=eve.raw of=/dev/sdX bs=16M conv=fsync status=progress
```

Replace `/dev/sdX` with your stick. Check the name twice. The wrong name erases the wrong disk.

**Update a stick later.** The script `windows/update_usb.ps1` writes only the changed parts (about 1 GB instead of 29 GB).
Run it in an Administrator PowerShell:

```powershell
windows\update_usb.ps1 -DiskNumber N -Image <new image> -Base <image now on the stick> -Write
```

Keep the image you flashed. You need it as `-Base` for the next update.

---

## A. Run from the USB stick

1. Turn the Pixelbook off. Insert the stick.
2. Turn the Pixelbook on.
3. Start the stick:
   - **RW_LEGACY firmware:** Press **Ctrl+L** at the warning screen. Then pick the stick from the menu (**Esc** shows it).
   - **Full ROM firmware:** Press **Esc** at the logo. Pick the stick from the boot menu.
4. A menu shows. Choose **Googlebook OS**.
5. Wait. The screen stays black for about a minute. This is normal.
6. The first start and the Google setup take about 20 minutes. Android compiles every app on each start from a stick.

Use the checklist in [TESTING.md](TESTING.md) to check sound, camera, Wi-Fi and the other parts.

### The boot menu

| Entry | What it does |
|---|---|
| **Googlebook OS** | Normal start. |
| **Googlebook OS, safe mode: internal audio off** | Starts without the speaker driver. Use it if sound ever breaks the system. |
| **Install to the internal eMMC** | Installs Googlebook OS to the Pixelbook. Shows only on the stick. |
| **Update the internal eMMC** | Replaces the system on the Pixelbook and keeps your apps and data. Shows only on the stick. |
| **Debug and test options** | Crash capture, suspend tests, full logging. For people who report bugs. |
| **UEFI firmware settings** | Opens the firmware menu. |

---

## B. Install to the Pixelbook (erases ChromeOS)

> [!CAUTION]
> This erases **everything** on the Pixelbook's internal storage, including ChromeOS and all its data.

Check this list first:

- You tested the stick (path A) and it works.
- You have the audio firmware ([BUILD.md](BUILD.md#the-audio-firmware)). Without it the Pixelbook has no sound.
- You installed the firmware you want ([Step 1](FIRMWARE.md)).
- The charger is connected.

Then follow these steps:

1. Start the stick and choose **Install to the internal eMMC**.
2. Read the text on the screen. Type `ERASE` and press **Enter**.
3. Wait 10 to 20 minutes. The screen does not change during the install.
4. **The Pixelbook turns itself off when the install succeeds.** Remove the stick.
5. Turn the Pixelbook on. With RW_LEGACY firmware, press **Ctrl+L**. With the Full ROM, it starts alone.
6. The first start sets up Android like a new device. This takes about 20 minutes.

If the Pixelbook **restarts** instead of turning off, the install failed. Start the stick again. The menu shows
what went wrong. The full log is on the stick at `/EFI/GBRUNCH/install-log.txt`.

### Update an installed system

1. Write the new image to the stick (see above).
2. Start the stick. Choose **Update the internal eMMC**. Type `UPDATE`.

The update replaces the system and keeps your apps, accounts and settings. It works only on a system that this installer
made, with the same partition layout.

<details>
<summary>What the installer does (for developers)</summary>

`install/install_to_disk.sh` writes the stick's partition table to the eMMC with fresh partition IDs. It makes the data
partition fill the rest of the disk. It copies every system partition and reads each copy back to check it. Partitions
that Android writes at run time (metadata, security stores, logs) get pristine contents instead of the stick's state.
It formats the data partition and writes `/EFI/GBRUNCH/install.cfg`, which makes the boot menu keep `/data` on disk.

The same script runs from any Linux live system: `sudo install/install_to_disk.sh <stick> /dev/mmcblk0`.
Add `--update` to keep the data.

</details>

---

## Logs

The system saves logs on a small partition (**GBLOG**). To copy the logs from a USB stick to Windows, run
`windows/dump_usb_logs.ps1 -Out <new folder>` in an Administrator PowerShell. On an installed system, read the logs in
`/oem/logs/Android-Logs/` over wireless adb. The logs never contain what you type. The keyboard trace records only keys
that are not letters, digits or punctuation.
