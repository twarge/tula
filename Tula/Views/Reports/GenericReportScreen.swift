import ERPNextKit
import SwiftUI

/// Runs any server report: filter definitions are parsed from the report's
/// Desk client script (`ReportFilterParser`), rendered as native controls in
/// a filter inspector, and the result flows through the same
/// table/chart/tiles renderer as the financial statements. `extra`
/// carries drill-down filters, which *seed* the matching filters (Desk
/// route_options semantics — applied once, then editable); only options with
/// no matching filter stay pinned.
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
    /// The filter inspector, as on `ReportScreen`: closed by default on iOS,
    /// open by default and remembered on macOS.
    #if os(macOS)
        @AppStorage(reportFiltersShownKey) private var showingFilters = true
    #else
        @State private var showingFilters = false
    #endif

    private var visibleDefinitions: [ReportFilterDefinition] {
        (definitions ?? []).filter { !$0.hidden }
    }

    /// Open only when there's something to show: a report without filters
    /// keeps the remembered macOS preference without an empty inspector.
    private var filtersPresented: Binding<Bool> {
        Binding(
            get: { showingFilters && !visibleDefinitions.isEmpty },
            set: { showingFilters = $0 })
    }

    var body: some View {
        content
            .inspector(isPresented: filtersPresented) {
                GenericReportFiltersInspector(
                    definitions: visibleDefinitions, values: $values)
            }
            .navigationTitle(reportName)
            .modifier(ScopeSubtitle(text: pdfSubtitle ?? ""))
            .toolbar {
                if !visibleDefinitions.isEmpty {
                    ReportFilterToolbar(
                        isFiltered: visibleDefinitions.contains {
                            (values[$0.fieldname] ?? "") != ($0.defaultValue ?? "")
                        },
                        isPresented: filtersPresented)
                }
                SearchToolbar()
                PDFExportToolbar(
                    title: reportName, subtitle: pdfSubtitle,
                    result: loadedResult, fallbackCurrency: model.fallbackCurrencyCode)
                OpenInDeskToolbar(
                    route: .queryReport(name: reportName, extra: [:]), placement: .demotedAction)
                RefreshToolbar(lastUpdated: lastUpdated, placement: .demotedAction) {
                    refreshToken += 1
                }
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
                drillRoute: drillRoute(for:column:), cellAction: cellAction(for:))
        }
    }

    /// Server-declared cell sources (`link_<fieldname>` on the row): a
    /// same-report link re-seeds the filters in place; everything else
    /// navigates.
    private func cellAction(for link: ReportLink) -> ReportCellAction? {
        if case .filters(let options) = link {
            return .setFilters {
                for (key, value) in options {
                    if let seed = Self.seedString(value) { values[key] = seed }
                }
            }
        }
        return Route(link: link).map { .navigate($0) }
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

    /// The filter values as request filters. MultiSelectList filters go out as
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
                        defaultCompany: model.filterState.company?.name,
                        defaultFiscalYear: model.filterState.fiscalYear?.name)
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
        // Drill-down options seed the matching filters — visible and
        // editable in the inspector, never silently pinned.
        for definition in definitions {
            if let value = extra[definition.fieldname], let seed = Self.seedString(value) {
                values[definition.fieldname] = seed
            }
        }
        seeded = true
    }

    /// A route option as filter text (filters hold single strings; one-element
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
                let needs = missing.map(\.label).joined(separator: ", ")
                state = .failed("This report needs: \(needs). Set them under Filters.")
                // Show the empty required filters even if the inspector
                // was closed.
                showingFilters = true
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

/// The report's parsed filters as labeled controls in an inspector, like
/// the statements' `ReportFiltersInspector`. The screen's subtitle shows
/// what's applied.
struct GenericReportFiltersInspector: View {
    let definitions: [ReportFilterDefinition]
    @Binding var values: [String: String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(definitions) { definition in
                    control(for: definition)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .reportFilterInspectorPresentation()
    }

    @ViewBuilder
    private func control(for definition: ReportFilterDefinition) -> some View {
        let value = $values[definition.fieldname]
        switch definition.fieldtype {
        case .check:
            Toggle(
                definition.label,
                isOn: Binding(
                    get: { value.wrappedValue == "1" },
                    set: { value.wrappedValue = $0 ? "1" : "0" }))
        case .select where !definition.selectOptions.isEmpty:
            labeled(definition.label) {
                Picker(definition.label, selection: value) {
                    // A required Select has no "Any" — the report can't
                    // run without it.
                    if !definition.required {
                        Text("Any").tag(String?.none)
                    }
                    ForEach(choices(for: definition), id: \.self) { choice in
                        Text(choice).tag(Optional(choice))
                    }
                }
                .labelsHidden()
            }
        case .date, .datetime:
            labeled(definition.label) {
                if value.wrappedValue == nil && !definition.required {
                    Button("Choose Date") {
                        value.wrappedValue = ValueFormatting.wireDateString(Date())
                    }
                } else {
                    HStack(spacing: 8) {
                        wireDatePicker(value)
                        if !definition.required {
                            Button {
                                value.wrappedValue = nil
                            } label: {
                                Label("Clear \(definition.label)", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .link where definition.options != nil:
            labeled(definition.label) {
                CommittedFilterField(
                    label: definition.label, linkDoctype: definition.options, value: value)
            }
        default:
            labeled(definition.label) {
                CommittedFilterField(
                    label: definition.label, linkDoctype: nil, value: value)
            }
        }
    }

    /// The Select's choices, keeping a seeded value the script's list
    /// doesn't name so the picker still shows it.
    private func choices(for definition: ReportFilterDefinition) -> [String] {
        var choices = definition.selectOptions.filter { !$0.isEmpty }
        if let current = values[definition.fieldname], !current.isEmpty,
            !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }
}

/// A typed filter (Link type-ahead or free text) that applies once the
/// entry settles — a picked suggestion, Return, or leaving the field — as
/// Desk's own link filters do, rather than re-running the report on every
/// keystroke.
private struct CommittedFilterField: View {
    let label: String
    let linkDoctype: String?
    @Binding var value: String?

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let linkDoctype {
                LinkSuggestField(doctype: linkDoctype, text: $draft) { commit($0) }
            } else {
                TextField(label, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { commit(draft) }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit(draft) }
                    }
            }
        }
        .onAppear { draft = value ?? "" }
        // Drill-downs and same-report links re-seed the value in place.
        .onChange(of: value) { _, newValue in draft = newValue ?? "" }
    }

    private func commit(_ text: String) {
        let committed = text.isEmpty ? nil : text
        if committed != value { value = committed }
    }
}
