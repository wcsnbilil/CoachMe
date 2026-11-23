"""Swing-path regression on the committed GolfDB 400 landmarks (baseline/golfdb400).

  python3 tools/baseline/regress.py            # compare with baseline/golfdb400/expected.json, exit 1 on any difference
  python3 tools/baseline/regress.py --update   # rewrite expected.json from today's code
  python3 tools/baseline/regress.py --against origin/main   # exit 1 if a gated metric is lower than on that ref

expected.json holds the per-clip snapshot (verdict, refusal reason, confidence, offset) and the metrics
computed from it. Gated metric: pairAgreement, the share of real-time / slow-motion pairs of the same
swing that get the same verdict.
"""
import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "baseline"))
import path_fault  # noqa: E402
from compare import pair_agreement  # noqa: E402
from uncertainty import describe_interval, describe_paired  # noqa: E402

DATA = ROOT / "baseline" / "golfdb400"
EXPECTED = DATA / "expected.json"
ADDRESS, TOP, IMPACT = 1, 4, 6
OFFSET_DECIMALS = 3
GATED = ["pairAgreement"]


def load():
    manifest = json.loads((DATA / "swings.json").read_text(encoding="utf-8"))
    values = np.fromfile(DATA / "landmarks.i16", dtype="<i2")
    per_frame = manifest["joints"] * 3
    for swing in manifest["swings"]:
        block = values[swing["offset"]:swing["offset"] + swing["frames"] * per_frame]
        block = block.reshape(swing["frames"], manifest["joints"], 3).astype(float)
        missing = block == manifest["missing"]
        landmarks = np.empty_like(block)
        landmarks[:, :, 0] = block[:, :, 0] / manifest["xyScale"] * swing["width"]
        landmarks[:, :, 1] = block[:, :, 1] / manifest["xyScale"] * swing["height"]
        landmarks[:, :, 2] = block[:, :, 2] / manifest["visibilityScale"]
        landmarks[missing] = np.nan
        yield swing, landmarks


def run():
    clips, rows = {}, {}
    for swing, landmarks in load():
        events = swing["events"]
        result = path_fault.analyze(landmarks, events[ADDRESS], events[TOP], events[IMPACT])
        offset = result.get("offset")
        clips[swing["name"]] = {
            "verdict": result["verdict"],
            "reason": result.get("reason"),
            "confidence": result.get("confidence"),
            "offset": None if offset is None else round(float(offset), OFFSET_DECIMALS),
        }
        rows[swing["name"]] = {**result, "name": swing["name"], "slow": swing["slow"],
                               "player": swing["player"], "youtube_id": swing["youtube_id"]}
    agree, total, _ = pair_agreement(rows)
    counts = Counter(clip["verdict"] for clip in clips.values())
    metrics = {
        "clips": len(clips),
        "pairs": total,
        "pairsAgreeing": agree,
        "pairAgreement": round(agree / total, 4),
        "refused": counts.get("无法判断", 0),
        "verdicts": dict(sorted(counts.items())),
    }
    return {"metrics": metrics, "clips": clips}


def units(clips):
    """1 for each real-time / slow-motion pair with the same verdict, 0 otherwise, keyed by (youtube_id, player)."""
    manifest = json.loads((DATA / "swings.json").read_text(encoding="utf-8"))
    groups = {}
    for swing in manifest["swings"]:
        clip = clips.get(swing["name"])
        if clip is not None:
            groups.setdefault((swing["youtube_id"], swing["player"]), {})[swing["slow"]] = clip
    return {key: float(g[0]["verdict"] == g[1]["verdict"]) for key, g in groups.items()
            if 0 in g and 1 in g and g[0]["offset"] is not None and g[1]["offset"] is not None}


def write(result):
    EXPECTED.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def compare(result):
    expected = json.loads(EXPECTED.read_text(encoding="utf-8"))
    changed = [name for name in result["clips"] if result["clips"][name] != expected["clips"].get(name)]
    print(f"一致率 {result['metrics']['pairsAgreeing']}/{result['metrics']['pairs']} = {result['metrics']['pairAgreement']:.4f}"
          f"（快照 {expected['metrics']['pairAgreement']:.4f}）；拒判 {result['metrics']['refused']}（快照 {expected['metrics']['refused']}）")
    print(f"pairAgreement {describe_interval(units(result['clips']).values(), '一对')}")
    if not changed and result["metrics"] == expected["metrics"]:
        print(f"{len(result['clips'])} 杆与快照一致")
        return 0
    print(f"{len(changed)} 杆与快照不同：")
    for name in changed:
        print(f"  {name}: {expected['clips'].get(name)} -> {result['clips'][name]}")
    print("如果这是有意的改动：运行 python3 tools/baseline/regress.py --update，把 expected.json 的变化一起提交，"
          "并在 PR 里说明哪些杆变了、为什么。")
    return 1


def against(ref):
    shown = subprocess.run(["git", "show", f"{ref}:{EXPECTED.relative_to(ROOT)}"], capture_output=True, text=True, cwd=ROOT)
    if shown.returncode != 0:
        print(f"{ref} 上还没有 expected.json")
        return 0
    old = json.loads(shown.stdout)
    new = json.loads(EXPECTED.read_text(encoding="utf-8"))
    before, now = old["metrics"], new["metrics"]
    failed = 0
    for key in GATED:
        print(f"{key}: {before[key]} -> {now[key]}")
        if now[key] < before[key]:
            failed = 1
    print(f"pairAgreement {describe_paired(units(old['clips']), units(new['clips']), '一对')}")
    if failed:
        print("基准指标下降了。这个 PR 不能合并：找出是哪些杆变差了并修掉，不要更新快照来通过检查。")
    return failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--against")
    a = ap.parse_args()
    if a.against:
        sys.exit(against(a.against))
    result = run()
    if a.update:
        write(result)
        print(json.dumps(result["metrics"], ensure_ascii=False))
        return
    sys.exit(compare(result))


if __name__ == "__main__":
    main()
