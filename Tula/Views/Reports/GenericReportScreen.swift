import ERPNextKit
import SwiftUI

/// Runs any server report: filter definitions are parsed from the report's
/// Desk client script (`ReportFilterParser`), rendered as native chips, and
/// the result flows through the same table/chart/tiles renderer as the
/// financial statements. `extra` carries pinned drill-down filters.
struct GenericReportScreen: View {
    let reportName: String
    var extra: [String: FrappeValue] = [:]

    @Environment(AppModel.self) private var model
    @State private var definitions: [ReportFilterDefinition]?
    @State private var values: [String: String] = [:]
    @State private var seeded = false
    @State private var state: LoadState<ReportResult> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0

    var body: some View {
        VStack(spacing: 0) {
            if let definitions, !definitions.filter({ !$0.hidden }).isEmpty {
                GenericFilterBar(definitions: definitions, values: $values)
                Divider()
            }
            content
        }
        .navigationTitle(reportName)
        .toolbar {
            OpenInDeskToolbar(route: .queryReport(name: reportName, extra: [:]))
            RefreshToolbar(lastUpdated: lastUpdated) { refreshToken += 1 }
        }
        .task(id: "prepare-\(model.sourceGeneration)-\(reportName)") {
            await prepare()
        }
        .task(id: taskKey) {
            guard seeded else { return }
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Running \(reportName)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Report Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let result):
            ReportResultView(result: result, fallbackCurrency: model.fallbackCurrencyCode)
        }
    }

    private var valuesKey: String {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }

    private var taskKey: String {
        "run-\(model.sourceGeneration)-\(reportName)-\(valuesKey)-\(refreshToken)-\(seeded)"
    }

    private var cacheKey: String {
        "report|\(model.sourceGeneration)|\(reportName)|\(valuesKey)"
    }

    /// Fetch + parse the report's filter definitions once, seed defaults.
    private func prepare() async {
        guard !seeded else { return }
        await model.ensureFilterOptions()

        var definitions: [ReportFilterDefinition]
        if let cached: (value: [ReportFilterDefinition], savedAt: Date) = model.cache.screen(
            "reportdefs|\(model.sourceGeneration)|\(reportName)") {
            definitions = cached.value
        } else {
            let script = (try? await model.dataSource.reportScript(name: reportName)) ?? nil
            definitions =
                script.flatMap {
                    ReportFilterParser.definitions(
                        reportName: reportName, script: $0,
                        defaultCompany: model.filterState.company?.name)
                } ?? []
            model.cache.setScreen(
                "reportdefs|\(model.sourceGeneration)|\(reportName)", definitions)
        }

        self.definitions = definitions
        for definition in definitions where values[definition.fieldname] == nil {
            if let defaultValue = definition.defaultValue {
                values[definition.fieldname] = defaultValue
            }
        }
        seeded = true
    }

    private func load() async {
        if case .loading = state,
            let cached: (value: ReportResult, savedAt: Date) = model.cache.screen(cacheKey) {
            state = .loaded(cached.value)
            lastUpdated = cached.savedAt
        } else if case .loading = state, !model.isDemo,
            let snapshot = SessionCache.reportSnapshot(forKey: cacheKey) {
            state = .loaded(snapshot.result)
            lastUpdated = snapshot.savedAt
        }

        let missing = (definitions ?? []).filter {
            $0.required && !$0.hidden && (values[$0.fieldname] ?? "").isEmpty
                && extra[$0.fieldname] == nil
        }
        if !missing.isEmpty {
            if case .loaded = state {} else {
                state = .failed(
                    "This report needs: \(missing.map(\.label).joined(separator: ", ")). Set them in the filter bar above.")
            }
            return
        }

        do {
            var filters: [String: FrappeValue] = [:]
            for definition in definitions ?? [] {
                if let value = values[definition.fieldname], !value.isEmpty {
                    filters[definition.fieldname] = .string(value)
                } else if definition.hidden, let defaultValue = definition.defaultValue {
                    filters[definition.fieldname] = .string(defaultValue)
                }
            }
            for (key, value) in extra {
                filters[key] = value
            }
            let result = try await model.dataSource.runReport(reportName, filters: filters)
            state = .loaded(result)
            lastUpdated = Date()
            model.cache.setScreen(cacheKey, result)
            if !model.isDemo {
                SessionCache.saveReportSnapshot(result, forKey: cacheKey)
            }
        } catch {
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Chip bar for parsed report filters — same components as the list quick
/// filters, driven by `ReportFilterDefinition`s.
struct GenericFilterBar: View {
    let definitions: [ReportFilterDefinition]
    @Binding var values: [String: String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(definitions.filter { !$0.hidden }) { definition in
                    chip(for: definition)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func chip(for definition: ReportFilterDefinition) -> some View {
        switch definition.fieldtype {
        case .select where !definition.selectOptions.isEmpty:
            SelectFilterChip(
                label: definition.label, choices: definition.selectOptions,
                value: $values[definition.fieldname])
        case .check:
            SelectFilterChip(
                label: definition.label, choices: ["1", "0"],
                value: $values[definition.fieldname],
                display: { $0 == "1" ? "Yes" : "No" })
        case .date, .datetime:
            DateFilterChip(label: definition.label, value: $values[definition.fieldname])
        case .link where definition.options != nil:
            LinkFilterChip(
                field: pseudoField(for: definition), value: $values[definition.fieldname])
        default:
            TextFilterChip(
                field: pseudoField(for: definition), value: $values[definition.fieldname])
        }
    }

    private func pseudoField(for definition: ReportFilterDefinition) -> DocField {
        var raw: [String: FrappeValue] = [
            "fieldname": .string(definition.fieldname),
            "label": .string(definition.label),
            "fieldtype": .string(definition.fieldtype.rawValue),
        ]
        if let options = definition.options {
            raw["options"] = .string(options)
        }
        return DocField(raw: raw)
    }
}
