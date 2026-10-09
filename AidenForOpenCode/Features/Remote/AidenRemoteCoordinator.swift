import Foundation
import Observation

enum AidenRemoteConnectionState: Equatable {
    case needsPairing
    case connecting
    case connected(server: VerifiedServer)
    case offline(message: String)
}

/// Why a pairing attempt failed; the pairing UI surfaces these as typed copy.
enum PairingFailure: Equatable, Error {
    case unreachable
    case unauthorized
    case notOpencode
    case storage
}

extension PairingFailure {
    var message: String {
        switch self {
        case .unreachable:
            return String(localized:
                "Couldn't reach the server. Check that it is running and that the address and port are correct."
            )
        case .unauthorized:
            return String(localized:
                "The server rejected the password. Run `opencode service password` and try again."
            )
        case .notOpencode:
            return String(localized:
                "That address answered, but it is not an OpenCode server."
            )
        case .storage:
            return String(localized:
                "The connection details couldn't be saved to the Keychain. Try again."
            )
        }
    }
}

/// Thrown by `client()` when there is no connected installation.
struct AidenRemoteNotConnectedError: Error {}

@MainActor
@Observable
final class AidenRemoteCoordinator {
    /// Builds the client for a candidate installation + password. Injectable
    /// so tests can stub the transport; implementations must never log the
    /// password argument.
    typealias ClientFactory = (OpenCodeInstallation, String) throws -> OpenCodeClient

    let installationStore: OpenCodeInstallationStore
    private let clientFactory: ClientFactory
    private(set) var connectionState: AidenRemoteConnectionState
    var presentedError: String?

    /// Monotonic epoch over the active installation. Every state-mutating flow
    /// captures it up front and drops results unless it still matches, so work
    /// started for a previous installation can never land — including an
    /// A→B→A revisit of the original installation.
    private var activationGeneration = 0
    private var cachedClient: (installationId: String, credential: String, client: OpenCodeClient)?

    var activeInstallationId: String? { installationStore.activeInstallationId }

    /// Stable identity used by caches/deep-links (= active installation id).
    var instanceId: String? { activeInstallationId }

    init(
        installationStore: OpenCodeInstallationStore? = nil,
        clientFactory: @escaping ClientFactory = { installation, password in
            try OpenCodeClient(config: OpenCodeServerConfig(
                baseURL: installation.endpoint,
                username: installation.username,
                password: password
            ))
        }
    ) {
        self.installationStore = installationStore ?? OpenCodeInstallationStore()
        self.clientFactory = clientFactory
        connectionState = self.installationStore.activeInstallationId == nil ? .needsPairing : .connecting
    }

    // MARK: - Lifecycle

    func start() async {
        await connectActiveInstallation()
    }

    func connectActiveInstallation() async {
        activationGeneration &+= 1
        let generation = activationGeneration
        guard let installation = installationStore.activeInstallation else {
            connectionState = .needsPairing
            presentedError = nil
            return
        }
        guard let credential = installationStore.credential(for: installation.id) else {
            // The snapshot survived but its scoped Keychain entry did not;
            // re-pairing recovers. Never auto-delete the installation here.
            connectionState = .offline(message: String(localized:
                "Saved password unavailable — pair again from Settings"
            ))
            return
        }
        connectionState = .connecting
        presentedError = nil
        do {
            let client = try makeClient(installation: installation, credential: credential)
            let config = try serverConfig(installation: installation, password: credential)
            let verified = try await PairingVerifier.verify(config: config, client: client)
            guard generation == activationGeneration else { return }
            installationStore.updateLastConnected(id: installation.id, date: Date())
            connectionState = .connected(server: verified)
        } catch {
            guard generation == activationGeneration else { return }
            handleConnectionError(error)
        }
    }

    /// Validate + persist a new installation. The verifier runs before any
    /// persistence; only a fully verified server is saved and activated.
    func pair(with config: OpenCodeServerConfig, name: String?) async -> Result<Void, PairingFailure> {
        let previousState = connectionState
        let displayName = name ?? config.baseURL.host ?? String(localized: "OpenCode Server")
        // Carrier for the client factory until the record exists; only the
        // endpoint/username are read from it.
        let candidate = OpenCodeInstallation(
            id: UUID().uuidString,
            name: displayName,
            endpoint: config.baseURL,
            username: config.username,
            createdAt: Date(),
            lastConnectedAt: nil
        )
        connectionState = .connecting
        presentedError = nil
        do {
            let client = try makeClient(installation: candidate, credential: config.password)
            let verified = try await PairingVerifier.verify(config: config, client: client, name: displayName)

            let saved: OpenCodeInstallation
            do {
                saved = try installationStore.save(
                    name: displayName,
                    endpoint: config.baseURL,
                    username: config.username,
                    password: config.password
                )
            } catch {
                throw PairingFailure.storage
            }
            activationGeneration &+= 1
            cachedClient = (installationId: saved.id, credential: config.password, client: client)
            connectionState = .connected(server: verified)
            return .success(())
        } catch let failure as PairingFailure {
            restoreStateAfterFailedPairing(previousState)
            return .failure(failure)
        } catch let error as PairingError {
            restoreStateAfterFailedPairing(previousState)
            return .failure(Self.pairingFailure(from: error))
        } catch {
            restoreStateAfterFailedPairing(previousState)
            return .failure(.unreachable)
        }
    }

    func switchInstallation(to id: String) async {
        guard installationStore.installations.contains(where: { $0.id == id }) else { return }
        installationStore.setActive(id: id)
        await connectActiveInstallation()
    }

    func removeInstallation(id: String) async {
        let wasActive = activeInstallationId == id
        activationGeneration &+= 1
        installationStore.remove(id: id)
        if cachedClient?.installationId == id {
            cachedClient = nil
        }
        await AidenRemoteLiveActivityManager.shared.endAll(instanceID: id)
        guard wasActive else { return }
        await connectActiveInstallation()
    }

    // MARK: - Consumption

    /// Client bound to the ACTIVE installation. Throws if not connected or if
    /// the credential cannot be read.
    func client() throws -> OpenCodeClient {
        guard case .connected = connectionState,
              let installation = installationStore.activeInstallation,
              let credential = installationStore.credential(for: installation.id) else {
            throw AidenRemoteNotConnectedError()
        }
        return try makeClient(installation: installation, credential: credential)
    }

    func requestContext() -> String? {
        activeInstallationId
    }

    /// True while `instanceId` remains the active installation. Async work
    /// keyed to a former installation must drop its results when false.
    func isCurrent(_ instanceId: String) -> Bool {
        !instanceId.isEmpty && activeInstallationId == instanceId
    }

    /// Maps a later-use failure onto the connection banner. A 401 marks the
    /// session expired but NEVER deletes the installation; reconnecting from
    /// Settings retries with the stored credential.
    func handleConnectionError(_ error: Error) {
        if isOpenCodeUnauthorized(error) {
            connectionState = .offline(message: Self.sessionExpiredMessage)
            presentedError = Self.sessionExpiredMessage
            return
        }
        let message = if let apiError = error as? OpenCodeAPIError {
            apiError.debugSummary
        } else {
            error.localizedDescription
        }
        connectionState = .offline(message: message)
        presentedError = message
    }

    // MARK: - Internals

    private static let sessionExpiredMessage = String(localized:
        "Session expired — reconnect from Settings"
    )

    private func restoreStateAfterFailedPairing(_ previousState: AidenRemoteConnectionState) {
        connectionState = installationStore.activeInstallationId == nil ? .needsPairing : previousState
    }

    private static func pairingFailure(from error: PairingError) -> PairingFailure {
        switch error {
        case .unreachable: return .unreachable
        case .unauthorized: return .unauthorized
        case .notOpencode, .malformedPayload: return .notOpencode
        }
    }

    private func makeClient(installation: OpenCodeInstallation, credential: String) throws -> OpenCodeClient {
        if let cachedClient,
           cachedClient.installationId == installation.id,
           cachedClient.credential == credential {
            return cachedClient.client
        }
        let client = try clientFactory(installation, credential)
        cachedClient = (installationId: installation.id, credential: credential, client: client)
        return client
    }

    private func serverConfig(installation: OpenCodeInstallation, password: String) throws -> OpenCodeServerConfig {
        try OpenCodeServerConfig(
            baseURL: installation.endpoint,
            username: installation.username,
            password: password
        )
    }

    private func isOpenCodeUnauthorized(_ error: Error) -> Bool {
        guard let apiError = error as? OpenCodeAPIError else { return false }
        if case .unauthorized = apiError { return true }
        return false
    }
}
