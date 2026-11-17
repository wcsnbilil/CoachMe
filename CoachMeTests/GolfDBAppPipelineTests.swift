import XCTest
import AVFoundation
import CoachMeCore
@testable import CoachMe

/// GolfDB through the App's own decode + MediaPipe (beta settings), for the App-pipeline baseline.
/// Skipped unless COACHME_GOLFDB_DIR is set (CI workflow golfdb-app.yml). Phases are GolfDB's labels,
/// so only the landmarks are written: <out>/<name>.json {width, height, landmarks [frame][33][x, y, vis]}
/// normalised; tools/e2e/golfdb_app_metrics.py turns them into run_path.py's landmark cache.
final class GolfDBAppPipelineTests: XCTestCase {

    struct Landmarks: Codable {
        var name: String
        var width: Double
        var height: Double
        var timestamps: [Double]
        var landmarks: [[[Double]]]
    }

    func testGolfDBLandmarksThroughTheAppPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["COACHME_GOLFDB_DIR"], !dir.isEmpty else {
            throw XCTSkip("set COACHME_GOLFDB_DIR (CI golfdb-app.yml does this)")
        }
        let out = URL(fileURLWithPath: env["COACHME_GOLFDB_OUT"] ?? NSTemporaryDirectory() + "golfdb-app", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let clips = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(clips.isEmpty)
        var failed: [String] = []
        let started = Date()
        for (n, url) in clips.enumerated() {
            let name = url.deletingPathExtension().lastPathComponent
            let target = out.appendingPathComponent(name + ".json")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            do {
                let asset = AVURLAsset(url: url)
                let analyzer = SwingAnalyzer(detector: MediaPipePoseDetector(numPoses: BetaAnalysisRunner.betaNumPoses))
                let frames = try await analyzer.analyse(asset: asset, timeRange: nil) { _ in }
                let size = try await BetaAnalysisRunner.presentedSize(asset)
                let r4 = { (v: Double) in (v * 10000).rounded() / 10000 }
                let row = Landmarks(name: name, width: size.width, height: size.height,
                                    timestamps: frames.map(\.timestampSeconds),
                                    landmarks: frames.map { f in
                                        f.imageLandmarks.map { [r4($0.position.x), r4($0.position.y), r4($0.visibility ?? 1)] }
                                    })
                try JSONEncoder().encode(row).write(to: target)
            } catch {
                failed.append("\(name): \(error)")
            }
            if n % 20 == 0 {
                print("GOLFDB \(n + 1)/\(clips.count) \(Int(Date().timeIntervalSince(started)))s")
            }
        }
        XCTAssertTrue(failed.isEmpty, failed.prefix(10).joined(separator: "\n"))
    }
}
