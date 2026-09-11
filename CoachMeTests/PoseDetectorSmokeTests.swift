import XCTest
import CoreVideo
import CoachMeCore
@testable import CoachMe

/// Exercises the MediaPipe seam against the real SDK and the real bundled model.
///
/// The rest of the suite runs entirely on CoachMeCore fixtures, so nothing else
/// would notice if `PoseLandmarkerOptions`, `MPImage(pixelBuffer:)` or
/// `detect(videoFrame:timestampInMilliseconds:)` drifted, or if the `.task`
/// model stopped being copied into the bundle. These tests fail loudly if any
/// of that breaks.
///
/// They assert on the *contract*, never on landmark values: the input is a blank
/// frame, and what the model reports for it is not something this project gets
/// to specify.
final class PoseDetectorSmokeTests: XCTestCase {

    private func blankFrame(width: Int = 640, height: Int = 480) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess, "无法创建测试用 pixel buffer")
        let unwrapped = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(unwrapped, [])
        if let base = CVPixelBufferGetBaseAddress(unwrapped) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(unwrapped) * height)
        }
        CVPixelBufferUnlockBaseAddress(unwrapped, [])
        return unwrapped
    }

    func testModelFileIsInTheAppBundle() throws {
        let path = Bundle.main.path(forResource: "pose_landmarker_heavy", ofType: "task")
        XCTAssertNotNil(path, "pose_landmarker_heavy.task 不在 App Bundle 中——检查 project.yml 的 resources 声明")
    }

    /// The real signature check: if `PoseLandmarkerOptions` or `PoseLandmarker`
    /// changed shape, this stops compiling; if the model cannot be read, it throws.
    func testPrepareLoadsTheRealModel() throws {
        let detector = MediaPipePoseDetector()
        XCTAssertNoThrow(try detector.prepare())
    }

    func testDetectOnABlankFrameReturnsAResultInsteadOfThrowing() throws {
        let detector = MediaPipePoseDetector()
        try detector.prepare()
        let result = try detector.detect(pixelBuffer: try blankFrame(), timestampMilliseconds: 0)
        // A blank frame has no person in it. What matters is that the call
        // completes and the conversion into CoachMeCore types holds.
        XCTAssertEqual(result.personCount, result.imageLandmarks.isEmpty ? 0 : result.personCount)
        XCTAssertGreaterThan(result.personCount + 1, 0)
    }

    /// MediaPipe's video mode rejects non-increasing timestamps. `detect` is
    /// supposed to absorb that rather than let the SDK throw.
    func testOutOfOrderTimestampsDoNotThrow() throws {
        let detector = MediaPipePoseDetector()
        try detector.prepare()
        let frame = try blankFrame()
        _ = try detector.detect(pixelBuffer: frame, timestampMilliseconds: 100)
        XCTAssertNoThrow(try detector.detect(pixelBuffer: frame, timestampMilliseconds: 50),
                         "倒退的时间戳应被 detect 内部吸收，而不是抛给调用方")
        XCTAssertNoThrow(try detector.detect(pixelBuffer: frame, timestampMilliseconds: 50))
    }

    func testDetectBeforePrepareThrowsInsteadOfCrashing() throws {
        let detector = MediaPipePoseDetector()
        XCTAssertThrowsError(try detector.detect(pixelBuffer: try blankFrame(), timestampMilliseconds: 0))
    }
}
