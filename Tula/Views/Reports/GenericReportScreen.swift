import ERPNextKit
import SwiftUI

/// Runs any server report: filter definitions are parsed from the report's
/// Desk client script (`ReportFilterParser`), rendered as native chips, and
/// the result flows through the same table/chart/tiles renderer as the
/// financial statements. `extra` carries drill-down filters, which *seed*
/// the matching chips (Desk route_options semantics — applied once, then
/// editable); only options with no matching filter stay pinned.
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
            SearchToolbar()
            PDFExportToolbar(
                title: reportName, subtitle: pdfSubtitle,
                result: loadedResult, fallbackCurrency: model.fallbackCurrencyCode)
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
            ReportResultView(
                result: result, fallbackCurrency: model.fallbackCurrencyCode,
                drillRoute: drillRoute(for:column:))
        }
    }

    /// Declarative drill-downs (ReportDrillRules): AR/AP Summary → detail,
    /// Trial Balance for Party → GL, Stock Balance → Stock Ledger, Budget
    /// Variance actuals → GL.
    private func drillRoute(for row: ReportRow, column: ReportColumn?) -> Route? {
        guard let drill = ReportDrillRules.drill(
            report: reportName, row: row.values, column: column,
            filters: wireFilters(), fiscalYears: model.fiscalYears)
        else { return nil }
        return .queryReport(name: drill.report, extra: drill.options)
    }

    private var loadedResult: ReportResult? {
        if case .loaded(let result) = state { return result }
        return nil
    }

    /// The applied filters, readable — Desk prints them under the report
    /// title, so the PDF records what it's showing.
    private var pdfSubtitle: String? {
        let parts = (definitions ?? []).filter { !$0.hidden }.compactMap {
            definition -> String? in
            guard let value = values[definition.fieldname], !value.isEmpty else { return nil }
            let display: String
            switch definition.fieldtype {
            case .check:
                display = value == "1" ? "Yes" : "No"
            case .date, .datetime:
                display = ValueFormatting.string(for: .string(value), fieldtype: .date)
            default:
                display = value
            }
            return "\(definition.label): \(display)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The chip values as request filters. MultiSelectList filters go out as
    /// one-element arrays (the server runs `in %(...)s` over them); drill
    /// options with no matching filter definition stay pinned on top.
    private func wireFilters() -> [String: FrappeValue] {
        var filters: [String: FrappeValue] = [:]
        for definition in definitions ?? [] {
            var value = values[definition.fieldname] ?? ""
            if value.isEmpty, definition.hidden {
                value = definition.defaultValue ?? ""
            }
            guard !value.isEmpty else { continue }
            filters[definition.fieldname] =
                definition.isMultiSelect ? .array([.string(value)]) : .string(value)
        }
        for (key, value) in extra
        where !(definitions ?? []).contains(where: { $0.fieldname == key }) {
            filters[key] = value
        }
        return filters
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
            // A cancelled fetch (the source generation moved while it was in
            // flight) must not be cached as "no filters" — the restarted
            // task fetches again.
            if Task.isCancelled { return }
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
        // Drill-down options seed the matching chips — visible and editable,
        // never silently pinned over the bar.
        for definition in definitions {
            if let value = extra[definition.fieldname], let seed = Self.seedString(value) {
                values[definition.fieldname] = seed
            }
        }
        seeded = true
    }

    /// A route option as chip text (chips hold single strings; one-element
    /// MultiSelectList arrays unwrap).
    private static func seedString(_ value: FrappeValue) -> String? {
        value.nonEmptyString ?? value.arrayValue?.first?.nonEmptyString
            ?? value.intValue.map(String.init)
            ?? value.doubleValue.map { String($0) }
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
            let result = try await model.dataSource.runReport(
                reportName, filters: wireFilters())
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
                display: { $0 == "1" ? "Yes" : "No" },
                allowsAny: false)
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
