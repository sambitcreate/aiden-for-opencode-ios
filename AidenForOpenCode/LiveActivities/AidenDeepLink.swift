import Foundation

/// Navigation payload extracted from an `aiden-opencode://` URL. `instanceId`
/// is the optional installation id (`OpenCodeInstallation.id`); when absent the
/// active installation is used.
struct AidenNavigationRequest: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case newSession
        case session(String)
    }

    let destination: Destination
    let instanceId: String?
}

/// The app's only URL routes: `aiden-opencode://new` and
/// `aiden-opencode://session/<id>` with an optional `?instance=<id>`.
enum AidenDeepLink {
    static var scheme: String {
        Bundle.main.object(forInfoDictionaryKey: "AidenURLScheme") as? String ?? "aiden-opencode"
    }

    static var newSessionURL: URL? {
        url(host: "new", path: nil, instanceId: nil)
    }

    static func sessionURL(instanceId: String?, sessionID: String) -> URL? {
        guard safeID(sessionID) else { return nil }
        return url(host: "session", path: "/" + sessionID, instanceId: instanceId)
    }

    /// Parses a deep link into a navigation request. Fails closed on foreign
    /// schemes, credentials in the URL, unknown hosts/queries, or malformed ids.
    static func request(from url: URL) -> AidenNavigationRequest? {
        guard url.scheme?.lowercased() == scheme.lowercased(),
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ $0.value != nil && $0.name == "instance" }) else { return nil }
        let instance = items.first?.value
        guard instance.map(safeID) ?? true else { return nil }

        switch host {
        case "new":
            guard url.path.isEmpty || url.path == "/" else { return nil }
            return AidenNavigationRequest(destination: .newSession, instanceId: instance)
        case "session":
            let sessionID = trimPathSeparator(url.path)
            guard safeID(sessionID) else { return nil }
            return AidenNavigationRequest(destination: .session(sessionID), instanceId: instance)
        default:
            return nil
        }
    }

    private static func url(host: String, path: String?, instanceId: String?) -> URL? {
        guard instanceId.map(safeID) ?? true else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path ?? "/"
        components.queryItems = instanceId.map { [URLQueryItem(name: "instance", value: $0)] }
        if components.queryItems?.isEmpty ?? true { components.queryItems = nil }
        return components.url
    }

    private static func trimPathSeparator(_ path: String) -> String {
        var value = path
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    private static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._:-".unicodeScalars.contains(scalar)
            }
    }
}
