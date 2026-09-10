import SwiftUI
import AVFoundation
import CoachMeCore

@MainActor
struct WorkbenchView: View {
    @Environment(SwingLibrary.self) private var library
    @State private var model: WorkbenchModel?
    @State private var showingChat = false
    let swing: SwingRecord

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView("正在读取分析结果…")
            }
        }
        .navigationTitle(swing.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = WorkbenchModel(swing: swing,
                                       cache: library.analysis(for: swing),
                                       videoURL: library.videoURL(for: swing))
            }
        }
    }

    @ViewBuilder
    private func content(_ model: WorkbenchModel) -> some View {
        @Bindable var model = model

        if model.cache == nil {
            ContentUnavailableView {
                Label("这段挥杆还没有分析结果", systemImage: "waveform.path.ecg")
            } description: {
                Text("分析可能被取消或失败了。请重新导入这段视频。")
            }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    videoSection(model)
                    transportControls(model)
                    keyframeSection(model)
                    readoutSection(model)
                    chartSection(model)
                    skeleton3DSection(model)
                    reportLink(model)
                    discussButton
                }
                .padding()
            }
            .sheet(isPresented: $showingChat) {
                ChatPanelView(swing: model.swing,
                              phase: model.currentPhase,
                              timestamp: model.playback?.currentTime ?? 0,
                              context: model.buildContext(rules: library.rules))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func videoSection(_ model: WorkbenchModel) -> some View {
        ZStack {
            if let playback = model.playback {
                PlayerLayerView(player: playback.player)
                if model.showSkeleton {
                    SkeletonOverlay(frame: model.currentPoseFrame,
                                    handedness: model.swing.handedness,
                                    videoSize: model.videoSize,
                                    minVisibility: model.swing.qualityPolicy.minVisibility)
                }
            } else {
                Color.black
            }
        }
        .aspectRatio(model.videoSize.width / max(model.videoSize.height, 1), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Toggle(isOn: Binding(get: { model.showSkeleton },
                                 set: { model.showSkeleton = $0 })) {
                Label("骨架", systemImage: "figure.walk")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .padding(8)
            .accessibilityLabel("显示或隐藏骨架叠加")
        }
        .overlay(alignment: .bottomLeading) {
            if let quality = model.currentMetrics?.quality, quality.blockingReason != nil {
                Label(quality.blockingReason!.localizedZH, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private func transportControls(_ model: WorkbenchModel) -> some View {
        if let playback = model.playback {
            @Bindable var playback = playback
            VStack(spacing: 8) {
                Slider(value: Binding(get: { playback.currentTime },
                                      set: { playback.seek(to: $0) }),
                       in: 0...max(playback.duration, 0.01))
                    .accessibilityLabel("播放进度")

                HStack(spacing: 20) {
                    Button { playback.step(by: -1, timestamps: model.timestamps) } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .accessibilityLabel("上一帧")

                    Button { playback.togglePlay() } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.largeTitle)
                    }
                    .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")

                    Button { playback.step(by: 1, timestamps: model.timestamps) } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .accessibilityLabel("下一帧")

                    Picker("速度", selection: Binding(get: { playback.rate },
                                                    set: { playback.setRate($0) })) {
                        Text("0.1×").tag(Float(0.1))
                        Text("0.25×").tag(Float(0.25))
                        Text("0.5×").tag(Float(0.5))
                        Text("1×").tag(Float(1.0))
                    }
                    .pickerStyle(.menu)
                }
                .font(.title2)

                Text(String(format: "%.3f 秒", playback.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func keyframeSection(_ model: WorkbenchModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("动作阶段").font(.headline)
                Spacer()
                if let phase = model.currentPhase {
                    Label(phase.nameZH, systemImage: "mappin.circle.fill").font(.subheadline)
                }
            }
            Text("v1 由教练手动标记。自动识别尚未经过验证，标错阶段会让按阶段生效的规则全部失效。")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SwingPhase.allCases) { phase in
                        KeyframeChip(phase: phase,
                                     marked: model.swing.keyframes.keyframe(for: phase),
                                     onMark: { model.markKeyframe(phase, library: library) },
                                     onJump: { time in model.playback?.seek(to: time) },
                                     onClear: { model.clearKeyframe(phase, library: library) })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readoutSection(_ model: WorkbenchModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前角度").font(.headline)
            if let metrics = model.currentMetrics {
                MetricReadoutGrid(metrics: metrics, handedness: model.swing.handedness)
            } else {
                Text("这一帧没有可用数据。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func chartSection(_ model: WorkbenchModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("角度曲线").font(.headline)
                Spacer()
                Picker("指标", selection: $model.chartMetric) {
                    ForEach(MetricID.allCases.filter { $0 != .wristPathBodyReferenced }, id: \.self) {
                        Text(MetricCatalog.definition(for: $0).nameZH).tag($0)
                    }
                }
                .pickerStyle(.menu)
            }
            AngleChartView(timeline: model.timeline,
                           metric: model.chartMetric,
                           handedness: model.swing.handedness,
                           keyframes: model.swing.keyframes,
                           currentTime: model.playback?.currentTime ?? 0,
                           onScrub: { model.playback?.seek(to: $0) })
                .frame(height: 220)
        }
    }

    @ViewBuilder
    private func skeleton3DSection(_ model: WorkbenchModel) -> some View {
        DisclosureGroup("独立骨架视图（三维估计）") {
            Skeleton3DView(frame: model.currentPoseFrame, handedness: model.swing.handedness)
                .frame(height: 320)
        }
    }

    @ViewBuilder
    private func reportLink(_ model: WorkbenchModel) -> some View {
        NavigationLink {
            ReportView(swing: model.swing)
        } label: {
            Label("查看分析报告", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var discussButton: some View {
        Button {
            showingChat = true
        } label: {
            Label("与 AI 教练讨论", systemImage: "bubble.left.and.text.bubble.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

@MainActor
struct KeyframeChip: View {
    let phase: SwingPhase
    let marked: Keyframe?
    let onMark: () -> Void
    let onJump: (Double) -> Void
    let onClear: () -> Void

    var body: some View {
        Menu {
            if let marked {
                Button("跳到该帧") { onJump(marked.timestampSeconds) }
                Button("用当前帧覆盖") { onMark() }
                Button("清除标记", role: .destructive) { onClear() }
            } else {
                Button("用当前帧标记") { onMark() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: marked == nil ? "circle.dashed" : "checkmark.circle.fill")
                Text(phase.nameZH)
                if let marked {
                    Text(String(format: "%.2fs", marked.timestampSeconds))
                        .font(.caption2.monospacedDigit())
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .accessibilityLabel("\(phase.nameZH)\(marked == nil ? "，未标记" : "，已标记")")
    }
}

@MainActor
struct MetricReadoutGrid: View {
    let metrics: FrameMetrics
    let handedness: Handedness

    private var rows: [(String, MetricOutcome, String)] {
        let lead = handedness.leadSide, trail = handedness.trailSide
        return [
            ("引导臂肘部", metrics.outcome(.elbowInteriorAngle, lead), "°"),
            ("后侧臂肘部", metrics.outcome(.elbowInteriorAngle, trail), "°"),
            ("引导臂上臂-躯干", metrics.outcome(.upperArmToTorsoAngle, lead), "°"),
            ("后侧臂上臂-躯干", metrics.outcome(.upperArmToTorsoAngle, trail), "°"),
            ("双上臂夹角", metrics.outcome(.betweenUpperArmsAngle), "°"),
            ("引导侧膝部", metrics.outcome(.kneeInteriorAngle, lead), "°"),
            ("后侧膝部", metrics.outcome(.kneeInteriorAngle, trail), "°"),
            ("肩线转角", metrics.outcome(.shoulderLineRotation), "°"),
            ("髋线转角", metrics.outcome(.hipLineRotation), "°"),
            ("肩髋分离角", metrics.outcome(.shoulderHipSeparation), "°")
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(rows, id: \.0) { name, outcome, unit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    switch outcome {
                    case .value(let v):
                        Text("\(v, specifier: "%.1f")\(unit)")
                            .font(.title3.monospacedDigit().weight(.medium))
                    case .unavailable(let reason):
                        // Never a number, never a zero — the reason is shown instead.
                        Label("无法可靠计算", systemImage: "minus.circle")
                            .font(.caption.weight(.medium))
                        Text(reason.localizedZH).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
