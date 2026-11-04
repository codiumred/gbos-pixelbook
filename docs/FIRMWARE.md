# Step 1: Install new firmware on your Pixelbook

The Pixelbook starts with Google's firmware. This firmware only starts ChromeOS. To start Googlebook OS, you must
install new firmware first. [MrChromebox](https://docs.mrchromebox.tech) makes free firmware for the Pixelbook.

> [!WARNING]
> Firmware changes can make a Pixelbook unable to start. Follow each step. Keep the charger connected.
> The steps in this guide come from MrChromebox's documentation and from reports of people with the same Pixelbook.
> If his page and this guide differ, follow his page.

## Choose your firmware

| | **RW_LEGACY** (start here) | **Full ROM** |
|---|---|---|
| What it does | Adds a second boot option. ChromeOS stays. | Replaces the whole firmware. ChromeOS does not start any more. |
| Extra hardware | None. | A **SuzyQ cable** and a **second computer that runs Linux**. Or you open the Pixelbook and disconnect the battery. |
| Write protection | Stays on. You change nothing. | You must turn it off first (see Path B). |
| Each time you turn the Pixelbook on | A warning screen shows. Press **Ctrl+L** to continue. | The Pixelbook starts straight away. |
| Risk | Low. It cannot damage the firmware. Pressing **Space** on the warning screen turns developer mode off and erases the local data. | Low, but a failed flash can stop the Pixelbook from starting. |
| Way back to ChromeOS | Use a ChromeOS recovery USB stick. | Restore your firmware backup, then use a ChromeOS recovery USB stick. |
| Good for | Trying Googlebook OS. Daily use, if you accept the **Ctrl+L** at each start. | Daily use with no warning screen. |

**Not sure?** Use RW_LEGACY. Everything in this project works with it, including the install to the Pixelbook.
You can add the Full ROM later.

> [!IMPORTANT]
> Do the firmware steps **before** you remove ChromeOS. Some of them use tools that only ChromeOS has.

## Before you start

Do each item in this list first:

1. Connect the charger. Use the original Pixelbook charger if you can.
2. Charge the battery to at least 50%.
3. Get the **audio firmware**. The build needs it for sound. You can copy it from ChromeOS or download it from Google. Read
   [the audio firmware section in BUILD.md](BUILD.md#the-audio-firmware).
4. Copy anything else you want to keep from ChromeOS. Developer mode erases the local data.
5. Make a **ChromeOS recovery USB stick** on another computer. It is your way back. Use Google's
   [Chromebook Recovery Utility](https://chromewebstore.google.com/detail/chromebook-recovery-utility/pocpnlppkickgojjlmhdmidojbmbodfm).
6. For the Full ROM only: prepare a **second USB stick** (any size) for your firmware backup.

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

> [!NOTE]
> **The command `gsctool -a -w disable` does not work on the Pixelbook.** It prints
> `Error: CCD info version incorrect (0)` and `Cr50 does not support this operation`. The Pixelbook has a **Cr50**
> security chip, and the error says that this chip does not support the command. MrChromebox lists the command as a method
> for the newer **Ti50** chip. For the Pixelbook (board `EVE`), he lists two methods: the **SuzyQ cable** and
> **disconnecting the battery**.

**Method 1: SuzyQ cable (no need to open the Pixelbook)**

A SuzyQ cable is a USB-C to USB-A debug cable. You also need a **second computer that runs Linux**. A Linux live USB
stick is enough. Reports from other Pixelbook owners say the cable does **not** work when you connect it to the
Pixelbook's own ChromeOS. It works when you connect it to another computer.

1. Open CCD. On the Pixelbook, open VT2 and run this command:

   ```sh
   sudo gsctool -a -o
   ```

2. Each time the screen says `Press PP button now!`, press the **Power** button once. Keep going until the screen
   says `PP Done!`. This takes a few minutes.
3. The Pixelbook restarts in normal mode. Turn on developer mode again (see
   [Turn on developer mode](#turn-on-developer-mode)).
4. Connect the SuzyQ cable. Put the USB-C end in the Pixelbook and the USB-A end in the second computer.
   If the next step shows nothing, flip the plug or use the Pixelbook's other USB-C port.
5. On the second computer, run `ls /dev/ttyUSB*`. You must see `/dev/ttyUSB0`, `/dev/ttyUSB1` and `/dev/ttyUSB2`.
6. On the second computer, run these three commands. They talk to the security chip:

   ```sh
   sudo sh -c 'echo "wp disable" > /dev/ttyUSB0'
   sudo sh -c 'echo "wp disable atboot" > /dev/ttyUSB0'
   sudo sh -c 'echo "ccd reset factory" > /dev/ttyUSB0'
   ```

   (On an old Cr50 version, use `wp false` and `wp false atboot`.)
7. On the Pixelbook, open VT2 and run this command:

   ```sh
   sudo crossystem wpsw_cur
   ```

   The answer must be `0`. The answer `1` means write protection is still on. Do not continue. Check the cable and repeat
   from step 4.

**Method 2: Disconnect the battery (opens the Pixelbook)**

Open the Pixelbook and unplug the battery cable from the mainboard. Then start the Pixelbook on the charger. Write
protection is off while the battery is out. MrChromebox says you need a USB-PD charger of 45 W or more.
Other Pixelbook owners report that the case is hard to open and close again without damage. We do not recommend this
method. See [MrChromebox's guide](https://docs.mrchromebox.tech/docs/firmware/wp/disabling.html) before you try it.

> [!NOTE]
> With Method 1, the command `wp disable atboot` keeps write protection off after a power-off. With Method 2, write protection
> comes back when you reconnect the battery. After you flash the Full ROM, you do not need to turn it on again.

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

- **RW_LEGACY:** Start a ChromeOS recovery USB stick (**Esc+Refresh+Power**). It erases Googlebook OS and installs ChromeOS.
- **Full ROM:** Run MrChromebox's script and choose the option to restore the stock firmware. Use your backup.
  Then use a ChromeOS recovery USB stick.
