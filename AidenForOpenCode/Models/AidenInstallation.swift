import Foundation
import Observation

/// A paired OpenCode V2 server. `id` is a stable UUID generated at pair time;
/// it keys caches, deep links, and the installation-scoped Keychain credential.
struct OpenCodeInstallation: Codable, Equatable, Identifiable, Sendable {
    var id: String // stable UUID generated at pair time (deep-link/caching key)
    var name: String // user-visible label, defaults to host
    var endpoint: URL // server base URL
    var username: String // "opencode"
    var createdAt: Date
    var lastConnectedAt: Date?
}

enum OpenCodeInstallationStoreError: Error, Equatable {
    /// Endpoint failed base-URL validation (absolute http(s), no query or fragment).
    case invalidEndpoint
}

@MainActor
@Observable
final class OpenCodeInstallationStore {
    private struct Snapshot: Codable {
        var installations: [OpenCodeInstallation]
        var activeInstallationId: String?
    }

    private let keychain: any KeychainStoring
    private(set) var installations: [OpenCodeInstallation]
    private(set) var activeInstallationId: String?

    var activeInstallation: OpenCodeInstallation? {
        guard let activeInstallationId else { return nil }
        return installations.first { $0.id == activeInstallationId }
    }

    init(keychain: any KeychainStoring = KeychainStore()) {
        self.keychain = keychain
        let snapshot = Self.loadSnapshot(from: keychain)
        installations = snapshot.installations
        activeInstallationId = snapshot.activeInstallationId.flatMap { candidate in
            snapshot.installations.contains(where: { $0.id == candidate }) ? candidate : nil
        }
    }

    /// Password for the installation, or nil when absent/unreadable. An empty
    /// string means an open server. Never log the returned value.
    func credential(for id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return try? keychain.load(.credential, scope: id)
    }

    /// Persists the password under the installation-scoped Keychain entry,
    /// registers the installation, and makes it active. Pairing the same
    /// endpoint + username again reconciles into the existing record instead
    /// of duplicating it. Throws only for an invalid endpoint or a Keychain
    /// failure; callers surface both as pairing/storage problems.
    func save(
        name: String,
        endpoint: URL,
        username: String,
        password: String
    ) throws -> OpenCodeInstallation {
        guard OpenCodeServerConfig.isValidBaseURL(endpoint) else {
            throw OpenCodeInstallationStoreError.invalidEndpoint
        }
        let normalizedUsername = username.isEmpty ? OpenCodeServerConfig.defaultUsername : username
        let normalizedEndpoint = Self.normalizeEndpoint(endpoint)
        let existing = installations.first {
            Self.normalizeEndpoint($0.endpoint) == normalizedEndpoint && $0.username == normalizedUsername
        }
        let displayName = name.isEmpty ? endpoint.host ?? String(localized: "OpenCode Server") : name

        let installation: OpenCodeInstallation
        if var reconciled = existing {
            reconciled.name = displayName
            reconciled.endpoint = endpoint
            reconciled.username = normalizedUsername
            installation = reconciled
        } else {
            installation = OpenCodeInstallation(
                id: UUID().uuidString,
                name: displayName,
                endpoint: endpoint,
                username: normalizedUsername,
                createdAt: Date(),
                lastConnectedAt: nil
            )
        }

        let previousInstallations = installations
        let previousActiveId = activeInstallationId

        // The scoped credential write must succeed before the installation is
        // advertised as usable in the registry. A reconciled record reuses its
        // id, so this overwrites the same scoped entry.
        try keychain.save(password, forKey: .credential, scope: installation.id)

        var updated = previousInstallations.filter { $0.id != installation.id }
        updated.append(installation)
        updated.sort(by: Self.sortOrder)

        installations = updated
        activeInstallationId = installation.id
        do {
            try persist()
        } catch {
            installations = previousInstallations
            activeInstallationId = previousActiveId
            // Only a brand-new record's credential is unrecoverable; a
            // reconciled one must keep whatever entry it had before this call.
            if existing == nil {
                try? keychain.delete(.credential, scope: installation.id)
            }
            throw error
        }
        return installation
    }

    func updateLastConnected(id: String, date: Date = Date()) {
        guard let index = installations.firstIndex(where: { $0.id == id }) else { return }
        installations[index].lastConnectedAt = date
        // A timestamp lost to a persistence failure is not worth rolling back;
        // the next successful persist flushes it.
        try? persist()
    }

    func setActive(id: String) {
        guard installations.contains(where: { $0.id == id }) else { return }
        guard activeInstallationId != id else { return }
        let previous = activeInstallationId
        activeInstallationId = id
        do {
            try persist()
        } catch {
            activeInstallationId = previous
        }
    }

    func remove(id: String) {
        guard installations.contains(where: { $0.id == id }) else { return }
        let previousInstallations = installations
        let previousActiveId = activeInstallationId
        installations.removeAll { $0.id == id }
        if activeInstallationId == id {
            activeInstallationId = installations.first?.id
        }
        do {
            try persist()
        } catch {
            installations = previousInstallations
            activeInstallationId = previousActiveId
            // Keep the credential so a retry can complete the removal.
            return
        }
        try? keychain.delete(.credential, scope: id)
    }

    private func persist() throws {
        let snapshot = Snapshot(
            installations: installations,
            activeInstallationId: activeInstallationId
        )
        let data = try JSONEncoder().encode(snapshot)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try keychain.save(value, forKey: .installations)
    }

    private static func loadSnapshot(from keychain: any KeychainStoring) -> Snapshot {
        // Retired Aiden-remote-v1 snapshots live under different keys or fail
        // to decode against this shape; both paths simply start empty.
        guard let value = try? keychain.load(.installations),
              let data = value.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(installations: [], activeInstallationId: nil)
        }

        var seen = Set<String>()
        let installations = snapshot.installations.filter { installation in
            !installation.id.isEmpty && seen.insert(installation.id).inserted
        }
        return Snapshot(
            installations: installations,
            activeInstallationId: snapshot.activeInstallationId
        )
    }

    private static func normalizeEndpoint(_ url: URL) -> String {
        var absolute = url.absoluteString
        while absolute.count > 1, absolute.hasSuffix("/") {
            absolute.removeLast()
        }
        return absolute
    }

    private static func sortOrder(
        _ lhs: OpenCodeInstallation,
        _ rhs: OpenCodeInstallation
    ) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order == .orderedSame {
            return lhs.id < rhs.id
        }
        return order == .orderedAscending
    }
}
