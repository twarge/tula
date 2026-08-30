import Foundation

/// Mutations the write gate can perform — the complete list. Mirrors the
/// `ReadMethod` whitelist on the read side (ARCHITECTURE.md §6): arbitrary
/// writes are not expressible, only these enumerated collaboration
/// operations, each a standard whitelisted Desk method.
public enum WriteMethod: String, Sendable, CaseIterable {
    case addComment = "frappe.desk.form.utils.add_comment"
    case updateComment = "frappe.desk.form.utils.update_comment"
    case addAssignment = "frappe.desk.form.assign_to.add"
    case removeAssignment = "frappe.desk.form.assign_to.remove"
    case addTag = "frappe.desk.doctype.tag.tag.add_tag"
    case removeTag = "frappe.desk.doctype.tag.tag.remove_tag"
    case toggleLike = "frappe.desk.like.toggle_like"
    case addShare = "frappe.share.add"
    case removeShare = "frappe.share.remove"
    case followDocument = "frappe.desk.form.document_follow.follow_document"
    case unfollowDocument = "frappe.desk.form.document_follow.unfollow_document"
    case createReminder = "frappe.automation.doctype.reminder.reminder.create_new_reminder"
    /// Generic doc delete — reachable only through `WriteSession`'s typed
    /// operations, which pin the doctype (Comment, File).
    case deleteDocument = "frappe.client.delete"
    case uploadFile = "upload_file"
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
    func call(_ method: WriteMethod, parameters: [String: String]) async throws -> Data {
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

    /// Multipart upload for `upload_file` — the one write that carries a
    /// body beyond form fields. Still an enumerated operation.
    func upload(
        fileName: String, data fileData: Data, doctype: String, docname: String,
        isPrivate: Bool
    ) async throws -> Data {
        guard var components = URLComponents(
            url: configuration.baseURL, resolvingAgainstBaseURL: false)
        else {
            throw ERPNextError(message: "Invalid server URL")
        }
        components.path =
            components.path.trimmingSuffix("/") + "/api/method/\(WriteMethod.uploadFile.rawValue)"
        guard let url = components.url else {
            throw ERPNextError(message: "Could not build request URL")
        }

        let boundary = "tula-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary, fileName: fileName, fileData: fileData,
            fields: [
                "doctype": doctype,
                "docname": docname,
                "is_private": isPrivate ? "1" : "0",
            ])
        request.timeoutInterval = 120

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

    static func multipartBody(
        boundary: String, fileName: String, fileData: Data, fields: [String: String]
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
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

    public func updateComment(name: String, content: String) async throws {
        try await client.call(
            .updateComment, parameters: ["name": name, "content": content])
    }

    public func deleteComment(name: String) async throws {
        try await client.call(
            .deleteDocument, parameters: ["doctype": "Comment", "name": name])
    }

    public func deleteAttachment(fileDocName: String) async throws {
        try await client.call(
            .deleteDocument, parameters: ["doctype": "File", "name": fileDocName])
    }

    public func uploadAttachment(
        fileName: String, data: Data, doctype: String, name: String, isPrivate: Bool = true
    ) async throws {
        _ = try await client.upload(
            fileName: fileName, data: data, doctype: doctype, docname: name,
            isPrivate: isPrivate)
    }

    public func toggleLike(doctype: String, name: String, liked: Bool) async throws {
        try await client.call(
            .toggleLike,
            parameters: ["doctype": doctype, "name": name, "add": liked ? "Yes" : "No"])
    }

    public func addShare(doctype: String, name: String, user shareWith: String) async throws {
        try await client.call(
            .addShare,
            parameters: [
                "doctype": doctype, "name": name, "user": shareWith,
                "read": "1", "write": "0", "share": "0", "notify": "1",
            ])
    }

    public func removeShare(doctype: String, name: String, user shared: String) async throws {
        try await client.call(
            .removeShare,
            parameters: ["doctype": doctype, "name": name, "user": shared])
    }

    public func setFollowing(doctype: String, name: String, following: Bool) async throws {
        try await client.call(
            following ? .followDocument : .unfollowDocument,
            parameters: ["doctype": doctype, "doc_name": name, "user": user])
    }

    public func createReminder(
        remindAt: String, description: String, doctype: String, name: String
    ) async throws {
        try await client.call(
            .createReminder,
            parameters: [
                "remind_at": remindAt,
                "description": description,
                "reminder_doctype": doctype,
                "reminder_docname": name,
            ])
    }

    public func assign(doctype: String, name: String, users: [String]) async throws {
        let list = try FrappeValue.array(users.map { .string($0) }).encodedJSONString()
        try await client.call(
            .addAssignment,
            parameters: ["doctype": doctype, "name": name, "assign_to": list])
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
        try await assign(doctype: doctype, name: name, users: [user])
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
