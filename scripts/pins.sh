# Pinned versions of the Google software this build starts from. Sourced by scripts/fetch_inputs.sh and
# image/gbrunch_assemble.sh. Change the recovery build in one place: here.
#
# Googlebook recovery image (Lenovo "ruby"):
#   build 16658739 = CL3B.260622.276.R4, Android 17, SDK 37.1, security patch 2026-10-01, built 2026-10-20.
#   The raw image is the pin that matters (extracting it from the ZIP is deterministic). The ZIP hash stays empty until
#   someone has hashed the official download; then it is checked too.
#   Previous build: 16452207 = CL3B.260622.271.R1, raw 4f4490415d4db0721fa99ad10abd64b1b05c284b6c0e413907da948561de8c9e
RECOVERY_BUILD=16658739
RECOVERY_URL=https://dl.google.com/device/recovery/ruby-user/16658739/recovery.zip
RECOVERY_ZIP_SHA=
RECOVERY_RAW_SHA=805de2e7251b2ec0c2089af0fe8f0547c386a58e8c5e24614d506697456837db

# ChromeOS recovery image for the Pixelbook ("eve"), used only by scripts/extract_chromeos_firmware.sh to get the audio DSP
# firmware (/lib/firmware/intel/avs) when you cannot copy it from a running Pixelbook.
#   ChromeOS 16700.68.0 (LTS channel). Builds before about 16000 (for example the 15886 "stable" one) still use the old
#   dsp_fw_kbl audio driver and have no intel/avs directory. Google's list of recovery images:
#   https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json
#   EVE_AVS_SHA is the SHA-256 of the sorted per-file hashes of the extracted tree (the pin that matters; it was checked
#   against the files copied by hand from a real Pixelbook).
EVE_RECOVERY_URL=https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_16700.68.0_eve_recovery_lts-channel_EveMPKeys-v11.bin.zip
EVE_RECOVERY_ZIP_SHA=4e9329391eb625ee365ee1f8cf00fe916ae37467bf02116d0b1a8a6fdfdbb3d8
EVE_AVS_SHA=4f595c6ca39f1c85d93406608c994cd8ec3da72f3d68fea878f70cabee3698ef
