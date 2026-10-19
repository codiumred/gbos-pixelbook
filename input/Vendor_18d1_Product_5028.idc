# Pixelbook (EVE) touchpad: Google "Rose", I2C-HID 18d1:5028.
# Android reads gestureProp.* into ChromeOS's libgestures. This pad reports pressure 0-45 (median 21 in a
# 20-minute trace), but libgestures' default Tap Minimum Pressure is 25, so about half of all light touches
# could not register as taps. The threshold is set below the typical peak of a real touch.
gestureProp.Tap_Minimum_Pressure = 6.0
