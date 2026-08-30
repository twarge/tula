# Tula — a native, read-only ERPNext client

**Goal:** a macOS/iOS SwiftUI app that renders ERPNext's UI natively — starting with financial
reports (P&L) — without building a bespoke view per ERPNext feature, and without WebKit.

**Read-only guarantee:** the app cannot write to the server. This is enforced structurally
(see §6), not by convention.

---

## 1. Why a systematic mapping is possible

ERPNext is built on the Frappe framework, and Frappe's own web UI ("Desk") is **not**
hand-written per feature. It is a generic renderer driven by metadata:

- Every entity is a **DocType** (Account, GL Entry, Sales Invoice, …). A DocType's metadata —
  its fields, field types, labels, layout breaks, list-view columns, title field — is itself
  stored as documents and served over the API.
- Every screen in Desk is one of a small number of **view archetypes** (list, form, tree,
  report, workspace/dashboard) instantiated from that metadata.
- Every **report** returns a self-describing payload: typed column definitions plus rows.

So the correct native strategy is: **replicate the renderer, not the screens.** We fetch the
same metadata Desk fetches, and map each metadata concept to a SwiftUI component. New DocTypes,
custom fields, and new reports on the server then appear in the native app with zero app code.

```
                 ┌────────────────────────────────────────────────┐
                 │                ERPNext server                  │
                 │  DocType meta   Report defs   Documents  Rows  │
                 └───────┬───────────────┬──────────┬────────┬────┘
                         │  (read-only HTTPS, token auth)    │
                 ┌───────▼───────────────▼──────────▼────────▼────┐
   ERPNextKit    │ ReadOnlyClient → typed models → normalization  │
                 │ DocTypeMeta · LayoutTree · ReportResult · Doc  │
                 └───────┬────────────────────────────────────────┘
                         │
                 ┌───────▼────────────────────────────────────────┐
   Tula app      │ Archetype views (generic):                     │
                 │  ReportScreen · ListScreen · DocumentScreen    │
                 │  each composed from FieldValueView registry    │
                 └────────────────────────────────────────────────┘
```

---

## 2. The three metadata layers we consume

| Layer | Frappe source | API | What it drives |
|---|---|---|---|
| **Schema** | DocType + DocField | `GET /api/method/frappe.desk.form.load.getdoctype?doctype=X` (returns the DocType *and* all child-table DocTypes) | Field labels, types, layout, list columns, link targets |
| **Data** | Documents | `GET /api/resource/{DocType}` (list) and `GET /api/resource/{DocType}/{name}` (single) | List rows, form values, child tables |
| **Reports** | Report doctype + report runner | `GET /api/method/frappe.desk.query_report.run?report_name=X&filters={…}` | Columns + rows + summary + chart config for any Query/Script report (P&L, Balance Sheet, GL, …) |

All three are GET requests. That is the foundation of the read-only guarantee.

---

## 3. Field-level mapping: DocField → SwiftUI component

Frappe has ~40 field types. Each maps to a small renderer in a **field registry**
(`FieldValueView`), keyed by `fieldtype`. Unknown types fall back to plain text — the app
degrades gracefully instead of breaking on server customization.

| Frappe fieldtype | Read-only SwiftUI rendering |
|---|---|
| `Data`, `Small Text`, `Phone`, `Autocomplete`, `Read Only` | `Text` |
| `Int`, `Float` | `Text` with number `FormatStyle`, trailing-aligned |
| `Currency` | `Text` with `.currency` format; currency code resolved from the field's `options` (another field naming the currency) or company default; trailing-aligned, monospaced digits |
| `Percent` | `Text` with percent format |
| `Date`, `Datetime`, `Time` | `Text` with date `FormatStyle` (Frappe wire format: `yyyy-MM-dd[ HH:mm:ss]`) |
| `Duration` | `Text` via `Duration.UnitsFormatStyle` |
| `Check` | `Image(systemName: "checkmark")` / empty (never a `Toggle` — read-only) |
| `Select` | `Text`; status-like fields get a tinted capsule badge |
| `Link` | **`NavigationLink`** routing to `.document(doctype: options, name: value)` — this single rule makes the whole data graph navigable |
| `Dynamic Link` | Same, doctype resolved from the sibling field named in `options` |
| `Table`, `Table MultiSelect` | Nested child-table section rendered by the same list machinery, using the child DocType's meta |
| `Text`, `Long Text`, `Code`, `JSON`, `Markdown Editor` | Scrollable `Text` (monospaced for code/JSON) |
| `Text Editor`, `HTML Editor`, `HTML` | Own lightweight parsing — **not** `NSAttributedString(html:)`, which spins up WebKit. Fields carrying a server-rendered `<table>` (tax breakup et al) are parsed (`HTMLTable`) and rendered as a native grid; other content strips to text |
| `Attach`, `Attach Image`, `Image` | Filename + `AsyncImage` for images (GET of `/files/...`) |
| `Color` | Color swatch + hex |
| `Rating` | Star row |
| `Section Break`, `Column Break`, `Tab Break`, `Fold` | **Layout, not content** — consumed by the layout parser (§4) |
| `Heading` | Section header `Text` |
| `Button`, `Signature`, `Geolocation`, `Barcode`, unknown | Hidden or plain-text fallback (buttons are actions → never rendered in a read-only app) |

## 4. Layout: Frappe's flat field list → a SwiftUI layout tree

Frappe encodes form layout *inline* in the field sequence: `Tab Break`, `Section Break`, and
`Column Break` fields partition the flat list. Desk parses this into tabs → sections → columns;
we do exactly the same, once, in `LayoutTree`:

```
[fields…] ──parse──▶ Layout
                      ├─ Tab("Details")
                      │   ├─ Section(label:, collapsible:)
                      │   │   ├─ Column([field, field, …])
                      │   │   └─ Column([field, …])
                      │   └─ Section …
                      └─ Tab("Accounting") …
```

Rendering rules:

- **Tabs** → segmented `Picker` (compact) / native `TabView`-style switcher.
- **Sections** → grouped `Form` sections (`GroupBox` on macOS), honoring `collapsible`.
- **Columns** → `Grid`/`ViewThatFits`: side-by-side on regular width (macOS, iPad), stacked on
  compact width (iPhone). One layout parser, adaptive presentation.
- **Fields** → `LabeledContent(label) { FieldValueView }`.
- Fields with `hidden == 1`, permission-restricted (`permlevel`), or empty values follow Desk's
  visibility conventions. `depends_on` expressions (on fields, sections, and tabs) are
  evaluated exactly as Desk does — as JavaScript against the document — via **JavaScriptCore**
  (`DependsOnEvaluator`): expression evaluation only, no web content, so the no-WebKit (UI)
  constraint stands. Unevaluable expressions fail open (we show more, never less). ERPNext's
  company-currency convention is mirrored too: `base_*` twins hide when conversion rate is 1.

This is the piece that makes "convert the UI component-by-component" real: **any** DocType —
including ones with custom fields added by the customer — renders correctly because layout is
data, not code.

## 5. View archetypes: Desk view → native container

| Desk view | Route (mirrors Desk URLs) | Native container |
|---|---|---|
| Workspace (sidebar + shortcuts) | `/app/{workspace}` | `NavigationSplitView` sidebar; workspace links/shortcuts → rows |
| List view | `/app/{doctype-list}` | macOS: `Table`; iOS: `List`. Columns = Desk's saved **List View Settings** for the DocType when configured (read via its settings document), else meta fields with `in_list_view`; title from `title_field`, status badge from `indicator` conventions |
| Form view | `/app/{doctype}/{name}` | Generic `DocumentScreen` from `LayoutTree` (§4) |
| Tree view (Chart of Accounts) | `/app/account/view/tree` | `List` + `DisclosureGroup`, children lazy-loaded via `is_group`/`parent_account` filters |
| **Query/Script report** | `/app/query-report/{name}` | Generic `ReportScreen` (§7) — this is the P&L path |
| Dashboard / Number Card / Chart | `/app/{workspace}` cards | Swift Charts + stat tiles (Phase 3; chart configs are also API-served metadata) |
| Print view | — | Out of scope for v1 (print formats are HTML templates; later: native `ImageRenderer` → PDF from the same layout tree) |

Navigation is a single `Route` enum mirroring Desk's URL scheme. Because every `Link` field
renders as a `NavigationLink(Route.document(…))`, deep navigation (report row → GL entry →
voucher → party) works uniformly with no per-feature code.

## 6. Read-only enforcement (three independent layers)

1. **Type system (primary):** the only transport in `ERPNextKit` is `ReadOnlyClient`. It can
   *only* issue `GET`. There is no code path that builds a `POST`/`PUT`/`DELETE`; RPC calls are
   restricted to a compiled-in whitelist (`ReadMethod` enum) of known-safe read endpoints
   (`query_report.run`, `form.load.getdoctype`, …). Adding a write would require changing the
   kit's public API — it cannot happen by accident in a view.
2. **UI:** no edit affordances exist. Field renderers are display-only (`Check` is an image,
   not a toggle; `Button` fields are never rendered).
3. **Server (recommended, defense in depth):** connect with an API key for a dedicated
   ERPNext user holding only `read`/`report` permissions, so even a bug cannot write.

**The write gate (shipped 2026-08-30).** Writes exist behind a session-only gate, built
exactly as prescribed below: `WriteClient` is the only type able to issue a non-GET request,
it can only call the enumerated `WriteMethod` whitelist (add comment, add/remove assignment,
add/remove tag — Desk's collaboration operations), and it exists only while the user has
opened the toolbar lock (off by default, relocked on settings changes, unavailable in demo
mode). Comment attribution and self-assignment use the signed-in identity from
`frappe.auth.get_logged_user`. Document mutations (edit, submit, cancel, amend, delete,
rename, duplicate) remain out of scope and impossible by construction.

**For any further writes**: keep this structure — do not dilute `ReadOnlyClient`. Add a separate, explicitly-gated write client with its own
enumerated mutation whitelist (save/submit/cancel/amend), a distinct capability protocol
beside the read-only `DataSource`, and per-connection opt-in (ideally a separate
write-scoped API key). Writes stay server-authoritative — commands up, refetch truth down;
the cached `modified` timestamp doubles as Frappe's optimistic-concurrency token; editors
revalidate before opening and auto-refresh pauses during edits. Offline writes are ruled
out permanently: ERPNext's server-side compute (taxes, pricing, GL) makes client-side
merge infeasible, so offline remains read-only.

## 7. The report engine (P&L first)

`frappe.desk.query_report.run` returns a self-describing payload; one generic renderer covers
every financial statement:

```jsonc
{ "message": {
    "columns": [ {"fieldname":"account","label":"Account","fieldtype":"Data","width":300},
                 {"fieldname":"aug_2025","label":"Aug 2025","fieldtype":"Currency","options":"currency","width":150}, … ],
    "result":  [ {"account":"Income","indent":0,"has_value":true,"aug_2025":41200.0,"currency":"USD", …}, … ],
    "report_summary": [ {"label":"Net Profit","value":…,"indicator":"Green"}, … ],
    "chart": { … }
}}
```

Normalization handled by `ReportResult` decoding:

- Columns arrive as **dicts** (script reports) or legacy **`"Label:Fieldtype/Options:Width"`
  strings** (old query reports) → normalized to `ReportColumn`.
- Rows arrive as **dicts** or **positional arrays** → normalized to keyed rows.
- `indent` + `is_group`/`has_value` → hierarchical outline (P&L account tree) with
  indentation, bold group rows, and quoted `'Total …'` rows styled as totals.
- Column `fieldtype` reuses the §3 registry → currency columns are formatted/aligned exactly
  like currency fields everywhere else.
- `report_summary` → native stat tiles above the table; `chart` → Swift Charts (Phase 3).

**Filters.** Script-report filter *definitions* live in each report's client JS — the one
place ERPNext is not cleanly metadata-driven. Strategy:
- v1: native `FilterSet` definitions for the standard financial statements (company, fiscal
  year / date range, periodicity, cost center, accumulated) — they share one shape.
- v2: parse the `filters: [...]` array out of `query_report.get_script` (it's a JSON-ish
  literal) with a tolerant parser, falling back to v1 sets.

Reports run with `ignore_prepared_report=1`; prepared-report support (large installs) can be
added later via its read-only status/fetch endpoints.

## 8. ERPNextKit module layout

```
ERPNextKit/
  Client/    ServerConfiguration (URL + token auth), ReadOnlyClient (GET-only),
             Endpoint (typed paths), ReadMethod (RPC whitelist)
  Meta/      DocTypeMeta, DocField, FieldType, LayoutTree, MetaStore (actor, cached)
  Data/      FrappeValue (heterogeneous JSON), Document, ListPage
  Reports/   ReportColumn, ReportRow, ReportResult, ReportService,
             FinancialStatementFilters (P&L / BS / CF / TB / GL)
  Demo/      DemoDataSource — fixtures shaped exactly like server payloads, so the app
             runs (and previews render) with no server; also the test corpus
```

The app talks to a `DataSource` protocol with two implementations: `LiveDataSource`
(ReadOnlyClient) and `DemoDataSource`. Credentials (API key/secret) are entered by the user in
Settings and stored in the Keychain; nothing is ever sent anywhere but the configured server.

## 9. Data freshness

Three tiers, of which the first two are implemented:

1. **Manual refresh:** toolbar refresh button (⌘R) on every screen, pull-to-refresh on iOS,
   with an "Updated HH:MM" stamp in the toolbar. Refreshes are silent — current content stays
   on screen until the new result arrives.
2. **Smart polling (`AutoRefreshModifier`):** while a screen is visible, poll
   `DataSource.latestModified(doctype)` — a one-row `modified desc` GET — every 45s and once
   on return to foreground; reload only when the timestamp moves. Every financial statement
   derives from **GL Entry** postings, so that single DocType is the change signal for all of
   them (`ReportDescriptor.changeSignalDoctype`); list/document screens probe their own
   DocType. Cost when idle: one tiny GET per interval, zero re-renders. Stays entirely inside
   the GET-only client, works on any ERPNext version, and does nothing in demo mode (the
   probe returns nil).
3. **Push (future):** Frappe's Socket.IO realtime channel (`doctype_subscribe` →
   `list_update`) can feed the same invalidate-and-reload path for sub-second updates. Costs:
   a Socket.IO client dependency, session-cookie auth on the handshake (token-auth support
   varies by version), and a wider transport surface — if added, it must be isolated in a
   listener that can only emit whitelisted subscribe events.

## 10. List filtering (design)

Desk's list filters are not hand-built per DocType either — they are generated from the same
metadata Tula already fetches, so the native filter UI can be one generic component set.

**Wire model.** Every filter is a `[fieldname, operator, value]` tuple passed in the list
endpoint's `filters` GET parameter — the transport Tula already uses, so filtering adds zero
new API surface and cannot violate the read-only guarantee. Frappe's operator vocabulary:
`=`, `!=`, `like`, `not like`, `in`, `not in`, `>`, `<`, `>=`, `<=`, `between`,
`is` (set / not set), `timespan` (named ranges like "last month"), and `descendants of` /
`ancestors of` for tree DocTypes (Account). `or_filters` (same shape, OR-combined) is also
GET-able for later.

**Metadata hooks.** Three drive the whole UI:
- `DocField.in_standard_filter` — the fields Desk shows as its sidebar "Filter By" quick
  filters (Status, Customer, Company, …). Tula renders exactly these as the quick-filter row.
- `fieldtype` — selects both the legal operator set and the value editor.
- `meta.sort_field` / `sort_order` — default sort; any field is sortable via `order_by`.

**Operator sets by fieldtype** (mirroring Desk):

| Fieldtype | Operators | Native value editor |
|---|---|---|
| Data / Text | like, not like, =, !=, is | `TextField` |
| Link | =, !=, in, not in, like, is (+ descendants of on trees) | autocomplete via `frappe.desk.search.search_link` (new whitelisted `ReadMethod`) |
| Select | =, !=, in, not in, is | `Menu` of the field's options |
| Check | = | Yes / No menu |
| Int / Float / Currency / Percent | =, !=, >, <, >=, <=, between, is | numeric field(s) |
| Date / Datetime | =, >, <, >=, <=, between, timespan, is | `DatePicker`(s) or named-range menu |

**Native components** (all generic, all metadata-driven):
1. **Quick-filter row** — one control per `in_standard_filter` field, rendered as menu
   chips under the toolbar. ⚠ Must respect the beta-SDK landmine (§ memory): no `Text`
   siblings beside menu pickers in an HStack — chips are self-contained `Menu`s.
2. **Filter editor** — an "Add Filter" popover/sheet: field picker (all presentable fields
   plus standard fields `name`, `owner`, `creation`, `modified`, `workflow_state`) →
   operator picker (table above) → value editor. Active conditions render as removable
   chips. One component serves every DocType.
3. **Link autocomplete** — `search_link(doctype, txt)` returns value/description pairs;
   reused later for report filters (§7 v2) and the ⌘K omnibar.
4. **Sort menu** — toolbar menu over the list fields, feeding `order_by`; macOS `Table`
   header-click sorting can map to the same server-side sort later.
5. **Persistence** — last-used conditions per DocType in UserDefaults (same pattern as
   child-table column prefs). Desk's server-side saved filters (the `List Filter` DocType)
   are *readable* with normal perms, so they can be offered as read-only presets; creating
   them stays out of scope (write).

**Suggested order:** quick filters first (small, most of the daily value), then the generic
editor + Link autocomplete, then saved-filter presets / `or_filters` / tree operators.

## 11. Pagination & caching (design)

**Pagination.** Lists load pages of 50 via `limit_start`; a cell `.onAppear` in the trailing
rows triggers the next page (SwiftUI `Table` rows materialize lazily on macOS, `List` on iOS).
Guards: one in-flight load, `hasMore` = full page returned, reset on sort/filter/search
change. Auto-refresh re-requests the full currently-loaded count from offset 0 so the dataset
never collapses under the scroll position. Total via `frappe.client.get_count` → "50 of 1,234".

**Caching tiers** (read-only client → no write-back to reconcile; `modified` is a universal
invalidation signal; everything keyed by server+user and wiped on `sourceGeneration` bump):

1. **Meta — in-memory `MetaStore` actor, session-long.** DocType bundles are refetched per
   screen today; caching them removes most traffic. Disk persistence optional (cold start).
2. **Lists/documents — memory, stale-while-revalidate.** Keep the last `Loaded` per screen
   key; show instantly on return, refresh silently (machinery already exists). No disk.
3. **Report snapshots — disk.** Last result per (report, filters) with timestamp → instant
   open with the "Updated HH:MM" stamp, silent re-run; GL Entry probe signals staleness.
   This is the offline-viewing tier.
4. **Never cached:** autocomplete, counts, anything cross-identity. Credentials stay in the
   Keychain only.

## 12. Roadmap

**Shipped (Phases 1–2, Aug 2026):** read-only kit + report engine; generic report/list/form
renderers; the five financial statements; Desk-conformant forms (depends_on via
JavaScriptCore, card grouping, blank fields, base-currency twins, HTML→native tables, child
tables with Desk GridView columns, row-detail sheets); Desk-parity lists (title/status/ID/
modified recipe, saved List View Settings columns, saved sort + header/menu sorting, quick
filter chips incl. synthesized ID/Title, type-ahead link filters, detailed filter editor,
search, count, infinite scroll); auto-refresh probes; three-tier caching with offline report
snapshots; Open in Desk; demo mode; stable code signing.

### Phase 3 — the report long tail ✅ shipped Aug 2026

Today only the five standard statements run; ERPNext ships hundreds of reports (AR/AP aging,
stock, tax). All of them already work through the same `query_report.run` renderer — what's
missing is navigation and filters:

1. **Report browser** — list the `Report` DocType (readable) grouped by module in the
   sidebar; route every entry to the existing `ReportScreen`. (S)
2. **Report filter parsing** — fetch `query_report.get_script`, tolerantly parse the
   `filters: [...]` literal into native filter definitions (field/type/options/default/
   mandatory), rendered by the same field-registry controls as the list filter editor;
   fall back to the native financial-statement sets. (M)
3. **Drill-down** — report → report routes with carried filters (P&L/BS account row → GL
   for that account and period), Desk's core accountant workflow. (S–M)
4. **Report charts** — `query_report.run` already returns `chart` config; render with
   Swift Charts above the grid. (M)

### Phase 4 — navigation & document breadth ✅ shipped Aug 2026 (items 5–9; attachments preview and workspaces verified against live servers only)

5. **Workspaces as the sidebar** — read the `Workspace` DocType (links, shortcuts, cards)
   so the sidebar mirrors the server's own navigation; hardcoded Browse list becomes the
   fallback. Any module the server adds appears with zero app code. (M)
6. **⌘K omnibar** — `frappe.utils.global_search.search` → palette → existing Routes. (M)
7. **Tree views** — Chart of Accounts (plus Cost Center, Item Group, Warehouse) via
   `DisclosureGroup` outlines; `treeview.get_children` is already whitelisted. (M)
8. **Attachments** — authenticated image/PDF loading (token header ≠ `AsyncImage`),
   attachment list from the `File` DocType, Quick Look preview. High value for AP review
   of supplier-invoice attachments. (M)
9. **Form periphery** — docstatus badge (draft/submitted/cancelled, `amended_from` link);
   Connections tab counts → filtered-list routes; read-only comments/activity timeline
   (`_comment_count`, Comment/Version DocTypes); assignment/tag chips. (M–L)

### Phase 5 — dashboards, polish, distribution ✅ shipped Aug 2026

Shipped: workspace number cards + dashboard charts (Swift Charts), native PDF export,
precision-honoring formatting, between/timespan operators and server filter presets,
macOS Go menu (⌘1–5/⌘0/⌘K), manual refresh busts the meta cache, and CI imported from
calcium: a test+build workflow plus an App Store Connect upload pipeline (cloud signing,
version-train preflight) awaiting the five repository secrets. Deferred from this phase:
prepared-report polling and multiple server profiles.

10. **Dashboards** — Number Cards and Dashboard Charts via their whitelisted read methods
    + Swift Charts; workspace cards slot in from Phase 4. (L)
11. **PDF export** — `ImageRenderer` of the report grid → share/print; native re-render,
    not Desk print formats. (M)
12. **Formatting fidelity** — honor field `precision`, System Settings number/date formats,
    accounting-style negatives. (S)
13. **Filter completeness** — `between`/`timespan` operators, `or_filters`, read-only
    presets from the server's `List Filter` DocType. (S–M)
14. **Prepared reports** — poll/fetch results for reports the server queues in the
    background (read-only endpoints). Needed for very large GL ranges. (M)
15. **Platform** — macOS menu commands + keyboard shortcuts (⌘1–5 statements, ⌘K, ⌘F),
    multiple server profiles, connectivity indicator, Developer ID notarized Mac build and
    TestFlight for iOS (certs already present), CI running `swift test` + both builds. (M)

### The write map (design — everything needed to complete the interface)

All writes stay behind the shipped gate (§6): enumerated operations only, session-only
unlock, server-authoritative, no offline writes ever. Five waves, each keeping the app
consistent if work stops after it:

**W1 — Collaboration completion (S–M).** Rounds out what shipped:
share add/remove (`frappe.share.add/remove`), like toggle (`frappe.desk.like.toggle_like`),
follow (`document_follow`), assign to *others* (user picker over the existing `search_link`
on User; close/complete assignments), edit/delete own comments
(`update_comment` / delete Comment), attachment upload (multipart `upload_file` — the one
new transport shape `WriteClient` needs) and File delete, Remind Me (Reminder insert).

**W2 — Lifecycle without field editing (M).** Submit and Cancel
(`frappe.client.submit/cancel`) with hard confirmations; **workflow actions** — fully
metadata-driven from the readable Workflow DocType (states, transitions, allowed roles) →
native action buttons; Delete (`frappe.client.delete`, confirm-by-name for cancelled/draft
docs); Rename (`update_document_title`); Duplicate (fetch → strip system fields → 
`frappe.client.insert`). Requires a `WriteEndpoint` growth: enumerated REST verbs
(PUT/POST/DELETE `/api/resource`) beside the method whitelist.

**W3 — Field editing (L, the core).** Edit mode on drafts (+ `allow_on_submit` fields on
submitted docs); the field registry grows editable counterparts per fieldtype (TextField /
TextEditor / numeric with formatters / pickers / Toggle / Select Picker / Link type-ahead
reusing the filter-chip search / editable child-table rows via the row-detail sheet / file
picker for Attach; HTML fields edit as plain text in v1); enforcement becomes real:
`read_only`, `reqd`, `set_only_once`, permlevels, `read_only_depends_on` and
`mandatory_depends_on` through the existing JavaScriptCore evaluator; save via PUT with the
cached `modified` token (optimistic concurrency — TimestampMismatch → reload banner, draft
lost in v1); auto-refresh pauses during an edit session. **Server-computed fields rule:**
the client does only convention-safe math (amount = qty × rate); taxes, pricing rules, and
totals refresh from server truth on save, displayed as such.

**W4 — Creation (M, after W3).** New-document buttons on lists/workspaces; Quick Entry
sheets generated from the meta's quick-entry fields (Desk's own compact-create pattern);
full blank form from meta defaults; naming stays server-side. Amend lands here (create the
amended copy, open it as an editable draft).

**W5 — Settings & bulk (M).** Persist list columns/sort back to List View Settings and
user settings; save filter presets (List Filter insert); bulk list operations
(assign/tag/submit/delete over selections). Email stays a `mailto:` hand-off with a Desk
link — no server write needed — unless full Communication authoring is ever wanted (L).

**Cross-cutting requirements:** two-step confirmations for destructive/irreversible ops
(submit, cancel, delete) under the single session lock; permission-aware affordances
(meta `permissions` + user roles readable — hide what the server would refuse, but the
server stays the enforcer); every mutation follows the shipped pattern — inline error,
refresh document on success.

### Engineering debt

- Meta cache is session-long: manual refresh (⌘R) should also bust it.
- Re-test the two beta-SDK layout landmines (report-grid `.refreshable`; Text beside menu
  Pickers) when release SDKs ship; restore the iOS "Updated" stamp if fixed.
- UI smoke tests driving the TULA_ROUTE / TULA_AUTOOPEN_FILTER hooks.

### Explicitly deferred

Anything that writes (see §6 write-readiness notes); offline writes permanently; Desk print
formats and custom client scripts; WebKit-dependent rendering.
