#!/bin/bash
# Build gbrunch's tools/extend_vendor_policy.c against libsepol 3.11. Ubuntu's libsepol (3.9) rejects the Android 17
# policy ("Invalid policy capability"), so the library is built from the upstream release tarball, whose
# SHA-256 is pinned below. Run inside Linux/WSL.
#   policy/build_policy_tool.sh <output binary> <gbrunch checkout>
set -euo pipefail
OUT="${1:?output binary}"; GB="${2:?gbrunch checkout}"
VER=3.11
SHA256=79f3d2c88f44b7eb5cf54d9792e03232297e17f97a179163f2750099a00f164d
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

curl -sSfL --retry 3 -o "$TMP/libsepol.tar.gz" "https://github.com/SELinuxProject/selinux/releases/download/$VER/libsepol-$VER.tar.gz"
echo "$SHA256  $TMP/libsepol.tar.gz" | sha256sum -c - >/dev/null
mkdir "$TMP/src" && tar -xzf "$TMP/libsepol.tar.gz" -C "$TMP/src" --strip-components=1
make -C "$TMP/src/src" -j"$(nproc)" libsepol.a >/dev/null 2>&1
mkdir -p "$(dirname "$OUT")"
gcc -O2 -I "$TMP/src/include" -o "$OUT" "$GB/tools/extend_vendor_policy.c" "$TMP/src/src/libsepol.a"
echo "built $OUT (libsepol $VER)"
