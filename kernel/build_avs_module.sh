#!/bin/bash
# Build snd-soc-avs.ko (Intel AVS audio DSP driver: Skylake/Kaby Lake) from the patched kernel tree, as an
# external module against the rebuilt kernel, to replace Google's prebuilt copy in vendor_dlkm (see the
# avs_path_set_constraint fix in apply.sh). Run inside Linux/WSL after kernel/build.sh.
#   kernel/build_avs_module.sh <kernel tree> <out dir> <Google's snd-soc-avs.ko> <work dir>
# Result: <work dir>/snd-soc-avs.ko. The kernel tree does not build AVS itself (CONFIG_SND_SOC_INTEL_AVS is unset in
# Google's config; the module comes from a separate vendor build), so the sources are copied out and built with
# CONFIG_SND_SOC_INTEL_AVS=m. Symbols exported by Google's other vendor modules (snd-hda-*, snd-soc-hda-codec) are
# not in this kernel's Module.symvers; their CRCs are taken from the versions Google's own build of this module
# recorded, so the result links against exactly the modules Google ships.
set -euo pipefail
K="${1:?kernel tree}"; O="${2:?out dir}"; G="${3:?Google snd-soc-avs.ko}"; W="${4:?work dir}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/apply.sh" "$K" >/dev/null
grep -q "pixelbook: one slot per module" "$K/sound/soc/intel/avs/path.c"

rm -rf "$W"; mkdir -p "$W/src/sound/soc/intel/avs" "$W/src/sound/soc/codecs"
cp "$K"/sound/soc/intel/avs/*.[ch] "$W/src/sound/soc/intel/avs/"
cp "$K/sound/soc/codecs/hda.h" "$W/src/sound/soc/codecs/"	# included as ../../codecs/hda.h
# the module only; the machine boards (separate modules) stay Google's
grep -v "boards/" "$K/sound/soc/intel/avs/Makefile" > "$W/src/sound/soc/intel/avs/Makefile"

modprobe --dump-modversions "$G" | awk -F'\t' 'NR == FNR { have[$2] = 1; next }
	!($2 in have) { printf "%s\t%s\tgoogle_vendor_module\tEXPORT_SYMBOL_GPL\t\n", $1, $2 }' "$O/Module.symvers" - > "$W/google.symvers"
echo "symbols from Google's vendor modules: $(wc -l < "$W/google.symvers")"

[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export KBUILD_GENDWARFKSYMS_STABLE=1 LOCALVERSION=
export KBUILD_BUILD_USER=gb KBUILD_BUILD_HOST=gb KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 2026" KBUILD_BUILD_VERSION=1
# The HDA options AVS selects are off in the GKI config but on in Google's vendor build: its snd-hda-core.ko exports
# snd_hdac_dsp_*, snd_hdac_i915_* and snd_hdac_acomp_*. Without them the headers turn those calls into empty stubs
# (no firmware loading) and struct hdac_stream loses a DSP_LOADER field, so they must match Google's build exactly.
HDA_CFG="-DCONFIG_SND_HDA_DSP_LOADER=1 -DCONFIG_SND_HDA_I915=1 -DCONFIG_SND_HDA_COMPONENT=1"
make -C "$K" O="$O" ARCH=x86_64 LLVM=1 M="$W/src/sound/soc/intel/avs" CONFIG_SND_SOC_INTEL_AVS=m \
	KCFLAGS="$HDA_CFG" KBUILD_EXTRA_SYMBOLS="$W/google.symvers" -j"$(nproc)" modules 2>&1 | tee "$W/build.log" | grep -E "WARNING|error|undefined" || true
cp "$W/src/sound/soc/intel/avs/snd-soc-avs.ko" "$W/snd-soc-avs.ko"

# gates: every symbol Google's module imports has the same CRC in ours, nothing extra is imported, and the
# module parameters (obsolete_card_names is set on the command line) are unchanged
modprobe --dump-modversions "$G" | sort > "$W/versions.google"
modprobe --dump-modversions "$W/snd-soc-avs.ko" | sort > "$W/versions.ours"
if ! diff "$W/versions.google" "$W/versions.ours" > "$W/versions.diff"; then
	echo "symbol versions differ from Google's module:"; head -20 "$W/versions.diff"; exit 1
fi
diff <(modinfo -F parm "$G" | sort) <(modinfo -F parm "$W/snd-soc-avs.ko" | sort)
# same functions compiled in (catches a source file or config branch that Google's build had and this one lacks)
nm "$G" | awk '$2 ~ /^[Tt]$/ {print $3}' | sed 's/\.[a-z]*\.[0-9]*$//' | sort -u > "$W/funcs.google"
nm "$W/snd-soc-avs.ko" | awk '$2 ~ /^[Tt]$/ {print $3}' | sed 's/\.[a-z]*\.[0-9]*$//' | sort -u > "$W/funcs.ours"
if ! diff "$W/funcs.google" "$W/funcs.ours" > "$W/funcs.diff"; then
	echo "function lists differ from Google's module:"; head -20 "$W/funcs.diff"; exit 1
fi
echo "snd-soc-avs.ko: $(sha256sum < "$W/snd-soc-avs.ko" | cut -c1-16)..., $(wc -l < "$W/versions.ours") symbol versions identical to Google's"
