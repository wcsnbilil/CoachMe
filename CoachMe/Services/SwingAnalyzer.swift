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
    /// SwingNet's per-frame probabilities from the main pass (empty if it did not run).
    var phaseProbabilities: [[Double]] { phaseDetector?.probabilityLog ?? [] }

    init(detector: PoseDetecting, phaseDetector: SwingNetPhaseDetector? = nil) {
        self.detector = detector
        self.phaseDetector = phaseDetector
    }

    /// Set when `analyse` stopped at `earlyStop` (the retake check refused); the frames returned end there.
    private(set) var stoppedEarly = false

    /// - knownKeyframes: phases from `phases(asset:timeRange:)` on the same range. SwingNet is then not run
    ///   again; decoding stays at SwingNet's size so the poses are exactly those of a combined pass.
    /// - earlyStop: once `at` frames have poses, `check` is called with them; true stops the pass there.
    func analyse(asset: AVAsset,
                 timeRange: CMTimeRange?,
                 knownKeyframes: [Keyframe]? = nil,
                 earlyStop: (at: Int, check: @Sendable ([PoseFrame]) -> Bool)? = nil,
                 onProgress: @Sendable @escaping (AnalysisProgress) -> Void) async throws -> [PoseFrame] {

        onProgress(AnalysisProgress(framesProcessed: 0, estimatedTotalFrames: 0, currentTimestampSeconds: 0, stage: "正在加载分析模型…"))
        try detector.prepare()
        detector.reset()
        keyframes = knownKeyframes ?? []
        phaseDetectionNote = nil
        stoppedEarly = false
        var phaseActive = phaseDetector != nil && knownKeyframes == nil
        if phaseActive {
            do { try phaseDetector?.prepare() }
            catch {
                phaseActive = false
                phaseDetectionNote = "姿态分析已保留；动作阶段模型无法载入，可稍后重试或手动标记。"
            }
        }

        let reader = VideoAssetReader(asset: asset)
        do {
            // Keep source detail for SwingNet; a second resize from 720 pixels
            // changed event maxima in the verified 4K regression clip.
            try await reader.start(timeRange: timeRange, maxDimension: phaseDetector == nil && knownKeyframes == nil ? 720 : 4096)
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
            if let earlyStop, frames.count == earlyStop.at, earlyStop.check(frames) {
                stoppedEarly = true
                return frames
            }
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

    /// SwingNet alone over the range (no pose), decoded exactly as `analyse` decodes it, so the phases
    /// equal those of the combined pass. Returns them with every frame's timestamp, in decode order,
    /// so a phase time maps to the frame index `analyse` will reach. Empty keyframes = none found
    /// (`analyse` then runs SwingNet itself, with its person-crop retry).
    func phases(asset: AVAsset, timeRange: CMTimeRange?,
                onProgress: @Sendable @escaping (AnalysisProgress) -> Void) async throws -> (keyframes: [Keyframe], timestamps: [Double]) {
        guard let phaseDetector else { return ([], []) }
        do { try phaseDetector.prepare() } catch { return ([], []) }
        let reader = VideoAssetReader(asset: asset)
        do { try await reader.start(timeRange: timeRange, maxDimension: 4096) }
        catch let error as VideoReaderError { throw AnalysisError.video(error) }
        defer { reader.cancel() }
        let estimated = await Self.estimateFrameCount(asset: asset, timeRange: timeRange, fallbackFPS: reader.nominalFrameRate)
        var stamps: [Double] = []
        var lastProgress = Date.distantPast
        while true {
            if Task.isCancelled { throw AnalysisError.cancelled }
            let decoded: DecodedFrame?
            do { decoded = try reader.nextFrame() }
            catch let error as VideoReaderError { throw AnalysisError.video(error) }
            guard let decoded else { break }
            do {
                try autoreleasepool { try phaseDetector.append(pixelBuffer: decoded.pixelBuffer, timestamp: decoded.timestampSeconds) }
            } catch is CancellationError { throw CancellationError() }
            catch { return ([], stamps) }
            stamps.append(decoded.timestampSeconds)
            if Date().timeIntervalSince(lastProgress) >= 0.1 {
                lastProgress = Date()
                onProgress(AnalysisProgress(framesProcessed: stamps.count, estimatedTotalFrames: estimated,
                                            currentTimestampSeconds: decoded.timestampSeconds, stage: "识别动作阶段"))
            }
        }
        let found = (try? phaseDetector.finish()) ?? []
        return (found, stamps)
    }

    /// Poses on about `count` frames spread evenly over the clip (the retake check right after import).
    /// Small frames; the whole clip is decoded but only the picked frames go through the detector.
    func sample(asset: AVAsset, count: Int) async throws -> [PoseFrame] {
        try detector.prepare()
        detector.reset()
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let reader = VideoAssetReader(asset: asset)
        do { try await reader.start(timeRange: nil, maxDimension: 720) }
        catch let error as VideoReaderError { throw AnalysisError.video(error) }
        defer { reader.cancel() }
        let targets = (0..<count).map { count > 1 ? duration * Double($0) / Double(count - 1) : 0 }
        var next = 0
        var frames: [PoseFrame] = []
        var last: DecodedFrame?
        while next < targets.count {
            if Task.isCancelled { throw AnalysisError.cancelled }
            let decoded: DecodedFrame?
            do { decoded = try reader.nextFrame() }
            catch let error as VideoReaderError { throw AnalysisError.video(error) }
            guard let frame = decoded ?? last else { break }
            if decoded != nil { last = frame }
            // the last target is the clip's end: take the final frame when decoding runs out
            guard frame.timestampSeconds >= targets[next] - 0.001 || decoded == nil else { continue }
            let result: PoseDetectionResult
            do {
                result = try autoreleasepool {
                    try detector.detect(pixelBuffer: frame.pixelBuffer,
                                        timestampMilliseconds: Int((frame.timestampSeconds * 1000).rounded()))
                }
            } catch let error as PoseDetectorError { throw AnalysisError.detector(error) }
            frames.append(PoseFrame(timestampSeconds: frame.timestampSeconds, imageLandmarks: result.imageLandmarks,
                                    worldLandmarks: result.worldLandmarks, detectedPersonCount: result.personCount))
            next += 1
            while next < targets.count, targets[next] <= frame.timestampSeconds { next += 1 }
            if decoded == nil { break }
        }
        return frames
    }

    /// Quick first pass over a long clip: pose only (no SwingNet), small frames, about
    /// `framesPerSecond` of them, enough for SwingSplitter to find where each swing is.
    /// Timestamps are the video's own, so a window found here can be passed to `analyse`.
    func scout(asset: AVAsset, framesPerSecond: Double = 15,
               onProgress: @Sendable @escaping (AnalysisProgress) -> Void) async throws -> [PoseFrame] {
        try detector.prepare()
        detector.reset()
        let reader = VideoAssetReader(asset: asset)
        do { try await reader.start(timeRange: nil, maxDimension: 720) }
        catch let error as VideoReaderError { throw AnalysisError.video(error) }
        defer { reader.cancel() }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let estimated = max(1, Int(duration * framesPerSecond))
        // a few ms of slack: 30 fps timestamps are not exact multiples of 1/30
        let step = 1 / framesPerSecond - 0.004
        var frames: [PoseFrame] = []
        var lastKept = -Double.infinity
        var lastProgress = Date.distantPast
        while true {
            if Task.isCancelled { throw AnalysisError.cancelled }
            let decoded: DecodedFrame?
            do { decoded = try reader.nextFrame() }
            catch let error as VideoReaderError { throw AnalysisError.video(error) }
            guard let decoded else { break }
            guard decoded.timestampSeconds - lastKept >= step else { continue }
            lastKept = decoded.timestampSeconds
            let result: PoseDetectionResult
            do {
                result = try autoreleasepool {
                    try detector.detect(pixelBuffer: decoded.pixelBuffer,
                                        timestampMilliseconds: Int((decoded.timestampSeconds * 1000).rounded()))
                }
            } catch let error as PoseDetectorError { throw AnalysisError.detector(error) }
            frames.append(PoseFrame(timestampSeconds: decoded.timestampSeconds,
                                    imageLandmarks: result.imageLandmarks,
                                    worldLandmarks: result.worldLandmarks,
                                    detectedPersonCount: result.personCount))
            if Date().timeIntervalSince(lastProgress) >= 0.1 {
                lastProgress = Date()
                onProgress(AnalysisProgress(framesProcessed: frames.count, estimatedTotalFrames: estimated,
                                            currentTimestampSeconds: decoded.timestampSeconds, stage: "正在找出每一次挥杆…"))
            }
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
