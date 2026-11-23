import XCTest
@testable import Model
@testable import Diagnosis
import DiagnosisTestSupport

/// Same synthetic swings as tools/faults/test_path_fault.py.
final class SwingPathAnalyzerTests: XCTestCase {
    typealias P = SwingPathAnalyzer.PathPoint

    let analyzer = SwingPathAnalyzer()

    func run(_ s: ([[P]], Int, Int, Int), _ a: SwingPathAnalyzer? = nil) -> SwingPathAnalyzer.Result {
        (a ?? analyzer).analyze(landmarks: s.0, address: s.1, top: s.2, impact: s.3)
    }

    func testOverTheTopAndInside() {
        XCTAssertEqual(run(SyntheticSwing.make(loop: 0.6)).verdict, .overTheTop)
        XCTAssertEqual(run(SyntheticSwing.make(loop: -0.4)).verdict, .tooInside)
        XCTAssertEqual(run(SyntheticSwing.make(loop: 0)).verdict, .withinProRange)
    }

    /// Only the hands are tracked (owner's decision 2026-11-23): the report names the hand path, never the club path.
    func testReportWordingNamesTheHandPath() {
        for v in [SwingPathAnalyzer.Verdict.withinProRange, .overTheTop, .tooInside] {
            XCTAssertTrue(v.displayZH.contains("手部路径"), v.displayZH)
            for side in [1, -1] {
                if let risk = v.riskZH(side: side) { XCTAssertTrue(risk.contains("双手"), risk) }
            }
        }
        for v in [SwingPathAnalyzer.Verdict.withinProRange, .overTheTop, .tooInside, .cannotJudge] {
            for word in ["杆头路径", "球杆路径"] { XCTAssertFalse(v.displayZH.contains(word), v.displayZH) }
        }
        XCTAssertEqual(SwingPathAnalyzer.Verdict.overTheTop.nameZH, "外下过度", "nameZH 必须和 tools/faults/path_fault.py 的判定标签一致")
    }

    func testMatchesPythonOnTheBaseSwing() {
        // path_fault.py on make_swing(loop=0): offset -0.156, backswing_offset -0.156, loop 0.0
        let r = run(SyntheticSwing.make(loop: 0))
        XCTAssertEqual(r.offset!, -0.156, accuracy: 0.0015)
        XCTAssertEqual(r.backswingOffset!, -0.156, accuracy: 0.0015)
        XCTAssertEqual(r.loop!, 0, accuracy: 0.0015)
    }

    func testLeftyMirrorGivesSameOffset() {
        let r = run(SyntheticSwing.make(loop: 0.4)), l = run(SyntheticSwing.make(loop: 0.4, lefty: true))
        XCTAssertEqual(r.side, 1)
        XCTAssertEqual(l.side, -1)
        XCTAssertEqual(r.offset!, l.offset!, accuracy: 1e-9)
    }

    func testWristLabelSwapIsHarmless() {
        var s = SyntheticSwing.make(loop: 0.4)
        let base = run(s).offset!
        for f in (s.1 + 5)..<(s.1 + 15) { s.0[f].swapAt(15, 16) }
        XCTAssertEqual(run(s).offset!, base, accuracy: 1e-12)
    }

    func testWristJumpingToElbowIsDropped() {
        var s = SyntheticSwing.make(loop: 0, frames: 120)
        let base = run(s).offset!
        for f in stride(from: s.2 + 4, to: s.3 - 4, by: 7) { s.0[f][15].x += 80 }
        XCTAssertEqual(run(s).offset!, base, accuracy: 0.03)
    }

    func testSingleFrameSpikeIsRemoved() {
        var s = SyntheticSwing.make(loop: 0, frames: 120)
        s.0[s.2 + 10][16].visibility = 0
        s.0[s.2 + 10][15].x += 40
        XCTAssertEqual(run(s).verdict, .withinProRange)
    }

    func testSlowMotionCopyAgrees() {
        let fast = run(SyntheticSwing.make(loop: 0.25, frames: 40, noise: 1.5, seed: 1))
        let slow = run(SyntheticSwing.make(loop: 0.25, frames: 160, noise: 1.5, seed: 2))
        XCTAssertEqual(fast.offset!, slow.offset!, accuracy: 0.05)
    }

    func testOffAxisCameraIsRefused() {
        let r = run(SyntheticSwing.make(shoulderWidth: 0.9))
        XCTAssertEqual(r.verdict, .cannotJudge)
        XCTAssertEqual(r.refusal, .cameraOffAxis)
    }

    func testLateAddressIsMovedBackToTheStillFrame() {
        let s = SyntheticSwing.make(loop: 0.6, frames: 120)
        let base = run(s)
        let late = analyzer.analyze(landmarks: s.0, address: s.1 + 8, top: s.2, impact: s.3)
        XCTAssertLessThanOrEqual(late.addressFrame!, s.1)
        XCTAssertEqual(late.offset!, base.offset!, accuracy: 0.01)
    }

    func testInsideTakeawayIsNotOverTheTop() {
        let normal = run(SyntheticSwing.make(loop: 0)), flat = run(SyntheticSwing.make(loop: 0, takeaway: -0.5))
        XCTAssertGreaterThan(flat.loop!, 0.3)
        XCTAssertEqual(flat.offset!, normal.offset!, accuracy: 0.02)
        XCTAssertEqual(flat.verdict, .withinProRange)
    }

    func testCalibrationMovesTheBoundary() {
        let tight = SwingPathAnalyzer(calibration: .init(outside: 0.1, inside: -0.6, source: "test"))
        XCTAssertEqual(run(SyntheticSwing.make(loop: 0.4), tight).verdict, .overTheTop)
        let wide = SwingPathAnalyzer(calibration: .init(outside: 0.6, inside: -0.6, source: "test"))
        XCTAssertEqual(run(SyntheticSwing.make(loop: 0.4), wide).verdict, .withinProRange)
    }

    func testPoseFramesAreScaledToPixels() {
        // Same swing fed as normalised PoseFrames of a 400x400 video.
        let s = SyntheticSwing.make(loop: 0.6)
        let frames = s.0.enumerated().map { i, pts in
            PoseFrame(timestampSeconds: Double(i) / 30,
                      imageLandmarks: pts.map { Landmark($0.x / 400, $0.y / 400, 0, visibility: $0.visibility) },
                      worldLandmarks: nil, detectedPersonCount: 1)
        }
        let r = analyzer.analyze(frames: frames, address: Double(s.1) / 30, top: Double(s.2) / 30,
                                 impact: Double(s.3) / 30, imageWidth: 400, imageHeight: 400)
        XCTAssertEqual(r.offset!, run(s).offset!, accuracy: 1e-9)
    }

    // MARK: Tracking jumps (path_fault.py v4)

    func testCleanSwingsHaveNoJumpFrames() {
        for frames in [30, 60, 160] {
            for loop in [-0.4, 0, 0.6] {
                let r = run(SyntheticSwing.make(loop: loop, frames: frames, noise: 1, seed: UInt64(frames)))
                XCTAssertEqual(r.jumpFrames, 0, "frames \(frames) loop \(loop)")
            }
        }
    }

    func testWholePoseJumpIsDropped() {
        var s = SyntheticSwing.make(loop: 0, frames: 60)
        let base = run(s).offset!
        for f in (s.2 + 3)..<(s.2 + 6) {
            s.0[f] = s.0[f].map { P(x: $0.x + 120, y: $0.y - 40, visibility: $0.visibility) }
        }
        let r = run(s)
        XCTAssertEqual(r.jumpFrames, 3)
        XCTAssertEqual(r.offset!, base, accuracy: 0.03)
    }

    func testBothWristsJumpingTogetherIsDropped() {
        var s = SyntheticSwing.make(loop: 0, frames: 40)
        let base = run(s)
        for f in (s.2 + 2)..<(s.2 + 4) { s.0[f][15].x += 70; s.0[f][16].x += 70 }
        let r = run(s)
        XCTAssertGreaterThanOrEqual(r.jumpFrames, 2)
        XCTAssertEqual(r.verdict, base.verdict)
        XCTAssertEqual(r.offset!, base.offset!, accuracy: 0.03)
    }

    func testJumpAtAddressDoesNotMoveTheReferenceLine() {
        var s = SyntheticSwing.make(loop: 0, frames: 60)
        let base = run(s)
        for j in [11, 12, 0] { s.0[s.1][j].x += 60 }
        let r = run(s)
        XCTAssertEqual(r.offset!, base.offset!, accuracy: 0.01)
        XCTAssertEqual(r.shoulderWidth!, base.shoulderWidth!, accuracy: 1e-9)
    }

    func testLostDownswingIsRefused() {
        var s = SyntheticSwing.make(loop: 0, frames: 120)
        for f in (s.2 + 5)..<(s.2 + 18) { s.0[f][15].visibility = 0; s.0[f][16].visibility = 0 }  // 13 of 30 frames
        XCTAssertEqual(run(s).refusal, .downswingGap)
        XCTAssertNil(run(s).confidence)
    }

    private func lost(_ gap: Int, frames: Int = 120) -> SwingPathAnalyzer.Result {
        var s = SyntheticSwing.make(loop: 0, frames: frames)
        for f in (s.2 + 5)..<(s.2 + 5 + gap) { s.0[f][15].visibility = 0; s.0[f][16].visibility = 0 }
        return run(s)
    }

    /// Same cases as test_path_fault.test_gap_near_its_limit_is_low_tracking_on_both_sides.
    func testGapNearItsLimitIsLowTrackingOnBothSides() {
        XCTAssertEqual(lost(3).confidence, .normal)
        for gap in [4, 7, 8, 11] {
            XCTAssertEqual(lost(gap).verdict, .withinProRange, "gap \(gap)")
            XCTAssertEqual(lost(gap).confidence, .lowTracking, "gap \(gap)")
        }
        XCTAssertEqual(lost(12).refusal, .downswingGap)
    }

    func testGapMarginScalesWithTheDownswing() {
        XCTAssertEqual(lost(1, frames: 60).confidence, .normal)
        XCTAssertEqual(lost(2, frames: 60).confidence, .lowTracking)
        XCTAssertEqual(lost(5, frames: 60).confidence, .lowTracking)
        XCTAssertEqual(lost(6, frames: 60).refusal, .downswingGap)
    }

    func testCameraNearItsLimitIsLowCameraOnBothSides() {
        for (width, want) in [(0.15, SwingPathAnalyzer.Confidence.normal), (0.195, .lowCamera), (0.205, .lowCamera)] {
            let r = run(SyntheticSwing.make(loop: 0, shoulderWidth: width))
            XCTAssertEqual(r.verdict, .withinProRange, "width \(width)")
            XCTAssertEqual(r.confidence, want, "width \(width)")
        }
        XCTAssertEqual(run(SyntheticSwing.make(loop: 0, shoulderWidth: 0.22)).refusal, .cameraOffAxis)
    }

    func testOffsetNearAThresholdIsNearBoundary() throws {
        let base = run(SyntheticSwing.make(loop: 0))
        XCTAssertEqual(base.confidence, .normal)
        let o = try XCTUnwrap(base.offset)
        for edge in [o + 0.04, o - 0.04] {
            let a = SwingPathAnalyzer(calibration: .init(outside: edge, inside: -0.516, source: "test"))
            let s = SyntheticSwing.make(loop: 0)
            XCTAssertEqual(a.analyze(landmarks: s.0, address: s.1, top: s.2, impact: s.3).confidence, .nearBoundary)
        }
        let far = SwingPathAnalyzer(calibration: .init(outside: o + 0.06, inside: -0.516, source: "test"))
        let s = SyntheticSwing.make(loop: 0)
        XCTAssertEqual(far.analyze(landmarks: s.0, address: s.1, top: s.2, impact: s.3).confidence, .normal)
    }

    func testPythonHelpersBehaveLikeNumpy() {
        XCTAssertEqual(SwingPathAnalyzer.median([3, 1, 2, 4]), 2.5)
        XCTAssertEqual(SwingPathAnalyzer.oddWindow(2.5), 3)   // round(2.5) == 2 in Python, then lo = 3
        XCTAssertEqual(SwingPathAnalyzer.oddWindow(4.5), 5)   // round(4.5) == 4 -> 5
        XCTAssertEqual(SwingPathAnalyzer.oddWindow(5.5), 7)   // round(5.5) == 6 -> 7
        XCTAssertEqual(SwingPathAnalyzer.interpolateNaN([.nan, 1, .nan, 3, .nan]), [1, 1, 2, 3, 3])
    }
}

/// Swift vs Python on real GolfDB landmarks. Skipped unless COACHME_PATH_PARITY
/// points at the JSON written by tools/faults/export_parity.py.
final class SwingPathParityTests: XCTestCase {
    struct Swing: Decodable {
        let name: String
        let phases: [Int]
        let landmarks: [[[Double?]]]
        let verdict: String
        let offset: Double?
        let backswing_offset: Double?
        let loop: Double?
        let jump_frames: Int?
        /// normal / near_boundary / low_tracking / low_camera; null when refused.
        let confidence: String?
    }

    func testMatchesPythonOnGolfDB() throws {
        guard let path = ProcessInfo.processInfo.environment["COACHME_PATH_PARITY"] else {
            throw XCTSkip("set COACHME_PATH_PARITY to the export_parity.py output")
        }
        let swings = try JSONDecoder().decode([Swing].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(swings.isEmpty)
        let analyzer = SwingPathAnalyzer()
        var mismatches: [String] = []
        var states = Set<String>()
        for s in swings {
            let pts = s.landmarks.map { frame in
                frame.map { v in
                    SwingPathAnalyzer.PathPoint(x: v[0] ?? .nan, y: v[1] ?? .nan, visibility: v[2] ?? .nan)
                }
            }
            let r = analyzer.analyze(landmarks: pts, address: s.phases[0], top: s.phases[1], impact: s.phases[2])
            func close(_ a: Double?, _ b: Double?) -> Bool {
                switch (a, b) {
                case (nil, nil): return true
                case let (x?, y?): return abs(x - y) <= 0.0015  // Python rounds to 3 decimals
                default: return false
                }
            }
            if r.verdict.nameZH != s.verdict || !close(r.offset, s.offset)
                || !close(r.backswingOffset, s.backswing_offset) || !close(r.loop, s.loop)
                || (s.jump_frames.map { $0 != r.jumpFrames } ?? false)
                || r.confidence?.rawValue != s.confidence {
                mismatches.append("\(s.name): swift \(r.verdict.nameZH) \(r.offset ?? .nan) \(r.refusal?.rawValue ?? "") \(r.confidence?.rawValue ?? "-")"
                                  + " / python \(s.verdict) \(s.offset ?? .nan) \(s.confidence ?? "-")")
            }
            if let c = s.confidence { states.insert(c) }
        }
        // The fixture (GolfDB + make_synthetic_parity.py) must keep every soft state covered.
        XCTAssertEqual(states, Set(SwingPathAnalyzer.Confidence.allCases.map(\.rawValue)), "一致性数据缺少某种结论把握状态")
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(swings.count) differ:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }
}

/// Deterministic Gaussian noise for the slow-motion test.
