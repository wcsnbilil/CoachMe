import XCTest
import AVFoundation
import CoachMeCore
@testable import CoachMe

/// The whole value path in one test: video → landmarks → keyframes → metrics →
/// coach rule → findings → the payload the chat panel would send.
///
/// Every layer had tests before this; the seams between them did not. This is
/// the closest thing to "a coach actually used the app" that runs unattended.
final class EndToEndJourneyTests: XCTestCase {

    private func decodeFixture() async throws -> [PoseFrame] {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "swing3s", withExtension: "mp4"))
        let reader = VideoAssetReader(asset: AVURLAsset(url: url))
        try await reader.start(timeRange: nil)
        defer { reader.cancel() }

        let detector = MediaPipePoseDetector()
        try detector.prepare()

        var frames: [PoseFrame] = []
        while let decoded = try reader.nextFrame() {
            let r = try detector.detect(pixelBuffer: decoded.pixelBuffer,
                                        timestampMilliseconds: Int(decoded.timestampSeconds * 1000))
            frames.append(PoseFrame(timestampSeconds: decoded.timestampSeconds,
                                    imageLandmarks: r.imageLandmarks,
                                    worldLandmarks: r.worldLandmarks,
                                    detectedPersonCount: r.personCount))
        }
        return frames
    }

    func testCoachJourneyProducesFindingsWithRealNumbers() async throws {
        // 1. Analyse the clip.
        let frames = try await decodeFixture()
        XCTAssertGreaterThan(frames.count, 40, "3 秒片段应解出足够多的帧")
        let usable = frames.filter { $0.detectedPersonCount == 1 }
        XCTAssertGreaterThan(Double(usable.count) / Double(frames.count), 0.8,
                             "大部分帧应检测到人")

        // 2. Coach marks keyframes. Positions are approximate on purpose — this
        //    test is about the wiring, not about finding the true top of swing.
        let addressFrame = try XCTUnwrap(usable.first)
        let topFrame = usable[usable.count * 2 / 5]
        let impactFrame = usable[usable.count * 3 / 5]

        let address = try XCTUnwrap(AddressReference(frame: addressFrame, space: .worldEstimate3D),
                                    "无法从准备姿势帧建立参考——三维关键点可能缺失")

        // 3. Metrics per marked phase, exactly as the workbench recomputes them.
        let calculator = SwingMetricsCalculator(handedness: .rightHanded, cameraView: .faceOn)
        let metricsByPhase: [SwingPhase: FrameMetrics] = [
            .address: calculator.metrics(for: addressFrame, address: address),
            .top:     calculator.metrics(for: topFrame, address: address),
            .impact:  calculator.metrics(for: impactFrame, address: address)
        ]

        // Group-2 metrics need the address reference; this is what proves the
        // keyframe actually reached the calculation.
        let shoulderRotation = metricsByPhase[.top]!.outcome(.shoulderLineRotation)
        guard case .value(let rotationDegrees) = shoulderRotation else {
            return XCTFail("上杆顶点的肩线转角应可计算，实际为 \(shoulderRotation)")
        }
        XCTAssertTrue((-180...180).contains(rotationDegrees))

        // 4. Coach authors a rule. The hash binds it to today's definition.
        let definition = MetricCatalog.definition(for: .shoulderLineRotation)
        let rule = CoachRule(metricID: .shoulderLineRotation,
                             metricDefinitionHash: definition.definitionHash,
                             phases: [.top],
                             side: .bilateral,
                             lowerBound: -200,
                             upperBound: 200,
                             sourceNote: "测试数据，非教学标准",
                             coachNote: "集成测试用",
                             outOfRangeExplanation: "超出你设置的范围",
                             drillSuggestion: "无")

        // 5. Evaluate.
        let findings = RuleEngine().findings(rules: [rule],
                                             metricsByPhase: metricsByPhase,
                                             handedness: .rightHanded,
                                             club: .driver,
                                             view: .faceOn)
        let finding = try XCTUnwrap(findings.first, "应产出一条判定")
        guard case .inRange = finding.evaluation else {
            return XCTFail("范围设得极宽，应判为 inRange，实际 \(finding.evaluation)")
        }

        // 6. A stale rule must be refused, not reinterpreted.
        var stale = rule
        stale.metricDefinitionHash = "0000000000000000"
        let staleFindings = RuleEngine().findings(rules: [stale], metricsByPhase: metricsByPhase,
                                                  handedness: .rightHanded, club: .driver, view: .faceOn)
        guard case .definitionMismatch = try XCTUnwrap(staleFindings.first).evaluation else {
            return XCTFail("定义哈希不匹配的规则应被拒绝")
        }

        // 7. The payload the chat panel would hand to a model.
        let readings = metricsByPhase.keys.sorted { $0.order < $1.order }.map { phase -> SwingAnalysisContext.MetricReading in
            let m = metricsByPhase[phase]!
            let outcome = m.outcome(.shoulderLineRotation)
            return SwingAnalysisContext.MetricReading(
                metricID: .shoulderLineRotation, nameZH: definition.nameZH, side: nil,
                phase: phase, timestampSeconds: m.timestampSeconds,
                value: outcome.value, unit: definition.unit,
                unavailableReason: { if case .unavailable(let r) = outcome { return r }; return nil }(),
                space: definition.space, definitionFormula: definition.formula,
                definitionHash: definition.definitionHash, caveatZH: definition.caveatZH,
                coachRange: nil)
        }
        let context = SwingAnalysisContext(
            swingID: UUID(), analysisVersion: 1, handedness: .rightHanded, club: .driver,
            cameraView: .faceOn, markedPhases: [.address, .top, .impact], selectedPhase: .top,
            selectedTimestampSeconds: topFrame.timestampSeconds, readings: readings,
            quality: SwingAnalysisContext.QualitySummary(
                framesAnalysed: frames.count,
                framesWithNoPerson: frames.filter { $0.detectedPersonCount == 0 }.count,
                framesWithMultiplePeople: frames.filter { $0.detectedPersonCount > 1 }.count,
                metricsUnavailable: [],
                statedLimitationsZH: SwingAnalysisContext.standingLimitationsZH),
            comparison: nil)

        // The payload must survive the round trip a network call would put it through.
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(SwingAnalysisContext.self, from: data)
        XCTAssertEqual(decoded, context)
        XCTAssertFalse(decoded.quality.statedLimitationsZH.isEmpty,
                       "限制说明必须随数据一起传出去")
    }
}
