import SwiftUI
import PhotosUI
import AVFoundation
import AVKit
import CoachMeCore

/// Import + setup + run the analysis. Everything the analysis needs that cannot
/// be inferred from pixels (handedness, club, camera view) is asked for here.
@MainActor
struct ImportView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let initialVideoURL: URL?
    let onImported: ((SwingRecord) -> Void)?
    init(initialVideoURL: URL? = nil, onImported: ((SwingRecord) -> Void)? = nil) {
        self.initialVideoURL = initialVideoURL
        self.onImported = onImported
    }
    @State private var preview: AVPlayer?
    @State private var loadTask: Task<Void, Never>?
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var assetDuration: Double = 0
    @State private var clipStart: Double = 0
    @State private var clipEnd: Double = 0

    @State private var handedness: Handedness = .rightHanded
    @State private var club: ClubType = .iron
    @State private var cameraView: CoachMeCore.CameraView = .faceOn
    /// Nothing in a video file says whether it was slowed down, and the smoothing
    /// cutoff has to match the footage's time base — see SmoothingParameters.
    @State private var isSlowMotion = false
    @State private var title = ""
    @State private var tipsOpen = false

    @State private var phase: Phase = .idle
    @State private var progress: AnalysisProgress?
    @State private var errorMessage: String?
    @State private var wasCancelled = false
    @State private var analysisTask: Task<Void, Never>?

    enum Phase: Equatable { case idle, loading, ready, analysing, failed }

    var body: some View {
        NavigationStack {
            Group {
                if phase == .analysing {
                    AnalysisProgressPanel(progress: progress, videoURL: videoURL, clipStart: clipStart,
                                          clipEnd: clipEnd, onCancel: cancelAnalysis)
                } else {
                    form
                }
            }
            .background(CoachStyle.background)
            .navigationTitle("新的分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CoachStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { cancelAnalysis(); dismiss() }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                loadTask?.cancel()
                loadTask = Task { await load(item) }
            }
        }
        .interactiveDismissDisabled(phase == .analysing)
        .task { if let initialVideoURL, videoURL == nil { await prepareVideo(initialVideoURL) } }
        .onDisappear { loadTask?.cancel(); analysisTask?.cancel(); preview?.pause() }
        .onChange(of: clipStart) { _, time in
            preview?.pause()
            preview?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onChange(of: clipEnd) { old, time in
            guard old > 0 else { return }
            preview?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: time, preferredTimescale: 600)
            preview?.pause()
            preview?.seek(to: CMTime(seconds: max(clipStart, time - 0.04), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                banners

                videoArea.padding(.horizontal, 10)

                if let videoURL {
                    trimSection(videoURL)
                        .padding(.horizontal, 18)
                        .padding(.top, 20)
                    settings
                        .padding(.horizontal, 18)
                        .padding(.top, 24)
                }

                tips
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                FootnoteLine(symbol: "lock", text: "视频只在本机分析，不会上传。")
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button { startAnalysis() } label: {
                HStack {
                    Text(phase == .failed ? "重试分析" : "开始分析")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 18)
            }
            .buttonStyle(CoachPrimaryButton())
            .disabled(videoURL == nil || phase == .loading || clipEnd - clipStart < 0.1)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(CoachStyle.background.overlay(alignment: .top) {
                Rectangle().fill(CoachStyle.line).frame(height: 1)
            })
        }
    }

    @ViewBuilder
    private var banners: some View {
        if wasCancelled && errorMessage == nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle")
                Text("已取消分析。选段和设置已保留，可以随时重新开始。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
            .foregroundStyle(CoachStyle.text)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoachStyle.neutralFill, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        if let errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("分析没有完成").font(.subheadline.weight(.semibold))
                        Text(errorMessage).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(CoachStyle.alert)
                if videoURL != nil {
                    Button("重试分析") { startAnalysis() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(CoachStyle.alert, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.leading, 28)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoachStyle.alertFill, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var videoArea: some View {
        if phase == .loading {
            VStack(spacing: 14) {
                ProgressView().tint(CoachStyle.onStage)
                Text("正在读取视频…").font(.subheadline.weight(.semibold))
                Text("从相册复制到 App 内，较长的视频需要稍等").font(.caption).opacity(0.6)
            }
            .foregroundStyle(CoachStyle.onStage)
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            .background(CoachStyle.stage, in: RoundedRectangle(cornerRadius: 22))
        } else if let preview {
            VideoPlayer(player: preview)
                .frame(height: 330)
                .background(CoachStyle.stage)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(alignment: .topTrailing) {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("更换视频", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(StageButton())
                    .padding(8)
                }
        } else {
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                VStack(spacing: 12) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(CoachStyle.accent)
                    Text("选择一段挥杆").font(.headline).foregroundStyle(CoachStyle.text)
                    Text("从准备姿势到收杆，记录一次完整动作。")
                        .font(.footnote)
                        .foregroundStyle(CoachStyle.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(CoachStyle.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            }
            .buttonStyle(.plain)
        }
    }

    private func trimSection(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("选取一次完整挥杆").font(.headline)
                Text("拖动两端，从准备姿势到收杆，去掉重复播放和片尾。")
                    .font(.footnote)
                    .foregroundStyle(CoachStyle.textSecondary)
            }
            ClipTrimmer(url: url, duration: assetDuration, start: $clipStart, end: $clipEnd)
            HStack(spacing: 8) {
                stat("起点", clipStart)
                stat("终点", clipEnd)
                stat("时长", max(0, clipEnd - clipStart))
            }
        }
    }

    private func stat(_ title: String, _ seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(CoachStyle.textTertiary)
            Text(String(format: "%.2f 秒", seconds)).font(.callout.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("分析设置")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("名称")
                    TextField(defaultTitle(), text: $title)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(CoachStyle.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                GroupDivider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("持杆手")
                        Spacer()
                        CoachSegmented(options: [(Handedness.rightHanded, "右手"), (.leftHanded, "左手")],
                                       selection: $handedness, segmentWidth: 64)
                    }
                    caption(handedness == .rightHanded ? "右手持杆：引导臂为左臂" : "左手持杆：引导臂为右臂")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                GroupDivider()

                HStack {
                    Text("球杆")
                    Spacer()
                    Picker("球杆", selection: $club) {
                        ForEach(ClubType.allCases, id: \.self) { Text($0.nameZH).tag($0) }
                    }
                    .labelsHidden()
                    .tint(CoachStyle.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                GroupDivider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("拍摄视角")
                        Spacer()
                        Picker("拍摄视角", selection: $cameraView) {
                            ForEach(CoachMeCore.CameraView.allCases, id: \.self) { Text($0.nameZH).tag($0) }
                        }
                        .labelsHidden()
                        .tint(CoachStyle.textSecondary)
                    }
                    caption("视角会影响哪些指标可用；选择“未知”时，部分指标不会与参考范围比较。")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                GroupDivider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("这是慢动作视频", isOn: $isSlowMotion).tint(CoachStyle.accent)
                    caption(isSlowMotion
                            ? "将按慢动作校准关键点平滑。适用于手机慢动作模式，或已降速导出的片段。"
                            : "按正常速度校准关键点平滑。若视频其实是慢动作，读数会比实际更抖。")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .coachGroup()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(CoachStyle.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { tipsOpen.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "camera").foregroundStyle(CoachStyle.accent)
                    Text("怎样拍得更清楚").foregroundStyle(CoachStyle.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoachStyle.textTertiary)
                        .rotationEffect(.degrees(tipsOpen ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if tipsOpen {
                VStack(alignment: .leading, spacing: 12) {
                    tip("固定机位，全身入镜", "三脚架或稳定支撑，头顶到脚底都在画面内，留出球杆空间。")
                    tip("正面或沿目标线后方", "镜头约与手部同高，尽量正对或沿目标线拍摄。")
                    tip("避免遮挡与多人入镜", "光线充足，衣服与背景有区分；画面里只保留一位挥杆者。")
                }
                .padding(.leading, 48)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .coachGroup()
    }

    private func tip(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(CoachStyle.textSecondary)
        }
    }

    // MARK: - Actions

    private func load(_ item: PhotosPickerItem) async {
        phase = .loading
        videoURL = nil
        preview?.pause()
        preview = nil
        clipEnd = 0
        errorMessage = nil
        wasCancelled = false
        do {
            guard let movie = try await item.loadTransferable(type: VideoFile.self) else {
                throw ImportError.unreadable
            }
            try Task.checkCancellation()
            await prepareVideo(movie.url)
        } catch is CancellationError { return }
        catch {
            errorMessage = "读取视频失败：\(error.localizedDescription)"
            phase = .failed
        }
    }

    private func prepareVideo(_ url: URL) async {
        phase = .loading
        preview?.pause()
        videoURL = nil
        errorMessage = nil
        do {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            try Task.checkCancellation()
            guard duration.isFinite, duration >= 0.1 else { throw ImportError.unreadable }
            videoURL = url
            assetDuration = duration
            clipStart = 0
            clipEnd = duration
            preview = AVPlayer(url: url)
            phase = .ready
        } catch is CancellationError { return }
        catch { phase = .failed; errorMessage = "读取视频失败：\(error.localizedDescription)" }
    }

    private func startAnalysis() {
        guard let videoURL, phase != .analysing, phase != .loading,
              clipStart.isFinite, clipEnd.isFinite, clipEnd - clipStart >= 0.1 else { return }
        let selectedStart = clipStart, selectedEnd = clipEnd
        let selectedSlowMotion = isSlowMotion
        preview?.pause()
        errorMessage = nil
        wasCancelled = false
        phase = .analysing
        progress = nil

        let swingID = UUID()
        let record = SwingRecord(
            id: swingID,
            title: title.isEmpty ? defaultTitle() : title,
            videoFilename: "",
            clipStartSeconds: clipStart,
            clipEndSeconds: clipEnd,
            handedness: handedness,
            club: club,
            cameraView: cameraView,
            poseModelIdentifier: MediaPipePoseDetector.ModelVariant.heavy.rawValue
        )

        analysisTask = Task {
            var storedFilename: String?
            var committed = false
            defer { if !committed { LocalStore.shared.discardPendingImport(id: swingID, filename: storedFilename) } }
            do {
                let storage = AnalysisImportStorage(root: LocalStore.shared.root)
                let filename = try await storage.importVideo(from: videoURL, swingID: swingID)
                storedFilename = filename
                try Task.checkCancellation()
                var saved = record
                saved.videoFilename = filename

                let storedURL = LocalStore.shared.videosDirectory.appendingPathComponent(filename)
                let asset = AVURLAsset(url: storedURL)
                let range = CMTimeRange(
                    start: CMTime(seconds: selectedStart, preferredTimescale: 600),
                    end: CMTime(seconds: selectedEnd, preferredTimescale: 600))

                let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(),
                                             phaseDetector: SwingNetPhaseDetector())
                let frames = try await analyzer.analyse(asset: asset, timeRange: range) { p in
                    Task { @MainActor in progress = p }
                }
                try Task.checkCancellation()

                saved.keyframes = await analyzer.keyframes
                saved.phaseDetectionNote = await analyzer.phaseDetectionNote

                let cache = AnalysisCache(swingID: swingID,
                                          analysisVersion: saved.analysisVersion,
                                          algorithmVersion: saved.algorithmVersion,
                                          poseModelIdentifier: saved.poseModelIdentifier,
                                          createdAt: Date(),
                                          frames: frames,
                                          smoothing: selectedSlowMotion ? .slowMotion : .realTime)
                progress = AnalysisProgress(framesProcessed: 0, estimatedTotalFrames: 0, currentTimestampSeconds: 0, stage: "正在保存分析…")
                try await storage.saveAnalysis(cache)
                try Task.checkCancellation()

                try library.saveChecked(saved)
                committed = true
                onImported?(saved)
                dismiss()
            } catch is CancellationError {
                phase = .ready
            } catch AnalysisError.cancelled {
                phase = .ready
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    phase = .failed
                }
            }
        }
    }

    private func cancelAnalysis() {
        if phase == .analysing { wasCancelled = true }
        analysisTask?.cancel()
        // Remain busy until the task has actually unwound and cleaned its files.
        preview?.pause()
    }

    private func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return "\(formatter.string(from: Date())) \(club.nameZH)"
    }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "无法读取所选视频。" }
    }
}

/// Filmstrip with two handles; the frame between them is what gets analysed.
@MainActor
struct ClipTrimmer: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double

    private static let minimumLength = 0.1
    private static let handleWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let span = max(duration, 0.01)
            let x: (Double) -> CGFloat = { CGFloat($0 / span) * width }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { index in
                        VideoFrameImage(url: url, time: span * (Double(index) + 0.5) / 10, maxPixel: 160)
                            .frame(width: width / 10, height: 64)
                            .clipped()
                    }
                }
                Rectangle().fill(CoachStyle.background.opacity(0.72)).frame(width: x(start))
                Rectangle().fill(CoachStyle.background.opacity(0.72))
                    .frame(width: max(0, width - x(end)))
                    .offset(x: x(end))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(CoachStyle.forest, lineWidth: 3)
                    .frame(width: max(Self.handleWidth * 2, x(end) - x(start)))
                    .offset(x: x(start))
                    .allowsHitTesting(false)
                handle
                    .offset(x: x(start))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { drag in
                        let t = Double(drag.location.x / width) * span
                        start = min(max(0, t), end - Self.minimumLength)
                    })
                    .accessibilityElement()
                    .accessibilityLabel("片段起点")
                    .accessibilityValue(String(format: "%.2f 秒", start))
                    .accessibilityAdjustableAction { direction in
                        start = min(max(0, start + (direction == .increment ? 0.05 : -0.05)), end - Self.minimumLength)
                    }
                handle
                    .offset(x: max(0, x(end) - Self.handleWidth))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { drag in
                        let t = Double(drag.location.x / width) * span
                        end = max(min(span, t), start + Self.minimumLength)
                    })
                    .accessibilityElement()
                    .accessibilityLabel("片段终点")
                    .accessibilityValue(String(format: "%.2f 秒", end))
                    .accessibilityAdjustableAction { direction in
                        end = max(min(span, end + (direction == .increment ? 0.05 : -0.05)), start + Self.minimumLength)
                    }
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var handle: some View {
        ZStack {
            Rectangle().fill(CoachStyle.forest)
            HStack(spacing: 2) {
                Capsule().fill(CoachStyle.lime).frame(width: 2, height: 20)
                Capsule().fill(CoachStyle.lime).frame(width: 2, height: 20)
            }
        }
        .frame(width: Self.handleWidth, height: 64)
        // Wider than it looks, so the handle meets the 44 pt touch minimum.
        .contentShape(Rectangle().inset(by: -14))
    }
}

/// Shows what the analysis is doing. Steps with a known frame count show real
/// progress; steps without one only say they are running — no invented percentage.
@MainActor
struct AnalysisProgressPanel: View {
    let progress: AnalysisProgress?
    let videoURL: URL?
    let clipStart: Double
    let clipEnd: Double
    let onCancel: () -> Void

    private static let steps = ["加载分析模型", "识别人体关键点", "识别动作阶段", "保存分析结果"]

    private var activeStep: Int {
        guard let stage = progress?.stage else { return 0 }
        if stage.contains("保存") { return 3 }
        if stage.contains("动作阶段（") || stage.contains("整理关键帧") { return 2 }
        if stage.contains("骨骼") { return 1 }
        return 0
    }

    private var knownTotal: Bool { (progress?.estimatedTotalFrames ?? 0) > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let videoURL {
                    VideoFrameImage(url: videoURL, time: floor(currentTime * 4) / 4, maxPixel: 700).opacity(0.6)
                } else {
                    CoachStyle.stage
                }
                if knownTotal {
                    GeometryReader { geometry in
                        Rectangle().fill(CoachStyle.limeOnDark)
                            .frame(width: geometry.size.width * (progress?.fraction ?? 0), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                Text(String(format: "当前 %.2f 秒", currentTime - clipStart))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(CoachStyle.onStage)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(CoachStyle.stage.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            }
            .frame(height: 280)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("正在分析这次挥杆").font(.title2.weight(.semibold))
                Text("分析在本机进行，离开此页面会中断。")
                    .font(.subheadline)
                    .foregroundStyle(CoachStyle.textSecondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)

            VStack(spacing: 0) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, name in
                    if index > 0 { GroupDivider(inset: 0) }
                    stepRow(index: index, name: name)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .coachGroup()
            .padding(.horizontal, 18)
            .padding(.top, 18)

            Text("帧数已知的步骤显示处理进度；其余步骤无法预估耗时，只显示正在进行。")
                .font(.caption)
                .foregroundStyle(CoachStyle.textTertiary)
                .padding(.horizontal, 22)
                .padding(.top, 12)

            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button("取消分析", action: onCancel)
                .buttonStyle(CoachSecondaryButton(tint: CoachStyle.alert))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(CoachStyle.background)
        }
        .padding(.top, 4)
    }

    private var currentTime: Double {
        let time = progress?.currentTimestampSeconds ?? 0
        return time > 0 ? time : clipStart
    }

    private func stepRow(index: Int, name: String) -> some View {
        let done = index < activeStep
        let active = index == activeStep
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CoachStyle.accent)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(CoachStyle.textTertiary.opacity(0.6))
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(name)
                        .font(.subheadline.weight(active ? .semibold : .regular))
                        .foregroundStyle(done || active ? CoachStyle.text : CoachStyle.textTertiary)
                    Spacer()
                    Text(meta(index: index, done: done, active: active))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(CoachStyle.textSecondary)
                }
                if active {
                    if knownTotal && (index == 1 || index == 2) {
                        ProgressView(value: progress?.fraction ?? 0).tint(CoachStyle.accent)
                    } else {
                        IndeterminateBar()
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func meta(index: Int, done: Bool, active: Bool) -> String {
        if done { return "完成" }
        guard active else { return "等待中" }
        if knownTotal, let progress, index == 1 || index == 2 {
            return "\(progress.framesProcessed) / \(progress.estimatedTotalFrames) 帧"
        }
        return "进行中"
    }
}

/// Moving bar for work whose length is unknown.
struct IndeterminateBar: View {
    @State private var moving = false

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(CoachStyle.fill)
                .overlay(alignment: .leading) {
                    Capsule().fill(CoachStyle.accent)
                        .frame(width: geometry.size.width * 0.4)
                        .offset(x: moving ? geometry.size.width : -geometry.size.width * 0.4)
                }
                .clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { moving = true }
        }
        .accessibilityLabel("正在进行")
    }
}

/// PhotosPicker hands back a file URL that is only valid briefly; copying it to
/// a temporary location keeps it alive until the analysis copies it into the store.
struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return VideoFile(url: destination)
        }
    }
}
