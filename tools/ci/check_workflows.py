"""Checks two workflow rules.

Every workflow runs its steps with pipefail, so `cmd | tee -a "$GITHUB_STEP_SUMMARY"` fails when cmd fails.
GitHub's default shell is `bash -e {0}` (no pipefail): a failing regression gate piped into tee used to
pass. `defaults: run: shell: bash` switches every step to `bash --noprofile --norc -eo pipefail {0}`.

No job runs with `if: always()`: that also runs it after the whole run was cancelled (a newer push), where it
reads missing artifacts and fails. `if: ${{ !cancelled() }}` still runs it after a failed dependency.

  python3 tools/ci/check_workflows.py                 # .github/workflows/*.yml
  python3 tools/ci/check_workflows.py a.yml b.yml
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULTS = re.compile(r"(?m)^defaults:\n[ ]+run:\n[ ]+shell: bash[ ]*$")
SHELL = re.compile(r"(?m)^[ ]+(?:- )?shell:[ ]*(.+?)[ ]*$")
JOB_ALWAYS = re.compile(r"(?m)^    if:.*always\(\)")


def problems(path):
    text = path.read_text(encoding="utf-8")
    found = []
    defaults = DEFAULTS.search(text)
    if not defaults:
        found.append("缺少顶层 `defaults: run: shell: bash`（GitHub 默认 shell 没有 pipefail，管道前面的命令失败不会让步骤失败）")
    for match in SHELL.finditer(text):
        if match.group(1) != "bash":
            line = text.count("\n", 0, match.start()) + 1
            found.append(f"第 {line} 行把 shell 改成了 `{match.group(1)}`，只能用 bash")
    for match in JOB_ALWAYS.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        found.append(f"第 {line} 行：任务级 `if: always()` 在整次运行被取消后也会跑，改用 `if: ${{{{ !cancelled() }}}}`")
    return found


def main():
    paths = [Path(p) for p in sys.argv[1:]] or sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    failed = 0
    for path in paths:
        for problem in problems(path):
            print(f"{path}: {problem}")
            failed = 1
    if not failed:
        print(f"{len(paths)} 个工作流都开了 pipefail，没有任务级 always()")
    sys.exit(failed)


if __name__ == "__main__":
    main()
