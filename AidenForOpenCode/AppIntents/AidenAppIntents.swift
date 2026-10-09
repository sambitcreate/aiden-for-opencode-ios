import AppIntents
import Foundation

/// One navigable destination cached in the App Group: a recent session.
/// Only display names and stable ids are stored — never endpoints,
/// credentials, or prompt content.
struct AidenIntentSessionRecord: Codable, Equatable, Sendable {
    let instanceId: String
    let sessionId: String
    let title: String
}

struct AidenIntentCatalogSnapshot: Codable, Equatable, Sendable {
    var sessionsByInstance: [String: [AidenIntentSessionRecord]] = [:]
}

/// App-Group cache feeding App Intents and Spotlight suggestions. Contains
/// session titles/ids keyed by installation id only.
struct AidenIntentCatalogStore: @unchecked Sendable {
    static let shared = AidenIntentCatalogStore()
    private static let key = "aiden.intent-catalog.v2"
    private static let maximumSessionsPerInstance = 20
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else {
            self.defaults = UserDefaults(suiteName: AppConfig.appGroupIdentifier)
        }
    }

    func load() -> AidenIntentCatalogSnapshot {
        guard let data = defaults?.data(forKey: Self.key), data.count <= 1_048_576,
              let value = try? JSONDecoder().decode(AidenIntentCatalogSnapshot.self, from: data) else {
            return AidenIntentCatalogSnapshot()
        }
        var sanitized = AidenIntentCatalogSnapshot()
        for (instanceId, sessions) in value.sessionsByInstance {
            guard Self.safeID(instanceId) else { continue }
            sanitized.sessionsByInstance[instanceId] = Array(
                sessions.filter { Self.safeID($0.instanceId) && Self.safeID($0.sessionId) && Self.safeName($0.title) }
                    .prefix(Self.maximumSessionsPerInstance)
            )
        }
        return sanitized
    }

    /// Replaces the cached recent-session list for one installation.
    func update(sessions: [AidenIntentSessionRecord], for instanceId: String?) async {
        guard let instanceId, Self.safeID(instanceId) else { return }
        let cleaned = Array(
            sessions.filter { $0.instanceId == instanceId && Self.safeID($0.sessionId) && Self.safeName($0.title) }
                .prefix(Self.maximumSessionsPerInstance)
        )
        var snapshot = load()
        if cleaned.isEmpty {
            snapshot.sessionsByInstance.removeValue(forKey: instanceId)
        } else {
            snapshot.sessionsByInstance[instanceId] = cleaned
        }
        persist(snapshot)
    }

    private func persist(_ snapshot: AidenIntentCatalogSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 1_048_576 else { return }
        defaults?.set(data, forKey: Self.key)
    }

    private static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._:-".unicodeScalars.contains(scalar)
            }
    }

    private static func safeName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 256
    }
}

// MARK: - Entities

/// An App Group-cached navigation destination: "New Session" or a recent
/// session on any paired installation.
struct AidenDestinationEntity: AppEntity, Equatable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenCode Destination")
    static let defaultQuery = AidenDestinationQuery()

    enum Kind: String, Codable, Sendable { case newSession, session }

    let kind: Kind
    /// Installation id for sessions; nil for "New Session".
    let instanceId: String?
    let sessionID: String?
    let title: String

    var id: String { "\(kind.rawValue)|\(instanceId ?? "-")|\(sessionID ?? "-")" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    static func newSession() -> AidenDestinationEntity {
        AidenDestinationEntity(kind: .newSession, instanceId: nil, sessionID: nil, title: String(localized: "New Session"))
    }

    static func session(record: AidenIntentSessionRecord) -> AidenDestinationEntity {
        AidenDestinationEntity(
            kind: .session,
            instanceId: record.instanceId,
            sessionID: record.sessionId,
            title: record.title
        )
    }

    var deepLinkURL: URL? {
        switch kind {
        case .newSession:
            return AidenDeepLink.newSessionURL
        case .session:
            guard let sessionID else { return nil }
            return AidenDeepLink.sessionURL(instanceId: instanceId, sessionID: sessionID)
        }
    }
}

struct AidenDestinationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AidenDestinationEntity] {
        let wanted = Set(identifiers)
        return try await suggestedEntities().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AidenDestinationEntity] {
        let snapshot = AidenIntentCatalogStore.shared.load()
        return [.newSession()] + snapshot.sessionsByInstance.values.flatMap { $0.map(AidenDestinationEntity.session(record:)) }
    }
}

// MARK: - Intents

/// Simply opens the app.
struct AidenOpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Aiden"
    static let description = IntentDescription("Open Aiden for OpenCode.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Opens one deep-link destination (`aiden-opencode://new` or
/// `aiden-opencode://session/<id>?instance=<id>`) from the App Group cache.
struct AidenOpenDestinationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Destination"
    static let description = IntentDescription("Open a new OpenCode session or a recent one.")

    @Parameter(title: "Destination") var destination: AidenDestinationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$destination)")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let url = destination.deepLinkURL else { throw AidenIntentError.invalidDestination }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// Opens the app straight onto a new-session flow (`aiden-opencode://new`).
struct AidenNewSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    static let description = IntentDescription("Start a new OpenCode session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let url = AidenDeepLink.newSessionURL else { throw AidenIntentError.invalidDestination }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

enum AidenIntentError: Error { case invalidDestination }

struct AidenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AidenOpenAppIntent(),
            phrases: ["Open \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Open Aiden",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: AidenNewSessionIntent(),
            phrases: ["New session in \(.applicationName)", "New chat in \(.applicationName)"],
            shortTitle: "New Session",
            systemImageName: "square.and.pencil"
        )
    }
}
