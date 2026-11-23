"""Seven-phase regression on the committed SwingNet probabilities of GolfDB split 1 (baseline/golfdb-split1-phases).

  python3 tools/baseline/regress_phases.py            # compare with expected.json, exit 1 on any difference
  python3 tools/baseline/regress_phases.py --update   # rewrite expected.json from today's code
  python3 tools/baseline/regress_phases.py --against origin/main   # exit 1 if a gated metric is lower than on that ref

Scoring follows the GolfDB paper as tools/benchmark/golfdb_eval.py does: a phase is correct when the
app's keyframe is within max(round((impact - address) / 30), 1) frames of the label. A clip where the
app gives no keyframes counts as wrong on all seven. Gated metric: phaseAccuracy, the share of correct
phases over all clips.
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
from app_selector import APP_EVENTS, SwingNetEventSelector  # noqa: E402
from golfdb_eval import APP_PHASE_OF_EVENT, tolerance  # noqa: E402
from uncertainty import describe_interval, describe_paired  # noqa: E402

DATA = ROOT / "baseline" / "golfdb-split1-phases"
EXPECTED = DATA / "expected.json"
GATED = ["phaseAccuracy"]
PHASES = [APP_PHASE_OF_EVENT[e] for e in APP_EVENTS]


def load():
    manifest = json.loads((DATA / "swings.json").read_text(encoding="utf-8"))
    values = np.fromfile(DATA / "probabilities.u16", dtype="<u2")
    classes = manifest["classes"]
    for swing in manifest["swings"]:
        block = values[swing["offset"]:swing["offset"] + swing["frames"] * classes]
        yield swing, block.reshape(swing["frames"], classes) / manifest["scale"]


def correct(frames, events):
    labels = np.asarray(events[1:-1])
    allowed = tolerance(labels)
    return [frames[APP_PHASE_OF_EVENT[e]] is not None
            and abs(frames[APP_PHASE_OF_EVENT[e]] - int(labels[e])) <= allowed for e in APP_EVENTS]


def units(clips):
    manifest = json.loads((DATA / "swings.json").read_text(encoding="utf-8"))
    events = {str(swing["id"]): swing["events"] for swing in manifest["swings"]}
    return {name: float(np.mean(correct(frames, events[name]))) for name, frames in clips.items() if name in events}


def run():
    clips, table = {}, []
    for swing, probabilities in load():
        selector = SwingNetEventSelector()
        for frame, row in enumerate(probabilities):
            selector.append([float(p) for p in row], float(frame))
        marks = selector.keyframes()
        frames = {phase: (None if phase not in marks else int(marks[phase][0])) for phase in PHASES}
        clips[str(swing["id"])] = frames
        table.append(correct(frames, swing["events"]))
    table = np.asarray(table, dtype=float)
    metrics = {
        "clips": len(clips),
        "phaseAccuracy": round(float(table.mean()), 4),
        "perPhase": {phase: round(float(table[:, i].mean()), 4) for i, phase in enumerate(PHASES)},
        "clipsWithoutKeyframes": sum(1 for frames in clips.values() if all(v is None for v in frames.values())),
    }
    return {"metrics": metrics, "clips": clips}


def write(result):
    EXPECTED.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def compare(result):
    expected = json.loads(EXPECTED.read_text(encoding="utf-8"))
    changed = [name for name in result["clips"] if result["clips"][name] != expected["clips"].get(name)]
    print(f"7 阶段准确率 {result['metrics']['phaseAccuracy']:.4f}（快照 {expected['metrics']['phaseAccuracy']:.4f}）；"
          f"没有关键帧的片段 {result['metrics']['clipsWithoutKeyframes']}（快照 {expected['metrics']['clipsWithoutKeyframes']}）")
    print(f"phaseAccuracy {describe_interval(units(result['clips']).values(), '片段')}")
    if not changed and result["metrics"] == expected["metrics"]:
        print(f"{len(result['clips'])} 段与快照一致")
        return 0
    print(f"{len(changed)} 段与快照不同：")
    for name in changed:
        print(f"  {name}: {expected['clips'].get(name)} -> {result['clips'][name]}")
    print("如果这是有意的改动：运行 python3 tools/baseline/regress_phases.py --update，把 expected.json 的变化一起提交，"
          "并在 PR 里说明哪些片段变了、为什么。")
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
    print(f"phaseAccuracy {describe_paired(units(old['clips']), units(new['clips']), '片段')}")
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
