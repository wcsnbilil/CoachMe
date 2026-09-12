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

    @State private var phase: Phase = .idle
    @State private var progress: AnalysisProgress?
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?

    enum Phase: Equatable { case idle, loading, ready, analysing, failed }

    var body: some View {
        NavigationStack {
            Form {
                shootingGuidance

                Section("视频") {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label(videoURL == nil ? "从相册导入视频" : "更换视频",
                              systemImage: "photo.on.rectangle")
                    }
                    if phase == .loading {
                        HStack { ProgressView(); Text("正在读取视频…") }
                    }
                    if videoURL != nil {
                        if let preview { VideoPlayer(player: preview).frame(height: 240) }
                        Text("只保留一次完整挥杆：从准备姿势到收杆，去掉重复播放和片尾字幕。")
                            .font(.caption).foregroundStyle(.secondary)
                        clipRangeControls
                    }
                }

                if videoURL != nil {
                    Section("设置") {
                        TextField("名称（选填）", text: $title)

                        Picker("持杆手", selection: $handedness) {
                            Text("右手（引导臂为左臂）").tag(Handedness.rightHanded)
                            Text("左手（引导臂为右臂）").tag(Handedness.leftHanded)
                        }

                        Picker("球杆", selection: $club) {
                            ForEach(ClubType.allCases, id: \.self) { Text($0.nameZH).tag($0) }
                        }

                        Picker("拍摄视角", selection: $cameraView) {
                            ForEach(CoachMeCore.CameraView.allCases, id: \.self) { Text($0.nameZH).tag($0) }
                        }
                        Text("视角会影响哪些指标可用，选「未知」时部分指标不会给出评价。")
                            .font(.caption).foregroundStyle(.secondary)

                        Toggle("这是慢动作视频", isOn: $isSlowMotion)
                        Text(isSlowMotion
                             ? "将按慢动作校准关键点平滑。适用于手机慢动作模式，或已降速导出的片段。"
                             : "按正常速度校准关键点平滑。若视频其实是慢动作，读数会比可达到的更抖。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let progress, phase == .analysing {
                    Section("分析中") {
                        ProgressView(value: progress.fraction) {
                            Text("\(progress.stage ?? "识别骨骼与动作阶段")：\(progress.framesProcessed) / \(progress.estimatedTotalFrames) 帧")
                        }
                        Text(String(format: "当前 %.2f 秒", progress.currentTimestampSeconds))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("取消分析", role: .destructive) { cancelAnalysis() }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.primary)
                        if videoURL != nil { Button("重试分析") { startAnalysis() }.disabled(phase == .analysing) }
                    }
                }
            }
            .disabled(phase == .analysing)
            .overlay(alignment: .bottom) {
                if phase == .analysing {
                    Button("取消分析", role: .destructive) { cancelAnalysis() }
                        .buttonStyle(.borderedProminent).padding().background(.thinMaterial, in: Capsule())
                }
            }
            .navigationTitle("新的分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { cancelAnalysis(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始分析") { startAnalysis() }
                        .disabled(videoURL == nil || phase == .analysing || phase == .loading || clipEnd - clipStart < 0.1)
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

    private var shootingGuidance: some View {
        Section("拍摄建议") {
            Label("固定机位，不要手持跟拍", systemImage: "camera.metering.center.weighted")
            Label("全身入镜，脚和头都不要出画", systemImage: "figure.stand")
            Label("避免遮挡，背景尽量干净、画面中只有一个人", systemImage: "person.crop.rectangle")
            Text("这些条件直接决定关键点能否被稳定识别。不满足时，App 会显示「无法可靠计算」而不是给出不可靠的数字。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var clipRangeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "分析片段：%.2f – %.2f 秒（共 %.2f 秒）",
                        clipStart, clipEnd, max(0, clipEnd - clipStart)))
                .font(.subheadline)
            HStack {
                Text("起点").font(.caption).frame(width: 32, alignment: .leading)
                Slider(value: $clipStart, in: 0...max(assetDuration, 0.01)) { _ in
                    if clipStart > clipEnd { clipStart = max(0, clipEnd - 0.1) }
                }
                .accessibilityLabel("片段起点")
            }
            HStack {
                Text("终点").font(.caption).frame(width: 32, alignment: .leading)
                Slider(value: $clipEnd, in: 0...max(assetDuration, 0.01)) { _ in
                    if clipEnd < clipStart { clipEnd = min(assetDuration, clipStart + 0.1) }
                }
                .accessibilityLabel("片段终点")
            }
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
                let filename = try LocalStore.shared.importVideo(from: videoURL, swingID: swingID)
                storedFilename = filename
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
                try LocalStore.shared.saveAnalysis(cache)

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
