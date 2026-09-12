import Foundation
import CoachMeCore

/// On-disk storage. Everything stays on the device; there is no account and no
/// sync in version 1.
///
/// Layout under Application Support/CoachMe:
///   swings.json            [SwingRecord]
///   rules.json             [CoachRule]
///   videos/<uuid>.mov
///   analyses/<uuid>.json   AnalysisCache
///   chats/<uuid>.json      Conversation
final class LocalStore {

    static let shared = LocalStore()

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    let root: URL
    var videosDirectory: URL { root.appendingPathComponent("videos", isDirectory: true) }
    var analysesDirectory: URL { root.appendingPathComponent("analyses", isDirectory: true) }
    var chatsDirectory: URL { root.appendingPathComponent("chats", isDirectory: true) }
    private var swingsFile: URL { root.appendingPathComponent("swings.json") }
    private var rulesFile: URL { root.appendingPathComponent("rules.json") }

    init(root: URL? = nil) {
        let base = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoachMe", isDirectory: true)
        self.root = base
        for directory in [base, base.appendingPathComponent("videos"),
                          base.appendingPathComponent("analyses"),
                          base.appendingPathComponent("chats")] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Analyses and videos are regenerable/user content but should not be
        // uploaded to iCloud backups silently.
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = false
        _ = resource
    }

    /// Only removes a new, uncommitted import owned by the caller.
    func discardPendingImport(id: UUID, filename: String?) {
        guard !loadSwings().contains(where: { $0.id == id }) else { return }
        if let filename, filename.hasPrefix(id.uuidString + "."), !filename.contains("/") {
            try? fm.removeItem(at: videosDirectory.appendingPathComponent(filename))
        }
        try? fm.removeItem(at: analysisURL(swingID: id))
    }

    // MARK: - Swings

    func loadSwings() -> [SwingRecord] {
        (try? decoder.decode([SwingRecord].self, from: Data(contentsOf: swingsFile))) ?? []
    }

    func saveSwings(_ swings: [SwingRecord]) throws {
        try encoder.encode(swings).write(to: swingsFile, options: .atomic)
    }

    func upsert(_ swing: SwingRecord) throws {
        var all = loadSwings()
        if let index = all.firstIndex(where: { $0.id == swing.id }) {
            all[index] = swing
        } else {
            all.insert(swing, at: 0)
        }
        try saveSwings(all)
    }

    func videoURL(for swing: SwingRecord) -> URL {
        videosDirectory.appendingPathComponent(swing.videoFilename)
    }

    /// Deletes the record together with every artefact that references it, so no
    /// orphaned cache, report or conversation is left behind.
    func delete(_ swing: SwingRecord) throws {
        try? fm.removeItem(at: videoURL(for: swing))
        try? fm.removeItem(at: analysisURL(swingID: swing.id))
        try? fm.removeItem(at: conversationURL(swingID: swing.id))
        var all = loadSwings()
        all.removeAll { $0.id == swing.id }
        try saveSwings(all)
    }

    /// Removes caches, videos and chats whose swing no longer exists.
    func pruneOrphans() {
        let live = Set(loadSwings().map(\.id.uuidString))
        for directory in [analysesDirectory, chatsDirectory] {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where !live.contains(file.deletingPathExtension().lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
        let videos = (try? fm.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: nil)) ?? []
        let referenced = Set(loadSwings().map(\.videoFilename))
        for video in videos where !referenced.contains(video.lastPathComponent) {
            try? fm.removeItem(at: video)
        }
    }

    // MARK: - Analysis cache

    func analysisURL(swingID: UUID) -> URL {
        analysesDirectory.appendingPathComponent("\(swingID.uuidString).json")
    }

    func loadAnalysis(swingID: UUID) -> AnalysisCache? {
        try? decoder.decode(AnalysisCache.self, from: Data(contentsOf: analysisURL(swingID: swingID)))
    }

    func saveAnalysis(_ cache: AnalysisCache) throws {
        try encoder.encode(cache).write(to: analysisURL(swingID: cache.swingID), options: .atomic)
    }

    // MARK: - Coach rules

    func loadRules() -> [CoachRule] {
        (try? decoder.decode([CoachRule].self, from: Data(contentsOf: rulesFile))) ?? []
    }

    func saveRules(_ rules: [CoachRule]) throws {
        try encoder.encode(rules).write(to: rulesFile, options: .atomic)
    }

    // MARK: - Conversations

    func conversationURL(swingID: UUID) -> URL {
        chatsDirectory.appendingPathComponent("\(swingID.uuidString).json")
    }

    func loadConversation(swingID: UUID) -> Conversation? {
        try? decoder.decode(Conversation.self, from: Data(contentsOf: conversationURL(swingID: swingID)))
    }

    func saveConversation(_ conversation: Conversation) throws {
        try encoder.encode(conversation)
            .write(to: conversationURL(swingID: conversation.swingID), options: .atomic)
    }

    /// Copies an imported video into the store and returns its filename.
    func importVideo(from source: URL, swingID: UUID) throws -> String {
        let filename = "\(swingID.uuidString).\(source.pathExtension.isEmpty ? "mov" : source.pathExtension)"
        let destination = videosDirectory.appendingPathComponent(filename)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
        return filename
    }
}
