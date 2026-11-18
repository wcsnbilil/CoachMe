import XCTest
@testable import CoachMeCore

final class PoseDisplayCompleterTests: XCTestCase {
    private func frame(_ t: Double, missing: Bool = false, count: Int = 1, dx: Double = 0) -> PoseFrame {
        let marks = (0..<33).map { j in
            Landmark(0.3+dx, 0.1+Double(j)*0.02, 0, visibility: 1, presence: 1)
        }
        return PoseFrame(timestampSeconds: t, imageLandmarks: missing ? [] : marks,
                         worldLandmarks: missing ? nil : marks, detectedPersonCount: count)
    }
    func testShortTotalLossIsInterpolatedWithoutPromotingConfidence() {
        let source = [frame(0), frame(0.1, missing: true, count: 0), frame(0.2, dx: 0.1)]
        let result = PoseDisplayCompleter().complete(source)
        XCTAssertEqual(result[1].imageLandmark(.leftKnee)!.position.x, 0.35, accuracy: 1e-6)
        XCTAssertEqual(result[1].imageLandmark(.leftKnee)?.visibility, 0)
        XCTAssertEqual(result[1].detectedPersonCount, 0)
        XCTAssertTrue(source[1].imageLandmarks.isEmpty)
        XCTAssertEqual(result[0].imageLandmarks, source[0].imageLandmarks)
    }
    func testDoesNotBorrowAcrossMultiplePeopleOrLongLoss() {
        let multi = PoseDisplayCompleter().complete([frame(0), frame(0.1, missing: true, count: 2), frame(0.2, missing: true, count: 0)])
        XCTAssertTrue(multi[1].imageLandmarks.isEmpty)
        XCTAssertTrue(multi[2].imageLandmarks.isEmpty)
        let long = PoseDisplayCompleter().complete([frame(0), frame(0.5, missing: true, count: 0), frame(1)])
        XCTAssertTrue(long[1].imageLandmarks.isEmpty)
    }
    func testAbsentLimbFollowsCurrentParentWithRecentBoneOffset() {
        let prior = frame(0)
        let moved = frame(0.2, dx: 0.1)
        var marks = moved.imageLandmarks
        marks[PoseJoint.leftKnee.rawValue] = Landmark(.nan, .nan, .nan, visibility: 0, presence: 0)
        let current = PoseFrame(timestampSeconds: 0.2, imageLandmarks: marks, worldLandmarks: nil, detectedPersonCount: 1)
        let result = PoseDisplayCompleter().complete([prior, current])
        XCTAssertEqual(result[1].imageLandmark(.leftKnee)!.position.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(result[1].imageLandmark(.leftKnee)?.visibility, 0)
    }
    func testAddressFootPriorReleasesAfterTop() {
        let start = frame(0)
        var marks = start.imageLandmarks
        marks[PoseJoint.rightAnkle.rawValue] = Landmark(0.6, 0.65, 0, visibility: 0.1, presence: 1)
        let low = [1.0, 1.5].map { PoseFrame(timestampSeconds: $0, imageLandmarks: marks, worldLandmarks: nil, detectedPersonCount: 1) }
        // Supply continuous frames so that no decoder gap crosses the stance.
        var frames = [start]
        for i in 1...15 {
            frames.append(PoseFrame(timestampSeconds: Double(i)/10, imageLandmarks: low[0].imageLandmarks,
                                    worldLandmarks: nil, detectedPersonCount: 1))
        }
        let result = PoseDisplayCompleter().complete(frames, keyframes: [Keyframe(phase: .address, timestampSeconds: 0), Keyframe(phase: .top, timestampSeconds: 1)])
        XCTAssertEqual(result[10].imageLandmark(.rightAnkle)!.position.x, 0.3, accuracy: 1e-6)
        XCTAssertEqual(result[15].imageLandmark(.rightAnkle)!.position.x, 0.6, accuracy: 1e-6)
    }
    func testWholeMissingLegCanUseContralateralBodyPrior() {
        var marks = frame(0).imageLandmarks
        for j in [25, 27, 29, 31] { marks[j] = Landmark(.nan, .nan, .nan, visibility: 0, presence: 0) }
        let input = PoseFrame(timestampSeconds: 0, imageLandmarks: marks, worldLandmarks: nil, detectedPersonCount: 1)
        let result = PoseDisplayCompleter().complete([input])[0]
        for j in [25, 27, 29, 31] {
            XCTAssertTrue(result.imageLandmarks[j].position.x.isFinite)
            XCTAssertEqual(result.imageLandmarks[j].visibility, 0)
        }
        XCTAssertEqual(result.imageLandmarks[26], marks[26])
    }

    func testEstimatedWorldBoneUsesPersonsReliableLength() {
        var frames = [frame(0), frame(0.1), frame(0.2)]
        var image = frame(0.3).imageLandmarks
        var world = image
        image[25].visibility = 0.1
        world[25] = Landmark(0.3, 1.2, 0, visibility: 0.1, presence: 1)
        frames.append(PoseFrame(timestampSeconds: 0.3, imageLandmarks: image, worldLandmarks: world, detectedPersonCount: 1))
        let result = PoseDisplayCompleter().complete(frames)
        let distance = (result[3].worldLandmark(.leftKnee)!.position-result[3].worldLandmark(.leftHip)!.position).length
        XCTAssertEqual(distance, 0.04, accuracy: 1e-6)
        XCTAssertEqual(result[3].imageLandmarks[23], image[23])
    }
}
