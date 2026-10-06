import ERPNextKit
import SwiftUI

/// Outline view for nested-set tree DocTypes (Chart of Accounts, Cost
/// Centers, Item Groups). The whole tree is fetched in one list call and
/// assembled client-side by the conventional `parent_<doctype>` field.
/// Desk's tree filters sit in a filter inspector: the company, on trees
/// whose DocType has one, and "Show all (including disabled)".
struct TreeScreen: View {
    let doctype: String

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Node]> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0
    /// The picked company; nil follows the app's current company, as Desk
    /// defaults its tree to the user's default company.
    @State private var company: String?
    /// Off by default: Desk hides disabled records, and a disabled group's
    /// whole branch with it.
    @State private var includeDisabled = false
    @State private var filterFields = FilterFields()
    /// The filter inspector, as on the report screens.
    #if os(macOS)
        @AppStorage(reportFiltersShownKey) private var showingFilters = true
    #else
        @State private var showingFilters = false
    #endif

    init(doctype: String, company: String? = nil) {
        self.doctype = doctype
        _company = State(initialValue: company)
    }

    struct Node: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var isGroup: Bool
        var disabled = false
        var children: [Node]?
    }

    /// Which of Desk's tree filters this DocType has, from its metadata.
    struct FilterFields: Equatable {
        var company = false
        var disabled = false
        var any: Bool { company || disabled }
    }

    private var effectiveCompany: String? {
        company ?? model.filterState.company?.name
    }

    /// The tree's company filter, when it has one.
    private var companyFilter: String? {
        filterFields.company ? effectiveCompany : nil
    }

    private var filtersPresented: Binding<Bool> {
        Binding(
            get: { showingFilters && filterFields.any },
            set: { showingFilters = $0 })
    }

    var body: some View {
        content
            .inspector(isPresented: filtersPresented) {
                TreeFiltersInspector(
                    fields: filterFields,
                    company: Binding(get: { effectiveCompany }, set: { company = $0 }),
                    includeDisabled: $includeDisabled)
            }
            .navigationTitle(doctype)
            .modifier(ScopeSubtitle(text: scopeSubtitle))
            .toolbar {
                if filterFields.any {
                    ReportFilterToolbar(
                        isFiltered: includeDisabled
                            || (company != nil && company != model.filterState.company?.name),
                        isPresented: filtersPresented)
                }
                SearchToolbar()
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: Route.doctypeList(doctype)) {
                        Label("View as List", systemImage: "list.bullet")
                    }
                    .help("View as list")
                }
                OpenInDeskToolbar(
                    route: .tree(doctype, filters: companyFilter.map { ["company": $0] } ?? [:]),
                    placement: .demotedAction)
                RefreshToolbar(lastUpdated: lastUpdated, placement: .demotedAction) {
                    refreshToken += 1
                }
            }
            .autoRefresh(signalDoctype: doctype) { refreshToken += 1 }
            .task(id: "\(cacheKey)-\(refreshToken)") {
                await load()
            }
    }

    /// The selection under the title, since the inspector may be closed.
    private var scopeSubtitle: String {
        [companyFilter, includeDisabled ? "Including disabled" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
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
                    List(visible(nodes), children: \.children) { node in
                        NavigationLink(value: Route.document(doctype: doctype, name: node.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: node.isGroup ? "folder" : "doc.text")
                                    .foregroundStyle(node.isGroup ? Color.accentColor : .secondary)
                                Text(node.title)
                                    .foregroundStyle(node.disabled ? .secondary : .primary)
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
    }

    /// The tree without disabled records (and so without the branches
    /// under them) unless they're asked for.
    private func visible(_ nodes: [Node]) -> [Node] {
        guard !includeDisabled else { return nodes }
        return nodes.compactMap { node in
            guard !node.disabled else { return nil }
            var node = node
            node.children = node.children.map(visible).flatMap { $0.isEmpty ? nil : $0 }
            return node
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
            filterFields = FilterFields(
                company: meta?.field(named: "company")?.options == "Company",
                disabled: meta?.field(named: "disabled") != nil)
            var filters: [ListFilter] = []
            if filterFields.company {
                // The default company comes with the filter options; a
                // company arriving restarts this task under the new key.
                await model.ensureFilterOptions()
                if Task.isCancelled { return }
                if let companyFilter {
                    filters.append(ListFilter("company", "=", .string(companyFilter)))
                }
            }
            var fields = ["name", parentField, "is_group", "lft"]
            if let titleField = meta?.titleField, !fields.contains(titleField) {
                fields.append(titleField)
            }
            if filterFields.disabled {
                fields.append("disabled")
            }
            let key = cacheKey
            let rows = try await model.dataSource.list(
                doctype, fields: fields, filters: filters,
                orderBy: "lft asc", limitStart: 0, limitPageLength: 5000)
            // Superseded (a new company): the restarted task loads that one.
            if Task.isCancelled { return }
            let nodes = build(rows: rows, meta: meta)
            state = .loaded(nodes)
            lastUpdated = Date()
            model.cache.setScreen(key, nodes)
        } catch {
            if Task.isCancelled { return }
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var cacheKey: String {
        "tree|\(model.sourceGeneration)|\(doctype)|\(effectiveCompany ?? "")"
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
                disabled: doc.raw["disabled"]?.boolValue ?? false,
                children: children.isEmpty ? nil : children)
        }

        // Roots: empty parent, or a parent outside the fetched set.
        return rows.filter { doc in
            let parent = doc.raw[parentField]?.nonEmptyString
            return parent == nil || !names.contains(parent!)
        }.map(node(for:))
    }
}

/// Desk's tree filter bar as an inspector: the company picker and the
/// include-disabled check.
private struct TreeFiltersInspector: View {
    let fields: TreeScreen.FilterFields
    @Binding var company: String?
    @Binding var includeDisabled: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if fields.company, !model.companies.isEmpty {
                    labeled("Company") {
                        Picker("Company", selection: $company) {
                            ForEach(model.companies) { company in
                                Text(company.name).tag(Optional(company.name))
                            }
                        }
                        .labelsHidden()
                    }
                }
                if fields.disabled {
                    Toggle("Show all (including disabled)", isOn: $includeDisabled)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .reportFilterInspectorPresentation()
    }
}
