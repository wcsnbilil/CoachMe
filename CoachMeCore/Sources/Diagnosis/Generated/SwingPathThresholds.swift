// Generated from config/thresholds.json by tools/thresholds/generate.py.

public enum SwingPathThresholds {
    public static let calibrationCenter = -0.154
    public static let calibrationOutside = 0.142
    public static let calibrationInside = -0.516
    public static let calibrationSource = "golfdb_dtl_first200_v3d"
    public static let minVisibility = 0.5
    public static let maxWristGap = 0.6
    public static let maxLineWidth = 0.2
    public static let minTrackedShare = 0.7
    public static let minBackswingRise = 0.5
    public static let smoothingWindowDivisor = 20.0
    public static let stillSpeedShare = 0.1
    public static let hampelSigmas = 3.0
    public static let madScale = 1.4826
    public static let maxHipShift = 0.5
    public static let maxReach = 1.8
    public static let despikeFloor = 0.25
    public static let despikeMADs = 3.0
    public static let jumpReturnShare = 0.5
    public static let jumpCancelShare = 0.5
    public static let maxJumpFrames = 4
    public static let maxDownswingGap = 0.25
    public static let minFilledGap = 3.0
    public static let cautionBackswingOffset = 0.4
    public static let nearBoundary = 0.05
    public static let lowTrackingFraction = 0.125
    public static let lowTrackingMinFrames = 1.0
    public static let lowCameraMargin = 0.05
}
