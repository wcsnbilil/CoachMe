import XCTest
import AVFoundation
import SwiftUI
import CoachMeCore
@testable import CoachMe

/// Beta build acceptance: AI and the other metrics cannot be reached, nothing
/// goes to the network, and the export carries every field.
@MainActor
final class BetaModeAppTests: XCTestCase {

    // MARK: AI and other metrics are not reachable

    func testBetaBuildShowsTheBetaRoot() {
        XCTAssertEqual(AppRoot.choose(betaMode: true), .beta)
        XCTAssertEqual(AppRoot.choose(betaMode: false), .fullCoach)
        XCTAssertEqual(BetaMode.parse("YES"), true)
        XCTAssertEqual(BetaMode.parse("NO"), false)
        XCTAssertEqual(BetaMode.parse(true), true)
        // The shipped Info.plist turns the beta on.
        XCTAssertEqual(BetaMode.parse(Bundle.main.object(forInfoDictionaryKey: BetaMode.defaultsKey) as Any), true)
    }

    func testEveryBetaScreenIsABetaSurface() {
        let routes: [BetaRoute] = [.guide, .result(UUID()), .replay3D(UUID())]
        let features = routes.map(\.feature) + BetaRoute.rootFeatures + BetaRoute.resultFeatures
        for f in features {
            XCTAssertTrue(f.isBetaSurface, "\(f) 不应出现在内测版")
            XCTAssertFalse(f.usesNetwork)
        }
        let blocked: [AppFeature] = [.aiCoachChat, .aiSettings, .jointAngleMetrics, .angleCurve, .coachRules, .keyframeWorkbench,
                                     .avatar3D, .skeletonPlayback]
        XCTAssertTrue(Set(features).isDisjoint(with: blocked))
    }

    /// The beta has a 3D replay, but only from the filming camera: no rotation, no view presets.
    @MainActor
    func testBeta3DReplayCannotChangeTheView() {
        XCTAssertEqual(BetaRoute.replay3D(UUID()).feature, .avatarReplay)
        let scene = BetaReplay3DView.scene(frame: nil)
        XCTAssertFalse(scene.orbit, "内测版 3D 回放不能拖动换视角")
        XCTAssertEqual(scene.angle, 0, "内测版 3D 回放只用原机位")
    }

    // MARK: Zero network requests (URLProtocol interception)

    final class CountingProtocol: URLProtocol {
        static var count = 0
        override class func canInit(with request: URLRequest) -> Bool { count += 1; return true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
        override func stopLoading() {}
    }

    private func fetch() async -> Error? {
        do { _ = try await URLSession.shared.data(from: URL(string: "https://example.com/coachme-probe")!); return nil }
        catch { return error }
    }

    func testBetaModeBlocksRequestsBeforeTheyReachTheNetworkLayer() async {
        URLProtocol.registerClass(CountingProtocol.self)
        defer { URLProtocol.unregisterClass(CountingProtocol.self) }

        CountingProtocol.count = 0
        _ = await fetch()
        XCTAssertGreaterThan(CountingProtocol.count, 0, "对照组：拦截器应能看到请求")

        BetaMode.enforceOffline()
        defer { BetaMode.liftOffline() }
        CountingProtocol.count = 0
        let error = await fetch()
        XCTAssertNotNil(error)
        XCTAssertEqual(CountingProtocol.count, 0, "内测模式下请求不应到达网络层")

        // The AI coach service is refused too, whatever session it would use.
        var c = LLMConfiguration(); c.provider = .deepSeek; c.baseURL = LLMProvider.deepSeek.baseURL; c.model = "m"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingProtocol.self]
        let service = LLMChatService(configuration: c, apiKey: "k", session: URLSession(configuration: config))
        let ctx = SwingAnalysisContext(swingID: UUID(), analysisVersion: 1, handedness: .rightHanded, club: .iron,
            cameraView: .downTheLine, markedPhases: [], selectedPhase: nil, selectedTimestampSeconds: 0, readings: [],
            quality: .init(framesAnalysed: 1, framesWithNoPerson: 0, framesWithMultiplePeople: 0,
                           metricsUnavailable: [], statedLimitationsZH: []), comparison: nil)
        do {
            for try await _ in service.send(message: ChatMessage(role: .user, content: "hi"),
                                            conversation: Conversation(swingID: UUID()), context: ctx, options: .init()) {}
            XCTFail("内测模式下 AI 请求应被拒绝")
        } catch {}
        XCTAssertEqual(CountingProtocol.count, 0)
    }

    /// The beta analysis itself (decode → pose → path) never touches the network.
    func testBetaAnalysisPipelineMakesNoRequests() async throws {
        URLProtocol.registerClass(CountingProtocol.self)
        defer { URLProtocol.unregisterClass(CountingProtocol.self) }
        CountingProtocol.count = 0

        let url = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: "swing3s", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(), phaseDetector: SwingNetPhaseDetector())
        let frames = try await analyzer.analyse(asset: asset, timeRange: nil) { _ in }
        let keyframes = await analyzer.keyframes
        let size = try await BetaAnalysisRunner.presentedSize(asset)
        let evidence = BetaAnalysisRunner.pathEvidence(frames: frames, keyframes: keyframes,
                                                       imageWidth: size.width, imageHeight: size.height)
        XCTAssertGreaterThan(frames.count, 10)
        _ = evidence
        XCTAssertEqual(CountingProtocol.count, 0, "本机分析不应发出网络请求")
    }

    // MARK: Export

    func testExportFileHasEveryField() throws {
        let records = [
            BetaRecord(appVersion: BetaMode.appVersion, build: BetaMode.build, verdict: .withinProRange,
                       refusal: nil, offset: -0.1, swingID: UUID(), evidence: nil),
            BetaRecord(appVersion: BetaMode.appVersion, build: BetaMode.build, verdict: .cannotJudge,
                       refusal: .wristsNotVisible, offset: nil, swingID: UUID(), evidence: nil),
        ]
        let url = try XCTUnwrap(BetaRootView.writeExport(records))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["appVersion"] as? String, BetaMode.appVersion)
        XCTAssertEqual(root["build"] as? String, BetaMode.build)
        let entries = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        for e in entries { XCTAssertEqual(Set(e.keys), Set(BetaExport.requiredEntryKeys)) }
        XCTAssertNotEqual(BetaMode.appVersion, "?")
        XCTAssertNotEqual(BetaMode.build, "?")
    }
}
