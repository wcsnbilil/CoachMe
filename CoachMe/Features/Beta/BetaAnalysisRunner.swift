import Foundation
import AVFoundation
import CoachMeCore

/// Imports a video, finds the swing, runs the downswing path check and saves a
/// BetaRecord. Same pipeline as ImportView, with the camera fixed to down-the-line
/// and no trimming.
@MainActor
enum BetaAnalysisRunner {

    /// One person, like the Python reference: with two, MediaPipe's tracking changed the verdict on
    /// two clips of the end-to-end matrix (PR #10). The beta screens never report bystanders.
    static let betaNumPoses = 1

    /// Clips longer than this get a quick low-rate pass first (SwingAnalyzer.scout + SwingSplitter)
    /// and only the chosen swing is analysed in full: a 60 s range video took 6 minutes whole.
    /// Shorter clips are analysed whole, exactly as before.
    static let splitMinimumSeconds = 8.0
    static let scoutFramesPerSecond = 15.0

    /// Where the chosen swing is in a long clip.
    struct SwingSelection: Equatable {
        /// Swings found by the first pass, in time order, as video time ranges (padded windows).
        var windows: [ClosedRange<Double>]
        /// Index into `windows` of the one to analyse.
        var chosen: Int
        var scoutMilliseconds: Int

        var range: CMTimeRange {
            CMTimeRange(start: CMTime(seconds: windows[chosen].lowerBound, preferredTimescale: 600),
                        end: CMTime(seconds: windows[chosen].upperBound, preferredTimescale: 600))
        }
    }

    /// Finds the swings of a long clip. nil = analyse the whole clip (short clip, or no swing found).
    /// `swingIndex` picks one (nil or out of range = the last, which is the one just hit).
    static func selectSwing(asset: AVAsset, duration: Double, swingIndex: Int? = nil,
                            onProgress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> SwingSelection? {
        guard duration > splitMinimumSeconds else { return nil }
        let started = Date()
        let scout = SwingAnalyzer(detector: MediaPipePoseDetector(numPoses: betaNumPoses))
        let frames = try await scout.scout(asset: asset, framesPerSecond: scoutFramesPerSecond) { p in
            Task { @MainActor in onProgress(p.fraction) }
        }
        let size = try await presentedSize(asset)
        let windows = swingWindows(scoutFrames: frames, imageWidth: size.width, imageHeight: size.height,
                                   duration: duration)
        guard !windows.isEmpty else { return nil }
        let chosen = swingIndex.flatMap { windows.indices.contains($0) ? $0 : nil } ?? windows.count - 1
        return SwingSelection(windows: windows, chosen: chosen,
                              scoutMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// Splitter windows (frame indices of the first pass) as video times. Kept apart so tests can drive it.
    static func swingWindows(scoutFrames frames: [PoseFrame], imageWidth: Double, imageHeight: Double,
                             duration: Double) -> [ClosedRange<Double>] {
        guard frames.count >= 10 else { return [] }
        let fps = SwingSplitter.frameRate(frames)
        let swings = SwingSplitter().findSwings(frames: frames, imageWidth: imageWidth, imageHeight: imageHeight)
        return SwingSplitter.windows(swings, frameCount: frames.count, fps: fps, single: true).map { w in
            let start = frames[w.start].timestampSeconds
            let end = min(duration, frames[min(w.end, frames.count) - 1].timestampSeconds + 1 / fps)
            return start...max(start, end)
        }
    }

    static var recordStore: BetaRecordStore { BetaRecordStore(directory: LocalStore.shared.root) }

    static func analyse(videoURL: URL, library: SwingLibrary, swingIndex: Int? = nil,
                        onProgress: @escaping @MainActor (Double) -> Void) async throws -> BetaRecord {
        let started = Date()
        let duration = try await AVURLAsset(url: videoURL).load(.duration).seconds
        guard duration.isFinite, duration >= 0.1 else { throw AnalysisError.noFramesProduced }

        let swingID = UUID()
        var record = SwingRecord(id: swingID, title: BetaStrings(.system).dateText(Date()), videoFilename: "",
                                 clipStartSeconds: 0, clipEndSeconds: duration, handedness: .rightHanded,
                                 club: .iron, cameraView: .downTheLine,
                                 poseModelIdentifier: MediaPipePoseDetector.ModelVariant.heavy.rawValue)
        var storedFilename: String?
        var committed = false
        defer { if !committed { LocalStore.shared.discardPendingImport(id: swingID, filename: storedFilename) } }

        let storage = AnalysisImportStorage(root: LocalStore.shared.root)
        let filename = try await storage.importVideo(from: videoURL, swingID: swingID)
        storedFilename = filename
        record.videoFilename = filename
        let storedURL = LocalStore.shared.videosDirectory.appendingPathComponent(filename)
        let asset = AVURLAsset(url: storedURL)

        // Long clip: first find the swings (a third of the progress bar), then analyse one of them.
        let selection = try await selectSwing(asset: asset, duration: duration, swingIndex: swingIndex) { p in
            onProgress(p * 0.3)
        }
        try Task.checkCancellation()
        if let selection {
            record.clipStartSeconds = selection.windows[selection.chosen].lowerBound
            record.clipEndSeconds = selection.windows[selection.chosen].upperBound
        }
        let scouted = selection != nil || duration > splitMinimumSeconds
        let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(numPoses: betaNumPoses),
                                     phaseDetector: SwingNetPhaseDetector())
        let frames = try await analyzer.analyse(asset: asset, timeRange: selection?.range) { p in
            Task { @MainActor in onProgress(scouted ? 0.3 + 0.7 * p.fraction : p.fraction) }
        }
        try Task.checkCancellation()
        record.keyframes = await analyzer.keyframes
        record.phaseDetectionNote = await analyzer.phaseDetectionNote
        let cache = AnalysisCache(swingID: swingID, analysisVersion: record.analysisVersion,
                                  algorithmVersion: record.algorithmVersion,
                                  poseModelIdentifier: record.poseModelIdentifier, createdAt: Date(),
                                  frames: frames, smoothing: .realTime)
        try await storage.saveAnalysis(cache)
        try library.saveChecked(record)
        committed = true

        let size = try await presentedSize(asset)
        let evidence = pathEvidence(frames: frames, keyframes: record.keyframes,
                                    imageWidth: size.width, imageHeight: size.height)
        let info = try? await videoInfo(asset)
        let beta = BetaRecord(appVersion: BetaMode.appVersion, build: BetaMode.build, verdict: evidence.verdict,
                              refusal: evidence.refusal, swingNotFound: !evidence.isJudged && evidence.refusal == nil,
                              offset: evidence.offset, swingID: swingID, evidence: evidence,
                              video: info, analysisMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                              deviceModel: BetaMode.deviceModel,
                              swingsFound: scouted ? (selection?.windows.count ?? 0) : nil,
                              swingChosen: selection.map { $0.chosen + 1 })
        try recordStore.append(beta)
        return beta
    }

    static func presentedSize(_ asset: AVAsset) async throws -> (width: Double, height: Double) {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noFramesProduced }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let presented = size.applying(transform)
        return (abs(Double(presented.width)), abs(Double(presented.height)))
    }

    /// Duration, displayed size, frame rate and codec, for the test log.
    static func videoInfo(_ asset: AVAsset) async throws -> VideoInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noFramesProduced }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let fps = try await track.load(.nominalFrameRate)
        let formats = try await track.load(.formatDescriptions)
        let codec = formats.first.map { VideoInfo.codecName(fourCC: CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
        return VideoInfo(durationSeconds: duration, width: Int(abs(size.width).rounded()),
                         height: Int(abs(size.height).rounded()), frameRate: Double(fps), codec: codec)
    }

    /// Same call as the full report's path card, kept as one function so tests can drive it.
    static func pathEvidence(frames: [PoseFrame], keyframes: [Keyframe],
                             imageWidth: Double, imageHeight: Double) -> PathEvidence {
        guard !frames.isEmpty,
              let address = keyframes.keyframe(for: .address)?.timestampSeconds,
              let top = keyframes.keyframe(for: .top)?.timestampSeconds,
              let impact = keyframes.keyframe(for: .impact)?.timestampSeconds else {
            return .swingNotFound(imageWidth: imageWidth, imageHeight: imageHeight)
        }
        func index(_ t: Double) -> Int {
            frames.indices.min { abs(frames[$0].timestampSeconds - t) < abs(frames[$1].timestampSeconds - t) } ?? 0
        }
        let result = SwingPathAnalyzer().analyze(frames: frames, address: address, top: top, impact: impact,
                                                 imageWidth: imageWidth, imageHeight: imageHeight)
        return PathEvidence(result: result, top: index(top), impact: index(impact),
                            frameSeconds: frames.map(\.timestampSeconds),
                            imageWidth: imageWidth, imageHeight: imageHeight)
    }
}
