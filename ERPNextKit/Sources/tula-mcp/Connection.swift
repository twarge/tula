import ERPNextKit
import Foundation
import Security

/// Where the server finds its ERPNext site: the environment first, then the
/// login Keychain (`tula-mcp login`).
///
/// The Tula app's own Keychain entry isn't used: the app is sandboxed, so
/// its items live in its own access group, out of a command-line tool's
/// reach. Use the same API key and secret here, or better a separate pair
/// for a user with only read and report permissions.
enum Connection {
    static let urlVariable = "ERPNEXT_URL"
    static let keyVariable = "ERPNEXT_API_KEY"
    static let secretVariable = "ERPNEXT_API_SECRET"

    struct Stored: Codable {
        var url: String
        var apiKey: String
        var apiSecret: String
    }

    struct Missing: Error, LocalizedError {
        var errorDescription: String? {
            """
            No ERPNext connection is configured. Either run `tula-mcp login`, or set \
            \(Connection.urlVariable), \(Connection.keyVariable) and \(Connection.secretVariable).
            """
        }
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> ServerConfiguration {
        let fromEnvironment = [urlVariable, keyVariable, secretVariable].map {
            environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if fromEnvironment.allSatisfy({ !$0.isEmpty }) {
            return try configuration(
                url: fromEnvironment[0], apiKey: fromEnvironment[1], apiSecret: fromEnvironment[2])
        }
        if fromEnvironment.contains(where: { !$0.isEmpty }) {
            throw ERPNextError(
                message: "Set all three of \(urlVariable), \(keyVariable) and \(secretVariable), or none.")
        }
        guard let stored = Keychain.load() else { throw Missing() }
        return try configuration(url: stored.url, apiKey: stored.apiKey, apiSecret: stored.apiSecret)
    }

    static func configuration(url: String, apiKey: String, apiSecret: String) throws
        -> ServerConfiguration {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(),
            ["http", "https"].contains(scheme), let host = parsed.host(), !host.isEmpty
        else {
            throw ERPNextError(message: "\"\(url)\" isn't a server URL (expected https://erp.example.com).")
        }
        guard parsed.user == nil, parsed.password == nil else {
            throw ERPNextError(message: "The server URL must not carry credentials.")
        }
        return ServerConfiguration(baseURL: parsed, apiKey: apiKey, apiSecret: apiSecret)
    }

    /// The API secret travels in a header on every request.
    static func sendsSecretInTheClear(_ configuration: ServerConfiguration) -> Bool {
        guard configuration.baseURL.scheme?.lowercased() == "http" else { return false }
        let host = configuration.baseURL.host() ?? ""
        return !["localhost", "127.0.0.1", "::1"].contains(host) && !host.hasSuffix(".localhost")
    }
}

/// One generic-password item in the login Keychain holding the whole
/// connection, so reading it asks the user at most once.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.twarge.tula-mcp",
        kSecAttrAccount as String: "connection",
    ]

    static func load() -> Connection.Stored? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Connection.Stored.self, from: data)
    }

    static func save(_ connection: Connection.Stored) throws {
        let data = try JSONEncoder().encode(connection)
        var status = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Tula MCP (ERPNext connection)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw ERPNextError(message: "Couldn't save to the Keychain: \(reason)")
        }
    }

    @discardableResult
    static func delete() -> Bool {
        SecItemDelete(base as CFDictionary) == errSecSuccess
    }
}
