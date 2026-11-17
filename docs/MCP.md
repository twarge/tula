# tula-mcp — ERPNext for Claude, read-only

`tula-mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server that
lets Claude (or any MCP client) query an ERPNext site. It is built on ERPNextKit's
`ReadOnlyClient`, the same transport the app reads through, so the guarantee of
[ARCHITECTURE.md §6](ARCHITECTURE.md) carries over unchanged: it can issue only `GET`
requests to the enumerated read endpoints. Nothing in it ever constructs a `WriteClient`.

## Build

```sh
swift build -c release --package-path ERPNextKit --product tula-mcp
cp ERPNextKit/.build/release/tula-mcp ~/.local/bin/    # or anywhere on your PATH
```

macOS only (it uses the Keychain and JavaScriptCore). No dependencies beyond ERPNextKit.

## Connect

Create an API key and secret in ERPNext (*User → Settings → API Access*). Use a user
that has only read and report permissions on what Claude should see: the server enforces
that user's permissions on every call, which is the one boundary that doesn't depend on
this code.

```sh
tula-mcp login     # asks for the URL, key and secret; checks them; saves to the Keychain
tula-mcp check     # "Connected to erp.example.com as reader@example.com."
tula-mcp logout    # removes the saved connection
```

The Tula app's saved credentials can't be shared: the app is sandboxed, and its Keychain
items are out of a command-line tool's reach. Rebuilding the binary changes its signature,
so macOS asks once more before letting the new build read the saved connection.

Alternatively set `ERPNEXT_URL`, `ERPNEXT_API_KEY` and `ERPNEXT_API_SECRET`; when all
three are present they win over the Keychain. Prefer the Keychain on a personal machine —
environment variables end up in client config files in plain text.

## Add it to Claude

Claude Code:

```sh
claude mcp add tula -- ~/.local/bin/tula-mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "tula": { "command": "/Users/you/.local/bin/tula-mcp" }
  }
}
```

To try it with no server, pass `--demo`: it serves the app's bundled demo company.

## Tools

| Tool | What it answers |
| --- | --- |
| `get_site_info` | Site, API user, companies and currencies, fiscal years, today's date |
| `search_doctypes` | What a kind of record is called here, custom DocTypes included |
| `get_doctype_schema` | A DocType's fields, link targets, select choices, child tables |
| `list_documents` | Documents of a DocType: filtered, sorted, paged |
| `count_documents` | How many match |
| `get_document` | One document in full, with its child tables |
| `search` | Desk's global search, across DocTypes |
| `find_documents` | A fragment of a name → the exact document name (Desk's link search) |
| `list_reports` | The site's query and script reports |
| `get_report_filters` | What a report needs before it will run |
| `run_report` | A report's table, summary and message, paged |

Every tool is annotated `readOnlyHint`. Results are compact JSON: nulls and empty strings
are dropped from documents, report rows are positional against `columns`, and anything
over 400 KB is refused with a hint to narrow the request rather than flooding the model's
context.

## Layout

```
ERPNextKit/Sources/
  TulaMCPCore/   MCPServer (JSON-RPC, one line in → one line out; no I/O),
                 Tools (the eleven tools over `any DataSource`), Arguments
  tula-mcp/      Main (stdio loop, login/check/logout), Connection (env + Keychain)
ERPNextKit/Tests/TulaMCPCoreTests/   the server end to end over DemoDataSource
```

A new tool is one `Tool` value in `Tools.swift`, added to `Tool.all`. It receives a
`DataSource` and nothing else, so it can do only what the app's read path can; a tool that
needs a new server endpoint needs a new `ReadMethod` case first, reviewed as §6 describes.
