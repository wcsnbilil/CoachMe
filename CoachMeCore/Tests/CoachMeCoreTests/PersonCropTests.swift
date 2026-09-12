import XCTest
@testable import CoachMeCore
final class PersonCropTests: XCTestCase {
    func testCropIsStableBoundedAndRejectsMissingSubject() throws {
        var marks = Array(repeating:Landmark(0.4,0.5,0,visibility:1,presence:1),count:33)
        marks[0].position.y=0.2; marks[27].position.y=0.8; marks[28].position.y=0.8
        let frames = (0..<15).map { PoseFrame(timestampSeconds:Double($0)/30,imageLandmarks:marks,worldLandmarks:nil,detectedPersonCount:1) }
        let crop = try XCTUnwrap(PersonCrop.estimate(from:frames))
        XCTAssertTrue((0...1).contains(crop.x)); XCTAssertLessThanOrEqual(crop.x+crop.width,1)
        XCTAssertTrue((0...1).contains(crop.y)); XCTAssertLessThanOrEqual(crop.y+crop.height,1)
        XCTAssertGreaterThan(crop.height,0.6)
        XCTAssertNil(PersonCrop.estimate(from:Array(frames.prefix(5))))
        let missing = frames.map { PoseFrame(timestampSeconds:$0.timestampSeconds,imageLandmarks:[],worldLandmarks:nil,detectedPersonCount:0) }
        XCTAssertNil(PersonCrop.estimate(from:missing))
    }
}
