"""Does the keyframe detection change the swing-path verdict? Uses the clips present in both committed baselines.

  python3 tools/baseline/regress_keyframes.py            # compare with expected.json, exit 1 on any difference
  python3 tools/baseline/regress_keyframes.py --update   # rewrite expected.json from today's code
  python3 tools/baseline/regress_keyframes.py --against origin/main   # exit 1 if a gated metric is lower than on that ref

For each clip that has both App landmarks (baseline/golfdb400) and SwingNet probabilities
(baseline/golfdb-split1-phases), the swing path is judged twice: once with the address, top and impact
frames the app's selector picks, once with GolfDB's labelled frames. Gated metric: verdictAgreement, the
share of clips where both give the same verdict. A clip where the app gives no keyframes counts as
disagreeing unless the labelled frames also end in a refusal.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "baseline"))
sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
sys.path.insert(0, str(ROOT / "tools" / "faults"))
import path_fault  # noqa: E402
import regress  # noqa: E402
import regress_phases  # noqa: E402
from app_selector import SwingNetEventSelector  # noqa: E402

EXPECTED = ROOT / "baseline" / "keyframes-to-path" / "expected.json"
GATED = ["verdictAgreement"]
REFUSED = "无法判断"


def run():
    landmarks_by_id = {swing["id"]: (swing, landmarks) for swing, landmarks in regress.load()}
    clips = {}
    for phases, probabilities in regress_phases.load():
        if phases["id"] not in landmarks_by_id:
            continue
        swing, landmarks = landmarks_by_id[phases["id"]]
        if swing["frames"] != phases["frames"]:
            raise SystemExit(f"{swing['name']}: 关键点有 {swing['frames']} 帧，概率有 {phases['frames']} 帧。"
                             "两份基准数据不是同一版视频：重新跑「回归基准数据」把两份一起更新。")
        events = swing["events"]
        labelled = path_fault.analyze(landmarks, events[regress.ADDRESS], events[regress.TOP], events[regress.IMPACT])
        selector = SwingNetEventSelector()
        for frame, row in enumerate(probabilities):
            selector.append([float(p) for p in row], float(frame))
        marks = selector.keyframes()
        if marks:
            frames = [int(marks[phase][0]) for phase in ("address", "top", "impact")]
            detected = path_fault.analyze(landmarks, *frames)["verdict"]
        else:
            frames, detected = None, REFUSED
        clips[swing["name"]] = {"slow": swing["slow"], "detectedFrames": frames,
                                "labelledFrames": [events[regress.ADDRESS], events[regress.TOP], events[regress.IMPACT]],
                                "detectedVerdict": detected, "labelledVerdict": labelled["verdict"]}
    same = sum(1 for clip in clips.values() if clip["detectedVerdict"] == clip["labelledVerdict"])
    metrics = {
        "clips": len(clips),
        "agreeing": same,
        "verdictAgreement": round(same / len(clips), 4),
        "faultOnlyWithDetectedFrames": sum(1 for clip in clips.values()
                                           if clip["detectedVerdict"] != clip["labelledVerdict"]
                                           and clip["detectedVerdict"] in ("外下过度", "内下过度")),
        "refusedOnlyWithDetectedFrames": sum(1 for clip in clips.values()
                                             if clip["detectedVerdict"] == REFUSED != clip["labelledVerdict"]),
    }
    return {"metrics": metrics, "clips": clips}


def compare(result):
    expected = json.loads(EXPECTED.read_text(encoding="utf-8"))
    changed = [name for name in result["clips"] if result["clips"][name] != expected["clips"].get(name)]
    metrics = result["metrics"]
    print(f"识别关键帧与标注关键帧的判定一致 {metrics['agreeing']}/{metrics['clips']} = {metrics['verdictAgreement']:.4f}"
          f"（快照 {expected['metrics']['verdictAgreement']:.4f}）；"
          f"只因识别关键帧而报外下/内下 {metrics['faultOnlyWithDetectedFrames']} 段，"
          f"只因识别关键帧而拒判 {metrics['refusedOnlyWithDetectedFrames']} 段")
    if not changed and metrics == expected["metrics"]:
        print(f"{metrics['clips']} 段与快照一致")
        return 0
    print(f"{len(changed)} 段与快照不同：")
    for name in changed:
        print(f"  {name}: {expected['clips'].get(name)} -> {result['clips'][name]}")
    print("如果这是有意的改动：运行 python3 tools/baseline/regress_keyframes.py --update，把 expected.json 的变化一起提交，"
          "并在 PR 里说明哪些片段变了、为什么。")
    return 1


def against(ref):
    shown = subprocess.run(["git", "show", f"{ref}:{EXPECTED.relative_to(ROOT)}"], capture_output=True, text=True, cwd=ROOT)
    if shown.returncode != 0:
        print(f"{ref} 上还没有 {EXPECTED.relative_to(ROOT)}")
        return 0
    before = json.loads(shown.stdout)["metrics"]
    now = json.loads(EXPECTED.read_text(encoding="utf-8"))["metrics"]
    failed = 0
    for key in GATED:
        print(f"{key}: {before[key]} -> {now[key]}")
        if now[key] < before[key]:
            failed = 1
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
        EXPECTED.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(json.dumps(result["metrics"], ensure_ascii=False))
        return
    sys.exit(compare(result))


if __name__ == "__main__":
    main()
