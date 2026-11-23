import AVFoundation
import Foundation
import Model
import PoseDetection

/// Analyses a newly imported clip: pose landmarks for every frame plus the detected phases.
enum SwingImport {
    struct Analysis {
        let frames: [PoseFrame]
        let keyframes: [Keyframe]
        let phaseDetectionNote: String?
    }

    /// Recorded on the swing so a report always says which pose model produced it.
    static let poseModelIdentifier = MediaPipePoseDetector.ModelVariant.heavy.rawValue

    static func analyse(videoURL: URL, start: Double, end: Double,
                        onProgress: @Sendable @escaping (AnalysisProgress) -> Void) async throws -> Analysis {
        let asset = AVURLAsset(url: videoURL)
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))
        let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(),
                                     phaseDetector: SwingNetPhaseDetector())
        let frames = try await analyzer.analyse(asset: asset, timeRange: range, onProgress: onProgress)
        try Task.checkCancellation()
        return Analysis(frames: frames,
                        keyframes: await analyzer.keyframes,
                        phaseDetectionNote: await analyzer.phaseDetectionNote)
    }
}
