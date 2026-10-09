import Foundation

/// Pairing flow failures, distinguishing why a candidate server could not be
/// adopted.
enum PairingError: Error, Equatable {
    /// Payload was undecodable, carried the wrong `kind`, or held an invalid endpoint.
    case malformedPayload(String)
    /// The endpoint did not answer or answered with an unexpected transport failure.
    case unreachable
    /// Credentials are required or wrong.
    case unauthorized
    /// Something responded, but it is not an OpenCode V2 server.
    case notOpencode
}

/// QR / paste pairing payload: `{kind:"aiden-opencode-pairing-v1", endpoint,
/// username?, password?, name?}`. Persist only after `PairingVerifier.verify`
/// succeeds; never log the password.
struct OpenCodePairingPayload: Codable, Equatable, Sendable {
    static let kind = "aiden-opencode-pairing-v1"

    let kind: String
    let endpoint: String
    let username: String?
    let password: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case endpoint
        case username
        case password
        case name
    }

    init(endpoint: String, username: String? = nil, password: String? = nil, name: String? = nil) throws {
        guard let url = URL(string: endpoint), OpenCodeServerConfig.isValidBaseURL(url) else {
            throw PairingError.malformedPayload("Endpoint must be absolute http(s) with no query or fragment")
        }
        self.kind = Self.kind
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = try container.decode(String.self, forKey: .kind)
        guard decodedKind == Self.kind else {
            throw PairingError.malformedPayload("Unsupported pairing payload kind '\(decodedKind)'")
        }
        let endpoint = try container.decode(String.self, forKey: .endpoint)
        guard let url = URL(string: endpoint), OpenCodeServerConfig.isValidBaseURL(url) else {
            throw PairingError.malformedPayload("Invalid pairing endpoint")
        }
        self.endpoint = endpoint
        self.kind = decodedKind
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(name, forKey: .name)
    }

    /// Builds the server config this payload describes (username defaults to
    /// `opencode`, empty password = open server).
    func serverConfig() throws -> OpenCodeServerConfig {
        guard let url = URL(string: endpoint) else {
            throw PairingError.malformedPayload("Invalid pairing endpoint")
        }
        return try OpenCodeServerConfig(
            baseURL: url,
            username: username ?? OpenCodeServerConfig.defaultUsername,
            password: password ?? ""
        )
    }

    static func decode(_ data: Data) throws -> OpenCodePairingPayload {
        do {
            return try JSONDecoder().decode(OpenCodePairingPayload.self, from: data)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.malformedPayload("Unreadable pairing payload")
        }
    }

    func encodedData() throws -> Data {
        do {
            return try JSONEncoder().encode(self)
        } catch {
            throw PairingError.malformedPayload("Pairing payload could not be encoded")
        }
    }
}

/// Result of a successful pairing verification.
struct VerifiedServer: Equatable, Sendable {
    let name: String?
    let directory: String
    let workspace: String?
}

enum PairingVerifier {
    /// Validates a candidate server: credentialed `GET /api/health`, then
    /// credentialed `GET /api/location`. Only persist after both succeed.
    ///
    /// V2 applies authorization middleware to every group, including health.
    static func verify(
        config: OpenCodeServerConfig,
        client: OpenCodeClient,
        name: String? = nil
    ) async throws -> VerifiedServer {
        do {
            try await client.health()
        } catch let error as OpenCodeAPIError {
            throw Self.pairingError(from: error)
        }

        do {
            let resolved = try await client.location(scope: nil)
            return VerifiedServer(
                name: name ?? config.baseURL.host,
                directory: resolved.directory,
                workspace: resolved.workspaceID
            )
        } catch let error as OpenCodeAPIError {
            throw Self.pairingError(from: error)
        }
    }

    private static func pairingError(from error: OpenCodeAPIError) -> PairingError {
        switch error {
        case .unauthorized:
            return .unauthorized
        case .network:
            return .unreachable
        case .notFound, .conflict, .server, .decoding, .invalidURL:
            return .notOpencode
        }
    }
}
