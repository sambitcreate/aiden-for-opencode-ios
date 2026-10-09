# Aiden for OpenCode — integration contract

Binding interface spec for the V2 remap. Every implementation agent MUST match these names/signatures exactly. Source-of-truth wire shapes: `../../opencode/packages/schema/src/*.ts`; endpoint reference: `../../opencode/specs/v2/server-api.md`.

## Ownership map (do not touch files you don't own)

| Area | Owner | Files |
|---|---|---|
| Transport | Networking agent | `Networking/OpenCode/*.swift`, `Networking/AidenSSEParser.swift` (rewrite ok); deletes `AidenRemoteContract.swift`, `AidenRemoteClient.swift`, `AidenServerTrust.swift` |
| Installation + pairing + coordinator | Pairing agent | `Models/AidenInstallation.swift` (rewritten), `Auth/KeychainStore.swift`, `Features/Remote/AidenPairingView.swift`, `Features/Remote/AidenRemoteCoordinator.swift` |
| Chat | Chat agent | `Models/AidenChat.swift` (rewritten), `Features/Remote/AidenChatFeature.swift` (rewritten) |
| Shell + prune | Shell agent | `ContentView.swift`, `Features/Remote/AidenProductShellView.swift`, `Features/Remote/AidenWorkspaceShellView.swift` (deleted), `Features/Bots/**` (deleted), `Features/Remote/AidenScheduledTasksView.swift` (deleted), `Features/Remote/AidenWorkspaceEnvironmentView.swift` + `AidenBotChatToolsView.swift` (deleted), `Features/Shared/**` kept, `Models/AidenBot.swift`, `Models/AidenScheduledTask.swift`, `Models/AidenWorkspaceEnvironment.swift` (deleted), `Persistence/AidenBotCache.swift` (deleted), `Persistence/AidenChatCache.swift` + `AidenChatDraftStore.swift` (kept, may be simplified by chat agent), `AppIntents/AidenAppIntents.swift`, `LiveActivities/*`, `Config/AppConfig.swift` |

## Shared types (already defined by transport layer)

From `Networking/OpenCode/OpenCodeCredential.swift`: `OpenCodeServerConfig {baseURL, username, password}`.
From `OpenCodeModels.swift`: `LocationInfo`, `LocationScope`, `AgentInfo`, `ModelInfo`, `ModelRef` (**object** `{id, providerID, variant?}` — never a bare string; construct via `ModelRef(providerID:modelID:)`, display/compare via `.identifier`), `ProviderInfo`, `SessionInfo` (timestamps are epoch-ms `Double`s), `SessionPage`, `OCMessage`, `MessagePage`, `AdmittedInput`, `HistoryPage`, `PermissionRequest`, `PermissionReply` (`once|always|reject`), `QuestionRequest`, `PromptDelivery` (`steer|queue`), `OpenCodeEvent {id, type, durable?, location?, metadata?, data, rawData}` with `OpenCodeEventData` typed union (unknown types decode to `.unknown`, never throw).
From `OpenCodeClient.swift`: `actor OpenCodeClient` — full REST + SSE surface: `health()`, `location(scope:)`, `agents/models/providers/commands/skills(scope:)`, `sessions(query:)`, `createSession(agent:model:directory:)`, `session(id:)`, `messages(sessionID:limit:order:cursor:)`, `context(sessionID:)`, `history(sessionID:after:limit:)`, `prompt(sessionID:text:id:delivery:files:agents:) -> AdmittedInput`, `interrupt`, `compact`, `wait`, `switchAgent`, `switchModel(modelRef:)`, `permissionRequests`, `sessionPermissions`, `replyPermission(sessionID:requestID:reply:message:)`, `questionRequests`, `replyQuestion(sessionID:requestID:answers:)`, `rejectQuestion`, `globalEvents()`, `sessionEvents(sessionID:after:)`. Errors: `OpenCodeAPIError` (`.unauthorized`, `.notFound`, `.conflict`, `.server`, `.network`, `.decoding`, `.invalidURL`).
From `OpenCodePairing.swift`: `OpenCodePairingPayload`, `PairingVerifier.verify(config:client:) -> VerifiedServer` (the health probe carries the candidate Basic credentials — V2's authorization middleware guards `/api/health` too).

## Coordinator API (pairing agent implements; others consume)

```swift
enum AidenRemoteConnectionState: Equatable {
    case needsPairing
    case connecting
    case connected(server: VerifiedServer)
    case offline(message: String)
}

@MainActor @Observable final class AidenRemoteCoordinator {
    let installationStore: OpenCodeInstallationStore     // renamed from AidenInstallationStore
    private(set) var connectionState: AidenRemoteConnectionState
    var presentedError: String?
    var activeInstallationId: String?

    func start() async
    func connectActiveInstallation() async
    func switchInstallation(to id: String) async
    /// Validate + persist a new installation. Returns failure reason for UI.
    func pair(with config: OpenCodeServerConfig, name: String?) async -> Result<Void, PairingFailure>
    func removeInstallation(id: String) async
    /// Client bound to the ACTIVE installation. Throws if not connected.
    func client() throws -> OpenCodeClient
    /// Stable identity used by caches/deep-links (= installation id).
    var instanceId: String? { get }
    func requestContext() -> String?   // instance id or nil
    func isCurrent(_ instanceId: String) -> Bool
}

enum PairingFailure: Equatable, Error { case unreachable, unauthorized, notOpencode, storage }
```

`OpenCodeInstallation` (in rewritten `Models/AidenInstallation.swift`):
```swift
struct OpenCodeInstallation: Codable, Equatable, Identifiable, Sendable {
    var id: String            // stable UUID generated at pair time (deep-link/caching key)
    var name: String          // user-visible label, defaults to host
    var endpoint: URL         // server base URL
    var username: String      // "opencode"
    var createdAt: Date
    var lastConnectedAt: Date?
}
```
Password is stored ONLY under Keychain service `sbtbiswas.AidenForOpenCode.pairing`, key = installation id. `OpenCodeInstallationStore` keeps `{installations, activeInstallationId}` snapshot in Keychain as today; API: `installations`, `activeInstallationId`, `credential(for:) -> String?`, `save(name:endpoint:username:password:) throws -> OpenCodeInstallation`, `updateLastConnected(id:date:)`, `setActive(id:)`, `remove(id:)`.

401 handling anywhere → coordinator marks state `.offline("Session expired — reconnect from Settings")` and does NOT auto-delete the installation.

## Chat architecture (chat agent)

- One long-lived `globalEvents()` subscription per active chat screen (and one lightweight app-level subscription for session-list presence badges when connected). Route by `event.data`'s `sessionID` field present in every `session.next.*` payload.
- Live text: append `.textDelta` to an ephemeral bubble keyed by `assistantMessageID`; on `.textEnded` replace with full text and clear ephemeral.
- Durable reconciliation: track `lastDurableSeq` per session from `event.durable.seq`; on reconnect or gap, fetch `messages(sessionID:)` fresh and `history(sessionID:after:lastDurableSeq)` for missed boundary events. Never re-send prompts automatically.
- Send path: optimistic user bubble (id `local-<uuid>`) → `prompt(sessionID:text:)` → replace with returned `AdmittedInput.id`. On failure remove optimistic bubble and surface error. No retry loop.
- Approvals: `.permissionAsked` → card with Once/Always/Deny → `replyPermission(reply: "once"|"always"|"reject")`. Questions: `.questionAsked` → options UI → `replyQuestion`/`rejectQuestion`.
- Interrupt: toolbar stop button → `interrupt(sessionID:)`.
- Model/agent selection per session via `switchModel`/`switchAgent`; pickers fed by `models()`/`agents()`.

## Deep links & App Intents (shell agent)

Scheme `aiden-opencode`: `aiden-opencode://session/<id>` opens chat, `aiden-opencode://new` creates a session. App Intents reduced to OpenApp + optional deep-link parameter. Live Activities driven from chat VM only (start on prompt admitted, end on step.ended/idle).

## Persistence namespaces

Ruling (post-review): the legacy `AidenChatCache`/`AidenChatDraftStore` files were **removed** rather than ported. Drafts live in the chat view-model for the session's lifetime; session lists refetch from the server on cold start. If offline draft/list caching returns, add an `OpenCodeChatCache-v1` namespace keyed by `instanceId + sessionID`. Deep links and App Intents keep using the App Group catalog (`ids/titles only`).
