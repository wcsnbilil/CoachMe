import XCTest
import CoreVideo
import UIKit
import CoachMeCore
@testable import CoachMe

/// End-to-end over a real photograph: JPEG → MediaPipe → CoachMeCore metrics.
///
/// `PoseDetectorSmokeTests` only proves the SDK seam does not throw on a blank
/// frame. This proves landmarks actually come out of the model and survive the
/// conversion into CoachMeCore's types well enough to compute an angle.
///
/// The fixture (`Fixtures/pose.jpg`, from Google's MediaPipe sample assets) is a
/// standing figure with both arms extended — not a golf swing. Assertions are on
/// *structure and plausibility*, never on specific angle values: this project has
/// no ground truth for that, and inventing one would contradict the rule that
/// CoachMe never states an accuracy it has not measured.
final class PoseDetectorFixtureTests: XCTestCase {

    private func fixturePixelBuffer() throws -> CVPixelBuffer {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "pose", withExtension: "jpg"),
                                "Fixtures/pose.jpg 不在测试 bundle 中")
        let image = try XCTUnwrap(UIImage(data: try Data(contentsOf: url)))
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height

        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer),
                       kCVReturnSuccess)
        let pb = try XCTUnwrap(buffer)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                          width: width, height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    private func detectOnFixture() throws -> PoseDetectionResult {
        let detector = MediaPipePoseDetector()
        try detector.prepare()
        return try detector.detect(pixelBuffer: try fixturePixelBuffer(), timestampMilliseconds: 0)
    }

    func testModelFindsExactlyOnePersonAndAllThirtyThreeLandmarks() throws {
        let result = try detectOnFixture()
        XCTAssertEqual(result.personCount, 1, "样例图中只有一个人")
        XCTAssertEqual(result.imageLandmarks.count, PoseJoint.allCases.count,
                       "MediaPipe 关键点数量应与 PoseJoint 枚举一致")
    }

    func testImageLandmarksAreNormalisedAndWorldLandmarksExist() throws {
        let result = try detectOnFixture()
        for (i, landmark) in result.imageLandmarks.enumerated() {
            XCTAssertTrue((-0.5...1.5).contains(landmark.position.x),
                          "第 \(i) 个关键点的 x 超出归一化范围: \(landmark.position.x)")
            XCTAssertTrue((-0.5...1.5).contains(landmark.position.y),
                          "第 \(i) 个关键点的 y 超出归一化范围: \(landmark.position.y)")
        }
        let world = try XCTUnwrap(result.worldLandmarks, "未产出 world landmarks，三维指标将全部不可用")
        XCTAssertEqual(world.count, PoseJoint.allCases.count)
    }

    /// The whole point of the seam: what MediaPipe returns must be computable by
    /// CoachMeCore without any further massaging.
    func testCoachMeCoreComputesRealMetricsFromTheDetectedPose() throws {
        let result = try detectOnFixture()
        let frame = PoseFrame(timestampSeconds: 0,
                              imageLandmarks: result.imageLandmarks,
                              worldLandmarks: result.worldLandmarks,
                              detectedPersonCount: result.personCount)

        let calculator = SwingMetricsCalculator(handedness: .rightHanded, cameraView: .faceOn)
        let metrics = calculator.metrics(for: frame, address: nil)

        let elbow = metrics.outcome(.elbowInteriorAngle, .left)
        guard case .value(let degrees) = elbow else {
            return XCTFail("左肘内角应可计算，实际为 \(elbow)")
        }
        // The figure's arms are extended, so the interior elbow angle is near
        // straight. A wide band on purpose — a sanity check, not a calibration.
        XCTAssertTrue((120.0...180.0).contains(degrees),
                      "伸展手臂的肘内角应接近 180°，实际 \(degrees)")

        let torso = try XCTUnwrap(frame.torsoFrame(in: .worldEstimate3D),
                                  "躯干坐标系应可从检测结果建立")
        XCTAssertGreaterThan(torso.torsoLength, 0)
    }
}
