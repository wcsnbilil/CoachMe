"""Compare App (simulator) and Python end-to-end results on the same clips.

  python tools/e2e/compare.py <app json dir> <python results.json> [--offset-tol 0.05]

Writes a Markdown report to stdout (CI appends it to the job summary). The
whole chain is compared: verdict first, then offset and phase frames. MediaPipe
differs between iOS and Python, so differences are listed, not forced to zero.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ZH = {"路径在职业范围内": "withinProRange", "外下过度": "overTheTop", "内下过度": "tooInside", "无法判断": "cannotJudge"}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("app_dir", type=Path)
    p.add_argument("python_results", type=Path)
    p.add_argument("--offset-tol", type=float, default=0.05)
    p.add_argument("--phase-tol", type=int, default=3, help="frames")
    a = p.parse_args()
    app = {f.stem: json.loads(f.read_text()) for f in sorted(a.app_dir.glob("*.json")) if not f.stem.endswith(".layers")}
    py = {r["name"]: r for r in json.loads(a.python_results.read_text(encoding="utf-8"))} if a.python_results.exists() else {}

    out = ["## 真实视频端到端（App 模拟器 vs Python）", "",
           "模拟器上的耗时和内存只作参考，真机会不同。超过 8 秒的视频先低帧率找出每一杆，只完整分析最后一杆；耗时含这一步。合成格式（`-dup`）是重复帧，不是真实慢动作。", "",
           "| 片段 | 格式 | 分析帧数 | 挥杆次数（选第几杆） | App 结论 | Python 结论 | 一致 | App offset | Py offset | App 阶段帧 | Py 阶段帧 | 耗时 ms | 峰值内存 MB |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    diffs, agree, total = [], 0, 0
    for name in sorted(set(app) | set(py)):
        ar, pr = app.get(name), py.get(name)
        fmt = name.split("__", 1)[1] if "__" in name else ""
        av = ar["verdict"] if ar else "—"
        pv = ZH.get(pr["verdict"], pr["verdict"]) if pr else "—"
        ao, po = (ar or {}).get("offset"), (pr or {}).get("offset")
        aph, pph = (ar or {}).get("phases"), (pr or {}).get("phases")
        # a long clip is cut down to one swing first: phases are relative to that window's first frame
        aoff, poff = (ar or {}).get("phaseOffset") or 0, (pr or {}).get("phaseOffset") or 0
        aph = [x + aoff for x in aph] if aph else aph
        pph = [x + poff for x in pph] if pph else pph
        asw, psw = (ar or {}).get("swingsFound"), (pr or {}).get("swingsFound")
        same = ar is not None and pr is not None and av == pv
        if ar and pr:
            total += 1
            agree += same
        notes = []
        if not ar:
            notes.append("App 没有结果")
        if not pr:
            notes.append("Python 没有结果")
        if ar and ar.get("error"):
            notes.append(f"App 出错：{ar['error']}")
        if ar and pr and av != pv:
            notes.append(f"结论不同：App {av}（{ar.get('refusal') or ''}）/ Python {pv}（{pr.get('reason', '')}）")
        if ao is not None and po is not None and abs(ao - po) > a.offset_tol:
            notes.append(f"offset 差 {ao - po:+.3f}")
        if aph and pph and max(abs(x - y) for x, y in zip(aph, pph)) > a.phase_tol:
            notes.append(f"阶段帧差 App {aph} / Py {list(pph)}")
        if asw != psw:
            notes.append(f"找到的挥杆次数不同：App {asw} / Python {psw}")
        if notes:
            diffs.append(f"- `{name}`：" + "；".join(notes))
        video = (ar or {}).get("video") or {}
        frames = (ar or {}).get("frames", "—")
        f = lambda v: "—" if v is None else f"{v:+.3f}"
        out.append(f"| `{name.split('__')[0]}` | {fmt} {video.get('codec', '')} {video.get('width', '')}×{video.get('height', '')} "
                   f"{video.get('frameRate', 0):.0f}fps | {frames} | {'整段' if asw is None else f"{asw}（{(ar or {}).get('swingChosen') or '—'}）"} | {av} | {pv} | {'✅' if same else '❌'} | {f(ao)} | {f(po)} | "
                   f"{aph or '—'} | {list(pph) if pph else '—'} | {(ar or {}).get('analysisMs', '—')} | "
                   f"{(ar or {}).get('peakMemoryMB', 0):.0f} |")
    out += ["", f"**结论一致 {agree}/{total}**（offset 容差 ±{a.offset_tol}，阶段帧容差 ±{a.phase_tol}）", ""]
    # retake checks (PR-4): the run never stops early here, so both answers can be held against the verdict
    pre = [(n, r) for n, r in sorted(app.items()) if "quick" in r]
    if pre:
        out += ["### 拍摄预检（App）", "",
                "① 导入后抽 16 帧的快速检查；② SwingNet 先跑、姿态到上杆顶点时按完整分析的规则判准备姿势 / 机位。"
                "这里不提前停，好拿最终结论对照：预检拒了的，最终也必须拒。", "",
                "| 片段 | ① 结果 | ① 用时 ms | 最窄站姿宽度 | ② 结果 | ② 在第几帧 / 共几帧 | ② 用时 ms | 全程 ms | 最终结论 | 对得上 |",
                "|---|---|---|---|---|---|---|---|---|---|"]
        bad = 0
        for n, r in pre:
            refused = (r.get("quick") not in (None, "ok")) or (r.get("early") not in (None, "ok"))
            ok = (not refused) or r["verdict"] == "cannotJudge"
            bad += not ok
            out.append(f"| `{n.split('__')[0]}` | {r.get('quick')} | {r.get('quickMs')} | {r.get('quickWidth')} | {r.get('early') or '没到'} | "
                       f"{r.get('earlyAtFrame') or '—'} / {r.get('frames')} | {r.get('earlyMs') or '—'} | {r.get('analysisMs')} | "
                       f"{r['verdict']} {r.get('refusal') or ''} | {'✅' if ok else '❌'} |")
        out += ["", f"预检拒了而最终给了结论：{bad} 段", ""]
    out += ["### 差异", ""] + (diffs or ["无"])
    print("\n".join(out))
    missing_app = [n for n in py if n not in app]
    errors = [n for n, r in app.items() if r.get("error")]
    sys.exit(1 if errors or missing_app else 0)


if __name__ == "__main__":
    main()
