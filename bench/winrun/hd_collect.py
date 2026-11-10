"""Collect 1080p high-frame-rate / slow-motion golf swing videos, three views (face-on, down-the-line, side).
Niko 2026-11-09: "重新下载素材 包括正面 正后方 侧面 1000份以上 1080p 120帧或者慢动作".
Videos stay on this PC (coachme-bench\hd_swings), never uploaded. Resumable: rerun to continue.
usage: python hd_collect.py search | meta | download | report"""
import json, re, subprocess, sys, time
from pathlib import Path

OUT = Path(r"C:\Users\k8881\coachme-bench\hd_swings")
META, VID = OUT / "meta", OUT / "video"
CAND, KEEP = OUT / "candidates.jsonl", OUT / "keep.jsonl"
YTDLP = str(Path(sys.executable).with_name("yt-dlp.exe"))
VIEWS = {
    "face_on": ["golf swing slow motion face on", "face on golf swing slow mo 4k", "pga tour swing face on slow motion",
                "golf driver swing face on super slow motion", "iron swing face on slow motion", "lpga swing face on slow motion",
                "amateur golf swing face on slow motion", "golf swing 240fps face on", "golf swing front view slow motion",
                "korn ferry swing face on slow motion", "golf swing face view slow motion 1080p", "golf swing slow motion front"],
    "dtl": ["golf swing slow motion down the line", "down the line golf swing slow mo 4k", "pga tour swing down the line slow motion",
            "driver swing down the line super slow motion", "iron swing down the line slow motion", "lpga swing down the line slow motion",
            "amateur golf swing down the line slow motion", "golf swing 240fps down the line", "golf swing behind view slow motion",
            "golf swing from behind slow motion", "korn ferry swing down the line slow motion", "golf swing dtl slow mo"],
    "side": ["golf swing side view slow motion", "golf swing slow motion side angle", "golf swing 45 degree angle slow motion",
             "golf swing target view slow motion", "golf swing from the target slow motion", "golf swing rear view slow motion",
             "golf swing overhead slow motion", "golf swing multiple angles slow motion", "golf swing all angles slow motion",
             "golf swing 360 slow motion"],
    "side2": ["golf swing side on slow motion", "golf swing side angle 4k slow motion", "golf swing from the side super slow motion",
              "golf swing target line view slow motion", "golf swing behind the target slow motion", "golf swing camera angle face on and down the line slow motion",
              "pga tour swing side view slow motion", "lpga swing side view slow motion", "driver swing side view slow motion 4k",
              "iron swing side view slow motion", "amateur golf swing side view slow motion", "golf swing slow motion 2 angles",
              "golf swing slow motion trackman range side angle", "golf swing face on and down the line slow motion 4k",
              "golf swing 45 degree camera angle slow mo", "golf swing opposite angle slow motion"],
}
SLOW = re.compile(r"slow[\s-]*mo|super\s*slow|slo[\s-]*mo|\b(120|240|480|960)\s*fps|high\s*speed|慢动作|慢镜头|スロー", re.I)


def search():
    OUT.mkdir(parents=True, exist_ok=True)
    seen = {json.loads(l)["id"] for l in CAND.open(encoding="utf-8")} if CAND.exists() else set()
    for view, qs in VIEWS.items():
        for q in qs:
            r = subprocess.run([YTDLP, f"ytsearch80:{q}", "--flat-playlist", "-j"], capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            with CAND.open("a", encoding="utf-8") as fh:
                for line in r.stdout.splitlines():
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    d = e.get("duration") or 0
                    if e["id"] in seen or (d and d > 900):
                        continue
                    seen.add(e["id"])
                    fh.write(json.dumps({"id": e["id"], "title": e.get("title"), "channel": e.get("channel") or e.get("uploader"),
                                         "duration": d, "view_query": view, "query": q}, ensure_ascii=False) + "\n")
            print(view, q, len(seen), flush=True)


def meta():
    META.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(l) for l in CAND.open(encoding="utf-8")]
    for n, c in enumerate(rows):
        p = META / f"{c['id']}.json"
        if p.exists():
            continue
        r = subprocess.run([YTDLP, f"https://www.youtube.com/watch?v={c['id']}", "-j", "--skip-download", "--sleep-requests", "1"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        info = {}
        try:
            full = json.loads(r.stdout.splitlines()[-1])
            fm = [f for f in full.get("formats", []) if f.get("vcodec") not in (None, "none")]
            info = {k: full.get(k) for k in ("id", "title", "description", "channel", "duration", "upload_date", "view_count", "tags")}
            info["formats"] = sorted({(f.get("height") or 0, round(f.get("fps") or 0)) for f in fm})
        except (ValueError, IndexError):
            info = {"id": c["id"], "error": r.stderr[-300:]}
        p.write_text(json.dumps(info, ensure_ascii=False), encoding="utf-8")
        if n % 25 == 0:
            print("meta", n, len(rows), flush=True)
    select()


def select():
    keep = []
    for l in CAND.open(encoding="utf-8"):
        c = json.loads(l)
        p = META / f"{c['id']}.json"
        if not p.exists():
            continue
        m = json.loads(p.read_text(encoding="utf-8"))
        if "formats" not in m:
            continue
        hd = [(h, f) for h, f in m["formats"] if h >= 1080]
        if not hd:
            continue
        text = f"{m.get('title', '')} {m.get('description', '')[:600]} {' '.join(m.get('tags') or [])}"
        hfr = max(f for h, f in hd) >= 100
        slow = bool(SLOW.search(text))
        if not (hfr or slow) or not re.search(r"golf|高尔夫|ゴルフ", text, re.I):
            continue
        t = text.lower()
        view = ("face_on" if re.search(r"face[\s-]*on|front view|正面", t) else
                "dtl" if re.search(r"down[\s-]*the[\s-]*line|\bdtl\b|from behind|behind view|后方", t) else
                "side" if re.search(r"side view|side angle|45|target view|rear view|侧面", t) else
                "multi" if re.search(r"angles|360", t) else c["view_query"] + "?")
        keep.append({"id": c["id"], "title": m.get("title"), "channel": m.get("channel"), "duration": m.get("duration"),
                     "view": view, "hfr_1080": hfr, "slow_text": slow, "max_fps_1080": max(f for h, f in hd)})
    with KEEP.open("w", encoding="utf-8") as fh:
        for k in keep:
            fh.write(json.dumps(k, ensure_ascii=False) + "\n")
    print("keep", len(keep), flush=True)


def download():
    VID.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(l) for l in KEEP.open(encoding="utf-8")]
    for n, k in enumerate(rows):
        if [p for p in VID.glob(f"{k['id']}.*") if p.suffix not in (".part", ".ytdl")]:
            continue
        subprocess.run([YTDLP, f"https://www.youtube.com/watch?v={k['id']}",
                        "-f", "bv*[height=1080][ext=mp4]/bv*[height=1080]/bv*[height>=1080]",
                        "-o", str(VID / "%(id)s.%(ext)s"), "--sleep-requests", "1", "--ignore-errors", "--no-playlist"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
        if n % 10 == 0:
            print("download", n, len(rows), flush=True)


def report():
    rows = [json.loads(l) for l in KEEP.open(encoding="utf-8")]
    have = {p.stem for p in VID.glob("*")} if VID.exists() else set()
    from collections import Counter
    print("keep", len(rows), "downloaded", sum(r["id"] in have for r in rows))
    print("views", Counter(r["view"] for r in rows))
    print("hfr", sum(r["hfr_1080"] for r in rows), "slow text", sum(r["slow_text"] for r in rows))
    print("minutes", round(sum((r["duration"] or 0) for r in rows) / 60))


if __name__ == "__main__":
    {"search": search, "meta": meta, "download": download, "report": report, "select": select}[sys.argv[1]]()
