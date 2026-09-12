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
    private var displayFrames: [PoseFrame] = []
    var playback: PlaybackController?
    var showSkeleton = true
    private(set) var findingPhases = false
    private(set) var phaseDetectionMessage: String?
    var chartMetric: MetricID = .elbowInteriorAngle
    private(set) var videoSize: CGSize = CGSize(width: 9, height: 16)

    init(swing: SwingRecord, cache: AnalysisCache?, videoURL: URL) {
        self.swing = swing
        self.cache = cache
        self.poseFrames = cache?.smoothedFrames() ?? []
        self.displayFrames = PoseDisplayCompleter(minVisibility: swing.qualityPolicy.minVisibility)
            .complete(self.poseFrames, keyframes: swing.keyframes)
        if cache != nil {
            timeline = MetricTimeline(poseFrames: poseFrames, record: swing)
        }
        let asset = AVURLAsset(url: videoURL)
        playback = PlaybackController(url: videoURL, duration: swing.durationSeconds, startTime: swing.clipStartSeconds)
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
        return poseFrames.nearest(to: time).flatMap { abs($0.timestampSeconds - time) <= 0.15 ? $0 : nil }
    }

    var currentDisplayPoseFrame: PoseFrame? {
        guard let time = playback?.currentTime else { return nil }
        return displayFrames.nearest(to: time).flatMap { abs($0.timestampSeconds - time) <= 0.15 ? $0 : nil }
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

    func findKeyframes(library: SwingLibrary, usePersonCrop: Bool = true) async {
        guard !findingPhases, swing.keyframes.isEmpty else { return }
        findingPhases = true
        phaseDetectionMessage = nil
        defer { findingPhases = false }
        do {
            let marks = try await SavedSwingPhaseAnalysis().run(url: library.videoURL(for: swing), start: swing.clipStartSeconds, end: swing.clipEndSeconds, frames: poseFrames, usePersonCrop: usePersonCrop)
            // Do not overwrite marks added while the background analysis ran.
            guard swing.keyframes.isEmpty else { return }
            if marks.isEmpty {
                phaseDetectionMessage = "未能识别出顺序一致的挥杆阶段，请手动标记这段视频。"
            } else {
                swing.keyframes = marks
                persist(library)
            }
        } catch is CancellationError {
            phaseDetectionMessage = "已取消关键帧识别。"
        } catch {
            phaseDetectionMessage = "阶段识别失败：\(error.localizedDescription)"
        }
    }

    func markKeyframe(_ phase: SwingPhase, library: SwingLibrary) {
        guard let time = playback?.currentTime else { return }
        let earlier = swing.keyframes.filter { $0.phase.order < phase.order }.map(\.timestampSeconds).max()
        let later = swing.keyframes.filter { $0.phase.order > phase.order }.map(\.timestampSeconds).min()
        guard earlier.map({ time > $0 }) ?? true, later.map({ time < $0 }) ?? true else {
            phaseDetectionMessage = "此时间与其他阶段顺序冲突，请先调整或清除相邻标记。"
            return
        }
        var keyframes = swing.keyframes
        keyframes.removeAll { $0.phase == phase }
        keyframes.append(Keyframe(phase: phase, timestampSeconds: time))
        swing.keyframes = keyframes.sorted { $0.phase.order < $1.phase.order }
        persist(library)
    }

    func confirmKeyframes(library: SwingLibrary) {
        let times = swing.keyframes.sorted { $0.phase.order < $1.phase.order }.map(\.timestampSeconds)
        guard times.count == SwingPhase.allCases.count, zip(times,times.dropFirst()).allSatisfy({ $0 < $1 }) else {
            phaseDetectionMessage = "请先补齐七个阶段，并检查时间顺序。"
            return
        }
        for i in swing.keyframes.indices where !swing.keyframes[i].markedByCoach {
            swing.keyframes[i].markedByCoach = true
            swing.keyframes[i].note += " · 用户已复核"
        }
        persist(library)
    }

    var reviewSummary: String {
        guard !poseFrames.isEmpty else { return "没有可用的姿态帧，请重新分析。" }
        let single = poseFrames.filter { $0.detectedPersonCount == 1 }.count
        let missing = poseFrames.filter { $0.detectedPersonCount == 0 }.count
        let unconfirmed = swing.keyframes.filter { !$0.markedByCoach }.count
        return "共 \(poseFrames.count) 帧，单人检出 \(Int(Double(single)/Double(poseFrames.count)*100))%，未检出 \(missing) 帧。关键帧 \(swing.keyframes.count)/7，\(unconfirmed) 个待复核。"
    }

    func clearKeyframe(_ phase: SwingPhase, library: SwingLibrary) {
        swing.keyframes.removeAll { $0.phase == phase }
        persist(library)
    }

    private func persist(_ library: SwingLibrary) {
        swing.analysisVersion += 1
        library.save(swing)
        displayFrames = PoseDisplayCompleter(minVisibility: swing.qualityPolicy.minVisibility)
            .complete(poseFrames, keyframes: swing.keyframes)
        // Address may have moved, which changes every rotation metric. Recompute
        // from the cached landmarks; no inference re-run.
        if let cache {
            timeline = MetricTimeline(poseFrames: poseFrames, record: swing)
        }
    }

    // MARK: - Analysis context for chat

    func buildContext(rules: [CoachRule]) -> SwingAnalysisContext {
        let confirmedKeyframes = swing.keyframes.filter { $0.markedByCoach }
        let byPhase = timeline?.metricsByPhase(confirmedKeyframes) ?? [:]
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

        var result = SwingAnalysisContext(
            swingID: swing.id,
            analysisVersion: swing.analysisVersion,
            handedness: swing.handedness,
            club: swing.club,
            cameraView: swing.cameraView,
            markedPhases: confirmedKeyframes.orderedPhases,
            selectedPhase: confirmedKeyframes.contains(where: { $0.phase == currentPhase }) ? currentPhase : nil,
            selectedTimestampSeconds: playback?.currentTime,
            readings: readings,
            quality: quality,
            comparison: nil)
        result.analysisDetails = analysisDetails()
        let applicableRules = rules.filter { $0.clubs.contains(swing.club) && $0.views.contains(swing.cameraView) }
        if let data = try? JSONEncoder().encode(applicableRules) {
            result.analysisDetails = (result.analysisDetails ?? "") + "\n适用教练规则（需按阶段匹配）：" + String(decoding: data, as: UTF8.self)
        }
        return result
    }

    private func analysisDetails() -> String {
        let frames = timeline?.frames ?? []
        let columns = MetricID.allCases.filter { $0 != .wristPathBodyReferenced }.flatMap { id in
            (MetricCatalog.isBilateral(id) ? [nil] : [BodySide.left, .right]).map { side in MetricKey(id, side) }
        }
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "NA" }
            return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        var lines = ["全程指标：所有分析帧，未抽样；NA=缺失或不可靠，绝非零。显示补全未参与。"]
        for (i,key) in columns.enumerated() {
            let d = MetricCatalog.definition(for: key.id)
            lines.append("c\(i)=\(d.nameZH)/\(key.side?.rawValue ?? "bilateral")/\(d.unit)/\(d.space.rawValue)；\(d.caveatZH)")
        }
        lines.append("全程标量统计（只计可用值；不是标准范围）：")
        for (i,key) in columns.enumerated() {
            let samples = frames.compactMap { frame -> (Double,Double)? in
                guard let value = frame.outcome(key.id,key.side).value, value.isFinite else { return nil }
                return (frame.timestampSeconds,value)
            }
            if let low = samples.min(by: { $0.1 < $1.1 }), let high = samples.max(by: { $0.1 < $1.1 }) {
                let mean = samples.reduce(0) { $0+$1.1 }/Double(samples.count)
                lines.append("c\(i): valid=\(samples.count)/\(frames.count), min=\(number(low.1))@\(number(low.0))s, max=\(number(high.1))@\(number(high.0))s, mean=\(number(mean))")
            } else { lines.append("c\(i): 无可用数据") }
        }
        lines.append("每行 timeSeconds,quality," + columns.indices.map { "c\($0)" }.joined(separator: ",") + ",leftWristBodyXYZ,rightWristBodyXYZ,leftWristImageXYZ,rightWristImageXYZ")
        for frame in frames {
            var row = [number(frame.timestampSeconds), frame.quality.blockingReason?.rawValue ?? "available"]
            row += columns.map { key in
                let outcome = frame.outcome(key.id,key.side)
                if case .unavailable(let reason) = outcome { return "NA:" + reason.rawValue }
                return number(outcome.value)
            }
            for table in [frame.wristBodyReferenced,frame.wristImagePath] {
                for side in [BodySide.left,.right] {
                    let p = table[side]
                    row += [number(p?.x),number(p?.y),number(p?.z)]
                }
            }
            lines.append(row.joined(separator: ","))
        }
        let confirmed = swing.keyframes.filter { $0.markedByCoach }
        let candidates = swing.keyframes.filter { !$0.markedByCoach }.map { number($0.timestampSeconds) }
        lines.append("未复核的自动取样时间（不赋予阶段含义）：" + candidates.joined(separator: ","))
        if !candidates.isEmpty { lines.append("准备姿势参考可能未复核，相对转角不能用于确定动作结论。请先独立看图，不能从数值猜阶段。") }
        if let data = try? JSONEncoder().encode(confirmed) {
            lines.append("关键帧来源与时间：" + String(decoding: data, as: UTF8.self))
        }
        if let frame = currentPoseFrame, let data = try? JSONEncoder().encode(frame) {
            lines.append("当前帧原始检测/平滑坐标（未显示补全）：" + String(decoding: data, as: UTF8.self))
        }
        lines.append("本次未传输视频、其他挥杆或全程逐关节原始坐标；逐帧指标已完整提供。")
        return lines.joined(separator: "\n")
    }
}
