import XCTest
import UIKit
import AVFoundation
import Darwin
import CoachMeCore
@testable import CoachMe

/// Real video through the whole beta chain: decode → MediaPipe → SwingNet →
/// path verdict. Runs every clip in COACHME_E2E_DIR (CI sets it through
/// TEST_RUNNER_COACHME_E2E_DIR) and writes one JSON per clip to COACHME_E2E_OUT
/// with the verdict, phases, time and peak memory, for tools/e2e/compare.py.
@MainActor
final class EndToEndVideoTests: XCTestCase {

    struct ClipResult: Codable {
        var name: String
        var video: VideoInfo?
        var frames: Int
        var phases: [Int]?
        var verdict: String
        var refusal: String?
        var offset: Double?
        var analysisMs: Int
        var peakMemoryMB: Double
        var error: String?
        /// Same clip with MediaPipe asked for one person (Python's setting); clips up to 20 s only.
        var verdictOnePose: String?
        var refusalOnePose: String?
        var offsetOnePose: Double?
    }

    /// Every layer of the chain, for tools/e2e/layers.py: decoded size and timestamps, per-frame
    /// landmarks (normalised x, y, visibility), SwingNet probabilities and the phase frames.
    struct Layers: Codable {
        var name: String
        var width: Double
        var height: Double
        var nominalFPS: Double?
        var timestamps: [Double]
        var personCounts: [Int]
        var landmarks: [[[Double]]]
        var probabilities: [[Double]]
        var phases: [Int]?
        /// The phases came from the person-crop rerun (main SwingNet pass found none).
        var usedPersonCrop: Bool
    }

    func testEveryClipRunsEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["COACHME_E2E_DIR"], !dir.isEmpty else {
            throw XCTSkip("set COACHME_E2E_DIR to a folder of videos (CI does this)")
        }
        let out = URL(fileURLWithPath: env["COACHME_E2E_OUT"] ?? NSTemporaryDirectory() + "e2e-app", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let clips = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(clips.isEmpty, "\(dir) 里没有视频")

        for url in clips {
            var r = await run(url, out: out)
            if r.error == nil, let d = try? await AVURLAsset(url: url).load(.duration).seconds, d <= 20 {
                let one = await run(url, out: nil, numPoses: 1)
                r.verdictOnePose = one.verdict
                r.refusalOnePose = one.refusal
                r.offsetOnePose = one.offset
            }
            if let pattern = env["COACHME_E2E_DUMP_FRAMES"], !pattern.isEmpty,
               url.lastPathComponent.contains(pattern) {
                try await Self.dumpFrames(url, to: out.appendingPathComponent("frames/" + url.deletingPathExtension().lastPathComponent))
            }
            let data = try JSONEncoder().encode(r)
            try data.write(to: out.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json"))
            print("E2E \(r.name) frames=\(r.frames) verdict=\(r.verdict) refusal=\(r.refusal ?? "-") "
                  + "ms=\(r.analysisMs) peakMB=\(String(format: "%.0f", r.peakMemoryMB)) \(r.error ?? "")")
            XCTAssertNil(r.error, "\(r.name) 没跑通：\(r.error ?? "")")
            XCTAssertGreaterThan(r.frames, 0, "\(r.name) 没解出画面")
        }
    }

    private func run(_ url: URL, out: URL?, numPoses: Int = 2) async -> ClipResult {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)
        let sampler = PeakMemorySampler()
        sampler.start()
        let started = Date()
        do {
            let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(numPoses: numPoses),
                                         phaseDetector: SwingNetPhaseDetector())
            let frames = try await analyzer.analyse(asset: asset, timeRange: nil) { _ in }
            let keyframes = await analyzer.keyframes
            let size = try await BetaAnalysisRunner.presentedSize(asset)
            let evidence = BetaAnalysisRunner.pathEvidence(frames: frames, keyframes: keyframes,
                                                           imageWidth: size.width, imageHeight: size.height)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let peak = sampler.stop()
            func index(_ phase: SwingPhase) -> Int? {
                guard let t = keyframes.keyframe(for: phase)?.timestampSeconds else { return nil }
                return frames.indices.min { abs(frames[$0].timestampSeconds - t) < abs(frames[$1].timestampSeconds - t) }
            }
            let phases = [index(.address), index(.top), index(.impact)]
            if let out {
                let fps = try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)
                let layers = Layers(
                    name: name, width: size.width, height: size.height, nominalFPS: fps.map { Double($0) },
                    timestamps: frames.map(\.timestampSeconds), personCounts: frames.map(\.detectedPersonCount),
                    landmarks: frames.map { f in
                        f.imageLandmarks.map { l in [Self.r4(l.position.x), Self.r4(l.position.y), Self.r4(l.visibility ?? 1)] }
                    },
                    probabilities: await analyzer.phaseProbabilities.map { $0.map(Self.r4) },
                    phases: phases.contains(nil) ? nil : phases.compactMap { $0 },
                    usedPersonCrop: (await analyzer.phaseDetectionNote ?? "").contains("人物增强"))
                try? JSONEncoder().encode(layers).write(to: out.appendingPathComponent(name + ".layers.json"))
            }
            return ClipResult(name: name, video: try? await BetaAnalysisRunner.videoInfo(asset), frames: frames.count,
                              phases: phases.contains(nil) ? nil : phases.compactMap { $0 },
                              verdict: evidence.verdict.rawValue,
                              refusal: evidence.refusal?.rawValue ?? (evidence.isJudged ? nil : "swingNotFound"),
                              offset: evidence.offset, analysisMs: ms, peakMemoryMB: peak, error: nil)
        } catch {
            return ClipResult(name: name, video: nil, frames: 0, phases: nil, verdict: "error", refusal: nil, offset: nil,
                              analysisMs: Int(Date().timeIntervalSince(started) * 1000), peakMemoryMB: sampler.stop(),
                              error: String(describing: error))
        }
    }
}

extension EndToEndVideoTests {
    /// Every frame exactly as the App's pose detector receives it (same reader settings), as
    /// lossless PNG, so tools/e2e/pose_on_frames.py can run Python MediaPipe on App pixels.
    static func dumpFrames(_ url: URL, to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reader = VideoAssetReader(asset: AVURLAsset(url: url))
        try await reader.start(timeRange: nil, maxDimension: 4096)
        defer { reader.cancel() }
        var i = 0
        while let frame = try reader.nextFrame() {
            let b = frame.pixelBuffer
            CVPixelBufferLockBaseAddress(b, .readOnly)
            let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(b),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                    | CGImageAlphaInfo.noneSkipFirst.rawValue)
            let image = ctx?.makeImage()
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
            if let image, let png = UIImage(cgImage: image).pngData() {
                try png.write(to: dir.appendingPathComponent(String(format: "%05d.png", i)))
            }
            i += 1
        }
    }

    nonisolated static func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}

/// Samples the process footprint every 50 ms; `stop()` returns the peak in MB.
final class PeakMemorySampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "coachme.memory-sampler")
    private var timer: DispatchSourceTimer?
    private var peak: UInt64 = 0

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        peak = Self.footprint()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.peak = max(self.peak, Self.footprint())
        }
        t.resume()
        timer = t
    }

    func stop() -> Double {
        queue.sync {
            timer?.cancel()
            timer = nil
            peak = max(peak, Self.footprint())
        }
        return Double(peak) / 1_048_576
    }
}
