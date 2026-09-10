import XCTest
import AVFoundation
@testable import CoachMe

/// High-frame-rate footage must reach the detector at its own frame rate.
///
/// `AVVideoComposition` carries a `frameDuration`, and the composition renders
/// at exactly that cadence. If it is left at a display-oriented value, a 240 fps
/// slow-motion clip is silently decimated to 30 fps — throwing away seven of
/// every eight frames, which is the entire reason the coach shot slow motion.
///
/// This matters more than it looks: `docs/LIMITATIONS.md` §6 shows that at
/// 24 fps the rotation signal and the pose model's noise share a frequency band,
/// so adjacent swing phases cannot be told apart. Frame rate is the only lever
/// that fixes it, and a silent decimation would take the lever away.
final class HighFrameRateTests: XCTestCase {

    func testHighFrameRateSourceIsNotDecimated() async throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "fps120", withExtension: "mp4"),
                                "Fixtures/fps120.mp4 不在测试 bundle 中")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let sourceRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(Double(sourceRate), 120, accuracy: 1, "夹具本身应是 120 fps")

        let reader = VideoAssetReader(asset: asset)
        try await reader.start(timeRange: nil)
        defer { reader.cancel() }

        var count = 0
        var timestamps: [Double] = []
        while let f = try reader.nextFrame() {
            timestamps.append(f.timestampSeconds)
            count += 1
        }

        let expected = Int((Double(sourceRate) * duration).rounded())
        XCTAssertGreaterThan(Double(count), Double(expected) * 0.9,
                             "解出 \(count) 帧，源有约 \(expected) 帧——高帧率素材被抽帧了")

        // The gaps must reflect the source cadence, not a display one.
        let gaps = zip(timestamps.dropFirst(), timestamps).map { $0 - $1 }
        let median = gaps.sorted()[gaps.count / 2]
        XCTAssertEqual(median, 1.0 / Double(sourceRate), accuracy: 0.002,
                       "帧间隔中位数 \(median)s，应约为 1/\(sourceRate)s")
    }
}
