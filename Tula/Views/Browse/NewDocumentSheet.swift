import ERPNextKit
import SwiftUI

/// W4 creation: a new document as an edit session over a meta-seeded
/// draft, rendered by the same generic form chain as W3 editing. Two
/// presentations of one sheet: Quick Entry (Desk's compact-create — the
/// mandatory + `allow_in_quick_entry` fields) with an Edit Full Form
/// escape hatch, and the full blank form. Amend reuses it with a seed
/// copied from the cancelled document. Naming stays server-side; a
/// prompt-named DocType gets an ID field feeding `__newname`.
struct NewDocumentSheet: View {
    let doctype: String
    /// Pre-filled draft (the amend seed); empty for a blank document.
    var seed: [String: FrappeValue] = [:]
    var onCreated: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Loaded> = .loading
    @State private var session: EditSession?
    @State private var quickEntry = false
    @State private var newName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    struct Loaded {
        var meta: DocTypeMeta
        var childMetas: [String: DocTypeMeta]
        var gridColumns: [String: [GridColumn]]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading \(doctype) form…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Form", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .loaded(let loaded):
                    if let session {
                        form(loaded, session: session)
                    }
                }
            }
            .navigationTitle("New \(doctype)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if quickEntry {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Edit Full Form") { quickEntry = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        create()
                    } label: {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(isCreating || model.writeSession == nil)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 620, minHeight: 520)
        #else
            .presentationDetents(quickEntry ? [.medium, .large] : [.large])
        #endif
        .task {
            await load()
        }
    }

    private func form(_ loaded: Loaded, session: EditSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if loaded.meta.autoname == "prompt" {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 2) {
                            Text("ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("*")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        TextField("New \(doctype) ID", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                    }
                }
                DocumentFormView(
                    meta: quickEntry ? Self.quickEntryMeta(loaded.meta) : loaded.meta,
                    childMetas: loaded.childMetas,
                    document: Document(raw: session.draft),
                    gridColumns: loaded.gridColumns)
                    .environment(\.editSession, session)
            }
            .padding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        do {
            let bundle = try await model.cache.metaBundle(for: doctype, using: model.dataSource)
            guard let meta = bundle.metas.first else {
                throw ERPNextError(message: "No metadata for \(doctype)")
            }
            let loaded = Loaded(
                meta: meta,
                childMetas: Dictionary(
                    uniqueKeysWithValues: bundle.metas.dropFirst().map { ($0.name, $0) }),
                gridColumns: bundle.gridColumns)
            var draft = seed.isEmpty ? Self.seedDraft(meta: meta) : seed
            draft["doctype"] = .string(doctype)
            draft["docstatus"] = .int(0)
            session = EditSession(document: Document(raw: draft), docstatus: 0)
            // Quick Entry only makes sense for blank creates with a curated
            // field set; amends open the full form.
            quickEntry = meta.quickEntry && seed.isEmpty
                && !Self.quickEntryFieldRaws(meta).isEmpty
            state = .loaded(loaded)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func create() {
        guard let writeSession = model.writeSession, let session else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                var draft = session.draft
                draft["doctype"] = .string(doctype)
                let id = newName.trimmingCharacters(in: .whitespaces)
                if !id.isEmpty {
                    draft["__newname"] = .string(id)
                }
                let created = try await writeSession.insert(documentRaw: draft)
                dismiss()
                onCreated(created)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Meta interpretation

    /// Convention-safe defaults from the metadata: literals, Today/Now.
    /// Session-dependent specials (`:Company`, `user`) stay server-side —
    /// the server fills them on insert.
    static func seedDraft(meta: DocTypeMeta) -> [String: FrappeValue] {
        var draft: [String: FrappeValue] = [:]
        for field in meta.fields {
            guard let raw = field.defaultRaw, !raw.hasPrefix(":") else { continue }
            switch field.fieldtype {
            case .check:
                draft[field.fieldname] = .int(raw == "1" || raw == "Yes" ? 1 : 0)
            case .int:
                if let value = Int(raw) { draft[field.fieldname] = .int(value) }
            case .float, .currency, .percent:
                if let value = Double(raw) { draft[field.fieldname] = .double(value) }
            case .date:
                draft[field.fieldname] = .string(
                    raw == "Today" ? ValueFormatting.wireDateString(Date()) : raw)
            case .datetime:
                draft[field.fieldname] = .string(
                    raw == "Today" || raw == "Now"
                        ? ValueFormatting.wireDatetimeString(Date()) : raw)
            default:
                if raw != "user" {
                    draft[field.fieldname] = .string(raw)
                }
            }
        }
        return draft
    }

    private static func quickEntryFieldRaws(_ meta: DocTypeMeta) -> [FrappeValue] {
        meta.raw["fields"]?.arrayValue?.filter { value in
            guard let dict = value.objectValue else { return false }
            let field = DocField(raw: dict)
            guard EditSession.hasEditor(field.fieldtype), !field.hidden,
                !field.readOnly, field.permlevel == 0
            else { return false }
            return field.reqd || field.allowInQuickEntry
        } ?? []
    }

    /// A synthetic DocType carrying only Desk's quick-entry field set — the
    /// same generic renderer then produces the compact dialog.
    static func quickEntryMeta(_ meta: DocTypeMeta) -> DocTypeMeta {
        var raw = meta.raw
        raw["fields"] = .array(quickEntryFieldRaws(meta))
        return DocTypeMeta(raw: raw)
    }
}

/// The gated "+ New" toolbar entry for list screens.
struct NewDocumentToolbar: ToolbarContent {
    let doctype: String
    @Binding var showingNew: Bool

    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.writeSession != nil {
                Button {
                    showingNew = true
                } label: {
                    Label("New \(doctype)", systemImage: "plus")
                }
                .help("Create a new \(doctype)")
            }
        }
    }
}
