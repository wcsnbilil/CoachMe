import XCTest
@testable import CoachMeCore

final class BetaModeTests: XCTestCase {

    // MARK: Beta surfaces: AI and other metrics are not reachable

    func testBetaModeOnlyExposesBetaSurfaces() {
        let reachable = AppFeature.allCases.filter { $0.isAvailable(betaMode: true) }
        XCTAssertEqual(Set(reachable), [.shootingGuide, .pathReport, .refusalHelp, .recordList, .exportRecords, .settingsVersion])
        for f in [AppFeature.aiCoachChat, .aiSettings, .jointAngleMetrics, .angleCurve, .coachRules, .keyframeWorkbench,
                  .avatar3D, .skeletonPlayback] {
            XCTAssertFalse(f.isAvailable(betaMode: true), "\(f) 在内测模式下不应可达")
            XCTAssertTrue(f.isAvailable(betaMode: false), "\(f) 在完整版应保留")
        }
        XCTAssertTrue(reachable.allSatisfy { !$0.usesNetwork })
    }

    // MARK: Zero network requests

    final class CountingProtocol: URLProtocol {
        static let lock = NSLock()
        static var count = 0
        override class func canInit(with request: URLRequest) -> Bool {
            lock.lock(); count += 1; lock.unlock()
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    private func chatContext() -> SwingAnalysisContext {
        SwingAnalysisContext(swingID: UUID(), analysisVersion: 1, handedness: .rightHanded, club: .iron,
            cameraView: .downTheLine, markedPhases: [], selectedPhase: nil, selectedTimestampSeconds: 0,
            readings: [], quality: .init(framesAnalysed: 10, framesWithNoPerson: 0, framesWithMultiplePeople: 0,
            metricsUnavailable: [], statedLimitationsZH: []), comparison: nil)
    }

    private func sendOnce(offline: Bool) async -> (requests: Int, error: Error?) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingProtocol.self]
        let session = URLSession(configuration: config)
        var c = LLMConfiguration(); c.provider = .openAI; c.baseURL = LLMProvider.openAI.baseURL; c.model = "m"
        let service = LLMChatService(configuration: c, apiKey: "k", session: session)
        CountingProtocol.lock.lock(); CountingProtocol.count = 0; CountingProtocol.lock.unlock()
        NetworkGate.shared.isOffline = offline
        defer { NetworkGate.shared.isOffline = false }
        var caught: Error?
        do {
            for try await _ in service.send(message: ChatMessage(role: .user, content: "hi"),
                                            conversation: Conversation(swingID: UUID()),
                                            context: chatContext(), options: .init()) {}
        } catch { caught = error }
        CountingProtocol.lock.lock(); defer { CountingProtocol.lock.unlock() }
        return (CountingProtocol.count, caught)
    }

    func testBetaModeMakesZeroNetworkRequests() async {
        // Control: with the gate open the interceptor does see the request,
        // so a zero below means "blocked", not "interceptor not wired".
        let open = await sendOnce(offline: false)
        XCTAssertGreaterThan(open.requests, 0)

        let beta = await sendOnce(offline: true)
        XCTAssertEqual(beta.requests, 0, "内测模式下不应发出任何网络请求")
        XCTAssertNotNil(beta.error)
    }

    func testNetworkGateCheck() {
        let gate = NetworkGate()
        XCTAssertNoThrow(try gate.check())
        gate.isOffline = true
        XCTAssertThrowsError(try gate.check())
    }

    // MARK: Export

    func testExportJSONHasEveryField() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            BetaRecord(createdAt: t0, appVersion: "0.1.0", build: "7", verdict: .overTheTop, refusal: nil,
                       offset: 0.3, swingID: UUID(), evidence: nil),
            BetaRecord(createdAt: t0.addingTimeInterval(60), appVersion: "0.1.0", build: "7", verdict: .cannotJudge,
                       refusal: .cameraOffAxis, offset: nil, swingID: UUID(), evidence: nil),
            BetaRecord(createdAt: t0.addingTimeInterval(120), appVersion: "0.1.0", build: "8", verdict: .cannotJudge,
                       refusal: nil, swingNotFound: true, offset: nil, swingID: nil, evidence: nil),
        ]
        let data = try BetaExport(records: records, appVersion: "0.1.0", build: "8", now: t0).jsonData()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in BetaExport.requiredRootKeys {
            XCTAssertNotNil(root[key], "缺少 \(key)")
        }
        XCTAssertEqual(root["recordCount"] as? Int, 3)
        let entries = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 3)
        for e in entries {
            XCTAssertEqual(Set(e.keys), Set(BetaExport.requiredEntryKeys))
        }
        XCTAssertEqual(entries[0]["verdict"] as? String, "overTheTop")
        XCTAssertTrue(entries[0]["refusalReason"] is NSNull)
        XCTAssertEqual(entries[1]["refusalReason"] as? String, "cameraOffAxis")
        XCTAssertEqual(entries[2]["refusalReason"] as? String, "swingNotFound")
        XCTAssertEqual(entries[2]["build"] as? String, "8")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(entries[0]["time"] as? String)))
        // Nothing about the video or landmarks leaks into the export.
        let text = String(decoding: data, as: UTF8.self)
        for banned in ["swingID", "evidence", "landmark", "videoFilename", "downswing", ".mov", ".mp4"] {
            XCTAssertFalse(text.contains(banned), "导出不应包含 \(banned)")
        }
    }

    func testRecordStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BetaRecordStore(directory: dir)
        XCTAssertEqual(store.load(), [])
        let ev = PathEvidence(verdict: .withinProRange, refusal: nil, offset: 0, side: 1, imageWidth: 720, imageHeight: 1280,
                              downswing: [.init(x: 1, y: 2)], referenceLine: [.init(x: 0, y: 10), .init(x: 5, y: 0)],
                              torsoPixels: 100, evidenceSeconds: 1.2)
        try store.append(BetaRecord(appVersion: "0.1.0", build: "1", verdict: .withinProRange, refusal: nil,
                                    offset: 0, swingID: nil, evidence: ev))
        try store.append(BetaRecord(appVersion: "0.1.0", build: "1", verdict: .cannotJudge, refusal: .downswingGap,
                                    offset: nil, swingID: nil, evidence: nil))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.refusal, .downswingGap, "最新的在前")
        XCTAssertEqual(loaded.last?.evidence, ev)
    }

    // MARK: Strings and refusal guidance

    func testLanguageFollowsSystem() {
        XCTAssertEqual(BetaLanguage.from(preferredLanguages: ["zh-Hans-CN", "en"]), .zh)
        XCTAssertEqual(BetaLanguage.from(preferredLanguages: ["zh-Hant-TW"]), .zh)
        XCTAssertEqual(BetaLanguage.from(preferredLanguages: ["en-US", "zh-Hans"]), .en)
        XCTAssertEqual(BetaLanguage.from(preferredLanguages: ["ja-JP"]), .en)
        XCTAssertEqual(BetaLanguage.from(preferredLanguages: []), .en)
    }

    func testEveryRefusalHasReasonAndRetakeStepsInBothLanguages() {
        let refusals: [SwingPathAnalyzer.Refusal?] = [nil, .phaseOrder, .torsoNotVisible, .cameraOffAxis, .wristsNotVisible,
            .sideUnclear, .backswingTooSmall, .shouldersNotAboveHands, .referenceNearVertical,
            .tooFewDownswingSamples, .trackingJumps, .downswingGap]
        var seen = Set<RefusalGuidance.Category>()
        for r in refusals {
            for lang in BetaLanguage.allCases {
                let g = RefusalGuidance(refusal: r, language: lang)
                XCTAssertFalse(g.reason.isEmpty)
                XCTAssertGreaterThanOrEqual(g.retakeSteps.count, 2)
                seen.insert(g.category)
            }
        }
        XCTAssertEqual(seen, Set(RefusalGuidance.Category.allCases))
        XCTAssertEqual(RefusalGuidance.category(for: .cameraOffAxis), .cameraOffLine)
        XCTAssertEqual(RefusalGuidance.category(for: .downswingGap), .trackingLost)
        XCTAssertEqual(RefusalGuidance.category(for: .wristsNotVisible), .wristsHidden)
        XCTAssertTrue(RefusalGuidance(refusal: .cameraOffAxis, language: .zh).reason.contains("机位偏离目标线"))
        XCTAssertTrue(RefusalGuidance(refusal: .trackingJumps, language: .zh).reason.contains("手部跟踪丢失"))
        XCTAssertTrue(RefusalGuidance(refusal: .wristsNotVisible, language: .zh).reason.contains("手腕可见帧太少"))
    }

    /// The hand path can look clean while the club comes over the top (Niko's clips), so no beta
    /// text may tell the user the swing is fine.
    func testBetaWordingNeverSaysTheSwingIsFine() {
        let banned = ["范围内", "没问题", "正常", "within range", "within the range", "no problem", "normal", "nothing wrong"]
        for lang in [BetaLanguage.zh, .en] {
            let s = BetaStrings(lang)
            var texts = [s.evidenceNote, s.uncertainty, s.reportTitle]
            for v in [SwingPathAnalyzer.Verdict.withinProRange, .overTheTop, .tooInside, .cannotJudge] {
                texts += [s.verdictTitle(v), s.verdictSummary(v, leftHanded: false),
                          s.verdictSummary(v, leftHanded: true), s.practicePlaceholder(v)]
            }
            for text in texts {
                for word in banned {
                    XCTAssertFalse(text.lowercased().contains(word), "\(lang)：「\(text)」含有「\(word)」")
                }
            }
        }
        XCTAssertTrue(BetaStrings(.zh).verdictSummary(.withinProRange, leftHanded: false).contains("看不到球杆的路线"))
    }

    func testStringsDifferByLanguageAndAreNonEmpty() {
        let zh = BetaStrings(.zh), en = BetaStrings(.en)
        XCTAssertEqual(zh.guideItems.count, 5)
        XCTAssertEqual(en.guideItems.count, 5)
        XCTAssertNotEqual(zh.uncertainty, en.uncertainty)
        XCTAssertEqual(zh.uncertainty, "参照职业球员的路径范围，对业余球手的准确度正在测试中。")
        XCTAssertEqual(zh.pendingCoach, "待教练确认")
        XCTAssertTrue(zh.verdictSummary(.overTheTop, leftHanded: false).contains("还取决于杆面"))
        XCTAssertTrue(zh.verdictSummary(.tooInside, leftHanded: false).contains("常和左曲或推右"))
        for v in [SwingPathAnalyzer.Verdict.withinProRange, .overTheTop, .tooInside, .cannotJudge] {
            XCTAssertEqual(zh.practicePlaceholder(v), PracticeTips.zh[v])
            XCTAssertEqual(en.practicePlaceholder(v), PracticeTips.en[v])
        }
        for v in [SwingPathAnalyzer.Verdict.withinProRange, .overTheTop, .tooInside, .cannotJudge] {
            for s in [zh, en] {
                XCTAssertFalse(s.verdictTitle(v).isEmpty)
                XCTAssertFalse(s.verdictSummary(v, leftHanded: false).isEmpty)
                XCTAssertFalse(s.practicePlaceholder(v).isEmpty)
            }
        }
    }

    // MARK: Evidence geometry

    func testEvidenceBandSurroundsReferenceLine() {
        let s = SwingPathAnalyzerTests.makeSwing(loop: 0.6, frames: 60)
        let r = SwingPathAnalyzer().analyze(landmarks: s.0, address: s.1, top: s.2, impact: s.3)
        XCTAssertEqual(r.verdict, .overTheTop)
        let torso = r.torsoPixels
        XCTAssertEqual(torso ?? 0, 100, accuracy: 15)
        let ev = PathEvidence(result: r, top: s.2, impact: s.3, frameSeconds: (0..<60).map { Double($0) / 30 },
                              imageWidth: 400, imageHeight: 400)
        XCTAssertFalse(ev.downswing.isEmpty)
        XCTAssertEqual(ev.evidenceSeconds ?? -1, Double((s.2 + s.3) / 2) / 30, accuracy: 1e-9)
        let band = ev.rangeBand()
        XCTAssertNotNil(band)
        if let band, let y = band.inside.first?.y, let x = ev.referenceX(atY: y) {
            // Right-handed: ball side is +x, so the outside edge sits right of the line.
            XCTAssertGreaterThan(band.outside[0].x, x)
            XCTAssertLessThan(band.inside[0].x, x)
        }
        XCTAssertNil(PathEvidence.swingNotFound(imageWidth: 1, imageHeight: 1).rangeBand())
    }

    // MARK: Log schema 2 (video, timing, device), 3 (swings found / chosen), 4 (preflight)

    func testExportCarriesVideoTimingRefusalAndDevice() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let video = VideoInfo(durationSeconds: 3.2104, width: 1080, height: 1920, frameRate: 239.87, codec: "HEVC")
        let rec = BetaRecord(createdAt: t0, appVersion: "0.1.0", build: "9", verdict: .cannotJudge,
                             refusal: .downswingGap, offset: nil, swingID: UUID(), evidence: nil,
                             video: video, analysisMilliseconds: 8421, deviceModel: "iPhone15,2",
                             swingsFound: 4, swingChosen: 4, preflight: "early:cameraOffAxis", preflightMilliseconds: 3100)
        let data = try BetaExport(records: [rec], appVersion: "0.1.0", build: "9", deviceModel: "iPhone15,2", now: t0).jsonData()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), Set(BetaExport.requiredRootKeys))
        XCTAssertEqual(root["schema"] as? Int, 4)
        XCTAssertEqual(root["deviceModel"] as? String, "iPhone15,2")
        let e = try XCTUnwrap((root["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(e.keys), Set(BetaExport.requiredEntryKeys))
        XCTAssertEqual(e["videoDurationSeconds"] as? Double, 3.21)
        XCTAssertEqual(e["videoWidth"] as? Int, 1080)
        XCTAssertEqual(e["videoHeight"] as? Int, 1920)
        XCTAssertEqual(e["videoFrameRate"] as? Double, 239.87)
        XCTAssertEqual(e["videoCodec"] as? String, "HEVC")
        XCTAssertEqual(e["videoOrientation"] as? String, "portrait")
        XCTAssertEqual(e["analysisMs"] as? Int, 8421)
        XCTAssertEqual(e["swingsFound"] as? Int, 4)
        XCTAssertEqual(e["swingChosen"] as? Int, 4)
        XCTAssertEqual(e["preflight"] as? String, "early:cameraOffAxis")
        XCTAssertEqual(e["preflightMs"] as? Int, 3100)
        XCTAssertEqual(e["refusalReason"] as? String, "downswingGap")
        XCTAssertEqual(e["refusalCategory"] as? String, "trackingLost")
        XCTAssertEqual(e["deviceModel"] as? String, "iPhone15,2")
        XCTAssertEqual(e["appVersion"] as? String, "0.1.0")
        XCTAssertEqual(e["build"] as? String, "9")
    }

    func testJudgedRecordHasNoRefusalCategory() {
        let r = BetaRecord(appVersion: "0.1.0", build: "1", verdict: .overTheTop, refusal: nil, offset: 0.3,
                           swingID: nil, evidence: nil)
        XCTAssertNil(r.refusalCategory)
        let n = BetaRecord(appVersion: "0.1.0", build: "1", verdict: .cannotJudge, refusal: nil, swingNotFound: true,
                           offset: nil, swingID: nil, evidence: nil)
        XCTAssertEqual(n.refusalCategory, "swingNotFound")
        XCTAssertEqual(n.refusalCode, "swingNotFound")
    }

    /// A records file written by build 0.1.0 (schema 1, before these fields) still loads and exports.
    func testOldRecordsFileStillLoadsAndExports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":784111777.5,"appVersion":"0.1.0","build":"1",
          "verdict":"withinProRange","swingNotFound":false,"offset":-0.12},
         {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":784111800.25,"appVersion":"0.1.0","build":"1",
          "verdict":"cannotJudge","refusal":"cameraOffAxis","swingNotFound":false}]
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("beta_records.json"))
        let loaded = BetaRecordStore(directory: dir).load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertNil(loaded[0].video)
        XCTAssertNil(loaded[0].analysisMilliseconds)
        let data = try BetaExport(records: loaded, appVersion: "0.2.0", build: "2").jsonData()
        let entries = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["records"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        for e in entries {
            XCTAssertEqual(Set(e.keys), Set(BetaExport.requiredEntryKeys))
            XCTAssertTrue(e["videoCodec"] is NSNull)
            XCTAssertTrue(e["analysisMs"] is NSNull)
            XCTAssertTrue(e["swingsFound"] is NSNull)
            XCTAssertTrue(e["preflight"] is NSNull)
            XCTAssertTrue(e["deviceModel"] is NSNull)
        }
        XCTAssertEqual(entries[1]["refusalCategory"] as? String, "cameraOffLine")
    }

    func testCodecNamesAndOrientation() {
        func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
        XCTAssertEqual(VideoInfo.codecName(fourCC: fourCC("hvc1")), "HEVC")
        XCTAssertEqual(VideoInfo.codecName(fourCC: fourCC("avc1")), "H.264")
        XCTAssertEqual(VideoInfo.codecName(fourCC: fourCC("mp4v")), "mp4v")
        XCTAssertEqual(VideoInfo(durationSeconds: 1, width: 1920, height: 1080, frameRate: 30, codec: "H.264").orientation, "landscape")
        XCTAssertEqual(VideoInfo(durationSeconds: 1, width: 720, height: 720, frameRate: 30, codec: "H.264").orientation, "square")
    }
}
