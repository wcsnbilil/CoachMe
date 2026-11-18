import Foundation

/// Process-wide switch that forbids outgoing requests. The beta build turns it
/// on at launch; every network path in CoachMeCore checks it before sending.
public final class NetworkGate: @unchecked Sendable {
    public static let shared = NetworkGate()
    private let lock = NSLock()
    private var offline = false

    public init() {}

    public var isOffline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return offline }
        set { lock.lock(); offline = newValue; lock.unlock() }
    }

    public struct Blocked: Error, Equatable {}

    /// Throws when requests are forbidden.
    public func check() throws {
        if isOffline { throw Blocked() }
    }
}

/// Everything a user can reach in the app. The beta build only routes to the
/// beta surfaces; this is what the tests assert against.
public enum AppFeature: String, CaseIterable, Sendable {
    case shootingGuide, pathReport, refusalHelp, recordList, exportRecords, settingsVersion
    /// 3D figure replayed from the filming camera only: no view switching, no angle numbers.
    case avatarReplay
    case aiCoachChat, aiSettings, jointAngleMetrics, angleCurve, coachRules, keyframeWorkbench
    /// Free-rotating 3D and the 2D skeleton playback: single-camera depth is not trustworthy from
    /// another view, so the beta only has `avatarReplay`.
    case avatar3D, skeletonPlayback

    public var isBetaSurface: Bool {
        switch self {
        case .shootingGuide, .pathReport, .refusalHelp, .recordList, .exportRecords, .settingsVersion, .avatarReplay: return true
        default: return false
        }
    }

    public func isAvailable(betaMode: Bool) -> Bool { betaMode ? isBetaSurface : true }

    /// Features that would talk to the network.
    public var usesNetwork: Bool { self == .aiCoachChat || self == .aiSettings }
}
