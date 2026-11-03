"""Same cases as CoachMeCore/Tests/CoachMeCoreTests/SwingNetEventSelectorTests.swift.

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


def times(marks):
    return [marks[p][0] for p in ORDER if p in marks]


s = SwingNetEventSelector()
ts = [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 4.84, 5.13]
for e in range(8):
    p = [0.0] * 9
    p[e] = 0.002 if e == 0 else 0.7
    p[8] = 1 - p[e]
    s.append(p, ts[e])
m = s.keyframes()
check("keeps original timestamps and low-scoring address", times(m), [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 5.13])
check("all seven phases present", [k for k in ORDER if k in m], ORDER)

s = SwingNetEventSelector()
for e in reversed(range(8)):
    p = [0.0] * 9
    p[e] = 1
    s.append(p, float(8 - e))
check("contradictory order -> no marks", s.keyframes(), {})

s = SwingNetEventSelector()
for i in range(9):
    p = [0.0] * 9
    p[i if i < 8 else 0] = 0.9 if i == 8 else 0.5
    p[8] = 1 - sum(p)
    s.append(p, float(i))
check("later setup does not discard ordered swing", times(s.keyframes()), [0, 1, 2, 3, 4, 5, 7])

s = SwingNetEventSelector()
early = [0.0] * 9
early[7], early[8] = 0.9, 0.1
s.append(early, 0.0)
for i in range(8):
    p = [0.0] * 9
    p[i], p[8] = 0.5, 0.5
    s.append(p, float(i + 1))
check("earlier finish does not discard ordered swing", times(s.keyframes()), [1, 2, 3, 4, 5, 6, 8])

s = SwingNetEventSelector()
for i in range(2, 8):
    p = [0.0] * 9
    p[i] = 1
    s.append(p, float(i))
late = [0.0] * 9
late[0] = 1
s.append(late, 8.0)
check("missing setup evidence does not invent boundary", s.keyframes(), {})

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
