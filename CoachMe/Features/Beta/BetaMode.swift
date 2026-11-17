import Foundation
import SwiftUI
import CoachMeCore

/// The beta (TestFlight) build: one feature, no network, no AI.
///
/// On by default through the `COACHME_BETA_MODE` build setting (project.yml →
/// Info.plist `CoachMeBetaMode`). Set it to NO for the full coach app, or pass
/// `-CoachMeBetaMode NO` as a launch argument. Nothing in the full app is removed.
enum BetaMode {
    static let defaultsKey = "CoachMeBetaMode"

    static var isOn: Bool {
        if let override = UserDefaults.standard.object(forKey: defaultsKey) {
            return parse(override) ?? false
        }
        return parse(Bundle.main.object(forInfoDictionaryKey: defaultsKey) as Any) ?? false
    }

    static func parse(_ value: Any) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return ["YES", "TRUE", "1"].contains(s.uppercased()) }
        return nil
    }

    /// Hosted unit tests launch the app too; they flip the gate themselves.
    static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// Call once at launch. In beta mode every request is refused before it is made.
    static func bootstrap(betaMode: Bool = isOn) {
        guard betaMode, !isRunningTests else { return }
        enforceOffline()
    }

    static func enforceOffline() {
        NetworkGate.shared.isOffline = true
        URLProtocol.registerClass(OfflineURLProtocol.self)
    }

    static func liftOffline() {
        NetworkGate.shared.isOffline = false
        URLProtocol.unregisterClass(OfflineURLProtocol.self)
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    /// Hardware model identifier ("iPhone15,2"); on the simulator, the simulated model.
    static var deviceModel: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty {
            return "Simulator " + sim
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}

/// Which root the app shows.
enum AppRoot: Equatable {
    case beta, fullCoach
    static func choose(betaMode: Bool) -> AppRoot { betaMode ? .beta : .fullCoach }
}

/// Fails every request on URLSession.shared (and sessions that inherit global
/// protocols) while the gate is closed.
final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { NetworkGate.shared.isOffline }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private struct BetaStringsKey: EnvironmentKey {
    static let defaultValue = BetaStrings(.system)
}

extension EnvironmentValues {
    var betaStrings: BetaStrings {
        get { self[BetaStringsKey.self] }
        set { self[BetaStringsKey.self] = newValue }
    }
}

extension SwingPathAnalyzer.Verdict {
    var betaColor: Color {
        switch self {
        case .withinProRange: return CoachStyle.confirmed
        case .overTheTop, .tooInside: return CoachStyle.alert
        case .cannotJudge: return CoachStyle.pending
        }
    }
    var betaFill: Color {
        switch self {
        case .withinProRange: return CoachStyle.confirmedFill
        case .overTheTop, .tooInside: return CoachStyle.alertFill
        case .cannotJudge: return CoachStyle.pendingFill
        }
    }
}

extension BetaStrings {
    func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        f.dateFormat = language == .zh ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return f.string(from: date)
    }
}
