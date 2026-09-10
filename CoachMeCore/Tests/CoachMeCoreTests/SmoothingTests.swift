import XCTest
@testable import CoachMeCore

/// Smoothing changes the numbers a coach reads, so the guarantees it must keep
/// are tested as tightly as the geometry.
final class SmoothingTests: XCTestCase {

    private func frame(_ t: Double, x: Double, visibility: Double = 1.0) -> PoseFrame {
        let marks = PoseJoint.allCases.map { _ in
            Landmark(x, 0, 0, visibility: visibility, presence: visibility)
        }
        var moved = marks
        moved[PoseJoint.leftShoulder.rawValue] = Landmark(x, 0, 0, visibility: visibility, presence: visibility)
        return PoseFrame(timestampSeconds: t, imageLandmarks: moved,
                         worldLandmarks: moved, detectedPersonCount: 1)
    }

    private func xs(_ frames: [PoseFrame]) -> [Double] {
        frames.map { $0.imageLandmark(.leftShoulder)!.position.x }
    }

    // MARK: - OneEuroFilter

    func testFirstSamplePassesThroughUntouched() {
        let f = OneEuroFilter(minCutoff: 5, beta: 2)
        var state = OneEuroFilter.State()
        XCTAssertEqual(f.filter(3.7, timestamp: 0, state: &state), 3.7, accuracy: 1e-12)
    }

    func testConstantSignalStaysConstant() {
        let f = OneEuroFilter(minCutoff: 5, beta: 2)
        var state = OneEuroFilter.State()
        for i in 0..<50 {
            let out = f.filter(2.0, timestamp: Double(i) / 24.0, state: &state)
            XCTAssertEqual(out, 2.0, accuracy: 1e-9, "常量信号不应被改变")
        }
    }

    func testNonPositiveTimeStepIsPassedThroughRatherThanDividedBy() {
        let f = OneEuroFilter(minCutoff: 5, beta: 2)
        var state = OneEuroFilter.State()
        _ = f.filter(1.0, timestamp: 1.0, state: &state)
        let out = f.filter(9.0, timestamp: 1.0, state: &state)   // dt == 0
        XCTAssertEqual(out, 9.0, accuracy: 1e-12)
        XCTAssertFalse(out.isNaN, "dt 为零不得产生 NaN")
    }

    func testNoiseIsReducedOnAStationarySignal() {
        let f = OneEuroFilter(minCutoff: 5, beta: 2)
        var state = OneEuroFilter.State()
        // Deterministic alternating noise around a constant.
        let raw = (0..<40).map { 10.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }
        var out: [Double] = []
        for (i, v) in raw.enumerated() {
            out.append(f.filter(v, timestamp: Double(i) / 24.0, state: &state))
        }
        func jitter(_ xs: [Double]) -> Double {
            zip(xs.dropFirst(), xs).map { abs($0 - $1) }.reduce(0, +) / Double(xs.count - 1)
        }
        XCTAssertLessThan(jitter(Array(out.dropFirst(5))), jitter(Array(raw.dropFirst(5))) * 0.8,
                          "平滑后抖动应明显下降")
    }

    func testARampIsTrackedWithBoundedLag() {
        let f = OneEuroFilter(minCutoff: 5, beta: 2)
        var state = OneEuroFilter.State()
        var out = 0.0
        for i in 0..<40 { out = f.filter(Double(i), timestamp: Double(i) / 24.0, state: &state) }
        // A steady ramp must not be left far behind; beta exists precisely for this.
        XCTAssertEqual(out, 39.0, accuracy: 3.0, "斜坡信号的延迟应有界")
    }

    // MARK: - PoseSequenceSmoother

    func testVisibilityAndPresenceAreNeverAltered() {
        let frames = (0..<10).map { frame(Double($0) / 24.0, x: Double($0), visibility: 0.83) }
        let out = PoseSequenceSmoother().smooth(frames)
        for f in out {
            XCTAssertEqual(f.imageLandmark(.leftShoulder)?.visibility, 0.83)
            XCTAssertEqual(f.imageLandmark(.leftShoulder)?.presence, 0.83)
        }
    }

    /// The rule that matters most: a landmark the model could not see must not be
    /// invented by carrying a filtered position forward.
    func testLowVisibilityLandmarksPassThroughUnchanged() {
        let frames = (0..<10).map { frame(Double($0) / 24.0, x: Double($0) * 100, visibility: 0.1) }
        let out = PoseSequenceSmoother().smooth(frames)
        XCTAssertEqual(xs(out), xs(frames), "低可见度关键点必须原样透传")
    }

    func testPersonCountAndTimestampsSurvive() {
        let frames = (0..<10).map { frame(Double($0) / 24.0, x: Double($0)) }
        let out = PoseSequenceSmoother().smooth(frames)
        XCTAssertEqual(out.map(\.timestampSeconds), frames.map(\.timestampSeconds))
        XCTAssertEqual(out.map(\.detectedPersonCount), frames.map(\.detectedPersonCount))
    }

    func testMissingWorldLandmarksStayMissing() {
        let frames = (0..<5).map { i -> PoseFrame in
            PoseFrame(timestampSeconds: Double(i) / 24.0,
                      imageLandmarks: PoseJoint.allCases.map { _ in Landmark(1, 2, 3, visibility: 1) },
                      worldLandmarks: nil, detectedPersonCount: 1)
        }
        let out = PoseSequenceSmoother().smooth(frames)
        XCTAssertTrue(out.allSatisfy { $0.worldLandmarks == nil }, "缺失的三维数据不得被补出来")
    }

    func testShortSequencesArePassedThrough() {
        XCTAssertEqual(PoseSequenceSmoother().smooth([]).count, 0)
        let one = [frame(0, x: 5)]
        XCTAssertEqual(xs(PoseSequenceSmoother().smooth(one)), xs(one))
    }

    func testNoneIsDistinctFromDefaultAndIsRecorded() {
        XCTAssertNotEqual(SmoothingParameters.default.minCutoff, 0)
        XCTAssertFalse(SmoothingParameters.default.describedZH.isEmpty,
                       "报告需要能说出做了什么处理")
    }
}

extension SmoothingTests {

    /// The two presets exist because one cutoff cannot serve both time bases.
    /// Slow-motion footage carries the same motion spread over more frames, so
    /// every frequency in it is lower and the cutoff must come down to match.
    func testSlowMotionPresetCutsFarLowerThanRealTime() {
        XCTAssertLessThan(SmoothingParameters.slowMotion.minCutoff,
                          SmoothingParameters.realTime.minCutoff,
                          "慢动作的截止频率必须低于实时")
        let ratio = SmoothingParameters.realTime.minCutoff / SmoothingParameters.slowMotion.minCutoff
        XCTAssertGreaterThan(ratio, 4, "两者差距应与常见慢动作倍率相当")
    }

    /// Real-time is the safer default: under-smoothing slow motion is a missed
    /// opportunity, while over-smoothing real footage destroys the downswing.
    func testDefaultIsTheRealTimePreset() {
        XCTAssertEqual(SmoothingParameters.default, SmoothingParameters.realTime)
    }

    func testBothPresetsShareTheVisibilityGate() {
        XCTAssertEqual(SmoothingParameters.slowMotion.minVisibility,
                       SmoothingParameters.realTime.minVisibility,
                       "可见度门槛与时间基准无关，两套预设应一致")
    }

    /// Whichever preset is chosen, it must survive being written to disk with the
    /// analysis — a report has to be able to state what was done.
    func testPresetsRoundTripThroughCoding() throws {
        for preset in [SmoothingParameters.realTime, .slowMotion] {
            let data = try JSONEncoder().encode(preset)
            XCTAssertEqual(try JSONDecoder().decode(SmoothingParameters.self, from: data), preset)
        }
    }
}
