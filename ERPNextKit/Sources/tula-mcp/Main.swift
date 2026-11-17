import ERPNextKit
import Foundation
import TulaMCPCore

let version = "0.1.0"

/// stdout belongs to the protocol; everything a person should read goes here.
func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

@main
enum TulaMCP {
    static let usage = """
        tula-mcp \(version) — a read-only MCP server for an ERPNext site.

        Usage:
          tula-mcp            Serve MCP over stdio (what an MCP client launches).
          tula-mcp --demo     Serve Tula's bundled demo data; no server, no credentials.
          tula-mcp login      Ask for the server URL, API key and secret, check them,
                              and save them in the login Keychain.
          tula-mcp logout     Remove the saved connection.
          tula-mcp check      Connect and say who the server thinks you are.

        The connection comes from \(Connection.urlVariable), \(Connection.keyVariable) and \(Connection.secretVariable)
        when all three are set, otherwise from the Keychain. See docs/MCP.md.
        """

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments.first {
            case nil:
                let configuration = try Connection.resolve()
                if Connection.sendsSecretInTheClear(configuration) {
                    note("tula-mcp: warning: \(configuration.baseURL) is plain http; the API secret is sent unencrypted.")
                }
                await serve(LiveDataSource(client: ReadOnlyClient(configuration: configuration)))
            case "--demo":
                await serve(DemoDataSource())
            case "login":
                try await login()
            case "logout":
                print(Keychain.delete() ? "Removed the saved connection." : "No saved connection.")
            case "check":
                try await check(Connection.resolve())
            case "--version", "-v":
                print(version)
            case "--help", "-h", "help":
                print(usage)
            default:
                note(usage)
                exit(64)
            }
        } catch {
            note("tula-mcp: \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: Serving

    /// Newline-delimited JSON-RPC on stdin and stdout until stdin closes.
    /// Calls run concurrently — a slow report doesn't hold up a lookup —
    /// and replies go out whole, one per line, in the order they finish.
    static func serve(_ source: any DataSource) async {
        let server = MCPServer(source: source, version: version)
        let output = Output()
        note("tula-mcp: serving \(source.displayName) (read-only)")
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    guard !line.allSatisfy(\.isWhitespace) else { continue }
                    group.addTask {
                        if let reply = await server.handle(line: line) {
                            await output.write(reply)
                        }
                    }
                }
            } catch {
                note("tula-mcp: reading stdin failed: \(error.localizedDescription)")
            }
        }
    }

    actor Output {
        func write(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

    // MARK: Setup commands

    static func login() async throws {
        let existing = Keychain.load()
        let url = prompt("ERPNext server URL", default: existing?.url)
        let apiKey = prompt("API key", default: existing?.apiKey)
        let apiSecret = prompt("API secret", secret: true)
        let configuration = try Connection.configuration(url: url, apiKey: apiKey, apiSecret: apiSecret)
        if Connection.sendsSecretInTheClear(configuration) {
            note("Warning: plain http sends the API secret unencrypted. Use https if the server offers it.")
        }
        try await check(configuration)
        try Keychain.save(
            Connection.Stored(
                url: configuration.baseURL.absoluteString, apiKey: apiKey, apiSecret: apiSecret))
        print("Saved to the login Keychain. MCP clients can now launch tula-mcp with no arguments.")
    }

    static func check(_ configuration: ServerConfiguration) async throws {
        let source = LiveDataSource(client: ReadOnlyClient(configuration: configuration))
        try await source.ping()
        // ping answers anyone; this is the call that proves the key.
        guard let user = try await source.loggedUser(), user != "Guest" else {
            throw ERPNextError(message: "\(source.displayName) answered, but didn't accept the API key and secret.")
        }
        print("Connected to \(source.displayName) as \(user).")
    }

    static func prompt(_ label: String, default fallback: String? = nil, secret: Bool = false) -> String {
        let suffix = fallback.map { " [\($0)]" } ?? ""
        let answer: String
        if secret, isatty(STDIN_FILENO) != 0, let typed = getpass("\(label): ") {
            answer = String(cString: typed)
        } else {
            FileHandle.standardError.write(Data("\(label)\(suffix): ".utf8))
            answer = readLine() ?? ""
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (fallback ?? "") : trimmed
    }
}
