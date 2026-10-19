#!/usr/bin/env python3
"""Print the CONFIG_ options that differ between two kernel .config files."""
import re, sys


def load(p):
    d = {}
    for line in open(p, errors="replace"):
        m = re.match(r"(CONFIG_\w+)=(.*)", line) or re.match(r"# (CONFIG_\w+) is not set", line)
        if m:
            d[m.group(1)] = m.group(2) if m.lastindex == 2 else "n"
    return d


a, b = load(sys.argv[1]), load(sys.argv[2])
keys = sorted(k for k in set(a) | set(b) if a.get(k, "n") != b.get(k, "n"))
for k in keys:
    print(f"{k}: {a.get(k, '(absent)')} -> {b.get(k, '(absent)')}")
print(f"# {len(keys)} options differ")
