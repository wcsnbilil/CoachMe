"""Layer-by-layer App vs Python table for each clip: where do the two chains start to differ?

  python tools/e2e/layers.py <app dir> <python dir>   (both hold <name>.layers.json)

Layers, in chain order:
  1 decode     frame count, displayed size, fps, timestamps
  2 pose       frames with a pose; mean pixel distance of shoulders / hips / wrists on frames both
               have; wrist visibility (share of frames >= 0.5, the analyzer's cut-off)
  3 SwingNet   max per-frame probability difference; address / top / impact frames
  4 verdict    the Python analyzer run on each combination of landmarks x phases. The analyzers
               already agree on identical input (22/22 GolfDB parity), so this 2x2 shows whether
               the landmarks or the phases move the verdict.
Markdown to stdout.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
from path_fault import analyze  # noqa: E402

JOINTS = {"肩": (11, 12), "髋": (23, 24), "手腕": (15, 16)}
ZH = {"路径在职业范围内": "职业范围", "外下过度": "外下", "内下过度": "内下", "无法判断": "拒判"}


def pixels(layers: dict) -> np.ndarray:
    w, h = layers["width"], layers["height"]
    out = np.full((len(layers["landmarks"]), 33, 3), np.nan)
    for i, fr in enumerate(layers["landmarks"]):
        if len(fr) == 33:
            a = np.array(fr, float)[:, :3]
            out[i] = np.c_[a[:, 0] * w, a[:, 1] * h, a[:, 2]]
    return out


def verdict(lm: np.ndarray, phases) -> str:
    if not phases:
        return "无阶段"
    if max(phases) >= len(lm):
        return "阶段越界"
    r = analyze(lm, *phases)
    v = ZH.get(r["verdict"], r["verdict"])
    return v + (f"（{r['reason']}）" if r.get("reason") else f" {r.get('offset', 0):+.3f}")


def table(app: dict, py: dict) -> list[str]:
    rows = []
    add = lambda layer, item, a, p, note="": rows.append(f"| {layer} | {item} | {a} | {p} | {note} |")
    na, np_ = len(app["timestamps"]), len(py["timestamps"])
    add("1 解码", "帧数", na, np_, "" if na == np_ else "⚠️ 不同")
    size_a, size_p = f"{app['width']:.0f}×{app['height']:.0f}", f"{py['width']:.0f}×{py['height']:.0f}"
    add("", "画面尺寸", size_a, size_p, "" if size_a == size_p else "⚠️ 不同（方向或缩放）")
    add("", "fps", f"{app.get('nominalFPS') or 0:.2f}", f"{py.get('nominalFPS') or 0:.2f}")
    n = min(na, np_)
    if n:
        dt = np.abs(np.array(app["timestamps"][:n]) - np.array(py["timestamps"][:n]))
        add("", "时间戳差（同序号帧）", f"首 {app['timestamps'][0]:.3f}s", f"首 {py['timestamps'][0]:.3f}s",
            f"最大 {dt.max() * 1000:.0f} ms")
    la, lp = pixels(app), pixels(py)
    own = la.copy()  # App landmarks in the App's own pixels = what the App's analyzer saw
    # compare in the Python frame's pixels (sizes can differ; landmarks are normalised)
    if (app["width"], app["height"]) != (py["width"], py["height"]):
        la[:, :, 0] *= py["width"] / app["width"]
        la[:, :, 1] *= py["height"] / app["height"]
    ha = np.isfinite(la[:n, 0, 0])
    hp = np.isfinite(lp[:n, 0, 0])
    add("2 姿态", "有姿态的帧", int(np.isfinite(la[:, 0, 0]).sum()), int(np.isfinite(lp[:, 0, 0]).sum()))
    both = ha & hp
    for zh, (j1, j2) in JOINTS.items():
        if both.any():
            d = np.linalg.norm(la[:n][both][:, [j1, j2], :2] - lp[:n][both][:, [j1, j2], :2], axis=2)
            torso = np.nanmedian(np.linalg.norm(lp[:n][both][:, [11, 12], :2].mean(1) - lp[:n][both][:, [23, 24], :2].mean(1), axis=1))
            add("", f"{zh} 位置差", "", "", f"平均 {np.nanmean(d):.1f}px（{np.nanmean(d) / torso:.2f} 躯干），"
                f"最大 {np.nanmax(d):.0f}px")
    wa = np.mean(np.nan_to_num(la[:, [15, 16], 2]) >= 0.5) if len(la) else 0
    wp = np.mean(np.nan_to_num(lp[:, [15, 16], 2]) >= 0.5) if len(lp) else 0
    add("", "手腕可见（≥0.5）", f"{wa:.0%}", f"{wp:.0%}")
    pa, pp = np.array(app["probabilities"] or [[0] * 9]), np.array(py["probabilities"] or [[0] * 9])
    m = min(len(pa), len(pp))
    add("3 SwingNet", "概率最大差（同序号帧）", len(pa), len(pp), f"{np.abs(pa[:m] - pp[:m]).max():.3f}" if m else "—")
    add("", "准备 / 顶点 / 击球帧", app.get("phases") or "—", py.get("phases") or "—",
        "" if app.get("phases") == py.get("phases") else "⚠️ 不同")
    add("", "阶段来自人物裁剪重跑", "是" if app.get("usedPersonCrop") else "否", "是" if py.get("personCrop") else "否")
    combos = [("App 关键点 + App 阶段", own, app.get("phases")), ("App 关键点 + Py 阶段", own, py.get("phases")),
              ("Py 关键点 + App 阶段", lp, app.get("phases")), ("Py 关键点 + Py 阶段", lp, py.get("phases"))]
    for i, (label, lm, ph) in enumerate(combos):
        add("4 判定" if i == 0 else "", label, "", "", verdict(lm, ph))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("app_dir", type=Path)
    ap.add_argument("py_dir", type=Path)
    a = ap.parse_args()
    out = ["## 逐层对比（App 模拟器 vs Python）", "",
           "第 4 层都用 Python 判定算法，只换输入：看是关键点还是阶段帧让结论分叉。", ""]
    for f in sorted(a.py_dir.glob("*.layers.json")):
        g = a.app_dir / f.name
        name = f.name[:-len(".layers.json")]
        out.append(f"### `{name}`")
        out.append("")
        if not g.exists():
            out += ["App 没有这一段的逐层数据。", ""]
            continue
        out += ["| 层 | 项目 | App | Python | 差异 |", "|---|---|---|---|---|"]
        out += table(json.loads(g.read_text()), json.loads(f.read_text(encoding="utf-8")))
        out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
