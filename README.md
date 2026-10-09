# Aiden for OpenCode

Aiden for OpenCode is the native SwiftUI iPhone/iPad companion for the **OpenCode V2 server** (`../opencode/packages/server` in the sibling OpenCode repository). The server owns execution, persistence, providers, and permissions; the app is an authenticated remote control + chat surface over your local network (or any reachable host).

## Sources of truth

- [`AGENTS.md`](AGENTS.md) — working agreement, protocol and security rules
- [`docs/v2-integration-contract.md`](docs/v2-integration-contract.md) — binding internal architecture contract
- [`../opencode/specs/v2/server-api.md`](../opencode/specs/v2/server-api.md) — full V2 endpoint reference
- `../opencode/packages/protocol/src/groups/*` and `../opencode/packages/schema/src/*` — normative wire shapes

## Building

Open `AidenForOpenCode.xcodeproj` and use the `AidenForOpenCode` scheme. Targets:

- `AidenForOpenCode` — main app (iOS 18+)
- `AidenForOpenCodeWidget` — Live Activity widget extension
- `AidenForOpenCodeTests` — unit tests

Compile check from the CLI:

```sh
cd aiden-for-opencode-ios
xcodebuild -project AidenForOpenCode.xcodeproj -scheme AidenForOpenCode \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

On-device Keychain/Live Activity validation is deferred to the owner; the owner signing team is configured via automatic signing. Contributors can override the team and identifiers in gitignored `Config/Local.xcconfig`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Connecting to a server

1. Start the OpenCode server reachable from your device: `opencode serve --hostname 0.0.0.0 --port 4096`.
2. Get the password: `opencode service password` (or set `OPENCODE_SERVER_PASSWORD`; unset means the server accepts unauthenticated clients).
3. In the app: **Connect** → paste the endpoint (`http://<lan-ip>:4096`) and password, or scan/paste a QR payload of the form:

```json
{"kind":"aiden-opencode-pairing-v1","endpoint":"http://192.168.1.10:4096","username":"opencode","password":"..."}
```

The app validates with a credentialed `GET /api/health` plus an authenticated `GET /api/location` probe before storing credentials in Keychain (V2 protects every route, health included).

Aiden for OpenCode talks **only** to the OpenCode V2 HTTP API.
