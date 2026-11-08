import XCTest
@testable import CoachMeCore

final class WorldDisplaySmootherTests: XCTestCase {
    private func frame(_ t: Double, _ z: Double, people: Int = 1, visibility: Double = 0.9, world: Bool = true) -> PoseFrame {
        let image = [Landmark(0.5,0.5,0,visibility:visibility,presence:1)]
        let worldMarks = [Landmark(0.1,-0.3,z,visibility:visibility,presence:1)]
        return PoseFrame(timestampSeconds:t,imageLandmarks:image,worldLandmarks:world ? worldMarks : nil,detectedPersonCount:people)
    }

    func testDepthJitterReducedImageAndConfidenceUntouched() {
        let input = (0..<60).map { frame(Double($0)/30, 0.2 + ($0%2 == 0 ? 0.03 : -0.03)) }
        let output = WorldDisplaySmoother().smooth(input)
        let before = input[5..<55].reduce(0.0) { $0 + abs($1.worldLandmarks![0].position.z-0.2) }
        let after = output[5..<55].reduce(0.0) { $0 + abs($1.worldLandmarks![0].position.z-0.2) }
        XCTAssertLessThan(after, before*0.35)
        for i in input.indices {
            XCTAssertEqual(output[i].imageLandmarks,input[i].imageLandmarks)
            XCTAssertEqual(output[i].worldLandmarks![0].visibility,0.9)
            XCTAssertEqual(output[i].timestampSeconds,input[i].timestampSeconds)
        }
    }

    func testConstantSpeedMotionIsNotDragged() {
        let times = [0.0,0.02,0.05,0.08,0.10,0.14,0.17,0.20]
        let input = times.map { frame($0,0.1+$0*1.5) }
        let output = WorldDisplaySmoother().smooth(input)
        for i in input.indices {
            XCTAssertEqual(output[i].worldLandmarks![0].position.z,input[i].worldLandmarks![0].position.z,accuracy:1e-8)
        }
    }

    func testNoMixingAcrossPeopleGapsMissingWorldOrInvalidPoints() {
        let input = [frame(0,0.2),frame(0.03,0.2),frame(0.06,0.8,people:2),frame(0.09,0.8),frame(0.12,0.8,world:false),
                     frame(0.15,0.5),frame(1,0.1),frame(1.03,.nan,visibility:0.1)]
        let output = WorldDisplaySmoother().smooth(input)
        for i in [0,1,2,3,5,6] {
            XCTAssertEqual(output[i].worldLandmarks![0].position.z,input[i].worldLandmarks![0].position.z,accuracy:1e-8)
        }
        XCTAssertNil(output[4].worldLandmarks, "缺失的三维数据不得被补出来")
        XCTAssertTrue(output[7].worldLandmarks![0].position.z.isNaN)
    }
}
