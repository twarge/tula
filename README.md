# Tula

A native macOS/iOS SwiftUI client for ERPNext. **Strictly read-only** — the
HTTP layer can only issue GET requests to whitelisted read APIs, so the app
cannot modify server state by construction.

Instead of one hand-built screen per ERPNext feature, Tula replicates what
ERPNext's own web UI does: it renders generically from the server's metadata
(DocTypes, field types, layout breaks, report column definitions). Any
DocType, custom field, or financial report renders through the same handful
of generic SwiftUI views. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the full mapping.

## Layout

- `ERPNextKit/` — Swift package: read-only API client, metadata models,
  layout parser, report engine, demo fixtures. `swift test` runs its tests.
- `Tula/` — the multiplatform SwiftUI app (macOS 14.4+, iOS 17.4+).
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec.

## Building

```sh
xcodegen generate       # produces Tula.xcodeproj (regenerate after adding files)
open Tula.xcodeproj   # build & run the Tula scheme for My Mac or an iPhone
```

## Connecting

The app launches in **demo mode** (bundled sample data, no network). To
connect a real server: Settings (gear in the sidebar) → turn off demo mode →
enter the server URL plus an API key/secret (ERPNext: *User → Settings → API
Access*). Use a user that has only read/report permissions — the app never
writes, but a read-only key is good defense in depth. Credentials are stored
in the Keychain.
