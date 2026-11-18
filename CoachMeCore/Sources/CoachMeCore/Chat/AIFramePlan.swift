import Foundation

/// Preserve the main positions and distribute 30 samples across their intervals.
/// Interpolated samples never claim to be detected or reviewed phases.
public struct AIFramePlan: Sendable {
    public static let maximumImageCount = 30
    public struct Sample: Sendable {
        public let timestamp: Double
        public let label: String
    }
    public let samples: [Sample]
    public init(keyframes: [Keyframe], start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start else { samples = []; return }
        var anchors: [Keyframe] = []
        for phase in SwingPhase.allCases {
            if let mark = keyframes.first(where: { $0.phase == phase && $0.timestampSeconds.isFinite && $0.timestampSeconds >= start && $0.timestampSeconds < end }) {
                anchors.append(mark)
            }
        }
        // Legacy six-position records have no takeaway. Keep this an estimate.
        if !anchors.contains(where: { $0.phase == .takeaway }),
           let a = anchors.first(where: { $0.phase == .address }),
           let b = anchors.first(where: { $0.phase == .midBackswing }), a.timestampSeconds < b.timestampSeconds {
            anchors.append(Keyframe(phase: .takeaway, timestampSeconds: (a.timestampSeconds + b.timestampSeconds) / 2,
                                    markedByCoach: false, note: "取样补位"))
        }
        anchors.sort {
            if $0.timestampSeconds == $1.timestampSeconds {
                return $0.markedByCoach && !$1.markedByCoach
            }
            return $0.timestampSeconds < $1.timestampSeconds
        }
        let last = max(start, end - min(0.05, (end-start)/2))
        if anchors.isEmpty {
            samples = (0..<Self.maximumImageCount).map {
                Sample(timestamp: start + (last-start)*Double($0)/Double(Self.maximumImageCount-1),
                       label: "选段取样，阶段未知")
            }
            return
        }
        var main: [Sample] = []
        for anchor in anchors where main.last?.timestamp != anchor.timestampSeconds {
            main.append(Sample(timestamp: anchor.timestampSeconds,
                label: anchor.markedByCoach ? anchor.phase.nameZH + "（已复核）" : "自动/补位取样，请按画面判断阶段，可能并非挥杆动作"))
        }
        // Partial records still cover the selected clip, without inventing phase labels.
        if main.count < SwingPhase.allCases.count {
            if let first = main.first, first.timestamp > start {
                main.insert(Sample(timestamp: start, label: "选段取样，阶段未知"), at: 0)
            }
            if let final = main.last, final.timestamp < last {
                main.append(Sample(timestamp: last, label: "选段取样，阶段未知"))
            }
        }
        guard main.count > 1 else { samples = main; return }
        // Balance samples by phase interval rather than duration, so a short
        // downswing receives detail even when the finish takes much longer.
        let intervalCount = main.count - 1
        let remaining = Self.maximumImageCount - main.count
        let perInterval = remaining / intervalCount
        let extraIntervals = remaining % intervalCount
        var result = [main[0]]
        for index in 0..<intervalCount {
            let left = main[index], right = main[index+1]
            let count = perInterval + (index < extraIntervals ? 1 : 0)
            for offset in 1...count {
                result.append(Sample(timestamp: left.timestamp + (right.timestamp-left.timestamp)*Double(offset)/Double(count+1),
                    label: "相邻主截图之间的过渡取样，不是独立识别阶段"))
            }
            result.append(right)
        }
        samples = result
    }
}
