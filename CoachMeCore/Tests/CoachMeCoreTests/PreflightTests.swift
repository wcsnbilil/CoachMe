import XCTest
@testable import CoachMeCore

final class PreflightTests: XCTestCase {
    typealias P = SwingPathAnalyzer.PathPoint

    /// A golfer standing down the line: shoulders and hips nearly on top of each other, hands below the hips.
    func standing(width: Double = 0.02) -> [P] {
        var pts = [P](repeating: .missing, count: 33)
        let torso = 120.0
        pts[11] = P(x: 360 - width * torso / 2, y: 400); pts[12] = P(x: 360 + width * torso / 2, y: 400)
        pts[23] = P(x: 360 - width * torso / 2, y: 520); pts[24] = P(x: 360 + width * torso / 2, y: 520)
        pts[15] = P(x: 380, y: 600); pts[16] = P(x: 382, y: 602)
        return pts
    }

    func testSampleIndicesSpanTheClip() {
        XCTAssertEqual(Preflight.sampleIndices(frameCount: 5), [0, 1, 2, 3, 4])
        let s = Preflight.sampleIndices(frameCount: 300)
        XCTAssertEqual(s.count, Preflight.quickSamples)
        XCTAssertEqual(s.first, 0)
        XCTAssertEqual(s.last, 299)
    }

    func testQuickPassesDownTheLine() {
        let r = Preflight.quick(samples: Array(repeating: standing(), count: 16), duration: 3)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.width ?? -1, 0.02, accuracy: 1e-9)
    }

    func testQuickRefusals() {
        XCTAssertEqual(Preflight.quick(samples: Array(repeating: standing(), count: 16), duration: 0.5).reason, .duration)
        XCTAssertEqual(Preflight.quick(samples: Array(repeating: [P](repeating: .missing, count: 33), count: 16),
                                       duration: 3).reason, .person)
        var noTrunk = standing()
        for j in [11, 12, 23, 24] { noTrunk[j].visibility = 0.1 }
        XCTAssertEqual(Preflight.quick(samples: Array(repeating: noTrunk, count: 16), duration: 3).reason, .body)
        XCTAssertEqual(Preflight.quick(samples: Array(repeating: standing(width: 0.8), count: 16), duration: 3).reason, .camera)
        // one narrow standing sample is enough to leave the camera to the full rules
        var mixed = Array(repeating: standing(width: 0.8), count: 16)
        mixed[3] = standing(width: 0.3)
        XCTAssertTrue(Preflight.quick(samples: mixed, duration: 3).ok)
    }

    func testEarlySetupNeedsOrderedPhases() {
        XCTAssertEqual(Preflight.earlySetup(landmarks: [], address: 5, top: 5, impact: 9), .phaseOrder)
    }
}

/// Swift vs Python on the GolfDB fixture clips and altered copies. Skipped unless
/// COACHME_PREFLIGHT_PARITY points at tools/preflight/make_preflight_parity.py output.
final class PreflightParityTests: XCTestCase {
    struct Case: Decodable {
        let name: String
        let duration: Double
        let samples: [Int]
        let phases: [Int]
        let quick: String?
        let width: Double?
        let early: String?
        let early_frames: Int
        let landmarks: [[[Double?]]]
    }

    func testMatchesPython() throws {
        guard let path = ProcessInfo.processInfo.environment["COACHME_PREFLIGHT_PARITY"] else {
            throw XCTSkip("set COACHME_PREFLIGHT_PARITY to the make_preflight_parity.py output")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(cases.isEmpty)
        var mismatches: [String] = []
        for c in cases {
            let lm: [[SwingPathAnalyzer.PathPoint]] = c.landmarks.map { frame in
                frame.map { v in .init(x: v[0] ?? .nan, y: v[1] ?? .nan, visibility: v[2] ?? .nan) }
            }
            let idx = Preflight.sampleIndices(frameCount: lm.count)
            let q = Preflight.quick(samples: idx.map { lm[$0] }, duration: c.duration)
            let (a, t, i) = (c.phases[0], c.phases[1], c.phases[2])
            let early = i < lm.count ? Preflight.earlySetup(landmarks: lm, address: a, top: t, impact: i) : nil
            let widthOK = (q.width == nil && c.width == nil)
                || (q.width != nil && c.width != nil && abs(q.width! - c.width!) < 1e-3)
            if idx != c.samples || q.reason?.rawValue != c.quick || !widthOK || early?.rawValue != c.early
                || Preflight.earlyFrames(address: a, top: t, impact: i) != c.early_frames {
                mismatches.append("\(c.name): swift quick \(q.reason?.rawValue ?? "ok") \(q.width ?? -1) early \(early?.rawValue ?? "ok")"
                                  + " / python \(c.quick ?? "ok") \(c.width ?? -1) \(c.early ?? "ok")")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(cases.count) differ:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }
}
