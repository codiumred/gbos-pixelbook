# Status

Tested on one Pixelbook (2017, i5-7Y57, 8 GB, board EVE) with Googlebook OS build 16452207 (Lenovo "ruby"
recovery, Android 17). "Verified" means seen on the device or in its logs.

## Works (verified on the device)

| Area | Notes |
|---|---|
| Boot, setup, Google sign-in, Play Store | First boot and setup take about 20 minutes from a USB stick. |
| Graphics | i915 + Vulkan (ANV) on HD Graphics 615. |
| Wi-Fi, Bluetooth | Intel 7265. Bluetooth pairs with speakers, TVs, phones. |
| Touchscreen, touchpad | Touchpad needed a kernel fix (it reported a phantom touch at the centre before every real touch). |
| Keyboard, top-row keys | Back, refresh, full screen, overview, brightness, play/pause, volume. |
| Screen brightness | Over the panel's DPCD (eDP AUX) channel, like ChromeOS. |
| Webcam | Needed the DMA-BUF system heap module, which nothing loaded on this hardware. |
| Speakers | Needed a fix in Google's AVS audio driver (array overrun that froze the machine). |
| Lid close/open | The screen turns off and the lock screen appears; the machine stays awake (see Suspend). |
| Quick Share | Works. |

## Does not work

| Area | Why |
|---|---|
| Continue On (phone app streaming) | The phone checks the laptop's Play Integrity verdict. That needs hardware attestation keys registered with Google at the factory; this build uses a software key store (from AOSP), whose keys Google's server rejects ("Device not registered"). Not fixable without faking attestation, which this project will not do. |
| Phone-assisted setup | Fails to connect to the phone. Likely the Bluetooth controller cannot advertise twice at once (inferred). Manual sign-in works. |
| Suspend | Closing the lid let Android suspend the machine and it never resumed, so suspend is blocked with a wake lock. The battery drains with the lid closed. |
| Over-the-air updates | None. Updating means rebuilding and reflashing. |
| Persistence | App data lives in RAM by default, so each boot is a fresh device. Internal-disk install with persistent data is planned. |

## Not tested yet

Headphone jack, microphones, HDMI audio over USB-C, stylus, external displays, battery life.

## Performance

Missing CPU instructions are emulated by the kernel. The worst cases (SHA-256 and SHA-1 hashing, zlib checksums)
have fast paths or a replacement library; what remains is mostly GFNI and wide AES. Expect noticeably slower app
start-up than on ChromeOS, especially during the first setup when apps are compiled.

## Security

Weaker than a stock Googlebook: the boot chain is unlocked (verified boot state "orange"), keys live in a software key
store, and the image adds a few SELinux rules. Do not rely on it for sensitive data.
