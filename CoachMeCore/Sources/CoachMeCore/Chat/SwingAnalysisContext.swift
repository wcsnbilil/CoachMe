import Foundation

/// The structured payload a future model would receive.
///
/// It contains only values that were actually computed or actually entered by
/// the coach. There is no field for a "standard" or "optimal" value, so none can
/// be invented downstream. When a metric has no coach range, `coachRange` is nil
/// and stays nil.
public struct SwingAnalysisContext: Sendable, Codable, Equatable {

    public struct MetricReading: Sendable, Codable, Equatable {
        public let metricID: MetricID
        public let nameZH: String
        public let side: BodySide?
        public let phase: SwingPhase
        public let timestampSeconds: Double
        /// nil when the metric could not be computed; `unavailableReason` says why.
        public let value: Double?
        public let unit: String
        public let unavailableReason: MetricUnavailableReason?
        /// Whether this number is a 2D image-plane projection or a 3D model estimate.
        public let space: MeasurementSpace
        public let definitionFormula: String
        public let definitionHash: String
        public let caveatZH: String
        public let coachRange: CoachRangeSummary?

        public init(metricID: MetricID,
                    nameZH: String,
                    side: BodySide?,
                    phase: SwingPhase,
                    timestampSeconds: Double,
                    value: Double?,
                    unit: String,
                    unavailableReason: MetricUnavailableReason?,
                    space: MeasurementSpace,
                    definitionFormula: String,
                    definitionHash: String,
                    caveatZH: String,
                    coachRange: CoachRangeSummary?) {
            self.metricID = metricID
            self.nameZH = nameZH
            self.side = side
            self.phase = phase
            self.timestampSeconds = timestampSeconds
            self.value = value
            self.unit = unit
            self.unavailableReason = unavailableReason
            self.space = space
            self.definitionFormula = definitionFormula
            self.definitionHash = definitionHash
            self.caveatZH = caveatZH
            self.coachRange = coachRange
        }
    }

    public struct CoachRangeSummary: Sendable, Codable, Equatable {
        public let lowerBound: Double?
        public let upperBound: Double?
        public let unit: String
        public let sourceNote: String
        public let coachNote: String
        public let outOfRangeExplanation: String
        public let drillSuggestion: String
        public let appliesToPhases: [SwingPhase]
        public let appliesToViews: [CameraView]

        public init(lowerBound: Double?,
                    upperBound: Double?,
                    unit: String,
                    sourceNote: String,
                    coachNote: String,
                    outOfRangeExplanation: String,
                    drillSuggestion: String,
                    appliesToPhases: [SwingPhase],
                    appliesToViews: [CameraView]) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
            self.unit = unit
            self.sourceNote = sourceNote
            self.coachNote = coachNote
            self.outOfRangeExplanation = outOfRangeExplanation
            self.drillSuggestion = drillSuggestion
            self.appliesToPhases = appliesToPhases
            self.appliesToViews = appliesToViews
        }
    }

    public struct QualitySummary: Sendable, Codable, Equatable {
        public let framesAnalysed: Int
        public let framesWithNoPerson: Int
        public let framesWithMultiplePeople: Int
        public let metricsUnavailable: [String]
        /// Free text stating what has not been validated, carried into any reply.
        public let statedLimitationsZH: [String]

        public init(framesAnalysed: Int,
                    framesWithNoPerson: Int,
                    framesWithMultiplePeople: Int,
                    metricsUnavailable: [String],
                    statedLimitationsZH: [String]) {
            self.framesAnalysed = framesAnalysed
            self.framesWithNoPerson = framesWithNoPerson
            self.framesWithMultiplePeople = framesWithMultiplePeople
            self.metricsUnavailable = metricsUnavailable
            self.statedLimitationsZH = statedLimitationsZH
        }
    }

    public let swingID: UUID
    public let analysisVersion: Int
    public let handedness: Handedness
    public let club: ClubType
    public let cameraView: CameraView
    public let markedPhases: [SwingPhase]
    public let selectedPhase: SwingPhase?
    public let selectedTimestampSeconds: Double?
    public let readings: [MetricReading]
    public let quality: QualitySummary
    /// Only populated when the user explicitly picked a swing to compare with.
    public let comparison: ComparisonSummary?

    public init(swingID: UUID,
                analysisVersion: Int,
                handedness: Handedness,
                club: ClubType,
                cameraView: CameraView,
                markedPhases: [SwingPhase],
                selectedPhase: SwingPhase?,
                selectedTimestampSeconds: Double?,
                readings: [MetricReading],
                quality: QualitySummary,
                comparison: ComparisonSummary?) {
        self.swingID = swingID
        self.analysisVersion = analysisVersion
        self.handedness = handedness
        self.club = club
        self.cameraView = cameraView
        self.markedPhases = markedPhases
        self.selectedPhase = selectedPhase
        self.selectedTimestampSeconds = selectedTimestampSeconds
        self.readings = readings
        self.quality = quality
        self.comparison = comparison
    }

    public struct ComparisonSummary: Sendable, Codable, Equatable {
        public let otherSwingID: UUID
        /// Phases present in both swings — the comparison is aligned on these,
        /// never on raw elapsed seconds.
        public let alignedPhases: [SwingPhase]
        public let deltas: [PhaseDelta]

        public init(otherSwingID: UUID, alignedPhases: [SwingPhase], deltas: [PhaseDelta]) {
            self.otherSwingID = otherSwingID
            self.alignedPhases = alignedPhases
            self.deltas = deltas
        }

        public struct PhaseDelta: Sendable, Codable, Equatable {
            public let metricID: MetricID
            public let side: BodySide?
            public let phase: SwingPhase
            public let thisValue: Double?
            public let otherValue: Double?
            public let delta: Double?

            public init(metricID: MetricID,
                        side: BodySide?,
                        phase: SwingPhase,
                        thisValue: Double?,
                        otherValue: Double?,
                        delta: Double?) {
                self.metricID = metricID
                self.side = side
                self.phase = phase
                self.thisValue = thisValue
                self.otherValue = otherValue
                self.delta = delta
            }
        }
    }

    /// The standing limitations that apply to every CoachMe analysis. Written
    /// once here so they travel with the data instead of living only in the UI.
    public static let standingLimitationsZH = [
        "三维坐标为 MediaPipe GHUM 模型估计，未经标定或动作捕捉验证。",
        "肩线与髋线转角为相对准备姿势的估计值，不是相对目标线；未标定时目标线与地面方向均未知。",
        "本系统不测量前臂旋前旋后、手腕屈伸、杆面角度或杆头速度。",
        "关键点可见度是数据是否可用的门槛，不代表角度测量的准确度。"
    ]
}
