# Security

Report security issues privately through this repository's GitHub security-advisory flow. Do not include device credentials, provider keys, pairing payloads, prompts, filesystem paths, or private logs in public issues.

This app connects to an OpenCode V2 server. Server passwords stay in Keychain and must never appear in URLs, logs, App Group caches, or Live Activities. Consult [AGENTS.md](AGENTS.md) and [the integration contract](docs/v2-integration-contract.md) for authentication and transport requirements.
