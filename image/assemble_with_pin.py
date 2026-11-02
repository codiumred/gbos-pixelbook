#!/usr/bin/env python3
"""Run gbrunch's native-image assembler on a different official Googlebook recovery build.

gbrunch's assembler accepts exactly one recovery image: it compares the SHA-256 of the image with a constant
(RAW_HASH in assemble_external_lab.py, build 16452207). That is a sensible guard for a tool that was validated against
one build. Google has since released newer builds, and Google's setup needs the newer one, so this wrapper replaces
only that one constant with the hash this repository pins (scripts/pins.sh) and then runs the assembler unchanged.
Every other check in the assembler still runs: the hashes of its own assets, of Google's kernel binary and of the
modules it builds. If a newer build changes any of those, the assembler stops with a clear message.

  RECOVERY_RAW_SHA=<sha256> python3 assemble_with_pin.py <assembler arguments>      (run in kit/assets)
"""
import os
import pathlib
import sys

assets = pathlib.Path.cwd()
if not (assets / "assemble_native_android.py").is_file():
    sys.exit("assemble_with_pin.py: run it from gbrunch's kit/assets directory")
want = os.environ.get("RECOVERY_RAW_SHA", "").strip().lower()
if len(want) != 64 or any(c not in "0123456789abcdef" for c in want):
    sys.exit("assemble_with_pin.py: set RECOVERY_RAW_SHA to the SHA-256 of the recovery image")

sys.path.insert(0, str(assets))
import assemble_external_lab as lab  # noqa: E402

if lab.RAW_HASH != want:
    print(f"assemble_with_pin: accepting recovery image {want[:12]}... instead of gbrunch's pinned {lab.RAW_HASH[:12]}...",
          flush=True)
    lab.RAW_HASH = want      # must happen before the next import, which copies the name

import assemble_native_android as native  # noqa: E402

native.main()
