"""Same cases as CoachMeCore/Tests/PhaseSegmentationTests/SwingNetEventSelectorTests.swift.

Run: python3 -I tools/benchmark/test_app_selector.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_selector import SwingNetEventSelector  # noqa: E402

ORDER = ["address", "takeaway", "midBackswing", "top", "midDownswing", "impact", "finish"]
passed = failed = 0


def check(name, actual, expected):
    global passed, failed
    ok = actual == expected
    passed += ok
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {name:<52} = {actual!r}")


def row(event, value):
    p = [0.0] * 9
    p[event] = value
    p[8] = 1 - value
    return p


def run(rows, ts=None):
    s = SwingNetEventSelector()
    for i, r in enumerate(rows):
        s.append(r, ts[i] if ts else float(i))
    return s.keyframes()


def times(marks):
    return [marks[p][0] for p in ORDER if p in marks]


ts = [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 4.84, 5.13]
m = run([row(e, 0.002 if e == 0 else 0.7) for e in range(8)], ts)
check("keeps original timestamps and low-scoring address", times(m), [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 5.13])
check("all seven phases present", [k for k in ORDER if k in m], ORDER)
check("reversed swing is not one swing", run([row(e, 1) for e in reversed(range(8))]), {})
check("ordered picks ignore a later stronger peak", times(run([row(e, 0.6) for e in range(8)] + [row(3, 0.9)])),
      [0, 1, 2, 3, 4, 5, 7])
check("later setup does not discard ordered swing", times(run([row(e, 0.5) for e in range(8)] + [row(0, 0.9)])),
      [0, 1, 2, 3, 4, 5, 7])
check("earlier finish does not discard ordered swing", times(run([row(7, 0.9)] + [row(e, 0.5) for e in range(8)])),
      [1, 2, 3, 4, 5, 6, 8])
check("ties go to the earliest frame", times(run([row(e, 0.5) for e in range(8)] + [row(7, 0.5)]))[-1], 7)
check("two events without evidence is not one swing", run([row(8, 1), row(8, 1)] + [row(e, 1) for e in range(2, 8)]), {})
check("fewer frames than events gives no marks", run([row(e, 1) for e in range(7)]), {})

s = SwingNetEventSelector()
uniform = [1 / 9] * 9
for name, args in [("NaN timestamp rejected", (uniform, float("nan"))), ("wrong length rejected", ([0.1], 6.0))]:
    try:
        s.append(*args)
        check(name, "accepted", "rejected")
    except ValueError:
        check(name, "rejected", "rejected")
s.append(uniform, 5.0)
try:
    s.append(uniform, 5.0)
    check("repeated timestamp rejected", "accepted", "rejected")
except ValueError:
    check("repeated timestamp rejected", "rejected", "rejected")

print(f"\n{passed}/{passed + failed} passed")
raise SystemExit(1 if failed else 0)
