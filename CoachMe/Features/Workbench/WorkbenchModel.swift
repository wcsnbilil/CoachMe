import SwiftUI
import AVFoundation
import CoachMeCore

/// Holds the analysis for one swing and keeps every panel on the same clock.
///
/// Metrics are recomputed from the cached landmarks whenever a keyframe changes.
/// Pose inference is never re-run for that — the cache is the source of truth.
@MainActor
@Observable
final class WorkbenchModel {
    private(set) var swing: SwingRecord
    let cache: AnalysisCache?
    private(set) var timeline: MetricTimeline?
    /// Smoothed once at load. Everything on screen — skeleton, readouts, chart —
    /// reads from this, so they can never disagree about what a frame contained.
    private let poseFrames: [PoseFrame]
    var playback: PlaybackController?
    var showSkeleton = true
    var chartMetric: MetricID = .elbowInteriorAngle
    private(set) var videoSize: CGSize = CGSize(width: 9, height: 16)

    init(swing: SwingRecord, cache: AnalysisCache?, videoURL: URL) {
        self.swing = swing
        self.cache = cache
        self.poseFrames = cache?.smoothedFrames() ?? []
        if cache != nil {
            timeline = MetricTimeline(poseFrames: poseFrames, record: swing)
        }
        let asset = AVURLAsset(url: videoURL)
        playback = PlaybackController(url: videoURL, duration: swing.durationSeconds)
        Task { await loadVideoSize(asset) }
    }

    private func loadVideoSize(_ asset: AVURLAsset) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return }
        // Apply the transform so a portrait recording reports portrait dimensions.
        let presented = size.applying(transform)
        videoSize = CGSize(width: abs(presented.width), height: abs(presented.height))
    }

    var timestamps: [Double] { poseFrames.map(\.timestampSeconds) }

    var currentPoseFrame: PoseFrame? {
        guard let cache, let time = playback?.currentTime else { return nil }
        return poseFrames.nearest(to: time)
    }

    var currentMetrics: FrameMetrics? {
        guard let time = playback?.currentTime else { return nil }
        return timeline?.metrics(at: time)
    }

    /// The phase whose keyframe is closest to the playhead, within a small window.
    var currentPhase: SwingPhase? {
        guard let time = playback?.currentTime else { return nil }
        return swing.keyframes
            .filter { abs($0.timestampSeconds - time) < 0.08 }
            .min { abs($0.timestampSeconds - time) < abs($1.timestampSeconds - time) }?
            .phase
    }

    // MARK: - Keyframes

    func markKeyframe(_ phase: SwingPhase, library: SwingLibrary) {
        guard let time = playback?.currentTime else { return }
        var keyframes = swing.keyframes
        keyframes.removeAll { $0.phase == phase }
        keyframes.append(Keyframe(phase: phase, timestampSeconds: time))
        swing.keyframes = keyframes.sorted { $0.phase.order < $1.phase.order }
        persist(library)
    }

    func clearKeyframe(_ phase: SwingPhase, library: SwingLibrary) {
        swing.keyframes.removeAll { $0.phase == phase }
        persist(library)
    }

    private func persist(_ library: SwingLibrary) {
        library.save(swing)
        // Address may have moved, which changes every rotation metric. Recompute
        // from the cached landmarks; no inference re-run.
        if let cache {
            timeline = MetricTimeline(poseFrames: poseFrames, record: swing)
        }
    }

    // MARK: - Analysis context for chat

    func buildContext(rules: [CoachRule]) -> SwingAnalysisContext {
        let byPhase = timeline?.metricsByPhase(swing.keyframes) ?? [:]
        var readings: [SwingAnalysisContext.MetricReading] = []

        for (phase, metrics) in byPhase.sorted(by: { $0.key.order < $1.key.order }) {
            for id in MetricID.allCases where id != .wristPathBodyReferenced {
                let definition = MetricCatalog.definition(for: id)
                let sides: [BodySide?] = MetricCatalog.isBilateral(id) ? [nil] : [.left, .right]
                for side in sides {
                    let outcome = metrics.outcome(id, side)
                    // A range is attached only when the coach actually authored one
                    // for this metric, phase and view. Otherwise it stays nil.
                    let rule = rules.first {
                        $0.metricID == id && $0.phases.contains(phase)
                            && $0.views.contains(swing.cameraView)
                            && $0.clubs.contains(swing.club)
                            && $0.side.resolve(handedness: swing.handedness) == side
                    }
                    readings.append(.init(
                        metricID: id,
                        nameZH: definition.nameZH,
                        side: side,
                        phase: phase,
                        timestampSeconds: metrics.timestampSeconds,
                        value: outcome.value,
                        unit: definition.unit,
                        unavailableReason: {
                            if case .unavailable(let r) = outcome { return r }
                            return nil
                        }(),
                        space: definition.space,
                        definitionFormula: definition.formula,
                        definitionHash: definition.definitionHash,
                        caveatZH: definition.caveatZH,
                        coachRange: rule.map { r in
                            .init(lowerBound: r.lowerBound, upperBound: r.upperBound, unit: r.unit,
                                  sourceNote: r.sourceNote, coachNote: r.coachNote,
                                  outOfRangeExplanation: r.outOfRangeExplanation,
                                  drillSuggestion: r.drillSuggestion,
                                  appliesToPhases: r.phases.sorted { $0.order < $1.order },
                                  appliesToViews: Array(r.views))
                        }
                    ))
                }
            }
        }

        let frames = timeline?.frames ?? []
        let quality = SwingAnalysisContext.QualitySummary(
            framesAnalysed: frames.count,
            framesWithNoPerson: frames.filter { $0.quality.blockingReason == .noPersonDetected }.count,
            framesWithMultiplePeople: frames.filter { $0.quality.blockingReason == .multiplePeople }.count,
            metricsUnavailable: readings.filter { $0.value == nil }
                .map { "\($0.nameZH)@\($0.phase.nameZH)" },
            statedLimitationsZH: SwingAnalysisContext.standingLimitationsZH)

        return SwingAnalysisContext(
            swingID: swing.id,
            analysisVersion: swing.analysisVersion,
            handedness: swing.handedness,
            club: swing.club,
            cameraView: swing.cameraView,
            markedPhases: swing.keyframes.orderedPhases,
            selectedPhase: currentPhase,
            selectedTimestampSeconds: playback?.currentTime,
            readings: readings,
            quality: quality,
            comparison: nil)
    }
}
