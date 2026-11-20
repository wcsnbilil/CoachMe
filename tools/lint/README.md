# Lint

```sh
tools/lint/run.sh                    # 跑全部规则，只报基线之外的新违规
tools/lint/selftest.sh               # 用 selftest/ 里的样例证明每条规则会命中
tools/lint/run.sh --update-baseline  # 修掉存量违规后重写基线
```

需要 SwiftLint 0.59.1（CI 用同一版本）。不在 PATH 里时用 `SWIFTLINT=/path/to/swiftlint` 指定。

| 配置 | 规则 | 范围 |
|---|---|---|
| `.swiftlint.yml` | `ui_calls_engine`、`mediapipe_outside_adapter`、`inference_bound_to_main_thread`、`workaround_comment`、`inline_lint_disable` | 全部 Swift |
| `.swiftlint-thresholds.yml` | `no_magic_numbers` | PoseDetection、PhaseSegmentation、Diagnosis、`CoachMe/Services` |

加规则：写进对应的配置，在 `selftest/` 加一个会命中的样例并在 `expected.txt` 里登记。

基线（`baseline-*.json`）记录规则生效前就存在的违规。CI 要求它只变小。
