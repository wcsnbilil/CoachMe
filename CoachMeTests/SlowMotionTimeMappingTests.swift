import XCTest
import AVFoundation
@testable import CoachMe

/// iPhone slow motion is not simply a high-frame-rate file. The track is shot at
/// 120 or 240 fps and the container carries a time mapping that stretches it, so
/// the asset's presentation timeline runs several times longer than real time.
///
/// `AVMutableComposition.scaleTimeRange(_:toDuration:)` produces the same
/// structure, which is what this fixture builds. A plain high-frame-rate file
/// (see `HighFrameRateTests`) does not exercise this path at all.
///
/// What must hold: every source frame still reaches the detector. Timestamps are
/// allowed to be in stretched presentation time — every metric in this app is
/// computed from positions within a frame, and phases are matched on the same
/// timeline the coach scrubs — but frames must not be dropped.
final class SlowMotionTimeMappingTests: XCTestCase {

    /// Builds a 120 fps second stretched to 4 seconds, the shape of a slow-motion clip.
    private func stretchedAsset(factor: Double) async throws -> AVAsset {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "fps120", withExtension: "mp4"))
        let source = AVURLAsset(url: url)
        let tracks = try await source.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(tracks.first)
        let duration = try await source.load(.duration)

        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                  of: sourceTrack, at: .zero)
        // The time mapping: same frames, longer presentation.
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                                   toDuration: CMTimeMultiplyByFloat64(duration, multiplier: factor))
        return composition
    }

    func testStretchedClipKeepsEverySourceFrame() async throws {
        let asset = try await stretchedAsset(factor: 4)
        let stretchedDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(stretchedDuration, 4.0, accuracy: 0.2, "夹具应被拉伸到约 4 秒")

        let reader = VideoAssetReader(asset: asset)
        try await reader.start(timeRange: nil)
        defer { reader.cancel() }

        var timestamps: [Double] = []
        while let f = try reader.nextFrame() { timestamps.append(f.timestampSeconds) }

        // 1 second of 120 fps source = 120 frames, whatever the presentation length.
        XCTAssertGreaterThan(timestamps.count, 108,
                             "只解出 \(timestamps.count) 帧，120 帧的源素材在时间映射下被抽帧了")

        // Timestamps must still advance monotonically across the mapping.
        for i in 1..<timestamps.count {
            XCTAssertGreaterThanOrEqual(timestamps[i], timestamps[i - 1],
                                        "第 \(i) 帧时间戳倒退")
        }
        XCTAssertEqual(timestamps.last ?? 0, stretchedDuration, accuracy: 0.3,
                       "最后一帧应落在拉伸后的时间轴末端")
    }
}
