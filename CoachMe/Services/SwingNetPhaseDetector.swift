import Foundation
import CoreML
import CoreVideo
import AVFoundation
import CoachMeCore

/// The official SwingNet checkpoint, split into a frame encoder and a BiLSTM.
/// Buffers at most 64 feature vectors. Frames must already be upright.
final class SwingNetPhaseDetector {
    private var encoder: MLModel?
    private var sequence: MLModel?
    private var features: [[Float]] = []
    private var timestamps: [Double] = []
    private var selector = SwingNetEventSelector()

    func prepare(bundle: Bundle = .main) throws {
        let configuration = MLModelConfiguration()
        // Float32 CPU inference is the parity baseline for the original weights.
        configuration.computeUnits = .cpuOnly
        encoder = try Self.load("SwingNetEncoder", bundle: bundle, configuration: configuration)
        sequence = try Self.load("SwingNetSequence", bundle: bundle, configuration: configuration)
        features.removeAll(keepingCapacity: true)
        timestamps.removeAll(keepingCapacity: true)
        selector = SwingNetEventSelector()
    }

    private static func load(_ name: String, bundle: Bundle,
                             configuration: MLModelConfiguration) throws -> MLModel {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw DetectionError.missingModel(name)
        }
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    func append(pixelBuffer: CVPixelBuffer, timestamp: Double) throws {
        try Task.checkCancellation()
        guard let encoder else { throw DetectionError.invalidOutput }
        let image = try Self.normalizedInput(pixelBuffer)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: image)])
        let prediction = try encoder.prediction(from: input)
        guard let vector = prediction.featureValue(for: "features")?.multiArrayValue,
              vector.count == 1280 else { throw DetectionError.invalidOutput }
        features.append((0..<1280).map { vector[$0].floatValue })
        timestamps.append(timestamp)
        if features.count == 64 { try flush() }
    }

    func finish() throws -> [Keyframe] {
        try flush()
        return selector.keyframes()
    }

    private func flush() throws {
        guard !features.isEmpty else { return }
        try Task.checkCancellation()
        guard let sequence else { throw DetectionError.invalidOutput }
        // The last chunk uses its actual length: padding changes a bidirectional LSTM.
        let input = try MLMultiArray(shape: [1, NSNumber(value: features.count), 1280], dataType: .float32)
        for t in features.indices {
            for j in 0..<1280 { input[t * 1280 + j] = NSNumber(value: features[t][j]) }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: input)])
        let prediction = try sequence.prediction(from: provider)
        guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue,
              logits.count == features.count * 9 else { throw DetectionError.invalidOutput }
        for t in features.indices {
            let row = (0..<9).map { logits[[0, NSNumber(value: t), NSNumber(value: $0)]].doubleValue }
            guard row.allSatisfy(\.isFinite), let maximum = row.max() else { throw DetectionError.invalidOutput }
            let exponents = row.map { exp($0 - maximum) }
            let total = exponents.reduce(0, +)
            try selector.append(probabilities: exponents.map { $0 / total }, timestamp: timestamps[t])
        }
        features.removeAll(keepingCapacity: true)
        timestamps.removeAll(keepingCapacity: true)
    }

    /// RGB, aspect-fit to 160 square, ImageNet mean-colour padding, then normalization.
    /// Bilinear sampling uses half-pixel centres, matching the OpenCV test pipeline.
    static func normalizedInput(_ buffer: CVPixelBuffer) throws -> MLMultiArray {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw DetectionError.invalidPixelBuffer
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw DetectionError.invalidPixelBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw DetectionError.invalidPixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { throw DetectionError.invalidPixelBuffer }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let scale = 160.0 / Double(max(width, height))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        let left = (160 - w) / 2, top = (160 - h) / 2
        let means: [Float] = [0.485, 0.456, 0.406]
        let stds: [Float] = [0.229, 0.224, 0.225]
        let padding: [Float] = [124, 116, 104] // OpenCV's rounded mean-colour border.
        let result = try MLMultiArray(shape: [1, 3, 160, 160], dataType: .float32)
        let dst = result.dataPointer.assumingMemoryBound(to: Float.self)
        for channel in 0..<3 {
            let value = (padding[channel] / 255 - means[channel]) / stds[channel]
            for i in 0..<(160 * 160) { dst[channel * 160 * 160 + i] = value }
        }
        for y in 0..<h {
            let sy = max(0, min(Double(height - 1), (Double(y) + 0.5) * Double(height) / Double(h) - 0.5))
            let y0 = Int(sy), y1 = min(y0 + 1, height - 1), fy = Float(sy - Double(y0))
            for x in 0..<w {
                let sx = max(0, min(Double(width - 1), (Double(x) + 0.5) * Double(width) / Double(w) - 0.5))
                let x0 = Int(sx), x1 = min(x0 + 1, width - 1), fx = Float(sx - Double(x0))
                for channel in 0..<3 {
                    let bgra = 2 - channel
                    let a = Float(bytes[y0 * stride + x0 * 4 + bgra])
                    let b = Float(bytes[y0 * stride + x1 * 4 + bgra])
                    let c = Float(bytes[y1 * stride + x0 * 4 + bgra])
                    let d = Float(bytes[y1 * stride + x1 * 4 + bgra])
                    let value = ((a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy).rounded()
                    dst[channel * 25600 + (y + top) * 160 + x + left] = (value / 255 - means[channel]) / stds[channel]
                }
            }
        }
        return result
    }

    enum DetectionError: LocalizedError {
        case missingModel(String), invalidOutput, invalidPixelBuffer
        var errorDescription: String? {
            switch self {
            case .missingModel(let name): return "缺少挥杆阶段模型 \(name)，请重新安装完整版本。"
            case .invalidOutput: return "挥杆阶段识别失败，请重新分析。"
            case .invalidPixelBuffer: return "无法读取挥杆阶段识别所需的画面。"
            }
        }
    }
}

/// Re-runs phase detection on a saved video without recomputing pose landmarks.
actor SavedSwingPhaseAnalysis {
    func run(url: URL) async throws -> [Keyframe] {
        let detector = SwingNetPhaseDetector()
        try detector.prepare()
        let reader = VideoAssetReader(asset: AVURLAsset(url: url))
        try await reader.start(timeRange: nil, maxDimension: 4096)
        defer { reader.cancel() }
        while let frame = try reader.nextFrame() {
            try Task.checkCancellation()
            try autoreleasepool {
                try detector.append(pixelBuffer: frame.pixelBuffer, timestamp: frame.timestampSeconds)
            }
        }
        return try detector.finish()
    }
}
