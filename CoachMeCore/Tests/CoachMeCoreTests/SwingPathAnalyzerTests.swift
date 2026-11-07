import XCTest
@testable import CoachMeCore

/// Same synthetic swings as tools/faults/test_path_fault.py.
final class SwingPathAnalyzerTests: XCTestCase {
    typealias P = SwingPathAnalyzer.PathPoint

    /// Right-handed DTL swing in pixels: torso 100 px, ball at larger x. `loop`
    /// bends the downswing toward the ball, `takeaway` bends the backswing.
    static func makeSwing(loop: Double = 0, frames: Int = 60, lefty: Bool = false, wristGap: Double = 0.1,
                          shoulderWidth: Double = 0.15, takeaway: Double = 0,
                          noise: Double = 0, seed: UInt64 = 1) -> ([[P]], Int, Int, Int) {
        var rng = SplitMix(seed: seed)
        let address = Int(Double(frames) * 0.1), top = Int(Double(frames) * 0.6), impact = Int(Double(frames) * 0.85)
        let hip = (200.0, 300.0), torso = 100.0
        let sh = (hip.0 + 30, hip.1 - torso * 0.95)
        let off = shoulderWidth * torso / 2
        let addr = (260.0, 330.0), topH = (180.0, 130.0)
        var out: [[P]] = []
        for f in 0..<frames {
            var hx: Double, hy: Double
            if f <= address {
                (hx, hy) = addr
            } else if f <= top {
                let t = Double(f - address) / Double(top - address)
                hx = addr.0 + (topH.0 - addr.0) * t + takeaway * torso * sin(.pi * t)
                hy = addr.1 + (topH.1 - addr.1) * t
            } else {
                let t = min(1, Double(f - top) / Double(impact - top))
                hx = topH.0 + (addr.0 - topH.0) * t + loop * torso * sin(.pi * t)
                hy = topH.1 + (addr.1 - topH.1) * t
            }
            if noise > 0 { hx += rng.gaussian() * noise; hy += rng.gaussian() * noise }
            var pts = Array(repeating: P(x: 0, y: 0), count: 33)
            pts[23] = P(x: hip.0 - off * 0.8, y: hip.1); pts[24] = P(x: hip.0 + off * 0.8, y: hip.1)
            pts[11] = P(x: sh.0 - off, y: sh.1); pts[12] = P(x: sh.0 + off, y: sh.1)
            pts[0] = P(x: sh.0 + 40, y: sh.1 - 30)
            let half = wristGap * torso / 2
            pts[15] = P(x: hx - half, y: hy); pts[16] = P(x: hx + half, y: hy)
            if lefty { pts = pts.map { P(x: 400 - $0.x, y: $0.y, visibility: $0.visibility) } }
            out.append(pts)
        }
        return (out, address, top, impact)
    }

    let analyzer = SwingPathAnalyzer()

    func run(_ s: ([[P]], Int, Int, Int), _ a: SwingPathAnalyzer? = nil) -> SwingPathAnalyzer.Result {
        (a ?? analyzer).analyze(landmarks: s.0, address: s.1, top: s.2, impact: s.3)
    }

    func testOverTheTopAndInside() {
        XCTAssertEqual(run(Self.makeSwing(loop: 0.6)).verdict, .overTheTop)
        XCTAssertEqual(run(Self.makeSwing(loop: -0.4)).verdict, .tooInside)
        XCTAssertEqual(run(Self.makeSwing(loop: 0)).verdict, .withinProRange)
    }

    func testMatchesPythonOnTheBaseSwing() {
        // path_fault.py on make_swing(loop=0): offset -0.156, backswing_offset -0.156, loop 0.0
        let r = run(Self.makeSwing(loop: 0))
        XCTAssertEqual(r.offset!, -0.156, accuracy: 0.0015)
        XCTAssertEqual(r.backswingOffset!, -0.156, accuracy: 0.0015)
        XCTAssertEqual(r.loop!, 0, accuracy: 0.0015)
    }

    func testLeftyMirrorGivesSameOffset() {
        let r = run(Self.makeSwing(loop: 0.4)), l = run(Self.makeSwing(loop: 0.4, lefty: true))
        XCTAssertEqual(r.side, 1)
        XCTAssertEqual(l.side, -1)
        XCTAssertEqual(r.offset!, l.offset!, accuracy: 1e-9)
    }

    func testWristLabelSwapIsHarmless() {
        var s = Self.makeSwing(loop: 0.4)
        let base = run(s).offset!
        for f in (s.1 + 5)..<(s.1 + 15) { s.0[f].swapAt(15, 16) }
        XCTAssertEqual(run(s).offset!, base, accuracy: 1e-12)
    }

    func testWristJumpingToElbowIsDropped() {
        var s = Self.makeSwing(loop: 0, frames: 120)
        let base = run(s).offset!
        for f in stride(from: s.2 + 4, to: s.3 - 4, by: 7) { s.0[f][15].x += 80 }
        XCTAssertEqual(run(s).offset!, base, accuracy: 0.03)
    }

    func testSingleFrameSpikeIsRemoved() {
        var s = Self.makeSwing(loop: 0, frames: 120)
        s.0[s.2 + 10][16].visibility = 0
        s.0[s.2 + 10][15].x += 40
        XCTAssertEqual(run(s).verdict, .withinProRange)
    }

    func testSlowMotionCopyAgrees() {
        let fast = run(Self.makeSwing(loop: 0.25, frames: 40, noise: 1.5, seed: 1))
        let slow = run(Self.makeSwing(loop: 0.25, frames: 160, noise: 1.5, seed: 2))
        XCTAssertEqual(fast.offset!, slow.offset!, accuracy: 0.05)
    }

    func testOffAxisCameraIsRefused() {
        let r = run(Self.makeSwing(shoulderWidth: 0.9))
        XCTAssertEqual(r.verdict, .cannotJudge)
        XCTAssertEqual(r.refusal, .cameraOffAxis)
    }

    func testLateAddressIsMovedBackToTheStillFrame() {
        let s = Self.makeSwing(loop: 0.6, frames: 120)
        let base = run(s)
        let late = analyzer.analyze(landmarks: s.0, address: s.1 + 8, top: s.2, impact: s.3)
        XCTAssertLessThanOrEqual(late.addressFrame!, s.1)
        XCTAssertEqual(late.offset!, base.offset!, accuracy: 0.01)
    }

    func testInsideTakeawayIsNotOverTheTop() {
        let normal = run(Self.makeSwing(loop: 0)), flat = run(Self.makeSwing(loop: 0, takeaway: -0.5))
        XCTAssertGreaterThan(flat.loop!, 0.3)
        XCTAssertEqual(flat.offset!, normal.offset!, accuracy: 0.02)
        XCTAssertEqual(flat.verdict, .withinProRange)
    }

    func testCalibrationMovesTheBoundary() {
        let tight = SwingPathAnalyzer(calibration: .init(outside: 0.1, inside: -0.6, source: "test"))
        XCTAssertEqual(run(Self.makeSwing(loop: 0.4), tight).verdict, .overTheTop)
        let wide = SwingPathAnalyzer(calibration: .init(outside: 0.6, inside: -0.6, source: "test"))
        XCTAssertEqual(run(Self.makeSwing(loop: 0.4), wide).verdict, .withinProRange)
    }

    func testPoseFramesAreScaledToPixels() {
        // Same swing fed as normalised PoseFrames of a 400x400 video.
        let s = Self.makeSwing(loop: 0.6)
        let frames = s.0.enumerated().map { i, pts in
            PoseFrame(timestampSeconds: Double(i) / 30,
                      imageLandmarks: pts.map { Landmark($0.x / 400, $0.y / 400, 0, visibility: $0.visibility) },
                      worldLandmarks: nil, detectedPersonCount: 1)
        }
        let r = analyzer.analyze(frames: frames, address: Double(s.1) / 30, top: Double(s.2) / 30,
                                 impact: Double(s.3) / 30, imageWidth: 400, imageHeight: 400)
        XCTAssertEqual(r.offset!, run(s).offset!, accuracy: 1e-9)
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
    }

    func testMatchesPythonOnGolfDB() throws {
        guard let path = ProcessInfo.processInfo.environment["COACHME_PATH_PARITY"] else {
            throw XCTSkip("set COACHME_PATH_PARITY to the export_parity.py output")
        }
        let swings = try JSONDecoder().decode([Swing].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(swings.isEmpty)
        let analyzer = SwingPathAnalyzer()
        var mismatches: [String] = []
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
                || !close(r.backswingOffset, s.backswing_offset) || !close(r.loop, s.loop) {
                mismatches.append("\(s.name): swift \(r.verdict.nameZH) \(r.offset ?? .nan) \(r.refusal?.rawValue ?? "")"
                                  + " / python \(s.verdict) \(s.offset ?? .nan)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(swings.count) differ:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }
}

/// Deterministic Gaussian noise for the slow-motion test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u = max(next(), 1e-12), v = next()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}
