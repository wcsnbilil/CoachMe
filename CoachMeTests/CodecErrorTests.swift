import XCTest
@testable import CoachMe

/// A coach who downloads footage from the web will hit AV1 sooner or later:
/// YouTube serves it by default, and no Apple silicon before M3 can decode it.
/// The message has to name the codec and the fix, because re-shooting the swing
/// would not help and re-exporting would.
final class CodecErrorTests: XCTestCase {

    func testKnownCodecsAreNamedInPlainLanguage() {
        XCTAssertEqual(VideoReaderError.codecNameZH("av01"), "AV1")
        XCTAssertEqual(VideoReaderError.codecNameZH("vp09"), "VP9/VP8")
        XCTAssertEqual(VideoReaderError.codecNameZH("avc1"), "H.264")
        XCTAssertEqual(VideoReaderError.codecNameZH("hvc1"), "HEVC")
    }

    func testUnknownCodecFallsBackToItsRawTagRatherThanGuessing() {
        XCTAssertEqual(VideoReaderError.codecNameZH("xyzw"), "xyzw")
    }

    func testMessageNamesBothTheCodecAndTheRemedy() {
        let message = VideoReaderError.unsupportedCodec(fourCC: "av01").errorDescription ?? ""
        XCTAssertTrue(message.contains("AV1"), "应说出具体编码")
        XCTAssertTrue(message.contains("H.264"), "应给出可行的替代编码")
        XCTAssertFalse(message.contains("av01"), "不应把裸标签暴露给教练")
    }
}
