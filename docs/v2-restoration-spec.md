# V2 Chrome Restoration Spec — "feels like Aiden on the Go"

Binding consolidation of the three triage reports (shell chrome, chat chrome, V2 data mapping). Implementation agents MUST match these names/signatures exactly. Full details live in the triage reports quoted in the dispatch prompts; this doc fixes decisions and seams.

## Locked IA

**Two tabs**: `Workspaces` (`folder.fill`, default) + `Settings` (`gearshape.fill`). iPhone tab bar; iPad keeps NavigationSplitView (sidebar 240/300/400 `.balanced`) listing the two areas.
- Workspaces home = OLD hero home restored: brand chip + search capsule header (68×68 collapsing to 0 while searching), quick-nav rows ("All Sessions" `bubble.left.and.bubble.right`, "Agents" `sparkles`), "Workspaces" section (directory cards), "Recent Chats" section (session rows), FAB (`square.and.pencil` 42×50, trailing 24 bottom 22) → zoom popover (`plus.bubble` Start here / `folder.badge.plus` Other Directory… / `sparkles` Choose Agent…).
- Agents grid becomes a pushed page from its quick-nav row (existing `AidenAgentsAreaView` reused).
- Offline banner (`wifi.slash` + Retry, `.regularMaterial`, safeAreaInset top) + "Connecting to OpenCode…" material overlay mounted at shell level.
- Per-installation nav persistence: `{selectedArea, selectedDirectory, compactDirectoryPath}`.

## Data mapping rules

- Workspace = distinct `SessionInfo.location.directory`; grouped client-side from recent sessions (initial window ≤200 via `allSessions`), directory detail fetches authoritatively via `SessionsQuery(directory:)`.
- Display titles: synthesized from first confirmed user row text (placeholder = empty / `"New session - …"` prefix); list falls back to `"Untitled session"`.
- Running badge: poll `activeSessions()` (≤5s while visible) → accent dot / `Label("Working", "waveform")`.
- Pending asks badge: `checkmark.shield` "Approval needed" when permissions/questions pending for that session.
- Leaf name: `lastPathComponent` of directory; fallback projectID prefix; fallback "Server Root".

## Transport additions (exact)

```swift
func activeSessions() async throws -> Set<String>            // GET /api/session/active {data:{id:{type}}}
func allSessions(query: SessionsQuery, limit: Int = 100, maxPages: Int = 10) async throws -> [SessionInfo]
// resend `limit` on EVERY cursor page (server cursors omit it)
enum FSKind: String, Codable, Sendable { case file, directory }
struct FSEntry: Codable, Equatable, Sendable { let path: String; let kind: FSKind /* key "type" */ } // dirs end "/"
func listDirectory(path: String?, scope: LocationScope?) async throws -> (location: LocationInfo, entries: [FSEntry])
func findEntries(query: String, type: FSKind?, limit: Int?, scope: LocationScope?) async throws -> [FSEntry] // order == rank
func readFile(path: String, scope: LocationScope?) async throws -> (data: Data, mime: String?) // path wildcard after /api/fs/read/, percent-encoded segments
```

## Chat sheet seam

`AidenNewSessionSheet` gains `directory`: `init(coordinator:agent:directory:onCreate:)` → passes into `createSession(directory:)`.

## Ownership (disjoint)

| Agent | Files |
|---|---|
| **S shell** | `Features/Remote/AidenProductShellView.swift` (in-place; grows glass modifiers, header, quick-nav, cards, FAB/popover, skeleton, banner, overlay, iPad split, persistence store) + extends `AidenForOpenCodeTests/AidenProductShellTests.swift` (grouping projection + nav reconciliation tests) |
| **C chat** | `Features/Remote/AidenChatFeature.swift` + `Features/Remote/AidenPairingView.swift` (in-place) |
| **T transport** | `Networking/OpenCode/OpenCodeClient.swift` + `OpenCodeModels.swift` + NEW test file `AidenForOpenCodeTests/OpenCodeV2AdditionsTests.swift` |

Integrator (parent): pbxproj entries for the new test file, cross-agent compile fixes, version/build, upload.

## Hard rules

- In-place edits preferred; any new file must be reported for pbxproj wiring.
- No resurrected v1 protocol code. Bots stay archived in `legacy/bots-v1/` (not compiled).
- Match OLD constants exactly where the triage specifies them (spacing 18/10, gutter 48, cornerRadius 24 composer / 14 cards / 18 bubbles, mic 44, capsules h34, shimmer 1.8s cycle, skeleton 1.6s sweep, smooth(0.24) search choreography).
- iOS 26 `glassEffect` branches guarded by `#available`, fallbacks per OLD modifiers.
- Never log credentials; no auth in URLs; fail-closed decoding.
