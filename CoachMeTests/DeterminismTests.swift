import XCTest
import AVFoundation
import CryptoKit
@testable import CoachMe
import CoachMeCore

/// Does the same video give the same answer every time? Skipped unless COACHME_DETERMINISM_DIR
/// (TEST_RUNNER_COACHME_DETERMINISM_DIR) points at a folder of videos.
///
/// Per clip, COACHME_DETERMINISM_RUNS times (default 5): the beta pipeline from scratch (fresh
/// detectors, first-pass split for long clips, SwingNet, pose, path verdict), plus a hash of every
/// decoded frame the pose detector sees. Then one "lockstep" pass: two fresh detectors fed the
/// very same pixel buffers, to tell decoder differences from MediaPipe differences.
/// One JSON per clip goes to COACHME_DETERMINISM_OUT for tools/e2e/determinism.py.
@MainActor
final class DeterminismTests: XCTestCase {

    struct Run: Codable {
        var verdict: String
        var refusal: String?
        var offset: Double?
        var phases: [Int]?
        var frameHashes: [String]
        var landmarks: [[[Double]]]
        var ms: Int
    }

    struct Lockstep: Codable {
        var frames: Int
        /// Frames where the two detectors' landmarks are not identical.
        var differing: Int
        var firstDiffering: Int?
        /// Largest |a - b| over x, y (normalised) and visibility.
        var maxDifference: Double
    }

    struct Clip: Codable {
        var name: String
        var runs: [Run]
        var lockstep: Lockstep?
    }

    func testSameVideoSameAnswer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["COACHME_DETERMINISM_DIR"], !dir.isEmpty else {
            throw XCTSkip("set COACHME_DETERMINISM_DIR to a folder of videos (CI does this)")
        }
        let runs = Int(env["COACHME_DETERMINISM_RUNS"] ?? "") ?? 5
        let out = URL(fileURLWithPath: env["COACHME_DETERMINISM_OUT"] ?? NSTemporaryDirectory() + "determinism", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let clips = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(clips.isEmpty)
        for url in clips {
            let name = url.deletingPathExtension().lastPathComponent
            var clip = Clip(name: name, runs: [], lockstep: nil)
            for i in 1...runs {
                let r = try await Self.run(url)
                clip.runs.append(r)
                print("DET \(name) run=\(i) verdict=\(r.verdict) refusal=\(r.refusal ?? "-") phases=\(r.phases.map { "\($0)" } ?? "-") "
                      + "pixels=\(Self.digest(r.frameHashes)) poses=\(Self.digest(r.landmarks)) ms=\(r.ms)")
            }
            clip.lockstep = try await Self.lockstep(url)
            if let l = clip.lockstep {
                print("DET \(name) lockstep frames=\(l.frames) differing=\(l.differing) first=\(l.firstDiffering.map(String.init) ?? "-") "
                      + "max=\(l.maxDifference)")
            }
            try JSONEncoder().encode(clip).write(to: out.appendingPathComponent(name + ".json"))
            let answers = Set(clip.runs.map { "\($0.verdict)/\($0.refusal ?? "")" })
            XCTAssertEqual(answers.count, 1, "\(name): \(runs) 次结论不同 \(answers.sorted())")
        }
    }

    /// The beta pipeline as BetaAnalysisRunner.analyse runs it, minus storage and the retake stops.
    static func run(_ url: URL) async throws -> Run {
        let started = Date()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let selection = try await BetaAnalysisRunner.selectSwing(asset: asset, duration: duration)
        let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(numPoses: BetaAnalysisRunner.betaNumPoses),
                                     phaseDetector: SwingNetPhaseDetector())
        let phased = try await analyzer.phases(asset: asset, timeRange: selection?.range) { _ in }
        let frames = try await analyzer.analyse(asset: asset, timeRange: selection?.range,
                                                knownKeyframes: phased.keyframes.isEmpty ? nil : phased.keyframes) { _ in }
        let keyframes = await analyzer.keyframes
        let size = try await BetaAnalysisRunner.presentedSize(asset)
        let evidence = BetaAnalysisRunner.pathEvidence(frames: frames, keyframes: keyframes,
                                                       imageWidth: size.width, imageHeight: size.height)
        func index(_ p: SwingPhase) -> Int? {
            guard let t = keyframes.keyframe(for: p)?.timestampSeconds else { return nil }
            return frames.indices.min { abs(frames[$0].timestampSeconds - t) < abs(frames[$1].timestampSeconds - t) }
        }
        let phases = [index(.address), index(.top), index(.impact)]
        return Run(verdict: evidence.verdict.rawValue,
                   refusal: evidence.refusal?.rawValue ?? (evidence.isJudged ? nil : "swingNotFound"),
                   offset: evidence.offset, phases: phases.contains(nil) ? nil : phases.compactMap { $0 },
                   frameHashes: try await hashes(asset, range: selection?.range),
                   landmarks: frames.map { f in f.imageLandmarks.map { [$0.position.x, $0.position.y, $0.visibility ?? 1] } },
                   ms: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// SHA-256 (first 8 bytes) of every frame as the pose pass decodes it (same reader settings).
    static func hashes(_ asset: AVAsset, range: CMTimeRange?) async throws -> [String] {
        let reader = VideoAssetReader(asset: asset)
        try await reader.start(timeRange: range, maxDimension: 4096)
        defer { reader.cancel() }
        var out: [String] = []
        while let f = try reader.nextFrame() { out.append(hash(f.pixelBuffer)) }
        return out
    }

    nonisolated static func hash(_ buffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var h = SHA256()
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "none" }
        let row = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer) * 4
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            h.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * row, count: width))
        }
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Two fresh detectors, the same decoded buffers, in step.
    static func lockstep(_ url: URL) async throws -> Lockstep {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let selection = try await BetaAnalysisRunner.selectSwing(asset: asset, duration: duration)
        let a = MediaPipePoseDetector(numPoses: BetaAnalysisRunner.betaNumPoses)
        let b = MediaPipePoseDetector(numPoses: BetaAnalysisRunner.betaNumPoses)
        try a.prepare(); try b.prepare()
        let reader = VideoAssetReader(asset: asset)
        try await reader.start(timeRange: selection?.range, maxDimension: 4096)
        defer { reader.cancel() }
        var n = 0, differing = 0, first: Int?, worst = 0.0
        while let f = try reader.nextFrame() {
            let ms = Int((f.timestampSeconds * 1000).rounded())
            let ra = try a.detect(pixelBuffer: f.pixelBuffer, timestampMilliseconds: ms)
            let rb = try b.detect(pixelBuffer: f.pixelBuffer, timestampMilliseconds: ms)
            var d = ra.imageLandmarks.count == rb.imageLandmarks.count ? 0.0 : 1.0
            for (p, q) in zip(ra.imageLandmarks, rb.imageLandmarks) {
                d = max(d, abs(p.position.x - q.position.x), abs(p.position.y - q.position.y),
                        abs((p.visibility ?? 1) - (q.visibility ?? 1)))
            }
            if d > 0 { differing += 1; if first == nil { first = n } }
            worst = max(worst, d)
            n += 1
        }
        return Lockstep(frames: n, differing: differing, firstDiffering: first, maxDifference: worst)
    }

    static func digest(_ value: some Encodable) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
