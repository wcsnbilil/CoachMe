import XCTest
@testable import Model
@testable import Diagnosis

/// The Swift analyzer on the committed GolfDB 400 landmarks must give the snapshot in
/// baseline/golfdb400/expected.json, which tools/baseline/regress.py writes from the Python analyzer.
final class GolfDB400RegressionTests: XCTestCase {
    struct Manifest: Decodable {
        struct Swing: Decodable {
            let name: String
            let width: Double
            let height: Double
            let frames: Int
            let events: [Int]
            let offset: Int
        }
        let xyScale: Double
        let visibilityScale: Double
        let missing: Int16
        let joints: Int
        let swings: [Swing]
    }

    struct Expected: Decodable {
        struct Clip: Decodable {
            let verdict: String
            let confidence: String?
            let offset: Double?
        }
        let clips: [String: Clip]
    }

    static let addressEvent = 1, topEvent = 4, impactEvent = 6
    static let offsetTolerance = 0.0015

    static var dataDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("baseline/golfdb400")
    }

    func testSwiftMatchesTheSnapshotOnEveryClip() throws {
        let directory = Self.dataDirectory
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("swings.json")))
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
        let raw = try Data(contentsOf: directory.appendingPathComponent("landmarks.i16"))
        let values: [Int16] = raw.withUnsafeBytes { buffer in
            (0..<raw.count / MemoryLayout<Int16>.size).map {
                Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Int16>.size, as: Int16.self))
            }
        }
        XCTAssertEqual(manifest.swings.count, expected.clips.count)

        let analyzer = SwingPathAnalyzer()
        let perPoint = 3
        var mismatches: [String] = []
        for swing in manifest.swings {
            let landmarks: [[SwingPathAnalyzer.PathPoint]] = (0..<swing.frames).map { frame in
                (0..<manifest.joints).map { joint in
                    let at = swing.offset + (frame * manifest.joints + joint) * perPoint
                    guard values[at] != manifest.missing else { return .missing }
                    return SwingPathAnalyzer.PathPoint(x: Double(values[at]) / manifest.xyScale * swing.width,
                                                       y: Double(values[at + 1]) / manifest.xyScale * swing.height,
                                                       visibility: Double(values[at + 2]) / manifest.visibilityScale)
                }
            }
            let result = analyzer.analyze(landmarks: landmarks, address: swing.events[Self.addressEvent],
                                          top: swing.events[Self.topEvent], impact: swing.events[Self.impactEvent])
            let clip = try XCTUnwrap(expected.clips[swing.name], swing.name)
            let offsetMatches: Bool
            switch (result.offset, clip.offset) {
            case (nil, nil): offsetMatches = true
            case let (mine?, theirs?): offsetMatches = abs(mine - theirs) <= Self.offsetTolerance
            default: offsetMatches = false
            }
            if result.verdict.nameZH != clip.verdict || result.confidence?.rawValue != clip.confidence || !offsetMatches {
                mismatches.append("\(swing.name): swift \(result.verdict.nameZH) \(result.confidence?.rawValue ?? "-") \(result.offset ?? .nan)"
                                  + " / 快照 \(clip.verdict) \(clip.confidence ?? "-") \(clip.offset ?? .nan)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(manifest.swings.count) 杆与快照不同:\n" + mismatches.joined(separator: "\n"))
    }
}
