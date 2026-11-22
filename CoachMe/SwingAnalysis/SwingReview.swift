import AVFoundation
import Foundation
import Model
import PoseDetection
import Diagnosis

/// What the report, comparison and workbench screens ask about a saved swing.
/// Screens call these and display the result types; they do not build the engines themselves.
enum SwingReview {
    static func timeline(for swing: SwingRecord, poseFrames: [PoseFrame]) -> MetricTimeline {
        MetricTimeline(poseFrames: poseFrames, record: swing)
    }

    /// Uses the cache's smoothed landmarks, the same ones the workbench shows.
    static func timeline(for swing: SwingRecord, cache: AnalysisCache) -> MetricTimeline {
        timeline(for: swing, poseFrames: cache.smoothedFrames())
    }

    static func findings(for swing: SwingRecord,
                         metricsByPhase: [SwingPhase: FrameMetrics],
                         rules: [CoachRule]) -> [RuleFinding] {
        RuleEngine().findings(rules: rules, metricsByPhase: metricsByPhase,
                              handedness: swing.handedness, club: swing.club, view: swing.cameraView)
    }

    /// Nil when the swing is not down-the-line, lacks address/top/impact, or the video size cannot be read.
    static func downswingPath(for swing: SwingRecord, cache: AnalysisCache, videoURL: URL) async -> SwingPathAnalyzer.Result? {
        guard swing.cameraView == .downTheLine,
              let address = swing.keyframes.keyframe(for: .address)?.timestampSeconds,
              let top = swing.keyframes.keyframe(for: .top)?.timestampSeconds,
              let impact = swing.keyframes.keyframe(for: .impact)?.timestampSeconds else { return nil }
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let presented = size.applying(transform)
        // Raw landmarks, as in tools/faults/path_fault.py: the analyzer does its own smoothing.
        return SwingPathAnalyzer().analyze(frames: cache.frames, address: address, top: top, impact: impact,
                                           imageWidth: abs(presented.width), imageHeight: abs(presented.height))
    }

    /// Re-detects the phases of a saved swing from its video; pose landmarks are reused, not recomputed.
    static func detectPhases(for swing: SwingRecord, videoURL: URL, poseFrames: [PoseFrame],
                             usePersonCrop: Bool) async throws -> [Keyframe] {
        try await SavedSwingPhaseAnalysis().run(url: videoURL, start: swing.clipStartSeconds, end: swing.clipEndSeconds,
                                                frames: poseFrames, usePersonCrop: usePersonCrop)
    }
}
