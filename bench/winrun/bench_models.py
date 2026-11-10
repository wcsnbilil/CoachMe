"""Run RTMW (rtmlib, wholebody 133) and ViTPose-H (transformers, vitpose-plus-huge, COCO head) on the benchmark frames;
MediaPipe = the cached pipeline landmarks for that frame (VIDEO mode, heavy). Same person box for RTMW and ViTPose
(YOLOX box that best overlaps the golfer).
B version (2026-11-10): also runs frames k-1 and k+1 (for jitter), times every model, and is resumable.
Output: pose_bench/preds.json  {id: {model: {name: [x, y, score]}, "prev"/"next": {model: {...}}, "ms": {model: ms}}}"""
import json, os, time
from pathlib import Path
import cv2, numpy as np, torch

B = Path(r"C:\Users\k8881\coachme-bench"); OUT = Path(os.environ.get("CM_POSE_OUT", B / "pose_bench"))
man = json.load(open(OUT / "manifest.json", encoding="utf-8"))
COCO = ["nose", "l_eye", "r_eye", "l_ear", "r_ear", "l_sh", "r_sh", "l_el", "r_el", "l_wr", "r_wr", "l_hip", "r_hip",
        "l_knee", "r_knee", "l_ank", "r_ank"]
FEET = {"l_bigtoe": 17, "r_bigtoe": 20, "l_heel": 19, "r_heel": 22}  # COCO-WholeBody foot points
HAND_MCP = {"l_index_mcp": 91 + 5, "r_index_mcp": 112 + 5}  # wholebody: left hand 91..111, right 112..132; index MCP = 5
MP = {"l_sh": 11, "r_sh": 12, "l_el": 13, "r_el": 14, "l_wr": 15, "r_wr": 16, "l_hip": 23, "r_hip": 24, "l_knee": 25,
      "r_knee": 26, "l_ank": 27, "r_ank": 28, "l_heel": 29, "r_heel": 30, "l_bigtoe": 31, "r_bigtoe": 32,
      "l_index_mcp": 19, "r_index_mcp": 20}  # MP 19/20 'index' ~ index knuckle region

from rtmlib import Wholebody
from transformers import AutoProcessor, VitPoseForPoseEstimation
import mediapipe as mp
from mediapipe.tasks import python as mpp
from mediapipe.tasks.python import vision
dev = "cuda"
wb = Wholebody(mode="performance", backend="onnxruntime", device=dev)
proc = AutoProcessor.from_pretrained("usyd-community/vitpose-plus-huge")
vit = VitPoseForPoseEstimation.from_pretrained("usyd-community/vitpose-plus-huge").to(dev).eval()
mp_img = vision.PoseLandmarker.create_from_options(vision.PoseLandmarkerOptions(
    base_options=mpp.BaseOptions(model_asset_path=str(B / "coachme/CoachMe/Resources/pose_landmarker_heavy.task")),
    running_mode=vision.RunningMode.IMAGE, num_poses=1))


def mp_of(lm):
    return {k: [float(lm[i, 0]), float(lm[i, 1]), float(lm[i, 2])] for k, i in MP.items()}


def run(im, lm, ms):
    """RTMW + ViTPose on one image, box chosen against the cached MediaPipe landmarks lm (33, 3)."""
    p = {}
    ok = np.isfinite(lm[:, 0])
    gb = np.array([lm[ok, 0].min(), lm[ok, 1].min(), lm[ok, 0].max(), lm[ok, 1].max()]) if ok.any() else None
    t = time.perf_counter(); boxes = wb.det_model(im); ms["yolox_det"].append((time.perf_counter() - t) * 1000)
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
    if box is None:
        return p
    t = time.perf_counter(); kp, sc = wb.pose_model(im, bboxes=[box]); ms["rtmw"].append((time.perf_counter() - t) * 1000)
    kp, sc = kp[0], sc[0]
    r = {k: [float(kp[i, 0]), float(kp[i, 1]), float(sc[i])] for i, k in enumerate(COCO)}
    r.update({k: [float(kp[i, 0]), float(kp[i, 1]), float(sc[i])] for k, i in {**FEET, **HAND_MCP}.items()})
    p["rtmw"] = r
    bx = np.array([[box[0], box[1], box[2] - box[0], box[3] - box[1]]], np.float32)
    t = time.perf_counter()
    inp = proc(cv2.cvtColor(im, cv2.COLOR_BGR2RGB), boxes=[bx], return_tensors="pt").to(dev)
    with torch.no_grad():
        out = vit(**inp, dataset_index=torch.tensor([0], device=dev))
    res = proc.post_process_pose_estimation(out, boxes=[bx])[0][0]
    k2, s2 = res["keypoints"].cpu().numpy(), res["scores"].cpu().numpy()
    ms["vitpose_h"].append((time.perf_counter() - t) * 1000)
    p["vitpose_h"] = {k: [float(k2[i, 0]), float(k2[i, 1]), float(s2[i])] for i, k in enumerate(COCO)}
    p["box"] = [float(v) for v in box]
    return p


def save(preds):
    tmp = OUT / "preds.tmp.json"; tmp.write_text(json.dumps(preds), encoding="utf-8"); os.replace(tmp, OUT / "preds.json")


preds = json.load(open(OUT / "preds.json", encoding="utf-8")) if (OUT / "preds.json").exists() else {}
for n, m in enumerate(man):
    if m["id"] in preds:
        continue
    lms = np.load(m["lm"]).astype(float); k = m["frame"]
    cap = cv2.VideoCapture(m["video"]); cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    cap.set(cv2.CAP_PROP_POS_FRAMES, max(0, k - 1))
    ims = {}
    for name, f in (("prev", k - 1), ("cur", k), ("next", k + 1)):
        if f < 0: continue
        ok, im = cap.read()
        if ok and f < len(lms): ims[name] = (im, f)
    cap.release()
    if "cur" not in ims:
        preds[m["id"]] = {"error": "frame not readable"}; continue
    ms = {"yolox_det": [], "rtmw": [], "vitpose_h": [], "mediapipe": []}
    p = {}
    for name, (im, f) in ims.items():
        q = run(im, lms[f], ms); q["mediapipe"] = mp_of(lms[f])
        if name == "cur": p.update(q)
        else: p[name] = q
    im = ims["cur"][0]; h, w = im.shape[:2]; s = min(1.0, 540 / h)  # same downscale as hd_pipeline.pose_video
    small = cv2.resize(im, (int(w * s), int(h * s))) if s < 1 else im
    t = time.perf_counter()
    mp_img.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(small, cv2.COLOR_BGR2RGB)))
    ms["mediapipe"].append((time.perf_counter() - t) * 1000)
    p["ms"] = {k2: round(float(np.mean(v)), 2) for k2, v in ms.items() if v}
    preds[m["id"]] = p
    if n % 25 == 0:
        save(preds); print(n, len(man), flush=True)
save(preds)
print("done", len(preds))
