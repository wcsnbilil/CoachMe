import XCTest
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
            let r = await run(url)
            let data = try JSONEncoder().encode(r)
            try data.write(to: out.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json"))
            print("E2E \(r.name) frames=\(r.frames) verdict=\(r.verdict) refusal=\(r.refusal ?? "-") "
                  + "ms=\(r.analysisMs) peakMB=\(String(format: "%.0f", r.peakMemoryMB)) \(r.error ?? "")")
            XCTAssertNil(r.error, "\(r.name) 没跑通：\(r.error ?? "")")
            XCTAssertGreaterThan(r.frames, 0, "\(r.name) 没解出画面")
        }
    }

    private func run(_ url: URL) async -> ClipResult {
        let name = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)
        let sampler = PeakMemorySampler()
        sampler.start()
        let started = Date()
        do {
            let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(), phaseDetector: SwingNetPhaseDetector())
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
