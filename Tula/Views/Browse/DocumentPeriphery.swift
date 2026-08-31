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
    /// Active Workflow state and available transitions (metadata-driven;
    /// empty when the DocType has no active workflow).
    var workflowState: String?
    var workflowActions: [String] = []
    var assignees: [String] = []
    var tags: [String] = []
    var shares: [String] = []
    var likedBy: [String] = []
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
        if let raw = document.raw["_liked_by"]?.nonEmptyString,
            let decoded = try? FrappeValue.decode(from: Data(raw.utf8)),
            let entries = decoded.arrayValue {
            periphery.likedBy = entries.compactMap { $0.nonEmptyString }
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
    var doctype: String = ""
    var documentRaw: [String: FrappeValue] = [:]
    var onMutate: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?
    @State private var downloadError: String?
    @State private var writeError: String?

    var body: some View {
        if periphery.hasBarContent || !actions.isEmpty || model.writesUnlocked {
            HStack(spacing: 8) {
                DocumentActionsCluster(actions: actions)
                    .layoutPriority(1)
                LifecycleCluster(
                    doctype: doctype, name: documentName, documentRaw: documentRaw,
                    periphery: periphery, onMutate: onMutate)
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
                if let message = downloadError ?? writeError {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.leading, 12)
                }
            }
        }
    }

    /// Runs a gated mutation, surfaces errors, and refreshes on success.
    private func write(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                writeError = nil
                onMutate()
            } catch {
                writeError = error.localizedDescription
            }
        }
    }

    private var chipsScroller: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // With an active workflow, its state is the document's
                    // indicator (Desk shows it in place of the docstatus).
                    if let workflowState = periphery.workflowState, !workflowState.isEmpty {
                        StatusBadge(status: workflowState)
                    } else if periphery.isSubmittable, let docstatus = periphery.docstatus {
                        StatusBadge(status: Self.docstatusLabel(docstatus))
                    }
                    ForEach(periphery.assignees, id: \.self) { assignee in
                        chip(label: assignee, systemImage: "person.crop.circle")
                            .contextMenu {
                                if let session = model.writeSession {
                                    Button(role: .destructive) {
                                        write {
                                            try await session.removeAssignment(
                                                doctype: doctype, name: documentName,
                                                user: assignee)
                                        }
                                    } label: {
                                        Label("Remove Assignment", systemImage: "person.badge.minus")
                                    }
                                }
                            }
                    }
                    if model.writeSession != nil {
                        AssignChip(
                            alreadyAssigned: periphery.assignees,
                            doctype: doctype, documentName: documentName,
                            perform: write)
                    }
                    ForEach(periphery.tags, id: \.self) { tag in
                        chip(label: tag, systemImage: "tag")
                            .contextMenu {
                                if let session = model.writeSession {
                                    Button(role: .destructive) {
                                        write {
                                            try await session.removeTag(
                                                tag, doctype: doctype, name: documentName)
                                        }
                                    } label: {
                                        Label("Remove Tag", systemImage: "tag.slash")
                                    }
                                }
                            }
                    }
                    if model.writeSession != nil {
                        AddTagChip { tag in
                            write {
                                try await model.writeSession?.addTag(
                                    tag, doctype: doctype, name: documentName)
                            }
                        }
                    }
                    if !periphery.likedBy.isEmpty || model.writeSession != nil {
                        LikeChip(
                            likedBy: periphery.likedBy,
                            doctype: doctype, documentName: documentName,
                            perform: write)
                    }
                    if !periphery.attachments.isEmpty || model.writeSession != nil {
                        AttachmentsChip(
                            attachments: periphery.attachments,
                            doctype: doctype, documentName: documentName,
                            perform: write,
                            previewURL: $previewURL,
                            downloadError: $downloadError)
                    }
                    if !periphery.shares.isEmpty || model.writeSession != nil {
                        SharesChip(
                            shares: periphery.shares,
                            doctype: doctype, documentName: documentName,
                            perform: write)
                    }
                    if model.writeSession != nil {
                        FollowChip(
                            doctype: doctype, documentName: documentName, perform: write)
                        RemindChip(
                            doctype: doctype, documentName: documentName, perform: write)
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

/// Paperclip chip → popover listing attachments; tap downloads and previews;
/// unlocked adds upload and delete.
private struct AttachmentsChip: View {
    let attachments: [DocumentPeriphery.Attachment]
    var doctype: String = ""
    var documentName: String = ""
    var perform: (@escaping () async throws -> Void) -> Void = { _ in }
    @Binding var previewURL: URL?
    @Binding var downloadError: String?

    @Environment(AppModel.self) private var model
    @State private var showingPopover = false
    @State private var showingImporter = false

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
                if attachments.isEmpty {
                    Text("No attachments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    .contextMenu {
                        if let session = model.writeSession {
                            Button(role: .destructive) {
                                showingPopover = false
                                perform {
                                    try await session.deleteAttachment(
                                        fileDocName: attachment.name)
                                }
                            } label: {
                                Label("Delete Attachment", systemImage: "trash")
                            }
                        }
                    }
                }
                if model.writeSession != nil {
                    Divider()
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Add Attachment…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            #if os(macOS)
                .frame(minWidth: 300)
            #endif
        }
        .fileImporter(
            isPresented: $showingImporter, allowedContentTypes: [.item]
        ) { result in
            guard let session = model.writeSession,
                case .success(let url) = result
            else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                downloadError = "Couldn't read \(url.lastPathComponent)"
                return
            }
            showingPopover = false
            perform {
                try await session.uploadAttachment(
                    fileName: url.lastPathComponent, data: data,
                    doctype: doctype, name: documentName)
            }
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

/// Share chip → who the document is shared with; unlocked adds share/unshare
/// with a user search.
private struct SharesChip: View {
    let shares: [String]
    var doctype: String = ""
    var documentName: String = ""
    var perform: (@escaping () async throws -> Void) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var showingPopover = false
    @State private var query = ""
    @State private var results: [LinkOption] = []

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
                if shares.isEmpty {
                    Text("Not shared")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(shares, id: \.self) { share in
                    HStack {
                        Label(share, systemImage: "person.crop.circle")
                            .font(.callout)
                        Spacer()
                        if let session = model.writeSession {
                            Button {
                                showingPopover = false
                                perform {
                                    try await session.removeShare(
                                        doctype: doctype, name: documentName, user: share)
                                }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if model.writeSession != nil {
                    Divider()
                    TextField("Share with user…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    ForEach(results.prefix(5)) { option in
                        Button {
                            showingPopover = false
                            perform {
                                try await model.writeSession?.addShare(
                                    doctype: doctype, name: documentName,
                                    user: option.value)
                            }
                        } label: {
                            Label(option.value, systemImage: "plus.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            #if os(macOS)
                .frame(minWidth: 280)
            #endif
            .task(id: query) {
                guard !query.isEmpty else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                results =
                    (try? await model.dataSource.searchLink(doctype: "User", query: query))
                    ?? []
            }
        }
    }
}

/// Heart chip: like count, filled when the signed-in user likes the
/// document; tap toggles when unlocked.
private struct LikeChip: View {
    let likedBy: [String]
    var doctype: String = ""
    var documentName: String = ""
    var perform: (@escaping () async throws -> Void) -> Void = { _ in }

    @Environment(AppModel.self) private var model

    private var likedByMe: Bool {
        guard let user = model.writeSession?.user else { return false }
        return likedBy.contains(user)
    }

    var body: some View {
        Button {
            guard let session = model.writeSession else { return }
            let target = !likedByMe
            perform {
                try await session.toggleLike(
                    doctype: doctype, name: documentName, liked: target)
            }
        } label: {
            Label("\(likedBy.count)", systemImage: likedByMe ? "heart.fill" : "heart")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .foregroundStyle(likedByMe ? AnyShapeStyle(.pink) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .disabled(model.writeSession == nil)
    }
}

/// Assign chip: assign to me, or search users to assign.
private struct AssignChip: View {
    let alreadyAssigned: [String]
    var doctype: String = ""
    var documentName: String = ""
    var perform: (@escaping () async throws -> Void) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var showingPopover = false
    @State private var query = ""
    @State private var results: [LinkOption] = []

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Label("Assign", systemImage: "person.badge.plus")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let session = model.writeSession,
                    !alreadyAssigned.contains(session.user) {
                    Button {
                        showingPopover = false
                        perform {
                            try await session.assignToMe(
                                doctype: doctype, name: documentName)
                        }
                    } label: {
                        Label("Assign to me", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.borderless)
                    Divider()
                }
                TextField("Assign user…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                ForEach(results.prefix(5)) { option in
                    Button {
                        showingPopover = false
                        perform {
                            try await model.writeSession?.assign(
                                doctype: doctype, name: documentName,
                                users: [option.value])
                        }
                    } label: {
                        Label(option.value, systemImage: "plus.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            #if os(macOS)
                .frame(minWidth: 280)
            #endif
            .task(id: query) {
                guard !query.isEmpty else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                results =
                    (try? await model.dataSource.searchLink(doctype: "User", query: query))
                    ?? []
            }
        }
    }
}

/// Follow chip: server-side document follow (daily digest in Desk).
private struct FollowChip: View {
    var doctype: String = ""
    var documentName: String = ""
    var perform: (@escaping () async throws -> Void) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var following: Bool?

    var body: some View {
        Button {
            guard let session = model.writeSession else { return }
            let target = !(following ?? false)
            perform {
                try await session.setFollowing(
                    doctype: doctype, name: documentName, following: target)
            }
            following = target
        } label: {
            Label(
                following == true ? "Following" : "Follow",
                systemImage: following == true ? "bookmark.fill" : "bookmark"
            )
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .task {
            guard let session = model.writeSession else { return }
            following =
                (try? await model.dataSource.isFollowing(
                    doctype: doctype, name: documentName, user: session.user)) ?? nil
        }
    }
}

/// Bell chip: create a server-side reminder for this document.
private struct RemindChip: View {
    var doctype: String = ""
    var documentName: String = ""
    var perform: (@escaping () async throws -> Void) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var showingPopover = false
    @State private var remindAt = Date().addingTimeInterval(24 * 3600)
    @State private var note = ""

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Label("Remind", systemImage: "bell")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Remind me about \(documentName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                DatePicker(
                    "When", selection: $remindAt,
                    displayedComponents: [.date, .hourAndMinute])
                TextField("Note (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Set Reminder") {
                        guard let session = model.writeSession else { return }
                        let when = ValueFormatting.wireDatetimeString(remindAt)
                        let description =
                            note.isEmpty ? "Check \(doctype) \(documentName)" : note
                        showingPopover = false
                        perform {
                            try await session.createReminder(
                                remindAt: when, description: description,
                                doctype: doctype, name: documentName)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            #if os(macOS)
                .frame(minWidth: 300)
            #endif
        }
    }
}

/// Dashboard, comments, and activity cards after the form body.
struct PeripheryTrailingSections: View {
    let periphery: DocumentPeriphery
    let documentName: String
    var doctype: String = ""
    var onMutate: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var commentDraft = ""
    @State private var isPostingComment = false
    @State private var commentError: String?
    @State private var editingCommentID: String?
    @State private var editDraft = ""

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

        if !periphery.comments.isEmpty || model.writesUnlocked {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let session = model.writeSession {
                        HStack(spacing: 8) {
                            TextField("Add a comment…", text: $commentDraft, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...4)
                            Button {
                                postComment(session)
                            } label: {
                                if isPostingComment {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                isPostingComment
                                    || commentDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let commentError {
                            Text(commentError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
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
                            if editingCommentID == comment.id {
                                TextField("Comment", text: $editDraft, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(1...4)
                                HStack {
                                    Button("Cancel") { editingCommentID = nil }
                                    Button("Save") { saveEditedComment(comment) }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(
                                            editDraft.trimmingCharacters(in: .whitespaces)
                                                .isEmpty)
                                }
                                .controlSize(.small)
                            } else {
                                Text(comment.content)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        .contextMenu {
                            if let session = model.writeSession,
                                comment.author == session.user {
                                Button {
                                    editDraft = comment.content
                                    editingCommentID = comment.id
                                } label: {
                                    Label("Edit Comment", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deleteComment(comment, session: session)
                                } label: {
                                    Label("Delete Comment", systemImage: "trash")
                                }
                            }
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

    private func saveEditedComment(_ comment: DocumentPeriphery.Comment) {
        guard let session = model.writeSession else { return }
        let content = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        Task {
            do {
                try await session.updateComment(name: comment.id, content: content)
                editingCommentID = nil
                commentError = nil
                onMutate()
            } catch {
                commentError = error.localizedDescription
            }
        }
    }

    private func deleteComment(
        _ comment: DocumentPeriphery.Comment, session: WriteSession
    ) {
        Task {
            do {
                try await session.deleteComment(name: comment.id)
                commentError = nil
                onMutate()
            } catch {
                commentError = error.localizedDescription
            }
        }
    }

    private func postComment(_ session: WriteSession) {
        let content = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isPostingComment = true
        Task {
            do {
                try await session.addComment(
                    doctype: doctype, name: documentName, content: content)
                commentDraft = ""
                commentError = nil
                onMutate()
            } catch {
                commentError = error.localizedDescription
            }
            isPostingComment = false
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


/// "+ Tag" chip: small popover with a text field; submits a new tag.
private struct AddTagChip: View {
    let onAdd: (String) -> Void

    @State private var showingPopover = false
    @State private var tag = ""

    var body: some View {
        Button {
            tag = ""
            showingPopover = true
        } label: {
            Label("Tag", systemImage: "plus")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                TextField("New tag", text: $tag)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { submit() }
                Button("Add") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            #if os(macOS)
                .frame(width: 260)
            #endif
        }
    }

    private func submit() {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        showingPopover = false
        onAdd(trimmed)
    }
}
