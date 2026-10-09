import Foundation

/// Connection credentials for an OpenCode V2 server.
///
/// Auth is HTTP Basic with username `opencode` and the server password; an
/// empty password means the server is open (auth disabled server-side). The
/// password must never appear in URLs, logs, or persisted caches — the
/// `auth_token` query form exists only for transports that cannot set headers
/// (the PTY WebSocket upgrade) and is unused by the REST client.
struct OpenCodeServerConfig: Codable, Equatable, Sendable {
    static let defaultUsername = "opencode"

    /// Absolute http/https origin (an optional reverse-proxy path prefix is
    /// allowed); never contains a query or fragment.
    let baseURL: URL
    let username: String
    /// Empty string = open server.
    let password: String

    init(baseURL: URL, username: String = OpenCodeServerConfig.defaultUsername, password: String = "") throws {
        guard Self.isValidBaseURL(baseURL) else {
            throw OpenCodeAPIError.invalidURL("Base URL must be absolute http(s) with no query or fragment")
        }
        self.baseURL = Self.normalized(baseURL)
        self.username = username
        self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case baseURL
        case username
        case password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .baseURL)
        guard let parsed = URL(string: raw), Self.isValidBaseURL(parsed) else {
            throw DecodingError.dataCorruptedError(
                forKey: .baseURL,
                in: container,
                debugDescription: "Invalid OpenCode server base URL"
            )
        }
        baseURL = Self.normalized(parsed)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? Self.defaultUsername
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
    }

    /// Accepts absolute http/https URLs with a host and no query or fragment.
    static func isValidBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard url.host?.isEmpty == false else { return false }
        return url.query == nil && url.fragment == nil
    }

    private static func normalized(_ url: URL) -> URL {
        var absolute = url.absoluteString
        while absolute.count > 1, absolute.hasSuffix("/") {
            absolute.removeLast()
        }
        return URL(string: absolute) ?? url
    }

    /// `(key, value)` for the HTTP Basic authorization header. Safe to send
    /// unconditionally: open servers ignore it.
    func basicAuthHeader() -> (key: String, value: String) {
        let credential = Data("\(username):\(password)".utf8).base64EncodedString()
        return ("Authorization", "Basic \(credential)")
    }
}
