import ERPNextKit
import QuickLook
import SwiftUI

/// Everything Desk shows around a form besides its fields, read-only
/// (ARCHITECTURE.md §12 Phase 4): a bar above the form carries docstatus,
/// assignees, tags, attachments, and shares; below the form come the
/// Dashboard (linked-document counts), comments, and the Version activity
/// trail.
struct DocumentPeriphery: Sendable {
    struct Connection: Identifiable, Sendable {
        var doctype: String
        var fieldname: String
        var count: Int
        var group: String?
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

    struct ActivityEntry: Identifiable, Sendable {
        var id: String
        var author: String
        var creation: String?
        var summary: String
    }

    var docstatus: Int?
    var isSubmittable = false
    var assignees: [String] = []
    var tags: [String] = []
    var shares: [String] = []
    var connections: [Connection] = []
    var attachments: [Attachment] = []
    var comments: [Comment] = []
    var activity: [ActivityEntry] = []

    var hasBarContent: Bool {
        isSubmittable || !assignees.isEmpty || !tags.isEmpty || !attachments.isEmpty
            || !shares.isEmpty
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
        async let versionDocs = try? source.list(
            "Version", fields: ["name", "owner", "creation", "data"],
            filters: [
                ListFilter("ref_doctype", "=", .string(doctype)),
                ListFilter("docname", "=", .string(name)),
            ],
            orderBy: "creation desc", limitStart: 0, limitPageLength: 15)
        async let shareDocs = try? source.list(
            "DocShare", fields: ["name", "user", "everyone"],
            filters: [
                ListFilter("share_doctype", "=", .string(doctype)),
                ListFilter("share_name", "=", .string(name)),
            ],
            orderBy: "creation asc", limitStart: 0, limitPageLength: 20)

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
        periphery.shares = (await shareDocs ?? []).compactMap { doc in
            doc["everyone"]?.boolValue == true
                ? "Everyone" : doc["user"]?.nonEmptyString
        }

        // Activity: parsed Version diffs, then the creation event.
        periphery.activity = (await versionDocs ?? []).compactMap { doc in
            guard let summary = versionSummary(doc["data"]?.nonEmptyString) else { return nil }
            return ActivityEntry(
                id: doc.name,
                author: doc["owner"]?.nonEmptyString ?? "Unknown",
                creation: doc["creation"]?.nonEmptyString,
                summary: summary)
        }
        if let owner = document.raw["owner"]?.nonEmptyString {
            periphery.activity.append(
                ActivityEntry(
                    id: "created",
                    author: owner,
                    creation: document.raw["creation"]?.nonEmptyString,
                    summary: "Created this document"))
        }

        // Dashboard: every linked DocType from the metadata, counted in one
        // batched call when the server supports it.
        let links = Array(meta.connectionLinks.prefix(16))
        if !links.isEmpty {
            let batched = (try? await source.openCounts(doctype: doctype, name: name)) ?? nil
            for link in links {
                let count: Int
                if let batched {
                    count = batched[link.doctype] ?? 0
                } else {
                    count =
                        ((try? await source.count(
                            link.doctype,
                            filters: [ListFilter(link.fieldname, "=", .string(name))])) ?? nil)
                        ?? 0
                }
                periphery.connections.append(
                    Connection(
                        doctype: link.doctype, fieldname: link.fieldname, count: count,
                        group: link.group))
            }
        }
        return periphery
    }

    /// "Changed Status → Paid, Outstanding Amount → 0" from a Version's diff.
    static func versionSummary(_ raw: String?) -> String? {
        guard let raw,
            let decoded = try? FrappeValue.decode(from: Data(raw.utf8)),
            let data = decoded.objectValue
        else { return nil }

        var parts: [String] = []
        let changed = data["changed"]?.arrayValue ?? []
        for row in changed.prefix(3) {
            guard let entry = row.arrayValue, entry.count >= 3,
                let fieldname = entry[0].nonEmptyString
            else { continue }
            let label = fieldname.replacingOccurrences(of: "_", with: " ").capitalized
            let newValue = entry[2].nonEmptyString ?? "blank"
            parts.append("\(label) → \(truncate(newValue))")
        }
        if changed.count > 3 {
            parts.append("…")
        }
        for key in ["added", "removed"] {
            let rows = data[key]?.arrayValue ?? []
            if !rows.isEmpty {
                parts.append("\(key.capitalized) \(rows.count) row\(rows.count == 1 ? "" : "s")")
            }
        }
        guard !parts.isEmpty else { return nil }
        return "Changed " + parts.joined(separator: ", ")
    }

    private static func truncate(_ value: String) -> String {
        value.count > 42 ? value.prefix(40) + "…" : value
    }
}

/// The bar above the form: docstatus, assignees, tags, attachments, shares —
/// Desk's sidebar, horizontal. Chips are self-contained buttons/popovers
/// (the layout-safe pattern from the quick-filter bar).
struct PeripheryBar: View {
    let periphery: DocumentPeriphery
    let documentName: String
    var actions: [DocumentAction] = []

    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?
    @State private var downloadError: String?

    var body: some View {
        if periphery.hasBarContent || !actions.isEmpty {
            HStack(spacing: 8) {
                DocumentActionsCluster(actions: actions)
                    .layoutPriority(1)
                if !actions.isEmpty && periphery.hasBarContent {
                    Divider().frame(height: 16)
                }
                chipsScroller
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .quickLookPreview($previewURL)
            .overlay(alignment: .bottomLeading) {
                if let downloadError {
                    Text(downloadError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.leading, 12)
                }
            }
        }
    }

    private var chipsScroller: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if periphery.isSubmittable, let docstatus = periphery.docstatus {
                        StatusBadge(status: Self.docstatusLabel(docstatus))
                    }
                    ForEach(periphery.assignees, id: \.self) { assignee in
                        chip(label: assignee, systemImage: "person.crop.circle")
                    }
                    ForEach(periphery.tags, id: \.self) { tag in
                        chip(label: tag, systemImage: "tag")
                    }
                    if !periphery.attachments.isEmpty {
                        AttachmentsChip(
                            attachments: periphery.attachments,
                            previewURL: $previewURL,
                            downloadError: $downloadError)
                    }
                    if !periphery.shares.isEmpty {
                        SharesChip(shares: periphery.shares)
                    }
                    Text(documentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 4)
                }
            }
    }

    private func chip(label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }

    static func docstatusLabel(_ docstatus: Int) -> String {
        switch docstatus {
        case 1: return "Submitted"
        case 2: return "Cancelled"
        default: return "Draft"
        }
    }
}

/// Paperclip chip → popover listing attachments; tap downloads and previews.
private struct AttachmentsChip: View {
    let attachments: [DocumentPeriphery.Attachment]
    @Binding var previewURL: URL?
    @Binding var downloadError: String?

    @Environment(AppModel.self) private var model
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Label("\(attachments.count)", systemImage: "paperclip")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(attachments) { attachment in
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
            }
            .padding(12)
            #if os(macOS)
                .frame(minWidth: 300)
            #endif
        }
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
            showingPopover = false
            previewURL = url
        } catch {
            downloadError = error.localizedDescription
        }
    }
}

/// Share chip → popover listing who the document is shared with (read-only).
private struct SharesChip: View {
    let shares: [String]

    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Label("\(shares.count)", systemImage: "person.2")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shared with")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(shares, id: \.self) { share in
                    Label(share, systemImage: "person.crop.circle")
                        .font(.callout)
                }
            }
            .padding(12)
            #if os(macOS)
                .frame(minWidth: 240)
            #endif
        }
    }
}

/// Dashboard, comments, and activity cards after the form body.
struct PeripheryTrailingSections: View {
    let periphery: DocumentPeriphery
    let documentName: String

    var body: some View {
        if !periphery.connections.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedConnections, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = group.title.isEmpty ? nil : group.title {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.connections) { connection in
                                connectionRow(connection)
                            }
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Dashboard").font(.headline).padding(.bottom, 2)
            }
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

        if !periphery.activity.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(periphery.activity) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.summary)
                                    .font(.callout)
                                HStack(spacing: 6) {
                                    Text(entry.author)
                                    if let ago = ValueFormatting.relativeModified(entry.creation) {
                                        Text(ago)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Activity").font(.headline).padding(.bottom, 2)
            }
        }
    }

    private var groupedConnections: [(title: String, connections: [DocumentPeriphery.Connection])] {
        var order: [String] = []
        var groups: [String: [DocumentPeriphery.Connection]] = [:]
        for connection in periphery.connections {
            let key = connection.group ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(connection)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    @ViewBuilder
    private func connectionRow(_ connection: DocumentPeriphery.Connection) -> some View {
        if connection.count > 0 {
            NavigationLink(
                value: Route.linkedList(
                    doctype: connection.doctype,
                    fieldname: connection.fieldname,
                    value: documentName)
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
        } else {
            HStack {
                Text(connection.doctype)
                Spacer()
                Text("0")
                    .monospacedDigit()
            }
            .foregroundStyle(.tertiary)
        }
    }
}
