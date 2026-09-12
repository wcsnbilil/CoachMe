import SwiftUI
import AVFoundation
import Combine

/// Thin wrapper over AVPlayerLayer.
///
/// `.resizeAspect` is used so the picture is never cropped; `SkeletonOverlay`
/// compensates for the resulting letterbox using the same aspect-fit maths.
@MainActor
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Playback state shared by the video, the skeleton, the readouts and the chart,
/// so all four are driven off one clock.
@MainActor
@Observable
final class PlaybackController {
    let player: AVPlayer
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1.0

    private var timeObserver: Any?
    private let itemDuration: Double
    let startTime: Double
    let endTime: Double
    var timeRange: ClosedRange<Double> { startTime...endTime }

    /// Observer teardown, captured at init so `deinit` needs no isolated state.
    /// `deinit` is nonisolated, so it cannot touch `player` or `timeObserver`
    /// directly on a `@MainActor` class. The closure holds the player and the
    /// observer token, not `self`, so it creates no retain cycle.
    private nonisolated(unsafe) var removeObserver: (() -> Void)?

    init(url: URL, duration: Double, startTime: Double = 0) {
        player = AVPlayer(url: url)
        let start = startTime.isFinite ? max(0, startTime) : 0
        let length = duration.isFinite ? max(0.01, duration) : 0.01
        self.startTime = start
        self.endTime = start + length
        itemDuration = length
        currentTime = start
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: start + length, preferredTimescale: 600)
        player.currentItem?.reversePlaybackEndTime = CMTime(seconds: start, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        // 30 Hz UI updates: fine enough for a scrubbing readout without
        // waking the main thread on every frame of a 240 fps clip.
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, time.seconds.isFinite else { return }
            self.currentTime = min(self.endTime, max(self.startTime, time.seconds))
            if self.isPlaying && time.seconds >= self.endTime - 0.015 { self.pause() }
        }
        timeObserver = observer
        let capturedPlayer = player
        removeObserver = { capturedPlayer.removeTimeObserver(observer) }
    }

    deinit {
        removeObserver?()
    }

    var duration: Double { itemDuration }

    func play() {
        if currentTime >= endTime - 0.02 { seek(to: startTime) }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Exact seek — `zero` tolerances matter for frame stepping and for keeping
    /// the skeleton on the frame the numbers were computed from.
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = min(max(startTime, seconds), endTime)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    /// Steps by one frame using the timestamps that were actually decoded, so
    /// stepping works on variable-frame-rate footage.
    func step(by frames: Int, timestamps: [Double]) {
        guard !timestamps.isEmpty else { return }
        pause()
        let index = timestamps.enumerated()
            .min { abs($0.element - currentTime) < abs($1.element - currentTime) }?.offset ?? 0
        let target = min(max(0, index + frames), timestamps.count - 1)
        seek(to: timestamps[target])
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying { player.rate = newRate }
    }
}

/// Decodes single video frames for thumbnails, cached by file, time and size.
@MainActor
final class VideoFrameCache {
    static let shared = VideoFrameCache()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()

    func image(url: URL, time: Double, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.path)#\(time)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        guard let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else { return nil }
        let image = UIImage(cgImage: result.image)
        cache.setObject(image, forKey: key, cost: result.image.bytesPerRow * result.image.height)
        return image
    }
}

/// One frame of a video, filled into its frame; dark until decoded.
@MainActor
struct VideoFrameImage: View {
    let url: URL
    let time: Double
    var maxPixel: CGFloat = 240
    @State private var image: UIImage?

    var body: some View {
        // The colour takes the offered size; the image only fills it, so a wide
        // frame can never push a grid cell or row wider than it was given.
        CoachStyle.stage
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: "\(url.path)#\(time)") {
            let next = await VideoFrameCache.shared.image(url: url, time: time, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = next
        }
        .accessibilityHidden(true)
    }
}
