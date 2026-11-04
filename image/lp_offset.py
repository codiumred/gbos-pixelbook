#!/usr/bin/env python3
"""Print "<byte offset> <size>" of a logical (dynamic) partition inside an image's super partition.

  lp_offset.py <image> <logical partition>      e.g. eve.raw system_a   or   donor super.raw system_a

The image is either a disk image with a GPT partition named "super" or a bare super image. Reads the
liblp metadata with gbrunch's tools/inspect_recovery.py (found through $GBRUNCH_TOOLS, which build_eve_image.sh
sets to the pinned gbrunch checkout) instead of relying on offsets copied from an earlier run.
"""
import os, pathlib, sys

_root = pathlib.Path(__file__).resolve().parent.parent
for _d in [os.environ.get("GBRUNCH_TOOLS", ""), str(_root / "inputs/gbrunch/tools"),
           str(pathlib.Path.home() / "googlebook-pixelbook/inputs/gbrunch/tools")]:
    if _d and (pathlib.Path(_d) / "inspect_recovery.py").is_file():
        sys.path.insert(0, _d)
        break
else:
    sys.exit("lp_offset.py: set GBRUNCH_TOOLS to the tools/ directory of the gbrunch checkout")
import inspect_recovery as ir  # noqa: E402


def main():
    img, name = sys.argv[1], sys.argv[2]
    with open(img, "rb") as f:
        base = 0
        try:
            base = next(p["offset"] for p in ir.gpt(f) if p["name"] == "super")
        except (AssertionError, StopIteration):
            pass                                   # bare super image
        lp = ir.liblp(f, base)
    parts = next(s for s in lp["slots"] if not s.get("empty"))["partitions"]
    part = next(p for p in parts if p["name"] == name and p["extents"])
    if len(part["extents"]) != 1:
        sys.exit(f"{name} has {len(part['extents'])} extents; this helper only handles one")
    print(part["extents"][0]["absolute_offset"], part["bytes"])


if __name__ == "__main__":
    main()
