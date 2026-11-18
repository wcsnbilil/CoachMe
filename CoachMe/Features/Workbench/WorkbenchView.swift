import SwiftUI
import AVFoundation
import CoachMeCore

enum StageMode: Hashable { case flat, spatial }
enum WorkbenchTab: Hashable { case readings, curve }

/// The sided angle drawn on the video, chosen from the readouts.
enum VideoMetric: String, CaseIterable, Identifiable {
    case leadElbow, trailElbow, leadKnee, trailKnee
    var id: String { rawValue }

    var metric: MetricID {
        switch self {
        case .leadElbow, .trailElbow: return .elbowInteriorAngle
        case .leadKnee, .trailKnee: return .kneeInteriorAngle
        }
    }

    var label: String {
        switch self {
        case .leadElbow: return "引导臂肘"
        case .trailElbow: return "后侧臂肘"
        case .leadKnee: return "引导侧膝"
        case .trailKnee: return "后侧膝"
        }
    }

    func side(_ handedness: Handedness) -> BodySide {
        switch self {
        case .leadElbow, .leadKnee: return handedness.leadSide
        case .trailElbow, .trailKnee: return handedness.trailSide
        }
    }

    func joints(_ handedness: Handedness) -> [PoseJoint] {
        let left = side(handedness) == .left
        switch self {
        case .leadElbow, .trailElbow:
            return left ? [.leftShoulder, .leftElbow, .leftWrist] : [.rightShoulder, .rightElbow, .rightWrist]
        case .leadKnee, .trailKnee:
            return left ? [.leftHip, .leftKnee, .leftAnkle] : [.rightHip, .rightKnee, .rightAnkle]
        }
    }
}

extension SwingPhase {
    var shortNameZH: String {
        switch self {
        case .address: return "准备"
        case .takeaway: return "上杆下"
        case .midBackswing: return "上杆中"
        case .top: return "顶点"
        case .midDownswing: return "下杆中"
        case .impact: return "击球"
        case .finish: return "收杆"
        }
    }

    /// What to check before confirming the automatically detected frame.
    var reviewHintZH: String {
        switch self {
        case .address: return "确认球杆已放稳、身体静止。这一帧是所有转角指标的零点。"
        case .takeaway: return "确认杆身接近水平、手在腰带高度附近。"
        case .midBackswing: return "确认引导臂接近水平。"
        case .top: return "对照画面确认杆身已到最高点。如不准确，拖动时间轴到正确画面后用当前帧标记。"
        case .midDownswing: return "确认手回到腰带高度附近。"
        case .impact: return "确认杆头正在触球。高速画面可能模糊，请用上一帧、下一帧逐帧对照。"
        case .finish: return "确认身体已停稳、完成收杆。"
        }
    }
}

extension Keyframe {
    var statusTextZH: String {
        (isManualMark ? "手动调整" : "自动识别") + " · " + (markedByCoach ? "已确认" : "待复核")
    }
}

@MainActor
enum OrientationControl {
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

@MainActor
struct WorkbenchView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var model: WorkbenchModel?
    @State private var showingChat = false
    @State private var showingReport = false
    @State private var showingReanalysis = false
    @State private var showingDetails = false
    @State private var confirmingDelete = false
    @State private var confirmingRedetect = false
    @State private var usePersonCrop = true
    @State private var phaseTask: Task<Void, Never>?
    @State private var tab: WorkbenchTab = .readings
    @State private var stageMode: StageMode = .flat
    @State private var selectedPhase: SwingPhase?
    @State private var videoMetric: VideoMetric = .leadElbow
    let swing: SwingRecord

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView("正在读取分析结果…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CoachStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(CoachStyle.background, for: .navigationBar)
        .toolbar { toolbarContent }
        .onDisappear { phaseTask?.cancel(); model?.playback?.pause() }
        .task {
            guard model == nil else { return }
            let loaded = WorkbenchModel(swing: swing,
                                        cache: library.analysis(for: swing),
                                        videoURL: library.videoURL(for: swing))
            model = loaded
            let keyframes = loaded.swing.keyframes.sorted { $0.phase.order < $1.phase.order }
            let first = keyframes.first { !$0.markedByCoach } ?? keyframes.first
            selectedPhase = first?.phase ?? .address
            if let first { loaded.playback?.seek(to: first.timestampSeconds) }
        }
        .sheet(isPresented: $showingReanalysis) {
            if let model { ImportView(initialVideoURL: library.videoURL(for: model.swing)) }
        }
        .sheet(isPresented: $showingChat) {
            if let model {
                ChatPanelView(swing: model.swing,
                              phase: model.currentPhase,
                              timestamp: model.playback?.currentTime ?? 0,
                              context: model.buildContext(rules: library.rules),
                              onJump: { time in
                                  showingChat = false
                                  model.playback?.pause()
                                  model.playback?.seek(to: time)
                              })
            }
        }
        .navigationDestination(isPresented: $showingReport) {
            if let model {
                ReportView(swing: model.swing, onJump: { time in
                    showingReport = false
                    model.playback?.pause()
                    model.playback?.seek(to: time)
                }, analysisContext: model.buildContext(rules: library.rules))
            }
        }
        .alert("分析说明", isPresented: $showingDetails) {
            Button("好", role: .cancel) {}
        } message: {
            Text((model?.reviewSummary ?? "") + "\n虚线骨架为估计位置，不参与角度计算。姿态模型：" + (model?.swing.poseModelIdentifier ?? ""))
        }
        .confirmationDialog("删除这次分析？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除分析", role: .destructive) {
                if let model { library.delete(model.swing) }
                dismiss()
            }
        } message: {
            Text("视频、分析结果和对话都会从本机删除，无法恢复。")
        }
        .confirmationDialog("重新识别关键帧？", isPresented: $confirmingRedetect, titleVisibility: .visible) {
            Button("清除并重新识别", role: .destructive) {
                guard let model else { return }
                phaseTask = Task { await model.redetectKeyframes(library: library, usePersonCrop: usePersonCrop) }
            }
        } message: {
            Text("现有的 \(model?.swing.keyframes.count ?? 0) 个关键帧（包括手动调整）会被清除。")
        }
    }

    // MARK: - Navigation bar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            let record = model?.swing ?? swing
            VStack(spacing: 1) {
                Text("挥杆分析").font(.subheadline.weight(.semibold))
                Text("\(record.title) · \(record.cameraView.nameZH)")
                    .font(.caption2)
                    .foregroundStyle(CoachStyle.textSecondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let model {
                Menu {
                    Button { confirmingRedetect = true } label: {
                        Label("重新识别关键帧", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.findingPhases)
                    Button { showingReanalysis = true } label: {
                        Label("重新选取挥杆片段", systemImage: "scissors")
                    }
                    Toggle(isOn: $usePersonCrop) {
                        Label("人物增强识别", systemImage: "person.crop.rectangle")
                    }
                    Divider()
                    Button { showingDetails = true } label: {
                        Label("分析说明", systemImage: "info.circle")
                    }
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("删除这次分析", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("更多操作")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: WorkbenchModel) -> some View {
        if model.cache == nil {
            ContentUnavailableView {
                Label("这段挥杆还没有分析结果", systemImage: "waveform.path.ecg")
            } description: {
                Text("分析可能被取消或失败了。可以重新选取挥杆片段再分析一次。")
            } actions: {
                Button("重新选取挥杆片段") { showingReanalysis = true }
                    .buttonStyle(CoachPrimaryButton(height: 44))
                    .frame(width: 220)
            }
        } else if isLandscape {
            LandscapeWorkbench(model: model, stageMode: $stageMode, videoMetric: $videoMetric,
                               selectedPhase: $selectedPhase,
                               onExit: { OrientationControl.request(.portrait) })
        } else {
            portrait(model)
        }
    }

    private func portrait(_ model: WorkbenchModel) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                StagePanel(model: model, stageMode: $stageMode, videoMetric: videoMetric,
                           onSnap: { selectedPhase = $0 },
                           onLandscape: { OrientationControl.request(.landscapeRight) })
                    .padding(.horizontal, 10)

                KeyframeSection(model: model, selectedPhase: $selectedPhase, usePersonCrop: $usePersonCrop,
                                videoURL: library.videoURL(for: model.swing),
                                onFind: {
                                    phaseTask = Task { await model.findKeyframes(library: library, usePersonCrop: usePersonCrop) }
                                },
                                onStop: { phaseTask?.cancel() })
                    .padding(.horizontal, 18)
                    .padding(.top, 22)

                dataSection(model)
                    .padding(.horizontal, 18)
                    .padding(.top, 24)

                FootnoteLine(symbol: "lock",
                             text: "姿态识别在本机完成。角度为模型估计，未经动作捕捉验证；虚线骨架为估计位置，不参与计算。")
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
            }
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onChange(of: model.currentPhase) { _, phase in
            if let phase { selectedPhase = phase }
        }
    }

    private func dataSection(_ model: WorkbenchModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CoachSegmented(options: [(WorkbenchTab.readings, "角度数据"), (.curve, "角度曲线")], selection: $tab)

            Text(caption(model))
                .font(.caption.monospacedDigit())
                .foregroundStyle(CoachStyle.textTertiary)
                .padding(.horizontal, 4)

            if tab == .readings {
                if let metrics = model.currentMetrics {
                    MetricReadoutGrid(metrics: metrics, handedness: model.swing.handedness, videoMetric: $videoMetric)
                } else {
                    Text("这一帧没有可用数据。")
                        .font(.subheadline)
                        .foregroundStyle(CoachStyle.textSecondary)
                        .coachCard()
                }
            } else {
                CurvePanel(model: model, selectedPhase: selectedPhase, rules: library.rules)
            }
        }
    }

    private func caption(_ model: WorkbenchModel) -> String {
        let time = (model.playback?.currentTime ?? 0) - (model.playback?.startTime ?? 0)
        let name = model.currentPhase?.nameZH ?? "当前帧"
        return "当前帧 · \(name) " + String(format: "%.2f 秒", time)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { showingReport = true } label: {
                Label("查看报告", systemImage: "doc.text")
            }
            .buttonStyle(CoachSecondaryButton())

            Button { showingChat = true } label: {
                Label("问 AI 教练", systemImage: "sparkles")
            }
            .buttonStyle(CoachPrimaryButton())
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(CoachStyle.background.overlay(alignment: .top) {
            Rectangle().fill(CoachStyle.line).frame(height: 1)
        })
    }
}

// MARK: - Stage

/// Dark video panel: video, skeleton, angle mark and the transport controls.
@MainActor
struct StagePanel: View {
    let model: WorkbenchModel
    @Binding var stageMode: StageMode
    let videoMetric: VideoMetric
    var onSnap: ((SwingPhase) -> Void)?
    var onLandscape: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            StageVideo(model: model, stageMode: $stageMode, videoMetric: videoMetric, onLandscape: onLandscape)
                .aspectRatio(stageAspect, contentMode: .fit)
            TransportBar(model: model, onSnap: onSnap)
        }
        .background(CoachStyle.stage)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    /// Portrait clips are capped at a height that leaves the keyframe strip on
    /// the first screen; wide clips get at least 4:3 so the overlays sit in the
    /// letterbox bands instead of on top of a short picture.
    private var stageAspect: CGFloat {
        let size = model.videoSize
        let aspect = size.height > 0 ? size.width / size.height : 9.0 / 16.0
        return min(max(aspect, 382.0 / 420.0), 4.0 / 3.0)
    }
}

@MainActor
struct StageVideo: View {
    let model: WorkbenchModel
    @Binding var stageMode: StageMode
    let videoMetric: VideoMetric
    var onLandscape: (() -> Void)?

    var body: some View {
        ZStack {
            CoachStyle.stage
            if stageMode == .flat {
                if let playback = model.playback { PlayerLayerView(player: playback.player) }
                if model.showSkeleton {
                    SkeletonOverlay(frame: model.currentDisplayPoseFrame,
                                    handedness: model.swing.handedness,
                                    videoSize: model.videoSize,
                                    minVisibility: model.swing.qualityPolicy.minVisibility,
                                    angle: angleMark)
                }
            } else {
                AvatarSceneView(frame: model.currentDisplayPoseFrame, angle: 0.35, reset: 0,
                                showBones: model.showSkeleton, darkStage: true)
                    .accessibilityLabel("三维人体估计，可拖动旋转、双指缩放")
            }
        }
        .overlay(alignment: .topLeading) { PhaseChip(model: model).padding(10) }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                CoachSegmented(options: [(StageMode.flat, "二维"), (.spatial, "三维")],
                               selection: $stageMode, onStage: true, segmentWidth: 46)
                Button { model.showSkeleton.toggle() } label: {
                    Image(systemName: "figure.stand")
                        .font(.title3)
                        .foregroundStyle(model.showSkeleton ? CoachStyle.limeOnDark : CoachStyle.onStage.opacity(0.7))
                }
                .buttonStyle(StageButton())
                .accessibilityLabel(model.showSkeleton ? "隐藏骨架" : "显示骨架")
            }
            .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            Group {
                if stageMode == .flat {
                    SkeletonLegend()
                } else {
                    Text("拖动旋转 · 三维为模型估计，非动作捕捉")
                        .font(.caption)
                        .foregroundStyle(CoachStyle.onStage.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(CoachStyle.stage.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if let onLandscape, stageMode == .flat {
                Button(action: onLandscape) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.body.weight(.medium))
                }
                .buttonStyle(StageButton())
                .padding(8)
                .accessibilityLabel("横屏查看")
            }
        }
        .clipped()
    }

    private var angleMark: SkeletonAngleMark {
        let handedness = model.swing.handedness
        let value = model.currentMetrics?.outcome(videoMetric.metric, videoMetric.side(handedness)).value
        return SkeletonAngleMark(joints: videoMetric.joints(handedness), label: videoMetric.label,
                                 value: value.map { String(format: "%.1f°", $0) })
    }
}

@MainActor
struct PhaseChip: View {
    let model: WorkbenchModel

    var body: some View {
        let time = (model.playback?.currentTime ?? 0) - (model.playback?.startTime ?? 0)
        let keyframe = model.currentPhase.flatMap { model.swing.keyframes.keyframe(for: $0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(keyframe?.phase.nameZH ?? "当前帧").font(.subheadline.weight(.semibold))
                Text(String(format: "%.2f 秒", time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CoachStyle.onStage.opacity(0.62))
            }
            .foregroundStyle(CoachStyle.onStage)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(CoachStyle.stage.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))

            if let keyframe {
                StatusTag(status: keyframe.markedByCoach ? .confirmed : .pending,
                          text: keyframe.statusTextZH, onStage: true)
            }
            if let reason = model.currentMetrics?.quality.blockingReason {
                StatusTag(status: .incomplete, text: reason.localizedZH, onStage: true)
            }
        }
    }
}

struct SkeletonLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) { LegendStroke(dashed: false); Text("实测") }
            HStack(spacing: 5) { LegendStroke(dashed: true); Text("补全 · 不参与计算") }
        }
        .font(.caption2)
        .foregroundStyle(CoachStyle.onStage.opacity(0.8))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(CoachStyle.stage.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct LegendStroke: View {
    let dashed: Bool
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 2))
            path.addLine(to: CGPoint(x: 17, y: 2))
        }
        .stroke(CoachStyle.onStage, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3.5, 3] : []))
        .frame(width: 18, height: 4)
    }
}

// MARK: - Transport

@MainActor
struct TransportBar: View {
    let model: WorkbenchModel
    var onSnap: ((SwingPhase) -> Void)?
    var horizontalPadding: CGFloat = 16
    private static let rates: [Float] = [0.1, 0.25, 0.5, 1]

    var body: some View {
        if let playback = model.playback {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(String(format: "%.2f", playback.currentTime - playback.startTime))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(CoachStyle.limeOnDark)
                        .frame(width: 36, alignment: .leading)
                    TimelineTrack(model: model, playback: playback, onSnap: onSnap)
                    Text(String(format: "%.2f 秒", playback.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CoachStyle.onStage.opacity(0.55))
                        .fixedSize()
                }
                HStack {
                    Button {
                        let index = Self.rates.firstIndex(of: playback.rate) ?? Self.rates.count - 1
                        playback.setRate(Self.rates[(index + 1) % Self.rates.count])
                    } label: {
                        Text(String(format: "%g×", playback.rate))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(minWidth: 56, minHeight: 44)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("播放速度")
                    Spacer()
                    HStack(spacing: 18) {
                        Button { playback.step(by: -1, timestamps: model.timestamps) } label: {
                            Image(systemName: "backward.frame.fill").font(.title3).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("上一帧")
                        Button { playback.togglePlay() } label: {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundStyle(CoachStyle.stage)
                                .frame(width: 56, height: 56)
                                .background(CoachStyle.onStage, in: Circle())
                        }
                        .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
                        Button { playback.step(by: 1, timestamps: model.timestamps) } label: {
                            Image(systemName: "forward.frame.fill").font(.title3).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("下一帧")
                    }
                    Spacer()
                    Text(model.frameNumber(at: playback.currentTime).map { "第 \($0) 帧" } ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CoachStyle.onStage.opacity(0.55))
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .foregroundStyle(CoachStyle.onStage)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
        }
    }
}

/// Scrubbable timeline with one marker per keyframe. Drags snap to a marker
/// within 8 pt, so a phase is easy to land on exactly.
@MainActor
struct TimelineTrack: View {
    let model: WorkbenchModel
    let playback: PlaybackController
    var onSnap: ((SwingPhase) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let span = max(playback.duration, 0.01)
            let x: (Double) -> CGFloat = { CGFloat(($0 - playback.startTime) / span) * width }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 4).offset(y: 17)
                Capsule().fill(Color.white.opacity(0.5))
                    .frame(width: max(0, x(playback.currentTime)), height: 4)
                    .offset(y: 17)
                ForEach(model.swing.keyframes) { keyframe in
                    KeyframeMarker(keyframe: keyframe, selected: model.currentPhase == keyframe.phase)
                        .position(x: x(keyframe.timestampSeconds), y: 7)
                }
                Circle().fill(CoachStyle.limeOnDark)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(CoachStyle.limeOnDark.opacity(0.25)).padding(-3))
                    .position(x: x(playback.currentTime), y: 19)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let location = min(max(0, drag.location.x), width)
                if let near = model.swing.keyframes.min(by: { abs(x($0.timestampSeconds) - location) < abs(x($1.timestampSeconds) - location) }),
                   abs(x(near.timestampSeconds) - location) < 8 {
                    playback.seek(to: near.timestampSeconds)
                    onSnap?(near.phase)
                } else {
                    playback.seek(to: playback.startTime + Double(location / width) * span)
                }
            })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(String(format: "%.2f 秒", playback.currentTime - playback.startTime))
        .accessibilityAdjustableAction { direction in
            playback.step(by: direction == .increment ? 1 : -1, timestamps: model.timestamps)
        }
    }
}

/// Shape carries the state: dashed ring = to review, dot = confirmed, diamond = placed by hand.
struct KeyframeMarker: View {
    let keyframe: Keyframe
    let selected: Bool

    var body: some View {
        ZStack {
            if !keyframe.markedByCoach {
                Circle().strokeBorder(selected ? CoachStyle.limeOnDark : CoachStyle.pendingOnStage,
                                      style: StrokeStyle(lineWidth: 1.6, dash: [2.5, 2]))
            } else if keyframe.isManualMark {
                RoundedRectangle(cornerRadius: 2).fill(CoachStyle.onStage).rotationEffect(.degrees(45)).padding(1.5)
            } else {
                Circle().fill(CoachStyle.onStage)
            }
            if selected && keyframe.markedByCoach {
                Circle().stroke(CoachStyle.limeOnDark, lineWidth: 2).frame(width: 15, height: 15)
            }
        }
        .frame(width: 10, height: 10)
    }
}

// MARK: - Keyframes

@MainActor
struct KeyframeSection: View {
    @Environment(SwingLibrary.self) private var library
    let model: WorkbenchModel
    @Binding var selectedPhase: SwingPhase?
    @Binding var usePersonCrop: Bool
    let videoURL: URL
    let onFind: () -> Void
    let onStop: () -> Void

    private var keyframes: [Keyframe] { model.swing.keyframes }
    private var pending: Int { keyframes.filter { !$0.markedByCoach }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if keyframes.isEmpty { detectionCard }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(SwingPhase.allCases) { phase in
                    let keyframe = keyframes.keyframe(for: phase)
                    KeyframeTile(phase: phase, keyframe: keyframe, videoURL: videoURL,
                                 selected: selectedPhase == phase) { select(phase) }
                        .contextMenu {
                            if let keyframe {
                                Button("跳到该帧") { model.playback?.seek(to: keyframe.timestampSeconds) }
                                Button("用当前帧覆盖") { model.markKeyframe(phase, library: library) }
                                Button("清除标记", role: .destructive) { model.clearKeyframe(phase, library: library) }
                            } else {
                                Button("用当前帧标记") { model.markKeyframe(phase, library: library) }
                            }
                        }
                }
            }
            if let selectedPhase { detailCard(selectedPhase) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("动作关键帧").font(.title3.weight(.semibold))
            Text(summary.text)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(summary.color)
            Spacer()
            if pending > 0 && keyframes.count == SwingPhase.allCases.count {
                Button("全部确认") { model.confirmKeyframes(library: library) }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
    }

    private var summary: (text: String, color: Color) {
        if keyframes.isEmpty { return ("未标记", CoachStyle.textSecondary) }
        if pending > 0 { return ("\(pending) 个待复核", CoachStyle.pending) }
        if keyframes.count < SwingPhase.allCases.count { return ("已标记 \(keyframes.count)/7", CoachStyle.textSecondary) }
        return ("7 个均已确认", CoachStyle.confirmed)
    }

    private var detectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有关键帧").font(.headline)
            Text("自动识别七个动作阶段，或拖动时间轴后在下方逐个“用当前帧标记”。")
                .font(.footnote)
                .foregroundStyle(CoachStyle.textSecondary)
            Toggle("人物增强识别", isOn: $usePersonCrop)
                .font(.subheadline)
                .tint(CoachStyle.accent)
                .disabled(model.findingPhases)
            if model.findingPhases {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在识别关键帧…").font(.subheadline)
                    Spacer()
                    Button("停止", action: onStop).font(.subheadline.weight(.semibold))
                }
                .frame(minHeight: 44)
            } else {
                Button(action: onFind) { Label("自动识别关键帧", systemImage: "sparkle") }
                    .buttonStyle(CoachPrimaryButton(height: 44))
            }
            if let message = model.phaseDetectionMessage {
                Text(message).font(.caption).foregroundStyle(CoachStyle.textSecondary)
            }
        }
        .coachCard()
    }

    private func detailCard(_ phase: SwingPhase) -> some View {
        let keyframe = keyframes.keyframe(for: phase)
        let start = model.playback?.startTime ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase.nameZH).font(.headline)
                    Text(keyframe.map { k in
                        String(format: "%.2f 秒", k.timestampSeconds - start)
                            + (model.frameNumber(at: k.timestampSeconds).map { " · 第 \($0) 帧" } ?? "")
                    } ?? "未标记")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(CoachStyle.textSecondary)
                }
                Spacer(minLength: 8)
                if let keyframe {
                    StatusTag(status: keyframe.isManualMark ? .manual : .autoDetected)
                    StatusTag(status: keyframe.markedByCoach ? .confirmed : .pending)
                } else {
                    StatusTag(status: .unmarked)
                }
            }
            Text(phase.reviewHintZH)
                .font(.footnote)
                .foregroundStyle(CoachStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.phaseDetectionMessage, !keyframes.isEmpty {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(CoachStyle.pending)
            }
            HStack(spacing: 10) {
                Button { model.markKeyframe(phase, library: library) } label: {
                    Label(keyframe == nil ? "用当前帧标记" : "用当前帧覆盖", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(CoachSecondaryButton(height: 44))
                Button {
                    model.confirmKeyframe(phase, library: library)
                    advance(from: phase)
                } label: {
                    Label(keyframe?.markedByCoach == true ? "已确认" : "确认此帧", systemImage: "checkmark")
                }
                .buttonStyle(CoachPrimaryButton(height: 44))
                .disabled(keyframe == nil || keyframe?.markedByCoach == true)
            }
        }
        .coachCard()
    }

    private func select(_ phase: SwingPhase) {
        selectedPhase = phase
        if let keyframe = keyframes.keyframe(for: phase) {
            model.playback?.pause()
            model.playback?.seek(to: keyframe.timestampSeconds)
        }
    }

    /// After confirming, move straight to the next frame that still needs review.
    private func advance(from phase: SwingPhase) {
        let ordered = SwingPhase.allCases
        let start = ordered.firstIndex(of: phase) ?? 0
        for offset in 1...ordered.count {
            let next = ordered[(start + offset) % ordered.count]
            if let keyframe = keyframes.keyframe(for: next), !keyframe.markedByCoach {
                select(next)
                return
            }
        }
    }
}

@MainActor
struct KeyframeTile: View {
    let phase: SwingPhase
    let keyframe: Keyframe?
    let videoURL: URL
    let selected: Bool
    let action: () -> Void

    private var status: (text: String, color: Color) {
        guard let keyframe else { return ("未标记", CoachStyle.textTertiary) }
        if !keyframe.markedByCoach { return ("待复核", CoachStyle.pending) }
        return (keyframe.isManualMark ? "手动" : "已确认", CoachStyle.confirmed)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    if let keyframe {
                        VideoFrameImage(url: videoURL, time: keyframe.timestampSeconds)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(CoachStyle.textTertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        Image(systemName: "plus").font(.caption).foregroundStyle(CoachStyle.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(2.5)
                .overlay(RoundedRectangle(cornerRadius: 12.5)
                    .strokeBorder(selected ? Color(hex: 0x9BC45A) : .clear, lineWidth: 2))

                Text(phase.nameZH)
                    .font(.system(size: 11, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? CoachStyle.confirmed : CoachStyle.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 2) {
                    marker
                    Text(status.text)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(status.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(phase.nameZH)，\(status.text)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var marker: some View {
        if let keyframe, keyframe.markedByCoach {
            RoundedRectangle(cornerRadius: keyframe.isManualMark ? 1 : 3.5)
                .fill(CoachStyle.accent)
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .strokeBorder(keyframe == nil ? CoachStyle.textTertiary : Color(hex: 0xB7862A),
                              style: StrokeStyle(lineWidth: 1.4, dash: [2, 1.5]))
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Curve

@MainActor
struct CurvePanel: View {
    let model: WorkbenchModel
    let selectedPhase: SwingPhase?
    let rules: [CoachRule]

    private static let metrics: [MetricID] = MetricID.allCases.filter { $0 != .wristPathBodyReferenced }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.metrics, id: \.self) { metric in
                        ChoiceChip(title: MetricCatalog.definition(for: metric).nameZH,
                                   selected: model.chartMetric == metric, showsCheck: false) {
                            model.chartMetric = metric
                        }
                    }
                }
            }
            AngleChartView(timeline: model.timeline,
                           metric: model.chartMetric,
                           handedness: model.swing.handedness,
                           keyframes: model.swing.keyframes,
                           currentTime: model.playback?.currentTime ?? 0,
                           clipStart: model.playback?.startTime ?? 0,
                           highlightedPhase: selectedPhase,
                           range: range,
                           onScrub: { model.playback?.seek(to: $0) })
                .frame(height: 260)
        }
        .coachCard(padding: 14)
    }

    /// The coach range for the selected phase, drawn only at that phase's frame —
    /// a rule applies to a phase, not to the whole swing.
    private var range: AngleChartView.ChartRange? {
        guard let phase = selectedPhase,
              let keyframe = model.swing.keyframes.keyframe(for: phase) else { return nil }
        let swing = model.swing
        let metric = model.chartMetric
        let definition = MetricCatalog.definition(for: metric)
        guard let rule = rules.first(where: {
            $0.isEnabled && $0.hasUsableRange && $0.metricID == metric && $0.phases.contains(phase)
                && $0.clubs.contains(swing.club) && $0.views.contains(swing.cameraView)
                && $0.metricDefinitionHash == definition.definitionHash
                && [nil, swing.handedness.leadSide].contains($0.side.resolve(handedness: swing.handedness))
        }) else { return nil }
        let lower = rule.lowerBound ?? definition.range.lowerBound
        let upper = rule.upperBound ?? definition.range.upperBound
        let source = rule.sourceNote.isEmpty ? "" : "（\(rule.sourceNote)）"
        return .init(time: keyframe.timestampSeconds, lower: lower, upper: upper,
                     text: "\(phase.nameZH)参考 \(lower.formatted())–\(upper.formatted())\(definition.unit)\(source)")
    }
}

// MARK: - Landscape

@MainActor
struct LandscapeWorkbench: View {
    let model: WorkbenchModel
    @Binding var stageMode: StageMode
    @Binding var videoMetric: VideoMetric
    @Binding var selectedPhase: SwingPhase?
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            StageVideo(model: model, stageMode: $stageMode, videoMetric: videoMetric)
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.swing.title).font(.footnote).foregroundStyle(CoachStyle.onStage.opacity(0.6))
                        if let keyframe = model.currentPhase.flatMap({ model.swing.keyframes.keyframe(for: $0) }) {
                            Label(keyframe.statusTextZH,
                                  systemImage: keyframe.markedByCoach ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(keyframe.markedByCoach ? CoachStyle.confirmedOnStage : CoachStyle.pendingOnStage)
                        }
                    }
                    Spacer()
                    Button(action: onExit) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.body.weight(.medium))
                    }
                    .buttonStyle(StageButton())
                    .accessibilityLabel("退出横屏")
                }

                TransportBar(model: model, onSnap: { selectedPhase = $0 }, horizontalPadding: 0)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(SwingPhase.allCases) { phase in
                        let keyframe = model.swing.keyframes.keyframe(for: phase)
                        let selected = selectedPhase == phase
                        Button {
                            selectedPhase = phase
                            if let keyframe { model.playback?.pause(); model.playback?.seek(to: keyframe.timestampSeconds) }
                        } label: {
                            VStack(spacing: 4) {
                                Text(phase.shortNameZH).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Image(systemName: keyframe == nil ? "circle.dotted"
                                      : (keyframe!.markedByCoach ? "checkmark.circle.fill" : "circle.dashed"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(keyframe?.markedByCoach == true ? CoachStyle.confirmedOnStage : CoachStyle.pendingOnStage)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(selected ? Color(hex: 0x26302B) : CoachStyle.stageRaised, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? CoachStyle.limeOnDark : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(phase.nameZH)
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(VideoMetric.allCases) { metric in
                        let value = model.currentMetrics?.outcome(metric.metric, metric.side(model.swing.handedness)).value
                        let selected = metric == videoMetric
                        Button { videoMetric = metric } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(metric.label + "部内角")
                                    .font(.caption2)
                                    .foregroundStyle(CoachStyle.onStage.opacity(0.6))
                                Text(value.map { String(format: "%.1f°", $0) } ?? "无法可靠计算")
                                    .font(value == nil ? .footnote.weight(.semibold) : .title3.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(value == nil ? CoachStyle.onStage.opacity(0.55)
                                                     : (selected ? CoachStyle.limeOnDark : CoachStyle.onStage))
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(CoachStyle.stageRaised, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? CoachStyle.limeOnDark.opacity(0.6) : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 340)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CoachStyle.stage.ignoresSafeArea())
        .foregroundStyle(CoachStyle.onStage)
    }

    private var aspect: CGFloat {
        let size = model.videoSize
        return size.height > 0 ? size.width / size.height : 9.0 / 16.0
    }
}

// MARK: - Readouts

@MainActor
struct MetricReadoutGrid: View {
    let metrics: FrameMetrics
    let handedness: Handedness
    var videoMetric: Binding<VideoMetric>?

    private struct Cell: Identifiable {
        let id: String
        let side: String
        let outcome: MetricOutcome
        let videoMetric: VideoMetric?
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let cells: [Cell]
    }

    private func paired(_ id: MetricID, _ name: String, leadLabel: String, trailLabel: String,
                        video: (VideoMetric, VideoMetric)? = nil) -> Row {
        Row(id: name, name: name, cells: [
            Cell(id: name + "L", side: leadLabel, outcome: metrics.outcome(id, handedness.leadSide), videoMetric: video?.0),
            Cell(id: name + "T", side: trailLabel, outcome: metrics.outcome(id, handedness.trailSide), videoMetric: video?.1)
        ])
    }

    /// Group 1: computable from a single frame.
    private var perFrame: [Row] {
        [paired(.elbowInteriorAngle, "肘部内角", leadLabel: "引导臂", trailLabel: "后侧臂", video: (.leadElbow, .trailElbow)),
         paired(.upperArmToTorsoAngle, "上臂与躯干夹角", leadLabel: "引导臂", trailLabel: "后侧臂"),
         Row(id: "双上臂夹角", name: "双上臂夹角",
             cells: [Cell(id: "B", side: "双侧", outcome: metrics.outcome(.betweenUpperArmsAngle), videoMetric: nil)]),
         paired(.kneeInteriorAngle, "膝部内角", leadLabel: "引导侧", trailLabel: "后侧", video: (.leadKnee, .trailKnee))]
    }

    /// Group 2: measured against the address keyframe. Split out because when no
    /// address is marked every one of them is unavailable for the same reason.
    private var relativeToAddress: [(String, MetricOutcome)] {
        [("肩线转角", metrics.outcome(.shoulderLineRotation)),
         ("髋线转角", metrics.outcome(.hipLineRotation)),
         ("肩髋分离角", metrics.outcome(.shoulderHipSeparation))]
    }

    private var addressMissing: Bool {
        if case .unavailable(.addressReferenceMissing) = metrics.outcome(.shoulderLineRotation) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupTitle("单帧可测")
            ForEach(Array(perFrame.enumerated()), id: \.element.id) { index, row in
                if index > 0 { GroupDivider(inset: 0).padding(.horizontal, 16) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.name).font(.subheadline)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              alignment: .leading, spacing: 8) {
                        ForEach(row.cells) { cell in cellView(cell) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Rectangle().fill(CoachStyle.background).frame(height: 6)
            groupTitle("相对准备姿势")
            if addressMissing {
                Label("先标记“准备姿势”关键帧，这三项才有数值。", systemImage: "mappin.circle")
                    .font(.caption)
                    .foregroundStyle(CoachStyle.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            ForEach(Array(relativeToAddress.enumerated()), id: \.offset) { index, item in
                if index > 0 { GroupDivider(inset: 0).padding(.horizontal, 16) }
                HStack(alignment: .firstTextBaseline) {
                    Text(item.0).font(.subheadline)
                    Spacer(minLength: 12)
                    value(item.1, large: false)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .accessibilityElement(children: .combine)
            }
            Text("转角以准备姿势为零点，不是相对目标线。点按带侧别的肘、膝读数，可在视频上显示对应角度。")
                .font(.caption)
                .foregroundStyle(CoachStyle.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 14)
        }
        .coachGroup()
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CoachStyle.textTertiary)
            .kerning(0.5)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    /// Only elbow and knee readings can be drawn on the video, so only those are
    /// buttons; the rest stay plain text rather than looking disabled.
    @ViewBuilder
    private func cellView(_ cell: Cell) -> some View {
        if let metric = cell.videoMetric {
            Button { videoMetric?.wrappedValue = metric } label: {
                cellContent(cell, showing: metric == videoMetric?.wrappedValue)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("在视频上显示这个角度")
        } else {
            cellContent(cell, showing: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func cellContent(_ cell: Cell, showing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(cell.side).font(.caption2).foregroundStyle(CoachStyle.textTertiary)
                if showing {
                    HStack(spacing: 3) {
                        Circle().fill(Color(hex: 0x9BC45A)).frame(width: 6, height: 6)
                        Text("视频中显示")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CoachStyle.accent)
                }
            }
            value(cell.outcome, large: true)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func value(_ outcome: MetricOutcome, large: Bool) -> some View {
        switch outcome {
        case .value(let v):
            Text("\(v, specifier: "%.1f")°")
                .font((large ? Font.title3 : .body).weight(.medium).monospacedDigit())
                .foregroundStyle(CoachStyle.text)
        case .unavailable(let reason):
            // Never a number, never a zero — the reason is shown instead.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "minus.circle").font(.caption)
                VStack(alignment: .leading, spacing: 0) {
                    Text("无法可靠计算").font(.caption.weight(.semibold)).foregroundStyle(CoachStyle.text)
                    Text(reason.localizedZH).font(.caption)
                }
            }
            .foregroundStyle(CoachStyle.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("无法可靠计算：\(reason.localizedZH)")
        }
    }
}
