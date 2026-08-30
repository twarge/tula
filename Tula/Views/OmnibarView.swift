import ERPNextKit
import SwiftUI

/// ⌘K global search: Frappe's awesomebar backend (`global_search.search`)
/// rendered as a native palette. Hits are doctype+name pairs — exactly a
/// document Route.
struct OmnibarView: View {
    let onOpen: (Route) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [GlobalSearchHit] = []
    @State private var hasSearched = false
    @State private var searchError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search everything…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onSubmit {
                        if let first = hits.first {
                            open(first)
                        }
                    }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            Divider()

            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(16)
                Spacer(minLength: 0)
            } else if hits.isEmpty {
                Text(
                    !hasSearched || query.isEmpty
                        ? "Search documents across every DocType." : "No matches."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(16)
                Spacer(minLength: 0)
            } else {
                List(hits) { hit in
                    Button {
                        open(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(hit.name)
                                    .fontWeight(.medium)
                                Text(hit.doctype)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            if let content = hit.content, !content.isEmpty {
                                Text(content)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        #if os(macOS)
            .frame(width: 560, height: 420)
        #else
            .presentationDetents([.large])
        #endif
        .onAppear { focused = true }
        .task(id: query) {
            guard !query.isEmpty else {
                hits = []
                hasSearched = false
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            do {
                hits = try await model.dataSource.globalSearch(query: query)
                searchError = nil
            } catch {
                hits = []
                searchError = error.localizedDescription
            }
            hasSearched = true
        }
    }

    private func open(_ hit: GlobalSearchHit) {
        onOpen(.document(doctype: hit.doctype, name: hit.name))
    }
}
