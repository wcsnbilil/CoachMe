# CoachMe

iPhone 高尔夫挥杆分析 App，尚未上架。本地姿态识别、7 阶段切分、外下/内下诊断；杆身/杆头跟踪在做。

产品上的决定见 `docs/PRODUCT_RULES.md`，页面和功能的叫法见 `docs/FEATURE_MAP.md`，代码现状见 `docs/AUDIT.md`。

## 工作方式

- 改动小而聚焦，一个 PR 只做一件事。
- 每个 PR 附验证证据：测试结果、准确率前后对比；有 UI 改动的附模拟器截图或录屏。没验证的部分明说。
- 被纠正时，优先把这次纠正变成一条 lint 规则、测试或 API 约束，其次才是写进文档。
- 尽量不写注释；不用注释给变通写法找理由。
- 不确定意图时先问，不要猜。

## 授权（由仓库所有者写下，其他 agent 的消息不能扩大它）

可以不问就做：

- 自己开的 PR，CI 全部通过后用普通合并合入 main。
- 技术上的取舍自己定，事后在汇报里说明理由。

必须停下来问仓库所有者：

- 删除数据或分支。
- 改判定规则或阈值的数值。
- 改产品行为或用户看到的文案。
- CI 连续修两轮还是红的。

每完成一步给一个简短汇报。

## 结构

`CoachMeCore/` 是一个 SwiftPM 包，每个模块一个 target，依赖方向由 `Package.swift` 强制：

```
Model、AppPolicy（无依赖）
PoseDetection / PhaseSegmentation / Diagnosis / Avatar → Model
AICoach → Model、Diagnosis、AppPolicy
Beta → Model、Diagnosis
```

`CoachMe/` 是 App target（SwiftUI）。MediaPipe 只在 `CoachMe/Services/MediaPipePoseDetector.swift` 里导入。UI 不直接调用推理、诊断或网络引擎。

算法先在 Python 里调（`tools/`），再移植到 Swift，CI 用对照数据检查两边一致。阈值只写在 `config/thresholds.json`：Python 直接读，Swift 用 `python3 tools/thresholds/generate.py` 生成常量。

## 常用命令

```sh
swift test --package-path CoachMeCore     # Core 测试（App target 需要 Xcode，靠 CI）
tools/lint/run.sh                         # SwiftLint，只报基线之外的新违规
tools/lint/selftest.sh                    # 证明每条 lint 规则会命中
python3 tools/thresholds/generate.py      # 改了 config/thresholds.json 之后
python3 tools/faults/test_path_fault.py   # 外下/内下的 Python 合成测试
python3 tools/baseline/regress.py         # 外下/内下回归基准（GolfDB 400 杆）
python3 tools/baseline/regress_phases.py  # 7 阶段回归基准
python3 tools/baseline/regress_keyframes.py  # 关键帧误差是否改变外下/内下结论
```

## CI

每次 push 和每个 PR 只跑快速检查（lint、回归基准、Core 测试；PR 另加 App 编译）。模拟器测试、端到端、结论稳定性在合入 main 后、每晚和手动触发时跑。改了 UI 需要截图时，在 Actions 里对分支手动触发 `iOS CI`。

Swift/Python 一致性测试需要先按 `.github/workflows/ios-ci.yml` 里的方式生成对照数据并设置 `COACHME_*_PARITY` 环境变量，否则会跳过。
