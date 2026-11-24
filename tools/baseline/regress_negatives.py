"""Videos that are not one complete swing (baseline/golfdb-split1-negatives, cut from GolfDB split 1): how often the
app still shows automatic phase marks on them.

  python3 tools/baseline/regress_negatives.py            # compare with expected.json, exit 1 on any difference
  python3 tools/baseline/regress_negatives.py --update   # rewrite expected.json from today's code
  python3 tools/baseline/regress_negatives.py --against origin/main   # exit 1 if a gated metric is lower than on that ref

Gated metric: negativeRejection, the share of cuts where the app gives no automatic marks. The cuts are listed in
tools/baseline/pack_negatives.py.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
sys.path.insert(0, str(ROOT / "tools" / "baseline"))
from app_selector import SwingNetEventSelector  # noqa: E402
from uncertainty import describe_interval, describe_paired  # noqa: E402

DATA = ROOT / "baseline" / "golfdb-split1-negatives"
EXPECTED = DATA / "expected.json"
GATED = ["negativeRejection"]


def load():
    manifest = json.loads((DATA / "swings.json").read_text(encoding="utf-8"))
    values = np.fromfile(DATA / "probabilities.u16", dtype="<u2")
    classes = manifest["classes"]
    for cut in manifest["cuts"]:
        block = values[cut["offset"]:cut["offset"] + cut["frames"] * classes]
        yield cut, block.reshape(cut["frames"], classes) / manifest["scale"]


def name(cut):
    return f"{cut['variant']}/{'+'.join(str(s) for s in cut['source'])}"


def marks(probabilities):
    selector = SwingNetEventSelector()
    for frame, row in enumerate(probabilities):
        selector.append([float(p) for p in row], float(frame))
    return {phase: int(time) for phase, (time, _) in sorted(selector.keyframes().items())}


def units(cuts):
    return {key: float(not frames) for key, frames in cuts.items()}


def run():
    cuts, variants = {}, {}
    for cut, probabilities in load():
        cuts[name(cut)] = marks(probabilities)
        variants.setdefault(cut["variant"], []).append(not cuts[name(cut)])
    metrics = {
        "cuts": len(cuts),
        "negativeRejection": round(float(np.mean([not frames for frames in cuts.values()])), 4),
        "perVariant": {v: {"cuts": len(r), "rejection": round(float(np.mean(r)), 4)} for v, r in variants.items()},
    }
    return {"metrics": metrics, "cuts": cuts}


def write(result):
    EXPECTED.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def compare(result):
    expected = json.loads(EXPECTED.read_text(encoding="utf-8"))
    changed = [key for key in result["cuts"] if result["cuts"][key] != expected["cuts"].get(key)]
    print(f"非完整挥杆不给关键帧的比例 {result['metrics']['negativeRejection']:.4f}"
          f"（快照 {expected['metrics']['negativeRejection']:.4f}），{describe_interval(units(result['cuts']).values(), '片段')}")
    for variant, row in result["metrics"]["perVariant"].items():
        print(f"  {variant}: {row['rejection']:.4f}（{row['cuts']} 段）")
    if not changed and result["metrics"] == expected["metrics"]:
        print(f"{len(result['cuts'])} 段与快照一致")
        return 0
    print(f"{len(changed)} 段与快照不同：")
    for key in changed:
        print(f"  {key}: {expected['cuts'].get(key)} -> {result['cuts'][key]}")
    print("如果这是有意的改动：运行 python3 tools/baseline/regress_negatives.py --update，把 expected.json 的变化一起提交，"
          "并在 PR 里说明哪些片段变了、为什么。")
    return 1


def against(ref):
    shown = subprocess.run(["git", "show", f"{ref}:{EXPECTED.relative_to(ROOT)}"], capture_output=True, text=True, cwd=ROOT)
    if shown.returncode != 0:
        print(f"{ref} 上还没有 expected.json")
        return 0
    old = json.loads(shown.stdout)
    new = json.loads(EXPECTED.read_text(encoding="utf-8"))
    failed = 0
    for key in GATED:
        print(f"{key}: {old['metrics'][key]} -> {new['metrics'][key]}")
        if new["metrics"][key] < old["metrics"][key]:
            failed = 1
    print(f"negativeRejection {describe_paired(units(old['cuts']), units(new['cuts']), '片段')}")
    if failed:
        print("基准指标下降了。这个 PR 不能合并：找出是哪些片段变差了并修掉，不要更新快照来通过检查。")
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
