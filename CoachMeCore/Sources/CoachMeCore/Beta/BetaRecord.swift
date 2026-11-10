import Foundation

/// One analysis in the beta build's local history.
public struct BetaRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var appVersion: String
    public var build: String
    public var verdict: SwingPathAnalyzer.Verdict
    public var refusal: SwingPathAnalyzer.Refusal?
    /// Set when no complete swing was found (no analyzer refusal exists for it).
    public var swingNotFound: Bool
    public var offset: Double?
    /// Local SwingRecord holding the video; never exported.
    public var swingID: UUID?
    /// What the report draws; never exported.
    public var evidence: PathEvidence?
    /// Added in log schema 2; nil on records saved before it.
    public var video: VideoInfo?
    public var analysisMilliseconds: Int?
    /// Hardware identifier such as "iPhone15,2". Not tied to a person.
    public var deviceModel: String?
    /// Added in log schema 3: swings the quick first pass found in a long clip (nil when the clip
    /// was short enough to analyse whole) and which one was analysed, counted from 1.
    public var swingsFound: Int?
    public var swingChosen: Int?

    public init(id: UUID = UUID(), createdAt: Date = Date(), appVersion: String, build: String,
                verdict: SwingPathAnalyzer.Verdict, refusal: SwingPathAnalyzer.Refusal?, swingNotFound: Bool = false,
                offset: Double?, swingID: UUID?, evidence: PathEvidence?,
                video: VideoInfo? = nil, analysisMilliseconds: Int? = nil, deviceModel: String? = nil,
                swingsFound: Int? = nil, swingChosen: Int? = nil) {
        self.swingsFound = swingsFound; self.swingChosen = swingChosen
        self.id = id; self.createdAt = createdAt; self.appVersion = appVersion; self.build = build
        self.verdict = verdict; self.refusal = refusal; self.swingNotFound = swingNotFound
        self.offset = offset; self.swingID = swingID; self.evidence = evidence
        self.video = video; self.analysisMilliseconds = analysisMilliseconds; self.deviceModel = deviceModel
    }

    /// User-actionable refusal group (camera / tracking / wrists / body / no swing), nil when judged.
    public var refusalCategory: String? {
        guard verdict == .cannotJudge else { return nil }
        return RefusalGuidance.category(for: refusal).rawValue
    }

    /// Stable machine name of the refusal for the export.
    public var refusalCode: String? {
        if let refusal { return refusal.rawValue }
        return swingNotFound ? "swingNotFound" : nil
    }
}

/// Video properties for the test log. No pixels, no file name, no location.
public struct VideoInfo: Sendable, Codable, Equatable {
    public var durationSeconds: Double
    /// As displayed (rotation applied).
    public var width: Int
    public var height: Int
    public var frameRate: Double
    /// "HEVC", "H.264", or the raw four-character code.
    public var codec: String

    public init(durationSeconds: Double, width: Int, height: Int, frameRate: Double, codec: String) {
        self.durationSeconds = durationSeconds; self.width = width; self.height = height
        self.frameRate = frameRate; self.codec = codec
    }

    public var orientation: String {
        width > height ? "landscape" : width < height ? "portrait" : "square"
    }

    /// Maps a CoreMedia codec FourCC to a readable name.
    public static func codecName(fourCC: UInt32) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((fourCC >> $0) & 0xFF))) }
        let code = String(chars)
        switch code {
        case "hvc1", "hev1": return "HEVC"
        case "avc1", "avc3": return "H.264"
        case "ap4h", "apcn", "apcs", "apco", "ap4x": return "ProRes"
        default: return code.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// The exported test log. No video, no landmarks, no evidence drawing, nothing
/// that identifies a person: only what is needed to see whether testers come back
/// and why analyses fail.
public struct BetaExport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var time: String
        public var appVersion: String
        public var build: String
        public var deviceModel: String?
        public var verdict: String
        public var refusalReason: String?
        public var refusalCategory: String?
        public var analysisMs: Int?
        public var video: VideoInfo?
        public var swingsFound: Int?
        public var swingChosen: Int?
    }
    public var schema: Int
    public var exportedAt: String
    public var appVersion: String
    public var build: String
    public var deviceModel: String?
    public var recordCount: Int
    public var records: [Entry]

    public static let requiredEntryKeys = [
        "time", "appVersion", "build", "deviceModel", "verdict", "refusalReason", "refusalCategory", "analysisMs",
        "videoDurationSeconds", "videoWidth", "videoHeight", "videoFrameRate", "videoCodec", "videoOrientation",
        "swingsFound", "swingChosen",
    ]
    public static let requiredRootKeys = ["schema", "exportedAt", "appVersion", "build", "deviceModel", "recordCount", "records"]

    public init(records: [BetaRecord], appVersion: String, build: String, deviceModel: String? = nil, now: Date = Date()) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        schema = 3
        exportedAt = f.string(from: now)
        self.appVersion = appVersion
        self.build = build
        self.deviceModel = deviceModel
        recordCount = records.count
        self.records = records.sorted { $0.createdAt < $1.createdAt }.map {
            Entry(time: f.string(from: $0.createdAt), appVersion: $0.appVersion, build: $0.build,
                  deviceModel: $0.deviceModel, verdict: $0.verdict.rawValue, refusalReason: $0.refusalCode,
                  refusalCategory: $0.refusalCategory, analysisMs: $0.analysisMilliseconds, video: $0.video,
                  swingsFound: $0.swingsFound, swingChosen: $0.swingChosen)
        }
    }

    private static func json(_ v: Any?) -> Any { v ?? NSNull() }

    /// JSON with every key present: unknown values are written as null, never dropped,
    /// so records saved before a field existed still export with the same shape.
    public func jsonData() throws -> Data {
        var root: [String: Any] = [
            "schema": schema, "exportedAt": exportedAt, "appVersion": appVersion,
            "build": build, "deviceModel": Self.json(deviceModel), "recordCount": recordCount,
        ]
        root["records"] = records.map { e -> [String: Any] in
            [
                "time": e.time, "appVersion": e.appVersion, "build": e.build,
                "deviceModel": Self.json(e.deviceModel), "verdict": e.verdict,
                "refusalReason": Self.json(e.refusalReason), "refusalCategory": Self.json(e.refusalCategory),
                "analysisMs": Self.json(e.analysisMs),
                "videoDurationSeconds": Self.json(e.video.map { ($0.durationSeconds * 1000).rounded() / 1000 }),
                "videoWidth": Self.json(e.video?.width), "videoHeight": Self.json(e.video?.height),
                "videoFrameRate": Self.json(e.video.map { ($0.frameRate * 100).rounded() / 100 }),
                "videoCodec": Self.json(e.video?.codec), "videoOrientation": Self.json(e.video?.orientation),
                "swingsFound": Self.json(e.swingsFound), "swingChosen": Self.json(e.swingChosen),
            ]
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

/// JSON-file store for beta records.
public final class BetaRecordStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("beta_records.json")
    }

    public func load() -> [BetaRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // Default date coding keeps sub-second precision, so order survives a reload.
        let decoder = JSONDecoder()
        return ((try? decoder.decode([BetaRecord].self, from: data)) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    public func append(_ record: BetaRecord) throws {
        var all = load()
        all.append(record)
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
    }
}
