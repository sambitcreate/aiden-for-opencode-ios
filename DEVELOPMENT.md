# iOS development

Requirements: current Xcode, iOS 18 or newer, and access to this repository's configured Apple development team for signed hardware runs.

Build and test the `AidenForOpenCode` scheme from `AidenForOpenCode.xcodeproj`. Compile verification uses terminal-based `xcodebuild` (see the README). Do not place credentials, pairing payloads, LAN addresses, or generated test-run files in source control.

The mobile client implements **only** the OpenCode V2 HTTP API (`../opencode/specs/v2/server-api.md`). When a wire shape changes, update the Swift DTOs in `AidenForOpenCode/Networking/OpenCode/` together with the schema packages — never invent shapes client-side.

See [`AGENTS.md`](AGENTS.md) for the working agreement, protocol rules, and product boundaries.
