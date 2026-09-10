# 已知限制与验证状态

本文件记录**当前真实状态**。凡未实际执行的验证，一律标为「未验证」，不写推测结论。

## 一、验证状态总表

| 项目 | 状态 | 说明 |
|---|---|---|
| 几何公式数值正确性 | ✅ **已验证** | `node tools/reference/verify_geometry.mjs` → **31/31 通过**（本机实际执行） |
| 规则引擎判定优先级 | ✅ **已验证** | `node tools/reference/verify_rules.mjs` → **25/25 通过**（本机实际执行） |
| `CoachMeCore` 能否编译 | ✅ **已验证** | `swift build` 0 error 0 warning |
| `CoachMeCore` 测试是否通过 | ✅ **已验证** | **28/28**（真 XCTest，Xcode 15.4） |
| iOS App 目标能否编译链接 | ✅ **已验证** | `xcodebuild ... build` → BUILD SUCCEEDED（iOS 17.5 SDK） |
| `CoachMeTests/ChatFrameworkTests.swift` | ✅ **已验证** | **6/6**（iPhone 15 模拟器） |
| CocoaPods 能否装成功 | ✅ **已验证** | MediaPipeTasksVision 0.10.21 + MediaPipeTasksCommon 0.10.21 安装并链接成功 |
| App 能否启动 | ✅ **已验证** | 模拟器启动，首页渲染正确，无崩溃 |
| 关键点平滑 | ✅ **已实现并调参** | One Euro 滤波，参数在真实 24 fps 素材上扫描确定；上杆平台抖动 3.64° → 1.58° |
| MediaPipe 能否加载模型并推理 | ✅ **已验证** | 真实照片跑通：personCount=1、33 个关键点、world landmarks 齐全，CoachMeCore 据此算出角度（`PoseDetectorFixtureTests`） |
| 真实**挥杆视频**端到端 | ❌ **未验证** | 静态单帧已通；`VideoAssetReader` 的解码、旋转校正、逐帧时间戳单调性均未验证 |
| MediaPipe 能否加载模型 | ❌ **未验证** | 需要 macOS + 真机 |
| 骨架与视频是否对齐 | ❌ **未验证** | 需要真机 + 真实视频 |
| 二维角度是否符合人工标注 | ❌ **未验证** | 需要标注数据 |
| 三维旋转是否准确 | ❌ **未验证，且短期内无法验证** | 需要标定、多视角或动作捕捉参考 |
| 性能 / 内存 / 电量 | ❌ **未验证** | 需要真机 Instruments |

**本项目当前没有任何准确率数字。** 任何位置都不应出现「精度 95%」这类表述，
因为没有做过对照测量。

## 二、方法学限制

### 三维数据是模型估计，不是动作捕捉

MediaPipe world landmarks 由 GHUM 人体形态模型生成。官方文档
（[Pose Landmarker 概览](https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker)）
**没有定义**其原点约定、单位刻度和坐标轴方向，只说明它是"3-dimensional"估计。

因此本项目：
- 全部三维读数标注为「模型估计」
- 躯干坐标系**只由被测者自身关键点构建**，不依赖任何轴向约定
- 绝不把髋部中心坐标系当作球场世界坐标系

### 目标线与地面方向未知

单机位、未标定的手机视频**无法**确定目标线方向或地面平面。因此肩/髋转角只做
**相对准备姿势**的测量。任何声称「相对目标线转了 X 度」的说法在本项目中都是不成立的。

### 可见度 ≠ 准确度

MediaPipe 的 `visibility` / `presence` 是模型对该点是否被遮挡的判断。
本项目**只用它作为"是否计算"的门槛**，绝不把它当作角度测量的准确率。
一个完全可见的关键点仍然可能被模型放错位置。

### 单目视频的固有歧义

上臂与躯干夹角在三维中无法区分手臂向前抬、向侧抬还是向后抬——这三种动作可能得到
相同数值。沿目标线机位下尤其明显。UI 中已附此说明。

## 三、产品范围限制（v1）

| 限制 | 原因 |
|---|---|
| 动作阶段需**教练手动标记** | 自动识别未经标注数据验证；标错阶段会让所有按阶段生效的规则失效 |
| 不内置任何参考范围 | 不编造职业标准或统一最佳角度。范围一律由教练自己录入，并附来源 |
| 无 AI 回答 | `UnconfiguredChatService` 不发任何网络请求，只返回「尚未连接」状态，不生成教练式回答 |
| 不测量杆面/杆速/前臂旋转 | 需要额外识别能力与独立验证，见 `METRICS.md` 末节 |
| 仅支持相册导入 | 实时摄像头识别为后续功能 |
| 无账号、无云同步 | v1 全部数据留在本机 |

## 四、已写完但未编译的部分

以下代码**已经写完**，但**从未编译过**，第一次在 Xcode 打开时应预期出现签名不匹配、
API 名称差异等编译错误：

- SwiftUI 界面层：首页、导入与拍摄指导、分析工作台、报告、规则管理、聊天面板、三维骨架视图
- MediaPipe 封装（`MediaPipePoseDetector`）——**风险最高**，API 名称按官方 iOS 文档写，
  但未对照真实 SDK 头文件验证
- 视频解码管线（`VideoAssetReader`）：`AVVideoComposition` 处理旋转/镜像，PTS 时间戳
- 骨架叠加坐标变换（`VideoDisplayGeometry`）：letterbox 修正
- 本地存储（`LocalStore`）
- Swift Charts 角度曲线

## 五、确实还没做的

- 两次挥杆的历史对比 UI（`SwingAnalysisContext.ComparisonSummary` 结构已定义，
  比较逻辑与界面未实现）
- 关键点平滑滤波（`SmoothingParameters` 已定义并会被记录，但尚未有实现，
  当前一律使用原始关键点）
- 实时摄像头识别
- 英文本地化（文案已集中，但未抽成 `.strings`）

## 五、需要真实数据才能推进的验证

拿到 Mac 和真实挥杆视频后，建议按此顺序建立验证基线：

1. **人工标注对照**：挑 10 帧，用图像标注工具人工量肘部角度，与 App 读数对比，
   记录逐帧差值。这是**唯一**能支撑"二维角度可信"说法的证据。
2. **重复性测试**：同一段视频跑三次，确认结果完全一致（缓存与推理是否分离正确）。
3. **视角敏感性**：同一次挥杆用正面和沿目标线各拍一次，比较同一指标的差异，
   量化视角影响。
4. **遮挡行为**：故意拍一段有遮挡的视频，确认相应帧显示「无法可靠计算」而非数字。

三维旋转的验证需要动作捕捉或多视角标定设备。在拿到之前，
`shoulderLineRotation` / `hipLineRotation` / `shoulderHipSeparation`
应始终以「未验证的估计值」呈现。

## 五、macOS 首次构建时修掉的问题

2026-09-09，首次在 macOS 上构建。分两轮：先用 Command Line Tools 编 `CoachMeCore`，
再装 Xcode 15.4 编整个 App。在 Windows 上「写完但没编译」的代码里一共 87 个问题，
分五类。

### 1. `MetricUnavailableReason` 未声明 `Error`（阻塞编译）

`SwingMetricsCalculator` 把它当作 `Result<Vector3, MetricUnavailableReason>` 的
Failure 类型使用，但 `Result` 要求 Failure: Error。

```
SwingMetricsCalculator.swift:78:70: error: type 'MetricUnavailableReason' does not conform to protocol 'Error'
SwingMetricsCalculator.swift:96:74: error: 同上
SwingMetricsCalculator.swift:181:64: error: cannot infer contextual base in reference to member 'wrist'
```

第 3 条是前两条的连带错误。已在 `MetricDefinition.swift` 的枚举声明上补 `Error`。

### 2. 手写的 `ClosedRange: Codable` 扩展会被静默忽略

标准库自 Swift 5.x 起已有 `extension ClosedRange: Codable where Bound: Codable`。
重复声明触发：

> conformance of 'ClosedRange<Bound>' to protocol 'Encodable' conflicts with that
> stated in the type's module 'Swift' and will be ignored

也就是说手写的 `encode(to:)` / `init(from:)` **永远不会被调用**。标准库的编码格式
同样是 `[lower, upper]` 两元素数组，与手写实现一致，因此删除不影响已产生的 JSON。
已从 `MetricDefinition.swift` 删除该扩展，编译警告从 8 条降为 0。

### 这次验证覆盖不到的

App 层的 21 个 Swift 文件只过了 `swiftc -parse`（纯语法）。上面这类**类型层面**的
错误正是 `-parse` 检查不出来的，所以 SwiftUI 界面、`MediaPipePoseDetector`、
`LocalStore`、`VideoAssetReader` 里很可能还有同类问题。装 Xcode 后按
`docs/MAC_SETUP.md` 走一遍才算数。

### 3. `CoachMeCore` 的 public struct 缺 public init（20 个编译错误）

Swift 的成员逐一初始化器默认是 `internal`，不随 `public struct` 一起公开。26 个
public struct 里有 9 个漏了 public init：`SwingAnalysisContext` 及其 5 个嵌套类型、
`TorsoFrame`、`MetricDefinition`、`FrameMetrics`。

后果是 **App 模块根本构造不出 `SwingAnalysisContext` 家族**——聊天与报告的整条数据
通路。编译器报的 `extra arguments at positions #1...#11` 加 `missing argument for
parameter 'from'` 就是这个：11 个参数的调用匹配不上任何可见初始化器，只好去匹配唯一
public 的 `init(from: Decoder)`。

**28/28 的单元测试不可能发现它**：测试用 `@testable import CoachMeCore`，拿的是
internal 访问权限。跨模块边界只有真的 App 目标才会撞上。已为 9 个类型补上 public init。

### 4. SwiftUI 视图的 MainActor 隔离（63 个编译错误）

iOS 17.5 SDK 里 `View` 协议声明是 `@_typeEraser(AnyView) public protocol View {`——
**整个协议没有 `@MainActor`**，只有 `body` 那一条要求有。所以 `body` 是 MainActor，
而 `private func videoSection(_:) -> some View` 这类辅助方法不是，一访问
`@MainActor @Observable` 的 model 就报错。

代码是照 iOS 18 SDK 的语义写的——那一版 `View` 整个协议标了 `@MainActor`。已给 20 个
视图类型显式加 `@MainActor`，等效于 iOS 18 SDK 的自动推断，将来升 Xcode 16 也不会冲突。

`VideoPlayerView.swift` 的 `PlaybackController.deinit` 是例外，跟 SDK 版本无关：
`deinit` 永远是 nonisolated，不能碰 `@MainActor` 类的存储属性。已改为在 init 时把
移除观察者的动作捕获进一个 `nonisolated(unsafe)` 闭包，闭包持有 player 和 observer
token 但不持有 `self`，无循环引用。

### 5. `Landmark` 类型名冲突（1 个编译错误）

`CoachMeCore` 和 `MediaPipeTasksVision` 都定义了 `Landmark`。
`MediaPipePoseDetector.swift` 同时 import 两者，裸写 `Landmark(...)` 触发
`'Landmark' is ambiguous for type lookup`。已限定为 `CoachMeCore.Landmark`。

这个文件是整个项目里唯一在装 pod 之前无法做任何检查的——它是唯一 import
MediaPipe 的文件。

### 6. 工程配置的两个问题

- `project.yml` 的 `CoachMeTests` 目标没有 Info.plist 也没开
  `GENERATE_INFOPLIST_FILE`，模拟器签名阶段直接失败。已补 `GENERATE_INFOPLIST_FILE: YES`。
- XcodeGen 2.45 与 CocoaPods 1.16 都写 `objectVersion = 77`（Xcode 16 格式），
  Xcode 15.4 拒绝打开。两者都没有可用的开关（XcodeGen 忽略 `objectVersion` spec 选项；
  `installer.pods_project.object_version=` 这个 setter 不存在）。已加
  `tools/setup-xcode-project.sh` 在生成后改写该字段，并在改写前检查工程未使用
  格式 77 独有特性。升到 Xcode 16 后可删掉这个脚本。

### 现在仍然验证不到的

App 能构建、能启动、测试全绿，**但没有一帧真实视频跑过这条管线**。
`MediaPipePoseDetector` 只是能编译链接，它调用的 MediaPipe API 签名是否正确、模型能否
加载、关键点是否对齐、角度是否准确、性能如何——全部仍然未验证，需要真机、模型文件和
真实挥杆视频。第一节到第四节的方法学限制一条都没有改变。

## 六、24 fps 素材下，转体指标不足以区分相邻动作阶段

2026-09-09，用一段真实一号木挥杆（Pexels 38025678，24 fps）逐帧测量肩线转角，得到
以下事实：

**原始曲线在上杆平台（2.30–2.75s）的帧间抖动均方根为 3.64°**，峰值出现在 2.336s
的 −47.9°，而相邻帧是 −34.7° 和 −40.7°——峰值本身就是一次跳变，不是稳定特征。

加入 One Euro 滤波后抖动降到 1.58°，但**峰值位置从 2.336s 移到 2.461s**。也就是说
「上杆顶点在哪一帧」这个问题，答案随滤波参数改变而改变 3 帧。

### 根本原因是采样率，不是滤波器

24 fps 的奈奎斯特频率是 12 Hz。这段挥杆的下杆过程约 0.25 秒，基频已在 4 Hz 量级，
而 MediaPipe 逐帧独立推理产生的误差同样分布在高频。**信号与噪声的频带高度重叠**，
任何线性滤波都无法把两者分开——这是采样定理的结论，不是调参能解决的问题。

参数扫描的结果印证了这一点：minCutoff 低于 3 Hz 时滤波器开始吃掉下杆本身（1 Hz 时
平滑曲线在击球处落后原始曲线 46°），高于 8 Hz 时噪声重新穿过。最优点 5 Hz 只能把
抖动降到 1.58°，且这个最优很浅。

### 实际影响

- **不要用转体指标区分「上杆中段」与「上杆顶点」。** 两个时刻的真实差异小于测量噪声。
- 转体指标用于跨阶段的大幅度对比（准备 vs 顶点 vs 击球）仍然可用，那里的变化量在
  40°–100°，远大于噪声。
- 要支撑相邻阶段的判断，需要 **120 fps 或更高**的素材。这不是本项目能通过软件解决的。

### 峰值肩转量偏低，原因未知

这段素材测得的峰值肩线转角约 −44°（相对准备姿势）。一号木上杆顶点的肩转通常被描述
为 80–100°，但那是**相对目标线**的定义，与本项目不同，两者不可直接比较。当前既没有
标注数据也没有动作捕捉参考，**无法判断这个差异有多少来自定义不同、多少来自测量偏差**。
不得据此宣称测量准确或不准确。

## 七、慢动作素材大幅改善转体指标，但需要在导入时声明

第六节的结论（24 fps 实时素材下转体指标分不出相邻阶段）**不适用于慢动作素材**。
2026-09-09 用一段超级慢动作素材（一次挥杆约占 18 秒）重测：

| | 24 fps 实时 | 慢动作 |
|---|---|---|
| 原始曲线抖动 | 3.64° | 2.09° |
| 平滑后抖动 | 1.58° | **0.41°** |
| 峰值位置是否随参数漂移 | 会（漂 3 帧） | **不会** |

峰值位置稳定是关键差别。在实时素材上「上杆顶点在哪一帧」的答案取决于滤波参数，
说明它不是稳定特征；在慢动作素材上它稳定在同一帧。**慢动作素材可以支撑相邻阶段的
区分，实时素材不行。**

### 一套参数无法通吃

最优 `minCutoff` 在实时素材上是 5.0 Hz，在慢动作素材上是 0.6 Hz，相差约 8 倍——
正好等于慢动作倍率。时间被拉伸后信号中每个频率成分都按同样比例降低，截止频率必须
跟着降。

**文件本身不携带「被降速了多少」这个信息**，无法自动推断（两段素材的容器帧率都是
24 fps，差别在内容速度而非采样率）。因此导入界面增加了「这是慢动作视频」开关，选择
结果随 `AnalysisCache.smoothing` 一起存盘。

默认为实时预设，因为这是更安全的错误方向：把实时预设用在慢动作上只是欠平滑，反过来
会把下杆抹平。

### 分屏素材会被正确拒绝

同一段素材的原始版本是左右分屏（同一球手两个机位）。73 帧中 73 帧检测到 2 个人，
全部被质量门槛判为 `multiplePeople` 并拒绝出值。这是正确行为——App 不会在两个身影
中随便挑一个来测量。

### 机位决定引导臂能否测量

| 素材 | 左肘可见度中位数 |
|---|---|
| 偏后侧机位（第六节那段） | 0.06–0.5，引导臂全程不可测 |
| 正面机位（本节这段） | **0.94** |

正面机位下 8 个指标全部可用；偏后侧机位下引导臂肘部、引导臂上臂-躯干、双上臂夹角
三项无法计算。这不是缺陷，是机位的物理限制。
