# Questions and answers

## Before you start

**Can I download a ready-made image?**
No. The image contains Google's software, and Google does not allow us to share it. The build script downloads Google's
official files and makes the image on your PC. See [BUILD.md](BUILD.md).

**Is this safe for my Pixelbook?**
The risk is low but real. A firmware change can stop the Pixelbook from starting. Path 1 in the [README](../README.md)
(RW_LEGACY and a USB stick) is the safest. It does not touch ChromeOS. The Full ROM replaces the firmware. Keep the backup
that MrChromebox's script offers.

**Do I need to open my Pixelbook, or buy anything?**
No, not for Path 1 or Path 2. RW_LEGACY needs no hardware and no write-protection step. Only the optional Full ROM needs a
SuzyQ cable and a second Linux computer, or you open the Pixelbook and disconnect the battery. See [FIRMWARE.md](FIRMWARE.md).

**The command `gsctool -a -w disable` printed "Cr50 does not support this operation".**
This is normal on the Pixelbook. Its Cr50 chip does not support that command. Use RW_LEGACY (no write protection step), or use
the SuzyQ method in [FIRMWARE.md](FIRMWARE.md#part-1-turn-off-write-protection).

**Can I go back to ChromeOS?**
Yes. See [Go back to ChromeOS](FIRMWARE.md#go-back-to-chromeos). Make a ChromeOS recovery USB stick on another computer first.

**Can I run Googlebook OS and ChromeOS together (dual boot)?**
Not supported. The installer erases the whole internal storage. You can keep ChromeOS and run Googlebook OS from a USB stick.

**Does this work on other Chromebooks, for example the Pixelbook Go?**
Unknown. This project only targets the 2017 Pixelbook (board `EVE`). Other Kaby Lake and Amber Lake Chromebooks may work with
changes to the audio, input and graphics settings. We have not tried them.

**Is this affiliated with Google?**
No. It is a hobby project.

## Using it

**Why is it slow?**
The Pixelbook's processor does not have some instructions that Googlebook OS uses. The kernel runs them in software, which is
slower. The first start after an install is the slowest, because Android compiles all apps.

**Why are my apps gone after I restart (USB stick)?**
When you run from a USB stick, app data lives in memory. A USB stick is too slow to hold it. Install to the Pixelbook to keep
your data.

**Why does Continue On not work?**
Continue On needs the laptop to prove to your phone that it is a genuine Googlebook. That proof comes from a security key
that the manufacturer registers with Google at the factory. The Pixelbook does not have one. This project does not fake it.

**Why does the phone-assisted setup fail?**
It probably fails because of the Pixelbook's Bluetooth chip, which cannot do two jobs at the same time. We have not proved
this. Sign in with your Google account on the screen instead. That works.

**Can I update it?**
There are no over-the-air updates. To update, build a new image and use **Update the internal eMMC** from the USB stick
([INSTALL.md](INSTALL.md#update-an-installed-system)). The update keeps your apps and data.

## Problems

**The screen stays black after I pick Googlebook OS.**
Wait about 2 minutes. The first start is slow, and the screen stays black until Android draws.

**The installer restarts the Pixelbook instead of turning it off.**
The install failed. Start the USB stick again. The menu shows the reason. The full log is in `/EFI/GBRUNCH/install-log.txt`
on the stick.

**I pressed Space on the warning screen and now I see a recovery screen.**
You turned developer mode off. With ChromeOS gone, the Pixelbook asks for a recovery USB stick. Make a ChromeOS recovery stick on
another computer, or install the Full ROM so the warning screen does not show.

**The sound stopped or the Pixelbook froze.**
Start the **safe mode** entry in the boot menu. It turns off the audio driver. Report the problem with logs
([TESTING.md](TESTING.md)).

**How do I report a bug?**
Open an issue on GitHub. Say which build you use, what you did and what happened. Add the log files if you can.
