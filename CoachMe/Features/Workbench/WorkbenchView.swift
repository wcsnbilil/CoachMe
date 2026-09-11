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
                    if model.showSkeleton {
                        Text("骨架已启用时序与人体比例补全；虚线为估计位置，不用于角度评分。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    SkeletonOverlay(frame: model.currentDisplayPoseFrame,
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
            Text(model.swing.keyframes.isEmpty
                 ? "尚无可用的自动标记：可能未运行阶段识别，或预测阶段顺序冲突。可手动标记；重新拍摄时尽量让人物占满画面并只保留一次完整挥杆。"
                 : "自动标记可直接跳转查看；需要调整时，拖动视频后重新标记该阶段。")
                .font(.caption).foregroundStyle(.secondary)

            if model.swing.keyframes.isEmpty {
                Button {
                    Task { await model.findKeyframes(library: library) }
                } label: {
                    HStack {
                        if model.findingPhases { ProgressView() }
                        Text(model.findingPhases ? "正在识别关键帧…" : "重新自动识别关键帧")
                    }
                }
                .disabled(model.findingPhases)
                .buttonStyle(.bordered)
            }
            if let message = model.phaseDetectionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            // Two columns rather than a horizontal scroller: at 375pt only two
            // and a half chips were visible, so a coach could not see that six
            // phases exist, let alone which were still unmarked.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
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
            Skeleton3DView(frame: model.currentDisplayPoseFrame, handedness: model.swing.handedness)
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
            KeyframeChipLabel(phase: phase, marked: marked)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(phase.nameZH)\(marked.map { "，已标记于 \(String(format: "%.2f", $0.timestampSeconds)) 秒" } ?? "，未标记")")
    }
}

/// The chip's visual, split from the `Menu` that wraps it so it can be rendered
/// and inspected on its own — `ImageRenderer` cannot draw interactive controls.
@MainActor
struct KeyframeChipLabel: View {
    let phase: SwingPhase
    let marked: Keyframe?

    var body: some View {
        HStack(spacing: 8) {
            // Shape carries the state as well as colour: a dashed ring reads as
            // unmarked even without colour perception.
            Image(systemName: marked == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(marked == nil ? AnyShapeStyle(.secondary)
                                               : AnyShapeStyle(Palette.leadArm))
            VStack(alignment: .leading, spacing: 1) {
                Text(phase.nameZH)
                    .font(.subheadline.weight(marked == nil ? .regular : .medium))
                Text(marked.map { String(format: "%.2f 秒", $0.timestampSeconds) + ($0.markedByCoach ? " · 手动" : " · 自动") } ?? "未标记")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // 44pt is the iOS minimum touch target; the old chip was about 32pt.
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(.quaternary.opacity(marked == nil ? 0.35 : 0.6),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(marked == nil ? .clear : Palette.leadArm.opacity(0.4), lineWidth: 1))
    }
}

@MainActor
struct MetricReadoutGrid: View {
    let metrics: FrameMetrics
    let handedness: Handedness

    /// One reading: a metric with either one value or a lead/trail pair.
    private struct Row: Identifiable {
        let id: String
        let name: String
        let lead: MetricOutcome?
        let trail: MetricOutcome?
        let single: MetricOutcome?
    }

    private func paired(_ id: MetricID, _ name: String) -> Row {
        Row(id: name, name: name,
            lead: metrics.outcome(id, handedness.leadSide),
            trail: metrics.outcome(id, handedness.trailSide),
            single: nil)
    }

    private func bilateral(_ id: MetricID, _ name: String) -> Row {
        Row(id: name, name: name, lead: nil, trail: nil, single: metrics.outcome(id))
    }

    /// Group 1: computable from a single frame.
    private var perFrame: [Row] {
        [paired(.elbowInteriorAngle, "肘部内角"),
         paired(.upperArmToTorsoAngle, "上臂与躯干夹角"),
         bilateral(.betweenUpperArmsAngle, "双上臂夹角"),
         paired(.kneeInteriorAngle, "膝部内角")]
    }

    /// Group 2: measured against the address keyframe. Split out because when no
    /// address is marked every one of them is unavailable for the same reason,
    /// and a coach reading four identical "cannot compute" cards learns nothing.
    private var relativeToAddress: [Row] {
        [bilateral(.shoulderLineRotation, "肩线转角"),
         bilateral(.hipLineRotation, "髋线转角"),
         bilateral(.shoulderHipSeparation, "肩髋分离角")]
    }

    private var addressMissing: Bool {
        if case .unavailable(.addressReferenceMissing) = metrics.outcome(.shoulderLineRotation) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("单帧可测", rows: perFrame, note: nil)
            group("相对准备姿势", rows: relativeToAddress,
                  note: addressMissing ? "先在上方标记「准备姿势」关键帧，这三项才有数值。" : nil)
        }
    }

    @ViewBuilder
    private func group(_ title: String, rows: [Row], note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
            if let note {
                Label(note, systemImage: "mappin.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, 14)
                    }
                    readingRow(row)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func readingRow(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let single = row.single {
                // Bilateral metric: name and value share one line.
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name).font(.subheadline)
                    Spacer(minLength: 12)
                    value(single)
                }
            } else {
                // Sided metric: the name is stated once, then the two sides sit
                // in equal-width columns so their values line up down the grid.
                Text(row.name).font(.subheadline)
                HStack(alignment: .top, spacing: 12) {
                    if let lead = row.lead { sideColumn("引导臂", lead) }
                    if let trail = row.trail { sideColumn("后侧臂", trail) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Side label above its value, never after it: the label has to be read
    /// first for the number below it to mean anything.
    @ViewBuilder
    private func sideColumn(_ label: String, _ outcome: MetricOutcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            value(outcome)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func value(_ outcome: MetricOutcome) -> some View {
        switch outcome {
        case .value(let v):
            Text("\(v, specifier: "%.1f")°")
                .font(.title3.monospacedDigit().weight(.medium))
        case .unavailable(let reason):
            // Never a number, never a zero — the reason is shown instead.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "minus.circle").font(.caption)
                Text(reason.localizedZH)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("无法可靠计算：\(reason.localizedZH)")
        }
    }
}