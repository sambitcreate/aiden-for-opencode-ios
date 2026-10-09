# AGENTS.md — Aiden for OpenCode working agreement

Aiden for OpenCode is a native SwiftUI iPhone/iPad companion for the **OpenCode V2 server** (`../opencode/packages/server` + `../opencode/packages/protocol` in the sibling OpenCode repository, aka "opencode2"). It is a port of the former "Aiden On The Go" app, re-targeted from the retired Aiden-remote-v1 protocol to OpenCode V2 exclusively. The OpenCode server is the execution and persistence authority; the app is a remote control + chat surface.

## Sources of truth

Read these before changing mobile behavior or contracts:

1. `../opencode/AGENTS.md` for the server repository requirements when changing server sources.
2. `../opencode/specs/v2/server-api.md` — full V2 endpoint reference (61 endpoints, auth, SSE envelope).
3. `../opencode/packages/protocol/src/groups/*` — normative endpoint/query/success/error schemas.
4. `../opencode/packages/schema/src/*` — normative wire DTO shapes (`session.ts`, `session-message.ts`, `session-event.ts`, `agent.ts`, `model.ts`, `provider.ts`, `permission*.ts`, `question*.ts`, `location.ts`, `event.ts`, `event-manifest.ts`, `session-input.ts`, `prompt-input.ts`).
5. `../opencode/packages/server/src/auth.ts` + `../opencode/packages/server/src/middleware/authorization.ts` — credential scheme.
6. `../opencode/packages/sdk/js/src/v2/client.ts` — reference client showing auth-header + location-query patterns.

Never consult Aiden-remote-v1 documents, fixtures, or the old Electron-app plans; they are retired. Do not invent endpoints or JSON shapes in Swift — mirror `../opencode/packages/schema/src` exactly.

## Delivery rules

- Target **only** the OpenCode V2 API. Any endpoint not listed in `../opencode/specs/v2/server-api.md` must not be called.
- Keep the transport layer confined to `AidenForOpenCode/Networking/OpenCode/`. Views and view models must go through that client, never build URLs themselves.
- Decode additive response fields tolerantly, but fail closed when required identity/auth fields are missing or invalid.
- Credentials live in Keychain only. Never send or persist the password in URLs, logs, App Group data, App Intents, Live Activities, fixtures, or source control. The `?auth_token=` query form may only be used where headers cannot be set (WebSocket upgrade); never log it.
- Use terminal-based `xcodebuild`/`xcrun` verification for compile checks. `CODE_SIGNING_ALLOWED=NO` builds are valid compile evidence; on-device Keychain/entitlements validation is deferred to the owner.
- Prefer Apple frameworks and the dependencies already locked by the project (`KeychainAccess`, `MarkdownUI`). New third-party dependencies require explicit approval.

## Protocol and security rules

- **Auth**: HTTP Basic with username `opencode` and the server password (`opencode service password`, or `OPENCODE_SERVER_PASSWORD`). An unconfigured password means the server is open. Failed auth returns 401 with `WWW-Authenticate: Basic realm="Secure Area"`.
- **Pairing** has no server-side handshake in V2. The app pairs by obtaining `{endpoint, username?, password?}` via QR scan, pasted payload, or manual entry, then validating with a credentialed `GET /api/health` followed by an authenticated probe (`GET /api/location`) — V2 applies its authorization middleware to every group including health, so the probe must carry the candidate Basic credentials to distinguish "reachable + correct password" from 401. Only persist after both succeed. Payload kind: `aiden-opencode-pairing-v1`.
- **SSE envelope** for `/api/event` and `/api/session/:id/event`: `{"id","type","data","durable"?,"location"?,"metadata"?}`. Heartbeats are `:` comment frames every 15s; there is no `id:` SSE field and no Last-Event-ID resume. Reconnect = refetch REST state, replay durable events via `?after=<seq>`, then follow live.
- **Streaming text**: `session.next.text.delta` arrives only on the global stream; `text.started`/`text.ended` (durable) carry full text. Deltas are live-only and never replayed.
- **Approvals/questions**: `permission.v2.asked` / `question.v2.asked` events surface interactive cards; reply via the documented POST endpoints. Never widen permissions client-side; reply values are exactly what the schema allows.
- TCP/SSE loss never retries a prompt admission or abandons server-owned work. Reconcile by stable IDs and durable sequence numbers.
- Plain `http://<lan-host>:<port>` is the expected production transport for LAN use; do not require TLS, and do not implement SPKI pinning.

## Product boundaries

- Tabs map to V2 concepts: **Agents** (from `GET /api/agent`), **Sessions** (chat list), **Connect/Settings** (pairing + installation management). Retired Aiden concepts (bots, scheduled tasks, usage metering, git projections, Mac speech relay, bot access catalogs) are out of scope and must not be resurrected.
- Chat = Session. Sending = `POST /api/session/:id/prompt` (durable admission). Assistant output streams over SSE. Interrupt = `POST /api/session/:sessionID/interrupt`.
- Reuse the existing chat transcript/composer/approval UI paths; do not fork a second streaming implementation.
- iPhone navigation stacks; adaptive iPad `NavigationSplitView`; no custom UI system.
- App Intents are App-Group-cache-only navigation. Live Activities are bounded last-known state without cloud push.
- Approved Apple identity: team `5WP229CBB8`, main bundle `sbtbiswas.AidenForOpenCode`, widget `sbtbiswas.AidenForOpenCode.LiveActivityWidget`, app group `group.sbtbiswas.AidenForOpenCode`, keychain service `sbtbiswas.AidenForOpenCode.pairing`, URL scheme `aiden-opencode`. Project/target/scheme: `AidenForOpenCode`.

## Xcode project mechanics

- `project.pbxproj` uses classic groups with **explicit file references**. Adding/removing a Swift file requires updating the pbxproj (and the tests target list) — coordinate this centrally; when told to modify existing files, prefer in-place edits over creating new files.
- Deployment target iOS 18.0, Swift 5 mode, targets: app, Live Activity widget extension, unit-test bundle.
