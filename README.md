# CoachMe

<p align="center">
  <strong>See your swing. Understand your next practice.</strong>
</p>

<p align="center">
  An iOS golf workbench for video review, seven swing phases, 2D/3D pose views, and AI coaching.
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white">
  <img alt="MediaPipe Heavy" src="https://img.shields.io/badge/Pose-MediaPipe_Heavy-204B3B">
  <img alt="Core tests 81 passed" src="https://img.shields.io/badge/Core_tests-81_passed-2EA44F">
</p>

Import a swing video, review the key moments, and discuss a specific movement with your AI coach. CoachMe brings playback, joint angles, phase review, reports, and follow-up questions into one native SwiftUI app.

## App screenshots

The redesigned app, running on the iPhone 17 Pro Simulator. These are real app captures; the AI page contains a saved response and a draft question.

<table>
  <tr>
    <td align="center"><a href="docs/screenshots/home.png"><img src="docs/screenshots/home.png" alt="Home · recent swings" width="300"></a></td>
    <td align="center"><a href="docs/screenshots/analysis.png"><img src="docs/screenshots/analysis.png" alt="Workbench · seven-phase review" width="300"></a></td>
  </tr>
  <tr>
    <td align="center"><sub>Home · recent swings</sub></td>
    <td align="center"><sub>Workbench · seven-phase review</sub></td>
  </tr>
  <tr>
    <td align="center"><a href="docs/screenshots/report.png"><img src="docs/screenshots/report.png" alt="Report · metrics and review status" width="300"></a></td>
    <td align="center"><a href="docs/screenshots/ai-coach.png"><img src="docs/screenshots/ai-coach.png" alt="AI coach · discuss a specific movement" width="300"></a></td>
  </tr>
  <tr>
    <td align="center"><sub>Report · metrics and review status</sub></td>
    <td align="center"><sub>AI coach · discuss a specific movement</sub></td>
  </tr>
</table>

## From video to practice

1. **Import and trim.** Select a video from Photos, keep one complete swing, and set handedness, club, camera view, and slow-motion mode. Follow analysis progress on the device.
2. **Review seven phases.** Move through address, takeaway, mid-backswing, top, mid-downswing, impact, and finish. Play slowly, step frame by frame, confirm a candidate, or mark the current frame.
3. **Explore the movement.** Switch between the video with a 2D pose overlay and a rotatable 3D human model. Inspect sided elbow and knee angles, use landscape playback, and scrub angle curves to return to the video.
4. **Read the report.** Check metrics by phase, compare them with your coach-defined ranges, and see exactly which keyframes still need review. Tap a metric for its definition and a direct route to the AI coach.
5. **Ask follow-up questions.** Discuss priorities and practice ideas using OpenAI, Claude, Gemini, DeepSeek, or an OpenAI-compatible endpoint. A supported vision model can interpret swing images with angle data as supporting context.

## Inside the app

| Area | Current implementation |
|---|---|
| Interface | Warm-white and forest-green SwiftUI screens, shared controls, fixed report/AI actions |
| Pose | MediaPipe Heavy, 33 landmarks, temporal smoothing and display-only completion |
| Keyframes | Local SwingNet inference with seven app phases, person-crop retry, manual marking and review |
| 3D view | Rigged human mesh driven by pose estimates, with rotation and zoom |
| Curves | Sided angle traces; missing readings break the line instead of being bridged |
| Rules | Editable ranges, sources and applicable conditions; rules can be enabled or disabled |
| AI coach | Provider settings, Keychain storage, contextual questions and scrolling to new messages |
| Storage | Local videos, analysis records and conversation history |

Pose, phase detection, and angle calculations run on the device. When you ask the configured AI service, the app sends the relevant analysis, conversation context and, if enabled, up to 13 selected video frames; it does not upload the complete video. See [AI setup and data scope](docs/AI_INTEGRATION.md).

## Recent improvements

- Unified the Home, Import, Workbench, Report, AI Coach, Rules, and Settings screens.
- Made analysis progress scrollable with a fixed cancel action; limited thumbnail caching and preview refreshes.
- Smoothed the 2D display skeleton while keeping measurement data separate from display completion.
- Fixed report pending counts and carried the selected phase, side, and metric into an editable AI question.
- Preserved provisional report rows and broke angle curves at missing or non-finite readings.

## Verification

Recorded on September 11, 2026:

| Check | Result |
|---|---|
| Core tests | 81 passed |
| iOS regression suite | 33 passed; 1 real-provider API test skipped |
| Targeted UI-logic regression | 9 passed after adding report-context, metric-question, and curve-gap cases; overlaps the full suite |
| Builds | iOS Simulator and physical-device builds succeeded |
| Video workflow | An 8.8-second clip completed analysis and produced seven candidates for review |
| UI walkthrough | Home, 2D/3D, landscape, curves, report details, AI question handoff, rules, settings and clip selection |
| Physical device | Latest build installed on iPhone 16 Pro; automatic launch was blocked by the lock screen |

These checks establish functionality, not measurement or coaching accuracy. Pose estimates and automatic phase labels still need review. Reference ranges come from the user's coach rules. See [measurement limitations](docs/LIMITATIONS.md), [SwingNet sources and terms](tools/swingnet/README.md), and [3D model attribution](CoachMe/Resources/GolfAvatar-LICENSE.txt).

## Quick start

### Requirements

- macOS with the full Xcode installation
- iOS 17.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and CocoaPods

### Build and run

```bash
tools/download-model.sh          # fetch MediaPipe pose_landmarker_heavy.task
tools/setup-xcode-project.sh     # generate the project, install Pods, fix its format
open CoachMe.xcworkspace         # open the workspace, not the .xcodeproj
```

The generated Xcode project and Google's 29 MB MediaPipe model are deliberately
not committed. The setup scripts prepare both.

### Run on an iPhone

```bash
xcodebuild -downloadPlatform iOS          # once, if the iOS platform is missing
tools/setup-device-signing.sh <TEAM_ID>   # write Team + bundle ID and regenerate
open CoachMe.xcworkspace                  # select the iPhone and press ⌘R
```

Before the first launch, trust the developer certificate under Settings → General
→ VPN & Device Management. A free Personal Team build expires after seven days.
Signing belongs in `project.yml`; a change made only in Xcode's Signing pane is
lost the next time the generated project is rebuilt.

## Tests

```bash
swift test --package-path CoachMeCore

xcodebuild -workspace CoachMe.xcworkspace -scheme CoachMe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

With only the Command Line Tools and no full Xcode installation:

```bash
swift build --package-path CoachMeCore
tools/no-xcode-testrunner/run.sh
node tools/reference/verify_geometry.mjs
node tools/reference/verify_rules.mjs
```

The Node scripts reproduce the Swift formulas and decision order to check the
math independently. They do not replace an app build or runtime test.

<details>
<summary><strong>Repository layout</strong></summary>

```text
CoachMeCore/                 Pure Swift logic; no SwiftUI, AVFoundation, or MediaPipe
  Sources/
    Model/                   Landmarks, frames, swing phases, and keyframes
    Geometry/                Vectors, angles, and the torso coordinate frame
    Metrics/                 Metric catalogue and calculators
    Quality/                 Visibility gates and per-frame quality
    Smoothing/               One Euro filter and pose-sequence smoothing
    Rules/                   Coach rules and the evaluation engine
    Chat/                    Messages, conversations, context, and ChatService
  Tests/                     Core regression tests

CoachMe/                     iOS app target
CoachMeTests/                iOS regression and integration tests
tools/reference/             Node geometry and rules reference implementation
tools/no-xcode-testrunner/   XCTest shim for machines without full Xcode
tools/setup-xcode-project.sh Generate the project and install dependencies
tools/setup-device-signing.sh Write physical-device signing configuration
tools/download-model.sh      Download the MediaPipe pose model
docs/                        Metrics, setup, limitations, and AI integration
project.yml                  XcodeGen project specification
```

</details>

## Documentation

| Document | Contents |
|---|---|
| [`docs/METRICS.md`](docs/METRICS.md) | Formulas, reference frames, zero points, signs, and caveats |
| [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) | What is and is not verified; read before trusting a number |
| [`docs/MAC_SETUP.md`](docs/MAC_SETUP.md) | Full Mac, Simulator, and device setup |
| [`docs/AI_INTEGRATION.md`](docs/AI_INTEGRATION.md) | Model input and claims an integration must never make |

## Roadmap

- [x] End-to-end analysis of real swing footage
- [x] MediaPipe pose inference and landmark smoothing
- [x] Coach rule management and evaluation
- [x] Simulator test suite and first physical-device run
- [ ] Measurement-accuracy benchmark
- [ ] Historical analysis comparison
- [ ] Live-camera analysis
- [x] Configurable AI coaching service

## Licence

No open-source licence yet; all rights reserved. The MediaPipe model and test
fixtures carry their own terms. The pose model belongs to Google;
`CoachMeTests/Fixtures/swing3s.mp4` is derived from a
[Pexels clip](https://www.pexels.com/video/38025678/) under the Pexels licence;
and `pose.jpg` comes from Google's MediaPipe sample assets.
