# Step 1: Install new firmware on your Pixelbook

The Pixelbook starts with Google's firmware. This firmware only starts ChromeOS. To start Googlebook OS, you must
install new firmware first. [MrChromebox](https://docs.mrchromebox.tech) makes free firmware for the Pixelbook.

> [!WARNING]
> Firmware changes can make a Pixelbook unable to start. Follow each step. Keep the charger connected.
> The steps in this guide come from MrChromebox's documentation. If his page and this guide differ, follow his page.

## Choose your firmware

| | **RW_LEGACY** | **Full ROM** (recommended) |
|---|---|---|
| What it does | Adds a second boot option. ChromeOS stays. | Replaces the whole firmware. ChromeOS does not start any more. |
| Write protection | Stays on. You change nothing. | You must turn it off first. |
| Each time you turn the Pixelbook on | A warning screen shows. Press **Ctrl+L** to continue. | The Pixelbook starts straight away. |
| Risk | Low. Pressing **Space** on the warning screen turns developer mode off and erases the local data. | Low, but a failed flash can stop the Pixelbook from starting. |
| Way back to ChromeOS | ChromeOS is still there. | Restore your firmware backup, then use a ChromeOS recovery USB stick. |
| Good for | Trying Googlebook OS from a USB stick. | Daily use as your only operating system. |

**Not sure?** Start with RW_LEGACY. You can install the Full ROM later while ChromeOS is still installed.

> [!IMPORTANT]
> Install the firmware **before** you remove ChromeOS. The firmware tools run inside ChromeOS.

## Before you start

Do each item in this list first:

1. Connect the charger. Use the original Pixelbook charger if you can.
2. Charge the battery to at least 50%.
3. Copy the **audio firmware** from ChromeOS. The build needs it for sound. Read
   [the audio firmware section in BUILD.md](BUILD.md#the-audio-firmware).
4. Copy anything else you want to keep from ChromeOS. Developer mode erases the local data.
5. Prepare a **second USB stick** (any size) to hold your firmware backup.

## Turn on developer mode

Skip this part if your Pixelbook already shows a warning screen about "OS verification is OFF" at start.

1. Turn the Pixelbook off.
2. Hold **Esc** and **Refresh**, then press **Power**. Release all three keys.
3. Press **Ctrl+D** at the recovery screen. Press **Enter** to confirm.
4. Wait about 5 minutes. The Pixelbook erases its local data and restarts.
5. Press **Ctrl+D** at the warning screen, or wait 30 seconds.
6. Wait for the ChromeOS setup or sign-in screen. You do not need to sign in.

## Open a command window

The firmware tools run in a text window called **VT2**.

1. Go to the ChromeOS setup or sign-in screen. Press **Ctrl+Alt+Refresh**. On the Pixelbook, the Refresh key acts as F2.
2. Type `chronos` and press **Enter**.
3. If the window asks for a password, press **Enter** again. The password is empty.

To go back to the normal screen, press **Ctrl+Alt+Back**. (This key acts as F1.)

---

## Path A: RW_LEGACY (no write protection step)

1. Open VT2 (see above).
2. Run this command. It downloads and starts MrChromebox's firmware script:

   ```sh
   cd; curl -LOf https://mrchromebox.tech/firmware-util.sh && sudo bash firmware-util.sh
   ```

3. Choose **Install/Update RW_LEGACY Firmware**.
4. Answer the questions on the screen. Wait until the script says it finished.
5. Restart the Pixelbook. At the warning screen, press **Ctrl+L**. The Pixelbook now starts from the new boot option.

You are done. Continue with [Step 2](BUILD.md) (build the image) and [Step 3](INSTALL.md).

---

## Path B: Full ROM

Part 1 turns off write protection. Part 2 installs the firmware.

### Part 1: Turn off write protection

The Pixelbook has a security chip called **Cr50**. The chip locks the firmware. These commands unlock it. You do not
need to open the Pixelbook or buy a cable.

1. Open VT2 (see above).
2. Run this command to open the chip's settings:

   ```sh
   sudo gsctool -a -o
   ```

3. Watch the screen. Each time it says `Press PP button now!`, press the **Power** button once.
4. Keep going until the screen says `PP Done!`. This takes a few minutes.
5. The Pixelbook restarts in normal mode. Turn on developer mode again (see
   [Turn on developer mode](#turn-on-developer-mode)). This erases the local data again.
6. Open VT2 again.
7. Run this command to turn off write protection:

   ```sh
   sudo gsctool -a -w disable
   ```

8. Press the **Power** button when the screen asks you to.
9. Check the result with this command:

   ```sh
   sudo gsctool -a -w
   ```

   The output must include `Flash WP: forced disabled`. If it does not, do not continue. See
   [MrChromebox's guide](https://docs.mrchromebox.tech/docs/firmware/wp/disabling.html) for other methods.

> [!NOTE]
> Write protection turns back on after a full power-off. This is fine. You only need it off while you flash.
> Do **not** turn the Pixelbook off between Part 1 and Part 2.

### Part 2: Install the firmware

1. Insert the **backup USB stick**.
2. Run this command in VT2:

   ```sh
   cd; curl -LOf https://mrchromebox.tech/firmware-util.sh && sudo bash firmware-util.sh
   ```

3. Choose **Install/Update UEFI (Full ROM) Firmware**.
4. When the script offers to **back up your stock firmware**, say yes. Save it to the USB stick.
5. Wait until the script says it finished. Do not turn the Pixelbook off.
6. **Copy the backup to your PC.** It is your way back to ChromeOS. It contains data that belongs to your device,
   so do not share it.
7. Restart the Pixelbook.

> [!CAUTION]
> If the flash fails, do **not** restart. Use the script's restore option and your backup.

### What you see after the flash

- ChromeOS does not start any more. This is normal.
- With no USB stick, the Pixelbook shows a boot screen with no operating system.
- Press **Esc** at the logo to see the boot menu and choose your USB stick.

Continue with [Step 2](BUILD.md) (build the image) and [Step 3](INSTALL.md).

---

## Go back to ChromeOS

- **RW_LEGACY:** Erase the Googlebook OS install. Then start a ChromeOS recovery USB stick. Make one with Google's
  [Chromebook Recovery Utility](https://chromewebstore.google.com/detail/chromebook-recovery-utility/pocpnlppkickgojjlmhdmidojbmbodfm).
- **Full ROM:** Run MrChromebox's script and choose the option to restore the stock firmware. Use your backup.
  Then use a ChromeOS recovery USB stick.
