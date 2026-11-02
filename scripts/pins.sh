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
