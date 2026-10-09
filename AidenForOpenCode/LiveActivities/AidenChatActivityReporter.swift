import Foundation

/// Bridges chat-stream milestones into the shared Live Activity manager so
/// paired-session runs surface on the Lock Screen without carrying message
/// content — only bounded titles/state text.
@MainActor
struct AidenChatActivityReporter: ChatActivityReporting {
    let coordinator: AidenRemoteCoordinator

    func started(sessionID: String, title: String) async {
        guard let instanceID = coordinator.instanceId else { return }
        await AidenRemoteLiveActivityManager.shared.start(
            instanceID: instanceID,
            sessionID: sessionID,
            sessionTitle: title,
            serverName: serverName
        )
    }

    func updated(sessionID: String, status: AgentRunActivityStatus, activity: String) async {
        guard let instanceID = coordinator.instanceId else { return }
        await AidenRemoteLiveActivityManager.shared.update(
            instanceID: instanceID,
            sessionID: sessionID,
            status: status,
            activity: activity
        )
    }

    func finished(sessionID: String, summary: String, status: AgentRunActivityStatus) async {
        guard let instanceID = coordinator.instanceId else { return }
        await AidenRemoteLiveActivityManager.shared.finish(
            instanceID: instanceID,
            sessionID: sessionID,
            status: status,
            message: summary
        )
    }

    private var serverName: String? {
        if case .connected(server: let server) = coordinator.connectionState {
            return server.name
        }
        return nil
    }
}
