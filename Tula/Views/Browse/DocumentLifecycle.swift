import ERPNextKit
import SwiftUI

/// W2 lifecycle actions: Submit, Cancel, metadata-driven workflow
/// transitions, Duplicate, Rename, and Delete. Visible only while the write
/// gate is unlocked; every state-changing action sits behind an explicit
/// confirmation, and errors come back as alerts rather than silent failures.
struct LifecycleCluster: View {
    let doctype: String
    let name: String
    let documentRaw: [String: FrappeValue]
    let periphery: DocumentPeriphery
    var isEditing: Bool = false
    /// Enters the W3 edit session; nil when nothing on the document is
    /// editable at its docstatus.
    var onEdit: (() -> Void)? = nil
    /// Opens the cancelled document's amended copy for editing in place;
    /// nil hides Amend.
    var onAmend: (() -> Void)? = nil
    var onMutate: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var pending: Pending?
    @State private var renameRequested = false
    @State private var newName = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private enum Pending: Identifiable {
        case submit
        case cancel
        case delete
        case workflow(String)

        var id: String {
            switch self {
            case .submit: return "submit"
            case .cancel: return "cancel"
            case .delete: return "delete"
            case .workflow(let action): return "workflow|\(action)"
            }
        }
    }

    var body: some View {
        // Lifecycle actions step aside while an edit session is open —
        // Save/Discard own the document until it closes.
        if model.writeSession != nil && !isEditing {
            HStack(spacing: 6) {
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Edit fields")
                }
                // With an active workflow, its transitions drive docstatus —
                // Desk hides the plain Submit button in that case.
                ForEach(periphery.workflowActions, id: \.self) { action in
                    Button(action) { pending = .workflow(action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if periphery.workflowActions.isEmpty, periphery.isSubmittable,
                    periphery.docstatus == 0 {
                    Button("Submit") { pending = .submit }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if periphery.docstatus == 1 {
                    Button("Cancel") { pending = .cancel }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                }
                if periphery.docstatus == 2, let onAmend {
                    // Desk's amend: a draft copy carrying amended_from,
                    // editable in this same form before anything hits the
                    // server.
                    Button("Amend", action: onAmend)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Menu {
                    Button {
                        duplicate()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button {
                        newName = name
                        renameRequested = true
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    // Desk allows deleting drafts and cancelled documents;
                    // submitted ones must be cancelled first.
                    if periphery.docstatus != 1 {
                        Button(role: .destructive) {
                            pending = .delete
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Lifecycle", systemImage: "arrow.triangle.branch")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Duplicate, rename, or delete this document")
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(busy)
            .confirmationDialog(
                confirmationTitle, isPresented: confirmationShown,
                titleVisibility: .visible
            ) {
                confirmationButtons
            } message: {
                Text(confirmationMessage)
            }
            .alert("Rename \(name)", isPresented: $renameRequested) {
                TextField("New ID", text: $newName)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sets a new ID for this \(doctype). Links elsewhere are updated by the server.")
            }
            .alert(
                "Couldn't Complete",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Confirmation dialog

    private var confirmationShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmationTitle: String {
        switch pending {
        case .submit: return "Submit \(name)?"
        case .cancel: return "Cancel \(name)?"
        case .delete: return "Delete \(name)?"
        case .workflow(let action): return "\(action) \(name)?"
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch pending {
        case .submit:
            return "Submitting makes this \(doctype) final. It can only be changed by cancelling and amending."
        case .cancel:
            return "Cancelling reverses this \(doctype)'s effects (ledger postings, stock movements)."
        case .delete:
            return "Permanently deletes \(doctype) \(name) from the server. This cannot be undone."
        case .workflow(let action):
            return "Applies the \(action) workflow transition to this \(doctype)."
        case nil:
            return ""
        }
    }

    @ViewBuilder private var confirmationButtons: some View {
        switch pending {
        case .submit:
            Button("Submit") { run { try await $0.submit(documentRaw: documentRaw) } }
        case .cancel:
            Button("Cancel Document", role: .destructive) {
                run { try await $0.cancel(doctype: doctype, name: name) }
            }
        case .delete:
            Button("Delete \(name)", role: .destructive) { delete() }
        case .workflow(let action):
            Button(action) {
                run { try await $0.applyWorkflow(documentRaw: documentRaw, action: action) }
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - Operations

    /// Runs a mutation that changes this document in place, then refreshes.
    private func run(_ operation: @escaping (WriteSession) async throws -> Void) {
        guard let session = model.writeSession else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await operation(session)
                onMutate()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func duplicate() {
        guard let session = model.writeSession else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let copyName = try await session.duplicate(
                    documentRaw: documentRaw, doctype: doctype)
                model.pendingRoute = .document(doctype: doctype, name: copyName)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rename() {
        guard let session = model.writeSession else { return }
        let target = newName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, target != name else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let settled = try await session.rename(
                    doctype: doctype, name: name, to: target)
                model.pendingRoute = .document(doctype: doctype, name: settled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete() {
        guard let session = model.writeSession else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await session.deleteDocument(doctype: doctype, name: name)
                model.pendingRoute = .doctypeList(doctype)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
