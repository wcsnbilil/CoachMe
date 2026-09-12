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
        var targets = swing.keyframes.sorted { $0.timestampSeconds < $1.timestampSeconds }.prefix(6).map {
            ($0.timestampSeconds, ($0.markedByCoach ? $0.phase.nameZH + "（已复核）" : "自动选取画面，请根据球杆和身体位置自行判断阶段，可能并非挥杆动作"))
        }
        if targets.isEmpty {
            // Uniform samples are explicitly not phase predictions.
            targets = (0..<6).map { i in
                (swing.clipStartSeconds + max(0, swing.durationSeconds - 0.05) * Double(i) / 5, "选段取样，阶段未知")
            }
        }
        var result: [LLMFrameImage] = []
        for (time, label) in targets {
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
            guard let jpeg = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.8) else {
                throw ChatServiceError.transport("无法准备动作截图，请重试。")
            }
            result.append(LLMFrameImage(jpegData: jpeg,
                label: String(format: "原视频 %.3f 秒 · %@", frame.actualTime.seconds, label)))
        }
        return result
    }
}
