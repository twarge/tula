import Foundation

/// Mutations the write gate can perform — the complete list. Mirrors the
/// `ReadMethod` whitelist on the read side (ARCHITECTURE.md §6): arbitrary
/// writes are not expressible, only these enumerated collaboration
/// operations, each a standard whitelisted Desk method.
public enum WriteMethod: String, Sendable, CaseIterable {
    case addComment = "frappe.desk.form.utils.add_comment"
    case addAssignment = "frappe.desk.form.assign_to.add"
    case removeAssignment = "frappe.desk.form.assign_to.remove"
    case addTag = "frappe.desk.doctype.tag.tag.add_tag"
    case removeTag = "frappe.desk.doctype.tag.tag.remove_tag"
}

/// The only type in the kit able to issue a non-GET request. Deliberately
/// separate from `ReadOnlyClient` — read paths cannot reach it, it exists
/// only while the user has unlocked writes, and it can only call the
/// `WriteMethod` whitelist above.
public final class WriteClient: Sendable {
    public let configuration: ServerConfiguration
    private let session: URLSession

    public init(configuration: ServerConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    @discardableResult
    public func call(_ method: WriteMethod, parameters: [String: String]) async throws -> Data {
        guard var components = URLComponents(
            url: configuration.baseURL, resolvingAgainstBaseURL: false)
        else {
            throw ERPNextError(message: "Invalid server URL")
        }
        components.path = components.path.trimmingSuffix("/") + "/api/method/\(method.rawValue)"
        guard let url = components.url else {
            throw ERPNextError(message: "Could not build request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(parameters)
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ERPNextError(message: "Unexpected response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ERPNextError(
                message: ReadOnlyClient.serverMessage(from: data, statusCode: http.statusCode),
                statusCode: http.statusCode)
        }
        return data
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ parameters: [String: String]) -> Data {
        let body = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

/// The unlocked write surface: enumerated, typed operations only. Created by
/// the app when the user opens the lock; discarded on relock.
public struct WriteSession: Sendable {
    public let client: WriteClient
    /// The signed-in user (from `frappe.auth.get_logged_user`), used for
    /// comment attribution and self-assignment.
    public let user: String

    public init(client: WriteClient, user: String) {
        self.client = client
        self.user = user
    }

    public func addComment(doctype: String, name: String, content: String) async throws {
        try await client.call(
            .addComment,
            parameters: [
                "reference_doctype": doctype,
                "reference_name": name,
                "content": content,
                "comment_email": user,
                "comment_by": user,
            ])
    }

    public func assignToMe(doctype: String, name: String) async throws {
        let list = try FrappeValue.array([.string(user)]).encodedJSONString()
        try await client.call(
            .addAssignment,
            parameters: ["doctype": doctype, "name": name, "assign_to": list])
    }

    public func removeAssignment(doctype: String, name: String, user assignee: String)
        async throws {
        try await client.call(
            .removeAssignment,
            parameters: ["doctype": doctype, "name": name, "assign_to": assignee])
    }

    public func addTag(_ tag: String, doctype: String, name: String) async throws {
        try await client.call(
            .addTag, parameters: ["tag": tag, "dt": doctype, "dn": name])
    }

    public func removeTag(_ tag: String, doctype: String, name: String) async throws {
        try await client.call(
            .removeTag, parameters: ["tag": tag, "dt": doctype, "dn": name])
    }
}
