import MarkdownUI
import Observation
import SwiftUI
import UIKit

// MARK: - Markdown rendering (salvaged from the previous chat implementation)

enum AidenMarkdownFallbackReason: Equatable {
    case tooManyCharacters
    case tooManyLines
}

enum AidenMarkdownRenderingPolicy {
    static let maximumCharacterCount = 80_000
    static let maximumLineCount = 2_000

    static func fallbackReason(for content: String) -> AidenMarkdownFallbackReason? {
        if content.count > maximumCharacterCount { return .tooManyCharacters }

        var lineCount = 1
        var previousWasCarriageReturn = false
        for scalar in content.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCarriageReturn { lineCount += 1 }
                previousWasCarriageReturn = false
            case 0x0D:
                lineCount += 1
                previousWasCarriageReturn = true
            case 0x2028, 0x2029:
                lineCount += 1
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
            if lineCount > maximumLineCount { return .tooManyLines }
        }
        return nil
    }
}

struct AidenMarkdownView: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: String

    var body: some View {
        Group {
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: " ")
            } else if AidenMarkdownRenderingPolicy.fallbackReason(for: content) != nil {
                Text(verbatim: content)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownUI.Markdown(content)
                    .markdownTheme(.aidenChat(colorScheme: colorScheme))
                    .markdownImageProvider(AidenMarkdownNoNetworkImageProvider())
                    .markdownCodeSyntaxHighlighter(.plainText)
                    .markdownTextStyle {
                        ForegroundColor(.primary)
                        BackgroundColor(nil)
                    }
                    .markdownTextStyle(\.code) {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                        BackgroundColor(Color(.tertiarySystemGroupedBackground))
                    }
                    .markdownBlockStyle(\.paragraph) { configuration in
                        configuration.label
                            .fixedSize(horizontal: false, vertical: true)
                            .relativeLineSpacing(.em(0.18))
                            .markdownMargin(top: 0, bottom: 8)
                    }
            }
        }
        .textSelection(.enabled)
    }
}

private struct AidenMarkdownNoNetworkImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        EmptyView()
    }
}

private extension MarkdownUI.Theme {
    static func aidenChat(colorScheme: ColorScheme) -> MarkdownUI.Theme {
        MarkdownUI.Theme.gitHub
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(16)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(
                    colorScheme == .dark
                        ? Color(red: 0.08, green: 0.09, blue: 0.12)
                        : Color(.tertiarySystemGroupedBackground)
                )
            }
    }
}

// MARK: - View model

@MainActor
@Observable
final class AidenChatViewModel {
    static let pageSize = 60

    private let coordinator: AidenRemoteCoordinator
    let sessionID: String
    @ObservationIgnored private let capturedInstanceID: String

    /// Seam for the shell-owned Live Activity manager. Defaults to a no-op so
    /// manager changes cannot break the chat feature.
    var activityReporting: any ChatActivityReporting = NoopChatActivityReporting()

    private(set) var session: AidenSessionSummary?
    private(set) var rows: [AidenChatRow] = []
    private(set) var liveTurn = AidenLiveTurn()
    private(set) var streamState: AidenChatStreamState = .idle
    private(set) var approvals: [AidenApprovalPrompt] = []
    private(set) var questions: [AidenQuestionPrompt] = []
    private(set) var models: [ModelInfo] = []
    private(set) var agents: [AgentInfo] = []
    private(set) var selectedModelRef: ModelRef?
    private(set) var selectedAgentID: String?
    private(set) var isLoading = false
    private(set) var isLoadingOlder = false
    private(set) var canLoadOlder = false
    private(set) var offlineMessage: String?
    private(set) var sendError: String?
    private(set) var transientNotice: String?
    private(set) var respondingRequestID: String?
    private(set) var isCompacting = false
    var presentedError: String?
    var draft = ""

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var lastDurableSeq: Int?
    @ObservationIgnored private var retriablePromptID: String?
    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var didStartLoops = false
    @ObservationIgnored private var reportedRunActive = false
    @ObservationIgnored private var lastReportedLiveActivityKey: String?
    @ObservationIgnored private var liveActivityTask: Task<Void, Never>?

    init(coordinator: AidenRemoteCoordinator, sessionID: String) {
        self.coordinator = coordinator
        self.sessionID = sessionID
        capturedInstanceID = coordinator.instanceId ?? ""
    }

    // MARK: derived state

    private var isStale: Bool {
        !capturedInstanceID.isEmpty && !coordinator.isCurrent(capturedInstanceID)
    }

    var isConnectedToServer: Bool {
        if case .connected = coordinator.connectionState { return true }
        return false
    }

    var showsOfflineBanner: Bool {
        if offlineMessage != nil { return true }
        if case .offline = coordinator.connectionState { return true }
        return false
    }

    /// True while a drain appears active: an open step without its matching
    /// end, or interactive prompts holding the turn.
    var isDrainRunning: Bool {
        liveTurn.isStepActive || streamState == .streaming || hasInteractivePrompts
    }

    var hasInteractivePrompts: Bool {
        !approvals.isEmpty || !questions.isEmpty
    }

    var showsLiveOverlay: Bool {
        streamState == .streaming
            || streamState == .waitingApproval
            || !liveTurn.isEmpty
            || hasInteractivePrompts
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isConnectedToServer
    }

    var liveScrollToken: Int {
        liveTurn.liveText.count + liveTurn.liveReasoning.count * 13 + liveTurn.tools.count * 97
            + approvals.count * 31 + questions.count * 17
    }

    var modelSections: [(providerID: String, models: [ModelInfo])] {
        let grouped = Dictionary(grouping: models.filter(\.enabled), by: \.providerID)
        return grouped.keys.sorted().map { providerID in
            (providerID, grouped[providerID] ?? [])
        }
    }

    var visibleAgents: [AgentInfo] {
        agents.filter { !$0.hidden }
    }

    var currentModelIdentifier: String? {
        selectedModelRef?.identifier
    }

    // MARK: title synthesis

    /// The server starts sessions untitled ("New session - …"); a readable
    /// label is synthesized from the earliest confirmed user prompt until a
    /// real server title lands via `refreshSession`.
    var hasServerTitle: Bool {
        guard let title = session?.info.title else { return false }
        return !title.isEmpty && !title.hasPrefix("New session")
    }

    var displayTitle: String? {
        if hasServerTitle { return session?.info.title }
        return Self.title(fromPrompt: rows.first(where: { $0.role == .user && $0.isConfirmed })?.userText)
    }

    /// First line of the prompt, capped at ~40 characters with tail ellipsis.
    static func title(fromPrompt prompt: String?) -> String? {
        guard let prompt else { return nil }
        let flattened = prompt
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > 40 else { return flattened }
        return flattened.prefix(40) + "…"
    }

    private func reportRunStart() {
        reportStartedOnce(title: displayTitle ?? String(localized: "Session"))
    }

    // MARK: loading

    func load() async {
        guard !isLoading, !didStartLoops || rows.isEmpty else {
            startLoopsIfNeeded()
            return
        }
        isLoading = true
        defer { isLoading = false }
        await refreshSession()
        await fetchTimeline()
        await loadCatalogs()
        await syncPendingRequests()
        startLoopsIfNeeded()
    }

    func shutdown() {
        eventTask?.cancel()
        pollTask?.cancel()
        reconcileTask?.cancel()
        eventTask = nil
        pollTask = nil
        reconcileTask = nil
        didStartLoops = false
        // Leave a running Live Activity up when the chat view disappears; the
        // server still owns the turn. Finish only on idle / interrupt / failure.
    }

    func loadOlder() async {
        guard canLoadOlder, !isLoadingOlder, let cursor = olderCursor else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let client = try coordinator.client()
            let page = try await client.messages(
                sessionID: sessionID,
                limit: Self.pageSize,
                order: .desc,
                cursor: cursor
            )
            guard !isStale else { return }
            rows = AidenTimelineReconciler.prependOlder(
                current: rows,
                older: AidenTimelineMapper.rows(from: page.data.reversed())
            )
            olderCursor = AidenMessagePagination.olderCursor(in: page)
            canLoadOlder = olderCursor != nil
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    private func refreshSession() async {
        do {
            let client = try coordinator.client()
            let info = try await client.session(id: sessionID)
            guard !isStale else { return }
            applySession(info)
        } catch is CancellationError {
            // View torn down mid-load; nothing to surface.
        } catch {
            if rows.isEmpty { presentedError = Self.friendlyMessage(for: error) }
        }
    }

    private func applySession(_ info: SessionInfo) {
        let summary = AidenSessionSummary(info: info)
        session = summary
        if selectedModelRef == nil { selectedModelRef = summary.modelRef }
        if selectedAgentID == nil { selectedAgentID = summary.agentID }
    }

    private func fetchTimeline() async {
        do {
            let client = try coordinator.client()
            let page = try await client.messages(
                sessionID: sessionID,
                limit: Self.pageSize,
                order: .desc
            )
            guard !isStale else { return }
            acceptMessages(page.data)
            olderCursor = AidenMessagePagination.olderCursor(in: page)
            canLoadOlder = olderCursor != nil
            if page.data.isEmpty {
                let context = try await client.context(sessionID: sessionID)
                guard !isStale else { return }
                rows = AidenTimelineReconciler.merge(
                    current: rows,
                    incoming: AidenTimelineMapper.rows(from: context)
                )
            }
        } catch is CancellationError {
            // View torn down mid-load; nothing to surface.
        } catch {
            if rows.isEmpty { presentedError = Self.friendlyMessage(for: error) }
        }
    }

    private func acceptMessages(_ messages: [OCMessage]) {
        rows = AidenTimelineReconciler.merge(
            current: rows,
            incoming: AidenTimelineMapper.rows(from: messages.reversed())
        )
        clearLiveOverlayIfConfirmed()
    }

    /// Once the finalized assistant message exists in durable history, the
    /// ephemeral streaming copy is redundant.
    private func clearLiveOverlayIfConfirmed() {
        guard let assistantMessageID = liveTurn.assistantMessageID,
              rows.contains(where: { $0.id == assistantMessageID && $0.role == .assistant })
        else { return }
        let hadFailure = liveTurn.failureMessage != nil
        liveTurn.reset()
        if !hasInteractivePrompts, streamState == .streaming || streamState == .waitingApproval {
            streamState = .idle
        }
        if reportedRunActive {
            reportFinished(
                summary: hadFailure ? String(localized: "Response failed") : String(localized: "Response complete"),
                status: hadFailure ? .failed : .complete
            )
        }
    }

    private func loadCatalogs() async {
        do {
            let client = try coordinator.client()
            async let agentRequest = client.agents()
            async let modelRequest = client.models()
            let (fetchedAgents, fetchedModels) = try await (agentRequest, modelRequest)
            guard !isStale else { return }
            agents = fetchedAgents
            models = fetchedModels
        } catch {
            // Menus degrade to empty rather than blocking the chat surface.
        }
    }

    // MARK: sending (steering)

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        sendError = nil
        let optimisticID = "local-\(UUID().uuidString.lowercased())"
        rows.append(AidenChatRow(
            id: optimisticID,
            role: .user,
            createdAt: Date(),
            blocks: [.text(text)],
            isConfirmed: false
        ))
        draft = ""
        // A stable client-side message id lets the server reconcile an exact
        // retry when a prompt was admitted but the response was lost, instead
        // of admitting a duplicate. Kept until one attempt succeeds.
        if retriablePromptID == nil {
            retriablePromptID = "msg_\(UUID().uuidString.lowercased())"
        }
        do {
            let client = try coordinator.client()
            let admitted = try await client.prompt(sessionID: sessionID, text: text, id: retriablePromptID)
            guard !isStale else { return }
            retriablePromptID = nil
            if let index = rows.firstIndex(where: { $0.id == optimisticID }) {
                rows[index].id = admitted.id
                rows[index].isConfirmed = true
            }
            reportRunStart()
        } catch {
            rows.removeAll { $0.id == optimisticID }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = text
            } else {
                draft = "\(text)\n\n\(draft)"
            }
            sendError = Self.friendlyMessage(for: error)
        }
    }

    // MARK: toolbar actions

    func interrupt() async {
        do {
            try await coordinator.client().interrupt(sessionID: sessionID)
            guard !isStale else { return }
            transientNotice = String(localized: "Interrupting…")
            reportFinished(summary: String(localized: "Interrupted"), status: .cancelled)
            scheduleReconcile(after: .milliseconds(500))
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    func compact() async {
        guard !isCompacting else { return }
        isCompacting = true
        defer { isCompacting = false }
        do {
            try await coordinator.client().compact(sessionID: sessionID)
            guard !isStale else { return }
            transientNotice = String(localized: "Compacting context…")
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    func switchModel(to ref: ModelRef) async {
        do {
            try await coordinator.client().switchModel(sessionID: sessionID, modelRef: ref)
            guard !isStale else { return }
            selectedModelRef = ref
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    func switchAgent(to agent: String) async {
        do {
            try await coordinator.client().switchAgent(sessionID: sessionID, agent: agent)
            guard !isStale else { return }
            selectedAgentID = agent
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    // MARK: approvals and questions

    func respondToApproval(_ reply: PermissionReply, requestID: String) async {
        guard approvals.contains(where: { $0.requestID == requestID }) else { return }
        respondingRequestID = requestID
        defer { respondingRequestID = nil }
        do {
            try await coordinator.client().replyPermission(sessionID: sessionID, requestID: requestID, reply: reply)
            guard !isStale else { return }
            approvals.removeAll { $0.requestID == requestID }
            resumeAfterPromptResolved()
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    func answerQuestion(requestID: String, answers: [[String]]) async {
        guard questions.contains(where: { $0.requestID == requestID }) else { return }
        respondingRequestID = requestID
        defer { respondingRequestID = nil }
        do {
            try await coordinator.client().replyQuestion(sessionID: sessionID, requestID: requestID, answers: answers)
            guard !isStale else { return }
            questions.removeAll { $0.requestID == requestID }
            resumeAfterPromptResolved()
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    func rejectQuestion(requestID: String) async {
        guard questions.contains(where: { $0.requestID == requestID }) else { return }
        respondingRequestID = requestID
        defer { respondingRequestID = nil }
        do {
            try await coordinator.client().rejectQuestion(sessionID: sessionID, requestID: requestID)
            guard !isStale else { return }
            questions.removeAll { $0.requestID == requestID }
            resumeAfterPromptResolved()
        } catch {
            presentedError = Self.friendlyMessage(for: error)
        }
    }

    private func resumeAfterPromptResolved() {
        if !hasInteractivePrompts, streamState == .waitingApproval {
            streamState = liveTurn.isStepActive ? .streaming : .idle
        }
        reportProgress()
        scheduleReconcile(after: .milliseconds(250))
    }

    // MARK: event loops

    private func startLoopsIfNeeded() {
        guard !didStartLoops else { return }
        didStartLoops = true
        eventTask = Task { [weak self] in
            await self?.runEventLoop()
        }
        pollTask = Task { [weak self] in
            await self?.runPollingLoop()
        }
    }

    private func runEventLoop() async {
        var hasEverConnected = false
        while !Task.isCancelled, !isStale {
            do {
                let client = try coordinator.client()
                let events = try await client.globalEvents()
                guard !Task.isCancelled else { return }
                reconnectAttempt = 0
                offlineMessage = nil
                if streamState == .offline { streamState = .idle }
                if hasEverConnected {
                    await reconcileAfterReconnect(client: client)
                }
                hasEverConnected = true
                for try await event in events {
                    guard !Task.isCancelled else { return }
                    handle(event)
                }
                // The stream closed cleanly; treat it as a drop and redial.
                throw OpenCodeAPIError.network(underlying: URLError(.networkConnectionLost))
            } catch {
                guard !Task.isCancelled else { return }
                if case OpenCodeAPIError.unauthorized = error {
                    // Bad credentials never recover by redialling; point the
                    // user at reconnect instead of retrying on a timer.
                    offlineMessage = String(localized: "Session expired — reconnect from Settings.")
                } else {
                    markOffline()
                }
                let delay = AidenReconnectPolicy.delaySeconds(attempt: reconnectAttempt)
                reconnectAttempt += 1
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func runPollingLoop() async {
        while !Task.isCancelled, !isStale {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await syncPendingRequests()
        }
    }

    private func markOffline() {
        offlineMessage = String(localized: "Connection lost — reconnecting…")
        if streamState == .idle || streamState == .streaming {
            streamState = .offline
        }
    }

    private func handle(_ event: OpenCodeEvent) {
        trackDurableSequence(of: event)
        guard event.data != .serverConnected else {
            scheduleReconcile(after: .milliseconds(150))
            return
        }
        guard event.data.aidenSessionID == sessionID else { return }
        apply(event.data)
    }

    private func trackDurableSequence(of event: OpenCodeEvent) {
        guard let durable = event.durable, durable.aggregateID == sessionID else { return }
        lastDurableSeq = max(lastDurableSeq ?? 0, durable.seq)
    }

    private func apply(_ data: OpenCodeEventData) {
        switch data {
        case .prompted(let payload):
            confirmOptimisticUserRows(text: payload.prompt.text, messageID: payload.messageID)
        case .stepStarted:
            liveTurn.apply(data)
            if streamState == .idle || streamState == .offline { streamState = .streaming }
            reportRunStart()
            reportProgress()
        case .stepEnded:
            liveTurn.apply(data)
            if !hasInteractivePrompts {
                reportFinished(summary: String(localized: "Response complete"), status: .complete)
            }
            scheduleReconcile(after: .milliseconds(300))
        case .stepFailed:
            liveTurn.apply(data)
            reportFinished(summary: String(localized: "Response failed"), status: .failed)
            scheduleReconcile(after: .milliseconds(400))
        case .permissionAsked(let request):
            if !approvals.contains(where: { $0.requestID == request.id }) {
                approvals.append(AidenApprovalPrompt(request: request))
            }
            streamState = .waitingApproval
            reportProgress()
        case .permissionReplied(let payload):
            approvals.removeAll { $0.requestID == payload.requestID }
            resumeAfterPromptResolved()
        case .questionAsked(let request):
            if !questions.contains(where: { $0.requestID == request.id }) {
                questions.append(AidenQuestionPrompt(request: request))
            }
            streamState = .waitingApproval
            reportProgress()
        case .questionReplied(let payload):
            questions.removeAll { $0.requestID == payload.requestID }
            resumeAfterPromptResolved()
        case .questionRejected(let payload):
            questions.removeAll { $0.requestID == payload.requestID }
            resumeAfterPromptResolved()
        case .agentSwitched(let payload):
            selectedAgentID = payload.agent
        case .modelSwitched(let payload):
            selectedModelRef = payload.model
        case .compactionStarted(let payload):
            upsertDivider(id: "compaction-\(payload.messageID)", title: String(localized: "Compacting context…"))
        case .compactionEnded(let payload):
            upsertDivider(id: "compaction-\(payload.messageID)", title: String(localized: "Context compacted"))
            scheduleReconcile(after: .milliseconds(300))
        case .textDelta, .textStarted, .textEnded,
             .reasoningDelta, .reasoningStarted, .reasoningEnded,
             .toolInputStarted, .toolInputDelta, .toolInputEnded,
             .toolCalled, .toolProgress, .toolSuccess, .toolFailed:
            if streamState == .idle || streamState == .offline { streamState = .streaming }
            liveTurn.apply(data)
            reportProgress()
        case .todoUpdated, .fileEdited, .retried, .compactionDelta, .serverConnected, .unknown:
            break
        }
    }

    /// An admitted echo replaces exactly one optimistic copy of the same text.
    private func confirmOptimisticUserRows(text: String, messageID: String) {
        var replaced = false
        for index in rows.indices.reversed() {
            guard rows[index].role == .user,
                  !rows[index].isConfirmed,
                  rows[index].userText == text else { continue }
            if replaced {
                rows.remove(at: index)
            } else {
                rows[index].id = messageID
                rows[index].isConfirmed = true
                replaced = true
            }
        }
    }

    private func upsertDivider(id: String, title: String) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].text = title
        } else {
            rows.append(AidenChatRow(id: id, role: .divider, createdAt: Date(), text: title))
        }
    }

    private func scheduleReconcile(after delay: Duration) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconcileNow()
        }
    }

    private func reconcileNow() async {
        await refreshSession()
        await fetchTimeline()
        await syncPendingRequests()
        transientNotice = nil
    }

    private func reconcileAfterReconnect(client: OpenCodeClient) async {
        await fetchTimelineWith(client)
        await recoverMissedBoundaries(client: client)
        await syncPendingRequests()
    }

    private func fetchTimelineWith(_ client: OpenCodeClient) async {
        do {
            let page = try await client.messages(
                sessionID: sessionID,
                limit: Self.pageSize,
                order: .desc
            )
            guard !isStale else { return }
            acceptMessages(page.data)
            olderCursor = AidenMessagePagination.olderCursor(in: page)
            canLoadOlder = olderCursor != nil
        } catch {
            // The banner stays up; the retry loop keeps trying.
        }
    }

    /// Durable boundary events missed while offline. Live-only deltas are
    /// never replayed; full text arrives through the timeline refetch above.
    /// V2 caps history pages at 100, so drain with a moving cursor.
    private func recoverMissedBoundaries(client: OpenCodeClient) async {
        guard var after = lastDurableSeq else { return }
        while !Task.isCancelled, !isStale {
            guard let page = try? await client.history(sessionID: sessionID, after: after, limit: 100) else { return }
            guard !isStale else { return }
            for event in page.data {
                trackDurableSequence(of: event)
                if let seq = event.durable?.seq { after = max(after, seq) }
                guard event.data.aidenSessionID == sessionID,
                      event.data.isDurableBoundaryEvent else { continue }
                apply(event.data)
            }
            guard page.hasMore, !page.data.isEmpty else { return }
        }
    }

    /// Outstanding permission/question requests, polled every few seconds and
    /// after reconnects, restore asks missed while the stream was down. The
    /// question list is location-scoped, so it must target the session's own
    /// directory — the server default can differ on multi-repo servers.
    private func syncPendingRequests() async {
        guard let client = try? coordinator.client() else { return }
        let scope = LocationScope(directory: session?.info.location.directory)
        do {
            async let permissionRequest = client.sessionPermissions(sessionID: sessionID)
            async let questionRequest = client.questionRequests(scope: scope)
            let (permissions, allQuestions) = try await (permissionRequest, questionRequest)
            guard !isStale else { return }
            let sessionQuestions = allQuestions.filter { $0.sessionID == sessionID }
            approvals = permissions.map(AidenApprovalPrompt.init(request:))
            questions = sessionQuestions.map(AidenQuestionPrompt.init(request:))
            if hasInteractivePrompts {
                streamState = .waitingApproval
            } else if streamState == .waitingApproval {
                streamState = liveTurn.isStepActive ? .streaming : .idle
            }
        } catch {
            // Keep whatever local state exists; the next poll retries.
        }
    }

    // MARK: Live Activity seam

    private func enqueueLiveActivity(_ work: @escaping @MainActor () async -> Void) {
        let previous = liveActivityTask
        liveActivityTask = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    private func reportStartedOnce(title: String) {
        guard !reportedRunActive else { return }
        reportedRunActive = true
        lastReportedLiveActivityKey = nil
        #if canImport(ActivityKit)
        let sessionID = sessionID
        enqueueLiveActivity { [weak self] in
            await self?.activityReporting.started(sessionID: sessionID, title: title)
        }
        #endif
    }

    private func reportProgress() {
        guard reportedRunActive else { return }
        #if canImport(ActivityKit)
        let snapshot = AgentRunActivityProgress.snapshot(
            waitingForApproval: hasInteractivePrompts,
            runningToolName: liveTurn.tools.last { $0.phase == .running || $0.phase == .preparing }?.name,
            hasLiveText: !liveTurn.liveText.isEmpty,
            isThinking: streamState == .streaming || liveTurn.isStepActive
        )
        let key = "\(snapshot.status.rawValue)|\(snapshot.activity)"
        guard lastReportedLiveActivityKey != key else { return }
        lastReportedLiveActivityKey = key
        let sessionID = sessionID
        enqueueLiveActivity { [weak self] in
            await self?.activityReporting.updated(
                sessionID: sessionID,
                status: snapshot.status,
                activity: snapshot.activity
            )
        }
        #endif
    }

    private func reportFinished(summary: String, status: AgentRunActivityStatus) {
        guard reportedRunActive else { return }
        reportedRunActive = false
        lastReportedLiveActivityKey = nil
        #if canImport(ActivityKit)
        let sessionID = sessionID
        enqueueLiveActivity { [weak self] in
            await self?.activityReporting.finished(sessionID: sessionID, summary: summary, status: status)
        }
        #endif
    }

    // MARK: errors

    static func friendlyMessage(for error: Error) -> String {
        guard let apiError = error as? OpenCodeAPIError else { return error.localizedDescription }
        switch apiError {
        case .unauthorized:
            return String(localized: "Session expired — reconnect from Settings.")
        case .notFound:
            return String(localized: "That session no longer exists on the server.")
        case .conflict(let message):
            return message
        case .server(_, let message):
            return message ?? String(localized: "The server could not complete the request.")
        case .network:
            return String(localized: "Cannot reach the server. Check your connection.")
        case .decoding:
            return String(localized: "The server sent an unexpected response.")
        case .invalidURL:
            return String(localized: "The paired server address is invalid.")
        }
    }
}

// MARK: - Detail view

/// Chat screen for one OpenCode session. Entry point for the app shell.
struct AidenChatDetailView: View {
    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: AidenChatViewModel
    @State private var composerHeight: CGFloat = 120
    @State private var isScrolledAwayFromLatest = false
    @State private var showsCompactConfirmation = false
    @FocusState private var composerIsFocused: Bool

    init(coordinator: AidenRemoteCoordinator, sessionID: String) {
        let model = AidenChatViewModel(coordinator: coordinator, sessionID: sessionID)
        model.activityReporting = AidenChatActivityReporter(coordinator: coordinator)
        _model = State(initialValue: model)
    }

    private var contentWidthLimit: CGFloat? {
        horizontalSizeClass == .regular ? 720 : nil
    }

    var body: some View {
        chatStack
            .background(palette.canvas.ignoresSafeArea())
            .onPreferenceChange(AidenComposerHeightPreferenceKey.self) { height in
                guard height > 0 else { return }
                composerHeight = height
            }
            .navigationTitle(model.displayTitle ?? String(localized: "Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top, spacing: 0) { topInset }
            .alert(
                String(localized: "Aiden for OpenCode"),
                isPresented: Binding(
                    get: { model.presentedError != nil },
                    set: { if !$0 { model.presentedError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { model.presentedError = nil }
            } message: {
                Text(model.presentedError ?? String(localized: "The operation could not be completed."))
            }
            .confirmationDialog(
                String(localized: "Compact this session's context?"),
                isPresented: $showsCompactConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Compact")) {
                    Task { await model.compact() }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Older messages are summarized to free context space. The transcript stays readable here."))
            }
            .task { await model.load() }
            .onDisappear { model.shutdown() }
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                messageList
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                aidenChatIsScrolledAwayFromLatest(
                    contentOffsetY: geometry.contentOffset.y,
                    containerHeight: geometry.containerSize.height,
                    contentHeight: geometry.contentSize.height,
                    bottomInset: geometry.contentInsets.bottom
                )
            } action: { _, isAwayFromLatest in
                isScrolledAwayFromLatest = isAwayFromLatest
            }
            .simultaneousGesture(
                TapGesture().onEnded { composerIsFocused = false }
            )
            .overlay(alignment: .bottom) {
                if isScrolledAwayFromLatest {
                    AidenChatJumpToLatestButton {
                        isScrolledAwayFromLatest = false
                        scrollToBottom(proxy)
                    }
                    .padding(.bottom, composerHeight + 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isScrolledAwayFromLatest)
            .onChange(of: model.rows.count) { _, _ in
                guard !isScrolledAwayFromLatest else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: model.liveScrollToken) { _, _ in
                guard !isScrolledAwayFromLatest else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: model.hasInteractivePrompts) { _, hasPrompts in
                guard hasPrompts else { return }
                composerIsFocused = false
                scrollToBottom(proxy)
            }
        }
    }

    private var messageList: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if model.isLoading && model.rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            ForEach(model.rows) { row in
                AidenTranscriptRowView(row: row, contentWidthLimit: contentWidthLimit)
            }
            if model.showsLiveOverlay {
                AidenLiveTurnSection(model: model, contentWidthLimit: contentWidthLimit)
            }
            Color.clear
                .frame(height: max(96, composerHeight + 12))
                .accessibilityHidden(true)
            Color.clear.frame(height: 1).id(Self.bottomAnchor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 20)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    static let bottomAnchor = "opencode-chat-bottom"

    private var chatStack: some View {
        ZStack(alignment: .bottom) {
            transcript
            composer
        }
    }

    @ViewBuilder
    private var topInset: some View {
        if model.showsOfflineBanner {
            AidenOfflineBanner(message: model.offlineMessage ?? reconnectBannerFallback)
        }
    }

    private var reconnectBannerFallback: String {
        String(localized: "Offline — waiting for the server…")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendError = model.sendError {
                Label(sendError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.danger)
                    .padding(.horizontal, 4)
            }
            if let notice = model.transientNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 4)
            }
            AidenChatComposerView(model: model, composerFocus: $composerIsFocused)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AidenComposerHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if !model.hasServerTitle, let title = model.displayTitle {
                // Synthesized label shimmers until a real server title lands.
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .aidenActivityShimmer(true)
            }
        }

        if model.isDrainRunning {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.interrupt() }
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(palette.danger)
                }
                .accessibilityLabel(String(localized: "Stop response"))
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                agentMenuSection
                modelMenuSection
                Divider()
                Button {
                    showsCompactConfirmation = true
                } label: {
                    Label(String(localized: "Compact Context"), systemImage: "compress.vertical")
                }
                .disabled(model.isCompacting)
            } label: {
                Image(systemName: AidenChromeSymbols.overflowMenu)
                    .font(.body.weight(.semibold))
                    .contentShape(Circle())
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(String(localized: "Session options"))
        }
    }

    @ViewBuilder
    private var agentMenuSection: some View {
        Section(String(localized: "Agent")) {
            if model.visibleAgents.isEmpty {
                Text(String(localized: "No agents available"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.visibleAgents, id: \.id) { agent in
                    Button {
                        Task { await model.switchAgent(to: agent.id) }
                    } label: {
                        if model.selectedAgentID == agent.id {
                            Label(agent.id, systemImage: "checkmark")
                        } else {
                            Text(agent.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelMenuSection: some View {
        Section(String(localized: "Model")) {
            if model.models.isEmpty {
                Text(String(localized: "No models available"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.modelSections, id: \.providerID) { section in
                    Section {
                        ForEach(section.models, id: \.identifier) { candidate in
                            Button {
                                Task { await model.switchModel(to: ModelRef(providerID: candidate.providerID, modelID: candidate.id)) }
                            } label: {
                                if model.currentModelIdentifier == candidate.identifier {
                                    Label(candidate.name, systemImage: "checkmark")
                                } else {
                                    Text(candidate.name)
                                }
                            }
                        }
                    } header: {
                        Label {
                            Text(section.providerID)
                        } icon: {
                            AidenProviderIcon(
                                providerID: section.providerID,
                                providerLabel: section.providerID,
                                size: 15,
                                color: palette.secondary
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct AidenComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 120

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Transcript rows

private struct AidenTranscriptRowView: View {
    @Environment(\.aidenPalette) private var palette
    let row: AidenChatRow
    let contentWidthLimit: CGFloat?

    /// Copy payload for the context menu / accessibility action.
    private var copyText: String? {
        switch row.role {
        case .user:
            return row.userText
        case .assistant:
            let text = row.blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }
            .joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        case .system, .divider:
            return nil
        }
    }

    var body: some View {
        Group {
            switch row.role {
            case .user:
                bubbleColumn(alignment: .trailing)
            case .assistant:
                HStack(alignment: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Self.groupedBlocks(row.blocks).enumerated()), id: \.offset) { _, group in
                            groupView(group)
                        }
                        if let outcome = row.outcome {
                            AidenOutcomeCard(outcome: outcome)
                        }
                    }
                    .frame(maxWidth: contentWidthLimit ?? .infinity, alignment: .leading)
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .system:
                Text(row.text)
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            case .divider:
                HStack(spacing: 10) {
                    line
                    Text(row.text)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                    line
                }
                .accessibilityElement(children: .combine)
            }
        }
        .contextMenu {
            if let text = copyText {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                }
            }
        }
        .accessibilityActions {
            if let text = copyText {
                Button(String(localized: "Copy response")) {
                    UIPasteboard.general.string = text
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var line: some View {
        Rectangle()
            .fill(palette.foreground.opacity(0.12))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }

    private func bubbleColumn(alignment: HorizontalAlignment) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if alignment == .trailing { Spacer(minLength: 48) }
            VStack(alignment: alignment, spacing: 10) {
                ForEach(Array(row.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.raised)
            )
            .frame(maxWidth: contentWidthLimit.map { min($0, 520) }, alignment: alignment == .trailing ? Alignment.trailing : Alignment.leading)
            if alignment == .leading { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? Alignment.trailing : Alignment.leading)
    }

    // MARK: blocks

    /// Consecutive tool blocks collapse into one collapsible activity feed so
    /// a durable assistant message renders its tool run as a single unit.
    private enum BlockGroup {
        case single(AidenChatBlock)
        case tools([AidenToolActivity])
    }

    private static func groupedBlocks(_ blocks: [AidenChatBlock]) -> [BlockGroup] {
        var groups: [BlockGroup] = []
        for block in blocks {
            if case .tool(let activity) = block {
                if case .tools(var existing) = groups.last {
                    existing.append(activity)
                    groups[groups.count - 1] = .tools(existing)
                } else {
                    groups.append(.tools([activity]))
                }
            } else {
                groups.append(.single(block))
            }
        }
        return groups
    }

    @ViewBuilder
    private func groupView(_ group: BlockGroup) -> some View {
        switch group {
        case .single(let block):
            blockView(block)
        case .tools(let activities):
            AidenToolActivityFeed(activities: activities, active: false, progressText: nil)
        }
    }

    @ViewBuilder
    private func blockView(_ block: AidenChatBlock) -> some View {
        switch block {
        case .text(let text):
            if row.role == .user {
                Text(verbatim: text)
                    .font(.body)
                    .textSelection(.enabled)
            } else {
                AidenMarkdownView(content: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .reasoning(_, let text):
            AidenReasoningCard(text: text, active: false)
        case .tool:
            EmptyView()
        }
    }
}

// MARK: - Tool activity feed

/// Collapsible run summary for a group of tool invocations. Collapsed, it
/// streams the last three live steps bottom-aligned; expanded, it lists every
/// step plus an optional progress paragraph.
private struct AidenToolActivityFeed: View {
    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenReduceMotion) private var reduceMotion
    let activities: [AidenToolActivity]
    let active: Bool
    let progressText: String?
    @State private var isExpanded = false

    private static let collapsedLineHeight: CGFloat = 24

    private func isActive(_ activity: AidenToolActivity) -> Bool {
        activity.phase == .preparing || activity.phase == .running
    }

    private var isRunning: Bool { active && activities.contains(where: isActive) }
    private var failedCount: Int { activities.filter { $0.phase == .failed }.count }
    /// Last three steps stream through the collapsed header while running.
    private var collapsedSteps: [AidenToolActivity] { Array(activities.suffix(3)) }

    private var summaryLine: String {
        let names = Array(Set(activities.map(\.name))).sorted()
        guard !names.isEmpty else { return String(localized: "Working") }
        let visible = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(visible), +\(names.count - 3)" : visible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 4 : 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(
                    alignment: isRunning && !isExpanded ? .bottom : .center,
                    spacing: 8
                ) {
                    Group {
                        if isRunning && !isExpanded {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(collapsedSteps) { activity in
                                    AidenToolStepLine(activity: activity, shimmer: isActive(activity))
                                        .frame(height: Self.collapsedLineHeight)
                                        .id(activity.id)
                                        .transition(.opacity)
                                }
                            }
                            .frame(
                                height: CGFloat(collapsedSteps.count) * Self.collapsedLineHeight,
                                alignment: .bottom
                            )
                            .clipped()
                        } else {
                            Text(summaryLine)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                                .aidenActivityShimmer(isRunning)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if failedCount > 0 {
                        Text(failedCount == 1 ? String(localized: "1 issue") : String(localized: "\(failedCount) issues"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.warning)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Tool activity"))
            .accessibilityValue(summaryLine)
            .accessibilityHint(isExpanded ? String(localized: "Collapses activity") : String(localized: "Expands activity"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(activities) { activity in
                        AidenToolStepLine(activity: activity, shimmer: isRunning && isActive(activity))
                    }
                    if let progressText, !progressText.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        Text(String(localized: "Updates"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondary)
                        Text(verbatim: progressText)
                            .font(.caption)
                            .foregroundStyle(palette.secondary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(.top, 1)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: activities.last?.id)
        .onAppear {
            // Failed steps deserve eyes; everything else stays folded.
            if failedCount > 0 { isExpanded = true }
        }
    }
}

/// One tool invocation line: verb prefix, semibold tool name, monospaced
/// input/output tail.
private struct AidenToolStepLine: View {
    @Environment(\.aidenPalette) private var palette
    let activity: AidenToolActivity
    let shimmer: Bool

    private var tone: Color {
        activity.phase == .failed ? palette.danger : palette.secondary
    }

    private var preview: String {
        activity.previewLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verb)
            Text(activity.name)
                .fontWeight(.semibold)
            if !preview.isEmpty {
                Text(verbatim: preview)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(tone)
        .lineLimit(1)
        .truncationMode(.tail)
        .aidenActivityShimmer(shimmer)
        .accessibilityElement(children: .combine)
    }

    private var verb: String {
        switch activity.phase {
        case .preparing:
            return String(localized: "Preparing")
        case .failed:
            return String(localized: "Failed")
        case .running, .completed:
            let pair = Self.verbs[activity.name.lowercased()] ?? (String(localized: "Using"), String(localized: "Used"))
            return activity.phase == .running ? pair.0 : pair.1
        }
    }

    private static let verbs: [String: (String, String)] = [
        "bash": (String(localized: "Running"), String(localized: "Ran")),
        "read": (String(localized: "Reading"), String(localized: "Read")),
        "write": (String(localized: "Writing"), String(localized: "Wrote")),
        "edit": (String(localized: "Editing"), String(localized: "Edited")),
        "patch": (String(localized: "Patching"), String(localized: "Patched")),
        "glob": (String(localized: "Searching files"), String(localized: "Searched files")),
        "grep": (String(localized: "Grepping"), String(localized: "Grepped")),
        "list": (String(localized: "Listing"), String(localized: "Listed")),
        "ls": (String(localized: "Listing"), String(localized: "Listed")),
        "websearch": (String(localized: "Searching the web"), String(localized: "Searched the web")),
        "webfetch": (String(localized: "Fetching"), String(localized: "Fetched")),
        "task": (String(localized: "Delegating"), String(localized: "Delegated")),
        "todowrite": (String(localized: "Planning"), String(localized: "Planned")),
    ]
}

// MARK: - Activity shimmer

/// Sweeping highlight used while a label represents live work.
private struct AidenActivityShimmerModifier: ViewModifier {
    @Environment(\.aidenReduceMotion) private var reduceMotion
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.overlay {
                GeometryReader { proxy in
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let cycle = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.8) / 1.8
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.42), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(proxy.size.width * 0.55, 36))
                        .offset(x: (proxy.size.width * 1.55 * cycle) - proxy.size.width * 0.55)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

private extension View {
    func aidenActivityShimmer(_ active: Bool) -> some View {
        modifier(AidenActivityShimmerModifier(active: active))
    }
}

// MARK: - Reasoning disclosure

private struct AidenReasoningCard: View {
    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenReduceMotion) private var reduceMotion
    let text: String
    let active: Bool
    @State private var isExpanded = false
    @State private var userControlled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                userControlled = true
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(active ? String(localized: "Thinking…") : String(localized: "Thinking"))
                        .font(.caption.weight(.semibold))
                        .aidenActivityShimmer(active)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Reasoning"))
            .accessibilityHint(isExpanded ? String(localized: "Collapses reasoning") : String(localized: "Expands reasoning"))

            if isExpanded, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .frame(maxHeight: 144, alignment: .top)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .onAppear {
            isExpanded = active && !userControlled
        }
        .onChange(of: active) { _, isActive in
            guard !userControlled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isExpanded = isActive
            }
        }
    }
}

// MARK: - Outcome card

private struct AidenOutcomeCard: View {
    @Environment(\.aidenPalette) private var palette
    let outcome: AidenTurnOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: outcome.symbol)
                .foregroundStyle(outcome.isFailure ? palette.danger : palette.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title)
                    .fontWeight(.semibold)
                if let detail = outcome.detail {
                    Text(detail)
                        .foregroundStyle(palette.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(10)
        .background(
            outcome.isFailure ? palette.danger.opacity(0.08) : palette.raised,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Live turn section

private struct AidenLiveTurnSection: View {
    @Environment(\.aidenPalette) private var palette
    @Bindable var model: AidenChatViewModel
    let contentWidthLimit: CGFloat?

    private var statusLine: (label: String, orb: OrbState)? {
        if !model.approvals.isEmpty { return (String(localized: "Waiting for approval"), .listening) }
        if !model.questions.isEmpty { return (String(localized: "Answer needed"), .listening) }
        if model.liveTurn.hasRunningTool {
            let tool = model.liveTurn.tools.last { $0.phase == .running || $0.phase == .preparing }
            let name = (tool?.name ?? "").lowercased()
            let isSearch = ["search", "find", "read", "list", "glob", "grep"].contains { name.contains($0) }
            return (isSearch ? String(localized: "Searching…") : String(localized: "Working…"), isSearch ? .searching : .working)
        }
        if !model.liveTurn.liveText.isEmpty { return (String(localized: "Responding…"), .composing) }
        // Streaming has begun but no reasoning, tools, or text arrived yet.
        let hasStreamedContent = !model.liveTurn.liveReasoning.isEmpty || !model.liveTurn.tools.isEmpty
        if model.streamState == .streaming && !hasStreamedContent {
            return (String(localized: "Preparing…"), .shaping)
        }
        if model.streamState == .streaming || model.streamState == .waitingApproval || model.liveTurn.isStepActive {
            return (String(localized: "Thinking…"), .solving)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = statusLine {
                HStack(spacing: 8) {
                    ThinkingOrb(state: status.orb, size: .px20)
                    Text(status.label)
                        .foregroundStyle(palette.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }

            let reasoning = model.liveTurn.liveReasoning
            if !reasoning.isEmpty {
                AidenReasoningCard(text: reasoning, active: model.liveTurn.isStepActive)
                    .transition(.opacity)
            }

            if !model.liveTurn.tools.isEmpty {
                AidenToolActivityFeed(
                    activities: model.liveTurn.tools,
                    active: true,
                    progressText: nil
                )
                .transition(.opacity)
            }

            ForEach(model.approvals) { approval in
                AidenPermissionCard(
                    prompt: approval,
                    isBusy: model.respondingRequestID == approval.requestID,
                    onReply: { reply in
                        Task { await model.respondToApproval(reply, requestID: approval.requestID) }
                    }
                )
            }

            ForEach(model.questions) { question in
                AidenQuestionCard(
                    prompt: question,
                    isBusy: model.respondingRequestID == question.requestID,
                    onAnswer: { answers in
                        Task { await model.answerQuestion(requestID: question.requestID, answers: answers) }
                    },
                    onReject: {
                        Task { await model.rejectQuestion(requestID: question.requestID) }
                    }
                )
            }

            if let failure = model.liveTurn.failureMessage {
                AidenOutcomeCard(outcome: AidenTurnOutcome(kind: .failed, message: failure))
            }

            let text = model.liveTurn.liveText
            if !text.isEmpty {
                AidenMarkdownView(content: text)
                    .frame(maxWidth: contentWidthLimit ?? .infinity, alignment: .leading)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                        }
                    }
                    .accessibilityActions {
                        Button(String(localized: "Copy response")) {
                            UIPasteboard.general.string = text
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permission card

private struct AidenPermissionCard: View {
    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenReduceMotion) private var reduceMotion
    let prompt: AidenApprovalPrompt
    let isBusy: Bool
    let onReply: (PermissionReply) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.warning)
                    .frame(width: 32, height: 32)
                    .background(palette.warning.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Approval needed"))
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "The agent is asking permission to continue."))
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(prompt.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(palette.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(String(localized: "Requested action"))
            .accessibilityValue(prompt.summary)
            .accessibilityHint(isExpanded ? String(localized: "Collapses action details") : String(localized: "Expands action details"))

            if isExpanded {
                Text(prompt.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                AidenGlassCapsuleButton(title: String(localized: "Deny"), tint: nil) { onReply(.reject) }
                AidenGlassCapsuleButton(title: String(localized: "Always"), tint: nil) { onReply(.always) }
                AidenGlassCapsuleButton(title: String(localized: "Allow once"), tint: palette.accent) { onReply(.once) }
            }
            .disabled(isBusy)
        }
        .padding(12)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.foreground.opacity(0.08), lineWidth: 0.5))
        .shadow(color: palette.foreground.opacity(0.08), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Glass capsule action button

/// Capsule action used by the approval/question cards: interactive Liquid
/// Glass on iOS 26, tinted fill or material capsule below that.
private struct AidenGlassCapsuleButton: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.aidenPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint == nil ? palette.foreground : palette.canvas)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .modifier(AidenApprovalActionGlassModifier(tint: tint))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct AidenApprovalActionGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.aidenPalette) private var palette

    let tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
            } else {
                content.glassEffect(.regular.interactive(), in: Capsule())
            }
        } else if let tint {
            content.background(tint, in: Capsule())
        } else if reduceTransparency {
            content
                .background(palette.canvas, in: Capsule())
                .overlay(Capsule().stroke(palette.foreground.opacity(0.14), lineWidth: 0.5))
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(palette.foreground.opacity(0.10), lineWidth: 0.5))
        }
    }
}

// MARK: - Question card

private struct AidenQuestionCard: View {
    @Environment(\.aidenPalette) private var palette
    let prompt: AidenQuestionPrompt
    let isBusy: Bool
    let onAnswer: ([[String]]) -> Void
    let onReject: () -> Void

    @State private var selections: [[Int]] = []
    @State private var customText = ""

    private func normalizedSelections() -> [[Int]] {
        if selections.count == prompt.questions.count { return selections }
        return prompt.questions.map { _ in [] }
    }

    private var canSubmit: Bool {
        guard !isBusy else { return false }
        return normalizedSelections().contains { !$0.isEmpty } || !customText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 32, height: 32)
                    .background(palette.accent.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                Text(String(localized: "The agent needs your input"))
                    .font(.subheadline.weight(.semibold))
            }

            ForEach(prompt.questions.indices, id: \.self) { questionIndex in
                let question = prompt.questions[questionIndex]
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                    Text(question.question)
                        .font(.callout)
                    ForEach(question.options.indices, id: \.self) { optionIndex in
                        optionRow(questionIndex: questionIndex, optionIndex: optionIndex, option: question.options[optionIndex])
                    }
                }
            }

            if prompt.allowsCustom {
                TextField(
                    String(localized: "Custom answer"),
                    text: $customText,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(isBusy)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                AidenGlassCapsuleButton(title: String(localized: "Reject"), tint: nil) { onReject() }
                    .disabled(isBusy)
                AidenGlassCapsuleButton(
                    title: String(localized: "Reply"),
                    tint: canSubmit ? palette.accent : nil
                ) {
                    onAnswer(prompt.answers(selections: normalizedSelections(), customText: customText))
                }
                .disabled(!canSubmit || isBusy)
            }
        }
        .padding(12)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.foreground.opacity(0.08), lineWidth: 0.5))
        .shadow(color: palette.foreground.opacity(0.08), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }

    private func isSelected(questionIndex: Int, optionIndex: Int) -> Bool {
        guard selections.indices.contains(questionIndex) else { return false }
        return selections[questionIndex].contains(optionIndex)
    }

    private func toggleSelection(questionIndex: Int, optionIndex: Int) {
        if selections.count != prompt.questions.count {
            selections = prompt.questions.map { _ in [] }
        }
        var chosen = selections[questionIndex]
        if chosen.contains(optionIndex) {
            chosen.removeAll { $0 == optionIndex }
        } else {
            if prompt.multiple {
                chosen.append(optionIndex)
            } else {
                chosen = [optionIndex]
            }
        }
        selections[questionIndex] = chosen
    }

    private func optionRow(questionIndex: Int, optionIndex: Int, option: QuestionOption) -> some View {
        Button {
            toggleSelection(questionIndex: questionIndex, optionIndex: optionIndex)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected(questionIndex: questionIndex, optionIndex: optionIndex) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected(questionIndex: questionIndex, optionIndex: optionIndex) ? palette.accent : palette.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.callout.weight(.medium))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption2)
                            .foregroundStyle(palette.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected(questionIndex: questionIndex, optionIndex: optionIndex)
                    ? palette.accent.opacity(0.12)
                    : palette.canvas.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}

// MARK: - Offline banner

private struct AidenOfflineBanner: View {
    @Environment(\.aidenPalette) private var palette
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Composer

private struct AidenChatComposerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.aidenPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.aidenReduceMotion) private var reduceMotion
    @Bindable var model: AidenChatViewModel
    let composerFocus: FocusState<Bool>.Binding
    @State private var voiceInput = ComposerVoiceInputController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(String(localized: "Message Aiden"), text: $model.draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 4)
                .padding(.top, 5)
                .focused(composerFocus)
                .disabled(voiceInput.isBusy && !voiceInput.isListening)
                .onChange(of: scenePhase) { _, phase in
                    // OLD parity: backgrounding discards an in-flight dictation.
                    if phase == .background, voiceInput.isListening {
                        voiceInput.stopBeforeSubmittingDraft()
                    }
                }
                .submitLabel(.send)
                .onSubmit {
                    voiceInput.stopBeforeSubmittingDraft()
                    Task { await model.send() }
                }

            HStack(alignment: .center, spacing: 10) {
                Button {
                    Task {
                        await voiceInput.toggle(
                            currentDraft: model.draft,
                            updateDraft: { model.draft = $0 }
                        )
                    }
                } label: {
                    Group {
                        if voiceInput.isListening {
                            AidenListeningWaveform(isAnimated: !reduceMotion)
                        } else {
                            Image(systemName: "mic")
                                .font(.body.weight(.medium))
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(voiceInput.isBusy && !voiceInput.isListening)
                .accessibilityLabel(voiceInput.isListening ? String(localized: "Stop voice input") : String(localized: "Start voice input"))

                Spacer(minLength: 0)

                if model.isDrainRunning {
                    Button {
                        Task { await model.interrupt() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 30, height: 30)
                            .background(palette.foreground, in: Circle())
                            .foregroundStyle(palette.canvas)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Stop response"))
                } else {
                    Button {
                        voiceInput.stopBeforeSubmittingDraft()
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.headline.bold())
                            .frame(width: 30, height: 30)
                            .background(sendButtonBackground, in: Circle())
                            .foregroundStyle(sendButtonForeground)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canSend)
                    .accessibilityLabel(String(localized: "Send message"))
                }
            }

            if let error = voiceInput.errorMessage, !voiceInput.isListening {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .composerSurface(palette: palette)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(palette.secondary.opacity(0.35), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .onDisappear {
            voiceInput.stopKeepingTranscript()
        }
    }

    private var sendButtonBackground: Color {
        if model.canSend { return palette.accent }
        return palette.foreground.opacity(colorScheme == .dark ? 0.18 : 0.12)
    }

    private var sendButtonForeground: Color {
        model.canSend ? palette.canvas : palette.secondary
    }
}


private struct AidenComposerSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let palette: AidenPalette
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    // The whole composer is a stable surface containing its own interactive
    // controls. Marking the container interactive causes Liquid Glass to
    // recompute multiple times during streamed updates.
    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            content.glassEffect(.regular, in: shape)
        } else if reduceTransparency {
            content.background(palette.raised, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private extension View {
    func composerSurface(palette: AidenPalette) -> some View {
        modifier(AidenComposerSurfaceModifier(palette: palette))
    }
}

private struct AidenListeningWaveform: View {
    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !isAnimated)) { context in
            let phase = isAnimated ? context.date.timeIntervalSinceReferenceDate * 7 : 0
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    let offset = Double(index) * 0.85
                    let amplitude = isAnimated ? abs(sin(phase + offset)) : 0.45
                    Capsule(style: .continuous)
                        .frame(width: 2.5, height: 19)
                        .scaleEffect(
                            x: 1,
                            y: (7 + (amplitude * 12)) / 19,
                            anchor: .center
                        )
                }
            }
            .frame(width: 24, height: 22)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - New session sheet

/// Agent/model pickers feeding `createSession(agent:model:directory:)`.
/// Presented by the app shell.
struct AidenNewSessionSheet: View {
    let coordinator: AidenRemoteCoordinator
    var onCreate: (SessionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.aidenPalette) private var palette
    @State private var agents: [AgentInfo] = []
    @State private var models: [ModelInfo] = []
    @State private var selectedAgentID: String?
    @State private var selectedModelIdentifier: String?
    @State private var isSubmitting = false
    @State private var errorText: String?
    private let directoryOverride: String?

    init(
        coordinator: AidenRemoteCoordinator,
        agent: String? = nil,
        directory: String? = nil,
        onCreate: @escaping (SessionInfo) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.onCreate = onCreate
        directoryOverride = directory
        _selectedAgentID = State(initialValue: agent)
    }

    /// Explicit override wins; otherwise sessions land in the connected
    /// server's working directory.
    private var directory: String? {
        if let directoryOverride { return directoryOverride }
        if case .connected(server: let server) = coordinator.connectionState {
            return server.directory
        }
        return nil
    }

    private var selectedModelRef: ModelRef? {
        guard let selectedModelIdentifier else { return nil }
        guard let model = models.first(where: { $0.identifier == selectedModelIdentifier }) else { return nil }
        return ModelRef(providerID: model.providerID, modelID: model.id)
    }

    private var canCreate: Bool { !isSubmitting }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Agent")) {
                    if agents.isEmpty {
                        Text(String(localized: "Loading agents…"))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(String(localized: "Agent"), selection: $selectedAgentID) {
                            Text(String(localized: "Default")).tag(String?.none)
                            ForEach(agents.filter { !$0.hidden }, id: \.id) { agent in
                                VStack(alignment: .leading) {
                                    Text(agent.id)
                                    if let description = agent.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(String?.some(agent.id))
                            }
                        }
                    }
                }

                Section(String(localized: "Model")) {
                    if models.isEmpty {
                        Text(String(localized: "Loading models…"))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(String(localized: "Model"), selection: $selectedModelIdentifier) {
                            Text(String(localized: "Session default")).tag(String?.none)
                            ForEach(groupedModels, id: \.providerID) { group in
                                Section {
                                    ForEach(group.models, id: \.identifier) { model in
                                        Text(model.name).tag(String?.some(model.identifier))
                                    }
                                } header: {
                                    Text(group.providerID)
                                }
                            }
                        }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(palette.danger)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(String(localized: "New Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create")) {
                        Task { await create() }
                    }
                    .disabled(!canCreate)
                }
            }
            .task { await loadCatalogs() }
        }
        .presentationDetents([.medium, .large])
    }

    private var groupedModels: [(providerID: String, models: [ModelInfo])] {
        let grouped = Dictionary(grouping: models.filter(\.enabled), by: \.providerID)
        return grouped.keys.sorted().map { providerID in
            (providerID, grouped[providerID] ?? [])
        }
    }

    private func loadCatalogs() async {
        do {
            let client = try coordinator.client()
            async let agentRequest = client.agents()
            async let modelRequest = client.models()
            let (fetchedAgents, fetchedModels) = try await (agentRequest, modelRequest)
            agents = fetchedAgents
            models = fetchedModels
            if selectedAgentID == nil {
                selectedAgentID = fetchedAgents.first(where: { !$0.hidden && ($0.mode == "primary" || $0.mode == "all") })?.id
            }
            if selectedModelIdentifier == nil {
                selectedModelIdentifier = fetchedModels.first(where: \.enabled)?.identifier
            }
        } catch {
            errorText = AidenChatViewModel.friendlyMessage(for: error)
        }
    }

    private func create() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            let client = try coordinator.client()
            let created = try await client.createSession(
                agent: selectedAgentID,
                model: selectedModelRef,
                directory: directory
            )
            dismiss()
            onCreate(created)
        } catch {
            errorText = AidenChatViewModel.friendlyMessage(for: error)
        }
    }
}

/// OLD-parity scrolled-away heuristic: true when the viewport lags the newest
/// content by more than `threshold` points.
func aidenChatIsScrolledAwayFromLatest(
    contentOffsetY: CGFloat,
    containerHeight: CGFloat,
    contentHeight: CGFloat,
    bottomInset: CGFloat,
    threshold: CGFloat = 72
) -> Bool {
    guard containerHeight > 0, contentHeight > containerHeight else { return false }
    let viewportBottom = contentOffsetY + containerHeight
    let contentBottom = contentHeight + max(0, bottomInset)
    return contentBottom - viewportBottom > threshold
}

private struct AidenChatJumpToLatestButton: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.aidenPalette) private var palette

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .modifier(AidenChatJumpToLatestGlassModifier(reduceTransparency: reduceTransparency))
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(String(localized: "Jump to latest"))
        .accessibilityHint(String(localized: "Scrolls to the newest message"))
    }
}

private struct AidenChatJumpToLatestGlassModifier: ViewModifier {
    @Environment(\.aidenPalette) private var palette
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else if reduceTransparency {
            content.background(palette.raised, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}
