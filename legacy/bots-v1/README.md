# Legacy archive — Aiden on the Go v1 sources (NOT compiled)

These files are the retired Aiden-remote-v1 client code, preserved verbatim for
future reference. They are **not referenced by any Xcode target** and will not
compile against the current app (their transport layer — `AidenRemoteClient`,
`AidenRemoteContract`, `AidenServerTrust` — was replaced by
`AidenForOpenCode/Networking/OpenCode/`).

Per owner decision (2026-08-24): bots stay **disabled** in the product. When
OpenCode V2 grows an equivalent surface (or a bot service ships server-side),
revive from here behind a feature flag and re-add to `project.pbxproj`.

Contents:
- `Features-Bots/` — Bots home/editor/profile/avatar/access flows
- `Models/` — AidenBot, AidenScheduledTask, AidenWorkspaceEnvironment
- `Persistence/` — bot cache, chat cache, draft stores
- `Networking/` — the retired v1 transport (client, contract, SPKI trust)
