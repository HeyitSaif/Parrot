#!/usr/bin/env python3
"""Dev-only diarization eval: join a FluidAudio `fluidaudiocli process` JSON
with a meeting's stored transcript from Parrot's SwiftData store, reassign
non-Me segments by max time overlap, and print a relabeled transcript plus
per-cluster stats. Used to calibrate the clustering threshold on real calls
(see docs/superpowers/specs/2026-08-04-speaker-diarization-design.md).

Usage: diarization-compare.py <diarization.json> [meeting title]
"""
import json, sqlite3, sys, os
from collections import Counter, defaultdict

if len(sys.argv) < 2:
    sys.exit(__doc__)
JSON_PATH = sys.argv[1]
TITLE = sys.argv[2] if len(sys.argv) > 2 else "Meeting Aug 3, 2026 at 1:00 pm"
DB = os.path.expanduser(
    "~/Library/Containers/com.uygar.parrot/Data/Library/Application Support/default.store")

d = json.load(open(JSON_PATH))
D = [(s["speakerId"], s["startTimeSeconds"], s["endTimeSeconds"]) for s in d["segments"]]

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
rows = con.execute(
    """SELECT s.ZSTARTTIME, s.ZENDTIME, s.ZSPEAKERLABEL, s.ZTEXT
       FROM ZTRANSCRIPTSEGMENT s JOIN ZMEETING m ON s.ZMEETING=m.Z_PK
       WHERE m.ZTITLE=? ORDER BY s.ZSTARTTIME""", (TITLE,)).fetchall()
if not rows:
    sys.exit(f"no meeting titled {TITLE!r} in {DB}")

def best(t0, t1):
    b, bo = None, 0.0
    for spk, d0, d1 in D:
        ov = min(t1, d1) - max(t0, d0)
        if ov > bo: b, bo = spk, ov
    return b

tot = defaultdict(float)
for spk, d0, d1 in D: tot[spk] += d1 - d0
print(f"{len(tot)} speakers in diarization: " +
      ", ".join(f"{k}={v:.0f}s" for k, v in sorted(tot.items())))

pairs = Counter(); unmatched = 0
for t0, t1, old, text in rows:
    if old == "Me":
        print(f"{t0:7.1f}  {'Me':>10}: {text[:70]}"); continue
    new = best(t0, t1)
    if new is None: unmatched += 1; new = "?"
    pairs[(old, new)] += 1
    tag = "" if old == new else f"   [was {old}]"
    print(f"{t0:7.1f}  {new:>10}: {text[:70]}{tag}")

print("\nold label -> new cluster (non-Me):")
for (old, new), n in sorted(pairs.items()): print(f"  {old:>10} -> {new}: {n}")
print(f"unmatched (no diarization overlap): {unmatched}")
