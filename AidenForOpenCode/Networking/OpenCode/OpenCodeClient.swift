import Foundation

/// Typed transport failures mapped from HTTP statuses and URLSession errors.
enum OpenCodeAPIError: Error {
    case unauthorized
    case notFound(String)
    case conflict(String)
    /// Any other non-2xx status; carries the response body message when present.
    case server(status: Int, message: String?)
    case network(underlying: any Error)
    case decoding(any Error)
    case invalidURL(String)

    var debugSummary: String {
        switch self {
        case .unauthorized:
            return "unauthorized"
        case .notFound(let what):
            return "not found: \(what)"
        case .conflict(let message):
            return "conflict: \(message)"
        case .server(let status, let message):
            return "server error \(status)\(message.map { ": \($0)" } ?? "")"
        case .network(let underlying):
            return "network error: \(underlying)"
        case .decoding(let underlying):
            return "decoding error: \(underlying)"
        case .invalidURL(let reason):
            return "invalid URL: \(reason)"
        }
    }
}

/// Carries a short body snippet with a JSON decode failure so logs can show
/// the mismatch without treating HTTP error payloads as success.
fileprivate struct OpenCodeDecodingFailure: Error, CustomStringConvertible {
    let underlying: any Error
    let snippet: String

    var description: String { "\(underlying) | body: \(snippet)" }
}

fileprivate struct DataEnvelope<Payload: Decodable>: Decodable {
    let data: Payload

    enum CodingKeys: String, CodingKey {
        case data
    }
}

fileprivate struct LocationEnvelope<Payload: Decodable>: Decodable {
    let location: LocationInfo
    let data: Payload

    enum CodingKeys: String, CodingKey {
        case location
        case data
    }
}

/// Async client for the OpenCode V2 HTTP API. One instance per paired server;
/// safe to share across view models.
///
/// Every request carries HTTP Basic credentials in headers only — credentials
/// never appear in URLs and are never logged.
actor OpenCodeClient {
    private let config: OpenCodeServerConfig
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Shared decoder for SSE envelopes; decoding is stateless per call.
    private static let eventDecoder = JSONDecoder()

    init(config: OpenCodeServerConfig, configuration: URLSessionConfiguration? = nil) {
        self.config = config
        let configuration = configuration ?? .default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Health & location

    /// GET /api/health — asserts the server reports healthy.
    func health() async throws {
        let (data, _) = try await send(request(method: "GET", url: try url("/api/health", query: [])))
        let decoded = try decode(HealthResponse.self, from: data)
        guard decoded.healthy else {
            throw OpenCodeAPIError.server(status: 503, message: "Server reported unhealthy")
        }
    }

    /// GET /api/location — protocol success is unwrapped `Location.Info`.
    func location(scope: LocationScope? = nil) async throws -> LocationInfo {
        let (data, _) = try await send(request(method: "GET", url: try url("/api/location", query: scope?.queryItems() ?? [])))
        return try decodeUnwrapped(LocationInfo.self, from: data)
    }

    // MARK: - Catalogs

    func agents(scope: LocationScope? = nil) async throws -> [AgentInfo] {
        try await catalog("/api/agent", scope: scope)
    }

    func models(scope: LocationScope? = nil) async throws -> [ModelInfo] {
        try await catalog("/api/model", scope: scope)
    }

    func providers(scope: LocationScope? = nil) async throws -> [ProviderInfo] {
        try await catalog("/api/provider", scope: scope)
    }

    func commands(scope: LocationScope? = nil) async throws -> [CommandInfo] {
        try await catalog("/api/command", scope: scope)
    }

    func skills(scope: LocationScope? = nil) async throws -> [SkillInfo] {
        try await catalog("/api/skill", scope: scope)
    }

    // MARK: - Sessions

    /// GET /api/session — `{data, cursor}`; a bare array is tolerated.
    func sessions(query: SessionsQuery = SessionsQuery()) async throws -> SessionPage {
        let (data, _) = try await send(request(method: "GET", url: try url("/api/session", query: query.queryItems())))
        return try decodeSessionPage(from: data)
    }

    /// GET /api/session/active — IDs of sessions whose drain is currently
    /// running on this server process. Values decode as opaque JSON trees so
    /// future state kinds cannot break the poll.
    func activeSessions() async throws -> Set<String> {
        let (data, _) = try await send(request(method: "GET", url: try url("/api/session/active", query: [])))
        let map: [String: OCJSON] = try decodeUnwrapped([String: OCJSON].self, from: data)
        return Set(map.keys)
    }

    /// Walks GET /api/session across cursor pages. Server cursors omit the
    /// page size, so `limit` is resent on every request. Stops when the
    /// server omits `cursor.next` or after `maxPages` pages; rows are
    /// deduplicated by ID defensively while preserving page order.
    func allSessions(
        query: SessionsQuery,
        limit: Int = 100,
        maxPages: Int = 10
    ) async throws -> [SessionInfo] {
        var page = query
        page.limit = limit
        var byID = [String: SessionInfo]()
        var order = [String]()
        for _ in 0..<max(maxPages, 0) {
            let response = try await sessions(query: page)
            for info in response.data where byID[info.id] == nil {
                byID[info.id] = info
                order.append(info.id)
            }
            guard let next = response.cursor.next else { break }
            page.cursor = next
        }
        return order.compactMap { byID[$0] }
    }

    /// POST /api/session. The wire model reference is always the
    /// `{id, providerID, variant?}` object — build it with
    /// `ModelRef(providerID:modelID:)`; a bare `"provider/model"` string is not
    /// accepted by the server schema.
    func createSession(
        agent: String? = nil,
        model: ModelRef? = nil,
        directory: String? = nil
    ) async throws -> SessionInfo {
        struct CreateBody: Encodable {
            let agent: String?
            let model: ModelRef?
            let location: LocationBody?

            struct LocationBody: Encodable {
                let directory: String

                enum CodingKeys: String, CodingKey {
                    case directory
                }
            }

            enum CodingKeys: String, CodingKey {
                case agent
                case model
                case location
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(agent, forKey: .agent)
                try container.encodeIfPresent(model, forKey: .model)
                try container.encodeIfPresent(location, forKey: .location)
            }
        }
        let body = CreateBody(
            agent: agent,
            model: model,
            location: directory.flatMap { value in
                value.isEmpty ? nil : CreateBody.LocationBody(directory: value)
            }
        )
        let data = try await postData("/api/session", body: body)
        return try decodeSessionInfo(from: data)
    }

    /// GET /api/session/:id — `{data: Session.Info}`; unwrapped info is tolerated.
    func session(id sessionID: String) async throws -> SessionInfo {
        let (data, _) = try await send(
            request(method: "GET", url: try url("/api/session/\(pathComponent(sessionID))", query: []))
        )
        return try decodeSessionInfo(from: data)
    }

    /// GET /api/session/:id/message (cursor-paginated timeline).
    func messages(
        sessionID: String,
        limit: Int? = nil,
        order: OpenCodeOrder? = nil,
        cursor: String? = nil
    ) async throws -> MessagePage {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let order { query.append(URLQueryItem(name: "order", value: order.rawValue)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (data, _) = try await send(
            request(method: "GET", url: try url("/api/session/\(pathComponent(sessionID))/message", query: query))
        )
        return try decodeMessagePage(from: data)
    }

    /// GET /api/session/:id/context — `{data: [...]}`; a bare array is tolerated.
    func context(sessionID: String) async throws -> [OCMessage] {
        let (data, _) = try await send(
            request(method: "GET", url: try url("/api/session/\(pathComponent(sessionID))/context", query: []))
        )
        return try decodeFlexibleArray(OCMessage.self, from: data)
    }

    /// GET /api/session/:id/history — finite page of durable events after an
    /// exclusive sequence number.
    func history(sessionID: String, after: Int? = nil, limit: Int? = nil) async throws -> HistoryPage {
        var query: [URLQueryItem] = []
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get("/api/session/\(pathComponent(sessionID))/history", query: query)
    }

    /// POST /api/session/:id/prompt — `{id?, prompt: {text, files?, agents?},
    /// delivery?, resume?}`. Delivery defaults to `.steer`.
    func prompt(
        sessionID: String,
        text: String,
        id: String? = nil,
        delivery: PromptDelivery = .steer,
        files: [PromptInputFileAttachment]? = nil,
        agents: [AgentAttachment]? = nil,
        resume: Bool? = nil
    ) async throws -> AdmittedInput {
        struct PromptBody: Encodable {
            let id: String?
            let prompt: PromptInput
            let delivery: PromptDelivery?
            let resume: Bool?

            enum CodingKeys: String, CodingKey {
                case id
                case prompt
                case delivery
                case resume
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(id, forKey: .id)
                try container.encode(prompt, forKey: .prompt)
                try container.encodeIfPresent(delivery, forKey: .delivery)
                try container.encodeIfPresent(resume, forKey: .resume)
            }
        }
        let body = PromptBody(
            id: id,
            prompt: PromptInput(text: text, files: files, agents: agents),
            delivery: delivery,
            resume: resume
        )
        let data = try await postData("/api/session/\(pathComponent(sessionID))/prompt", body: body)
        return try decodeAdmitted(from: data)
    }

    /// POST /api/session/:id/interrupt — no-op when idle.
    func interrupt(sessionID: String) async throws {
        try await postEmpty("/api/session/\(pathComponent(sessionID))/interrupt")
    }

    /// POST /api/session/:id/compact.
    func compact(sessionID: String) async throws {
        try await postEmpty("/api/session/\(pathComponent(sessionID))/compact")
    }

    /// POST /api/session/:id/wait — blocks until the agent loop is idle.
    func wait(sessionID: String) async throws {
        try await postEmpty("/api/session/\(pathComponent(sessionID))/wait", timeout: 600)
    }

    /// POST /api/session/:id/agent.
    func switchAgent(sessionID: String, agent: String) async throws {
        struct SwitchBody: Encodable {
            let agent: String

            enum CodingKeys: String, CodingKey {
                case agent
            }
        }
        try await postEmpty("/api/session/\(pathComponent(sessionID))/agent", body: SwitchBody(agent: agent))
    }

    /// POST /api/session/:id/model.
    func switchModel(sessionID: String, modelRef: ModelRef) async throws {
        struct SwitchBody: Encodable {
            let model: ModelRef

            enum CodingKeys: String, CodingKey {
                case model
            }
        }
        try await postEmpty("/api/session/\(pathComponent(sessionID))/model", body: SwitchBody(model: modelRef))
    }

    // MARK: - Permissions

    /// GET /api/permission/request.
    func permissionRequests(scope: LocationScope? = nil) async throws -> [PermissionRequest] {
        try await locationList("/api/permission/request", scope: scope)
    }

    /// GET /api/session/:id/permission.
    func sessionPermissions(sessionID: String) async throws -> [PermissionRequest] {
        let (data, _) = try await send(
            request(method: "GET", url: try url("/api/session/\(pathComponent(sessionID))/permission", query: []))
        )
        return try decodeFlexibleArray(PermissionRequest.self, from: data)
    }

    /// POST /api/session/:id/permission/:requestID/reply.
    func replyPermission(
        sessionID: String,
        requestID: String,
        reply: PermissionReply,
        message: String? = nil
    ) async throws {
        struct ReplyBody: Encodable {
            let reply: PermissionReply
            let message: String?

            enum CodingKeys: String, CodingKey {
                case reply
                case message
            }
        }
        try await postEmpty(
            "/api/session/\(pathComponent(sessionID))/permission/\(pathComponent(requestID))/reply",
            body: ReplyBody(reply: reply, message: message)
        )
    }

    // MARK: - Questions

    /// GET /api/question/request.
    func questionRequests(scope: LocationScope? = nil) async throws -> [QuestionRequest] {
        try await locationList("/api/question/request", scope: scope)
    }

    /// POST /api/session/:id/question/:requestID/reply — answers aligned with
    /// the questions; each answer is an array of selected labels.
    func replyQuestion(sessionID: String, requestID: String, answers: [[String]]) async throws {
        try await postEmpty(
            "/api/session/\(pathComponent(sessionID))/question/\(pathComponent(requestID))/reply",
            body: QuestionReplyBody(answers: answers)
        )
    }

    /// POST /api/session/:id/question/:requestID/reject.
    func rejectQuestion(sessionID: String, requestID: String) async throws {
        try await postEmpty("/api/session/\(pathComponent(sessionID))/question/\(pathComponent(requestID))/reject")
    }

    // MARK: - Filesystem

    /// GET /api/fs/list — direct children of one directory relative to the
    /// requested location.
    func listDirectory(path: String?, scope: LocationScope?) async throws -> DirectoryListing {
        var query: [URLQueryItem] = []
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        query.append(contentsOf: scope?.queryItems() ?? [])
        let (data, _) = try await send(request(method: "GET", url: try url("/api/fs/list", query: query)))
        if let envelope = try? decoder.decode(LocationEnvelope<[FSEntry]>.self, from: data) {
            return DirectoryListing(location: envelope.location, entries: envelope.data)
        }
        let entries = try decodeFlexibleArray(FSEntry.self, from: data)
        if let location = try? decoder.decode(LocationEnvelope<OCJSON>.self, from: data).location {
            return DirectoryListing(location: location, entries: entries)
        }
        throw OpenCodeAPIError.decoding(
            OpenCodeDecodingFailure(underlying: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "fs.list missing location envelope")), snippet: Self.bodySnippet(data))
        )
    }

    /// GET /api/fs/find — ranked entries relative to the requested location;
    /// result order is the server's rank. The success shape is the
    /// `{location, data}` envelope; a bare array is tolerated as a fallback.
    func findEntries(query: String, type: FSKind?, limit: Int?, scope: LocationScope?) async throws -> [FSEntry] {
        var items: [URLQueryItem] = [URLQueryItem(name: "query", value: query)]
        if let type { items.append(URLQueryItem(name: "type", value: type.rawValue)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        items.append(contentsOf: scope?.queryItems() ?? [])
        let (data, _) = try await send(request(method: "GET", url: try url("/api/fs/find", query: items)))
        return try decodeFlexibleArray(FSEntry.self, from: data)
    }

    /// GET /api/fs/read/* — one file's bytes relative to the requested
    /// location. The path rides the wildcard after `/api/fs/read/`, split
    /// into individually percent-encoded segments so `/` separators survive
    /// and pre-encoded input never collapses into a single component. The
    /// MIME type comes from the response `Content-Type`.
    func readFile(path: String, scope: LocationScope?) async throws -> (data: Data, mime: String?) {
        let wildcard = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let (data, response) = try await send(
            request(method: "GET", url: try url("/api/fs/read/\(wildcard)", query: scope?.queryItems() ?? [], preEncodedPath: true))
        )
        return (data, Self.mimeType(fromContentHeader: response.value(forHTTPHeaderField: "Content-Type")))
    }

    /// Media type portion of a `Content-Type` header (`nil` when absent).
    private static func mimeType(fromContentHeader value: String?) -> String? {
        guard let value else { return nil }
        let base = value.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return base.isEmpty ? nil : base
    }

    // MARK: - Event streams

    /// Global SSE stream (`GET /api/event`). Carries live-only deltas such as
    /// `session.next.text.delta`; heartbeats are filtered by the parser.
    func globalEvents() async throws -> AsyncThrowingStream<OpenCodeEvent, Error> {
        eventStream(url: try url("/api/event", query: []))
    }

    /// Per-session durable SSE stream; replays events after `after`, then follows live.
    func sessionEvents(sessionID: String, after: Int? = nil) async throws -> AsyncThrowingStream<OpenCodeEvent, Error> {
        var query: [URLQueryItem] = []
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        return eventStream(url: try url("/api/session/\(pathComponent(sessionID))/event", query: query))
    }

    // MARK: - Request plumbing

    private func url(_ path: String, query: [URLQueryItem], preEncodedPath: Bool = false) throws -> URL {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenCodeAPIError.invalidURL(config.baseURL.absoluteString)
        }
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        if preEncodedPath {
            // The caller already percent-encoded the path (e.g. fs.read wildcards);
            // setting `.path` here would re-escape "%" and double-encode.
            components.percentEncodedPath = basePath + path
        } else {
            components.path = basePath + path
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let final = components.url else {
            throw OpenCodeAPIError.invalidURL(path)
        }
        return final
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func request(
        method: String,
        url: URL,
        body: Data? = nil,
        contentType: String? = "application/json",
        accept: String = "application/json",
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let header = config.basicAuthHeader()
        urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil, let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        urlRequest.httpBody = body
        if let timeout {
            urlRequest.timeoutInterval = timeout
        }
        return urlRequest
    }

    private func send(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw OpenCodeAPIError.network(underlying: URLError(.badServerResponse))
            }
            if !(200..<300).contains(http.statusCode) {
                throw Self.failure(status: http.statusCode, context: http.url?.path ?? "", data: data)
            }
            return (data, http)
        } catch let error as OpenCodeAPIError {
            throw error
        } catch {
            throw OpenCodeAPIError.network(underlying: error)
        }
    }

    private func decode<Output: Decodable>(_ type: Output.Type, from data: Data) throws -> Output {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw OpenCodeAPIError.decoding(
                OpenCodeDecodingFailure(underlying: error, snippet: Self.bodySnippet(data))
            )
        }
    }

    private func decodeUnwrapped<Output: Decodable>(_ type: Output.Type, from data: Data) throws -> Output {
        if let envelope = try? decoder.decode(DataEnvelope<Output>.self, from: data) {
            return envelope.data
        }
        return try decode(Output.self, from: data)
    }

    private func decodeFlexibleArray<Item: Decodable>(_ type: Item.Type, from data: Data) throws -> [Item] {
        if let envelope = try? decoder.decode(LocationEnvelope<[Item]>.self, from: data) {
            return envelope.data
        }
        if let envelope = try? decoder.decode(DataEnvelope<[Item]>.self, from: data) {
            return envelope.data
        }
        return try decode([Item].self, from: data)
    }

    private func decodeSessionPage(from data: Data) throws -> SessionPage {
        let prepared = Self.fillingMissingSessionTitles(data)
        if let page = try? decoder.decode(SessionPage.self, from: prepared) {
            return page
        }
        if let envelope = try? decoder.decode(DataEnvelope<[SessionInfo]>.self, from: prepared) {
            return SessionPage(data: envelope.data, cursor: PageCursor(previous: nil, next: nil))
        }
        if let rows = try? decoder.decode([SessionInfo].self, from: prepared) {
            return SessionPage(data: rows, cursor: PageCursor(previous: nil, next: nil))
        }
        return try decode(SessionPage.self, from: prepared)
    }

    private func decodeMessagePage(from data: Data) throws -> MessagePage {
        if let page = try? decoder.decode(MessagePage.self, from: data) {
            return page
        }
        if let envelope = try? decoder.decode(DataEnvelope<[OCMessage]>.self, from: data) {
            return MessagePage(data: envelope.data, cursor: PageCursor(previous: nil, next: nil))
        }
        if let rows = try? decoder.decode([OCMessage].self, from: data) {
            return MessagePage(data: rows, cursor: PageCursor(previous: nil, next: nil))
        }
        return try decode(MessagePage.self, from: data)
    }

    private func decodeSessionInfo(from data: Data) throws -> SessionInfo {
        try decodeUnwrapped(SessionInfo.self, from: Self.fillingMissingSessionTitles(data))
    }

    private func decodeAdmitted(from data: Data) throws -> AdmittedInput {
        if let envelope = try? decoder.decode(DataEnvelope<AdmittedInput>.self, from: data) {
            return envelope.data
        }
        if let admitted = try? decoder.decode(AdmittedInput.self, from: data) {
            return admitted
        }
        if let envelope = try? decoder.decode(DataEnvelope<InboxUserAdmission>.self, from: data) {
            return envelope.data.asAdmitted
        }
        if let inbox = try? decoder.decode(InboxUserAdmission.self, from: data) {
            return inbox.asAdmitted
        }
        return try decode(AdmittedInput.self, from: data)
    }

    private struct InboxUserAdmission: Decodable {
        let id: String
        let sessionID: String
        let timeCreated: Double
        let payload: PromptPayload
        let delivery: PromptDelivery

        enum CodingKeys: String, CodingKey {
            case id
            case sessionID
            case timeCreated
            case payload
            case delivery
        }

        var asAdmitted: AdmittedInput {
            AdmittedInput(
                admittedSeq: 0,
                id: id,
                sessionID: sessionID,
                prompt: payload,
                delivery: delivery,
                timeCreated: timeCreated,
                promotedSeq: nil
            )
        }
    }

    private static func fillingMissingSessionTitles(_ data: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return data }
        return (try? JSONSerialization.data(withJSONObject: fillSessionTitles(root))) ?? data
    }

    private static func fillSessionTitles(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(fillSessionTitles)
        }
        guard var object = value as? [String: Any] else { return value }
        for key in object.keys {
            if let nested = object[key] {
                object[key] = fillSessionTitles(nested)
            }
        }
        if let id = object["id"] as? String, id.hasPrefix("ses_"), object["projectID"] != nil, object["title"] == nil {
            object["title"] = ""
        }
        return object
    }

    private func postData<Input: Encodable>(_ path: String, body: Input) async throws -> Data {
        let payload = try encodeJSON(body)
        let (data, _) = try await send(request(method: "POST", url: try url(path, query: []), body: payload))
        return data
    }

    private func encodeJSON<Input: Encodable>(_ body: Input) throws -> Data {
        let encoded = try encoder.encode(body)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return encoded
        }
        return try JSONSerialization.data(withJSONObject: Self.omittingNulls(object))
    }

    private static func omittingNulls(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var next: [String: Any] = [:]
            for (key, nested) in object {
                if nested is NSNull { continue }
                next[key] = omittingNulls(nested)
            }
            return next
        }
        if let array = value as? [Any] {
            return array.compactMap { item -> Any? in
                if item is NSNull { return nil }
                return omittingNulls(item)
            }
        }
        return value
    }

    private func get<Output: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Output {
        let (data, _) = try await send(request(method: "GET", url: try url(path, query: query)))
        return try decode(Output.self, from: data)
    }

    private func catalog<Item: Decodable>(_ path: String, scope: LocationScope?) async throws -> [Item] {
        let (data, _) = try await send(request(method: "GET", url: try url(path, query: scope?.queryItems() ?? [])))
        return try decodeFlexibleArray(Item.self, from: data)
    }

    private func locationList<Item: Decodable>(_ path: String, scope: LocationScope?) async throws -> [Item] {
        try await catalog(path, scope: scope)
    }

    private func postEmpty(_ path: String, timeout: TimeInterval? = nil) async throws {
        _ = try await send(request(method: "POST", url: try url(path, query: []), body: nil, timeout: timeout))
    }

    private func postEmpty<Input: Encodable>(_ path: String, body: Input, timeout: TimeInterval? = nil) async throws {
        let payload = try encodeJSON(body)
        _ = try await send(request(method: "POST", url: try url(path, query: []), body: payload, timeout: timeout))
    }

    // MARK: - Error mapping

    private static func failure(status: Int, context: String, data: Data?) -> OpenCodeAPIError {
        let message = errorMessage(from: data)
        switch status {
        case 401:
            return .unauthorized
        case 404:
            return .notFound(message ?? context)
        case 409:
            return .conflict(message ?? "Conflict")
        default:
            return .server(status: status, message: message)
        }
    }

    private static func errorMessage(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let nested = object["error"] as? [String: Any],
               let message = nested["message"] as? String, !message.isEmpty {
                return message
            }
            if let tag = object["_tag"] as? String, !tag.isEmpty {
                return tag
            }
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(300))
    }

    private static func bodySnippet(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(data.count) bytes"
        return String(text.prefix(240))
    }

    // MARK: - SSE plumbing

    private func eventStream(url streamURL: URL) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        let urlSession = session
        let sseRequest = request(method: "GET", url: streamURL, accept: "text/event-stream")
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let (bytes, response) = try await urlSession.bytes(for: sseRequest)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Drain a bounded slice of the error body for diagnostics.
                        var body = Data()
                        body.reserveCapacity(16_384)
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 16_384 { break }
                        }
                        throw Self.failure(status: http.statusCode, context: http.url?.path ?? "", data: body)
                    }
                    var parser = AidenSSEParser()
                    for try await rawLine in bytes.lines {
                        if Task.isCancelled { break }
                        guard let payload = try parser.consume(line: rawLine) else { continue }
                        continuation.yield(try Self.decodeEnvelope(payload))
                    }
                    if !Task.isCancelled, let payload = try parser.finish() {
                        continuation.yield(try Self.decodeEnvelope(payload))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if let apiError = error as? OpenCodeAPIError {
                        continuation.finish(throwing: apiError)
                    } else {
                        continuation.finish(throwing: OpenCodeAPIError.network(underlying: error))
                    }
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    private static func decodeEnvelope(_ payload: String) throws -> OpenCodeEvent {
        do {
            return try eventDecoder.decode(OpenCodeEvent.self, from: Data(payload.utf8))
        } catch {
            throw OpenCodeAPIError.decoding(error)
        }
    }

    private struct HealthResponse: Decodable {
        let healthy: Bool

        enum CodingKeys: String, CodingKey {
            case healthy
        }
    }
}
