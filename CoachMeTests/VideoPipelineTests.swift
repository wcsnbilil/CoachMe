import XCTest
import AVFoundation
import CoreVideo
import CoachMeCore
@testable import CoachMe

/// The real video path: file → VideoAssetReader → MediaPipe → CoachMeCore.
///
/// This is the layer that had zero coverage until 2026-09-09, and it was broken:
/// `AVMutableVideoComposition.renderSize` resizes the output *canvas* without
/// scaling the picture, so a 4K clip was delivered as a 720-pixel crop of one
/// corner. The subject fell outside every frame and the app reported
/// "未检测到人物" for footage that was perfectly good. Nothing caught it because
/// every other test either builds pixel buffers by hand or works on a still.
///
/// Fixture: `swing3s.mp4`, 3 seconds at 1280×675 trimmed from a 4096×2160 clip
/// (pexels.com/video/38025678, free licence). It is deliberately a downscale
/// case — a fixture already at the target size would not exercise the bug.
final class VideoPipelineTests: XCTestCase {

    private func fixtureAsset() throws -> AVURLAsset {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "swing3s", withExtension: "mp4"),
                                "Fixtures/swing3s.mp4 不在测试 bundle 中")
        return AVURLAsset(url: url)
    }

    @MainActor func testThirtyOriginalFramesCanBePreparedForAI() async throws {
        let asset = try fixtureAsset()
        let record = SwingRecord(title: "30-frame test", videoFilename: "swing3s.mp4",
                                 clipStartSeconds: 0, clipEndSeconds: 2.8,
                                 handedness: .rightHanded, club: .driver,
                                 cameraView: .downTheLine, poseModelIdentifier: "test")
        let images = try await AIKeyframeImages.load(swing: record, videoURL: asset.url)
        XCTAssertEqual(images.count, 30)
        XCTAssertTrue(images.allSatisfy { $0.jpegData.starts(with: [0xff, 0xd8]) })
        XCTAssertLessThanOrEqual(images.reduce(0) { $0 + $1.jpegData.count }, 16_000_000)
        XCTAssertTrue(images.allSatisfy { $0.label.contains("原视频") })
    }

    /// The regression test for the crop bug. Under the bug this was 0 of N.
    func testSubjectIsDetectedInDecodedFrames() async throws {
        let reader = VideoAssetReader(asset: try fixtureAsset())
        try await reader.start(timeRange: nil)
        defer { reader.cancel() }

        let detector = MediaPipePoseDetector()
        try detector.prepare()

        var examined = 0
        var withPerson = 0
        while let frame = try reader.nextFrame(), examined < 24 {
            let result = try detector.detect(pixelBuffer: frame.pixelBuffer,
                                             timestampMilliseconds: Int(frame.timestampSeconds * 1000))
            if result.personCount >= 1 { withPerson += 1 }
            examined += 1
        }

        XCTAssertGreaterThan(examined, 0, "没有解出任何帧")
        // The subject is in shot for the whole fixture. A crop or a botched
        // orientation transform drops this to near zero.
        XCTAssertGreaterThan(Double(withPerson) / Double(examined), 0.8,
                             "只有 \(withPerson)/\(examined) 帧检测到人——画面很可能被裁切或变换错了")
    }

    /// Non-uniform scaling would stretch the picture, and every angle the app
    /// reports would inherit the distortion.
    func testDownscalePreservesAspectRatio() async throws {
        let asset = try fixtureAsset()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let orientedRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let sourceAspect = abs(orientedRect.width) / abs(orientedRect.height)

        let reader = VideoAssetReader(asset: asset)
        try await reader.start(timeRange: nil, maxDimension: 480)
        defer { reader.cancel() }

        XCTAssertEqual(max(reader.renderSize.width, reader.renderSize.height), 480, accuracy: 2,
                       "长边应被缩到 maxDimension")
        XCTAssertEqual(reader.renderSize.width / reader.renderSize.height, sourceAspect, accuracy: 0.02,
                       "缩放后宽高比应与源一致")
    }

    /// The decoded buffer must match the size the reader advertises — the
    /// skeleton overlay maps normalised landmarks onto exactly this rectangle.
    func testDecodedBuffersMatchAdvertisedRenderSize() async throws {
        let reader = VideoAssetReader(asset: try fixtureAsset())
        try await reader.start(timeRange: nil)
        defer { reader.cancel() }

        let frame = try XCTUnwrap(try reader.nextFrame(), "没有解出第一帧")
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), Int(reader.renderSize.width))
        XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), Int(reader.renderSize.height))
    }

    /// MediaPipe's video mode rejects non-increasing timestamps, and every
    /// metric is keyed to the source presentation time.
    func testTimestampsAreNonDecreasing() async throws {
        let reader = VideoAssetReader(asset: try fixtureAsset())
        try await reader.start(timeRange: nil)
        defer { reader.cancel() }

        var last = -Double.infinity
        var count = 0
        while let frame = try reader.nextFrame(), count < 40 {
            XCTAssertGreaterThanOrEqual(frame.timestampSeconds, last,
                                        "第 \(count) 帧的时间戳倒退了")
            last = frame.timestampSeconds
            count += 1
        }
        XCTAssertGreaterThan(count, 10, "3 秒的片段应解出远超 10 帧")
    }
}
