import XCTest
import AVFoundation
@testable import CoachMe

/// iPhone portrait clips store landscape pixels plus rotation metadata. The fixture is a
/// 90×160 portrait picture (blue, red square at the top-left) stored turned 90° with
/// display rotation -90, like a real iPhone file. tools/e2e/test_rotation.py checks the
/// Python readers on the same file: both sides must see 90×160 with red at the top-left.
final class RotatedVideoTests: XCTestCase {

    func testRotatedPortraitDecodesUpright() async throws {
        let url = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: "rotated_portrait", withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        let size = try await BetaAnalysisRunner.presentedSize(asset)
        XCTAssertEqual(size.width, 90, accuracy: 0.5)
        XCTAssertEqual(size.height, 160, accuracy: 0.5)

        let reader = VideoAssetReader(asset: asset)
        try await reader.start(timeRange: nil, maxDimension: 4096)
        defer { reader.cancel() }
        let frame = try XCTUnwrap(try reader.nextFrame())
        let buffer = frame.pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 90)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 160)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func bgr(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = base + y * stride + x * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        let topLeft = bgr(10, 10), bottomRight = bgr(80, 150)
        XCTAssertGreaterThan(topLeft.2, 150, "左上角应是红色：\(topLeft)")
        XCTAssertLessThan(topLeft.0, 100, "左上角应是红色：\(topLeft)")
        XCTAssertGreaterThan(bottomRight.0, 150, "右下角应是蓝色：\(bottomRight)")
    }
}
