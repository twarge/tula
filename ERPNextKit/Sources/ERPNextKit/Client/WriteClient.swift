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
    /// Doc delete: pinned to Comment/File by the collaboration operations,
    /// or any doctype via the confirmed lifecycle delete.
    case deleteDocument = "frappe.client.delete"
    case uploadFile = "upload_file"
    // W2 — document lifecycle (ARCHITECTURE §12 write map).
    case submitDocument = "frappe.client.submit"
    case cancelDocument = "frappe.client.cancel"
    case insertDocument = "frappe.client.insert"
    case renameDocument = "frappe.model.rename_doc.update_document_title"
    case applyWorkflow = "frappe.model.workflow.apply_workflow"
    /// Desk's form save (W3): full document JSON + action Save/Update. The
    /// document's `modified` timestamp doubles as the optimistic lock — a
    /// stale draft raises TimestampMismatchError instead of overwriting.
    case saveDocument = "frappe.desk.form.save.savedocs"
    // W5 — settings & bulk (ARCHITECTURE §12 write map).
    /// Per-user Desk view settings (list sort, grid columns) for a DocType.
    case saveUserSettings = "frappe.model.utils.user_settings.save"
    /// Desk's list-column settings (the List View Settings document).
    case saveListViewSettings = "frappe.desk.doctype.list_view_settings.list_view_settings.save_listview_settings"
    case bulkDelete = "frappe.desk.reportview.delete_items"
    case bulkSubmitCancel = "frappe.desk.doctype.bulk_update.bulk_update.submit_cancel_or_update_docs"
    case bulkAssign = "frappe.desk.form.assign_to.add_multiple"
    case bulkTag = "frappe.desk.doctype.tag.tag.add_tags"
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
                statusCode: http.statusCode,
                excType: (try? FrappeValue.decode(from: data))?
                    .objectValue?["exc_type"]?.nonEmptyString)
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


// MARK: - W2 lifecycle operations

extension WriteSession {
    /// Submit a draft. The full document (including its `modified` token,
    /// Frappe's optimistic lock) is posted back.
    public func submit(documentRaw: [String: FrappeValue]) async throws {
        let json = try FrappeValue.object(documentRaw).encodedJSONString()
        try await client.call(.submitDocument, parameters: ["doc": json])
    }

    public func cancel(doctype: String, name: String) async throws {
        try await client.call(
            .cancelDocument, parameters: ["doctype": doctype, "name": name])
    }

    /// Lifecycle delete of a whole document — always behind an explicit
    /// confirmation in the UI.
    public func deleteDocument(doctype: String, name: String) async throws {
        try await client.call(
            .deleteDocument, parameters: ["doctype": doctype, "name": name])
    }

    /// Rename; returns the new name the server settled on.
    public func rename(doctype: String, name: String, to newName: String) async throws
        -> String {
        let data = try await client.call(
            .renameDocument,
            parameters: [
                "doctype": doctype, "docname": name, "name": newName, "merge": "0",
            ])
        return try FrappeValue.decode(from: data).objectValue?["message"]?.nonEmptyString
            ?? newName
    }

    /// Create a document (W4). Naming stays server-side (`__newname` carries
    /// a user-supplied ID for prompt-named DocTypes); returns the assigned
    /// name.
    public func insert(documentRaw: [String: FrappeValue]) async throws -> String {
        let json = try FrappeValue.object(documentRaw).encodedJSONString()
        let data = try await client.call(.insertDocument, parameters: ["doc": json])
        guard
            let name = try FrappeValue.decode(from: data).objectValue?["message"]?
                .objectValue?["name"]?.nonEmptyString
        else {
            throw ERPNextError(message: "The server did not return the new document's name.")
        }
        return name
    }

    /// Duplicate: insert a copy with system fields stripped; returns the new
    /// document's name.
    public func duplicate(documentRaw: [String: FrappeValue], doctype: String) async throws
        -> String {
        try await insert(documentRaw: Self.duplicableRaw(documentRaw, doctype: doctype))
    }

    /// A draft copy suitable for creation flows: system fields stripped;
    /// with `amendedFrom`, the amend seed (Desk's amended-copy pattern).
    public static func draftCopy(
        of raw: [String: FrappeValue], doctype: String, amendedFrom: String? = nil
    ) -> [String: FrappeValue] {
        var copy = duplicableRaw(raw, doctype: doctype)
        if let amendedFrom {
            copy["amended_from"] = .string(amendedFrom)
        }
        return copy
    }

    /// Apply a workflow transition (Approve, Reject, …) to the document.
    public func applyWorkflow(documentRaw: [String: FrappeValue], action: String) async throws {
        let json = try FrappeValue.object(documentRaw).encodedJSONString()
        try await client.call(
            .applyWorkflow, parameters: ["doc": json, "action": action])
    }

    /// Copy of a document suitable for insertion: identity, audit, docstatus,
    /// and collaboration fields removed, top-level and per child row.
    static func duplicableRaw(
        _ raw: [String: FrappeValue], doctype: String
    ) -> [String: FrappeValue] {
        let topStrip: Set<String> = [
            "name", "owner", "creation", "modified", "modified_by", "docstatus",
            "idx", "amended_from", "_assign", "_comments", "_user_tags",
            "_liked_by", "_seen",
        ]
        let childStrip: Set<String> = [
            "name", "parent", "owner", "creation", "modified", "modified_by",
            "docstatus", "idx",
        ]
        var copy: [String: FrappeValue] = [:]
        for (key, value) in raw where !topStrip.contains(key) {
            if let rows = value.arrayValue,
                rows.allSatisfy({ $0.objectValue != nil }), !rows.isEmpty {
                copy[key] = .array(
                    rows.map { row in
                        .object(
                            row.objectValue!.filter { !childStrip.contains($0.key) })
                    })
            } else {
                copy[key] = value
            }
        }
        copy["doctype"] = .string(doctype)
        return copy
    }
}


// MARK: - W3 field editing

extension WriteSession {
    /// Save an edited draft. `submitted` selects Desk's "Update" action,
    /// which restricts the save to `allow_on_submit` fields server-side.
    public func save(documentRaw: [String: FrappeValue], submitted: Bool) async throws {
        let json = try FrappeValue.object(documentRaw).encodedJSONString()
        try await client.call(
            .saveDocument,
            parameters: ["doc": json, "action": submitted ? "Update" : "Save"])
    }

    /// Upload a file for an Attach field: stores it, attaches it to the
    /// document, and returns the `file_url` to put in the field.
    public func uploadForField(
        fileName: String, data: Data, doctype: String, name: String,
        isPrivate: Bool = true
    ) async throws -> String {
        let response = try await client.upload(
            fileName: fileName, data: data, doctype: doctype, docname: name,
            isPrivate: isPrivate)
        guard
            let url = (try? FrappeValue.decode(from: response))?.objectValue?["message"]?
                .objectValue?["file_url"]?.nonEmptyString
        else {
            throw ERPNextError(message: "The server did not return the uploaded file's URL.")
        }
        return url
    }
}


// MARK: - W5 settings & bulk operations

public enum BulkDocstatusAction: String, Sendable {
    case submit
    case cancel
}

extension WriteSession {
    /// Persist the user's list sort into their Desk `user_settings` for the
    /// DocType — merged over the existing blob so GridView and the rest of
    /// the settings survive.
    public func saveUserListSort(
        doctype: String, existingSettings: String?, sortBy: String, descending: Bool
    ) async throws {
        let merged = Self.mergedListSort(
            into: existingSettings, sortBy: sortBy, descending: descending)
        let json = try FrappeValue.object(merged).encodedJSONString()
        try await client.call(
            .saveUserSettings, parameters: ["doctype": doctype, "user_settings": json])
    }

    static func mergedListSort(
        into existing: String?, sortBy: String, descending: Bool
    ) -> [String: FrappeValue] {
        var settings =
            existing.flatMap { try? FrappeValue.decode(from: Data($0.utf8)).objectValue }
            ?? [:]
        var list = settings["List"]?.objectValue ?? [:]
        list["sort_by"] = .string(sortBy)
        list["sort_order"] = .string(descending ? "desc" : "asc")
        settings["List"] = .object(list)
        return settings
    }

    /// Persist list columns to the DocType's List View Settings — the same
    /// document Desk's list "gear" writes, and the one Tula already reads.
    public func saveListColumns(
        doctype: String, fieldnames: [String], labels: [String: String],
        removed: [String] = []
    ) async throws {
        let fields = FrappeValue.array(
            fieldnames.map { fieldname in
                .object([
                    "fieldname": .string(fieldname),
                    "label": .string(labels[fieldname] ?? fieldname),
                ])
            })
        let settings = FrappeValue.object(["fields": .string(try fields.encodedJSONString())])
        try await client.call(
            .saveListViewSettings,
            parameters: [
                "doctype": doctype,
                "listview_settings": try settings.encodedJSONString(),
                "removed_listview_fields": Self.jsonList(removed),
            ])
    }

    // MARK: Bulk (Desk's own batched endpoints — one call per operation)

    public func bulkDelete(doctype: String, names: [String]) async throws {
        try await client.call(
            .bulkDelete, parameters: ["doctype": doctype, "items": Self.jsonList(names)])
    }

    public func bulkSubmitCancel(
        doctype: String, names: [String], action: BulkDocstatusAction
    ) async throws {
        try await client.call(
            .bulkSubmitCancel,
            parameters: [
                "doctype": doctype, "docnames": Self.jsonList(names),
                "action": action.rawValue,
            ])
    }

    public func bulkAssign(doctype: String, names: [String], to users: [String]) async throws {
        try await client.call(
            .bulkAssign,
            parameters: [
                "doctype": doctype, "name": Self.jsonList(names),
                "assign_to": Self.jsonList(users),
            ])
    }

    public func bulkAddTag(_ tag: String, doctype: String, names: [String]) async throws {
        try await client.call(
            .bulkTag,
            parameters: [
                "tags": Self.jsonList([tag]), "dt": doctype, "docs": Self.jsonList(names),
            ])
    }

    static func jsonList(_ values: [String]) -> String {
        (try? FrappeValue.array(values.map { .string($0) }).encodedJSONString()) ?? "[]"
    }
}
