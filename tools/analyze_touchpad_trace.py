#!/usr/bin/env python3
"""Summarise a `getevent -lt` trace of a multitouch touchpad (touchpad-events.txt from the Pixelbook logger).

  python tools/analyze_touchpad_trace.py touchpad-events.txt [--jump 600]

Question it answers: when the pointer "jumps", does the hardware/kernel report one contact moving a long way
between two frames (the touchpad or hid-multitouch is at fault), a new contact appearing far away after a very
short gap (finger lift not seen), or just long gaps between frames (the system was too busy to read events)?

Output: frame rate and gap statistics, contact lifetimes, the largest same-contact position jumps, the shortest
lift-to-touch gaps, and events per 100 ms bucket around the biggest jumps.
"""
import argparse, collections, re, statistics, sys

LINE = re.compile(r"^\[\s*(\d+\.\d+)\]\s+(?:\S+:\s+)?(EV_\w+)\s+(\w+)\s+(\S+)")


def parse(path):
    frames, cur, slot = [], {}, 0
    state = {}                      # slot -> dict(id, x, y)
    t = None
    for line in open(path, errors="replace"):
        m = LINE.match(line)
        if not m:
            continue
        t, typ, code, val = float(m.group(1)), m.group(2), m.group(3), m.group(4)
        if typ == "EV_ABS":
            if code == "ABS_MT_SLOT":
                slot = int(val, 16)
            else:
                s = state.setdefault(slot, {"id": -1, "x": None, "y": None})
                if code == "ABS_MT_TRACKING_ID":
                    s["id"] = -1 if val.lower() == "ffffffff" else int(val, 16)
                    if s["id"] == -1:
                        s["x"] = s["y"] = None
                elif code == "ABS_MT_POSITION_X":
                    s["x"] = int(val, 16)
                elif code == "ABS_MT_POSITION_Y":
                    s["y"] = int(val, 16)
        elif typ == "EV_SYN" and code == "SYN_REPORT":
            frames.append((t, {k: dict(v) for k, v in state.items() if v["id"] != -1}))
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--jump", type=int, default=600, help="report same-contact moves larger than this many units/frame")
    a = ap.parse_args()
    frames = parse(a.trace)
    if len(frames) < 2:
        sys.exit("no frames parsed (is this a getevent -lt trace?)")
    ts = [f[0] for f in frames]
    gaps = [b - a_ for a_, b in zip(ts, ts[1:])]
    active = [g for g in gaps if g < 0.5]          # ignore idle periods
    print(f"frames: {len(frames)}  span: {ts[-1]-ts[0]:.1f}s")
    if active:
        print(f"inter-frame gap while touching: median {statistics.median(active)*1000:.1f} ms, "
              f"p95 {sorted(active)[int(len(active)*.95)]*1000:.1f} ms, max {max(active)*1000:.1f} ms")
    jumps, lifts = [], []
    last_seen = {}                                    # tracking id -> (t, x, y)
    last_end = None                                   # (t, x, y) of the most recent contact that disappeared
    prev_ids = {}
    for t, st in frames:
        ids = {s["id"]: s for s in st.values() if s["x"] is not None}
        for tid, s in ids.items():
            if tid in last_seen:
                _, px, py = last_seen[tid]
                d = max(abs(s["x"] - px), abs(s["y"] - py))
                if d > a.jump:
                    jumps.append((d, t, tid, px, py, s["x"], s["y"]))
            elif last_end is not None:
                lifts.append((t - last_end[0], t, last_end[1:], (s["x"], s["y"])))
            last_seen[tid] = (t, s["x"], s["y"])
        gone = [tid for tid in prev_ids if tid not in ids]
        if gone and not ids:
            last_end = (t,) + last_seen[gone[0]][1:]
        prev_ids = ids
    print(f"\nsame-contact jumps > {a.jump} units in one frame: {len(jumps)}")
    for d, t, tid, px, py, x, y in sorted(jumps, reverse=True)[:8]:
        print(f"  t={t:.3f} id={tid} ({px},{py}) -> ({x},{y})  d={d}")
    short = sorted(l for l in lifts if l[0] < 0.25)
    print(f"\nnew contact shortly after the previous one ended (lift gap < 250 ms): {len(short)}")
    for gap, t, frm, to in short[:8]:
        print(f"  t={t:.3f} gap={gap*1000:.0f} ms  ended at {frm}, new at {to}")
    big = sorted((g, t) for g, t in zip(gaps, ts) if 0.1 < g < 5)[-5:]
    print("\nlongest read gaps (100 ms .. 5 s), i.e. times nothing was delivered while a finger may have been down:")
    for g, t in reversed(big):
        print(f"  after t={t:.3f}: {g*1000:.0f} ms")
    ids_total = collections.Counter(tid for _, st in frames for tid in (s["id"] for s in st.values()))
    life = [n for n in ids_total.values()]
    if life:
        print(f"\ncontacts: {len(life)}  median frames per contact {statistics.median(life):.0f}")


if __name__ == "__main__":
    main()
