"""Run RTMW (rtmlib, wholebody 133) and ViTPose-H (transformers, vitpose-plus-huge, COCO head) on the benchmark frames;
MediaPipe = the cached pipeline landmarks for that frame. Same person box for RTMW and ViTPose (YOLOX box that best
overlaps the golfer). Output: pose_bench/preds.json  {id: {model: {name: [x, y, score]}}}"""
import json
from pathlib import Path
import cv2, numpy as np, torch

B = Path(r"C:\Users\49907\coachme-bench"); OUT = B / "pose_bench"
man = json.load(open(OUT / "manifest.json", encoding="utf-8"))
COCO = ["nose", "l_eye", "r_eye", "l_ear", "r_ear", "l_sh", "r_sh", "l_el", "r_el", "l_wr", "r_wr", "l_hip", "r_hip",
        "l_knee", "r_knee", "l_ank", "r_ank"]
FEET = {"l_bigtoe": 17, "r_bigtoe": 20, "l_heel": 19, "r_heel": 22}  # COCO-WholeBody foot points
HAND_MCP = {"l_index_mcp": 91 + 5, "r_index_mcp": 112 + 5}  # wholebody: left hand 91..111, right 112..132; index MCP = 5
MP = {"l_sh": 11, "r_sh": 12, "l_el": 13, "r_el": 14, "l_wr": 15, "r_wr": 16, "l_hip": 23, "r_hip": 24, "l_knee": 25,
      "r_knee": 26, "l_ank": 27, "r_ank": 28, "l_heel": 29, "r_heel": 30, "l_bigtoe": 31, "r_bigtoe": 32,
      "l_index_mcp": 19, "r_index_mcp": 20}  # MP 19/20 'index' ~ index knuckle region

from rtmlib import Wholebody, YOLOX
from transformers import AutoProcessor, VitPoseForPoseEstimation
dev = "cuda"
wb = Wholebody(mode="performance", backend="onnxruntime", device=dev)
proc = AutoProcessor.from_pretrained("usyd-community/vitpose-plus-huge")
vit = VitPoseForPoseEstimation.from_pretrained("usyd-community/vitpose-plus-huge").to(dev).eval()

preds = {}
for n, m in enumerate(man):
    im = cv2.imread(str(OUT / "frames" / f"{m['id']}.png"))
    lm = np.load(m["lm"])[m["frame"]]
    p = {"mediapipe": {k: [float(lm[i, 0]), float(lm[i, 1]), float(lm[i, 2])] for k, i in MP.items()}}
    ok = np.isfinite(lm[:, 0])
    gb = np.array([lm[ok, 0].min(), lm[ok, 1].min(), lm[ok, 0].max(), lm[ok, 1].max()]) if ok.any() else None
    boxes = wb.det_model(im)
    if len(boxes) and gb is not None:
        def iou(b):
            x1, y1, x2, y2 = max(b[0], gb[0]), max(b[1], gb[1]), min(b[2], gb[2]), min(b[3], gb[3])
            inter = max(0, x2 - x1) * max(0, y2 - y1)
            return inter / ((b[2] - b[0]) * (b[3] - b[1]) + (gb[2] - gb[0]) * (gb[3] - gb[1]) - inter + 1e-6)
        box = max(boxes, key=iou)
    elif len(boxes):
        box = max(boxes, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]))
    else:
        box = gb
    if box is not None:
        kp, sc = wb.pose_model(im, bboxes=[box])
        kp, sc = kp[0], sc[0]
        r = {k: [float(kp[i, 0]), float(kp[i, 1]), float(sc[i])] for i, k in enumerate(COCO)}
        r.update({k: [float(kp[i, 0]), float(kp[i, 1]), float(sc[i])] for k, i in {**FEET, **HAND_MCP}.items()})
        p["rtmw"] = r
        bx = np.array([[box[0], box[1], box[2] - box[0], box[3] - box[1]]], np.float32)
        inp = proc(cv2.cvtColor(im, cv2.COLOR_BGR2RGB), boxes=[bx], return_tensors="pt").to(dev)
        with torch.no_grad():
            out = vit(**inp, dataset_index=torch.tensor([0], device=dev))
        res = proc.post_process_pose_estimation(out, boxes=[bx])[0][0]
        k2, s2 = res["keypoints"].cpu().numpy(), res["scores"].cpu().numpy()
        p["vitpose_h"] = {k: [float(k2[i, 0]), float(k2[i, 1]), float(s2[i])] for i, k in enumerate(COCO)}
        p["box"] = [float(v) for v in box]
    preds[m["id"]] = p
    if n % 25 == 0: print(n, len(man), flush=True)
(OUT / "preds.json").write_text(json.dumps(preds), encoding="utf-8")
print("done", len(preds))
