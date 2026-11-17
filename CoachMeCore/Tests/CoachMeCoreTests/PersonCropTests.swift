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

final class PoseTrackSelectorTests: XCTestCase {
    /// A 33-point pose whose torso is centred at (x, y) with the given size.
    func pose(_ x: Double, _ y: Double, size: Double = 0.2) -> [Landmark] {
        var p = Array(repeating: Landmark(x, y, 0), count: 33)
        p[11] = Landmark(x - 0.03, y - size / 2, 0); p[12] = Landmark(x + 0.03, y - size / 2, 0)
        p[23] = Landmark(x - 0.03, y + size / 2, 0); p[24] = Landmark(x + 0.03, y + size / 2, 0)
        return p
    }

    func testKeepsTheSamePersonWhenTheOrderSwaps() {
        var sel = PoseTrackSelector()
        let golfer = pose(0.5, 0.5, size: 0.3), bystander = pose(0.15, 0.4, size: 0.1)
        XCTAssertEqual(sel.select([bystander, golfer]), 1)          // largest first
        XCTAssertEqual(sel.select([golfer, bystander]), 0)
        XCTAssertEqual(sel.select([bystander, pose(0.52, 0.5, size: 0.3)]), 1)
        XCTAssertEqual(sel.select([pose(0.53, 0.5, size: 0.3)]), 0)
        XCTAssertNil(sel.select([]))
        sel.reset()
        XCTAssertEqual(sel.select([bystander, golfer]), 1)
    }
}
