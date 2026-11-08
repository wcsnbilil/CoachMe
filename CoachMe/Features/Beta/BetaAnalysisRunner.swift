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

    static var recordStore: BetaRecordStore { BetaRecordStore(directory: LocalStore.shared.root) }

    static func analyse(videoURL: URL, library: SwingLibrary,
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

        let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(numPoses: betaNumPoses),
                                     phaseDetector: SwingNetPhaseDetector())
        let frames = try await analyzer.analyse(asset: asset, timeRange: nil) { p in
            Task { @MainActor in onProgress(p.fraction) }
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
                              deviceModel: BetaMode.deviceModel)
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
