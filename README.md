# CoachMe

高尔夫挥杆分析与教学 iOS App。视频 → 骨架 → 角度 → 教练参考范围 → 反馈 → AI 对话。

## 当前状态（2026-09-09，已在 macOS + Xcode 15.4 上完整构建并运行）

| 模块 | 状态 |
|---|---|
| `CoachMeCore` 编译 | ✅ 0 error 0 warning |
| `CoachMeCore` 单元测试 | ✅ **28/28 通过**（真 XCTest） |
| iOS App 目标构建 | ✅ **BUILD SUCCEEDED**（Xcode 15.4 / iOS 17.5 SDK，含 MediaPipe pod 链接） |
| `CoachMeTests`（聊天框架 + MediaPipe 冒烟 + 端到端） | ✅ **14/14 通过**（iPhone 15 模拟器） |
| MediaPipe 模型加载与推理 | ✅ 真实照片跑通：33 个关键点 + world landmarks，CoachMeCore 算出角度 |
| App 启动 | ✅ 模拟器启动正常，首页渲染正确，无崩溃 |
| 几何公式数值验证 | ✅ 31/31 |
| 规则判定优先级验证 | ✅ 25/25 |
| 真机运行 / 真实**挥杆视频**端到端 | ❌ **未验证**（静态照片已通，视频解码与逐帧时间戳未验证） |
| 骨架对齐、角度准确度、性能 | ❌ **未验证**（见 LIMITATIONS） |
| 历史对比 UI、关键点平滑、实时摄像头 | ⬜ 未开始 |

首次在 macOS 上构建时修掉了 87 个问题，分五类，详见
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) 第五节。

完整状态与限制见 [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md)。

## 结构

```
CoachMeCore/          纯 Swift 逻辑包，不依赖 SwiftUI / AVFoundation / MediaPipe
  Sources/
    Model/            关键点、帧、动作阶段、关键帧
    Geometry/         向量、角度、躯干坐标系
    Metrics/          指标定义目录 + 计算器
    Quality/          可见度门槛与帧级质量
    Rules/            教练规则与判定引擎
    Chat/             消息、会话、分析上下文、ChatService 接口
  Tests/              XCTest（28/28 通过）

CoachMe/              iOS App 目标（构建通过，模拟器可运行）
tools/reference/      Node 数值参考，用于在无 Swift 环境时验证公式
tools/no-xcode-testrunner/  只有 CLT、没有 Xcode 时跑 XCTest 套件的垫片
tools/setup-xcode-project.sh  生成工程 + 装 pod + 降工程格式到 Xcode 15 可读
docs/                 指标定义、Mac 构建步骤、限制说明
project.yml           XcodeGen 工程描述
Podfile               MediaPipeTasksVision 0.10.21（版本锁定，见文件内说明）
```

## 构建与测试

```bash
tools/setup-xcode-project.sh              # xcodegen + pod install + 工程格式降级
xcodebuild -workspace CoachMe.xcworkspace -scheme CoachMe \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
swift test --package-path CoachMeCore     # 28/28
```

`tools/setup-xcode-project.sh` 会把工程格式降到 objectVersion 56——XcodeGen 2.45
和 CocoaPods 1.16 默认写 77（Xcode 16 格式），Xcode 15.4 打不开。脚本内有说明。

### 不装 Xcode 也能跑的验证

```bash
swift build --package-path CoachMeCore    # 编译核心逻辑包
tools/no-xcode-testrunner/run.sh          # 28/28（绕开缺失的 XCTest）
node tools/reference/verify_geometry.mjs  # 31/31
node tools/reference/verify_rules.mjs     # 25/25
```

`swift test` 在只装了 Command Line Tools 的机器上会报 `error: XCTest not available`
（XCTest 只随完整 Xcode 分发）。`tools/no-xcode-testrunner/` 用一个最小 XCTest 垫片
编译原封不动的测试文件来绕开，说明见该目录的 README。装了 Xcode 后请直接用 `swift test`。

`tools/reference/` 下的两个 node 脚本复刻 Swift 中的同一批公式与判定顺序，最初用于
在没有 Swift 工具链时确认**算法本身**正确。

以上都不能证明 iOS App 目标可编译或可运行——那需要完整 Xcode。

## 在 Mac 上继续

见 [`docs/MAC_SETUP.md`](docs/MAC_SETUP.md)。

## 三条不可退让的产品规则

1. **算不出来就说算不出来。** 任何指标在数据不足时显示「无法可靠计算」并给出原因，
   永远不用 0、默认角度或推算值填充。
2. **不编标准。** App 不内置任何参考范围。范围由教练录入，附来源与适用条件。
   超出范围只表述为「超出你设置的范围」，不表述为「动作错误」。
3. **不假装有 AI。** v1 的 `UnconfiguredChatService` 不发任何网络请求，
   只返回「尚未连接」状态，绝不生成教练式回答。
