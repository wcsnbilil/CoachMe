"""Summarise DeterminismTests output: does the same video give the same answer every time?

  python tools/e2e/determinism.py <dir of per-clip JSON>
  python tools/e2e/determinism.py --across label=dir label=dir ...   (separate processes / machines)

For each clip: the verdicts of every run, whether the decoded pixels were identical across runs,
how far the landmarks drifted between runs (and from which frame), and the lockstep pass (two
fresh detectors fed the same buffers). Markdown to stdout; exit 1 if any clip's verdict changed.
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np


def main():
    d = Path(sys.argv[1])
    clips = [json.loads(f.read_text()) for f in sorted(d.glob("*.json"))]
    out = ["## 同一视频多次运行（App 模拟器）", "",
           "每段从头跑 N 次整条内测链路（新的检测器）。「画面」= 姿态检测器收到的每帧像素是否逐次相同；"
           "「关键点」= 各次之间同一帧关键点的最大差（归一化坐标）；「同步」= 两个新检测器喂同一批像素时有几帧结果不同。", "",
           "| 片段 | 结论（次数） | 阶段帧 | 画面逐次相同 | 关键点最大差 | 第一处不同帧 | 不同的帧数 | 同步：不同帧 / 总帧 | 同步最大差 |",
           "|---|---|---|---|---|---|---|---|---|"]
    unstable = 0
    for c in clips:
        runs = c["runs"]
        answers = Counter(f"{r['verdict']}{'/' + r['refusal'] if r.get('refusal') else ''}" for r in runs)
        unstable += len(answers) > 1
        phases = Counter(str(r.get("phases")) for r in runs)
        same_pixels = len({tuple(r["frameHashes"]) for r in runs}) == 1
        lm = [np.array(r["landmarks"], float) if r["landmarks"] and all(len(f) == 33 for f in r["landmarks"]) else None
              for r in runs]
        drift, first, nframes = 0.0, None, 0
        if all(x is not None for x in lm) and len({x.shape for x in lm}) == 1:
            stack = np.stack(lm)
            per = np.nanmax(np.abs(stack - stack[:1]).reshape(len(runs), stack.shape[1], -1), axis=(0, 2))
            drift = float(np.nanmax(per)) if per.size else 0.0
            bad = np.flatnonzero(per > 0)
            first = int(bad[0]) if len(bad) else None
            nframes = len(bad)
        else:
            drift = float("nan")  # some frame had no pose in one run and a pose in another
        ls = c.get("lockstep") or {}
        out.append(f"| `{c['name'].split('__')[-1]}` | {'，'.join(f'{k} ×{v}' for k, v in answers.items())}"
                   f"{' ❌' if len(answers) > 1 else ''} | {'，'.join(phases)} | {'是' if same_pixels else '否'} | "
                   f"{drift:.4f} | {first if first is not None else '—'} | {nframes} / {len(lm[0]) if lm and lm[0] is not None else '—'} | "
                   f"{ls.get('differing', '—')} / {ls.get('frames', '—')} | {ls.get('maxDifference', 0):.4f} |")
    out += ["", f"**结论有变化的片段：{unstable}/{len(clips)}**"]
    print("\n".join(out))
    sys.exit(1 if unstable else 0)


def across(specs: list[str]) -> int:
    """Same clips, separate test processes (and machines): first run of each, compared with the first."""
    sets = []
    for spec in specs:
        label, d = spec.split("=", 1)
        sets.append((label, {json.loads(f.read_text())["name"]: json.loads(f.read_text()) for f in sorted(Path(d).glob("*.json"))}))
    names = sorted(set.intersection(*[set(c) for _, c in sets]))
    head = " | ".join(f"{l}（{next(iter(c.values())).get('processors', '?')} 核，先快检={'是' if next(iter(c.values())).get('quickFirst') else '否'}）"
                      for l, c in sets)
    out = ["## 跨进程 / 跨机器", "", f"每格 = 该次结论；对比都以第一列为准：画面是否相同、关键点最大差、有差别的帧数。", "",
           f"| 片段 | {head} |", "|---" * (len(sets) + 1) + "|"]
    changed = 0
    for n in names:
        ref = sets[0][1][n]["runs"][0]
        ref_lm = np.array(ref["landmarks"], float) if all(len(f) == 33 for f in ref["landmarks"]) else None
        cells, verdicts = [], set()
        for _, c in sets:
            r = c[n]["runs"][0]
            v = f"{r['verdict']}{'/' + r['refusal'] if r.get('refusal') else ''}"
            verdicts.add(v)
            px = "画面同" if r["frameHashes"] == ref["frameHashes"] else "画面不同"
            lm = np.array(r["landmarks"], float) if all(len(f) == 33 for f in r["landmarks"]) else None
            if ref_lm is not None and lm is not None and lm.shape == ref_lm.shape:
                diff = np.abs(lm - ref_lm).reshape(len(lm), -1).max(axis=1)
                cells.append(f"{v}；{px}；差 {np.nanmax(diff):.4f}，{int((diff > 0).sum())} 帧")
            else:
                cells.append(f"{v}；{px}；关键点帧数不同")
        changed += len(verdicts) > 1
        out.append(f"| `{n.split('__')[-1]}` | " + " | ".join(cells) + f"{' ❌' if len(verdicts) > 1 else ''} |")
    out += ["", f"**跨进程 / 机器结论有变化的片段：{changed}/{len(names)}**"]
    print("\n".join(out))
    return 1 if changed else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--across":
        sys.exit(across(sys.argv[2:]))
    main()
