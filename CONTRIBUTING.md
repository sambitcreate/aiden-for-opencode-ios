# Contributing to Aiden for OpenCode

Follow [AGENTS.md](AGENTS.md) and the OpenCode V2 contracts. Preserve the MIT license and bundled third-party notices. Every behavior change needs focused XCTest coverage and physical-device verification proportional to risk.

## Code signing for contributors

The shared configuration keeps the owner’s approved Apple team and `sbtbiswas.AidenForOpenCode` identity. Other contributors should create the gitignored `Config/Local.xcconfig` with your own Apple team and unique identifiers:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
APP_BUNDLE_IDENTIFIER = com.example.yourapp
APP_GROUP_IDENTIFIER = group.com.example.yourapp
KEYCHAIN_SERVICE = com.example.yourapp.pairing
```

Use matching App Group entitlements and select your own team when exporting an archive. Never commit signing overrides, export credentials, provisioning profiles, or certificates.

Do not add a third-party dependency or a new remote endpoint without explicit approval and corresponding contract coverage. Never use a simulator as a substitute for signed Keychain or Local Network verification.
