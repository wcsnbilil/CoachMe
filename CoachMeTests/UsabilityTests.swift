import XCTest
import AVFoundation
import CoachMeCore
@testable import CoachMe

final class UsabilityTests: XCTestCase {
    func swing(start: Double = 5, end: Double = 10) -> SwingRecord {
        SwingRecord(title: "test",videoFilename:"test.mp4",clipStartSeconds:start,clipEndSeconds:end,
                    handedness:.rightHanded,club:.iron,cameraView:.faceOn,poseModelIdentifier:"test")
    }
    @MainActor func testTrimmedPlaybackUsesSourceTimestamps() {
        let player = PlaybackController(url: URL(fileURLWithPath:"/no-video.mp4"),duration:5,startTime:5)
        XCTAssertEqual(player.currentTime,5)
        XCTAssertEqual(player.timeRange,5...10)
        player.seek(to:8.5); XCTAssertEqual(player.currentTime,8.5)
        player.seek(to:0); XCTAssertEqual(player.currentTime,5)
        player.seek(to:99); XCTAssertEqual(player.currentTime,10)
        player.step(by:-1,timestamps:[5,6,7,8,9,10]); XCTAssertEqual(player.currentTime,9)
        XCTAssertEqual(player.player.currentItem!.forwardPlaybackEndTime.seconds,10)
    }
    @MainActor func testNoStaleSkeletonOutsideAnalysisFrames() {
        let record = swing()
        let frame = PoseFrame(timestampSeconds:6,imageLandmarks:[],worldLandmarks:nil,detectedPersonCount:0)
        let cache = AnalysisCache(swingID:record.id,analysisVersion:1,algorithmVersion:"1",poseModelIdentifier:"test",createdAt:Date(),frames:[frame],smoothing:nil)
        let model = WorkbenchModel(swing:record,cache:cache,videoURL:URL(fileURLWithPath:"/no-video.mp4"))
        model.playback?.seek(to:8)
        XCTAssertNil(model.currentPoseFrame)
        XCTAssertNil(model.currentDisplayPoseFrame)
        let context = model.buildContext(rules:[])
        XCTAssertTrue(context.analysisDetails?.contains("全程指标") == true)
        XCTAssertEqual(context.quality.framesAnalysed,1)
    }
    @MainActor func testUnreviewedPhaseNamesDoNotAnchorAIContext() {
        var record = swing()
        record.keyframes = [Keyframe(phase:.top,timestampSeconds:8,markedByCoach:false)]
        let model = WorkbenchModel(swing:record,cache:nil,videoURL:URL(fileURLWithPath:"/none.mp4"))
        let context = model.buildContext(rules:[])
        XCTAssertTrue(context.markedPhases.isEmpty)
        XCTAssertTrue(context.readings.isEmpty)
        XCTAssertTrue(context.analysisDetails?.contains("8.000") == true)
        XCTAssertFalse(context.analysisDetails?.contains("\"phase\":\"top\"") == true)
        record.keyframes[0].markedByCoach = true
        let reviewed = WorkbenchModel(swing:record,cache:nil,videoURL:URL(fileURLWithPath:"/none.mp4")).buildContext(rules:[])
        XCTAssertEqual(reviewed.markedPhases,[.top])
    }
    @MainActor func testReportContextExcludesUnreviewedPhaseNames() {
        var record = swing()
        record.keyframes = [Keyframe(phase: .top, timestampSeconds: 8, markedByCoach: false),
                            Keyframe(phase: .impact, timestampSeconds: 9, markedByCoach: true)]
        let timeline = MetricTimeline(poseFrames: [], record: record)
        let context = WorkbenchModelContextShim(swing: record, timeline: timeline).build(rules: [])
        XCTAssertEqual(context.markedPhases, [.impact])
        XCTAssertFalse(context.readings.contains { $0.phase == .top })
    }

    @MainActor func testReportQuestionCarriesMetricAndSide() {
        let row = ReportRow.make(metric: .kneeInteriorAngle, side: .left, phase: .impact,
                                 time: 9, outcome: .value(145), finding: nil, handedness: .rightHanded)
        XCTAssertTrue(row.coachingQuestion.contains(SwingPhase.impact.nameZH))
        XCTAssertTrue(row.coachingQuestion.contains("引导侧"))
        XCTAssertTrue(row.coachingQuestion.contains("145.0"))
        XCTAssertTrue(row.coachingQuestion.contains(row.name))
    }

    @MainActor func testChartBreaksAtMissingAndNonfiniteReadings() {
        let points = AngleChartView.segmentedSamples([(5, 140), (5.1, 145), (5.2, nil),
                                                       (5.3, 150), (5.4, .nan), (5.5, 155)],
                                                      series: "引导臂", clipStart: 5)
        XCTAssertEqual(points[0].segment, points[1].segment)
        XCTAssertNotEqual(points[1].segment, points[3].segment)
        XCTAssertNotEqual(points[3].segment, points[5].segment)
        XCTAssertNil(points[4].value)
        XCTAssertEqual(points[0].t, 0)
    }

    func testFailedImportCleanupDoesNotDeleteSavedSwing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LocalStore(root:root)
        var record = swing()
        record.videoFilename = record.id.uuidString+".mp4"
        let file = store.videosDirectory.appendingPathComponent(record.videoFilename)
        try Data([1,2,3]).write(to:file)
        store.discardPendingImport(id:record.id,filename:record.videoFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        try Data([1,2,3]).write(to:file)
        try store.upsert(record)
        store.discardPendingImport(id:record.id,filename:record.videoFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    @MainActor func testManualMarkersMustRemainOrdered() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = SwingLibrary(store:LocalStore(root:root))
        var record = swing()
        record.keyframes = [Keyframe(phase:.address,timestampSeconds:5.5),Keyframe(phase:.impact,timestampSeconds:8)]
        let model = WorkbenchModel(swing:record,cache:nil,videoURL:URL(fileURLWithPath:"/none.mp4"))
        model.playback?.seek(to:9)
        model.markKeyframe(.top,library:library)
        XCTAssertNil(model.swing.keyframes.keyframe(for:.top))
        XCTAssertNotNil(model.phaseDetectionMessage)
    }
    @MainActor func testRetryReusesExistingQuestion() async {
        struct FailingService: ChatService {
            var isConfigured: Bool { true }
            func send(message: ChatMessage,conversation: Conversation,context:SwingAnalysisContext,options:ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent,Error> {
                AsyncThrowingStream { $0.finish(throwing:ChatServiceError.timedOut) }
            }
        }
        let record = swing()
        let context = SwingAnalysisContext(swingID:record.id,analysisVersion:1,handedness:.rightHanded,club:.iron,cameraView:.faceOn,markedPhases:[],selectedPhase:nil,selectedTimestampSeconds:nil,readings:[],quality:.init(framesAnalysed:0,framesWithNoPerson:0,framesWithMultiplePeople:0,metricsUnavailable:[],statedLimitationsZH:[]),comparison:nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = ChatModel(swing:record,phase:nil,timestamp:5,context:context,service:FailingService(),store:LocalStore(root:root))
        await model.send("问题")
        let question = model.conversation.messages.first!
        XCTAssertEqual(question.status,.failed)
        await model.retry(question)
        XCTAssertEqual(model.conversation.messages.filter { $0.role == .user }.count,1)
        XCTAssertEqual(model.conversation.messages.first?.id,question.id)
    }
}
