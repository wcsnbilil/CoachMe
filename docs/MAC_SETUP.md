# 在 Mac 上构建与运行 CoachMe

本工程在 Windows 上编写。以下第 1–4 步已在 Mac 上实际执行过，真机运行于 2026-09-11
首次跑通。Xcode 仅在 macOS 上运行，CocoaPods 安装、Swift 编译、MediaPipe 推理和
真机运行都必须在 Mac 上完成。

## 0. 前置条件

| 项目 | 要求 |
|---|---|
| macOS | 能运行 Xcode 15 或更高版本 |
| Xcode | 15+（iOS 17 SDK）；真机是 iOS 26 时需要 Xcode 26 |
| CocoaPods | `sudo gem install cocoapods` |
| XcodeGen | `brew install xcodegen` |
| Apple ID | 免费 Apple ID 可做 7 天真机调试；上架需付费开发者账号 |

## 1. 生成工程并安装依赖

```bash
cd coachme
xcodegen generate          # 由 project.yml 生成 CoachMe.xcodeproj
pod install                # 安装 MediaPipeTasksVision 0.10.21
open CoachMe.xcworkspace   # 必须开 workspace，不是 xcodeproj
```

## 2. 下载姿态模型

模型文件**不在仓库中**（适用 Google 自己的许可）。

```bash
tools/download-model.sh          # 默认 heavy，可传 lite / full
tools/setup-xcode-project.sh     # 重新生成工程，让模型进 Copy Bundle Resources
```

脚本会校验下载到的 `.task` 确实是含 tflite 的 zip 包，而不是一个返回 200 的错误页。
`project.yml` 已把 `CoachMe/Resources/*.task` 声明为 resources，不需要手动拖进 Xcode。

代码通过 `BaseOptions.modelAssetPath` 从 App Bundle 读取。文件缺失时 App 显示
「模型文件缺失」，不崩溃也不退回假数据——`PoseDetectorSmokeTests` 覆盖了这条路径。

**默认使用 heavy**：App、分析记录中的模型标识和下载脚本均使用 Heavy。
切换其他变体时，应同步修改检测器配置和分析记录中的模型标识，并用自己的视频实测。

## 3. 运行纯逻辑测试（不需要真机）

```bash
cd CoachMeCore
swift test
```

这一步会验证 `docs/METRICS.md` 里全部角度定义（28/28 通过）。断言里的期望值来自
`tools/reference/verify_geometry.mjs` 的实际运行结果（31/31），不要为了让测试变绿而
修改它们。

## 4. 真机运行

2026-09-11 首次跑通：iPhone 16 Pro、iOS 26.4.2、Xcode 26.6、免费个人团队签名。

1. Xcode 26 安装时不带 iOS 平台组件，缺它时构建报 `iOS 26.5 is not installed`。
   先装一次：`xcodebuild -downloadPlatform iOS`（或 Xcode → Settings → Components）。
   SDK 版本高于手机系统没有关系，部署目标是 iOS 17.0
2. `tools/setup-device-signing.sh <TEAM_ID>` 把 Team 和 bundle ID 写进 `project.yml`
   并重新生成工程。Team ID 在 Xcode → Settings → Accounts 里。**不要在 Xcode 的
   Signing & Capabilities 里改**——工程是生成的，下次重新生成就会被覆盖。
   bundle ID 默认变成 `com.<team id 小写>.coachme`，因为 `com.coachme.app` 很可能已被占用
3. iPhone 用数据线连接并开启开发者模式，在设备列表中选中，⌘R 运行。
   命令行等价做法：
   ```bash
   xcodebuild -workspace CoachMe.xcworkspace -scheme CoachMe \
     -destination 'id=<UDID>' -allowProvisioningUpdates build
   xcrun devicectl device install app --device <设备> <Debug-iphoneos/CoachMe.app 的路径>
   ```
   UDID 用 `xcrun xctrace list devices` 查。`-allowProvisioningUpdates` 让 Xcode 用已登录
   的 Apple ID 自动创建开发证书和描述文件
4. 首次运行需在 iPhone 上「设置 → 通用 → VPN 与设备管理」信任你的开发者证书。
   不信任时启动报 `profile has not been explicitly trusted by the user`
5. 免费个人团队签的包 7 天后失效，重新构建安装即可

**必须在真机上验证，不要只用模拟器**：模拟器没有相册中的真实视频，且 MediaPipe 在
模拟器（x86/arm64 slice）上的行为与真机不一致。

## 5. 建议的首次验证顺序

按此顺序验证，任何一步失败都先停下来修：

1. App 能启动、能打开相册选择器
2. 选中一段挥杆视频，能显示时长和缩略图
3. 分析能跑完并给出进度，中途能取消
4. 骨架叠加与人物对齐——**用竖拍和横拍各测一次**，这是最容易出错的地方
5. 拖动进度条，骨架、角度读数、曲线游标三者同步
6. 新导入视频生成六个自动阶段；点击可跳转，重新标记后显示「手动」。准备姿势标记作为肩线/髋线转角的参考。
7. 遮挡严重的帧显示"无法可靠计算"，而不是某个数字
