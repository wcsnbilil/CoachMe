import Foundation

/// Gates that decide whether a metric is computed at all.
///
/// These thresholds are about **whether the landmarks are usable**, not about how
/// accurate the resulting angle is. A landmark can be fully visible and still be
/// placed imprecisely by the model. Nothing in this file should ever be presented
/// to the user as an accuracy figure.
public struct QualityPolicy: Sendable, Codable, Equatable {
    /// Minimum model visibility for a landmark to be used. Frames below this
    /// produce `.unavailable(.lowVisibility)`.
    public var minVisibility: Double
    /// Optional minimum presence score, when the model supplies one.
    public var minPresence: Double?
    /// Refuse every metric when more than one person is detected.
    public var rejectMultiplePeople: Bool

    public init(minVisibility: Double = 0.5,
                minPresence: Double? = nil,
                rejectMultiplePeople: Bool = true) {
        self.minVisibility = minVisibility
        self.minPresence = minPresence
        self.rejectMultiplePeople = rejectMultiplePeople
    }

    public static let `default` = QualityPolicy()
}

/// Frame-level findings that apply to every metric in that frame.
public struct FrameQuality: Sendable, Equatable, Codable {
    public let detectedPersonCount: Int
    public let hasWorldLandmarks: Bool
    /// Fraction of the 33 landmarks that pass the visibility gate. Reported for
    /// transparency in the report; not an accuracy score.
    public let visibleLandmarkFraction: Double
    public let blockingReason: MetricUnavailableReason?

    public init(detectedPersonCount: Int,
                hasWorldLandmarks: Bool,
                visibleLandmarkFraction: Double,
                blockingReason: MetricUnavailableReason?) {
        self.detectedPersonCount = detectedPersonCount
        self.hasWorldLandmarks = hasWorldLandmarks
        self.visibleLandmarkFraction = visibleLandmarkFraction
        self.blockingReason = blockingReason
    }

    public static func evaluate(frame: PoseFrame, policy: QualityPolicy) -> FrameQuality {
        let gate = policy.minVisibility
        let total = max(frame.imageLandmarks.count, 1)
        let visible = frame.imageLandmarks.filter { ($0.visibility ?? 1.0) >= gate }.count
        let fraction = Double(visible) / Double(total)

        var blocking: MetricUnavailableReason?
        if frame.detectedPersonCount == 0 || frame.imageLandmarks.isEmpty {
            blocking = .noPersonDetected
        } else if policy.rejectMultiplePeople && frame.detectedPersonCount > 1 {
            blocking = .multiplePeople
        }

        return FrameQuality(detectedPersonCount: frame.detectedPersonCount,
                            hasWorldLandmarks: frame.worldLandmarks != nil,
                            visibleLandmarkFraction: fraction,
                            blockingReason: blocking)
    }
}
