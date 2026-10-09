import Foundation

// MARK: - UI-facing chat model for the OpenCode V2 remap
//
// Everything here is a renderable value type bridging `Networking/OpenCode`
// wire shapes (`OCMessage`, `OpenCodeEventData`, `SessionInfo`, …). JSON keys
// are never restated: decoding lives entirely in the transport layer.

/// Legacy provider artwork payload. V2 catalogs carry no artwork; this type is
/// retained only because the kept shared `AidenProviderIcon` accepts it.
struct AidenProviderArtwork: Codable, Equatable, Sendable {
    let mimeType: String
    let dataBase64: String

    var boundedPNGData: Data? {
        guard mimeType == "image/png",
              dataBase64.count <= 44_000,
              let data = Data(base64Encoded: dataBase64),
              data.count <= 32 * 1024
        else { return nil }
        let header = [UInt8](data.prefix(24))
        guard header.count == 24,
              Array(header[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[12..<16]) == [73, 72, 68, 82]
        else { return nil }
        let dimension: (Int) -> UInt32 = { offset in
            (UInt32(header[offset]) << 24)
                | (UInt32(header[offset + 1]) << 16)
                | (UInt32(header[offset + 2]) << 8)
                | UInt32(header[offset + 3])
        }
        let width = dimension(16)
        let height = dimension(20)
        guard width > 0, height > 0, width <= 64, height <= 64 else { return nil }
        return data
    }
}

// MARK: - Tool activity

enum AidenToolPhase: Equatable, Sendable {
    case preparing
    case running
    case completed
    case failed

    var label: String {
        switch self {
        case .preparing: "Preparing"
        case .running: "Running"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }
}

/// One tool invocation row, keyed by its wire `callID`.
struct AidenToolActivity: Identifiable, Equatable, Sendable {
    let callID: String
    var name: String
    var phase: AidenToolPhase
    /// Live input tail while the server streams tool input JSON.
    var inputTail: String
    /// Short excerpt of progress/result content once available.
    var detail: String?
    var errorMessage: String?

    var id: String { callID }

    /// Single-line preview for collapsed rows.
    var previewLine: String {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        if let detail, !detail.isEmpty { return detail }
        let tail = inputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.replacingOccurrences(of: "\n", with: " ")
    }

    static let inputTailLimit = 400

    mutating func appendInputTail(_ delta: String) {
        inputTail.append(delta)
        if inputTail.count > Self.inputTailLimit {
            inputTail = "…" + inputTail.suffix(Self.inputTailLimit)
        }
    }

    mutating func setInputTail(from input: [String: OCJSON]) {
        inputTail = Self.preview(of: input)
    }

    mutating func setDetail(from content: [ToolResultContent]) {
        let text = content.compactMap { piece -> String? in
            if case .text(let value) = piece { return value }
            return nil
        }
        .joined(separator: "\n")
        guard !text.isEmpty else { return }
        detail = String(text.prefix(240))
    }

    /// Compact single-line projection of a structured tool input object.
    static func preview(of input: [String: OCJSON]) -> String {
        let pairs = input.sorted(by: { $0.key < $1.key }).map { key, value -> String in
            "\(key): \(flatten(value))"
        }
        let joined = pairs.joined(separator: ", ")
        guard joined.count > 160 else { return joined }
        return String(joined.prefix(157)) + "…"
    }

    private static func flatten(_ value: OCJSON) -> String {
        switch value {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value):
            value.count > 60 ? String(value.prefix(57)) + "…" : value
        case .array(let values): "[\(values.map(flatten).joined(separator: ","))]"
        case .object(let fields): "{\(fields.sorted(by: { $0.key < $1.key }).map { "\($0.key):\(flatten($0.value))" }.joined(separator: ","))}"
        }
    }
}

// MARK: - Transcript rows and blocks

/// One renderable content block inside a message row.
enum AidenChatBlock: Equatable, Sendable {
    /// Assistant markdown or user plain text.
    case text(String)
    case reasoning(id: String, text: String)
    case tool(AidenToolActivity)
}

/// Terminal state of a turn as shown inline under an assistant reply.
struct AidenTurnOutcome: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case failed
        case interrupted
    }

    let kind: Kind
    let message: String?

    init(kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    var isFailure: Bool { kind == .failed }

    var title: String {
        kind == .failed ? "Generation failed" : "Response interrupted"
    }

    var symbol: String {
        kind == .failed ? "exclamationmark.triangle" : "stop.circle"
    }

    var detail: String? {
        if let message, !message.isEmpty { return message }
        return kind == .failed ? "The model provider could not complete this response." : nil
    }

    static func from(error: UnknownErrorValue?) -> AidenTurnOutcome? {
        guard let error else { return nil }
        return AidenTurnOutcome(kind: .failed, message: error.message)
    }
}

/// One row of the transcript. Assistant messages collapse their interleaved
/// text / reasoning / tool parts into ordered blocks on a single row.
struct AidenChatRow: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
        /// Centered informational line (system/synthetic/shell echoes, switches).
        case system
        /// Compaction boundary divider.
        case divider
    }

    /// Mutable so an admitted prompt can replace an optimistic row's local id.
    var id: String
    let role: Role
    let createdAt: Date
    var blocks: [AidenChatBlock]
    /// Copy for `.system` / `.divider` roles; empty otherwise.
    var text: String
    var outcome: AidenTurnOutcome?
    /// False for optimistic rows that the server has not echoed yet.
    var isConfirmed: Bool

    init(
        id: String,
        role: Role,
        createdAt: Date,
        blocks: [AidenChatBlock] = [],
        text: String = "",
        outcome: AidenTurnOutcome? = nil,
        isConfirmed: Bool = true
    ) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.blocks = blocks
        self.text = text
        self.outcome = outcome
        self.isConfirmed = isConfirmed
    }

    var userText: String? {
        guard role == .user else { return nil }
        if case .text(let value) = blocks.first { return value }
        return nil
    }
}

// MARK: - Session summary

/// UI wrapper around `SessionInfo` (epoch-ms timestamps converted to `Date`).
struct AidenSessionSummary: Identifiable, Equatable, Sendable {
    let info: SessionInfo

    init(info: SessionInfo) {
        self.info = info
    }

    var id: String { info.id }
    var title: String { info.title.isEmpty ? String(localized: "Session") : info.title }
    var updatedDate: Date { Self.date(fromMilliseconds: info.time.updated) }
    var modelRef: ModelRef? { info.model }
    var agentID: String? { info.agent }

    static func date(fromMilliseconds milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

// MARK: - Stream phase

enum AidenChatStreamState: Equatable, Sendable {
    case idle
    case streaming
    case waitingApproval
    case error(String)
    case offline
}

// MARK: - Pending interactive prompts

struct AidenApprovalPrompt: Identifiable, Equatable, Sendable {
    let requestID: String
    let action: String
    let resources: [String]

    var id: String { requestID }

    init(request: PermissionRequest) {
        requestID = request.id
        action = request.action
        resources = request.resources
    }

    init(requestID: String, action: String, resources: [String]) {
        self.requestID = requestID
        self.action = action
        self.resources = resources
    }

    var summary: String {
        let objects = resources.joined(separator: ", ")
        return objects.isEmpty ? action : "\(action) · \(objects)"
    }
}

struct AidenQuestionPrompt: Identifiable, Equatable, Sendable {
    let requestID: String
    let questions: [QuestionInfo]
    let multiple: Bool
    let allowsCustom: Bool

    init(request: QuestionRequest) {
        requestID = request.id
        questions = request.questions
        multiple = request.questions.allSatisfy { $0.multiple == true }
        allowsCustom = request.questions.allSatisfy { $0.custom != false }
    }

    init(requestID: String, questions: [QuestionInfo], multiple: Bool = false, allowsCustom: Bool = true) {
        self.requestID = requestID
        self.questions = questions
        self.multiple = multiple
        self.allowsCustom = allowsCustom
    }

    var id: String { requestID }

    /// Builds the aligned `[[String]]` answer body from per-question
    /// selections. The shared custom-answer field fills any question the user
    /// left without an option selection.
    func answers(selections: [[Int]], customText: String) -> [[String]] {
        zip(questions.indices, selections).map { index, chosen in
            var labels = chosen.compactMap { choice in
                questions[index].options.indices.contains(choice) ? questions[index].options[choice].label : nil
            }
            let trimmedCustom = customText.trimmingCharacters(in: .whitespacesAndNewlines)
            if allowsCustom, !trimmedCustom.isEmpty, labels.isEmpty {
                labels.append(trimmedCustom)
            }
            return labels
        }
    }
}

// MARK: - Live turn accumulator

struct AidenStreamingSegment: Equatable, Sendable {
    let id: String
    var text: String
}

/// Ephemeral streaming state for the in-flight assistant turn, fed only by SSE
/// events. Durable history replaces it once reconciliation lands the final
/// message row.
struct AidenLiveTurn: Equatable, Sendable {
    private(set) var assistantMessageID: String?
    private(set) var isStepActive = false
    private(set) var textSegments: [AidenStreamingSegment] = []
    private(set) var reasoningSegments: [AidenStreamingSegment] = []
    private(set) var tools: [AidenToolActivity] = []
    private(set) var failureMessage: String?

    var isEmpty: Bool {
        textSegments.allSatisfy(\.text.isEmpty)
            && reasoningSegments.allSatisfy(\.text.isEmpty)
            && tools.isEmpty
            && failureMessage == nil
            && !isStepActive
    }

    var liveText: String {
        textSegments.map(\.text).joined()
    }

    var liveReasoning: String {
        reasoningSegments.map(\.text).joined()
    }

    var hasRunningTool: Bool {
        tools.contains { $0.phase == .preparing || $0.phase == .running }
    }

    mutating func reset() {
        self = AidenLiveTurn()
    }

    /// Applies one event payload. Events belonging to other sessions must be
    /// filtered before calling; unknown payloads are ignored.
    mutating func apply(_ data: OpenCodeEventData) {
        switch data {
        case .stepStarted(let payload):
            assistantMessageID = payload.assistantMessageID
            isStepActive = true
            failureMessage = nil
        case .stepEnded:
            isStepActive = false
        case .stepFailed(let payload):
            isStepActive = false
            failureMessage = payload.error.message
        case .textStarted(let payload):
            assistantMessageID = payload.assistantMessageID
            upsertSegment(id: payload.textID, into: &textSegments)
        case .textDelta(let payload):
            assistantMessageID = payload.assistantMessageID
            appendDelta(payload.textID, payload.delta, into: &textSegments)
        case .textEnded(let payload):
            assistantMessageID = payload.assistantMessageID
            replaceSegment(id: payload.textID, with: payload.text, in: &textSegments)
        case .reasoningStarted(let payload):
            assistantMessageID = payload.assistantMessageID
            upsertSegment(id: payload.reasoningID, into: &reasoningSegments)
        case .reasoningDelta(let payload):
            assistantMessageID = payload.assistantMessageID
            appendDelta(payload.reasoningID, payload.delta, into: &reasoningSegments)
        case .reasoningEnded(let payload):
            assistantMessageID = payload.assistantMessageID
            replaceSegment(id: payload.reasoningID, with: payload.text, in: &reasoningSegments)
        case .toolInputStarted(let payload):
            assistantMessageID = payload.assistantMessageID
            upsertTool(callID: payload.callID, name: payload.name, phase: .preparing)
        case .toolInputDelta(let payload):
            if let index = toolIndex(payload.callID) {
                tools[index].appendInputTail(payload.delta)
            }
        case .toolInputEnded(let payload):
            if let index = toolIndex(payload.callID) {
                tools[index].inputTail = payload.text
            }
        case .toolCalled(let payload):
            assistantMessageID = payload.assistantMessageID
            upsertTool(callID: payload.callID, name: payload.tool, phase: .running)
            if let index = toolIndex(payload.callID) {
                tools[index].setInputTail(from: payload.input)
            }
        case .toolProgress(let payload):
            if let index = toolIndex(payload.callID) {
                tools[index].phase = .running
                tools[index].setDetail(from: payload.content)
            }
        case .toolSuccess(let payload):
            if let index = toolIndex(payload.callID) {
                tools[index].phase = .completed
                tools[index].setDetail(from: payload.content)
            }
        case .toolFailed(let payload):
            if let index = toolIndex(payload.callID) {
                tools[index].phase = .failed
                tools[index].errorMessage = payload.error.message
            }
        default:
            break
        }
    }

    // MARK: segment helpers

    private func segmentIndex(_ id: String, in segments: [AidenStreamingSegment]) -> Int? {
        segments.firstIndex { $0.id == id }
    }

    private func upsertSegment(id: String, into segments: inout [AidenStreamingSegment]) {
        if segmentIndex(id, in: segments) == nil {
            segments.append(AidenStreamingSegment(id: id, text: ""))
        }
    }

    private func appendDelta(_ id: String, _ delta: String, into segments: inout [AidenStreamingSegment]) {
        if let index = segmentIndex(id, in: segments) {
            segments[index].text += delta
        } else {
            segments.append(AidenStreamingSegment(id: id, text: delta))
        }
    }

    private func replaceSegment(id: String, with text: String, in segments: inout [AidenStreamingSegment]) {
        if let index = segmentIndex(id, in: segments) {
            segments[index].text = text
        } else if !text.isEmpty {
            segments.append(AidenStreamingSegment(id: id, text: text))
        }
    }

    // MARK: tool helpers

    private func toolIndex(_ callID: String) -> Int? {
        tools.firstIndex { $0.callID == callID }
    }

    private mutating func upsertTool(callID: String, name: String, phase: AidenToolPhase) {
        if let index = toolIndex(callID) {
            tools[index].name = name
            tools[index].phase = phase
        } else {
            tools.append(AidenToolActivity(
                callID: callID,
                name: name,
                phase: phase,
                inputTail: "",
                detail: nil,
                errorMessage: nil
            ))
        }
    }
}

// MARK: - Wire → transcript mapping

enum AidenTimelineMapper {
    /// Maps a chronological (oldest-first) page of wire messages into rows.
    static func rows(from messages: [OCMessage]) -> [AidenChatRow] {
        messages.flatMap { row(from: $0) }
    }

    /// Maps a single wire message into zero or more rows.
    static func row(from message: OCMessage) -> [AidenChatRow] {
        switch message {
        case .user(let payload):
            [
                AidenChatRow(
                    id: payload.id,
                    role: .user,
                    createdAt: AidenSessionSummary.date(fromMilliseconds: payload.time.created),
                    blocks: [.text(payload.text)]
                ),
            ]
        case .assistant(let payload):
            [
                AidenChatRow(
                    id: payload.id,
                    role: .assistant,
                    createdAt: AidenSessionSummary.date(fromMilliseconds: payload.time.created),
                    blocks: blocks(from: payload.content),
                    outcome: AidenTurnOutcome.from(error: payload.error)
                ),
            ]
        case .compaction(let payload):
            [
                AidenChatRow(
                    id: payload.id,
                    role: .divider,
                    createdAt: AidenSessionSummary.date(fromMilliseconds: payload.time.created),
                    text: "Context compacted"
                ),
            ]
        case .system(let payload):
            [systemRow(id: payload.id, dateMilliseconds: payload.time.created, text: payload.text)]
        case .synthetic(let payload):
            [systemRow(id: payload.id, dateMilliseconds: payload.time.created, text: payload.text)]
        case .shell(let payload):
            [systemRow(id: payload.id, dateMilliseconds: payload.time.created, text: "$ \(payload.command)")]
        case .agentSwitched(let payload):
            [systemRow(id: payload.id, dateMilliseconds: payload.time.created, text: "Agent switched to \(payload.agent)")]
        case .modelSwitched(let payload):
            [systemRow(
                id: payload.id,
                dateMilliseconds: payload.time.created,
                text: "Model switched to \(payload.model.identifier)"
            )]
        case .unrecognized:
            []
        }
    }

    static func blocks(from content: [AssistantContent]) -> [AidenChatBlock] {
        content.map { part -> AidenChatBlock? in
            switch part {
            case .text(let payload):
                return .text(payload.text)
            case .reasoning(let payload):
                return .reasoning(id: payload.id, text: payload.text)
            case .tool(let part):
                return .tool(activity(callID: part.id, name: part.name, state: part.state))
            case .unrecognized:
                return nil
            }
        }
        .compactMap { $0 }
    }

    static func activity(callID: String, name: String, state: ToolRunState) -> AidenToolActivity {
        var activity = AidenToolActivity(
            callID: callID,
            name: name,
            phase: .running,
            inputTail: "",
            detail: nil,
            errorMessage: nil
        )
        switch state {
        case .pending(let input):
            activity.phase = .preparing
            activity.inputTail = input
        case .running(let input, _, let content):
            activity.setInputTail(from: input)
            activity.setDetail(from: content)
        case .completed(let input, _, let content, _, _, _):
            activity.phase = .completed
            activity.setInputTail(from: input)
            activity.setDetail(from: content)
        case .failed(let input, let content, _, let error, _):
            activity.phase = .failed
            activity.setInputTail(from: input)
            activity.setDetail(from: content)
            activity.errorMessage = error.message
        }
        return activity
    }

    static func systemRow(id: String, dateMilliseconds: Double, text: String) -> AidenChatRow {
        AidenChatRow(
            id: id,
            role: .system,
            createdAt: AidenSessionSummary.date(fromMilliseconds: dateMilliseconds),
            text: text
        )
    }
}

// MARK: - Event routing helpers

extension OpenCodeEventData {
    /// Session identity carried by session-scoped payloads; nil for global or
    /// unscoped payloads (`file.edited`, `server.connected`, unknown).
    var aidenSessionID: String? {
        switch self {
        case .prompted(let payload): payload.sessionID
        case .agentSwitched(let payload): payload.sessionID
        case .modelSwitched(let payload): payload.sessionID
        case .stepStarted(let payload): payload.sessionID
        case .stepEnded(let payload): payload.sessionID
        case .stepFailed(let payload): payload.sessionID
        case .textStarted(let payload): payload.sessionID
        case .textDelta(let payload): payload.sessionID
        case .textEnded(let payload): payload.sessionID
        case .reasoningStarted(let payload): payload.sessionID
        case .reasoningDelta(let payload): payload.sessionID
        case .reasoningEnded(let payload): payload.sessionID
        case .toolInputStarted(let payload): payload.sessionID
        case .toolInputDelta(let payload): payload.sessionID
        case .toolInputEnded(let payload): payload.sessionID
        case .toolCalled(let payload): payload.sessionID
        case .toolProgress(let payload): payload.sessionID
        case .toolSuccess(let payload): payload.sessionID
        case .toolFailed(let payload): payload.sessionID
        case .retried(let payload): payload.sessionID
        case .compactionStarted(let payload): payload.sessionID
        case .compactionDelta(let payload): payload.sessionID
        case .compactionEnded(let payload): payload.sessionID
        case .todoUpdated(let payload): payload.sessionID
        case .permissionAsked(let payload): payload.sessionID
        case .permissionReplied(let payload): payload.sessionID
        case .questionAsked(let payload): payload.sessionID
        case .questionReplied(let payload): payload.sessionID
        case .questionRejected(let payload): payload.sessionID
        case .fileEdited, .serverConnected, .unknown: nil
        }
    }

    /// Durable boundary payloads worth replaying after a reconnect. Live-only
    /// deltas are excluded — they never replay and reconciliation refetches
    /// full text anyway.
    var isDurableBoundaryEvent: Bool {
        switch self {
        case .prompted, .agentSwitched, .modelSwitched, .stepStarted, .stepEnded, .stepFailed,
             .textStarted, .textEnded, .reasoningStarted, .reasoningEnded,
             .toolInputStarted, .toolInputEnded, .toolCalled, .toolSuccess, .toolFailed,
             .retried, .compactionStarted, .compactionEnded,
             .permissionAsked, .permissionReplied, .questionAsked, .questionReplied, .questionRejected:
            true
        default:
            false
        }
    }
}

// MARK: - Reconciliation

enum AidenTimelineReconciler {
    /// Merges a fresh fetch into the current timeline. Existing ids are
    /// replaced in place, new ids keep incoming order appended, and optimistic
    /// user rows shadowed by a confirmed echo are dropped.
    static func merge(current: [AidenChatRow], incoming: [AidenChatRow]) -> [AidenChatRow] {
        var merged = current
        for row in incoming {
            if let index = merged.firstIndex(where: { $0.id == row.id }) {
                merged[index] = row
            } else {
                merged.append(row)
            }
        }
        return dropShadowedOptimistic(merged)
    }

    /// Prepends an older page (already chronological) skipping duplicates.
    static func prependOlder(current: [AidenChatRow], older: [AidenChatRow]) -> [AidenChatRow] {
        let knownIDs = Set(current.map(\.id))
        let fresh = older.filter { !knownIDs.contains($0.id) }
        return fresh + current
    }

    /// Removes optimistic (unconfirmed) user rows whose text now exists on a
    /// confirmed user row — the admission echo made the local copy redundant.
    static func dropShadowedOptimistic(_ rows: [AidenChatRow]) -> [AidenChatRow] {
        let confirmedTexts = Set(rows.compactMap { row -> String? in
            guard row.role == .user, row.isConfirmed else { return nil }
            return row.userText
        })
        return rows.filter { row in
            guard !row.isConfirmed, row.role == .user, let text = row.userText else { return true }
            return !confirmedTexts.contains(text)
        }
    }
}

// MARK: - Pagination and reconnect policy

enum AidenMessagePagination {
    /// Continuation cursor toward older messages on a newest-first page.
    static func olderCursor(in page: MessagePage) -> String? {
        page.cursor.next
    }
}

enum AidenReconnectPolicy {
    static let baseDelaySeconds: TimeInterval = 1
    static let maximumDelaySeconds: TimeInterval = 30

    static func delaySeconds(attempt: Int) -> TimeInterval {
        let safeAttempt = max(0, min(attempt, 5))
        return min(maximumDelaySeconds, baseDelaySeconds * pow(2, Double(safeAttempt)))
    }
}

// MARK: - Live Activity seam

/// Minimal bridge between the chat view model and the app's Live Activity
/// manager. The shell owns the concrete reporter; chat only knows this
/// protocol, so manager changes cannot break the chat feature.
@MainActor
protocol ChatActivityReporting {
    func started(sessionID: String, title: String) async
    func updated(sessionID: String, status: AgentRunActivityStatus, activity: String) async
    func finished(sessionID: String, summary: String, status: AgentRunActivityStatus) async
}

/// Default no-op reporter used until the shell injects a real one.
@MainActor
struct NoopChatActivityReporting: ChatActivityReporting {
    func started(sessionID: String, title: String) async {}
    func updated(sessionID: String, status: AgentRunActivityStatus, activity: String) async {}
    func finished(sessionID: String, summary: String, status: AgentRunActivityStatus) async {}
}
