import ActivityKit
import Foundation

/// Owns the app-side Live Activity lifecycle for one OpenCode session run.
/// The widget renders only the bounded state written here and never receives
/// network credentials. Driven from the chat view model: start on prompt
/// admission, update on progress, finish on step end / idle.
@MainActor
final class AidenRemoteLiveActivityManager {
    static let shared = AidenRemoteLiveActivityManager()

    private var currentActivity: Activity<AgentRunActivityAttributes>?
    private var stateByActivityID: [String: AgentRunActivityAttributes.ContentState] = [:]

    nonisolated static func matches(
        _ attributes: AgentRunActivityAttributes,
        instanceID: String,
        sessionID: String
    ) -> Bool {
        attributes.instanceID == instanceID && attributes.sessionID == sessionID
    }

    /// Starts (or adopts) the Live Activity for one session run.
    func start(
        instanceID: String,
        sessionID: String,
        sessionTitle: String,
        serverName: String? = nil,
        startedAt: Date = Date()
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = AgentRunActivityStateReducer.initialState(
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            startedAt: startedAt
        )

        if let existing = activity(instanceID: instanceID, sessionID: sessionID) {
            currentActivity = existing
            await update(existing) { _ in state }
            return
        }

        let attributes = AgentRunActivityAttributes(
            instanceID: instanceID,
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            serverName: serverName,
            startedAt: startedAt
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content(for: state),
                pushType: nil
            )
            currentActivity = activity
            stateByActivityID[activity.id] = state
        } catch {
            currentActivity = nil
        }
    }

    /// Updates the bounded status line for a running session.
    func update(instanceID: String, sessionID: String, stateText: String, isRunning: Bool = true) async {
        await update(instanceID: instanceID, sessionID: sessionID) { state in
            AgentRunActivityStateReducer.applying(
                status: isRunning ? inferStatus(from: stateText) : .responding,
                activity: stateText,
                state: state
            )
        }
    }

    func update(
        instanceID: String,
        sessionID: String,
        status: AgentRunActivityStatus,
        activity: String
    ) async {
        await update(instanceID: instanceID, sessionID: sessionID) {
            AgentRunActivityStateReducer.applying(status: status, activity: activity, state: $0)
        }
    }

    func toolStarted(name: String?, instanceID: String, sessionID: String) async {
        await update(instanceID: instanceID, sessionID: sessionID) {
            AgentRunActivityStateReducer.toolStarted(name: name, state: $0)
        }
    }

    func waitingForApproval(instanceID: String, sessionID: String) async {
        await update(instanceID: instanceID, sessionID: sessionID) {
            AgentRunActivityStateReducer.applying(
                status: .waitingForApproval,
                activity: String(localized: "Waiting for approval"),
                state: $0
            )
        }
    }

    /// Ends the activity with a final status line.
    func finish(instanceID: String, sessionID: String, stateText: String) async {
        await finish(instanceID: instanceID, sessionID: sessionID, stateText: stateText, failed: false)
    }

    /// Failures/cancellations clear quickly; successful ends linger longer.
    func finish(instanceID: String, sessionID: String, stateText: String, failed: Bool) async {
        await finish(
            instanceID: instanceID,
            sessionID: sessionID,
            status: failed ? .failed : .complete,
            message: stateText
        )
    }

    func finish(
        instanceID: String,
        sessionID: String,
        status: AgentRunActivityStatus,
        message: String,
        errorSummary: String? = nil
    ) async {
        guard let activity = activity(instanceID: instanceID, sessionID: sessionID) else { return }
        let state = AgentRunActivityStateReducer.final(
            status: status,
            activity: message,
            state: state(for: activity),
            errorSummary: errorSummary
        )
        stateByActivityID[activity.id] = state
        let linger: TimeInterval = status == .complete ? 300 : 30
        await activity.end(
            content(for: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(linger))
        )
        stateByActivityID[activity.id] = nil
        if currentActivity?.id == activity.id { currentActivity = nil }
    }

    /// Ends every Live Activity for one installation (unpair / forget server).
    func endAll(instanceID: String) async {
        for activity in Activity<AgentRunActivityAttributes>.activities
        where activity.attributes.instanceID == instanceID {
            await activity.end(nil, dismissalPolicy: .immediate)
            stateByActivityID[activity.id] = nil
            if currentActivity?.id == activity.id { currentActivity = nil }
        }
    }

    /// Ends restored activities whose sessions are no longer live after relaunch.
    func endOrphanedActivities(keepingSessionIDs liveSessionIDs: Set<String>, instanceID: String) async {
        for activity in Activity<AgentRunActivityAttributes>.activities
        where activity.attributes.instanceID == instanceID && isLive(activity) {
            if liveSessionIDs.contains(activity.attributes.sessionID) { continue }
            await finish(
                instanceID: instanceID,
                sessionID: activity.attributes.sessionID,
                status: .cancelled,
                message: String(localized: "Session ended")
            )
        }
    }

    /// Flags every live activity as stale — used when the app leaves the
    /// foreground or loses its connection and can no longer refresh state.
    func markAllStale() async {
        for activity in Activity<AgentRunActivityAttributes>.activities where isLive(activity) {
            let previous = self.state(for: activity)
            guard previous.isRunning else { continue }
            let stale = AgentRunActivityStateReducer.stale(state: previous)
            stateByActivityID[activity.id] = stale
            await activity.update(content(for: stale))
        }
    }

    private func update(
        instanceID: String,
        sessionID: String,
        transform: (AgentRunActivityAttributes.ContentState) -> AgentRunActivityAttributes.ContentState
    ) async {
        guard let activity = activity(instanceID: instanceID, sessionID: sessionID) else { return }
        await update(activity, transform: transform)
    }

    private func update(
        _ activity: Activity<AgentRunActivityAttributes>,
        transform: (AgentRunActivityAttributes.ContentState) -> AgentRunActivityAttributes.ContentState
    ) async {
        guard isLive(activity) else { return }
        currentActivity = activity
        let state = transform(state(for: activity))
        stateByActivityID[activity.id] = state
        await activity.update(content(for: state))
    }

    private func state(
        for activity: Activity<AgentRunActivityAttributes>
    ) -> AgentRunActivityAttributes.ContentState {
        if let state = stateByActivityID[activity.id] { return state }
        let state = activity.content.state
        stateByActivityID[activity.id] = state
        return state
    }

    private func activity(instanceID: String, sessionID: String) -> Activity<AgentRunActivityAttributes>? {
        if let currentActivity,
           Self.matches(currentActivity.attributes, instanceID: instanceID, sessionID: sessionID),
           isLive(currentActivity) {
            return currentActivity
        }
        return Activity<AgentRunActivityAttributes>.activities.first {
            Self.matches($0.attributes, instanceID: instanceID, sessionID: sessionID) && isLive($0)
        }
    }

    private func isLive(_ activity: Activity<AgentRunActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    private func content(
        for state: AgentRunActivityAttributes.ContentState,
        staleDate: Date? = Date().addingTimeInterval(300)
    ) -> ActivityContent<AgentRunActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.isFinal ? nil : staleDate)
    }

    private func inferStatus(from stateText: String) -> AgentRunActivityStatus {
        AgentRunActivityProgress.snapshot(
            waitingForApproval: stateText.localizedCaseInsensitiveContains("approval"),
            runningToolName: nil,
            hasLiveText: stateText.localizedCaseInsensitiveContains("respond")
                || stateText.localizedCaseInsensitiveContains("writing"),
            isThinking: stateText.localizedCaseInsensitiveContains("think")
        ).status
    }
}
