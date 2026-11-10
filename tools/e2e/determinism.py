"""Summarise DeterminismTests output: does the same video give the same answer every time?

  python tools/e2e/determinism.py <dir of per-clip JSON>

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


if __name__ == "__main__":
    main()
