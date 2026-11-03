"""Reference implementation of CoachMeCore's SwingComparison.

Written first in Python, then ported line for line to
CoachMeCore/Sources/CoachMeCore/Chat/SwingComparison.swift. The Swift tests in
SwingComparisonTests.swift use the same cases, so either side can be checked
against the other.

Rules the comparison must keep:
  1. Align on phases both swings have confirmed, never on elapsed seconds.
  2. Match sides by role (lead / trail arm), so a left-handed and a right-handed
     swing compare the same arm, not the same image side.
  3. Compute a difference only when both values exist, are finite, and were
     produced by the same metric definition and unit. Otherwise delta is None.
  4. Say why numbers may not be comparable (camera view, handedness, club,
     definition version) instead of silently comparing them.

Run: python3 -I tools/reference/verify_comparison.py
"""

import math

PHASES = ["address", "takeaway", "midBackswing", "top", "midDownswing", "impact", "finish"]
VIEW_ZH = {"faceOn": "正面", "downTheLine": "沿目标线后方", "unknown": "未知视角"}


def lead_side(handedness):
    return "left" if handedness == "rightHanded" else "right"


def role(side, handedness):
    if side is None:
        return None
    return "lead" if side == lead_side(handedness) else "trail"


def usable(value):
    return value is not None and math.isfinite(value)


def compare(this, other):
    """this / other: dicts shaped like SwingAnalysisContext (only the fields used)."""
    aligned = sorted(set(this["markedPhases"]) & set(other["markedPhases"]), key=PHASES.index)

    index = {}
    for r in other["readings"]:
        index[(r["metricID"], role(r["side"], other["handedness"]), r["phase"])] = r

    deltas = []
    definition_mismatches = 0
    for r in this["readings"]:
        if r["phase"] not in aligned:
            continue
        o = index.get((r["metricID"], role(r["side"], this["handedness"]), r["phase"]))
        other_value = o["value"] if o else None
        same_definition = o is not None and o["definitionHash"] == r["definitionHash"] and o["unit"] == r["unit"]
        if o is not None and not same_definition:
            definition_mismatches += 1
        delta = None
        if same_definition and usable(r["value"]) and usable(other_value):
            delta = r["value"] - other_value
        deltas.append({
            "metricID": r["metricID"],
            "side": r["side"],
            "phase": r["phase"],
            "thisValue": r["value"] if usable(r["value"]) else None,
            "otherValue": other_value if usable(other_value) else None,
            "delta": delta,
        })

    warnings = []
    if not aligned:
        warnings.append("两次挥杆没有共同的已复核阶段，无法对比。请先在工作台复核关键帧。")
    if this["cameraView"] != other["cameraView"]:
        warnings.append(f"机位不同（{VIEW_ZH[this['cameraView']]} / {VIEW_ZH[other['cameraView']]}），同一指标的数值受视角影响，差值仅供参考。")
    if this["handedness"] != other["handedness"]:
        warnings.append("持杆手不同，已按引导侧 / 后侧对齐，而不是按画面左右。")
    if this["club"] != other["club"]:
        warnings.append("球杆不同，动作幅度本身就可能不同。")
    if definition_mismatches:
        warnings.append(f"有 {definition_mismatches} 项指标定义版本不同，未计算差值。可重新分析较早的那次挥杆。")

    return {"alignedPhases": aligned, "deltas": deltas, "warningsZH": warnings}


# ---------------------------------------------------------------- checks

passed = failed = 0


def check(name, actual, expected):
    global passed, failed
    ok = actual == expected
    passed += ok
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {name:<58} = {actual!r}")


def reading(metric, side, phase, value, h="h1", unit="°"):
    return {"metricID": metric, "side": side, "phase": phase, "value": value,
            "definitionHash": h, "unit": unit}


def ctx(readings, phases, handedness="rightHanded", view="faceOn", club="iron"):
    return {"readings": readings, "markedPhases": phases, "handedness": handedness,
            "cameraView": view, "club": club}


# 1. Basic delta, phase alignment
a = ctx([reading("elbowInteriorAngle", "left", "top", 150.0),
         reading("elbowInteriorAngle", "left", "impact", 170.0)], ["address", "top", "impact"])
b = ctx([reading("elbowInteriorAngle", "left", "top", 140.0),
         reading("elbowInteriorAngle", "left", "impact", 175.0)], ["top", "impact", "finish"])
r = compare(a, b)
check("aligned phases are the intersection, in swing order", r["alignedPhases"], ["top", "impact"])
check("delta = this - other at top", r["deltas"][0]["delta"], 10.0)
check("delta = this - other at impact", r["deltas"][1]["delta"], -5.0)
check("same setup gives no warnings", r["warningsZH"], [])

# 2. Phase only in one swing is dropped
a = ctx([reading("kneeInteriorAngle", "left", "address", 160.0)], ["address"])
b = ctx([reading("kneeInteriorAngle", "left", "address", 150.0)], ["top"])
r = compare(a, b)
check("no common phase -> no deltas", r["deltas"], [])
check("no common phase -> explicit warning", r["warningsZH"][0].startswith("两次挥杆没有共同"), True)

# 3. Missing / non-finite values never become a number
a = ctx([reading("elbowInteriorAngle", "left", "top", None),
         reading("elbowInteriorAngle", "right", "top", float("nan")),
         reading("kneeInteriorAngle", "left", "top", 150.0)], ["top"])
b = ctx([reading("elbowInteriorAngle", "left", "top", 140.0),
         reading("elbowInteriorAngle", "right", "top", 120.0)], ["top"])
r = compare(a, b)
check("this value missing -> delta None", r["deltas"][0]["delta"], None)
check("NaN is reported as missing, not as a value", r["deltas"][1]["thisValue"], None)
check("NaN -> delta None", r["deltas"][1]["delta"], None)
check("other reading absent -> otherValue None", r["deltas"][2]["otherValue"], None)
check("other reading absent -> delta None", r["deltas"][2]["delta"], None)

# 4. Handedness: compare the lead arm with the lead arm
a = ctx([reading("elbowInteriorAngle", "left", "top", 150.0)], ["top"], handedness="rightHanded")
b = ctx([reading("elbowInteriorAngle", "left", "top", 100.0),
         reading("elbowInteriorAngle", "right", "top", 145.0)], ["top"], handedness="leftHanded")
r = compare(a, b)
check("right-hander lead (left) vs left-hander lead (right)", r["deltas"][0]["otherValue"], 145.0)
check("delta uses the lead arm", r["deltas"][0]["delta"], 5.0)
check("handedness warning present", any("持杆手不同" in w for w in r["warningsZH"]), True)

# 5. Bilateral (side None) metrics match each other
a = ctx([reading("shoulderLineRotation", None, "top", -44.0)], ["top"])
b = ctx([reading("shoulderLineRotation", None, "top", -50.0)], ["top"])
check("bilateral metric delta", compare(a, b)["deltas"][0]["delta"], 6.0)

# 6. Definition hash / unit mismatch -> no delta, warning
a = ctx([reading("elbowInteriorAngle", "left", "top", 150.0, h="new"),
         reading("kneeInteriorAngle", "left", "top", 150.0, unit="°")], ["top"])
b = ctx([reading("elbowInteriorAngle", "left", "top", 140.0, h="old"),
         reading("kneeInteriorAngle", "left", "top", 2.6, unit="rad")], ["top"])
r = compare(a, b)
check("definition hash mismatch -> delta None", r["deltas"][0]["delta"], None)
check("unit mismatch -> delta None", r["deltas"][1]["delta"], None)
check("values still shown for both", (r["deltas"][0]["thisValue"], r["deltas"][0]["otherValue"]), (150.0, 140.0))
check("mismatch warning counts both", any("有 2 项指标定义版本不同" in w for w in r["warningsZH"]), True)

# 7. Camera view and club warnings, in a fixed order
a = ctx([], ["top"], view="faceOn", club="driver")
b = ctx([], ["top"], view="downTheLine", club="iron")
w = compare(a, b)["warningsZH"]
check("view warning first, names both views", w[0].startswith("机位不同（正面 / 沿目标线后方）"), True)
check("club warning second", w[1].startswith("球杆不同"), True)

# 8. Reading order follows this swing's readings
a = ctx([reading("kneeInteriorAngle", "left", "impact", 1.0),
         reading("elbowInteriorAngle", "left", "top", 2.0)], ["top", "impact"])
r = compare(a, ctx([], ["top", "impact"]))
check("delta order follows this swing's readings",
      [(d["metricID"], d["phase"]) for d in r["deltas"]],
      [("kneeInteriorAngle", "impact"), ("elbowInteriorAngle", "top")])

print(f"\n{passed}/{passed + failed} passed")
raise SystemExit(1 if failed else 0)
