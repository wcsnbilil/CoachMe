import Foundation

/// Stable display-oriented crop for SwingNet only. Pose measurements stay in
/// the original frame. Medians reduce the influence of waggles and bystanders.
public struct PersonCrop: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public static func estimate(from frames: [PoseFrame]) -> PersonCrop? {
        var boxes: [[Double]] = []
        let joints: [PoseJoint] = [.nose,.leftShoulder,.rightShoulder,.leftHip,.rightHip,.leftKnee,.rightKnee,.leftAnkle,.rightAnkle]
        for frame in frames where frame.detectedPersonCount == 1 {
            let positions = joints.compactMap { joint -> Vector3? in
                guard let m = frame.imageLandmark(joint), m.position.x.isFinite, m.position.y.isFinite,
                      (0...1).contains(m.position.x), (0...1).contains(m.position.y),
                      (m.presence ?? 1) >= 0.5 else { return nil }
                return m.position
            }
            guard positions.count >= 7 else { continue }
            boxes.append([positions.map(\.x).min()!,positions.map(\.y).min()!,positions.map(\.x).max()!,positions.map(\.y).max()!])
        }
        guard boxes.count >= 12 else { return nil }
        let median = (0..<4).map { j -> Double in
            let sorted = boxes.map { $0[j] }.sorted()
            return (sorted[(sorted.count-1)/2]+sorted[sorted.count/2])/2
        }
        let h = median[3]-median[1], cx = (median[0]+median[2])/2, cy = (median[1]+median[3])/2
        guard h > 0.08 else { return nil }
        let left = max(0,cx-h*0.55), right = min(1,cx+h*0.55)
        let top = max(0,cy-h*0.7), bottom = min(1,cy+h*0.7)
        guard right-left > 0.05, bottom-top > 0.05 else { return nil }
        return PersonCrop(x:left,y:top,width:right-left,height:bottom-top)
    }
}
