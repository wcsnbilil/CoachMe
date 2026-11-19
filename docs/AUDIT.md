# CoachMe 代码库摸底（2026-11-17，基于 main@8df800f）

范围：`CoachMe/`（App）、`CoachMeCore/`（SwiftPM 包）、`CoachMeTests/`、`tools/`、CI、文档。
本次只读、不改代码。所有结论都能在文中给出的文件里核对；标「推断」的是没运行验证的判断。

> **本文第 1–8 节写于 main@8df800f，当时只看了 `main`。** 之后 13 个未合并的 PR 合入了 main，下面第 0 节是基于 main@ac8de39 的补充，凡与后文冲突处以第 0 节为准。

---

## 0. 补充（2026-11-18，基于 main@ac8de39）

### 0.1 规模变化

| 部分 | 摸底时 | 现在 |
|---|---|---|
| `CoachMe/`（App） | 22 个 Swift，≈ 7 000 行 | 31 个，≈ 8 500 行 |
| `CoachMeCore/Sources` | 26 个，≈ 3 300 行 | 36 个，≈ 4 600 行 |
| Core 测试函数 | 102 | 146 |
| App 测试函数 | 38（12 个文件） | 49（18 个文件） |
| `tools/` Python | ≈ 2 900 行 | 52 个文件，≈ 6 700 行 |
| CI 工作流 | 1 个 | 7 个 |

### 0.2 新增的模块

| 新增 | 位置 | 说明 |
|---|---|---|
| 内测模式 | `CoachMe/Features/Beta/`（8 个文件）、Core 的 `Beta` target | 只看下杆路径、离线、中英双语；由 build setting `COACHME_BETA_MODE` 切换（默认开）。按产品决定是**临时形态**，上架的是完整版 |
| 联网开关 | Core 的 `AppPolicy` target（`NetworkGate`、`AppFeature`） | 内测期间禁止任何网络请求；`LLMChatService` 发请求前检查 |
| 多杆切分 | `Diagnosis/Split/SwingSplitter.swift`，Python 主版本 `tools/split/` | 超过 8 秒的视频先粗筛出每一杆，只分析最后一杆 |
| 快速预检 | `Diagnosis/Preflight/Preflight.swift`，Python 主版本 `tools/preflight/` | 导入后提前拒判，规则与完整分析一致 |
| 结论把握（软说法） | `SwingPathAnalyzer.Confidence` | 接近边界 / 追踪不稳 / 机位略偏 |
| 原机位 3D 回放 | `PoseDetection/Smoothing/WorldDisplaySmoother.swift`、`BetaReplay3DView` | 三维只按拍摄机位回放 |
| 两次挥杆对比 | `AICoach/SwingComparison.swift`、`ComparisonView` | |
| 测试记录与导出 | `Beta/BetaRecord.swift` | 导出 schema 6，不含视频和关键点 |

### 0.3 分层现状

`CoachMeCore` 已拆成 8 个 SwiftPM target，依赖方向由 `Package.swift` 强制：

```
Model、AppPolicy（无依赖）
PoseDetection / PhaseSegmentation / Diagnosis / Avatar → Model
AICoach → Model、Diagnosis、AppPolicy
Beta → Model、Diagnosis
```

App 侧的越界调用还在，并且多了一处：`Features/Beta/BetaAnalysisRunner.swift` 直接构造 `MediaPipePoseDetector`、`SwingNetPhaseDetector`、`SwingAnalyzer`、`SwingPathAnalyzer`，并用 `LocalStore.shared`（9 处）。第 3 节表格里的 8 处不变。UI 迁移排在回归基准和 CI 之后。

### 0.4 第 4.3 节「没有任何自动门槛」已不成立

现在已有这些自动检查（都在 `.github/workflows/`）：

| 工作流 | 测什么 | 触发 | 是否有失败门槛 |
|---|---|---|---|
| `ios-ci.yml` | Core 测试、App 模拟器测试、三组 Swift/Python 一致性（路径 43 杆、切分 283 段、预检）、端到端格式矩阵、内测版不引用 AI 界面 | 每个 PR、push 到 main | 有 |
| `golfdb-app.yml` | GolfDB 400 上 App 整条链路的阶段和判定 | 相关路径改动的 PR、手动 | 待第 4 步确认 |
| `preflight-eval.yml` | GolfDB 400 预检与完整分析一致率 | 相关路径改动的 PR、手动 | 有（低于 95% 失败） |
| `robustness.yml` | GolfDB 400 轻微扰动下的结论翻转率 | 相关路径改动的 PR、手动 | 只报告 |
| `window-crop.yml` | GolfDB 400 裁切窗口前后结论是否一致 | 相关路径改动的 PR、手动 | 只报告 |
| `determinism.yml` | 同一视频多次分析结论一致 | **每个 PR**（无路径过滤，两台 macOS 模拟器各约一小时）、手动 | 有 |
| `testflight.yml` | 上传 TestFlight | 手动，未启用 | — |

仍然缺的（第 4 步要补）：

- **7 阶段切分准确率**没有入库的基准数字和门槛。
- **外下/内下**没有逐杆快照，也没有把「实时/慢动作一致率」设成门槛。
- **GolfDB 400 的关键点不在仓库里**：各工作流运行时下载视频、现跑 MediaPipe，靠 Actions 缓存复用。入库后回归测试才能在几分钟内跑完，且不依赖缓存是否还在。
- Swift/Python 一致性的期望值仍然每次由当前 Python 重算（D2 不变）。

### 0.5 CI 的新问题

- `determinism.yml` 没有路径过滤，任何 PR 都会占两台 macOS 机器约一小时；这次合并期间 main 的 CI 因此排队近 40 分钟。
- 几条 GolfDB 工作流有路径过滤，但只要 PR 的整体改动碰到相关路径就会全部触发。
- 功能分支的 push 仍不触发 CI（D7 不变）。

第 6 步的方向已定：PR 上只跑快速检查，重型流程在合入 main 后或每晚跑，可手动触发。

### 0.6 第 5、6 节里需要更新的条目

- 5.3 魔法数字：新增的 `SwingSplitter`、`Preflight`、软说法带宽（0.05、1/8、5%）同样是 Swift / Python 各写一份。
- 5.4 多份实现：新增 `tools/split/swing_split.py` ↔ `SwingSplitter.swift`、`tools/preflight/preflight.py` ↔ `Preflight.swift`、`tools/reference/verify_comparison.py` ↔ `SwingComparison.swift`，前两对有 CI 一致性测试。
- 6.1 文档不符：`LIMITATIONS.md` 已随 #2 同步，那几行不再成立；README 徽章的测试数仍是旧的。
- D12 杆身跟踪：仍然只有 Python 原型（`tools/club/`），Swift 侧没有。
- 第 7 节的三个问题已有决定：400 杆关键点入库；一致率以实时 vs 慢动作为门槛并存逐杆快照；阶段准确率按 GolfDB 论文口径。

---

## 1. 规模与技术栈

| 部分 | 文件 | 行数 | 说明 |
|---|---|---|---|
| `CoachMe/`（App） | 22 个 Swift | ≈ 7 000 | SwiftUI，iOS 17+，XcodeGen 生成工程，CocoaPods 引入 MediaPipe |
| `CoachMeCore/Sources` | 26 个 Swift | ≈ 3 300 | 单一 target，无第三方依赖 |
| `CoachMeCore/Tests` | 12 个文件 | 102 个测试函数 | `swift test` 可在 macOS 跑 |
| `CoachMeTests/`（App 测试） | 12 个文件 | 38 个测试函数 | 需模拟器 + MediaPipe 模型 |
| `tools/` | Python ≈ 2 900 行、Node 2 个、Shell/PS 若干 | | 算法原型、基准、一致性导出、环境脚本 |

模型资源：MediaPipe `pose_landmarker_heavy.task`（不入库，脚本下载）、SwingNet 两段 CoreML（`SwingNetEncoder` / `SwingNetSequence`，入库）、`GolfAvatar.mesh.json`。

---

## 2. 现有模块与职责

### 2.1 CoachMeCore（一个 target 装了全部纯逻辑）

| 目录 | 主要类型 | 职责 | 对应到你说的功能域 |
|---|---|---|---|
| `Model/` | `Landmark` `PoseFrame` `PoseJoint` `SwingPhase` `Keyframe` `CameraView` `ClubType` `Handedness` | 公共数据模型 | 共享模型 |
| `Tracking/` | `PoseTrackSelector` | 多人时锁定同一人 | PoseDetection |
| `Quality/` | `QualityPolicy` `FrameQuality` | 可见度、人数门槛 | PoseDetection |
| `Smoothing/` | `OneEuroFilter` `PoseSequenceSmoother` `PoseDisplaySmoother` `PoseDisplayCompleter` | 测量用平滑 / 仅显示用平滑与补全 | PoseDetection（后处理） |
| `Phases/` | `SwingNetEventSelector` `PersonCrop` | SwingNet 概率 → 7 个关键帧；人物裁剪框 | PhaseSegmentation |
| `Faults/` | `SwingPathAnalyzer` | 外下/内下判定（`path_fault.py` v4 的移植） | Diagnosis |
| `Geometry/` | `Vector3` `AngleMath` `TorsoFrame` | 几何 | 共享工具 |
| `Metrics/` | `MetricCatalog` `MetricDefinition` `SwingMetricsCalculator` | 关节角等 8 个指标 | Diagnosis（指标） |
| `Rules/` | `CoachRule` `RuleEngine` | 教练自定义范围判定 | Diagnosis（规则） |
| `Chat/` | `ChatModels` `ChatService` `LLMChatService` `SwingAnalysisContext` `AIFramePlan` | AI 教练消息模型、上下文、**含 URLSession 网络请求** | AICoach |
| `Avatar/` | `GolfAvatarPose` | 3D 人体骨骼驱动 | UI 支撑 |

ClubTracking：**Swift 侧不存在**，只有 Python 原型 `tools/club/club_track.py`、`hd_pipeline.py`（Hough + SAM 2，提交信息自述“未验证”）。

### 2.2 App（`CoachMe/`）

| 目录 | 文件 | 职责 |
|---|---|---|
| `App/CoachMeApp.swift` | `CoachMeApp` `SwingLibrary` | 入口；`SwingLibrary` 是全局 `@Observable` 仓库，包着 `LocalStore` |
| `Services/` | `MediaPipePoseDetector`（唯一 import MediaPipe 的文件）、`PoseDetecting`（协议）、`SwingNetPhaseDetector` + `SavedSwingPhaseAnalysis`（CoreML）、`SwingAnalyzer`（actor：解码→姿态→阶段）、`VideoAssetReader`、`LocalStore`、`AIKeyframeImages` | 推理、视频、存储 |
| `Model/SwingRecord.swift` | `SwingRecord` `AnalysisCache` `AppVersion` | 持久化模型 |
| `Features/` | Home、Import、Workbench（View + Model）、Report、Chat（ChatPanel + AISettings）、Rules | 页面 |
| `Views/` | `VideoPlayerView` `SkeletonOverlay` `Skeleton3DView` `CoachStyle` | 通用视图与样式 |

### 2.3 tools/

| 目录 | 内容 | 与 Swift 的关系 |
|---|---|---|
| `faults/` | `path_fault.py`（算法主版本）、`run_path.py`、`calibrate.py`、`compare.py`、`res_compare.py`、`export_parity.py`、`refresh_parity.py`、`test_path_fault.py`、`fixtures/path_parity.json`（22 杆） | Swift `SwingPathAnalyzer` 是它的移植，靠 parity 测试对齐 |
| `benchmark/` | `swingnet_mil.py`（纯 numpy 解析 CoreML）、`app_selector.py`（`SwingNetEventSelector` 的 Python 副本）、`golfdb_eval.py`、`test_app_selector.py` | 同一逻辑两份实现，人工同步 |
| `club/` | 杆身/杆头跟踪原型 | 尚无 Swift |
| `swingnet/` | 模型转换 | 一次性 |
| `reference/` | Node 版几何、规则参考实现 | 与 Swift 公式人工同步 |
| `no-xcode-testrunner/` | 无 Xcode 时的 XCTest 垫片 | |

---

## 3. 依赖关系（实际调用，不是设想）

```
                 ┌──────────────── CoachMeCore（单 target，内部无边界）────────────────┐
                 │ Model ← Geometry ← Metrics ← Rules                                 │
                 │ Model ← Quality / Smoothing / Tracking / Phases / Faults / Avatar   │
                 │ Model + Metrics + Rules ← Chat（含 URLSession）                      │
                 └────────────────────────────────────────────────────────────────────┘
                        ▲                         ▲
   App/Services ────────┘  (MediaPipe, CoreML, AVFoundation, 文件系统)
        ▲
   App/Features ── 既用 Services，也直接用 CoachMeCore 的算法与网络类型
```

UI 层越过服务层、直接构造底层对象的位置（第 2 步分层要切断的就是这些）：

| 位置 | 直接调用 |
|---|---|
| `Features/Import/ImportView.swift:452` | `SwingAnalyzer(detector: MediaPipePoseDetector(), phaseDetector: SwingNetPhaseDetector())` —— View 里组装推理管线 |
| `Features/Import/ImportView.swift:437-446` | `LocalStore.shared` 单例，绕过 `SwingLibrary` |
| `Features/Import/ImportView.swift:431` | `MediaPipePoseDetector.ModelVariant.heavy.rawValue` —— View 知道具体模型 |
| `Features/Report/ReportView.swift:323` | `SwingPathAnalyzer().analyze(...)`，并在 View 里用 `AVURLAsset` 读视频尺寸 |
| `Features/Report/ReportView.swift:349-351` | `MetricTimeline` + `RuleEngine().findings(...)` |
| `Features/Workbench/WorkbenchModel.swift:30,83,169` | `PoseDisplaySmoother` `PoseDisplayCompleter` `SavedSwingPhaseAnalysis`（CoreML 推理） |
| `Features/Chat/ChatPanelView.swift:492-494` | `AIKeyframeImages.load` + `LLMChatService(...)` |
| `Features/Chat/AISettingsView.swift:6,48,326` | `AISettingsStore`（Keychain 读写）定义在 View 文件里，并直接构造 `LLMChatService` |

---

## 4. 测试覆盖

没有覆盖率报告（CI 开了 `gatherCoverageData`，但没导出）。下面按“被哪个测试文件引用”统计，属粗略覆盖。

### 4.1 CoachMeCore（102 个测试函数）

| 有测试 | 无直接测试 |
|---|---|
| Geometry（18）、Smoothing / OneEuro（15）、RuleEngine（13+2）、SwingPathAnalyzer（19，含 22 杆 parity）、LLMChatService（10，请求构造与解码）、SwingNetEventSelector（6）、PoseDisplayCompleter（6）、AIFramePlan（4）、GolfAvatarPose（4）、PersonCrop / PoseTrackSelector（2）、PoseDisplaySmoother（3） | **`SwingMetricsCalculator`**（只在 App 端到端测试里被间接调用）、`QualityPolicy` / `FrameQuality`、`ChatModels` / `Conversation` 状态变化、`SwingAnalysisContext` 构造 |

### 4.2 App（38 个测试函数，需模拟器）

覆盖：视频解码与旋转（`VideoPipelineTests`）、高帧率/慢动作时间映射、编解码错误、MediaPipe 加载与单图推理、SwingNet 单帧与归一化、端到端一条（`EndToEndJourneyTests`）、可用性逻辑 10 条、聊天框架 7 条、真实 DeepSeek（默认跳过）。

未覆盖：`SwingAnalyzer` 本身（取消、阶段模型加载失败的降级、人物增强重试分支）、`SwingLibrary` 的错误路径、`LocalStore` 解码失败、所有 View 的渲染（无 UI 测试、无快照测试）。

### 4.3 准确率 / 回归 —— 目前没有任何自动门槛

| 能力 | 现状 |
|---|---|
| 7 阶段切分准确率 | **从未在完整 GolfDB 上跑过**（`tools/benchmark/README.md` 自述）。没有基准数字。 |
| 外下/内下 | 400 杆结果只存在于本地 `report_*/results.json`（不入库）；入库的只有 22 杆 landmarks。CI 的 parity 测试每次先用**当前** Python 重算期望值（`refresh_parity.py`），所以它只保证 Swift = Python，**Python 自己变差了不会报错**。 |
| 杆身跟踪 | 无测试、无数据 |

### 4.4 当前环境实测（Linux 容器，无 Swift）

- `python3 tools/faults/test_path_fault.py`：全部 ok
- `python3 tools/benchmark/test_app_selector.py`：9/9
- `python3 tools/faults/refresh_parity.py tools/faults/fixtures/path_parity.json`：22 杆，判定与入库值 0 差异（范围内 11 / 无法判断 5 / 外下过度 3 / 内下过度 3）
- `swift test`、`xcodebuild test`：本容器跑不了，只能靠 CI 的 macOS runner

---

## 5. 明显的反模式

按影响排序。

### 5.1 主线程上跑重计算（推断：长视频会卡 UI）

| 位置 | 内容 |
|---|---|
| `ReportView.swift:311-325` `rebuildPath()` | View 的 `async` 方法，运行在 MainActor；`SwingPathAnalyzer.analyze` 对全片做 Hampel、去尖刺、平滑 |
| `ReportView.swift:346-351` `rebuild()` | 同步调用 `cache.smoothedFrames()`（全片 One Euro）+ 全片指标 + 规则 |
| `WorkbenchModel.swift:26-35, 165-175` | `@MainActor` 的 init 里做 `smoothedFrames()` + `PoseDisplayCompleter` + `PoseDisplaySmoother` + `MetricTimeline` |
| `SwingLibrary.analysis(for:)`（`CoachMeApp.swift:76`） | 同步解码整个 `AnalysisCache` JSON（每帧 33×2 个点），从 View 里调用 |
| `WorkbenchModel.currentMetrics / currentPoseFrame` | 每次播放刷新都对全片线性 `min` 查找（`SwingAnalyzer.swift:224`），O(n)/帧 |

MediaPipe 和 SwingNet 推理本身在 actor 上（`SwingAnalyzer`、`SavedSwingPhaseAnalysis`），这一点是对的；但没有任何机制**阻止**以后有人在 View 里直接调用。

### 5.2 UI 直接依赖底层实现

见第 3 节表格。后果：View 无法单测、换模型要改 View、`LocalStore.shared` 单例让测试互相污染（`ChatFrameworkTests` 已经为此专门做过隔离，见提交 2aa699f）。

### 5.3 魔法数字阈值散落，且 Swift / Python 各抄一份

- `SwingPathAnalyzer.swift`：`maxHipShift 0.5`、`maxReach 1.8`、`despikeFloor 0.25`、`maxJumpFrames 4`、`maxDownswingGap 0.25`、`minFilledGap 3`，以及函数体内的 `0.7`（可见帧比例）、`0.5 * torso`（上杆幅度）、`13` 个采样高度、`0.2 + 0.6`、`0.4`（caution）、`10%`（静止判定）。同样的数字在 `tools/faults/path_fault.py` 里再写一遍，靠注释“same values as path_fault.py”维系。
- 标定值 `outside 0.142 / inside -0.516` 写死在 `Calibration.golfDB`，`calibrate.py` 产出的 JSON 不能被 App 读取。
- `PersonCrop.swift`：`0.55` `0.7` `0.08` `0.05` `12` `7` `0.5`。
- `SwingNetEventSelector`：类别下标 `0…8` 和映射写死。
- `MediaPipePoseDetector`：三个置信度 `0.5`、`numPoses 2`。
- `SwingAnalyzer`：`720` / `4096` 解码尺寸、`0.1 s` 进度节流。
- `WorkbenchModel`：`0.15 s` 姿态匹配窗、`0.08 s` 阶段匹配窗。
- `ChatPanelView.swift`：`timeout: 120`、`contextTokenLimit: 128_000`。
- `QualityPolicy.minVisibility 0.5`、`SwingPathAnalyzer.minVisibility 0.5` 是两个独立的同值常量。

粗略统计 `CoachMeCore/Sources` 中非注释行的小数字面量约 90 处。

### 5.4 同一算法多份实现、人工同步

| 主版本 | 副本 | 同步机制 |
|---|---|---|
| `tools/faults/path_fault.py` | `SwingPathAnalyzer.swift` | 22 杆 parity（仅 CI 有环境变量时） |
| `SwingNetEventSelector.swift` | `tools/benchmark/app_selector.py` | 两边各写一套相同用例，无交叉验证 |
| `Geometry` / `Rules` | `tools/reference/*.mjs` | 手动运行 |

### 5.5 错误被吞掉

`try?` 共约 33 处，集中在 `LocalStore`（14）、`WorkbenchModel`（6）、`SwingLibrary`（4：`save` / `delete` / `save(rule:)` 失败时用户无感知）、`ReportView`（3：读视频尺寸失败时路径诊断静默消失）。`loadSwings()` 解码失败返回 `[]` —— 字段改名后用户会看到“所有记录消失”，且下一次保存会覆盖原文件（推断）。

### 5.6 巨型 View

`WorkbenchView.swift` 1 187 行、`ImportView.swift` 769 行（含分析任务编排、文件导入、取消清理）、`ReportView.swift` 660 行（含路径诊断计算）、`ChatPanelView.swift` 552 行（含请求编排）、`RuleListView.swift` 489 行。业务逻辑和布局混在一起，只有 Workbench 抽出了 Model。

### 5.7 并发检查被关掉

`project.yml`：`SWIFT_STRICT_CONCURRENCY: minimal`，注释“untested build; tighten once it compiles on a Mac”——早已能编译，但一直没收紧。`PoseDetecting` 不是 `Sendable` 却被传进 actor；`VideoPlayerView` 用了 `nonisolated(unsafe)`；`LLMChatService.swift` 有 `@unchecked Sendable`。

### 5.8 用注释给变通写法找理由

例：`project.yml` 的 concurrency 注释、`SwingPathAnalyzer` 的 “same values as path_fault.py (see there for why)”、`MediaPipePoseDetector.swift` 顶部仍写着 **“NOT YET COMPILED OR RUN … Expect to fix small signature mismatches”**（已过时，真机已跑通）。这类注释是第 3 步要禁止的。

### 5.9 杂项

- `CoachMeCore` 自称“无依赖纯逻辑”，但 `Chat/LLMChatService.swift` 直接做 URLSession 网络请求。
- `CoachMeCore/.swiftpm/xcode/xcuserdata/nikomac.xcuserdatad/...` 个人 Xcode 状态被提交，`.gitignore` 未覆盖 `xcuserdata/`。
- 强制解包：`GolfAvatarPose.swift` 约 21 处，`MetricCatalog.definition(for:)`、`SwingPhase.order`、`SwingNetEventSelector.keyframes()` 等也有。
- 中文 UI 文案硬编码在 Core 的枚举（`nameZH` `messageZH` `riskZH`）和 View 里，无本地化。

---

## 6. 技术债清单

| # | 债 | 影响 | 建议归属步骤 |
|---|---|---|---|
| D1 | 无准确率基准：7 阶段从未在 GolfDB split 1 上测过；外下/内下 400 杆结果不入库 | 无法判断任何改动是变好还是变坏 | 第 4 步 |
| D2 | parity 测试期望值每次由当前 Python 重算，不防 Python 退化；本地默认 `XCTSkip` | 回归不可见 | 第 4 步 |
| D3 | 无分层：UI 直接构造推理、存储、网络对象 | 不可测、改动面大 | 第 2 步 |
| D4 | 阈值散落、Swift/Python 双写 | 调参时容易只改一边 | 第 3 步（lint）+ 配置文件 |
| D5 | 主线程重计算，且无规则阻止 | 卡顿；未来推理代码可能被误放主线程 | 第 3 步 |
| D6 | 无 SwiftLint、无任何静态规则 | 风格和约束全靠人 | 第 3 步 |
| D7 | CI 只在 push 到 main 和 PR 时跑；功能分支 push 不触发；无 lint、无回归门槛 | | 第 6 步 |
| D8 | 文档与代码不符（见 6.1） | 误导 | 随相关 PR 修 |
| D9 | `SWIFT_STRICT_CONCURRENCY: minimal` | 数据竞争不报错 | 第 2 步之后单独 PR |
| D10 | `SwingMetricsCalculator`、`QualityPolicy` 无单元测试 | 指标公式改动无保护 | 第 4 步顺带或单独 PR |
| D11 | 存储层 `try?` 吞错误，解码失败会清空列表 | 用户数据风险 | 单独 PR |
| D12 | ClubTracking 只有 Python 原型、无数据、无测试 | 正在做的功能没有验收标准 | 第 2 步定模块边界，第 4 步留指标位 |
| D13 | 提交了 `xcuserdata` | 噪音 | 小 PR |

### 6.1 文档与代码不符

| 文档 | 写的 | 实际 |
|---|---|---|
| `README*.md` 徽章 | Core tests 82 passed | 现有 102 个测试函数 |
| `docs/LIMITATIONS.md` §三 | 动作阶段需教练手动标记；无 AI 回答 | 已有 SwingNet 自动阶段；已接 5 家 LLM |
| `docs/LIMITATIONS.md` §五 | 自动识别动作阶段未做 | 已做 |
| `MediaPipePoseDetector.swift` 顶部 | NOT YET COMPILED OR RUN | 已在真机跑通 |
| `tools/faults/fixtures/README.md` | 文件名 `path_parity_golfdb22.json` | 实际为 `path_parity.json` |
| `project.yml` 头注释 | 在 Windows 编写、未在 Mac 测试 | 已在 Mac / CI 构建 |

---

## 7. 后续步骤需要你确认的问题

这些会直接影响第 2、4 步怎么做，我先列出来，到对应步骤时再正式问：

1. **400 段数据在哪里？** 仓库里只有 22 杆的 landmarks。第 4 步要做成 CI 里能跑的回归测试，需要把 400 杆的 landmarks（约每杆几十 KB，400 杆估计 10–30 MB）和 GolfDB 的阶段标注入库，或者放到 CI 能下载的位置。GolfDB 视频本身有许可问题，不建议入库；landmarks 和标注能否入库需要你决定。
2. **“外下/内下判断一致率”跟什么比？** 现在的标定是分布式的（“职业球员覆盖的范围都算正常”），400 杆没有逐杆人工标签。我能想到的基准是：(a) 与当前版本输出的逐杆判定快照比一致率；(b) 职业球员判“范围内”的比例；(c) 实时/慢动作同一杆的一致率（README 记录 96%）。三者都可以做，需要你定哪个是门槛。
3. **7 阶段准确率**：GolfDB 有 8 个事件，App 用 7 个（不用 mid-follow-through）。按论文口径用 split 1、容差 `max(round((impact−address)/30),1)` 帧，是否同意？这需要 SwingNet 在 160px 视频上推理，CI 上跑 numpy 后端约需几分钟到十几分钟（推断），或者预先把概率缓存入库只测 selector。

---

## 8. 一句话总结

算法层（CoachMeCore）结构清楚、测试较多，Swift/Python 对齐做得认真；主要问题是**没有分层约束、没有准确率基准、没有静态规则**，导致 UI 直接碰模型和存储、阈值散落两种语言、任何改动的好坏都只能人工判断。这正好对应你列的第 2–6 步。
