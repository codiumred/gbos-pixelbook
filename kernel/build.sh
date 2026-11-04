#!/bin/bash
# Build the patched Googlebook kernel (run inside Linux/WSL).
#   kernel/build.sh <kernel tree> <out dir> <shipped .config> [make targets...]
# Method follows fukayatti/gbos-x86-port (kernel/kmake.sh): plain make with LLVM, the
# shipped config, a release string identical to the shipped kernel, and stable
# gendwarfksyms so symbol CRCs match Google's prebuilt modules.
set -euo pipefail
K="${1:?kernel tree}"; O="${2:?out dir}"; CFG="${3:?shipped config}"; shift 3
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SUFFIX="${RELEASE_SUFFIX:--android17-5-g3938c8d97142-ab16302624}"
JOBS="${JOBS:-$(nproc)}"

[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export KBUILD_GENDWARFKSYMS_STABLE=1
export LOCALVERSION=
export KBUILD_BUILD_USER=gb KBUILD_BUILD_HOST=gb KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 2026" KBUILD_BUILD_VERSION=1
MAKE=(make -C "$K" O="$O" ARCH=x86_64 LLVM=1)
if command -v rustc >/dev/null; then
	MAKE+=(RUSTC="$(command -v rustc)" BINDGEN="$(command -v bindgen)"
	       RUST_LIB_SRC="$(rustc --print sysroot)/lib/rustlib/src/rust/library")
fi

mkdir -p "$O"
if [ ! -f "$O/.config" ] || [ "${RECONFIG:-0}" = 1 ]; then
	cp "$CFG" "$O/.config"
	"$K/scripts/config" --file "$O/.config" \
		--set-str LOCALVERSION "$RELEASE_SUFFIX" --disable LOCALVERSION_AUTO \
		--enable X86_ISA_EMU --enable MODULE_SIG_PROTECT_PREBUILT
	# optional extra fragments (drivers for a specific machine), merged in order
	for frag in ${CONFIG_FRAGMENTS:-}; do
		"$K/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$frag" >/dev/null
	done
	"${MAKE[@]}" olddefconfig
	python3 "$HERE/config_diff.py" "$CFG" "$O/.config" | tee "$O/config-delta.txt"
fi
# CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw": Kleaf generates this from the KMI symbol
# lists. Reproduce it: every symbol name from gki/x86_64/symbols/*, one per line, sorted.
awk '!/^[[:space:]]*(\[|#|$)/ { gsub(/[[:space:]]/, ""); print }' "$K"/gki/x86_64/symbols/* | sort -u > "$O/abi_symbollist.raw.new"
cmp -s "$O/abi_symbollist.raw.new" "$O/abi_symbollist.raw" 2>/dev/null || mv "$O/abi_symbollist.raw.new" "$O/abi_symbollist.raw"
rm -f "$O/abi_symbollist.raw.new"

# CONFIG_MODULE_SIG_PROTECT_LIST="protected_module_names_list": build-tree paths (no .ko) of the GKI
# modules. Kleaf derives it from its GKI module list; here it is derived from the module file names
# shipped in system_dlkm (gki_modules.txt) and this build's modules.order, which only exists after
# the compile stage, hence the possible second make pass.
gen_protected() {
	python3 - "$O" "${GKI_MODULES_LIST:-$HERE/gki_modules.txt}" <<'PY'
import pathlib, sys
out, lst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
want = {l.strip().removesuffix(".ko") for l in lst.read_text().split() if l.strip()}
order = out / "modules.order"
paths = [l.strip().removesuffix(".o").removesuffix(".ko") for l in order.read_text().split()] if order.exists() else []
keep = sorted(p for p in paths if p.rsplit("/", 1)[-1] in want)
new = "".join(p + "\n" for p in keep)
f = out / "protected_module_names_list"
if not f.exists() or f.read_text() != new:
    f.write_text(new)
    print(f"protected_module_names_list: {len(keep)} of {len(want)} GKI modules mapped")
PY
}
if [ $# -eq 0 ]; then set -- bzImage modules; fi
gen_protected
before="$(sha256sum < "$O/protected_module_names_list")"
"${MAKE[@]}" -j"$JOBS" "$@"
gen_protected
if [ "$before" != "$(sha256sum < "$O/protected_module_names_list")" ]; then
	"${MAKE[@]}" -j"$JOBS" "$@"
fi
"${MAKE[@]}" -s kernelrelease
