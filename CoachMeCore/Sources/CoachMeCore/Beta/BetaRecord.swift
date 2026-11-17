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

    public init(id: UUID = UUID(), createdAt: Date = Date(), appVersion: String, build: String,
                verdict: SwingPathAnalyzer.Verdict, refusal: SwingPathAnalyzer.Refusal?, swingNotFound: Bool = false,
                offset: Double?, swingID: UUID?, evidence: PathEvidence?) {
        self.id = id; self.createdAt = createdAt; self.appVersion = appVersion; self.build = build
        self.verdict = verdict; self.refusal = refusal; self.swingNotFound = swingNotFound
        self.offset = offset; self.swingID = swingID; self.evidence = evidence
    }

    /// Stable machine name of the refusal for the export.
    public var refusalCode: String? {
        if let refusal { return refusal.rawValue }
        return swingNotFound ? "swingNotFound" : nil
    }
}

/// The exported test log. No video, no landmarks, no evidence drawing: only
/// what is needed to see whether testers come back.
public struct BetaExport: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var time: String
        public var appVersion: String
        public var build: String
        public var verdict: String
        public var refusalReason: String?
    }
    public var schema: Int
    public var exportedAt: String
    public var appVersion: String
    public var build: String
    public var recordCount: Int
    public var records: [Entry]

    public static let requiredEntryKeys = ["time", "appVersion", "build", "verdict", "refusalReason"]

    public init(records: [BetaRecord], appVersion: String, build: String, now: Date = Date()) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        schema = 1
        exportedAt = f.string(from: now)
        self.appVersion = appVersion
        self.build = build
        recordCount = records.count
        self.records = records.sorted { $0.createdAt < $1.createdAt }.map {
            Entry(time: f.string(from: $0.createdAt), appVersion: $0.appVersion, build: $0.build,
                  verdict: $0.verdict.rawValue, refusalReason: $0.refusalCode)
        }
    }

    /// JSON with every key present (refusalReason is written as null, not dropped).
    public func jsonData() throws -> Data {
        var root: [String: Any] = [
            "schema": schema, "exportedAt": exportedAt, "appVersion": appVersion,
            "build": build, "recordCount": recordCount,
        ]
        root["records"] = records.map { e -> [String: Any] in
            ["time": e.time, "appVersion": e.appVersion, "build": e.build, "verdict": e.verdict,
             "refusalReason": e.refusalReason.map { $0 as Any } ?? NSNull()]
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
