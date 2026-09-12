import XCTest
@testable import CoachMeCore

final class GolfAvatarPoseTests:XCTestCase {
    func testTemplateIsCompleteFiniteAndHasFixedLimbLengths() {
        let pose=GolfAvatarPose(frame:nil)
        XCTAssertEqual(pose.joints.count,13)
        XCTAssertFalse(pose.hasObservation)
        checkLengths(pose)
        XCTAssertEqual(pose.bones.count,15)
    }
    func testMissingLegAndInvalidCoordinatesStillProduceCompleteModel() {
        var marks=Array(repeating:Landmark(.nan,.infinity,0,visibility:0,presence:0),count:33)
        for (j,p) in GolfAvatarPose.rest where j != .leftKnee && j != .leftAnkle {
            marks[j.rawValue]=Landmark(p.x,-p.y,-p.z,visibility:1,presence:1)
        }
        let frame=PoseFrame(timestampSeconds:1,imageLandmarks:[],worldLandmarks:marks,detectedPersonCount:1)
        let pose=GolfAvatarPose(frame:frame)
        XCTAssertTrue(pose.hasObservation)
        XCTAssertTrue(pose.estimated.contains(.leftAnkle))
        checkLengths(pose)
        // Input landmarks and measurement confidence remain untouched.
        XCTAssertTrue(frame.worldLandmark(.leftAnkle)!.position.x.isNaN)
    }
    func testExtremeScaleCannotStretchBodyAndMappingIsSeekOrderIndependent() {
        let marks: [Landmark] = (0..<33).map { index in
            Landmark(Double(index%3)-1,Double(index%5)*0.5-1,Double(index%7)*0.3-1,visibility:1,presence:1)
        }
        let frame=PoseFrame(timestampSeconds:2,imageLandmarks:[],worldLandmarks:marks,detectedPersonCount:1)
        let first=GolfAvatarPose(frame:frame)
        _=GolfAvatarPose(frame:nil)
        XCTAssertEqual(first.joints,GolfAvatarPose(frame:frame).joints)
        checkLengths(first)
        XCTAssertEqual((first.joints[.leftShoulder]!-first.joints[.rightShoulder]!).length,0.44,accuracy:1e-6)
        XCTAssertEqual((first.joints[.leftHip]!-first.joints[.rightHip]!).length,0.30,accuracy:1e-6)
    }
    func testMultiplePeopleFallBackToTemplate() {
        let frame=PoseFrame(timestampSeconds:1,imageLandmarks:[],worldLandmarks:[],detectedPersonCount:2)
        XCTAssertEqual(GolfAvatarPose(frame:frame).joints,GolfAvatarPose(frame:nil).joints)
    }
    private func checkLengths(_ pose:GolfAvatarPose,file:StaticString=#filePath,line:UInt=#line) {
        for (a,b,length) in GolfAvatarPose.segments {
            XCTAssertEqual((pose.joints[b]!-pose.joints[a]!).length,length,accuracy:1e-6,file:file,line:line)
        }
        XCTAssertTrue(pose.joints.values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },file:file,line:line)
    }
}
