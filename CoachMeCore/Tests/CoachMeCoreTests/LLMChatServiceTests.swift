import XCTest
@testable import CoachMeCore

final class LLMChatServiceTests: XCTestCase {
    func context() -> SwingAnalysisContext {
        SwingAnalysisContext(swingID: UUID(),analysisVersion: 1,handedness: .rightHanded,club: .iron,
            cameraView: .faceOn,markedPhases: [],selectedPhase: nil,selectedTimestampSeconds: 1.5,
            readings: [],quality: .init(framesAnalysed: 250,framesWithNoPerson: 0,framesWithMultiplePeople: 0,
            metricsUnavailable: [],statedLimitationsZH: ["低可信度不是零"]),comparison: nil)
    }
    func config(_ provider: LLMProvider) -> LLMConfiguration {
        var c = LLMConfiguration(); c.provider = provider; c.baseURL = provider.baseURL; c.model = "test-model"; return c
    }
    func testAllProviderEndpointsAndHeaders() throws {
        for provider in [LLMProvider.openAI,.claude,.gemini,.deepSeek] {
            let service = LLMChatService(configuration: config(provider),apiKey: "test-secret")
            let req = try service.makeRequest(message: ChatMessage(role: .user,content: "分析"),
                conversation: Conversation(swingID: UUID()),context: context(),options: .init())
            XCTAssertEqual(req.httpMethod,"POST")
            XCTAssertEqual(req.url?.lastPathComponent,provider == .claude ? "messages" : "completions")
            XCTAssertEqual(req.value(forHTTPHeaderField: provider == .claude ? "x-api-key" : "Authorization"),
                           provider == .claude ? "test-secret" : "Bearer test-secret")
            XCTAssertFalse(String(decoding:req.httpBody!,as:UTF8.self).contains("test-secret"))
            if provider == .claude {
                let body = try JSONSerialization.jsonObject(with:req.httpBody!) as! [String:Any]
                XCTAssertNotNil(body["system"])
                XCTAssertEqual(body["max_tokens"] as? Int,4096)
                XCTAssertEqual(req.value(forHTTPHeaderField:"anthropic-version"),"2023-06-01")
            }
        }
    }
    func testHistoryIncludesQuestionOnceAndExcludesOfflineNotices() throws {
        var c = context(); c.analysisDetails = "全程指标没有抽样"
        let question = ChatMessage(role:.user,content:"现在的问题")
        let history = Conversation(swingID:c.swingID,messages:[
            ChatMessage(role:.user,content:"离线问题",producedWhileUnconfigured:true),
            ChatMessage(role:.system,kind:.statusNotice,content:"系统状态"),
            ChatMessage(role:.assistant,content:"之前的回答"),question])
        let req = try LLMChatService(configuration:config(.deepSeek),apiKey:"test").makeRequest(message:question,
            conversation:history,context:c,options:.init())
        let body = try JSONSerialization.jsonObject(with:req.httpBody!) as! [String:Any]
        let messages = body["messages"] as! [[String:String]]
        XCTAssertEqual(messages.filter { $0["content"] == "现在的问题" }.count,1)
        XCTAssertTrue(messages.contains { $0["content"] == "之前的回答" })
        XCTAssertFalse(messages.contains { $0["content"] == "离线问题" || $0["content"] == "系统状态" })
        XCTAssertTrue(messages.contains { $0["content"]?.contains("全程指标没有抽样") == true })
    }
    func testRejectsUnsafeOrMalformedBaseURLs() {
        for address in ["http://example.com/v1","https://user:secret@example.com/v1","https://example.com/v1?key=secret","https://example.com/v1/chat/completions"] {
            var c = config(.openAI); c.baseURL = address
            XCTAssertThrowsError(try c.endpoint())
        }
    }
    func testContextLimitIsEnforcedBeforeRequest() {
        let service = LLMChatService(configuration:config(.openAI),apiKey:"test")
        XCTAssertThrowsError(try service.makeRequest(message:.init(role:.user,content:"test"),
            conversation:.init(swingID:UUID()),context:context(),options:.init(contextTokenLimit:1)))
    }
    func testResponseParsersAndEmptyReply() throws {
        let openAI = Data(#"{"choices":[{"message":{"content":"回答"}}]}"#.utf8)
        for provider in [LLMProvider.openAI,.gemini,.deepSeek,.compatible] {
            XCTAssertEqual(try LLMChatService.decodeReply(openAI,provider:provider),"回答")
        }
        let claude = Data(#"{"content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"回答"}]}"#.utf8)
        XCTAssertEqual(try LLMChatService.decodeReply(claude,provider:.claude),"回答")
        XCTAssertThrowsError(try LLMChatService.decodeReply(Data("{}".utf8),provider:.openAI))
    }
    func testAuthenticationAndTimeoutErrorsAreActionable() async throws {
        for host in ["unauthorized.test", "timeout.test"] {
            let settings = URLSessionConfiguration.ephemeral
            settings.protocolClasses = [ChatMockProtocol.self]
            var c = config(.compatible); c.baseURL = "https://" + host + "/v1"
            let service = LLMChatService(configuration:c,apiKey:"do-not-expose",session:URLSession(configuration:settings))
            do {
                for try await _ in service.send(message:.init(role:.user,content:"test"),conversation:.init(swingID:UUID()),context:context(),options:.init()) {}
                XCTFail("Expected request failure")
            } catch let error as ChatServiceError {
                if host == "timeout.test" { XCTAssertEqual(error,.timedOut) }
                else if case .server(let status, let message) = error {
                    XCTAssertEqual(status,401); XCTAssertFalse(message.contains("do-not-expose"))
                } else { XCTFail("Expected authentication failure") }
            }
        }
    }
    func testDeepSeekModesAndStaleAnalysisHistory() throws {
        for thinking in [false,true] {
            var c = config(.deepSeek); c.deepSeekThinking = thinking
            let service = LLMChatService(configuration:c,apiKey:"test")
            let data = context()
            let old = ChatMessage(role:.assistant,content:"旧分析结论",analysisVersion:0)
            let req = try service.makeRequest(message:.init(role:.user,content:"新问题"),
                conversation:.init(swingID:data.swingID,messages:[old]),context:data,options:.init())
            let body = try JSONSerialization.jsonObject(with:req.httpBody!) as! [String:Any]
            XCTAssertEqual((body["thinking"] as? [String:String])?["type"],thinking ? "enabled" : "disabled")
            XCTAssertEqual(body["max_tokens"] as? Int,thinking ? 8192 : 2048)
            let messages = body["messages"] as! [[String:String]]
            XCTAssertFalse(messages.contains { $0["content"] == "旧分析结论" })
        }
    }

    func testActualURLSessionUsesMockTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatMockProtocol.self]
        let service = LLMChatService(configuration:config(.deepSeek),apiKey:"test",
                                     session:URLSession(configuration:configuration))
        var answer: String?
        for try await event in service.send(message:.init(role:.user,content:"test"),
            conversation:.init(swingID:UUID()),context:context(),options:.init()) {
            if case .finished(let message) = event { answer = message.content }
        }
        XCTAssertEqual(answer,"来自模拟服务的回答")
    }
}
private final class ChatMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "timeout.test" {
            client?.urlProtocol(self,didFailWithError:URLError(.timedOut)); return
        }
        let status = request.url?.host == "unauthorized.test" ? 401 : 200
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(#"{"choices":[{"message":{"content":"来自模拟服务的回答"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
