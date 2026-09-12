import SwiftUI
import AVFoundation
import CoachMeCore

@MainActor
struct WorkbenchView: View {
    @Environment(SwingLibrary.self) private var library
    @State private var model: WorkbenchModel?
    @State private var showingChat = false
    @State private var section = 0
    @State private var showingReanalysis = false
    @State private var usePersonCrop = true
    @State private var phaseTask: Task<Void, Never>?
    let swing: SwingRecord

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView("正在读取分析结果…")
            }
        }
        .onDisappear { phaseTask?.cancel() }
        .navigationTitle("挥杆分析")
        .toolbar(.visible,for:.navigationBar)
        .toolbarBackground(CoachStyle.background,for:.navigationBar)
        .toolbarBackground(.visible,for:.navigationBar)
        .background(CoachStyle.background)
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
                VStack(spacing: 20) {
                    HStack {
                        VStack(alignment:.leading,spacing:5) {
                            Text(model.swing.club.nameZH).font(.title2.weight(.semibold))
                            Text(model.swing.createdAt,format:.dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.swing.cameraView.nameZH).font(.caption.weight(.medium))
                            .padding(.horizontal,12).padding(.vertical,8)
                            .background(CoachStyle.surface,in:Capsule())
                    }
                    VStack(spacing:12) {
                        videoSection(model)
                        transportControls(model).padding(.horizontal,14).padding(.bottom,12)
                    }.background(CoachStyle.surface,in:RoundedRectangle(cornerRadius:22))
                    Picker("分析内容",selection:$section) {
                        Text("动作").tag(0)
                        Text("数据").tag(1)
                        Text("三维").tag(2)
                    }.pickerStyle(.segmented)
                    if section == 0 {
                        keyframeSection(model).coachCard()
                    } else if section == 1 {
                        readoutSection(model).coachCard()
                        chartSection(model).coachCard()
                        DisclosureGroup("分析说明") {
                            Text(model.reviewSummary).font(.caption).foregroundStyle(.secondary)
                            Text("虚线骨架为估计位置，不参与角度计算。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.coachCard()
                        reportLink(model)
                    } else {
                        VStack(alignment:.leading,spacing:12) {
                            Text("空间姿态").font(.headline)
                            Text("标准人体模型随动作变化，可旋转和缩放观察。")
                                .font(.caption).foregroundStyle(.secondary)
                            Skeleton3DView(frame:model.currentDisplayPoseFrame,handedness:model.swing.handedness)
                                .frame(height:460)
                        }.coachCard()
                    }
                }
                .padding(.horizontal,18).padding(.top,8).padding(.bottom,24)
            }
            .background(CoachStyle.background)
            .safeAreaInset(edge:.bottom) {
                discussButton.padding(.horizontal,18).padding(.top,10).padding(.bottom,8)
                    .background(.ultraThinMaterial)
            }
            .sheet(isPresented: $showingReanalysis) { ImportView(initialVideoURL: library.videoURL(for: model.swing)) }
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
        .frame(maxHeight:420)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 20))
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
                       in: playback.timeRange)
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
                 ? "选择视频中的对应动作，添加阶段标记。"
                 : "点击阶段，可跳转查看或调整标记。")
                .font(.caption).foregroundStyle(.secondary)

            if model.swing.keyframes.contains(where: { !$0.markedByCoach }) {
                Text("请检查自动标记是否对应正确动作。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("确认阶段") { model.confirmKeyframes(library: library) }
                    .buttonStyle(.bordered)
            }
            if model.swing.keyframes.isEmpty {
                Button("重新选取单次挥杆分析") { showingReanalysis = true }
                    .disabled(model.findingPhases)
                Toggle("人物增强识别", isOn: $usePersonCrop).font(.subheadline).disabled(model.findingPhases)
                Text("人物较小时优先开启；关闭可使用原图。请只保留一次完整挥杆。")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    phaseTask = Task { await model.findKeyframes(library: library, usePersonCrop: usePersonCrop) }
                } label: {
                    HStack {
                        if model.findingPhases { ProgressView() }
                        Text(model.findingPhases ? "正在识别关键帧…" : "重新自动识别关键帧")
                    }
                }
                .disabled(model.findingPhases)
                .buttonStyle(.bordered)
            }
            if model.findingPhases { Button("停止识别") { phaseTask?.cancel() } }
            if let message = model.phaseDetectionMessage ?? model.swing.phaseDetectionNote {
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
            HStack { Image(systemName:"sparkles"); Text("听听教练怎么说"); Spacer(); Image(systemName:"arrow.up.right") }.padding(.horizontal,18)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CoachPrimaryButton())
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
                                               : AnyShapeStyle(CoachStyle.accent))
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
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(CoachStyle.background,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(marked == nil ? .clear : CoachStyle.accent.opacity(0.18), lineWidth: 1))
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