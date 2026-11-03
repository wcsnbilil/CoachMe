import Foundation

/// Compares two analysed swings phase by phase.
///
/// Ported from `tools/reference/verify_comparison.py`; keep the two in step.
///
/// - Aligns on phases both swings have confirmed, never on elapsed seconds.
/// - Matches sides by role (lead / trail arm), not by image side, so a
///   left-handed and a right-handed swing compare the same arm.
/// - Computes a difference only when both values exist, are finite, and come
///   from the same metric definition and unit. Otherwise `delta` stays nil.
/// - States why numbers may not be comparable instead of hiding it.
public enum SwingComparison {

    private enum Role: Hashable { case lead, trail }

    private struct Key: Hashable {
        let metricID: MetricID
        let role: Role?
        let phase: SwingPhase
    }

    private static func role(_ side: BodySide?, _ handedness: Handedness) -> Role? {
        guard let side else { return nil }
        return side == handedness.leadSide ? .lead : .trail
    }

    private static func usable(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func viewNameZH(_ view: CameraView) -> String {
        switch view {
        case .faceOn:      return "正面"
        case .downTheLine: return "沿目标线后方"
        case .unknown:     return "未知视角"
        }
    }

    /// `this` is the swing being viewed; every delta is `this − other`.
    public static func summary(this: SwingAnalysisContext,
                               other: SwingAnalysisContext) -> SwingAnalysisContext.ComparisonSummary {
        let aligned = Set(this.markedPhases).intersection(other.markedPhases)
            .sorted { $0.order < $1.order }
        let alignedSet = Set(aligned)

        var index: [Key: SwingAnalysisContext.MetricReading] = [:]
        for reading in other.readings {
            index[Key(metricID: reading.metricID, role: role(reading.side, other.handedness),
                      phase: reading.phase)] = reading
        }

        var deltas: [SwingAnalysisContext.ComparisonSummary.PhaseDelta] = []
        var definitionMismatches = 0
        for reading in this.readings where alignedSet.contains(reading.phase) {
            let match = index[Key(metricID: reading.metricID, role: role(reading.side, this.handedness),
                                  phase: reading.phase)]
            let sameDefinition = match.map {
                $0.definitionHash == reading.definitionHash && $0.unit == reading.unit
            } ?? false
            if match != nil && !sameDefinition { definitionMismatches += 1 }

            let thisValue = usable(reading.value)
            let otherValue = usable(match?.value)
            var delta: Double?
            if sameDefinition, let thisValue, let otherValue { delta = thisValue - otherValue }

            deltas.append(.init(metricID: reading.metricID, side: reading.side, phase: reading.phase,
                                thisValue: thisValue, otherValue: otherValue, delta: delta))
        }

        var warnings: [String] = []
        if aligned.isEmpty {
            warnings.append("两次挥杆没有共同的已复核阶段，无法对比。请先在工作台复核关键帧。")
        }
        if this.cameraView != other.cameraView {
            warnings.append("机位不同（\(viewNameZH(this.cameraView)) / \(viewNameZH(other.cameraView))），同一指标的数值受视角影响，差值仅供参考。")
        }
        if this.handedness != other.handedness {
            warnings.append("持杆手不同，已按引导侧 / 后侧对齐，而不是按画面左右。")
        }
        if this.club != other.club {
            warnings.append("球杆不同，动作幅度本身就可能不同。")
        }
        if definitionMismatches > 0 {
            warnings.append("有 \(definitionMismatches) 项指标定义版本不同，未计算差值。可重新分析较早的那次挥杆。")
        }

        return .init(otherSwingID: other.swingID, alignedPhases: aligned, deltas: deltas,
                     warningsZH: warnings)
    }
}
