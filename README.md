# Tula

A native macOS/iOS SwiftUI client for ERPNext. **Read-only by default** — the
reading transport can only issue GET requests to whitelisted read APIs.
Writing goes through a separate client that exists only while the toolbar
lock is open: off at launch, relocked when the connection settings change,
and unavailable in demo mode. Even then it can call only an enumerated list
of the Frappe methods Desk itself uses — comments, assignments, tags and the
rest of the collaboration surface; submit, cancel, workflow actions, rename,
duplicate and delete, each confirmed first; field editing; creating and
amending documents; and list settings and bulk actions. See §6 of
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the whole write surface.

Instead of one hand-built screen per ERPNext feature, Tula replicates what
ERPNext's own web UI does: it renders generically from the server's metadata
(DocTypes, field types, layout breaks, report column definitions). Any
DocType, custom field, or financial report renders through the same handful
of generic SwiftUI views. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the full mapping.

## Layout

- `ERPNextKit/` — Swift package: the GET-only read client and the gated write
  client, metadata models, layout parser, report engine, demo fixtures.
  `swift test` runs its tests.
- `Tula/` — the multiplatform SwiftUI app (macOS 14.4+, iOS 17.4+).
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec.

## Building

```sh
xcodegen generate       # produces Tula.xcodeproj (regenerate after adding files)
open Tula.xcodeproj   # build & run the Tula scheme for My Mac or an iPhone
```

## Connecting

The app launches in **demo mode** (bundled sample data, no network). To
connect a real server: Settings (gear in the sidebar, or ⌘, on the Mac) → turn
off demo mode → enter the server URL plus an API key/secret (ERPNext: *User →
Settings → API Access*). For defense in depth, use a user that has only
read/report permissions: the server then refuses any write, even with the
lock open. Credentials are stored in the Keychain.

## License

Copyright 2026 Twarge LLC. Licensed under the Apache License, Version 2.0;
see [LICENSE](LICENSE) or https://www.apache.org/licenses/LICENSE-2.0.
