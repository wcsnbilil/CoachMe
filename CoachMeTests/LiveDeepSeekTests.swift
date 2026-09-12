import XCTest
import CoachMeCore
@testable import CoachMe

/// Explicitly opt-in device verification. Ordinary test runs never call a paid API.
final class LiveDeepSeekTests: XCTestCase {
    @MainActor func testRealSavedSwingInterpretation() async throws {
        guard ProcessInfo.processInfo.environment["COACHME_LIVE_DEEPSEEK"] == "1" else {
            throw XCTSkip("Real provider test is opt-in")
        }
        let configuration = AISettingsStore.configuration
        guard configuration.provider == .deepSeek else { throw XCTSkip("DeepSeek is not selected on this device") }
        let key = AISettingsStore.key(configuration)
        guard !key.isEmpty else { throw XCTSkip("No DeepSeek credential in device Keychain") }
        var tuned = configuration
        // Verify the tuned mode using the user's selected model and endpoint.
        if tuned.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { tuned.model = "deepseek-flash" }
        tuned.deepSeekThinking = false
        let service = LLMChatService(configuration:tuned,apiKey:key)
        let store = LocalStore.shared
        let library = SwingLibrary(store:store)
        let record = try XCTUnwrap(library.swings.first { library.analysis(for:$0) != nil })
        let model = WorkbenchModel(swing:record,cache:library.analysis(for:record),videoURL:library.videoURL(for:record))
        let context = model.buildContext(rules:library.rules)
        let message = ChatMessage(role:.user,content:"请解读这次挥杆。先说明数据是否足够可靠，再给最多三项有具体数据依据的发现与练习建议。不能计算的指标请直接说明。",analysisVersion:record.analysisVersion)
        var reply: ChatMessage?
        for try await event in service.send(message:message,conversation:Conversation(swingID:record.id),context:context,
            options:ChatRequestOptions(timeout:120,maxRetries:0,contextTokenLimit:128_000)) {
            if case .finished(let value) = event { reply = value }
        }
        let answer = try XCTUnwrap(reply)
        XCTAssertGreaterThan(answer.content.count,40)
        XCTAssertFalse(answer.content.contains(key))
        // Store a review artifact locally; do not put credentials or API headers in it.
        let directory = store.root.appendingPathComponent("diagnostics",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data(answer.content.utf8).write(to:directory.appendingPathComponent("deepseek-live-answer.txt"),options:.atomic)
        let info = "provider=DeepSeek\nmodel=\(tuned.model)\nswing=\(record.id)\nframes=\(context.quality.framesAnalysed)\nanswerCharacters=\(answer.content.count)\n"
        try Data(info.utf8).write(to:directory.appendingPathComponent("deepseek-live-result.txt"),options:.atomic)
    }
}
