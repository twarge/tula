import ERPNextKit
import SwiftUI

/// Outline view for nested-set tree DocTypes (Chart of Accounts, Cost
/// Centers, Item Groups). The whole tree is fetched in one list call and
/// assembled client-side by the conventional `parent_<doctype>` field.
struct TreeScreen: View {
    let doctype: String

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Node]> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0

    struct Node: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var isGroup: Bool
        var children: [Node]?
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading \(doctype) tree…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load \(doctype)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded(let nodes):
                if nodes.isEmpty {
                    ContentUnavailableView("No \(doctype) records", systemImage: "tray")
                } else {
                    List(nodes, children: \.children) { node in
                        NavigationLink(value: Route.document(doctype: doctype, name: node.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: node.isGroup ? "folder" : "doc.text")
                                    .foregroundStyle(node.isGroup ? Color.accentColor : .secondary)
                                Text(node.title)
                                if let subtitle = node.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(doctype)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.doctypeList(doctype)) {
                    Label("View as List", systemImage: "list.bullet")
                }
                .help("View as list")
            }
            OpenInDeskToolbar(route: .tree(doctype))
            RefreshToolbar(lastUpdated: lastUpdated) { refreshToken += 1 }
        }
        .autoRefresh(signalDoctype: doctype) { refreshToken += 1 }
        .task(id: "\(model.sourceGeneration)-\(doctype)-\(refreshToken)") {
            await load()
        }
    }

    private var parentField: String {
        "parent_" + doctype.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private func load() async {
        if case .loading = state,
            let cached: (value: [Node], savedAt: Date) = model.cache.screen(cacheKey) {
            state = .loaded(cached.value)
            lastUpdated = cached.savedAt
        }
        do {
            let bundle = try await model.cache.metaBundle(for: doctype, using: model.dataSource)
            let meta = bundle.metas.first
            var fields = ["name", parentField, "is_group", "lft"]
            if let titleField = meta?.titleField, !fields.contains(titleField) {
                fields.append(titleField)
            }
            let rows = try await model.dataSource.list(
                doctype, fields: fields, filters: [],
                orderBy: "lft asc", limitStart: 0, limitPageLength: 5000)
            let nodes = build(rows: rows, meta: meta)
            state = .loaded(nodes)
            lastUpdated = Date()
            model.cache.setScreen(cacheKey, nodes)
        } catch {
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var cacheKey: String {
        "tree|\(model.sourceGeneration)|\(doctype)"
    }

    private func build(rows: [Document], meta: DocTypeMeta?) -> [Node] {
        let byParent = Dictionary(grouping: rows) { doc in
            doc.raw[parentField]?.nonEmptyString ?? ""
        }
        let names = Set(rows.map(\.name))

        func node(for doc: Document) -> Node {
            let children = (byParent[doc.name] ?? []).map(node(for:))
            let title = meta.map { doc.title(using: $0) } ?? doc.name
            return Node(
                id: doc.name,
                title: title,
                subtitle: title == doc.name ? nil : doc.name,
                isGroup: doc.raw["is_group"]?.boolValue ?? !children.isEmpty,
                children: children.isEmpty ? nil : children)
        }

        // Roots: empty parent, or a parent outside the fetched set.
        return rows.filter { doc in
            let parent = doc.raw[parentField]?.nonEmptyString
            return parent == nil || !names.contains(parent!)
        }.map(node(for:))
    }
}
