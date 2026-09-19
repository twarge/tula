import ERPNextKit
import SwiftUI

/// The awesomebar: Tula's mirror of ERPNext's main search bar. One field,
/// three suggestion categories as you type — navigation ("Purchase Invoice"
/// list), reports, and full-text document hits from Frappe's global search.
/// Reachable from the magnifying glass on every screen and ⌘F (or ⌘K). The
/// top hit is highlighted as Desk's awesomebar does; ↑/↓ move the highlight
/// without leaving the field and Return opens it.
struct OmnibarView: View {
    let onOpen: (Route) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var doctypeCatalog: [String] = []
    @State private var reportCatalog: [ReportInfo] = []
    @State private var documentHits: [GlobalSearchHit] = []
    @State private var hasSearched = false
    @State private var searchError: String?
    /// The arrow-key highlight; nil (or a vanished result) means the top hit.
    @State private var selectedID: String?
    @FocusState private var focused: Bool

    private struct Suggestion: Identifiable {
        var label: String
        var detail: String
        var systemImage: String
        var route: Route
        var id: String { "\(detail)|\(label)" }
    }

    /// One keyboard-navigable result, flattened across the three sections.
    private struct Entry {
        var id: String
        var route: Route
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search documents, lists, and reports…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onSubmit { openHighlighted() }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
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
            } else if query.isEmpty {
                Text("Jump to any list or report, or search every document.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                Spacer(minLength: 0)
            } else if navigationHits.isEmpty && reportHits.isEmpty && documentHits.isEmpty {
                Text(hasSearched ? "No matches." : "Searching…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    List {
                        if !navigationHits.isEmpty {
                            Section("Go To") {
                                ForEach(navigationHits) { row($0) }
                            }
                        }
                        if !reportHits.isEmpty {
                            Section("Reports") {
                                ForEach(reportHits) { row($0) }
                            }
                        }
                        if !documentHits.isEmpty {
                            Section("Documents") {
                                ForEach(documentHits) { documentRow($0) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        #if os(macOS)
            .frame(width: 580, height: 460)
        #else
            .presentationDetents([.large])
        #endif
        .onAppear {
            focused = true
            if let seeded = ProcessInfo.processInfo.environment["TULA_OMNIBAR_QUERY"],
                query.isEmpty {
                query = seeded
            }
        }
        .task {
            // Session-cached catalogs; the DocType universe falls back to the
            // doctypes Tula already knows when the catalog isn't readable.
            doctypeCatalog = await model.cache.doctypeNames(using: model.dataSource)
            if doctypeCatalog.isEmpty {
                doctypeCatalog = model.browseDoctypes
            }
            reportCatalog = await model.cache.reportsCatalog(using: model.dataSource)
        }
        .task(id: query) {
            selectedID = nil
            guard !query.isEmpty else {
                documentHits = []
                hasSearched = false
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            do {
                documentHits = try await model.dataSource.globalSearch(query: query)
                searchError = nil
            } catch {
                documentHits = []
                searchError = error.localizedDescription
            }
            hasSearched = true
        }
    }

    private func row(_ suggestion: Suggestion) -> some View {
        Button {
            onOpen(suggestion.route)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(suggestion.label)
                    .fontWeight(.medium)
                Spacer()
                Text(suggestion.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(highlight(suggestion.id))
    }

    private func documentRow(_ hit: GlobalSearchHit) -> some View {
        Button {
            onOpen(.document(doctype: hit.doctype, name: hit.name))
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
        .listRowBackground(highlight(hit.id))
    }

    private func highlight(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(id == highlightedID ? Color.accentColor.opacity(0.2) : .clear)
            .padding(.horizontal, 4)
    }

    /// Case-insensitive match, prefix hits ranked first — Desk's ordering.
    private func rank(_ candidates: [String]) -> [String] {
        let needle = query.lowercased()
        let matches = candidates.filter { $0.lowercased().contains(needle) }
        return matches.sorted { a, b in
            let aPrefix = a.lowercased().hasPrefix(needle)
            let bPrefix = b.lowercased().hasPrefix(needle)
            if aPrefix != bPrefix { return aPrefix }
            return a < b
        }
    }

    private var navigationHits: [Suggestion] {
        guard !query.isEmpty else { return [] }
        return rank(doctypeCatalog).prefix(5).map { doctype in
            Suggestion(
                label: doctype,
                detail: doctype == "Account" ? "Tree" : "List",
                systemImage: doctype == "Account" ? "list.bullet.indent" : "doc.text",
                route: doctype == "Account" ? .tree(doctype) : .doctypeList(doctype))
        }
    }

    private var reportHits: [Suggestion] {
        guard !query.isEmpty else { return [] }
        let byName = Dictionary(
            uniqueKeysWithValues: reportCatalog.map { ($0.name, $0) })
        return rank(reportCatalog.map(\.name)).prefix(5).map { name in
            Suggestion(
                label: name,
                detail: byName[name]?.refDoctype ?? "Report",
                systemImage: "chart.bar.doc.horizontal",
                route: .queryReport(name: name, extra: [:]))
        }
    }

    /// Every result in display order.
    private var entries: [Entry] {
        (navigationHits + reportHits).map { Entry(id: $0.id, route: $0.route) }
            + documentHits.map {
                Entry(id: $0.id, route: .document(doctype: $0.doctype, name: $0.name))
            }
    }

    private var highlightedID: String? {
        let entries = entries
        if let selectedID, entries.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return entries.first?.id
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let entries = entries
        guard !entries.isEmpty else { return .ignored }
        let current = entries.firstIndex { $0.id == highlightedID } ?? 0
        selectedID = entries[min(max(current + delta, 0), entries.count - 1)].id
        return .handled
    }

    private func openHighlighted() {
        if let entry = entries.first(where: { $0.id == highlightedID }) {
            onOpen(entry.route)
        }
    }
}

/// The persistent entry point mirroring Desk's always-visible search bar:
/// a magnifying glass on every screen's toolbar (plus ⌘F/⌘K).
struct SearchToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.omnibarRequested = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search documents, lists, and reports (⌘F)")
        }
    }
}
