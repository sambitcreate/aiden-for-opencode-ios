import Foundation

// MARK: - Generic JSON value tree

/// Generic JSON tree used for opaque values (`Schema.Unknown`,
/// `Record<string, unknown>`) and for keeping raw event payloads alongside
/// their typed decodings.
enum OCJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([OCJSON])
    case object([String: OCJSON])
}

extension OCJSON: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([OCJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: OCJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension OCJSON {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [OCJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: OCJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Captures any Encodable value as a generic JSON tree (best effort).
    init<T: Encodable>(capturing value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let tree = try? JSONDecoder().decode(OCJSON.self, from: data) else {
            self = .null
            return
        }
        self = tree
    }
}

// MARK: - Shared enums

/// `SessionInput.Delivery` — how an admitted prompt joins the session.
enum PromptDelivery: String, Codable, Sendable, Equatable {
    /// Steer the active drain at the next safe provider-turn boundary.
    case steer
    /// Stay pending until the session would otherwise become idle.
    case queue
}

/// `Permission.Reply`.
enum PermissionReply: String, Codable, Sendable, Equatable {
    case once
    case always
    case reject
}

/// `Permission.Effect`.
enum PermissionEffect: String, Codable, Sendable, Equatable {
    case allow
    case deny
    case ask
}

/// `Session.Compaction.reason`. Unknown values fail-open so a newer reason
/// cannot take down a timeline or SSE payload.
enum CompactionReason: Equatable, Sendable {
    case auto
    case manual
    case unrecognized(String)
}

extension CompactionReason: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "auto": self = .auto
        case "manual": self = .manual
        default: self = .unrecognized(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case .manual: try container.encode("manual")
        case .unrecognized(let raw): try container.encode(raw)
        }
    }
}

/// Query ordering shared by session and message listings.
enum OpenCodeOrder: String, Sendable, Equatable {
    case asc
    case desc
}

// MARK: - Location (schema/location.ts)

/// `Location.Ref`.
struct LocationRef: Codable, Equatable, Sendable {
    let directory: String
    let workspaceID: String?

    enum CodingKeys: String, CodingKey {
        case directory
        case workspaceID
    }

    init(directory: String, workspaceID: String? = nil) {
        self.directory = directory
        self.workspaceID = workspaceID
    }
}

/// `Location.Info` — resolved by GET /api/location.
struct LocationInfo: Codable, Equatable, Sendable {
    struct ProjectRef: Codable, Equatable, Sendable {
        let id: String
        let directory: String

        enum CodingKeys: String, CodingKey {
            case id
            case directory
        }
    }

    let directory: String
    let workspaceID: String?
    let project: ProjectRef

    enum CodingKeys: String, CodingKey {
        case directory
        case workspaceID
        case project
    }
}

/// Client-side scope for the `?location[directory]=…&location[workspace]=…`
/// deepObject query used by location-scoped list endpoints.
struct LocationScope: Equatable, Sendable {
    let directory: String?
    let workspace: String?

    init(directory: String? = nil, workspace: String? = nil) {
        self.directory = directory
        self.workspace = workspace
    }

    func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let directory {
            items.append(URLQueryItem(name: "location[directory]", value: directory))
        }
        if let workspace {
            items.append(URLQueryItem(name: "location[workspace]", value: workspace))
        }
        return items
    }
}

// MARK: - Model reference (schema/model.ts)

/// `Model.Ref` — `{id, providerID, variant?}`.
///
/// The wire form is always the object; the `"providerID/modelID"` shorthand is
/// tolerated on decode only so additive servers cannot break timelines.
struct ModelRef: Codable, Equatable, Sendable {
    let id: String
    let providerID: String
    let variant: String?

    enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case variant
    }

    init(providerID: String, modelID: String, variant: String? = nil) {
        self.id = modelID
        self.providerID = providerID
        self.variant = variant
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let shorthand = try? single.decode(String.self) {
            let parts = shorthand.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Invalid model ref \(shorthand)")
            }
            providerID = String(parts[0])
            id = String(parts[1])
            variant = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decode(String.self, forKey: .providerID)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerID, forKey: .providerID)
        try container.encodeIfPresent(variant, forKey: .variant)
    }

    /// Display/comparison key in the canonical `providerID/modelID` form.
    var identifier: String { "\(providerID)/\(id)" }
}

// MARK: - Provider (schema/provider.ts)

/// `Provider.Request` — static headers/body merged into provider calls.
struct ProviderRequestOverride: Codable, Equatable, Sendable {
    let headers: [String: String]
    let body: [String: OCJSON]

    enum CodingKeys: String, CodingKey {
        case headers
        case body
    }
}

struct ProviderAISDKConfig: Equatable, Sendable {
    let package: String
    let url: String?
    let settings: [String: OCJSON]?
}

struct ProviderNativeConfig: Equatable, Sendable {
    let url: String?
    let settings: [String: OCJSON]
}

/// `Provider.Api` tagged union (`type: "aisdk" | "native"`).
enum ProviderApiConfig: Equatable, Sendable {
    case aisdk(ProviderAISDKConfig)
    case native(ProviderNativeConfig)
}

extension ProviderApiConfig: Codable {
    private enum Discriminator: String, CodingKey {
        case type
    }

    private enum AISDKKeys: String, CodingKey {
        case type
        case package
        case url
        case settings
    }

    private enum NativeKeys: String, CodingKey {
        case type
        case url
        case settings
    }

    init(from decoder: Decoder) throws {
        let discriminator = try decoder.container(keyedBy: Discriminator.self)
        let type = try discriminator.decode(String.self, forKey: .type)
        switch type {
        case "aisdk":
            let container = try decoder.container(keyedBy: AISDKKeys.self)
            self = .aisdk(ProviderAISDKConfig(
                package: try container.decode(String.self, forKey: .package),
                url: try container.decodeIfPresent(String.self, forKey: .url),
                settings: try container.decodeIfPresent([String: OCJSON].self, forKey: .settings)
            ))
        case "native":
            let container = try decoder.container(keyedBy: NativeKeys.self)
            self = .native(ProviderNativeConfig(
                url: try container.decodeIfPresent(String.self, forKey: .url),
                settings: try container.decodeIfPresent([String: OCJSON].self, forKey: .settings) ?? [:]
            ))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: discriminator, debugDescription: "Unknown provider api kind '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .aisdk(let config):
            var container = encoder.container(keyedBy: AISDKKeys.self)
            try container.encode("aisdk", forKey: .type)
            try container.encode(config.package, forKey: .package)
            try container.encodeIfPresent(config.url, forKey: .url)
            try container.encodeIfPresent(config.settings, forKey: .settings)
        case .native(let config):
            var container = encoder.container(keyedBy: NativeKeys.self)
            try container.encode("native", forKey: .type)
            try container.encodeIfPresent(config.url, forKey: .url)
            try container.encode(config.settings, forKey: .settings)
        }
    }
}

/// `Provider.Info`.
struct ProviderInfo: Codable, Equatable, Sendable {
    let id: String
    let integrationID: String?
    let name: String
    let disabled: Bool?
    let api: ProviderApiConfig
    let request: ProviderRequestOverride

    enum CodingKeys: String, CodingKey {
        case id
        case integrationID
        case name
        case disabled
        case api
        case request
    }
}

// MARK: - Agent (schema/agent.ts)

/// `Agent.Rule` within a ruleset.
struct PermissionRule: Codable, Equatable, Sendable {
    let action: String
    let resource: String
    let effect: PermissionEffect

    enum CodingKeys: String, CodingKey {
        case action
        case resource
        case effect
    }
}

/// `Agent.Info`. `mode` is one of `subagent`, `primary`, `all`; `color` is a
/// `#rrggbb` hex string or a theme token name.
struct AgentInfo: Codable, Equatable, Sendable {
    let id: String
    let model: ModelRef?
    let request: ProviderRequestOverride
    let system: String?
    let description: String?
    let mode: String
    let hidden: Bool
    let color: String?
    let steps: Int?
    let permissions: [PermissionRule]

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case request
        case system
        case description
        case mode
        case hidden
        case color
        case steps
        case permissions
    }
}

// MARK: - Model (schema/model.ts)

struct ModelCapabilities: Codable, Equatable, Sendable {
    let tools: Bool
    let input: [String]
    let output: [String]

    enum CodingKeys: String, CodingKey {
        case tools
        case input
        case output
    }
}

struct ModelCostTier: Codable, Equatable, Sendable {
    let type: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case type
        case size
    }
}

struct ModelCacheCost: Codable, Equatable, Sendable {
    let read: Double
    let write: Double

    enum CodingKeys: String, CodingKey {
        case read
        case write
    }
}

struct ModelCost: Codable, Equatable, Sendable {
    let tier: ModelCostTier?
    let input: Double
    let output: Double
    let cache: ModelCacheCost

    enum CodingKeys: String, CodingKey {
        case tier
        case input
        case output
        case cache
    }
}

struct ModelRequestConfig: Codable, Equatable, Sendable {
    let headers: [String: String]
    let body: [String: OCJSON]
    let variant: String?

    enum CodingKeys: String, CodingKey {
        case headers
        case body
        case variant
    }
}

struct ModelVariantConfig: Codable, Equatable, Sendable {
    let id: String
    let headers: [String: String]
    let body: [String: OCJSON]

    enum CodingKeys: String, CodingKey {
        case id
        case headers
        case body
    }
}

struct ModelTiming: Codable, Equatable, Sendable {
    /// Epoch milliseconds.
    let released: Double

    enum CodingKeys: String, CodingKey {
        case released
    }
}

struct ModelLimitInfo: Codable, Equatable, Sendable {
    let context: Int
    let input: Int?
    let output: Int

    enum CodingKeys: String, CodingKey {
        case context
        case input
        case output
    }
}

/// `Model.Info`. `status` is one of `alpha`, `beta`, `deprecated`, `active`.
struct ModelInfo: Codable, Equatable, Sendable {
    let id: String
    let providerID: String
    let family: String?
    let name: String
    let api: ProviderApiConfig
    let capabilities: ModelCapabilities
    let request: ModelRequestConfig
    let variants: [ModelVariantConfig]
    let time: ModelTiming
    let cost: [ModelCost]
    let status: String
    let enabled: Bool
    let limit: ModelLimitInfo

    enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case family
        case name
        case api
        case capabilities
        case request
        case variants
        case time
        case cost
        case status
        case enabled
        case limit
    }

    /// Canonical `providerID/modelID` key.
    var identifier: String { "\(providerID)/\(id)" }
}

// MARK: - Command and Skill (schema/command.ts, schema/skill.ts)

/// `Command.Info`.
struct CommandInfo: Codable, Equatable, Sendable {
    let name: String
    let template: String
    let description: String?
    let agent: String?
    let model: ModelRef?
    let subtask: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case template
        case description
        case agent
        case model
        case subtask
    }
}

/// `Skill.Info`.
struct SkillInfo: Codable, Equatable, Sendable {
    let name: String
    let description: String?
    let slash: Bool?
    let location: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case slash
        case location
        case content
    }
}

// MARK: - Session (schema/session.ts)

struct TokenCacheUsage: Codable, Equatable, Sendable {
    let read: Double
    let write: Double

    enum CodingKeys: String, CodingKey {
        case read
        case write
    }
}

struct TokenUsage: Codable, Equatable, Sendable {
    let input: Double
    let output: Double
    let reasoning: Double
    let cache: TokenCacheUsage

    enum CodingKeys: String, CodingKey {
        case input
        case output
        case reasoning
        case cache
    }
}

struct FileDiffInfo: Codable, Equatable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String

    enum CodingKeys: String, CodingKey {
        case path
        case status
        case additions
        case deletions
        case patch
    }
}

/// `Revert.State`.
struct RevertState: Codable, Equatable, Sendable {
    let messageID: String
    let partID: String?
    let snapshot: String?
    let diff: String?
    let files: [FileDiffInfo]?

    enum CodingKeys: String, CodingKey {
        case messageID
        case partID
        case snapshot
        case diff
        case files
    }
}

struct SessionTiming: Codable, Equatable, Sendable {
    /// Epoch milliseconds.
    let created: Double
    /// Epoch milliseconds.
    let updated: Double
    /// Epoch milliseconds.
    let archived: Double?

    enum CodingKeys: String, CodingKey {
        case created
        case updated
        case archived
    }
}

/// `Session.Info`.
struct SessionInfo: Codable, Equatable, Sendable {
    let id: String
    let parentID: String?
    let projectID: String
    let agent: String?
    let model: ModelRef?
    let cost: Double
    let tokens: TokenUsage
    let time: SessionTiming
    let title: String
    let location: LocationRef
    let subpath: String?
    let revert: RevertState?

    enum CodingKeys: String, CodingKey {
        case id
        case parentID
        case projectID
        case agent
        case model
        case cost
        case tokens
        case time
        case title
        case location
        case subpath
        case revert
    }
}

struct PageCursor: Codable, Equatable, Sendable {
    let previous: String?
    let next: String?

    enum CodingKeys: String, CodingKey {
        case previous
        case next
    }
}

/// GET /api/session response page.
struct SessionPage: Codable, Equatable, Sendable {
    let data: [SessionInfo]
    let cursor: PageCursor

    enum CodingKeys: String, CodingKey {
        case data
        case cursor
    }

    init(data: [SessionInfo], cursor: PageCursor) {
        self.data = data
        self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([SessionInfo].self, forKey: .data)
        cursor = try container.decodeIfPresent(PageCursor.self, forKey: .cursor) ?? PageCursor(previous: nil, next: nil)
    }
}

/// Query for GET /api/session. At most one of `directory` or `project` should
/// be set (`project` may be combined with `subpath`).
struct SessionsQuery: Equatable, Sendable {
    var directory: String?
    var project: String?
    var subpath: String?
    var workspace: String?
    var limit: Int?
    var order: OpenCodeOrder?
    var search: String?
    var cursor: String?

    init(
        directory: String? = nil,
        project: String? = nil,
        subpath: String? = nil,
        workspace: String? = nil,
        limit: Int? = nil,
        order: OpenCodeOrder? = nil,
        search: String? = nil,
        cursor: String? = nil
    ) {
        self.directory = directory
        self.project = project
        self.subpath = subpath
        self.workspace = workspace
        self.limit = limit
        self.order = order
        self.search = search
        self.cursor = cursor
    }

    func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let directory { items.append(URLQueryItem(name: "directory", value: directory)) }
        if let project { items.append(URLQueryItem(name: "project", value: project)) }
        if let subpath { items.append(URLQueryItem(name: "subpath", value: subpath)) }
        if let workspace { items.append(URLQueryItem(name: "workspace", value: workspace)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let order { items.append(URLQueryItem(name: "order", value: order.rawValue)) }
        if let search { items.append(URLQueryItem(name: "search", value: search)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }
}

// MARK: - Prompt values (schema/prompt.ts)

struct PromptSource: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case text
    }
}

/// `Prompt.FileAttachment` (message echoes). `mime` is required on the wire
/// but decoded tolerantly since it is not an identity field.
struct FileAttachment: Codable, Equatable, Sendable {
    let uri: String
    let mime: String?
    let name: String?
    let description: String?
    let source: PromptSource?

    enum CodingKeys: String, CodingKey {
        case uri
        case mime
        case name
        case description
        case source
    }
}

/// `Prompt.AgentAttachment`.
struct AgentAttachment: Codable, Equatable, Sendable {
    let name: String
    let source: PromptSource?

    enum CodingKeys: String, CodingKey {
        case name
        case source
    }
}

/// `Prompt` / `PromptInput.Prompt` as echoed inside messages and admitted
/// inputs.
struct PromptPayload: Codable, Equatable, Sendable {
    let text: String
    let files: [FileAttachment]?
    let agents: [AgentAttachment]?

    enum CodingKeys: String, CodingKey {
        case text
        case files
        case agents
    }
}

// MARK: - Errors and tool helpers

/// `Session.Error.Unknown` (`{type: "unknown", message}`).
struct UnknownErrorValue: Codable, Equatable, Sendable {
    let message: String

    enum CodingKeys: String, CodingKey {
        case type
        case message
    }

    init(message: String) {
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("unknown", forKey: .type)
        try container.encode(message, forKey: .message)
    }
}

/// `LLM.ProviderMetadata` = Record<string, Record<string, unknown>>.
typealias ProviderMetadataMap = [String: [String: OCJSON]]

struct ToolProviderInfo: Codable, Equatable, Sendable {
    let executed: Bool
    let metadata: ProviderMetadataMap?
    let resultMetadata: ProviderMetadataMap?

    enum CodingKeys: String, CodingKey {
        case executed
        case metadata
        case resultMetadata
    }

    init(
        executed: Bool,
        metadata: ProviderMetadataMap? = nil,
        resultMetadata: ProviderMetadataMap? = nil
    ) {
        self.executed = executed
        self.metadata = metadata
        self.resultMetadata = resultMetadata
    }
}

/// `session.next.retry_error`.
struct RetryErrorInfo: Codable, Equatable, Sendable {
    let message: String
    let statusCode: Double?
    let isRetryable: Bool
    let responseHeaders: [String: String]?
    let responseBody: String?
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case message
        case statusCode
        case isRetryable
        case responseHeaders
        case responseBody
        case metadata
    }
}

// MARK: - Messages (schema/session-message.ts)

struct MessageCreatedTime: Codable, Equatable, Sendable {
    /// Epoch milliseconds.
    let created: Double

    enum CodingKeys: String, CodingKey {
        case created
    }
}

struct MessageSpanTime: Codable, Equatable, Sendable {
    /// Epoch milliseconds.
    let created: Double
    /// Epoch milliseconds.
    let completed: Double?

    enum CodingKeys: String, CodingKey {
        case created
        case completed
    }
}

/// `LLM.ToolContent` — tool result content blocks. Unknown `type` values
/// fail-open so additive tool output cannot fail a whole message page.
enum ToolResultContent: Equatable, Sendable {
    case text(text: String)
    case file(uri: String, mime: String, name: String?)
    case unrecognized(type: String)
}

extension ToolResultContent: Codable {
    private enum Keys: String, CodingKey {
        case type
        case text
        case uri
        case mime
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        switch type {
        case "text":
            guard let text = try? container.decode(String.self, forKey: .text) else {
                self = .unrecognized(type: type)
                return
            }
            self = .text(text: text)
        case "file":
            guard let uri = try? container.decode(String.self, forKey: .uri),
                  let mime = try? container.decode(String.self, forKey: .mime) else {
                self = .unrecognized(type: type)
                return
            }
            self = .file(
                uri: uri,
                mime: mime,
                name: try container.decodeIfPresent(String.self, forKey: .name)
            )
        default:
            self = .unrecognized(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .file(let uri, let mime, let name):
            try container.encode("file", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encode(mime, forKey: .mime)
            try container.encodeIfPresent(name, forKey: .name)
        case .unrecognized(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

/// `SessionMessage.ToolState` tagged union on `status`.
enum ToolRunState: Equatable, Sendable {
    case pending(input: String)
    case running(input: [String: OCJSON], structured: [String: OCJSON], content: [ToolResultContent])
    case completed(
        input: [String: OCJSON],
        attachments: [FileAttachment]?,
        content: [ToolResultContent],
        outputPaths: [String]?,
        structured: [String: OCJSON],
        result: OCJSON?
    )
    case failed(
        input: [String: OCJSON],
        content: [ToolResultContent],
        structured: [String: OCJSON],
        error: UnknownErrorValue,
        result: OCJSON?
    )
}

extension ToolRunState: Codable {
    enum Keys: String, CodingKey {
        case status
        case input
        case structured
        case metadata
        case content
        case attachments
        case outputPaths
        case result
        case error
    }

    /// `structured` is required in current schema; some stored rows still
    /// emit the older `metadata` object. Either object is accepted; both
    /// missing becomes an empty map so the rest of the part can decode.
    private static func structured(in container: KeyedDecodingContainer<Keys>) -> [String: OCJSON] {
        if let structured = try? container.decode([String: OCJSON].self, forKey: .structured) {
            return structured
        }
        if let metadata = try? container.decode([String: OCJSON].self, forKey: .metadata) {
            return metadata
        }
        return [:]
    }

    private static func content(in container: KeyedDecodingContainer<Keys>) -> [ToolResultContent] {
        (try? container.decode([ToolResultContent].self, forKey: .content)) ?? []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "pending":
            self = .pending(input: try container.decode(String.self, forKey: .input))
        case "running":
            self = .running(
                input: try container.decode([String: OCJSON].self, forKey: .input),
                structured: Self.structured(in: container),
                content: Self.content(in: container)
            )
        case "completed":
            self = .completed(
                input: try container.decode([String: OCJSON].self, forKey: .input),
                attachments: try container.decodeIfPresent([FileAttachment].self, forKey: .attachments),
                content: Self.content(in: container),
                outputPaths: try container.decodeIfPresent([String].self, forKey: .outputPaths),
                structured: Self.structured(in: container),
                result: try container.decodeIfPresent(OCJSON.self, forKey: .result)
            )
        case "error":
            self = .failed(
                input: try container.decode([String: OCJSON].self, forKey: .input),
                content: Self.content(in: container),
                structured: Self.structured(in: container),
                error: try container.decode(UnknownErrorValue.self, forKey: .error),
                result: try container.decodeIfPresent(OCJSON.self, forKey: .result)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unknown tool state '\(other)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .pending(let input):
            try container.encode("pending", forKey: .status)
            try container.encode(input, forKey: .input)
        case .running(let input, let structured, let content):
            try container.encode("running", forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encode(structured, forKey: .structured)
            try container.encode(content, forKey: .content)
        case .completed(let input, let attachments, let content, let outputPaths, let structured, let result):
            try container.encode("completed", forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encodeIfPresent(attachments, forKey: .attachments)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(outputPaths, forKey: .outputPaths)
            try container.encode(structured, forKey: .structured)
            try container.encodeIfPresent(result, forKey: .result)
        case .failed(let input, let content, let structured, let error, let result):
            try container.encode("error", forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encode(content, forKey: .content)
            try container.encode(structured, forKey: .structured)
            try container.encode(error, forKey: .error)
            try container.encodeIfPresent(result, forKey: .result)
        }
    }
}

struct ToolPartTiming: Codable, Equatable, Sendable {
    let created: Double
    let ran: Double?
    let completed: Double?
    let pruned: Double?

    enum CodingKeys: String, CodingKey {
        case created
        case ran
        case completed
        case pruned
    }
}

struct AssistantTextContent: Codable, Equatable, Sendable {
    let id: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case text
    }

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try container.decode(String.self, forKey: .text)
    }
}

struct AssistantReasoningContent: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let providerMetadata: ProviderMetadataMap?
    let time: MessageSpanTime?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case providerMetadata
        case time
    }

    init(id: String, text: String, providerMetadata: ProviderMetadataMap? = nil, time: MessageSpanTime? = nil) {
        self.id = id
        self.text = text
        self.providerMetadata = providerMetadata
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try container.decode(String.self, forKey: .text)
        providerMetadata = try container.decodeIfPresent(ProviderMetadataMap.self, forKey: .providerMetadata)
        time = try container.decodeIfPresent(MessageSpanTime.self, forKey: .time)
    }
}

struct AssistantToolPart: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let provider: ToolProviderInfo?
    let state: ToolRunState
    let time: ToolPartTiming

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case state
        case time
        case executed
    }

    init(id: String, name: String, provider: ToolProviderInfo?, state: ToolRunState, time: ToolPartTiming) {
        self.id = id
        self.name = name
        self.provider = provider
        self.state = state
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(ToolRunState.self, forKey: .state)
        time = try container.decode(ToolPartTiming.self, forKey: .time)
        if let nested = try container.decodeIfPresent(ToolProviderInfo.self, forKey: .provider) {
            provider = nested
        } else if let executed = try container.decodeIfPresent(Bool.self, forKey: .executed) {
            provider = ToolProviderInfo(executed: executed)
        } else {
            provider = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(state, forKey: .state)
        try container.encode(time, forKey: .time)
    }
}

/// `SessionMessage.AssistantContent` tagged union on `type`. Unknown members
/// fail-open so additive content cannot fail a whole message page.
enum AssistantContent: Equatable, Sendable {
    case text(AssistantTextContent)
    case reasoning(AssistantReasoningContent)
    case tool(AssistantToolPart)
    case unrecognized(type: String)
}

extension AssistantContent: Codable {
    private enum Keys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        switch type {
        case "text":
            self = (try? AssistantTextContent(from: decoder)).map { .text($0) } ?? .unrecognized(type: type)
        case "reasoning":
            self = (try? AssistantReasoningContent(from: decoder)).map { .reasoning($0) } ?? .unrecognized(type: type)
        case "tool":
            self = (try? AssistantToolPart(from: decoder)).map { .tool($0) } ?? .unrecognized(type: type)
        default:
            self = .unrecognized(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let content):
            try Self.encode(payload: content, discriminator: "text", to: encoder)
        case .reasoning(let content):
            try Self.encode(payload: content, discriminator: "reasoning", to: encoder)
        case .tool(let content):
            try Self.encode(payload: content, discriminator: "tool", to: encoder)
        case .unrecognized(let type):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(type, forKey: .type)
        }
    }

    /// Writes a discriminated payload by merging the literal `type` key into
    /// the payload's own encoded object, keeping a single keyed container.
    private static func encode<P: Encodable>(payload: P, discriminator: String, to encoder: Encoder) throws {
        var fields: [String: OCJSON]
        if case .object(let decoded) = OCJSON(capturing: payload) {
            fields = decoded
        } else {
            fields = [:]
        }
        fields["type"] = .string(discriminator)
        var container = encoder.singleValueContainer()
        try container.encode(OCJSON.object(fields))
    }
}

struct AssistantSnapshot: Codable, Equatable, Sendable {
    let start: String?
    let end: String?
    let files: [String]?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case files
    }
}

struct AgentSwitchedMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let time: MessageCreatedTime
    let agent: String

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case time
        case agent
    }
}

struct ModelSwitchedMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let time: MessageCreatedTime
    let model: ModelRef

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case time
        case model
    }
}

struct UserMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let time: MessageCreatedTime
    let text: String
    let files: [FileAttachment]?
    let agents: [AgentAttachment]?

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case time
        case text
        case files
        case agents
    }
}

struct SyntheticMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let time: MessageCreatedTime
    let sessionID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case time
        case sessionID
        case text
    }
}

struct SystemMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let time: MessageCreatedTime
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case time
        case text
    }
}

struct ShellMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let time: MessageSpanTime
    let callID: String
    let command: String
    let output: String

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case time
        case callID
        case command
        case output
    }
}

struct AssistantMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let agent: String
    let model: ModelRef
    let content: [AssistantContent]
    let snapshot: AssistantSnapshot?
    let finish: String?
    let cost: Double?
    let tokens: TokenUsage?
    let error: UnknownErrorValue?
    let time: MessageSpanTime

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case agent
        case model
        case content
        case snapshot
        case finish
        case cost
        case tokens
        case error
        case time
    }
}

struct CompactionMessage: Codable, Equatable, Sendable {
    let id: String
    let metadata: [String: OCJSON]?
    let time: MessageCreatedTime
    let reason: CompactionReason
    let summary: String
    let recent: String

    enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case time
        case reason
        case summary
        case recent
    }
}

/// `SessionMessage.Message` tagged union on `type`. Unrecognized kinds from
/// newer servers fall into `.unrecognized(type:)` instead of failing the whole
/// timeline decode.
enum OCMessage: Equatable, Sendable {
    case agentSwitched(AgentSwitchedMessage)
    case modelSwitched(ModelSwitchedMessage)
    case user(UserMessage)
    case synthetic(SyntheticMessage)
    case system(SystemMessage)
    case shell(ShellMessage)
    case assistant(AssistantMessage)
    case compaction(CompactionMessage)
    case unrecognized(type: String)
}

extension OCMessage: Codable {
    private enum Keys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "agent-switched": self = .agentSwitched(try AgentSwitchedMessage(from: decoder))
        case "model-switched": self = .modelSwitched(try ModelSwitchedMessage(from: decoder))
        case "user": self = .user(try UserMessage(from: decoder))
        case "synthetic": self = .synthetic(try SyntheticMessage(from: decoder))
        case "system": self = .system(try SystemMessage(from: decoder))
        case "shell": self = .shell(try ShellMessage(from: decoder))
        case "assistant": self = .assistant(try AssistantMessage(from: decoder))
        case "compaction": self = .compaction(try CompactionMessage(from: decoder))
        case let other: self = .unrecognized(type: other)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .agentSwitched(let message):
            try Self.write(message, discriminator: "agent-switched", to: encoder)
        case .modelSwitched(let message):
            try Self.write(message, discriminator: "model-switched", to: encoder)
        case .user(let message):
            try Self.write(message, discriminator: "user", to: encoder)
        case .synthetic(let message):
            try Self.write(message, discriminator: "synthetic", to: encoder)
        case .system(let message):
            try Self.write(message, discriminator: "system", to: encoder)
        case .shell(let message):
            try Self.write(message, discriminator: "shell", to: encoder)
        case .assistant(let message):
            try Self.write(message, discriminator: "assistant", to: encoder)
        case .compaction(let message):
            try Self.write(message, discriminator: "compaction", to: encoder)
        case .unrecognized:
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Cannot encode an unrecognized message")
            )
        }
    }

    /// Writes a union member by merging the literal `type` key into the
    /// message's own encoded object, keeping a single keyed container.
    private static func write<P: Encodable>(_ payload: P, discriminator: String, to encoder: Encoder) throws {
        var fields: [String: OCJSON]
        if case .object(let decoded) = OCJSON(capturing: payload) {
            fields = decoded
        } else {
            fields = [:]
        }
        fields["type"] = .string(discriminator)
        var container = encoder.singleValueContainer()
        try container.encode(OCJSON.object(fields))
    }

    /// Wire discriminator for this message kind.
    var typeName: String {
        switch self {
        case .agentSwitched: return "agent-switched"
        case .modelSwitched: return "model-switched"
        case .user: return "user"
        case .synthetic: return "synthetic"
        case .system: return "system"
        case .shell: return "shell"
        case .assistant: return "assistant"
        case .compaction: return "compaction"
        case .unrecognized: return "unrecognized"
        }
    }
}

// MARK: - Session input (schema/session-input.ts, schema/prompt-input.ts)

/// Outgoing prompt body (`PromptInput.Prompt`). Mirrors the exact input shape;
/// notably `files` entries carry no `mime`.
struct PromptInputFileAttachment: Encodable, Equatable, Sendable {
    let uri: String
    let name: String?
    let description: String?
    let source: PromptSource?

    enum CodingKeys: String, CodingKey {
        case uri
        case name
        case description
        case source
    }
}

struct PromptInput: Encodable, Equatable, Sendable {
    let text: String
    let files: [PromptInputFileAttachment]?
    let agents: [AgentAttachment]?

    enum CodingKeys: String, CodingKey {
        case text
        case files
        case agents
    }
}

/// `SessionInput.Admitted` — durable admission receipt for POST …/prompt.
struct AdmittedInput: Codable, Equatable, Sendable {
    let admittedSeq: Int
    let id: String
    let sessionID: String
    let prompt: PromptPayload
    let delivery: PromptDelivery
    /// Epoch milliseconds.
    let timeCreated: Double
    let promotedSeq: Int?

    init(
        admittedSeq: Int,
        id: String,
        sessionID: String,
        prompt: PromptPayload,
        delivery: PromptDelivery,
        timeCreated: Double,
        promotedSeq: Int? = nil
    ) {
        self.admittedSeq = admittedSeq
        self.id = id
        self.sessionID = sessionID
        self.prompt = prompt
        self.delivery = delivery
        self.timeCreated = timeCreated
        self.promotedSeq = promotedSeq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        admittedSeq = try container.decodeIfPresent(Int.self, forKey: .admittedSeq) ?? 0
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        if let prompt = try container.decodeIfPresent(PromptPayload.self, forKey: .prompt) {
            self.prompt = prompt
        } else {
            self.prompt = try container.decode(PromptPayload.self, forKey: .payload)
        }
        delivery = try container.decodeIfPresent(PromptDelivery.self, forKey: .delivery) ?? .steer
        timeCreated = try container.decode(Double.self, forKey: .timeCreated)
        promotedSeq = try container.decodeIfPresent(Int.self, forKey: .promotedSeq)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(admittedSeq, forKey: .admittedSeq)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(delivery, forKey: .delivery)
        try container.encode(timeCreated, forKey: .timeCreated)
        try container.encodeIfPresent(promotedSeq, forKey: .promotedSeq)
    }

    enum CodingKeys: String, CodingKey {
        case admittedSeq
        case id
        case sessionID
        case prompt
        case payload
        case delivery
        case timeCreated
        case promotedSeq
    }
}

// MARK: - Permissions and questions (schema/permission.ts, schema/question.ts)

/// `Permission.Source` (currently only the `tool` variant).
struct PermissionSource: Codable, Equatable, Sendable {
    let type: String
    let messageID: String
    let callID: String

    enum CodingKeys: String, CodingKey {
        case type
        case messageID
        case callID
    }
}

/// `Permission.Request`.
struct PermissionRequest: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let action: String
    let resources: [String]
    let save: [String]?
    let metadata: [String: OCJSON]?
    let source: PermissionSource?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case action
        case resources
        case save
        case metadata
        case source
    }
}

/// `PermissionSaved.Info`.
struct PermissionSavedInfo: Codable, Equatable, Sendable {
    let id: String
    let projectID: String
    let action: String
    let resource: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case action
        case resource
    }
}

struct QuestionOption: Codable, Equatable, Sendable {
    let label: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case label
        case description
    }
}

/// `Question.Info`.
struct QuestionInfo: Codable, Equatable, Sendable {
    let question: String
    let header: String
    let options: [QuestionOption]
    let multiple: Bool?
    /// Allow typing a custom answer; server default is true.
    let custom: Bool?

    enum CodingKeys: String, CodingKey {
        case question
        case header
        case options
        case multiple
        case custom
    }
}

/// `Question.Tool`.
struct QuestionToolRef: Codable, Equatable, Sendable {
    let messageID: String
    let callID: String

    enum CodingKeys: String, CodingKey {
        case messageID
        case callID
    }
}

/// `Question.Request`.
struct QuestionRequest: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let questions: [QuestionInfo]
    let tool: QuestionToolRef?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case questions
        case tool
    }
}

/// `Question.Reply` body — answers aligned with the questions, each answer an
/// array of selected labels.
struct QuestionReplyBody: Encodable, Equatable, Sendable {
    let answers: [[String]]

    enum CodingKeys: String, CodingKey {
        case answers
    }
}

// MARK: - Events (schema/event.ts envelope + schema/session-event.ts payloads)

/// `Event.Payload.durable` tag.
struct EventDurableTag: Codable, Equatable, Sendable {
    let aggregateID: String
    let seq: Int
    let version: Int

    enum CodingKeys: String, CodingKey {
        case aggregateID
        case seq
        case version
    }
}

// Shared base fields (`timestamp` is epoch milliseconds; `sessionID` present on
// all session.next.* payloads).

struct PromptedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let messageID: String
    let prompt: PromptPayload
    let delivery: PromptDelivery

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case messageID
        case prompt
        case delivery
    }
}

struct AgentSwitchedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let messageID: String
    let agent: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case messageID
        case agent
    }
}

struct ModelSwitchedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let messageID: String
    let model: ModelRef

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case messageID
        case model
    }
}

struct StepStartedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let agent: String
    let model: ModelRef
    let snapshot: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case agent
        case model
        case snapshot
    }
}

struct StepEndedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let finish: String
    let cost: Double
    let tokens: TokenUsage
    let snapshot: String?
    let files: [String]?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case finish
        case cost
        case tokens
        case snapshot
        case files
    }
}

struct StepFailedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let error: UnknownErrorValue

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case error
    }
}

struct TextStartedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let textID: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case textID
    }
}

struct TextDeltaEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let textID: String
    let delta: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case textID
        case delta
    }
}

struct TextEndedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let textID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case textID
        case text
    }
}

struct ReasoningStartedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let reasoningID: String
    let providerMetadata: ProviderMetadataMap?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case reasoningID
        case providerMetadata
    }
}

struct ReasoningDeltaEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let reasoningID: String
    let delta: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case reasoningID
        case delta
    }
}

struct ReasoningEndedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let reasoningID: String
    let text: String
    let providerMetadata: ProviderMetadataMap?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case reasoningID
        case text
        case providerMetadata
    }
}

struct ToolInputStartedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let callID: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case callID
        case name
    }
}

struct ToolInputDeltaEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let callID: String
    let delta: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case callID
        case delta
    }
}

struct ToolInputEndedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let callID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case callID
        case text
    }
}

struct ToolCalledEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let callID: String
    let tool: String
    let input: [String: OCJSON]
    let provider: ToolProviderInfo

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case callID
        case tool
        case input
        case provider
    }
}

struct ToolProgressEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let callID: String
    let structured: [String: OCJSON]
    let content: [ToolResultContent]

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case callID
        case structured
        case content
    }
}

struct ToolSuccessEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let callID: String
    let structured: [String: OCJSON]
    let content: [ToolResultContent]
    let outputPaths: [String]?
    let result: OCJSON?
    let provider: ToolProviderInfo

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case callID
        case structured
        case content
        case outputPaths
        case result
        case provider
    }
}

struct ToolFailedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let assistantMessageID: String
    let callID: String
    let error: UnknownErrorValue
    let result: OCJSON?
    let provider: ToolProviderInfo

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case assistantMessageID
        case callID
        case error
        case result
        case provider
    }
}

struct RetriedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let attempt: Double
    let error: RetryErrorInfo

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case attempt
        case error
    }
}

struct CompactionStartedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let messageID: String
    let reason: CompactionReason

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case messageID
        case reason
    }
}

struct CompactionDeltaEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let messageID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case messageID
        case text
    }
}

struct CompactionEndedEventData: Codable, Equatable, Sendable {
    let timestamp: Double
    let sessionID: String
    let messageID: String
    let reason: CompactionReason
    let text: String
    let recent: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case messageID
        case reason
        case text
        case recent
    }
}

/// `SessionTodo.Info`.
struct TodoItem: Codable, Equatable, Sendable {
    let content: String
    /// pending | in_progress | completed | cancelled.
    let status: String
    /// high | medium | low.
    let priority: String

    enum CodingKeys: String, CodingKey {
        case content
        case status
        case priority
    }
}

/// `todo.updated` (carries only `sessionID`, no timestamp).
struct TodoUpdatedEventData: Codable, Equatable, Sendable {
    let sessionID: String
    let todos: [TodoItem]

    enum CodingKeys: String, CodingKey {
        case sessionID
        case todos
    }
}

/// `file.edited` (carries only `file`).
struct FileEditedEventData: Codable, Equatable, Sendable {
    let file: String

    enum CodingKeys: String, CodingKey {
        case file
    }
}

/// `permission.v2.replied`.
struct PermissionRepliedEventData: Codable, Equatable, Sendable {
    let sessionID: String
    let requestID: String
    let reply: PermissionReply

    enum CodingKeys: String, CodingKey {
        case sessionID
        case requestID
        case reply
    }
}

/// `question.v2.replied`.
struct QuestionRepliedEventData: Codable, Equatable, Sendable {
    let sessionID: String
    let requestID: String
    let answers: [[String]]

    enum CodingKeys: String, CodingKey {
        case sessionID
        case requestID
        case answers
    }
}

/// `question.v2.rejected`.
struct QuestionRejectedEventData: Codable, Equatable, Sendable {
    let sessionID: String
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case sessionID
        case requestID
    }
}

/// Typed decodings of the event envelopes the app consumes. Unknown event
/// types fall into `.unknown(raw)` without throwing.
enum OpenCodeEventData: Equatable, Sendable {
    /// `session.next.prompted` and `session.next.prompt.admitted` share this shape.
    case prompted(PromptedEventData)
    case agentSwitched(AgentSwitchedEventData)
    case modelSwitched(ModelSwitchedEventData)
    case stepStarted(StepStartedEventData)
    case stepEnded(StepEndedEventData)
    case stepFailed(StepFailedEventData)
    case textStarted(TextStartedEventData)
    case textDelta(TextDeltaEventData)
    case textEnded(TextEndedEventData)
    case reasoningStarted(ReasoningStartedEventData)
    case reasoningDelta(ReasoningDeltaEventData)
    case reasoningEnded(ReasoningEndedEventData)
    case toolInputStarted(ToolInputStartedEventData)
    case toolInputDelta(ToolInputDeltaEventData)
    case toolInputEnded(ToolInputEndedEventData)
    case toolCalled(ToolCalledEventData)
    case toolProgress(ToolProgressEventData)
    case toolSuccess(ToolSuccessEventData)
    case toolFailed(ToolFailedEventData)
    case retried(RetriedEventData)
    case compactionStarted(CompactionStartedEventData)
    case compactionDelta(CompactionDeltaEventData)
    case compactionEnded(CompactionEndedEventData)
    case todoUpdated(TodoUpdatedEventData)
    case fileEdited(FileEditedEventData)
    /// `permission.v2.asked` carries a full `Permission.Request`.
    case permissionAsked(PermissionRequest)
    case permissionReplied(PermissionRepliedEventData)
    /// `question.v2.asked` carries a full `Question.Request`.
    case questionAsked(QuestionRequest)
    case questionReplied(QuestionRepliedEventData)
    case questionRejected(QuestionRejectedEventData)
    case serverConnected
    case unknown(OCJSON)

    var rawRepresentation: OCJSON {
        switch self {
        case .prompted(let value): return OCJSON(capturing: value)
        case .agentSwitched(let value): return OCJSON(capturing: value)
        case .modelSwitched(let value): return OCJSON(capturing: value)
        case .stepStarted(let value): return OCJSON(capturing: value)
        case .stepEnded(let value): return OCJSON(capturing: value)
        case .stepFailed(let value): return OCJSON(capturing: value)
        case .textStarted(let value): return OCJSON(capturing: value)
        case .textDelta(let value): return OCJSON(capturing: value)
        case .textEnded(let value): return OCJSON(capturing: value)
        case .reasoningStarted(let value): return OCJSON(capturing: value)
        case .reasoningDelta(let value): return OCJSON(capturing: value)
        case .reasoningEnded(let value): return OCJSON(capturing: value)
        case .toolInputStarted(let value): return OCJSON(capturing: value)
        case .toolInputDelta(let value): return OCJSON(capturing: value)
        case .toolInputEnded(let value): return OCJSON(capturing: value)
        case .toolCalled(let value): return OCJSON(capturing: value)
        case .toolProgress(let value): return OCJSON(capturing: value)
        case .toolSuccess(let value): return OCJSON(capturing: value)
        case .toolFailed(let value): return OCJSON(capturing: value)
        case .retried(let value): return OCJSON(capturing: value)
        case .compactionStarted(let value): return OCJSON(capturing: value)
        case .compactionDelta(let value): return OCJSON(capturing: value)
        case .compactionEnded(let value): return OCJSON(capturing: value)
        case .todoUpdated(let value): return OCJSON(capturing: value)
        case .fileEdited(let value): return OCJSON(capturing: value)
        case .permissionAsked(let value): return OCJSON(capturing: value)
        case .permissionReplied(let value): return OCJSON(capturing: value)
        case .questionAsked(let value): return OCJSON(capturing: value)
        case .questionReplied(let value): return OCJSON(capturing: value)
        case .questionRejected(let value): return OCJSON(capturing: value)
        case .serverConnected: return .object([:])
        case .unknown(let raw): return raw
        }
    }
}

/// SSE event envelope shared by `/api/event` and `/api/session/:id/event`
/// (`{id, type, data, durable?, location?, metadata?}`). The `data` field is
/// decoded twice: once as the raw JSON tree and once into the typed payload;
/// unknown or malformed payloads degrade to `.unknown(raw)` instead of failing
/// the stream. Required identity fields (`id`, `type`) fail closed.
struct OpenCodeEvent: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let durable: EventDurableTag?
    let location: LocationRef?
    let metadata: [String: OCJSON]?
    let data: OpenCodeEventData
    /// Raw JSON tree for `data`, preserved verbatim from the wire.
    let rawData: OCJSON

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case data
        case durable
        case location
        case metadata
    }

    init(
        id: String,
        type: String,
        durable: EventDurableTag? = nil,
        location: LocationRef? = nil,
        metadata: [String: OCJSON]? = nil,
        data: OpenCodeEventData,
        rawData: OCJSON? = nil
    ) {
        self.id = id
        self.type = type
        self.durable = durable
        self.location = location
        self.metadata = metadata
        self.data = data
        self.rawData = rawData ?? data.rawRepresentation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        durable = try container.decodeIfPresent(EventDurableTag.self, forKey: .durable)
        location = try container.decodeIfPresent(LocationRef.self, forKey: .location)
        metadata = try container.decodeIfPresent([String: OCJSON].self, forKey: .metadata)
        rawData = (try? container.decode(OCJSON.self, forKey: .data)) ?? .null
        data = Self.typedData(type: type, raw: rawData, container: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(rawData, forKey: .data)
        try container.encodeIfPresent(durable, forKey: .durable)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }

    private static func typedData(
        type: String,
        raw: OCJSON,
        container: KeyedDecodingContainer<OpenCodeEvent.CodingKeys>
    ) -> OpenCodeEventData {
        func decode<D: Decodable>(_ type: D.Type) -> D? {
            try? container.decode(D.self, forKey: .data)
        }
        switch type {
        case "session.next.prompted", "session.next.prompt.admitted":
            return decode(PromptedEventData.self).map { .prompted($0) } ?? .unknown(raw)
        case "session.next.agent.switched":
            return decode(AgentSwitchedEventData.self).map { .agentSwitched($0) } ?? .unknown(raw)
        case "session.next.model.switched":
            return decode(ModelSwitchedEventData.self).map { .modelSwitched($0) } ?? .unknown(raw)
        case "session.next.step.started":
            return decode(StepStartedEventData.self).map { .stepStarted($0) } ?? .unknown(raw)
        case "session.next.step.ended":
            return decode(StepEndedEventData.self).map { .stepEnded($0) } ?? .unknown(raw)
        case "session.next.step.failed":
            return decode(StepFailedEventData.self).map { .stepFailed($0) } ?? .unknown(raw)
        case "session.next.text.started":
            return decode(TextStartedEventData.self).map { .textStarted($0) } ?? .unknown(raw)
        case "session.next.text.delta":
            return decode(TextDeltaEventData.self).map { .textDelta($0) } ?? .unknown(raw)
        case "session.next.text.ended":
            return decode(TextEndedEventData.self).map { .textEnded($0) } ?? .unknown(raw)
        case "session.next.reasoning.started":
            return decode(ReasoningStartedEventData.self).map { .reasoningStarted($0) } ?? .unknown(raw)
        case "session.next.reasoning.delta":
            return decode(ReasoningDeltaEventData.self).map { .reasoningDelta($0) } ?? .unknown(raw)
        case "session.next.reasoning.ended":
            return decode(ReasoningEndedEventData.self).map { .reasoningEnded($0) } ?? .unknown(raw)
        case "session.next.tool.input.started":
            return decode(ToolInputStartedEventData.self).map { .toolInputStarted($0) } ?? .unknown(raw)
        case "session.next.tool.input.delta":
            return decode(ToolInputDeltaEventData.self).map { .toolInputDelta($0) } ?? .unknown(raw)
        case "session.next.tool.input.ended":
            return decode(ToolInputEndedEventData.self).map { .toolInputEnded($0) } ?? .unknown(raw)
        case "session.next.tool.called":
            return decode(ToolCalledEventData.self).map { .toolCalled($0) } ?? .unknown(raw)
        case "session.next.tool.progress":
            return decode(ToolProgressEventData.self).map { .toolProgress($0) } ?? .unknown(raw)
        case "session.next.tool.success":
            return decode(ToolSuccessEventData.self).map { .toolSuccess($0) } ?? .unknown(raw)
        case "session.next.tool.failed":
            return decode(ToolFailedEventData.self).map { .toolFailed($0) } ?? .unknown(raw)
        case "session.next.retried":
            return decode(RetriedEventData.self).map { .retried($0) } ?? .unknown(raw)
        case "session.next.compaction.started":
            return decode(CompactionStartedEventData.self).map { .compactionStarted($0) } ?? .unknown(raw)
        case "session.next.compaction.delta":
            return decode(CompactionDeltaEventData.self).map { .compactionDelta($0) } ?? .unknown(raw)
        case "session.next.compaction.ended":
            return decode(CompactionEndedEventData.self).map { .compactionEnded($0) } ?? .unknown(raw)
        case "todo.updated":
            return decode(TodoUpdatedEventData.self).map { .todoUpdated($0) } ?? .unknown(raw)
        case "file.edited":
            return decode(FileEditedEventData.self).map { .fileEdited($0) } ?? .unknown(raw)
        case "permission.v2.asked":
            return decode(PermissionRequest.self).map { .permissionAsked($0) } ?? .unknown(raw)
        case "permission.v2.replied":
            return decode(PermissionRepliedEventData.self).map { .permissionReplied($0) } ?? .unknown(raw)
        case "question.v2.asked":
            return decode(QuestionRequest.self).map { .questionAsked($0) } ?? .unknown(raw)
        case "question.v2.replied":
            return decode(QuestionRepliedEventData.self).map { .questionReplied($0) } ?? .unknown(raw)
        case "question.v2.rejected":
            return decode(QuestionRejectedEventData.self).map { .questionRejected($0) } ?? .unknown(raw)
        case "server.connected":
            return .serverConnected
        default:
            return .unknown(raw)
        }
    }
}

/// GET /api/session/:id/history response.
struct HistoryPage: Codable, Equatable, Sendable {
    let data: [OpenCodeEvent]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore
    }
}

/// GET /api/session/:id/message response page.
struct MessagePage: Codable, Equatable, Sendable {
    let data: [OCMessage]
    let cursor: PageCursor

    enum CodingKeys: String, CodingKey {
        case data
        case cursor
    }

    init(data: [OCMessage], cursor: PageCursor) {
        self.data = data
        self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([OCMessage].self, forKey: .data)
        cursor = try container.decodeIfPresent(PageCursor.self, forKey: .cursor) ?? PageCursor(previous: nil, next: nil)
    }
}

// MARK: - Filesystem (schema/filesystem.ts)

/// `FileSystem.Entry.type`.
enum FSKind: String, Codable, Sendable {
    case file
    case directory
}

/// `FileSystem.Entry`. The wire discriminator is `"type"`; directory paths
/// end with a trailing slash and are preserved verbatim.
struct FSEntry: Codable, Equatable, Sendable {
    let path: String
    let kind: FSKind

    enum CodingKeys: String, CodingKey { case path, kind = "type" }
}

/// GET /api/fs/list response — resolved location plus direct children
/// (`Location.response([FileSystem.Entry])`).
struct DirectoryListing: Equatable, Sendable {
    let location: LocationInfo
    let entries: [FSEntry]
}
