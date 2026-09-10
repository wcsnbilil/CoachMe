# CoachMe

**English** · [简体中文](README.zh-CN.md)

Golf swing analysis for iOS. Video → skeleton → joint angles → the coach's own
reference ranges → feedback.

CoachMe ships **no built-in "correct" angles**. Every reference range is entered
by a coach, carries its source, and is only ever described as *outside the range
you set* — never as a wrong movement.

<img src="simulator-launch.png" alt="CoachMe home screen" width="300">

## Status — 2026-09-10

Runs end to end on the iOS Simulator against real swing footage.

| Area | State |
|---|---|
| `CoachMeCore` build | ✅ 0 errors, 0 warnings |
| `CoachMeCore` tests | ✅ **46/46** (real XCTest) |
| iOS app build | ✅ Xcode 15.4 / iOS 17.5 SDK, MediaPipe pod linked |
| App tests | ✅ **24/24** on the iPhone 15 Simulator |
| Real video, end to end | ✅ decode → pose → keyframes → metrics → rule findings → chat payload |
| MediaPipe inference | ✅ 33 landmarks + world landmarks on real footage |
| Landmark smoothing | ✅ One Euro, tuned on real footage, separate real-time / slow-motion presets |
| Node reference checks | ✅ geometry 31/31, rules 25/25 |
| **On-device run** | ❌ **blocked** — see below |
| **Measurement accuracy** | ❌ **never measured** — see [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) |
| History comparison, live camera | ⬜ not started |

**There are no accuracy figures anywhere in this project.** Nothing here has been
compared against manual annotation or motion capture, so no claim about how close
a reported angle is to the truth can be made. `docs/LIMITATIONS.md` records what
has and has not been verified, in detail.

### Why on-device is blocked

Xcode 15.4 carries device support up to iOS 16.4 and has no developer disk image
for iOS 26, so `devicectl` reports `connected (no DDI)`. Deploying to an iOS 26
device needs Xcode 26.4, which needs macOS 26.2. Everything below therefore runs
in the Simulator.

## Layout

```
CoachMeCore/            Pure Swift logic. No SwiftUI, no AVFoundation, no MediaPipe.
  Sources/
    Model/              Landmarks, frames, swing phases, keyframes
    Geometry/           Vectors, angles, the torso frame
    Metrics/            Metric catalogue + calculator
    Quality/            Visibility gates and per-frame quality
    Smoothing/          One Euro filter and the pose sequence smoother
    Rules/              Coach rules and the evaluation engine
    Chat/               Messages, conversations, analysis context, ChatService
  Tests/                46 tests

CoachMe/                iOS app target
tools/reference/        Node reimplementations of the formulas, for checking
                        the maths without a Swift toolchain
tools/no-xcode-testrunner/  Runs the XCTest suite with Command Line Tools only
tools/setup-xcode-project.sh    Generates the project, installs pods, fixes format
tools/setup-device-signing.sh   Writes signing details into project.yml
tools/download-model.sh         Fetches the MediaPipe pose model
docs/                   Metric definitions, Mac setup, limitations
project.yml             XcodeGen specification — the project file is generated
Podfile                 MediaPipeTasksVision 0.10.21, pinned (reason in the file)
```

## Getting started

Two things are deliberately **not** in the repository: the generated Xcode
project, and the 5.5 MB MediaPipe model (it carries Google's own licence).

```bash
tools/download-model.sh          # pose_landmarker_lite.task → CoachMe/Resources/
tools/setup-xcode-project.sh     # xcodegen + pod install + project format fix
open CoachMe.xcworkspace         # the workspace, not the .xcodeproj
```

`setup-xcode-project.sh` rewrites the project format to `objectVersion = 56`.
XcodeGen 2.45 and CocoaPods 1.16 both emit `77`, the Xcode 16 format, which
Xcode 15.4 refuses to open. Delete that step once you move to Xcode 16+.

### Test

```bash
swift test --package-path CoachMeCore     # 46 tests, seconds, no Simulator
xcodebuild -workspace CoachMe.xcworkspace -scheme CoachMe \
  -destination 'platform=iOS Simulator,name=iPhone 15' test    # 24 tests
```

### Without Xcode

`swift test` fails with `error: XCTest not available` on a machine that has only
the Command Line Tools, because XCTest ships with the full Xcode. These work
anyway:

```bash
swift build --package-path CoachMeCore
tools/no-xcode-testrunner/run.sh          # the real test files, XCTest shimmed
node tools/reference/verify_geometry.mjs  # 31/31
node tools/reference/verify_rules.mjs     # 25/25
```

The Node scripts reimplement the same formulas and the same decision order as the
Swift code. They check that the **maths** is right; they cannot tell you whether
the app builds or runs.

## Three rules the product does not bend

**1. If it cannot be computed, say so.** Any metric without sufficient data shows
「无法可靠计算」 and the reason. Never 0, never a default angle, never an
extrapolation. This is why `MetricOutcome` is an enum carrying a reason rather
than an optional `Double`, why `Vector3.normalized()` returns nil on a degenerate
vector, and why nothing downstream fills a gap.

**2. No invented standards.** The app contains no reference ranges. A coach
enters their own, with a source note and the conditions they apply under. A value
outside one is reported as *outside the range you set*, never as an error —
`RuleEvaluation` has no case for "wrong".

**3. No pretend AI.** The v1 `UnconfiguredChatService` makes no network calls and
returns a "not configured" status. It never generates coaching-shaped text.

## Documentation

| | |
|---|---|
| [`docs/METRICS.md`](docs/METRICS.md) | Every metric: formula, reference frame, zero and sign, caveats |
| [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) | What is verified, what is not, and why. Read before trusting a number |
| [`docs/MAC_SETUP.md`](docs/MAC_SETUP.md) | Build steps on a Mac |
| [`docs/AI_INTEGRATION.md`](docs/AI_INTEGRATION.md) | What a model would receive, and what it must never claim |

## Licence

None yet — all rights reserved. The MediaPipe model and the test fixtures carry
their own terms: the pose model is Google's, `CoachMeTests/Fixtures/swing3s.mp4`
is derived from a [Pexels](https://www.pexels.com/video/38025678/) clip under the
Pexels licence, and `pose.jpg` comes from Google's MediaPipe sample assets.
