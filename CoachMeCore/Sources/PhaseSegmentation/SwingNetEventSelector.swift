import Foundation
import Model

/// Reduces the nine-class per-frame probabilities used by GolfDB's SwingNet.
/// Scores are model outputs, not calibrated correctness probabilities.
///
/// The eight GolfDB events are picked together in strictly increasing frames, maximising the product of their
/// probabilities. A video whose eight picks have a low geometric mean is not treated as one complete swing.
/// Same algorithm as tools/benchmark/app_selector.py; products and comparisons only, so both pick the same frames.
public struct SwingNetEventSelector {
    /// The phase each GolfDB event is shown as, in event order; mid-follow-through is ordered but not shown.
    private static let shownAs: [SwingPhase?] = [.address, .takeaway, .midBackswing, .top, .midDownswing, .impact,
                                                 nil, .finish]
    private static let events = shownAs.count
    private var rows: [[Double]] = []
    private var timestamps: [Double] = []
    public init() {}

    public mutating func append(probabilities: [Double], timestamp: Double) throws {
        guard probabilities.count == 9, timestamp.isFinite,
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              timestamps.last.map({ timestamp > $0 }) ?? true else {
            throw InputError.invalidPrediction
        }
        timestamps.append(timestamp)
        rows.append(Array(probabilities.prefix(Self.events)))
    }

    public func keyframes() -> [Keyframe] {
        guard let (frames, product) = Self.ordered(rows),
              log(product) / Double(Self.events) >= SwingPhasesThresholds.minMeanLogProbability else { return [] }
        return Self.shownAs.enumerated().compactMap { event, shown in
            shown.map { phase in
                Keyframe(phase: phase, timestampSeconds: timestamps[frames[event]], markedByCoach: false,
                         note: String(format: "SwingNet 1800 · 自动标记 · 模型分数 %.4f", rows[frames[event]][event]))
            }
        }
    }

    /// Frames f0 < f1 < ... < f7 maximising the product of rows[f_e][e]; the earliest frame wins ties.
    static func ordered(_ raw: [[Double]]) -> (frames: [Int], product: Double)? {
        guard raw.count >= events else { return nil }
        let rows = raw.map { $0.map { max($0, SwingPhasesThresholds.probabilityFloor) } }
        var best = rows.map { $0[0] }
        var back: [[Int]] = []
        for event in 1..<events {
            var next = Array(repeating: 0.0, count: rows.count)
            var arg = Array(repeating: 0, count: rows.count)
            var running = 0.0
            var at = 0
            for (t, row) in rows.enumerated() {
                if running > 0 {
                    next[t] = running * row[event]
                    arg[t] = at
                }
                if best[t] > running {
                    running = best[t]
                    at = t
                }
            }
            best = next
            back.append(arg)
        }
        guard var t = best.indices.max(by: { best[$0] < best[$1] || (best[$0] == best[$1] && $0 > $1) }) else { return nil }
        let product = best[t]
        var frames = [t]
        for arg in back.reversed() {
            t = arg[t]
            frames.append(t)
        }
        return (frames.reversed(), product)
    }

    public enum InputError: Error { case invalidPrediction }
}
