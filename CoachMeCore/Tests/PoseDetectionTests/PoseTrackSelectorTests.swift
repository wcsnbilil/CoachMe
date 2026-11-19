import XCTest
@testable import Model
@testable import PoseDetection

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
