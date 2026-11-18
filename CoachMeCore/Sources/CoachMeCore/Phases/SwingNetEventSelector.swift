import Foundation

/// Reduces the nine-class per-frame probabilities used by GolfDB's SwingNet.
/// Scores are model outputs, not calibrated correctness probabilities.
public struct SwingNetEventSelector {
    private var scores = Array(repeating: -Double.infinity, count: 8)
    private var times = Array<Double?>(repeating: nil, count: 8)
    private var boundaries: [(time: Double, address: Double, finish: Double, takeaway: Double)] = []
    private var lastTimestamp: Double?
    public init() {}

    public mutating func append(probabilities: [Double], timestamp: Double) throws {
        guard probabilities.count == 9, timestamp.isFinite,
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              lastTimestamp.map({ timestamp > $0 }) ?? true else {
            throw InputError.invalidPrediction
        }
        lastTimestamp = timestamp
        boundaries.append((timestamp, probabilities[0], probabilities[7], probabilities[1]))
        for event in 0..<8 where probabilities[event] > scores[event] {
            scores[event] = probabilities[event]
            times[event] = timestamp
        }
    }

    /// Preserve the independently predicted interior phases. Only repair boundary
    /// events, which can otherwise latch onto a later setup or an earlier finish.
    /// Contradictory interior phases still require manual review.
    public func keyframes() -> [Keyframe] {
        let mapping: [(Int, SwingPhase)] = [(0, .address), (2, .midBackswing),
                                           (3, .top), (4, .midDownswing),
                                           (5, .impact), (7, .finish)]
        var times = self.times
        var scores = self.scores
        let interior = [2, 3, 4, 5].compactMap { times[$0] }
        guard interior.count == 4,
              zip(interior, interior.dropFirst()).allSatisfy({ $0 < $1 }) else { return [] }
        if times[0].map({ $0 >= interior[0] }) ?? true {
            guard let candidate = boundaries.filter({ $0.time < interior[0] && $0.address > 0 })
                .max(by: { $0.address < $1.address }) else { return [] }
            times[0] = candidate.time
            scores[0] = candidate.address
        }
        if times[7].map({ $0 <= interior[3] }) ?? true {
            guard let candidate = boundaries.filter({ $0.time > interior[3] && $0.finish > 0 })
                .max(by: { $0.finish < $1.finish }) else { return [] }
            times[7] = candidate.time
            scores[7] = candidate.finish
        }
        let selected = mapping.compactMap { times[$0.0] }
        guard selected.count == mapping.count,
              zip(selected, selected.dropFirst()).allSatisfy({ $0 < $1 }) else { return [] }
        var extendedMapping = mapping
        if let address = times[0], let mid = times[2],
           let candidate = boundaries.filter({ $0.time > address && $0.time < mid && $0.takeaway > 0 })
            .max(by: { $0.takeaway < $1.takeaway }) {
            times[1] = candidate.time
            scores[1] = candidate.takeaway
            extendedMapping.insert((1, .takeaway), at: 1)
        }
        return extendedMapping.map { event, phase in
            Keyframe(phase: phase, timestampSeconds: times[event]!, markedByCoach: false,
                     note: String(format: "SwingNet 1800 · 自动标记 · 模型分数 %.4f", scores[event]))
        }
    }

    public enum InputError: Error { case invalidPrediction }
}
