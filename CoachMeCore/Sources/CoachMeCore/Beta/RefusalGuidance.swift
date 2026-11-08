import Foundation

/// Why the path check refused, grouped the way a user can act on it, with how to re-film.
public struct RefusalGuidance: Sendable, Equatable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case cameraOffLine      // 机位偏离目标线
        case trackingLost       // 手部跟踪丢失
        case wristsHidden       // 手腕可见帧太少
        case bodyNotInFrame     // 身体不完整
        case swingNotFound      // 没找到完整挥杆
    }

    public let category: Category
    public let reason: String
    public let retakeSteps: [String]

    /// Analyzer refusals plus `nil` for "no address/top/impact found".
    public static func category(for refusal: SwingPathAnalyzer.Refusal?) -> Category {
        guard let refusal else { return .swingNotFound }
        switch refusal {
        case .cameraOffAxis, .referenceNearVertical, .backswingTooSmall, .shouldersNotAboveHands, .sideUnclear:
            return .cameraOffLine
        case .trackingJumps, .downswingGap, .tooFewDownswingSamples:
            return .trackingLost
        case .wristsNotVisible:
            return .wristsHidden
        case .torsoNotVisible:
            return .bodyNotInFrame
        case .phaseOrder:
            return .swingNotFound
        }
    }

    public init(refusal: SwingPathAnalyzer.Refusal?, language: BetaLanguage) {
        let c = Self.category(for: refusal)
        category = c
        let zh = language == .zh
        switch c {
        case .cameraOffLine:
            reason = zh ? "机位偏离目标线：画面不是从球手正后方、沿目标方向拍的，肩膀和髋部看起来太宽，或镜头太高。"
                        : "The camera is off the target line: it isn't directly behind the golfer, so the shoulders and hips look too wide, or the camera is too high."
            retakeSteps = zh ? ["站到球手正后方，镜头对准目标方向", "镜头高度放在手的位置，不要俯拍", "准备姿势时两肩应该几乎重叠"]
                             : ["Stand directly behind the golfer, pointing at the target", "Hold the camera at hand height, not looking down", "At address the shoulders should almost overlap"]
        case .trackingLost:
            reason = zh ? "手部跟踪丢失：下杆有一段双手没被识别出来，或识别点乱跳。"
                        : "Hand tracking was lost: for part of the downswing the hands weren't found, or the points jumped around."
            retakeSteps = zh ? ["在光线充足的地方拍，避免逆光", "背景尽量简单，画面里只有球手一个人", "用慢动作或 60 帧录制，减少模糊"]
                             : ["Film in good light, not against the sun", "Use a plain background with only the golfer in frame", "Record in slow-mo or 60 fps to reduce blur"]
        case .wristsHidden:
            reason = zh ? "手腕可见帧太少：大部分画面里看不清双手。"
                        : "The wrists were visible in too few frames: the hands can't be seen in most of the video."
            retakeSteps = zh ? ["不要让身体或球包挡住双手", "穿和背景颜色不同的衣服、不戴深色手套", "离近一点（3–4 米），让人占画面一半高度"]
                             : ["Don't let the body or a bag block the hands", "Wear colours that stand out from the background; avoid dark gloves", "Move closer (3–4 m) so the golfer fills half the frame height"]
        case .bodyNotInFrame:
            reason = zh ? "身体不完整：准备姿势时肩膀或髋部不在画面里。"
                        : "The body isn't fully in frame: the shoulders or hips are missing at address."
            retakeSteps = zh ? ["后退一点，让头到脚和球杆都在画面里", "竖着拍，镜头对准球手中间"]
                             : ["Step back so head to feet and the club are all in frame", "Film in portrait, centred on the golfer"]
        case .swingNotFound:
            reason = zh ? "没找到一次完整挥杆：视频里缺少准备、上杆顶点或击球。"
                        : "No complete swing was found: the video is missing the address, top or impact."
            retakeSteps = zh ? ["从准备姿势开始录，到收杆后再停", "一段视频只录一次挥杆"]
                             : ["Start recording at address and stop after the finish", "One swing per video"]
        }
    }
}
