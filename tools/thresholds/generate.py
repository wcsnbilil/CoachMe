"""Writes the Swift constants for config/thresholds.json.

  python3 tools/thresholds/generate.py           # rewrite the generated file
  python3 tools/thresholds/generate.py --check   # exit 1 if it is out of date
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config" / "thresholds.json"
GENERATED = ROOT / "CoachMeCore/Sources/Diagnosis/Generated"
OUTPUTS = {
    "swingPath": GENERATED / "SwingPathThresholds.swift",
    "swingSplit": GENERATED / "SwingSplitThresholds.swift",
    "preflight": GENERATED / "PreflightThresholds.swift",
}


def literal(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    return repr(value)


def render(section, values):
    name = section[0].upper() + section[1:] + "Thresholds"
    lines = ["// Generated from config/thresholds.json by tools/thresholds/generate.py.", "", f"public enum {name} {{"]
    lines += [f"    public static let {key} = {literal(value)}" for key, value in values.items()]
    return "\n".join(lines + ["}", ""])


def main():
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    stale = []
    for section, path in OUTPUTS.items():
        text = render(section, config[section])
        if "--check" in sys.argv:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(path.relative_to(ROOT))
        else:
            path.write_text(text, encoding="utf-8")
            print(f"wrote {path.relative_to(ROOT)}")
    if stale:
        print("生成的阈值文件不是最新的：" + "、".join(map(str, stale)))
        print("改阈值只改 config/thresholds.json，然后运行 python3 tools/thresholds/generate.py。")
        sys.exit(1)


if __name__ == "__main__":
    main()
