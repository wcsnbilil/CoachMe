import XCTest
@testable import Model
@testable import PhaseSegmentation

/// The Swift selector on the committed SwingNet probabilities must give the keyframes in the snapshots that the
/// Python selector writes: baseline/golfdb-split1-phases/expected.json (tools/baseline/regress_phases.py) and
/// baseline/golfdb-split1-negatives/expected.json (tools/baseline/regress_negatives.py).
final class GolfDBPhaseRegressionTests: XCTestCase {
    struct Entry: Decodable {
        let id: Int?
        let variant: String?
        let source: [Int]?
        let frames: Int
        let offset: Int

        var key: String {
            if let variant, let source { return variant + "/" + source.map(String.init).joined(separator: "+") }
            return String(id ?? -1)
        }
    }

    struct Manifest: Decodable {
        let scale: Double
        let classes: Int
        let swings: [Entry]?
        let cuts: [Entry]?
    }

    struct Expected: Decodable {
        let clips: [String: [String: Int?]]?
        let cuts: [String: [String: Int]]?
    }

    static func directory(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("baseline").appendingPathComponent(name)
    }

    func testSwiftMatchesTheSnapshotOnEveryClip() throws {
        try check("golfdb-split1-phases")
    }

    func testSwiftMatchesTheSnapshotOnEveryNegativeCut() throws {
        try check("golfdb-split1-negatives")
    }

    private func check(_ name: String) throws {
        let directory = Self.directory(name)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("swings.json")))
        let decoded = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
        let expected = decoded.clips?.mapValues { $0.compactMapValues { $0 } } ?? decoded.cuts ?? [:]
        let entries = manifest.swings ?? manifest.cuts ?? []
        let raw = try Data(contentsOf: directory.appendingPathComponent("probabilities.u16"))
        let values: [UInt16] = raw.withUnsafeBytes { buffer in
            (0..<raw.count / MemoryLayout<UInt16>.size).map {
                UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<UInt16>.size, as: UInt16.self))
            }
        }
        XCTAssertEqual(entries.count, expected.count)

        var mismatches: [String] = []
        for entry in entries {
            var selector = SwingNetEventSelector()
            for frame in 0..<entry.frames {
                let start = entry.offset + frame * manifest.classes
                let probabilities = values[start..<start + manifest.classes].map { Double($0) / manifest.scale }
                try selector.append(probabilities: probabilities, timestamp: Double(frame))
            }
            var mine: [String: Int] = [:]
            for keyframe in selector.keyframes() { mine[keyframe.phase.rawValue] = Int(keyframe.timestampSeconds) }
            let theirs = try XCTUnwrap(expected[entry.key], entry.key)
            if mine != theirs {
                mismatches.append("\(entry.key): swift \(mine.sorted { $0.value < $1.value }) / 快照 \(theirs.sorted { $0.value < $1.value })")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(entries.count) 段与快照不同:\n" + mismatches.joined(separator: "\n"))
    }
}
