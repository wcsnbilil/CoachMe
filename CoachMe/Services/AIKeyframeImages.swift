import AVFoundation
import UIKit
import CoachMeCore

/// Original oriented frames, never skeleton renderings. Images stay in memory.
@MainActor
enum AIKeyframeImages {
    static func load(swing: SwingRecord, videoURL: URL) async throws -> [LLMFrameImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        let targets = AIFramePlan(keyframes: swing.keyframes, start: swing.clipStartSeconds,
                                  end: swing.clipEndSeconds).samples
        guard !targets.isEmpty else { throw ChatServiceError.transport("没有可用的动作内容，请检查选段。") }
        var result: [LLMFrameImage] = []
        for target in targets {
            let time = target.timestamp, label = target.label
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
            guard let jpeg = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.8) else {
                throw ChatServiceError.transport("暂时无法准备挥杆分析，请重试。")
            }
            result.append(LLMFrameImage(jpegData: jpeg,
                label: String(format: "原视频 %.3f 秒 · %@", frame.actualTime.seconds, label)))
        }
        return result
    }
}
