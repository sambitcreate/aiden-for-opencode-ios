import Foundation
import XCTest
@testable import AidenForOpenCode

/// Unit tests for the V2 chat mapping and event-application logic. Every case
/// constructs real transport DTOs — no URL or client mocks.
final class AidenChatTests: XCTestCase {
    // MARK: - Event routing

    func testSessionIDRoutingCoversSessionScopedPayloads() {
        let sessionID = "ses_1"
        XCTAssertEqual(TextDeltaEventData(
            timestamp: 1, sessionID: sessionID, assistantMessageID: "msg", textID: "t1", delta: "a"
        ).sessionID, sessionID)
        XCTAssertEqual(StepStartedEventData(
            timestamp: 1, sessionID: sessionID, assistantMessageID: "msg", agent: "build", model: Self.modelRef, snapshot: nil
        ).sessionID, sessionID)
        XCTAssertEqual(PermissionRequest(
            id: "perm_1", sessionID: sessionID, action: "edit",
            resources: ["/tmp/x"], save: nil, metadata: nil, source: nil
        ).sessionID, sessionID)
        XCTAssertEqual(QuestionRequest(id: "q_1", sessionID: sessionID, questions: [], tool: nil).sessionID, sessionID)
        XCTAssertEqual(TodoUpdatedEventData(sessionID: sessionID, todos: []).sessionID, sessionID)
    }

    func testSessionIDExtractionFromTypedEventData() {
        let sessionID = "ses_route"
        func data(_ event: OpenCodeEventData) -> String? {
            event.aidenSessionID
        }

        XCTAssertEqual(data(.textDelta(Self.textDelta(sessionID))), sessionID)
        XCTAssertEqual(data(.stepEnded(Self.stepEnded(sessionID))), sessionID)
        XCTAssertEqual(data(.permissionAsked(Self.permissionRequest(sessionID))), sessionID)
        XCTAssertEqual(data(.questionRejected(QuestionRejectedEventData(sessionID: sessionID, requestID: "q"))), sessionID)

        // Global or unscoped payloads never claim a session.
        XCTAssertNil(data(.serverConnected))
        XCTAssertNil(data(.fileEdited(FileEditedEventData(file: "/tmp/a"))))
        XCTAssertNil(data(.unknown(.object(["anything": .int(1)]))))
    }

    func testDurableBoundaryClassificationExcludesLiveOnlyDeltas() {
        XCTAssertTrue(OpenCodeEventData.stepStarted(Self.stepStarted("s")).isDurableBoundaryEvent)
        XCTAssertTrue(OpenCodeEventData.compactionEnded(Self.compactionEnded("s")).isDurableBoundaryEvent)
        XCTAssertFalse(OpenCodeEventData.textDelta(Self.textDelta("s")).isDurableBoundaryEvent)
        XCTAssertFalse(OpenCodeEventData.reasoningDelta(ReasoningDeltaEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "m", reasoningID: "r", delta: "x"
        )).isDurableBoundaryEvent)
        XCTAssertFalse(OpenCodeEventData.toolInputDelta(ToolInputDeltaEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "m", callID: "c", delta: "{"
        )).isDurableBoundaryEvent)
    }

    // MARK: - Live turn accumulator

    func testLiveTurnAccumulatesTextDeltasAndFinalizesOnEnd() {
        var turn = AidenLiveTurn()
        turn.apply(.stepStarted(Self.stepStarted("s")))
        turn.apply(.textStarted(TextStartedEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", textID: "t1"
        )))
        turn.apply(.textDelta(Self.textDelta("s", delta: "Hello")))
        turn.apply(.textDelta(Self.textDelta("s", delta: ", world")))
        XCTAssertEqual(turn.liveText, "Hello, world")
        XCTAssertTrue(turn.isStepActive)
        XCTAssertEqual(turn.assistantMessageID, "asst")

        turn.apply(.textEnded(TextEndedEventData(
            timestamp: 2, sessionID: "s", assistantMessageID: "asst", textID: "t1", text: "Hello, world!"
        )))
        XCTAssertEqual(turn.liveText, "Hello, world!")

        turn.apply(.stepEnded(Self.stepEnded("s")))
        XCTAssertFalse(turn.isStepActive)
        // Ended text survives step end until reconciliation replaces it.
        XCTAssertEqual(turn.liveText, "Hello, world!")
    }

    func testLiveTurnKeepsMultipleTextSegmentsInArrivalOrder() {
        var turn = AidenLiveTurn()
        turn.apply(.textDelta(Self.textDelta("s", delta: "one ")))
        turn.apply(.textStarted(TextStartedEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", textID: "t2"
        )))
        turn.apply(.textDelta(TextDeltaEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", textID: "t2", delta: "two"
        )))
        XCTAssertEqual(turn.liveText, "one two")
    }

    func testLiveTurnReasoningSegmentsFinalizeIndependentlyOfText() {
        var turn = AidenLiveTurn()
        turn.apply(.reasoningStarted(ReasoningStartedEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", reasoningID: "r1", providerMetadata: nil
        )))
        turn.apply(.reasoningDelta(ReasoningDeltaEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", reasoningID: "r1", delta: "pondering"
        )))
        turn.apply(.textDelta(Self.textDelta("s", delta: "answer")))
        XCTAssertEqual(turn.liveReasoning, "pondering")
        XCTAssertEqual(turn.liveText, "answer")

        turn.apply(.reasoningEnded(ReasoningEndedEventData(
            timestamp: 2, sessionID: "s", assistantMessageID: "asst", reasoningID: "r1",
            text: "Pondering deeply.", providerMetadata: nil
        )))
        XCTAssertEqual(turn.liveReasoning, "Pondering deeply.")
        XCTAssertEqual(turn.liveText, "answer")
    }

    func testLiveTurnToolLifecycleTracksPhaseAndInputTail() {
        var turn = AidenLiveTurn()
        turn.apply(.toolInputStarted(ToolInputStartedEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", callID: "call_1", name: "bash"
        )))
        XCTAssertEqual(turn.tools.first?.phase, .preparing)

        turn.apply(.toolInputDelta(ToolInputDeltaEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", callID: "call_1", delta: "{\"command\":"
        )))
        turn.apply(.toolInputDelta(ToolInputDeltaEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", callID: "call_1", delta: "\"ls\"}"
        )))
        XCTAssertEqual(turn.tools.first?.inputTail, #"{"command":"ls"}"#)

        turn.apply(.toolCalled(ToolCalledEventData(
            timestamp: 2, sessionID: "s", assistantMessageID: "asst", callID: "call_1",
            tool: "bash", input: ["command": .string("ls -la")], provider: ToolProviderInfo(executed: true, metadata: nil)
        )))
        XCTAssertEqual(turn.tools.first?.phase, .running)
        XCTAssertEqual(turn.tools.first?.previewLine, "command: ls -la")
        XCTAssertTrue(turn.hasRunningTool)

        turn.apply(.toolSuccess(ToolSuccessEventData(
            timestamp: 3, sessionID: "s", assistantMessageID: "asst", callID: "call_1",
            structured: [:], content: [.text(text: "total 0")],
            outputPaths: nil, result: nil,
            provider: ToolProviderInfo(executed: true, metadata: nil)
        )))
        XCTAssertEqual(turn.tools.first?.phase, .completed)
        XCTAssertEqual(turn.tools.first?.detail, "total 0")
        XCTAssertFalse(turn.hasRunningTool)
    }

    func testLiveTurnToolFailureCarriesErrorMessage() throws {        var turn = AidenLiveTurn()
        turn.apply(.toolCalled(ToolCalledEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", callID: "call_x",
            tool: "read", input: [:], provider: ToolProviderInfo(executed: false, metadata: nil)
        )))
        turn.apply(.toolFailed(ToolFailedEventData(
            timestamp: 2, sessionID: "s", assistantMessageID: "asst", callID: "call_x",
            error: UnknownErrorValue(message: "File not found"), result: nil,
            provider: ToolProviderInfo(executed: false, metadata: nil)
        )))
        let tool = try XCTUnwrap(turn.tools.first)
        XCTAssertEqual(tool.phase, .failed)
        XCTAssertEqual(tool.errorMessage, "File not found")
    }

    func testLiveTurnStepFailureRecordsErrorAndDeactivatesStep() throws {
        var turn = AidenLiveTurn()
        turn.apply(.stepStarted(Self.stepStarted("s")))
        turn.apply(.stepFailed(StepFailedEventData(
            timestamp: 2, sessionID: "s", assistantMessageID: "asst",
            error: UnknownErrorValue(message: "provider exploded")
        )))
        XCTAssertFalse(turn.isStepActive)
        XCTAssertEqual(turn.failureMessage, "provider exploded")
        XCTAssertFalse(turn.isEmpty)
    }

    func testLiveTurnIgnoresUnrelatedPayloads() {
        var turn = AidenLiveTurn()
        turn.apply(.serverConnected)
        turn.apply(.todoUpdated(TodoUpdatedEventData(sessionID: "s", todos: [])))
        turn.apply(.unknown(.string("mystery")))
        XCTAssertTrue(turn.isEmpty)
    }

    func testLiveTurnInputTailIsBounded() throws {        var turn = AidenLiveTurn()
        turn.apply(.toolInputStarted(ToolInputStartedEventData(
            timestamp: 1, sessionID: "s", assistantMessageID: "asst", callID: "c", name: "write"
        )))
        let chunk = String(repeating: "x", count: 100)
        for _ in 0..<10 {
            turn.apply(.toolInputDelta(ToolInputDeltaEventData(
                timestamp: 1, sessionID: "s", assistantMessageID: "asst", callID: "c", delta: chunk
            )))
        }
        let tail = try XCTUnwrap(turn.tools.first?.inputTail)
        XCTAssertLessThanOrEqual(tail.count, AidenToolActivity.inputTailLimit + 1)
        XCTAssertTrue(tail.hasPrefix("…"))
    }

    // MARK: - Wire message mapping

    func testAssistantMessageBlocksPreserveContentOrder() throws {        let content: [AssistantContent] = [
            .reasoning(AssistantReasoningContent(id: "r1", text: "think", providerMetadata: nil, time: nil)),
            .tool(AssistantToolPart(
                id: "call_1", name: "bash", provider: nil,
                state: .completed(input: [:], attachments: nil, content: [], outputPaths: nil, structured: [:], result: nil),
                time: ToolPartTiming(created: 0, ran: nil, completed: nil, pruned: nil)
            )),
            .text(AssistantTextContent(id: "t1", text: "**done**")),
        ]
        let rows = AidenTimelineMapper.rows(from: [.assistant(AssistantMessage(
            id: "asst", metadata: nil, agent: "build", model: Self.modelRef,
            content: content, snapshot: nil, finish: "stop", cost: nil, tokens: nil,
            error: nil, time: MessageSpanTime(created: 1_000, completed: 2_000)
        ))])

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.role, .assistant)
        XCTAssertEqual(row.blocks.count, 3)
        guard case .reasoning(let reasoningID, _) = row.blocks[0],
              case .tool(let activity) = row.blocks[1],
              case .text(let text) = row.blocks[2] else {
            return XCTFail("Unexpected block order: \(row.blocks)")
        }
        XCTAssertEqual(reasoningID, "r1")
        XCTAssertEqual(activity.callID, "call_1")
        XCTAssertEqual(activity.phase, .completed)
        XCTAssertEqual(text, "**done**")
    }

    func testUserCompactionSystemAndSwitchMessagesMapToExpectedRows() {
        let messages: [OCMessage] = [
            .user(UserMessage(
                id: "u1", metadata: nil, time: MessageCreatedTime(created: 5_000),
                text: "hi", files: nil, agents: nil
            )),
            .compaction(CompactionMessage(
                id: "cmp1", metadata: nil, time: MessageCreatedTime(created: 6_000),
                reason: .manual, summary: "s", recent: "r"
            )),
            .shell(ShellMessage(
                id: "sh1", metadata: nil, time: MessageSpanTime(created: 7_000, completed: 7_500),
                callID: "c", command: "bun test", output: "ok"
            )),
            .agentSwitched(AgentSwitchedMessage(
                id: "ag1", metadata: nil, time: MessageCreatedTime(created: 8_000), agent: "review"
            )),
            .modelSwitched(ModelSwitchedMessage(
                id: "mo1", metadata: nil, time: MessageCreatedTime(created: 9_000), model: Self.modelRef
            )),
            .unrecognized(type: "from-the-future"),
        ]

        let rows = AidenTimelineMapper.rows(from: messages)
        XCTAssertEqual(rows.map(\.id), ["u1", "cmp1", "sh1", "ag1", "mo1"])
        XCTAssertEqual(rows[0].role, .user)
        XCTAssertEqual(rows[0].userText, "hi")
        XCTAssertEqual(rows[1].role, .divider)
        XCTAssertEqual(rows[2].role, .system)
        XCTAssertEqual(rows[3].text, "Agent switched to review")
        XCTAssertEqual(rows[4].text, "Model switched to anthropic/claude-sonnet-4")
    }

    func testEpochMillisecondsConvertToDates() {
        let info = SessionInfo(
            id: "ses_t", parentID: nil, projectID: "p", agent: nil, model: nil,
            cost: 0, tokens: TokenUsage(input: 0, output: 0, reasoning: 0, cache: TokenCacheUsage(read: 0, write: 0)),
            time: SessionTiming(created: 1_700_000_000_000, updated: 1_700_000_000_500, archived: nil),
            title: "T", location: LocationRef(directory: "/tmp"), subpath: nil, revert: nil
        )
        let summary = AidenSessionSummary(info: info)
        XCTAssertEqual(summary.updatedDate.timeIntervalSince1970, 1_700_000_000.5, accuracy: 0.001)
    }

    // MARK: - Durable tool state mapping

    func toolActivity(_ state: ToolRunState) -> AidenToolActivity {
        AidenTimelineMapper.activity(callID: "call_9", name: "glob", state: state)
    }

    func testDurableToolStatesMapToPhases() {
        XCTAssertEqual(self.toolActivity(.pending(input: "{}")).phase, .preparing)
        XCTAssertEqual(self.toolActivity(.running(input: ["pattern": .string("*")], structured: [:], content: [])).phase, .running)

        let completed = self.toolActivity(.completed(
            input: [:], attachments: nil,
            content: [.text(text: "found 3 files")],
            outputPaths: nil, structured: [:], result: nil
        ))
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.detail, "found 3 files")

        let failed = self.toolActivity(.failed(
            input: [:], content: [], structured: [:],
            error: UnknownErrorValue(message: "nope"), result: nil
        ))
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.errorMessage, "nope")
    }

    // MARK: - Reconciliation

    private func confirmedUserRow(id: String, text: String, createdAt: Date = Date(timeIntervalSince1970: 100)) -> AidenChatRow {
        AidenChatRow(id: id, role: .user, createdAt: createdAt, blocks: [.text(text)], isConfirmed: true)
    }

    private func optimisticUserRow(text: String) -> AidenChatRow {
        AidenChatRow(id: "local-\(text)", role: .user, createdAt: Date(), blocks: [.text(text)], isConfirmed: false)
    }

    func testMergeReplacesExistingIDsAndAppendsNewRows() {
        let current = [
            self.confirmedUserRow(id: "u1", text: "first"),
            AidenChatRow(id: "a1", role: .assistant, createdAt: Date(), blocks: [.text("v1")]),
        ]
        let incoming = [
            self.confirmedUserRow(id: "u1", text: "first"),
            AidenChatRow(id: "a1", role: .assistant, createdAt: Date(), blocks: [.text("v2 final")]),
            self.confirmedUserRow(id: "u2", text: "second"),
        ]
        let merged = AidenTimelineReconciler.merge(current: current, incoming: incoming)
        XCTAssertEqual(merged.map(\.id), ["u1", "a1", "u2"])
        if case .text(let value) = merged[1].blocks.first { XCTAssertEqual(value, "v2 final") } else {
            XCTFail("missing assistant block")
        }
    }

    func testMergeDropsOptimisticRowsShadowedByConfirmedEchoes() {
        let current = [self.optimisticUserRow(text: "hello"), AidenChatRow(id: "x", role: .system, createdAt: Date(), text: "note")]
        let incoming = [self.confirmedUserRow(id: "srv-u", text: "hello")]
        let merged = AidenTimelineReconciler.merge(current: current, incoming: incoming)
        XCTAssertEqual(merged.map(\.id), ["x", "srv-u"])
    }

    func testPrependOlderSkipsDuplicatesAndPreservesOrder() {
        let current = [
            self.confirmedUserRow(id: "m3", text: "three"),
            self.confirmedUserRow(id: "m4", text: "four"),
        ]
        let older = [
            self.confirmedUserRow(id: "m1", text: "one"),
            self.confirmedUserRow(id: "m2", text: "two"),
            self.confirmedUserRow(id: "m3", text: "three"),
        ]
        let merged = AidenTimelineReconciler.prependOlder(current: current, older: older)
        XCTAssertEqual(merged.map(\.id), ["m1", "m2", "m3", "m4"])
    }

    // MARK: - Pagination cursor math

    func testOlderCursorFollowsTheNextPointer() {
        let page = MessagePage(
            data: [],
            cursor: PageCursor(previous: "cur-prev", next: "cur-next")
        )
        XCTAssertEqual(AidenMessagePagination.olderCursor(in: page), "cur-next")

        let exhausted = MessagePage(data: [], cursor: PageCursor(previous: "cur-prev", next: nil))
        XCTAssertNil(AidenMessagePagination.olderCursor(in: exhausted))
    }

    // MARK: - Reconnect policy

    func testBackoffDelaysGrowExponentiallyAndCapAtThirtySeconds() {
        XCTAssertEqual(AidenReconnectPolicy.delaySeconds(attempt: 0), 1)
        XCTAssertEqual(AidenReconnectPolicy.delaySeconds(attempt: 1), 2)
        XCTAssertEqual(AidenReconnectPolicy.delaySeconds(attempt: 3), 8)
        XCTAssertEqual(AidenReconnectPolicy.delaySeconds(attempt: 5), 30)
        XCTAssertEqual(AidenReconnectPolicy.delaySeconds(attempt: 50), 30)
        XCTAssertEqual(AidenReconnectPolicy.delaySeconds(attempt: -3), 1)
    }

    // MARK: - Outcome presentation

    func testOutcomePresentationForFailuresAndInterruptions() {
        let failed = AidenTurnOutcome.from(error: UnknownErrorValue(message: "rate limited"))
        XCTAssertEqual(failed?.kind, .failed)
        XCTAssertEqual(failed?.message, "rate limited")
        XCTAssertEqual(failed?.title, "Generation failed")
        XCTAssertTrue(failed?.isFailure ?? false)

        let interrupted = AidenTurnOutcome(kind: .interrupted)
        XCTAssertEqual(interrupted.title, "Response interrupted")
        XCTAssertFalse(interrupted.isFailure)

        XCTAssertNil(AidenTurnOutcome.from(error: nil))
    }

    // MARK: - Question answers

    func testQuestionAnswersAlignSelectionsWithQuestionsAndCustomText() {
        let prompt = AidenQuestionPrompt(requestID: "q1", questions: [
            QuestionInfo(question: "Deploy?", header: "Deploy", options: [
                QuestionOption(label: "Yes", description: "ship it"),
                QuestionOption(label: "No", description: "hold"),
            ], multiple: false, custom: true),
            QuestionInfo(question: "Where?", header: "Target", options: [
                QuestionOption(label: "Staging", description: ""),
            ], multiple: true, custom: true),
        ])

        let answers = prompt.answers(selections: [[1], [0]], customText: "canary 10%")
        XCTAssertEqual(answers, [["No"], ["Staging"]])

        let customOnly = prompt.answers(selections: [[], []], customText: "canary 10%")
        XCTAssertEqual(customOnly, [["canary 10%"], ["canary 10%"]])

        let withoutCustom = prompt.answers(selections: [[0], []], customText: "")
        XCTAssertEqual(withoutCustom, [["Yes"], []])

        // Out-of-range selections are dropped instead of crashing.
        let guarded = prompt.answers(selections: [[9]], customText: "")
        XCTAssertEqual(guarded, [[]])
    }

    // MARK: - Model references

    func testModelRefConstructionAndIdentifier() throws {
        let ref = ModelRef(providerID: "anthropic", modelID: "claude-sonnet-4")
        XCTAssertEqual(ref.identifier, "anthropic/claude-sonnet-4")
        let encoded = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(ModelRef.self, from: encoded)
        XCTAssertEqual(decoded, ref)
        XCTAssertEqual(decoded.id, "claude-sonnet-4")
    }

    // MARK: - Shared fixtures

    private static let modelRef = ModelRef(providerID: "anthropic", modelID: "claude-sonnet-4")

    private static func textDelta(_ sessionID: String, delta: String = "a") -> TextDeltaEventData {
        TextDeltaEventData(
            timestamp: 1, sessionID: sessionID, assistantMessageID: "asst", textID: "t1", delta: delta
        )
    }

    private static func stepStarted(_ sessionID: String) -> StepStartedEventData {
        StepStartedEventData(
            timestamp: 1, sessionID: sessionID, assistantMessageID: "asst",
            agent: "build", model: modelRef, snapshot: nil
        )
    }

    private static func stepEnded(_ sessionID: String) -> StepEndedEventData {
        StepEndedEventData(
            timestamp: 2, sessionID: sessionID, assistantMessageID: "asst",
            finish: "stop", cost: 0, tokens: TokenUsage(
                input: 0, output: 0, reasoning: 0, cache: TokenCacheUsage(read: 0, write: 0)
            ),
            snapshot: nil, files: nil
        )
    }

    private static func permissionRequest(_ sessionID: String) -> PermissionRequest {
        PermissionRequest(
            id: "perm_1", sessionID: sessionID, action: "edit",
            resources: ["/tmp/x"], save: nil, metadata: nil, source: nil
        )
    }

    private static func compactionEnded(_ sessionID: String) -> CompactionEndedEventData {
        CompactionEndedEventData(
            timestamp: 3, sessionID: sessionID, messageID: "cm1",
            reason: .auto, text: "summary", recent: "recent"
        )
    }
}
