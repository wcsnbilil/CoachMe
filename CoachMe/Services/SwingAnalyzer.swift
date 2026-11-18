import Foundation
import AVFoundation
import CoachMeCore

/// Progress reported while an analysis runs.
struct AnalysisProgress: Equatable {
    var framesProcessed: Int
    var estimatedTotalFrames: Int
    var currentTimestampSeconds: Double

    var stage: String? = nil

    var fraction: Double {
        guard estimatedTotalFrames > 0 else { return 0 }
        return min(1, Double(framesProcessed) / Double(estimatedTotalFrames))
    }
}

enum AnalysisError: LocalizedError {
    case cancelled
    case detector(PoseDetectorError)
    case video(VideoReaderError)
    case noFramesProduced

    var errorDescription: String? {
        switch self {
        case .cancelled:            return "已取消分析。"
        case .detector(let e):      return e.errorDescription
        case .video(let e):         return e.errorDescription
        case .noFramesProduced:     return "这段视频没有解出可用的画面，请换一段试试。"
        }
    }
}

/// Runs decode → pose detection → per-frame landmark capture off the main actor.
///
/// Metric computation is deliberately NOT done here: metrics depend on the
/// address keyframe, which is generated automatically or placed by the coach. Landmarks are
/// cached once; metrics are recomputed cheaply from the cache whenever keyframes
/// or the handedness change, so re-marking a keyframe never re-runs inference.
actor SwingAnalyzer {

    private let detector: PoseDetecting
    private let phaseDetector: SwingNetPhaseDetector?
    private(set) var keyframes: [Keyframe] = []
    private(set) var phaseDetectionNote: String?

    init(detector: PoseDetecting, phaseDetector: SwingNetPhaseDetector? = nil) {
        self.detector = detector
        self.phaseDetector = phaseDetector
    }

    func analyse(asset: AVAsset,
                 timeRange: CMTimeRange?,
                 onProgress: @Sendable @escaping (AnalysisProgress) -> Void) async throws -> [PoseFrame] {

        onProgress(AnalysisProgress(framesProcessed: 0, estimatedTotalFrames: 0, currentTimestampSeconds: 0, stage: "正在加载分析模型…"))
        try detector.prepare()
        detector.reset()
        keyframes = []
        phaseDetectionNote = nil
        var phaseActive = phaseDetector != nil
        do { try phaseDetector?.prepare() }
        catch {
            phaseActive = false
            phaseDetectionNote = "姿态分析已保留；动作阶段模型无法载入，可稍后重试或手动标记。"
        }

        let reader = VideoAssetReader(asset: asset)
        do {
            // Keep source detail for SwingNet; a second resize from 720 pixels
            // changed event maxima in the verified 4K regression clip.
            try await reader.start(timeRange: timeRange, maxDimension: phaseDetector == nil ? 720 : 4096)
        } catch let error as VideoReaderError {
            throw AnalysisError.video(error)
        }
        defer { reader.cancel() }

        let estimatedTotal = await Self.estimateFrameCount(asset: asset,
                                                           timeRange: timeRange,
                                                           fallbackFPS: reader.nominalFrameRate)

        var frames: [PoseFrame] = []
        frames.reserveCapacity(max(estimatedTotal, 16))
        var processed = 0
        var lastProgress = Date.distantPast

        while true {
            // Cooperative cancellation: checked every frame so cancelling is
            // responsive and the reader is torn down by `defer`.
            if Task.isCancelled { throw AnalysisError.cancelled }

            let decoded: DecodedFrame?
            do {
                decoded = try reader.nextFrame()
            } catch let error as VideoReaderError {
                throw AnalysisError.video(error)
            }
            guard let decoded else { break }

            let milliseconds = Int((decoded.timestampSeconds * 1000).rounded())
            let result: PoseDetectionResult
            do {
                result = try autoreleasepool {
                    try detector.detect(pixelBuffer: decoded.pixelBuffer,
                                        timestampMilliseconds: milliseconds)
                }
            } catch let error as PoseDetectorError {
                throw AnalysisError.detector(error)
            }

            frames.append(PoseFrame(timestampSeconds: decoded.timestampSeconds,
                                    imageLandmarks: result.imageLandmarks,
                                    worldLandmarks: result.worldLandmarks,
                                    detectedPersonCount: result.personCount))

            if phaseActive {
                do {
                    try autoreleasepool {
                        try phaseDetector?.append(pixelBuffer: decoded.pixelBuffer, timestamp: decoded.timestampSeconds)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    phaseActive = false
                    phaseDetectionNote = "姿态分析已保留；阶段识别中断，可稍后重试或手动标记。"
                }
            }

            processed += 1
            if Date().timeIntervalSince(lastProgress) >= 0.1 || processed == estimatedTotal {
                lastProgress = Date()
                onProgress(AnalysisProgress(framesProcessed: processed,
                                            estimatedTotalFrames: estimatedTotal,
                                            currentTimestampSeconds: decoded.timestampSeconds,
                                            stage: "识别骨骼与动作阶段"))
            }
        }

        guard !frames.isEmpty else { throw AnalysisError.noFramesProduced }
        if phaseActive {
            onProgress(AnalysisProgress(framesProcessed: 0, estimatedTotalFrames: 0, currentTimestampSeconds: frames.last?.timestampSeconds ?? 0, stage: "正在整理关键帧…"))
            do {
                keyframes = try phaseDetector?.finish() ?? []
                if keyframes.isEmpty { phaseDetectionNote = "未找到顺序一致的挥杆阶段。请只保留一次完整挥杆，或手动标记。" }
            } catch is CancellationError { throw CancellationError() }
            catch { phaseDetectionNote = "阶段识别失败，姿态分析已保留。" }
        }
        if keyframes.isEmpty, phaseDetector != nil, PersonCrop.estimate(from: frames) != nil,
           let urlAsset = asset as? AVURLAsset {
            try Task.checkCancellation()
            onProgress(AnalysisProgress(framesProcessed: processed, estimatedTotalFrames: processed,
                                        currentTimestampSeconds: frames.last?.timestampSeconds ?? 0,
                                        stage: "优化动作阶段（人物增强）"))
            do {
                keyframes = try await SavedSwingPhaseAnalysis().run(url: urlAsset.url,
                    start: timeRange?.start.seconds ?? 0, end: timeRange?.end.seconds,
                    frames: frames, usePersonCrop: true, onProgress: onProgress)
                phaseDetectionNote = keyframes.isEmpty
                    ? "人物增强仍未找到一致阶段。请重新选取一次挥杆，或手动标记。"
                    : "已使用人物增强生成关键帧候选，请逐帧复核。"
            } catch is CancellationError { throw CancellationError() }
            catch { phaseDetectionNote = "人物增强失败，姿态分析已保留；可手动标记。" }
        }
        return frames
    }

    private static func estimateFrameCount(asset: AVAsset,
                                           timeRange: CMTimeRange?,
                                           fallbackFPS: Float) async -> Int {
        let duration: Double
        if let timeRange {
            duration = timeRange.duration.seconds
        } else {
            duration = (try? await asset.load(.duration).seconds) ?? 0
        }
        let fps = fallbackFPS > 0 ? Double(fallbackFPS) : 30
        return max(1, Int(duration * fps))
    }
}

/// Turns cached landmarks into metrics. Pure and cheap — safe to call on every
/// keyframe edit.
struct MetricTimeline {
    let frames: [FrameMetrics]

    init(poseFrames: [PoseFrame], record: SwingRecord) {
        let calculator = SwingMetricsCalculator(handedness: record.handedness,
                                                cameraView: record.cameraView,
                                                policy: record.qualityPolicy)

        // The address keyframe supplies the zero reference for every rotation.
        // Without it those metrics report `.addressReferenceMissing` rather than
        // guessing a reference pose.
        let address: AddressReference? = {
            guard let keyframe = record.addressKeyframe,
                  let frame = poseFrames.nearest(to: keyframe.timestampSeconds) else { return nil }
            return AddressReference(frame: frame, space: .worldEstimate3D)
        }()

        frames = poseFrames.map { calculator.metrics(for: $0, address: address) }
    }

    func metrics(at seconds: Double) -> FrameMetrics? {
        frames.nearest(to: seconds, key: \.timestampSeconds)
    }

    /// Values for one metric over time, with gaps preserved.
    ///
    /// Unavailable samples become `nil` so the chart can break the line. They are
    /// never interpolated across, which would draw motion that was not measured.
    func series(_ id: MetricID, side: BodySide?) -> [(t: Double, value: Double?)] {
        frames.map { ($0.timestampSeconds, $0.outcome(id, side).value) }
    }

    func metricsByPhase(_ keyframes: [Keyframe]) -> [SwingPhase: FrameMetrics] {
        var out: [SwingPhase: FrameMetrics] = [:]
        for keyframe in keyframes {
            if let m = metrics(at: keyframe.timestampSeconds) { out[keyframe.phase] = m }
        }
        return out
    }
}

extension Array {
    /// Nearest element by a time key. Frames are in ascending time order, so a
    /// linear scan is fine at swing lengths (a few hundred frames).
    func nearest(to seconds: Double, key: (Element) -> Double) -> Element? {
        self.min { abs(key($0) - seconds) < abs(key($1) - seconds) }
    }

    func nearest(to seconds: Double, key path: KeyPath<Element, Double>) -> Element? {
        nearest(to: seconds) { $0[keyPath: path] }
    }
}

extension Array where Element == PoseFrame {
    func nearest(to seconds: Double) -> PoseFrame? {
        nearest(to: seconds, key: \.timestampSeconds)
    }
}
