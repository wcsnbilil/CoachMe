"""Which clips does the automatic-phase run refuse that the labelled-phase run judges, and why.

  python tools/e2e/refusal_diff.py report_py/results.json impact/results_swingnet.json

Both files are run_path.py-format results on the same GolfDB clips: the first with GolfDB's labelled
phases, the second with SwingNet phases. A clip counts as "refused because of phases" when SwingNet
found no phases, or any of address / top / impact is more than --tol frames from the label.
Markdown to stdout.
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

REFUSED = "无法判断"
EVENTS = ("准备", "顶点", "击球")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("labelled", type=Path)
    p.add_argument("auto", type=Path)
    p.add_argument("--tol", type=int, default=3, help="frames; larger phase error = phase is wrong")
    a = p.parse_args()
    lab = {r["name"]: r for r in json.loads(a.labelled.read_text(encoding="utf-8"))}
    auto = {r["name"]: r for r in json.loads(a.auto.read_text(encoding="utf-8"))}
    names = [n for n in auto if n in lab]

    def err(n):
        pa, pl = auto[n].get("phases"), lab[n].get("phases")
        if not pa or not pl:
            return None
        return [pa[i] - pl[i] for i in range(3)]

    def phase_wrong(n):
        e = err(n)
        return e is None or any(abs(x) > a.tol for x in e)

    extra = [n for n in names if auto[n]["verdict"] == REFUSED and lab[n]["verdict"] != REFUSED]
    fewer = [n for n in names if lab[n]["verdict"] == REFUSED and auto[n]["verdict"] != REFUSED]
    both = sum(auto[n]["verdict"] == REFUSED and lab[n]["verdict"] == REFUSED for n in names)
    n_lab = sum(lab[n]["verdict"] == REFUSED for n in names)
    n_auto = sum(auto[n]["verdict"] == REFUSED for n in names)
    wrong = [n for n in extra if phase_wrong(n)]

    out = [f"## 自动阶段比标注阶段多拒判的段（{len(names)} 段，阶段误差 >{a.tol} 帧算阶段错）", "",
           f"- 拒判：标注阶段 {n_lab}，自动阶段 {n_auto}；两边都拒 {both}",
           f"- 只有自动阶段拒判 {len(extra)} 段，其中阶段错导致 {len(wrong)} 段"
           f"（{len(wrong) / len(extra):.0%}）" if extra else f"- 只有自动阶段拒判 0 段",
           f"- 反过来，标注阶段拒判、自动阶段给了结论 {len(fewer)} 段", ""]
    out += ["### 只有自动阶段拒判：拒判原因", "", "| 原因 | 段数 | 其中阶段错 |", "|---|---|---|"]
    by_reason = Counter(auto[n].get("reason", "") for n in extra)
    for reason, k in by_reason.most_common():
        out.append(f"| {reason or '—'} | {k} | {sum(auto[n].get('reason', '') == reason for n in wrong)} |")
    out += ["", "### 逐段", "",
            "| 段 | 慢动作 | 标注阶段结论 | 自动阶段拒判原因 | 阶段误差（准备/顶点/击球，帧） | 阶段错 |",
            "|---|---|---|---|---|---|"]
    for n in extra:
        e = err(n)
        es = "SwingNet 没给出阶段" if e is None else " / ".join(f"{x:+d}" for x in e)
        out.append(f"| {n} | {'是' if lab[n].get('slow') else ''} | {lab[n]['verdict']} | "
                   f"{auto[n].get('reason', '')} | {es} | {'是' if phase_wrong(n) else '否'} |")
    if fewer:
        out += ["", "### 标注阶段拒判、自动阶段给了结论", "",
                "| 段 | 标注阶段拒判原因 | 自动阶段结论 | 阶段误差 |", "|---|---|---|---|"]
        for n in fewer:
            e = err(n)
            out.append(f"| {n} | {lab[n].get('reason', '')} | {auto[n]['verdict']} | "
                       f"{'—' if e is None else ' / '.join(f'{x:+d}' for x in e)} |")
    print("\n".join(out))


if __name__ == "__main__":
    main()
