import ERPNextKit
import QuickLook
import SwiftUI

/// Everything Desk shows around a form besides its fields: docstatus,
/// assignments and tags, the Connections tab, attachments, and the comment
/// timeline — all read-only (ARCHITECTURE.md §12 Phase 4).
struct DocumentPeriphery: Sendable {
    struct Connection: Identifiable, Sendable {
        var doctype: String
        var fieldname: String
        var count: Int
        var id: String { doctype }
    }

    struct Attachment: Identifiable, Sendable {
        var name: String
        var fileName: String
        var filePath: String
        var isPrivate: Bool
        var size: Int?
        var id: String { name }
    }

    struct Comment: Identifiable, Sendable {
        var id: String
        var author: String
        var creation: String?
        var content: String
    }

    var docstatus: Int?
    var isSubmittable = false
    var assignees: [String] = []
    var tags: [String] = []
    var connections: [Connection] = []
    var attachments: [Attachment] = []
    var comments: [Comment] = []

    var isEmpty: Bool {
        !isSubmittable && assignees.isEmpty && tags.isEmpty && connections.isEmpty
            && attachments.isEmpty && comments.isEmpty
    }

    /// Best-effort loader: every piece degrades to empty on failure.
    static func load(
        doctype: String, name: String, meta: DocTypeMeta, document: Document,
        using source: any DataSource
    ) async -> DocumentPeriphery {
        var periphery = DocumentPeriphery()
        periphery.isSubmittable = meta.isSubmittable
        periphery.docstatus = document.raw["docstatus"]?.intValue

        if let raw = document.raw["_assign"]?.nonEmptyString,
            let decoded = try? FrappeValue.decode(from: Data(raw.utf8)),
            let entries = decoded.arrayValue {
            periphery.assignees = entries.compactMap { $0.nonEmptyString }
        }
        if let raw = document.raw["_user_tags"]?.nonEmptyString {
            periphery.tags = raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }

        async let attachmentDocs = try? source.list(
            "File", fields: ["name", "file_name", "file_url", "is_private", "file_size"],
            filters: [
                ListFilter("attached_to_doctype", "=", .string(doctype)),
                ListFilter("attached_to_name", "=", .string(name)),
            ],
            orderBy: "creation desc", limitStart: 0, limitPageLength: 25)
        async let commentDocs = try? source.list(
            "Comment", fields: ["name", "content", "comment_email", "owner", "creation"],
            filters: [
                ListFilter("reference_doctype", "=", .string(doctype)),
                ListFilter("reference_name", "=", .string(name)),
                ListFilter("comment_type", "=", .string("Comment")),
            ],
            orderBy: "creation desc", limitStart: 0, limitPageLength: 20)

        periphery.attachments = (await attachmentDocs ?? []).compactMap { doc in
            guard let path = doc["file_url"]?.nonEmptyString else { return nil }
            return Attachment(
                name: doc.name,
                fileName: doc["file_name"]?.nonEmptyString
                    ?? (path as NSString).lastPathComponent,
                filePath: path,
                isPrivate: doc["is_private"]?.boolValue ?? false,
                size: doc["file_size"]?.intValue)
        }
        periphery.comments = (await commentDocs ?? []).map { doc in
            Comment(
                id: doc.name,
                author: doc["comment_email"]?.nonEmptyString
                    ?? doc["owner"]?.nonEmptyString ?? "Unknown",
                creation: doc["creation"]?.nonEmptyString,
                content: (doc["content"]?.stringValue ?? "").strippingSimpleHTML())
        }

        for link in meta.connectionLinks.prefix(10) {
            let count =
                (try? await source.count(
                    link.doctype,
                    filters: [ListFilter(link.fieldname, "=", .string(name))])) ?? nil
            if let count, count > 0 {
                periphery.connections.append(
                    Connection(doctype: link.doctype, fieldname: link.fieldname, count: count))
            }
        }
        return periphery
    }
}

/// Docstatus badge + assignee/tag chips shown above the form.
struct PeripheryHeaderView: View {
    let periphery: DocumentPeriphery
    let documentName: String

    var body: some View {
        if periphery.isSubmittable || !periphery.tags.isEmpty || !periphery.assignees.isEmpty {
            HStack(spacing: 8) {
                if periphery.isSubmittable, let docstatus = periphery.docstatus {
                    StatusBadge(status: Self.docstatusLabel(docstatus))
                }
                ForEach(periphery.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                ForEach(periphery.assignees, id: \.self) { assignee in
                    Label(assignee, systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(documentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    static func docstatusLabel(_ docstatus: Int) -> String {
        switch docstatus {
        case 1: return "Submitted"
        case 2: return "Cancelled"
        default: return "Draft"
        }
    }
}

/// Connections, attachments, and comments cards after the form body.
struct PeripheryTrailingSections: View {
    let periphery: DocumentPeriphery

    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?
    @State private var downloadError: String?

    var body: some View {
        if !periphery.connections.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(periphery.connections) { connection in
                        NavigationLink(
                            value: Route.linkedList(
                                doctype: connection.doctype,
                                fieldname: connection.fieldname,
                                value: connectionValue)
                        ) {
                            HStack {
                                Text(connection.doctype)
                                Spacer()
                                Text("\(connection.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            } label: {
                Text("Connections").font(.headline).padding(.bottom, 2)
            }
        }

        if !periphery.attachments.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(periphery.attachments) { attachment in
                        Button {
                            Task { await open(attachment) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: symbol(for: attachment.fileName))
                                    .foregroundStyle(.tint)
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                Spacer()
                                if let size = attachment.size {
                                    Text(
                                        ByteCountFormatter.string(
                                            fromByteCount: Int64(size), countStyle: .file)
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                if attachment.isPrivate {
                                    Image(systemName: "lock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let downloadError {
                        Text(downloadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(4)
            } label: {
                Text("Attachments").font(.headline).padding(.bottom, 2)
            }
            .quickLookPreview($previewURL)
        }

        if !periphery.comments.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(periphery.comments) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(comment.author)
                                    .font(.caption.weight(.semibold))
                                if let ago = ValueFormatting.relativeModified(comment.creation) {
                                    Text(ago)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(comment.content)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Comments").font(.headline).padding(.bottom, 2)
            }
        }
    }

    /// The document these sections belong to (from the first connection's
    /// perspective the linked value is always the parent doc's name).
    var connectionValue: String = ""

    init(periphery: DocumentPeriphery, documentName: String) {
        self.periphery = periphery
        self.connectionValue = documentName
    }

    private func symbol(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "csv", "xlsx", "xls": return "tablecells"
        case "zip": return "doc.zipper"
        default: return "doc"
        }
    }

    private func open(_ attachment: DocumentPeriphery.Attachment) async {
        do {
            let data = try await model.dataSource.fileData(path: attachment.filePath)
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "Attachments", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appending(component: attachment.fileName)
            try data.write(to: url, options: .atomic)
            downloadError = nil
            previewURL = url
        } catch {
            downloadError = error.localizedDescription
        }
    }
}
