import XCTest
import CoreVideo
@testable import CoachMe

final class SwingNetPhaseDetectorTests: XCTestCase {
    func testBundledModelsAcceptSingleFrameTail() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
                       kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0,
               CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        let detector = SwingNetPhaseDetector()
        try detector.prepare()
        try detector.append(pixelBuffer: frame, timestamp: 7.25)
        // All events on a single frame must not become a fake ordered swing.
        XCTAssertTrue(try detector.finish().isEmpty)
    }

    func testRGBNormalizationAndLetterbox() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 160,
                       kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<160 { for x in 0..<320 {
            let offset = y * stride + x * 4
            data[offset] = 0; data[offset + 1] = 0; data[offset + 2] = 255; data[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let input = try SwingNetPhaseDetector.normalizedInput(frame)
        XCTAssertEqual(input[80 * 160 + 80].doubleValue, (1 - 0.485) / 0.229, accuracy: 0.001)
        XCTAssertEqual(input[25600 + 80 * 160 + 80].doubleValue, -0.456 / 0.224, accuracy: 0.001)
        XCTAssertEqual(input[0].doubleValue, (124.0 / 255 - 0.485) / 0.229, accuracy: 0.001)
    }
}
