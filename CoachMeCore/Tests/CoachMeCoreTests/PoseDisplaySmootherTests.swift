import XCTest
@testable import CoachMeCore

final class PoseDisplaySmootherTests: XCTestCase {
    private func frame(_ t: Double, _ x: Double, people: Int = 1, visibility: Double = 0.9) -> PoseFrame {
        let marks = [Landmark(x,0.5,0,visibility:visibility,presence:1)]
        return PoseFrame(timestampSeconds:t,imageLandmarks:marks,worldLandmarks:marks,detectedPersonCount:people)
    }
    func testStationaryJitterReducedWithoutChangingConfidenceOrWorldData() {
        let input = (0..<60).map { frame(Double($0)/30, 0.5 + ($0%2 == 0 ? 0.008 : -0.008)) }
        let output = PoseDisplaySmoother().smooth(input)
        let before = input[5..<55].reduce(0.0) { $0 + abs($1.imageLandmarks[0].position.x-0.5) }
        let after = output[5..<55].reduce(0.0) { $0 + abs($1.imageLandmarks[0].position.x-0.5) }
        XCTAssertLessThan(after, before*0.35)
        for i in input.indices {
            XCTAssertEqual(output[i].worldLandmarks,input[i].worldLandmarks)
            XCTAssertEqual(output[i].imageLandmarks[0].visibility,0.9)
            XCTAssertEqual(output[i].timestampSeconds,input[i].timestampSeconds)
        }
    }
    func testFastLinearMotionPreservesPositionEvenAtBoundariesAndVariableFrameRate() {
        let times = [0.0,0.02,0.05,0.08,0.10,0.14,0.17,0.20]
        let input = times.map { frame($0,0.15+$0*2.5) }
        let output = PoseDisplaySmoother().smooth(input)
        for i in input.indices { XCTAssertEqual(output[i].imageLandmarks[0].position.x,input[i].imageLandmarks[0].position.x,accuracy:1e-8) }
    }
    func testNoSmoothingAcrossPeopleGapsOrInvalidObservations() {
        let input = [frame(0,0.2),frame(0.03,0.2),frame(0.06,0.8,people:2),frame(0.09,0.8),frame(0.12,0.8),frame(1,0.1),frame(1.03,.nan,visibility:0.1)]
        let output = PoseDisplaySmoother().smooth(input)
        for i in 0..<6 { XCTAssertEqual(output[i].imageLandmarks[0].position.x,input[i].imageLandmarks[0].position.x,accuracy:1e-8) }
        XCTAssertTrue(output[6].imageLandmarks[0].position.x.isNaN)
    }
}
