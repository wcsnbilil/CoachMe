import XCTest
@testable import CoachMeCore

final class SwingSplitterTests: XCTestCase {

    /// One synthetic swing: hands at hip height, up above the shoulders, back down, up to a finish.
    static func swing(frames n: Int = 90, offset: Double = 0) -> [[SwingPathAnalyzer.PathPoint]] {
        (0..<n).map { f in
            var pts = [SwingPathAnalyzer.PathPoint](repeating: .init(x: 0, y: 0, visibility: 0), count: 33)
            pts[11] = .init(x: 190 + offset, y: 200); pts[12] = .init(x: 210 + offset, y: 200)
            pts[23] = .init(x: 190 + offset, y: 300); pts[24] = .init(x: 210 + offset, y: 300)
            let t = Double(f)
            let y: Double
            switch f {
            case ..<20: y = 310                                   // address
            case 20..<45: y = 310 - 150 * (t - 20) / 25           // backswing
            case 45..<55: y = 160 + 150 * (t - 45) / 10           // downswing
            case 55..<70: y = 310 - 160 * (t - 55) / 15           // follow-through
            default: y = 150                                      // finish
            }
            pts[15] = .init(x: 240 + offset, y: y); pts[16] = .init(x: 244 + offset, y: y)
            return pts
        }
    }

    /// finish -> lower the club -> stand at address
    static func lowering(frames n: Int = 60) -> [[SwingPathAnalyzer.PathPoint]] {
        (0..<n).map { f in
            var pts = swing(frames: 1)[0]
            let y = 150 + 160 * min(1, Double(f) / 40)
            pts[15].y = y; pts[16].y = y
            return pts
        }
    }

    func testOneSwingIsFoundAndAnalysedWhole() {
        let found = SwingSplitter().findSwings(landmarks: Self.swing(), fps: 30)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.top ?? 0, 45, accuracy: 2)
        XCTAssertEqual(found.first?.impact ?? 0, 55, accuracy: 2)
        XCTAssertTrue(SwingSplitter.windows(found, frameCount: 90, fps: 30).isEmpty)
        XCTAssertEqual(SwingSplitter.windows(found, frameCount: 90, fps: 30, single: true).count, 1)
    }

    func testThreeSwingsGiveThreeWindowsThatDoNotOverlap() {
        let lm = Self.swing() + Self.lowering() + Self.swing() + Self.lowering() + Self.swing()
        let found = SwingSplitter().findSwings(landmarks: lm, fps: 30)
        XCTAssertEqual(found.count, 3)
        let w = SwingSplitter.windows(found, frameCount: lm.count, fps: 30)
        XCTAssertEqual(w.count, 3)
        for (a, b) in zip(w, w.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
        for (s, win) in zip(found, w) {
            XCTAssertLessThanOrEqual(win.start, s.address)
            XCTAssertGreaterThan(win.end, s.impact)
        }
    }

    func testEveryOtherFrameFindsTheSameSwings() {
        let lm = Self.swing() + Self.lowering() + Self.swing()
        let half = stride(from: 0, to: lm.count, by: 2).map { lm[$0] }
        let found = SwingSplitter().findSwings(landmarks: half, fps: 15)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Double(found[0].top) * 2, 45, accuracy: 4)
        XCTAssertEqual(Double(found[1].top) * 2, 90 + 60 + 45, accuracy: 4)
    }

    func testNoSwingInAStandingClip() {
        let lm = (0..<120).map { _ in Self.swing(frames: 1)[0] }
        XCTAssertTrue(SwingSplitter().findSwings(landmarks: lm, fps: 30).isEmpty)
    }
}

/// Swift vs Python on joined GolfDB sequences. Skipped unless COACHME_SPLIT_PARITY points at the
/// JSON written by tools/split/make_split_parity.py.
final class SwingSplitParityTests: XCTestCase {
    struct Case: Decodable {
        let name: String
        let fps: Double
        let swings: [[Int]]
        let windows: [[Int]]
        let single_windows: [[Int]]
        let joints: [Int]
        let landmarks: [[[Double?]]]
    }

    func testMatchesPython() throws {
        guard let path = ProcessInfo.processInfo.environment["COACHME_SPLIT_PARITY"] else {
            throw XCTSkip("set COACHME_SPLIT_PARITY to the make_split_parity.py output")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(cases.isEmpty)
        var mismatches: [String] = []
        for c in cases {
            let lm: [[SwingPathAnalyzer.PathPoint]] = c.landmarks.map { frame in
                var pts = [SwingPathAnalyzer.PathPoint](repeating: .missing, count: 33)
                for (j, v) in zip(c.joints, frame) {
                    pts[j] = .init(x: v[0] ?? .nan, y: v[1] ?? .nan, visibility: v[2] ?? .nan)
                }
                return pts
            }
            let found = SwingSplitter().findSwings(landmarks: lm, fps: c.fps)
            let w = SwingSplitter.windows(found, frameCount: lm.count, fps: c.fps)
            let w1 = SwingSplitter.windows(found, frameCount: lm.count, fps: c.fps, single: true)
            if found.map({ [$0.address, $0.top, $0.impact] }) != c.swings || w.map({ [$0.start, $0.end] }) != c.windows
                || w1.map({ [$0.start, $0.end] }) != c.single_windows {
                mismatches.append("\(c.name): swift \(found.map { [$0.address, $0.top, $0.impact] }) / python \(c.swings)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(cases.count) differ:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }
}
