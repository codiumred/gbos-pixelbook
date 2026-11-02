# Testing a new image on the Pixelbook

A checklist for each new version, in an order that never risks data before the stick-based checks pass. Copy the
logs off the stick afterwards (`windows/dump_usb_logs.ps1`), or read them live over wireless adb
(`/oem/logs/Android-Logs/`).

## From the USB stick (nothing on the Pixelbook changes)

1. **Boot menu**: the entries in docs/INSTALL.md appear; "Debug and test options" opens a submenu.
2. **Normal boot** reaches setup or the desktop.
3. **Sound**: speaker (video volume changes the loudness), **headphone jack** (plugging in moves sound to the
   headphones), **internal microphone** and **headset microphone** (Recorder app). `pbmixer` reports in logcat
   (`logcat -s pbmixer`): every control it set, or which one failed.
4. **Camera**, **Wi-Fi**, **Bluetooth**, **brightness keys**, **touchpad**: as before.
5. **Safe mode** entry: boots with internal audio off.

## Firmware (once, from ChromeOS)

See [FIRMWARE.md](FIRMWARE.md). After flashing, boot the stick again with Esc instead of CTRL+L and repeat step 2.

## Suspend (optional, from the stick)

"Debug and test options" -> "Suspend test, S3 (deep)", then close the lid for 30 s and open it. Then the same with
"s2idle". Note for each: did it sleep (power light), did it wake on lid open or a key press, did the screen come back.
If it hangs, press Refresh+Power, boot the stick normally and copy the logs: the failed resume is in
`pstore-console-ramoops-0.txt`.

## Internal install

1. Stick menu -> "Install to the internal eMMC", type `ERASE`. It powers off when done (10-20 minutes).
2. Remove the stick, power on: the first boot from the eMMC sets up Android (about 20 minutes).
3. Sign in, install an app, restart: the app and the sign-in are still there.
4. Optional: build a newer image, write it to the stick, boot it, "Update the internal eMMC", type `UPDATE`; the
   app and sign-in survive.
