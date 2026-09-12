import Foundation

/// Seven main positions with one temporal midpoint between each pair.
/// Interpolated samples never claim to be detected or reviewed phases.
public struct AIFramePlan: Sendable {
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
        anchors.sort { $0.timestampSeconds < $1.timestampSeconds }
        if anchors.isEmpty {
            let last = max(start, end - min(0.05, (end-start)/2))
            samples = (0..<13).map { Sample(timestamp: start + (last-start)*Double($0)/12, label: "选段取样，阶段未知") }
            return
        }
        var result: [Sample] = []
        for (index, anchor) in anchors.enumerated() {
            if index > 0 {
                let previous = anchors[index-1]
                guard anchor.timestampSeconds > previous.timestampSeconds else { continue }
                result.append(Sample(timestamp: (previous.timestampSeconds + anchor.timestampSeconds)/2,
                    label: "相邻主截图之间的过渡取样，不是独立识别阶段"))
            }
            result.append(Sample(timestamp: anchor.timestampSeconds,
                label: anchor.markedByCoach ? anchor.phase.nameZH + "（已复核）" : "自动/补位取样，请按画面判断阶段，可能并非挥杆动作"))
        }
        samples = result
    }
}
