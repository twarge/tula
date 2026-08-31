import ERPNextKit
import SwiftUI

/// W5 bulk operations over a list selection: assign, tag, submit/cancel,
/// and delete — each one call to Desk's own batched endpoints, with the
/// destructive/irreversible ones behind explicit confirmations. Appears
/// between the quick filters and the rows whenever documents are selected
/// and the write gate is open.
struct BulkActionsBar: View {
    let doctype: String
    let isSubmittable: Bool
    @Binding var selection: Set<String>
    var onDone: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var pending: Pending?
    @State private var tagPromptShown = false
    @State private var tagText = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private enum Pending: Identifiable {
        case submit
        case cancel
        case delete

        var id: String {
            switch self {
            case .submit: return "submit"
            case .cancel: return "cancel"
            case .delete: return "delete"
            }
        }
    }

    /// The bar also renders (with actions disabled) under the verification
    /// preview hook, which cannot open the real gate.
    private var previewOnly: Bool {
        model.writeSession == nil
            && ProcessInfo.processInfo.environment["TULA_EDIT_PREVIEW"] == "1"
    }

    var body: some View {
        if !selection.isEmpty, model.writeSession != nil || previewOnly {
            HStack(spacing: 10) {
                Text("\(selection.count) selected")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Button("Assign to Me") { assignToMe() }
                Button("Tag…") {
                    tagText = ""
                    tagPromptShown = true
                }
                if isSubmittable {
                    Button("Submit…") { pending = .submit }
                    Button("Cancel…") { pending = .cancel }
                }
                Button("Delete…", role: .destructive) { pending = .delete }
                if busy {
                    ProgressView().controlSize(.small)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    selection = []
                } label: {
                    Label("Clear Selection", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busy || previewOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .confirmationDialog(
                confirmationTitle, isPresented: confirmationShown, titleVisibility: .visible
            ) {
                confirmationButtons
            } message: {
                Text(confirmationMessage)
            }
            .alert("Tag \(selection.count) Documents", isPresented: $tagPromptShown) {
                TextField("Tag", text: $tagText)
                Button("Add Tag") { addTag() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Confirmations

    private var confirmationShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmationTitle: String {
        switch pending {
        case .submit: return "Submit \(selection.count) documents?"
        case .cancel: return "Cancel \(selection.count) documents?"
        case .delete: return "Delete \(selection.count) documents?"
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch pending {
        case .submit:
            return "Submitting makes these \(doctype) documents final."
        case .cancel:
            return "Cancelling reverses these documents' effects (ledger postings, stock movements)."
        case .delete:
            return "Permanently deletes the selected \(doctype) documents. This cannot be undone."
        case nil:
            return ""
        }
    }

    @ViewBuilder private var confirmationButtons: some View {
        switch pending {
        case .submit:
            Button("Submit \(selection.count)") {
                run { try await $0.bulkSubmitCancel(
                    doctype: doctype, names: Array(selection), action: .submit) }
            }
        case .cancel:
            Button("Cancel \(selection.count)", role: .destructive) {
                run { try await $0.bulkSubmitCancel(
                    doctype: doctype, names: Array(selection), action: .cancel) }
            }
        case .delete:
            Button("Delete \(selection.count)", role: .destructive) {
                run { try await $0.bulkDelete(doctype: doctype, names: Array(selection)) }
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - Operations

    private func assignToMe() {
        guard let user = model.writeSession?.user else { return }
        run { try await $0.bulkAssign(doctype: doctype, names: Array(selection), to: [user]) }
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        run { try await $0.bulkAddTag(tag, doctype: doctype, names: Array(selection)) }
    }

    private func run(_ operation: @escaping (WriteSession) async throws -> Void) {
        guard let session = model.writeSession else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await operation(session)
                selection = []
                onDone()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
