import Foundation
import AVFoundation
import CoreVideo

/// Decoded frame plus the timestamp everything downstream keys off.
struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    /// Presentation timestamp from the source video, in seconds. Using the real
    /// PTS (not frame index ÷ nominal fps) is what keeps variable-frame-rate
    /// video and slow-motion clips correct.
    let timestampSeconds: Double
}

enum VideoReaderError: LocalizedError {
    case noVideoTrack
    case cannotCreateReader(String)
    case readFailed(String)
    /// The container is fine but this device cannot decode the codec inside it.
    /// Worth its own case: the fix is to re-export the file, not to re-shoot it,
    /// and a generic "decode failed" sends the coach hunting for the wrong thing.
    case unsupportedCodec(fourCC: String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:               return "这个文件里没有视频轨道。"
        case .cannotCreateReader(let d):  return "无法读取视频：\(d)"
        case .readFailed(let d):          return "视频解码失败：\(d)"
        case .unsupportedCodec(let code):
            return "这段视频用的是 \(Self.codecNameZH(code)) 编码，本机无法解码。"
                + "常见于从网站下载的视频。请用 H.264（AVC）或 HEVC 重新导出后再导入。"
        }
    }

    /// Names the codecs worth naming; anything else is shown as its raw tag.
    static func codecNameZH(_ fourCC: String) -> String {
        switch fourCC {
        case "av01":                 return "AV1"
        case "vp09", "vp08":         return "VP9/VP8"
        case "avc1", "avc3":         return "H.264"
        case "hvc1", "hev1":         return "HEVC"
        default:                     return fourCC
        }
    }
}

/// Streams frames out of a video one at a time.
///
/// Two things this deliberately does:
/// - Applies the asset's preferred transform through an `AVVideoComposition`, so
///   every frame handed to the detector is **upright**. Normalised landmark
///   coordinates then line up with what the user sees, which is what makes the
///   skeleton overlay correct for portrait and landscape recordings alike.
/// - Optionally downscales. A 4K 240 fps clip decoded at full size will exhaust
///   memory; the analysis does not need full resolution.
final class VideoAssetReader {

    let asset: AVAsset
    private(set) var renderSize: CGSize = .zero
    private(set) var nominalFrameRate: Float = 0

    private var reader: AVAssetReader?
    private var output: AVAssetReaderOutput?

    init(asset: AVAsset) {
        self.asset = asset
    }

    /// - Parameters:
    ///   - timeRange: the portion the user selected for analysis.
    ///   - maxDimension: longest edge after downscaling. 720 keeps a full body in
    ///     frame well within MediaPipe's 256×256 model input.
    func start(timeRange: CMTimeRange?, maxDimension: CGFloat = 720) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoReaderError.noVideoTrack
        }

        nominalFrameRate = try await track.load(.nominalFrameRate)
        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)

        // Where the picture lands once the track's rotation/mirroring is applied.
        // preferredTransform can push content into negative coordinates, so it has
        // to be translated back to the origin before anything else happens.
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))

        var size = orientedSize
        let longest = max(orientedSize.width, orientedSize.height)
        if longest > maxDimension, longest > 0 {
            let scale = maxDimension / longest
            // Keep both dimensions even — some encoders and CV pipelines require it.
            size = CGSize(width: (orientedSize.width * scale).rounded(.down).evenised,
                          height: (orientedSize.height * scale).rounded(.down).evenised)
        }
        guard size.width >= 2, size.height >= 2 else {
            throw VideoReaderError.cannotCreateReader("视频尺寸异常：\(orientedSize)")
        }
        renderSize = size

        // videoComposition(withPropertiesOf:) supplies frameDuration and colour
        // properties. Its layer instructions are replaced below: setting
        // renderSize alone resizes the *canvas* and crops the picture to it —
        // the downscale has to be a transform on the layer, or a 4K frame is
        // delivered as a 720-pixel crop of its own top-left corner.
        let base = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        let mutableComposition = base.mutableCopy() as! AVMutableVideoComposition
        mutableComposition.renderSize = size

        // Uniform scale only. Fitting each axis independently would stretch the
        // picture, and every angle this app reports would inherit the distortion.
        let fit = min(size.width / orientedSize.width, size.height / orientedSize.height)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(
            preferred
                .concatenating(CGAffineTransform(translationX: -orientedRect.minX,
                                                 y: -orientedRect.minY))
                .concatenating(CGAffineTransform(scaleX: fit, y: fit)),
            at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layerInstruction]
        mutableComposition.instructions = [instruction]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoReaderError.cannotCreateReader(error.localizedDescription)
        }
        if let timeRange { reader.timeRange = timeRange }

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let compositionOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                                                                    videoSettings: settings)
        compositionOutput.videoComposition = mutableComposition
        // Buffers are consumed and released one at a time; copying keeps the
        // reader's internal pool from being pinned by downstream work.
        compositionOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(compositionOutput) else {
            throw VideoReaderError.cannotCreateReader("无法添加视频输出")
        }
        reader.add(compositionOutput)

        guard reader.startReading() else {
            // Ask what the codec was only once reading has actually failed, so the
            // happy path pays nothing and no codec allowlist has to be maintained.
            let descriptions = try? await track.load(.formatDescriptions)
            if let first = descriptions?.first {
                let subType = CMFormatDescriptionGetMediaSubType(first)
                let tag = String(bytes: withUnsafeBytes(of: subType.bigEndian) { Array($0) },
                                 encoding: .ascii) ?? ""
                if !tag.isEmpty {
                    throw VideoReaderError.unsupportedCodec(fourCC: tag)
                }
            }
            throw VideoReaderError.readFailed(reader.error?.localizedDescription ?? "未知错误")
        }

        self.reader = reader
        self.output = compositionOutput
    }

    /// Pulls the next frame, or nil at end of stream.
    func nextFrame() throws -> DecodedFrame? {
        guard let reader, let output else { return nil }

        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw VideoReaderError.readFailed(reader.error?.localizedDescription ?? "未知错误")
            }
            return nil
        }
        defer { CMSampleBufferInvalidate(sample) }

        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, !pts.isIndefinite else { return nil }

        return DecodedFrame(pixelBuffer: buffer, timestampSeconds: pts.seconds)
    }

    func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
    }
}

private extension CGFloat {
    var evenised: CGFloat {
        let i = Int(self)
        return CGFloat(i % 2 == 0 ? i : i - 1)
    }
}
