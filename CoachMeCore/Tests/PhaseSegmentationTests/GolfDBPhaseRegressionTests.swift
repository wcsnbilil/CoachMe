import XCTest
@testable import Model
@testable import PhaseSegmentation

/// The Swift selector on the committed SwingNet probabilities of GolfDB split 1 must give the keyframes in
/// baseline/golfdb-split1-phases/expected.json, which tools/baseline/regress_phases.py writes from the
/// Python selector.
final class GolfDBPhaseRegressionTests: XCTestCase {
    struct Manifest: Decodable {
        struct Swing: Decodable {
            let id: Int
            let frames: Int
            let offset: Int
        }
        let scale: Double
        let classes: Int
        let swings: [Swing]
    }

    struct Expected: Decodable {
        let clips: [String: [String: Int?]]
    }

    static var dataDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("baseline/golfdb-split1-phases")
    }

    func testSwiftMatchesTheSnapshotOnEveryClip() throws {
        let directory = Self.dataDirectory
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("swings.json")))
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
        let raw = try Data(contentsOf: directory.appendingPathComponent("probabilities.u16"))
        let values: [UInt16] = raw.withUnsafeBytes { buffer in
            (0..<raw.count / MemoryLayout<UInt16>.size).map {
                UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<UInt16>.size, as: UInt16.self))
            }
        }
        XCTAssertEqual(manifest.swings.count, expected.clips.count)

        var mismatches: [String] = []
        for swing in manifest.swings {
            var selector = SwingNetEventSelector()
            for frame in 0..<swing.frames {
                let start = swing.offset + frame * manifest.classes
                let probabilities = values[start..<start + manifest.classes].map { Double($0) / manifest.scale }
                try selector.append(probabilities: probabilities, timestamp: Double(frame))
            }
            var mine: [String: Int] = [:]
            for keyframe in selector.keyframes() { mine[keyframe.phase.rawValue] = Int(keyframe.timestampSeconds) }
            let theirs = try XCTUnwrap(expected.clips[String(swing.id)], "\(swing.id)").compactMapValues { $0 }
            if mine != theirs {
                mismatches.append("\(swing.id): swift \(mine.sorted { $0.value < $1.value }) / 快照 \(theirs.sorted { $0.value < $1.value })")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(manifest.swings.count) 段与快照不同:\n" + mismatches.joined(separator: "\n"))
    }
}
