import ERPNextKit
import SwiftUI

/// Generic query/script-report screen: filter inspector → `query_report.run`
/// → summary tiles + hierarchical table. Every financial statement (and any
/// other server report routed here) uses this one screen.
struct ReportScreen: View {
    let descriptor: ReportDescriptor
    /// Route options carried by drill-down routes. On the General Ledger they
    /// *seed* the screen's editable filter state (Desk `route_options`
    /// semantics — applied once, then the user can widen or change them); on
    /// the other statements they stay merged over the inspector's values.
    var extra: [String: FrappeValue] = [:]

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<ReportResult> = .loading
    @State private var glState: GeneralLedgerFilterState
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0
    /// The filter inspector: closed by default on iOS (a sheet on a phone);
    /// open by default on macOS, where Desk keeps report filters on screen,
    /// and remembered there across reports.
    #if os(macOS)
        @AppStorage(reportFiltersShownKey) private var showingFilters = true
    #else
        @State private var showingFilters = false
    #endif

    init(descriptor: ReportDescriptor, extra: [String: FrappeValue] = [:]) {
        self.descriptor = descriptor
        self.extra = extra
        // Route identity (`.id(route.stableID)`) folds `extra` in, so each
        // distinct drill-down gets its own freshly seeded state.
        _glState = State(initialValue: GeneralLedgerFilterState(routeOptions: extra))
    }

    private var isGeneralLedger: Bool {
        if case .dateRange = descriptor.filterStyle { return true }
        return false
    }

    private struct TaskKey: Hashable {
        var generation: Int
        var filters: FinancialFilterState
        var glFilters: GeneralLedgerFilterState
        var report: String
        var extraKey: String
        var token: Int
    }

    private var extraKey: String {
        extra.keys.sorted().map { key in
            "\(key)=\((try? extra[key]?.encodedJSONString()) ?? "")"
        }.joined(separator: "&")
    }

    var body: some View {
        content
            .inspector(isPresented: $showingFilters) {
                ReportFiltersInspector(descriptor: descriptor, glState: $glState)
            }
            .navigationTitle(descriptor.title)
            .modifier(ScopeSubtitle(text: scopeSubtitle))
            .toolbar {
                ReportFilterToolbar(
                    isFiltered: isGeneralLedger
                        ? glState.hasAdvancedFilters : model.filterState.hasAdvancedFilters,
                    isPresented: $showingFilters)
                SearchToolbar()
                PDFExportToolbar(
                    title: descriptor.title, subtitle: pdfSubtitle,
                    result: loadedResult, fallbackCurrency: model.fallbackCurrencyCode)
                OpenInDeskToolbar(
                    route: .queryReport(name: descriptor.name, extra: requestFilters),
                    placement: .demotedAction)
                RefreshToolbar(lastUpdated: lastUpdated, placement: .demotedAction) {
                    refreshToken += 1
                }
            }
            .autoRefresh(signalDoctype: descriptor.changeSignalDoctype) { refreshToken += 1 }
            .task(
                id: TaskKey(
                    generation: model.sourceGeneration,
                    filters: model.filterState,
                    glFilters: glState,
                    report: descriptor.name,
                    extraKey: extraKey,
                    token: refreshToken)
            ) {
                // Restore from the session cache, else the disk snapshot — the
                // offline tier — then refresh silently.
                if case .loading = state {
                    if let cached: (value: ReportResult, savedAt: Date) = model.cache.screen(
                        cacheKey) {
                        state = .loaded(cached.value)
                        lastUpdated = cached.savedAt
                    } else if !model.isDemo,
                        let snapshot = SessionCache.reportSnapshot(forKey: cacheKey) {
                        state = .loaded(snapshot.result)
                        lastUpdated = snapshot.savedAt
                    }
                }
                await load()
            }
    }

    private var cacheKey: String {
        "report|\(model.sourceGeneration)|\(descriptor.name)|"
            + "\(model.filterState.cacheToken)|\(extraKey)"
            + (isGeneralLedger ? "|\(glState.cacheToken)" : "")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Running \(descriptor.title)…")
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
                result: result,
                fallbackCurrency: model.fallbackCurrencyCode,
                drillRoute: drillRoute(for:column:))
        }
    }

    private func drillRoute(for row: ReportRow, column: ReportColumn?) -> Route? {
        switch descriptor.filterStyle {
        case .financialStatement:
            return statementDrill(for: row, column: column)
        case .fiscalYearRange:
            return trialBalanceDrill(for: row, column: column)
        case .dateRange:
            return nil
        }
    }

    /// P&L / Balance Sheet / Cash Flow cells drill into the General Ledger —
    /// Desk's core accountant motion, carrying the statement's own scoping
    /// (project, cost center, finance book, currency) along. The account
    /// cell (nil column) and the Total column cover the whole reporting
    /// span; a period column's cell narrows to that column's date range.
    /// Receivable/Payable accounts hand off to the AR/AP ageing reports
    /// instead, as Desk does.
    private func statementDrill(for row: ReportRow, column: ReportColumn?) -> Route? {
        guard let account = row.values["account"]?.nonEmptyString,
            !account.isQuotedTotalLabel
        else { return nil }
        if let column, !column.fieldtype.isNumeric { return nil }

        let period = column.flatMap { periodSpan(for: $0) }
        if let accountType = row.values["account_type"]?.nonEmptyString,
            accountType == "Receivable" || accountType == "Payable" {
            var options: [String: FrappeValue] = ["party_account": .string(account)]
            if let company = model.filterState.company {
                options["company"] = .string(company.name)
            }
            // AR/AP are as-of reports: the clicked column's end date, else
            // the span end (Desk always uses the span end).
            if let asOf = period?.end ?? model.filterState.effectiveDateSpan?.end {
                options["report_date"] = .string(asOf)
            }
            if let financeBook = model.filterState.financeBook {
                options["finance_book"] = .string(financeBook)
            }
            if let costCenter = model.filterState.costCenter {
                options["cost_center"] = .array([.string(costCenter)])
            }
            if let project = model.filterState.project {
                options["project"] = .array([.string(project)])
            }
            return .queryReport(
                name: accountType == "Receivable" ? "Accounts Receivable" : "Accounts Payable",
                extra: options)
        }

        var seed = GeneralLedgerFilterState()
        seed.account = account
        seed.project = model.filterState.project
        seed.costCenter = model.filterState.costCenter
        seed.financeBook = model.filterState.financeBook
        seed.presentationCurrency = model.filterState.presentationCurrency
        seed.includeDefaultBookEntries = model.filterState.includeDefaultBookEntries
        if let span = model.filterState.effectiveDateSpan {
            seed.fromDate = span.start
            seed.toDate = span.end
        }
        if let period {
            seed.fromDate = period.start
            seed.toDate = period.end
        }
        return .queryReport(name: StandardReports.generalLedger.name, extra: seed.routeOptions)
    }

    /// Trial Balance account rows drill into the General Ledger over the
    /// fiscal year. One target ties to every column: GL's own Opening,
    /// Total, and Closing rows are the TB's opening, movement, and closing
    /// figures for that account.
    private func trialBalanceDrill(for row: ReportRow, column: ReportColumn?) -> Route? {
        guard let account = row.values["account"]?.nonEmptyString,
            !account.isQuotedTotalLabel,
            let fiscalYear = model.filterState.fiscalYear
        else { return nil }
        if let column, !column.fieldtype.isNumeric { return nil }
        var seed = GeneralLedgerFilterState()
        seed.account = account
        seed.fromDate = fiscalYear.startDate
        seed.toDate = fiscalYear.endDate
        return .queryReport(name: StandardReports.generalLedger.name, extra: seed.routeOptions)
    }

    /// Maps a period column (fieldname like "mar_2025") back to its date
    /// range by recomputing the server's period list; nil for the Total
    /// column and anything unmatched, which fall back to the whole span.
    private func periodSpan(for column: ReportColumn) -> (start: String, end: String)? {
        guard column.fieldname != "total",
            let span = model.filterState.effectiveDateSpan
        else { return nil }
        let periods = FinancialPeriods.periods(
            spanStart: span.start, spanEnd: span.end,
            periodicity: model.filterState.periodicity,
            alignsFirstPeriodToMonth: model.filterState.basedOnDateRange)
        guard let period = periods.first(where: { $0.key == column.fieldname }) else {
            return nil
        }
        // Accumulated columns are cumulative from their fiscal year's start
        // (the server's reset_period_on_fy_change default), not one period.
        if model.filterState.accumulatedValues ?? descriptor.accumulatedByDefault {
            let start = model.fiscalYears.first {
                $0.startDate <= period.toDate && period.toDate <= $0.endDate
            }?.startDate ?? span.start
            return (start, period.toDate)
        }
        return (period.fromDate, period.toDate)
    }

    /// The dates the General Ledger actually runs with: explicit state, else
    /// the global fiscal-year span.
    private var glEffectiveSpan: (start: String, end: String)? {
        if let from = glState.fromDate, let to = glState.toDate { return (from, to) }
        guard let fiscalYear = model.filterState.fiscalYear else { return nil }
        return (glState.fromDate ?? fiscalYear.startDate, glState.toDate ?? fiscalYear.endDate)
    }

    private var loadedResult: ReportResult? {
        if case .loaded(let result) = state { return result }
        return nil
    }

    private var pdfSubtitle: String {
        let parts: [String?]
        if isGeneralLedger {
            parts = [
                model.filterState.company?.name,
                glState.account,
                glEffectiveSpan.map { "\($0.start) – \($0.end)" },
            ]
        } else {
            parts = [
                model.filterState.company?.name,
                model.filterState.basedOnDateRange
                    ? model.filterState.effectiveDateSpan.map { "\($0.start) – \($0.end)" }
                    : [
                        model.filterState.fiscalYear?.name,
                        model.filterState.toFiscalYear?.name,
                    ].compactMap { $0 }.joined(separator: " – "),
            ]
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The current filter selection under the title, since the filters live
    /// in an inspector that may be closed.
    private var scopeSubtitle: String {
        [pdfSubtitle, descriptor.usesPeriodicity ? model.filterState.periodicity.rawValue : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The filters the report runs with — also what Open in Desk carries,
    /// so Desk opens with the same selection.
    private var requestFilters: [String: FrappeValue] {
        var filters = descriptor.filters(for: model.filterState)
        if isGeneralLedger {
            glState.apply(to: &filters)
        } else {
            for (key, value) in extra {
                filters[key] = value
            }
        }
        return filters
    }

    private func load() async {
        // Keep showing current content during a refresh; only blank to a
        // spinner when there's nothing on screen yet.
        if case .loaded = state {} else { state = .loading }
        await model.ensureFilterOptions()
        if let optionsError = model.filterOptionsError {
            state = .failed(optionsError)
            return
        }
        do {
            let result = try await model.dataSource.runReport(
                descriptor.name, filters: requestFilters)
            state = .loaded(result)
            lastUpdated = Date()
            model.cache.setScreen(cacheKey, result)
            if !model.isDemo {
                SessionCache.saveReportSnapshot(result, forKey: cacheKey)
            }
        } catch {
            // Keep the cached/snapshot content on refresh failure (offline);
            // only surface errors when there's nothing to show.
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// The toolbar's Filters button, which toggles the screen's filter
/// inspector (`ReportFiltersInspector`, `GenericReportFiltersInspector`).
struct ReportFilterToolbar: ToolbarContent {
    /// Fills the icon when anything beyond the defaults is applied.
    let isFiltered: Bool
    @Binding var isPresented: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isPresented.toggle()
            } label: {
                Label(
                    "Filters",
                    systemImage: isFiltered
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
            }
            .help("Show or hide filters")
        }
    }
}

/// Every report filter in one inspector — a trailing column where
/// there's room (Mac, iPad, the Duo unfolded), a sheet on a phone — so the
/// pickers, date fields, and link fields sit together. Values apply
/// immediately, and the screen's subtitle shows the selection while it's
/// closed.
struct ReportFiltersInspector: View {
    let descriptor: ReportDescriptor
    /// The General Ledger's screen-local, drill-seeded filter state;
    /// unused by the other statements.
    @Binding var glState: GeneralLedgerFilterState
    @Environment(AppModel.self) private var model

    private var isGeneralLedger: Bool {
        if case .dateRange = descriptor.filterStyle { return true }
        return false
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.companies.isEmpty {
                    labeled("Company") {
                        Picker("Company", selection: $model.filterState.company) {
                            ForEach(model.companies) { company in
                                Text(company.name).tag(Optional(company))
                            }
                        }
                        .labelsHidden()
                    }
                }
                if isGeneralLedger {
                    // Desk's GL bar: an explicit date range (the fiscal
                    // year is only the default span) plus the account, so
                    // seeded drill-down filters stay visible and editable.
                    labeled("From Date") {
                        wireDatePicker(glDateSource(\.fromDate, fallback: \.startDate))
                    }
                    labeled("To Date") {
                        wireDatePicker(glDateSource(\.toDate, fallback: \.endDate))
                    }
                    labeled("Account") {
                        LinkSuggestField(
                            doctype: "Account", text: optionalBinding($glState.account))
                    }
                } else if !model.fiscalYears.isEmpty {
                    labeled("Fiscal Year") {
                        Picker("Fiscal Year", selection: $model.filterState.fiscalYear) {
                            ForEach(model.fiscalYears) { year in
                                Text(year.name).tag(Optional(year))
                            }
                        }
                        .labelsHidden()
                    }
                }
                if descriptor.usesPeriodicity {
                    labeled("Periodicity") {
                        Picker("Periodicity", selection: $model.filterState.periodicity) {
                            ForEach(Periodicity.allCases) { periodicity in
                                Text(periodicity.rawValue).tag(periodicity)
                            }
                        }
                        .labelsHidden()
                    }
                }
                if isGeneralLedger {
                    Divider()
                    GeneralLedgerAdvancedFields(state: $glState)
                } else if descriptor.usesPeriodicity {
                    Divider()
                    AdvancedReportFields(descriptor: descriptor)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .reportFilterInspectorPresentation()
    }

    /// Effective GL dates: explicit state, else the global fiscal year's
    /// bound — editing writes the explicit date.
    private func glDateSource(
        _ keyPath: WritableKeyPath<GeneralLedgerFilterState, String?>,
        fallback: KeyPath<FiscalYear, String>
    ) -> Binding<String?> {
        Binding(
            get: {
                glState[keyPath: keyPath]
                    ?? model.filterState.fiscalYear?[keyPath: fallback]
            },
            set: { glState[keyPath: keyPath] = $0 })
    }
}

/// Where the macOS report and tree screens remember whether the filter
/// inspector is open.
let reportFiltersShownKey = "reportFiltersShown"

extension View {
    /// Shared by the report filter inspectors: a column where there's
    /// room, and as a phone sheet a half-height rest with the report still
    /// live behind it, so each change shows as it's made.
    func reportFilterInspectorPresentation() -> some View {
        inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            #if !os(macOS)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            #endif
    }
}

/// `navigationSubtitle` under the title: iOS 26+, and the window subtitle on
/// macOS.
struct ScopeSubtitle: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                // Never empty: a subtitle that appears after first layout
                // (filters still loading) leaves the bar at its old height
                // and clips the top of the large title.
                content.navigationSubtitle(text.isEmpty ? " " : text)
            } else {
                content
            }
        #else
            content.navigationSubtitle(text)
        #endif
    }
}

/// Desk's remaining General Ledger scoping filters, below the date range and
/// account in the filter inspector. Values apply immediately.
struct GeneralLedgerAdvancedFields: View {
    @Binding var state: GeneralLedgerFilterState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("Project") {
                LinkSuggestField(
                    doctype: "Project", text: optionalBinding($state.project))
            }
            if !state.additionalAccounts.isEmpty || !state.additionalProjects.isEmpty {
                // A drill link scoped to several accounts/projects: the
                // Account field edits the first, the rest are listed here so
                // nothing is pinned out of sight.
                labeled("Also In Scope") {
                    VStack(alignment: .leading, spacing: 4) {
                        if !state.additionalAccounts.isEmpty {
                            Text(
                                "\(state.additionalAccounts.count) more account\(state.additionalAccounts.count == 1 ? "" : "s"): "
                                    + state.additionalAccounts.joined(separator: ", "))
                        }
                        if !state.additionalProjects.isEmpty {
                            Text(
                                "\(state.additionalProjects.count) more project\(state.additionalProjects.count == 1 ? "" : "s"): "
                                    + state.additionalProjects.joined(separator: ", "))
                        }
                        Button("Clear") {
                            state.additionalAccounts = []
                            state.additionalProjects = []
                        }
                        .controlSize(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            labeled("Cost Center") {
                LinkSuggestField(
                    doctype: "Cost Center", text: optionalBinding($state.costCenter))
            }
            labeled("Finance Book") {
                LinkSuggestField(
                    doctype: "Finance Book", text: optionalBinding($state.financeBook))
            }
            labeled("Currency") {
                LinkSuggestField(
                    doctype: "Currency",
                    text: optionalBinding($state.presentationCurrency))
            }

            Divider()

            labeled("Group By") {
                Picker("Group By", selection: $state.categorizeBy) {
                    ForEach(
                        GeneralLedgerFilterState.categorizeChoices, id: \.self
                    ) { choice in
                        Text(choice).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Toggle(
                "Include Default FB Entries",
                isOn: $state.includeDefaultBookEntries)

            HStack {
                Spacer()
                Button("Reset") {
                    state = GeneralLedgerFilterState()
                }
                .disabled(state == GeneralLedgerFilterState())
            }
        }
    }
}

/// The rest of Desk's financial-statement filter set (finance book,
/// presentation currency, cost center, project, fiscal-year span or date
/// range, and the two checkboxes), below the inspector's pickers. Values
/// apply immediately — the report task re-runs on every state change.
struct AdvancedReportFields: View {
    let descriptor: ReportDescriptor

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $model.filterState.basedOnDateRange) {
                Text("Fiscal Year").tag(false)
                Text("Date Range").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.filterState.basedOnDateRange {
                labeled("From Date") {
                    wireDatePicker($model.filterState.periodStartDate)
                }
                labeled("To Date") {
                    wireDatePicker($model.filterState.periodEndDate)
                }
            } else {
                labeled("To Fiscal Year") {
                    Picker(
                        "To Fiscal Year",
                        selection: Binding(
                            get: {
                                model.filterState.toFiscalYear
                                    ?? model.filterState.fiscalYear
                            },
                            set: { year in
                                model.filterState.toFiscalYear =
                                    year == model.filterState.fiscalYear ? nil : year
                            })
                    ) {
                        ForEach(model.fiscalYears) { year in
                            Text(year.name).tag(Optional(year))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Divider()

            labeled("Finance Book") {
                LinkSuggestField(
                    doctype: "Finance Book",
                    text: optionalBinding($model.filterState.financeBook))
            }
            labeled("Currency") {
                LinkSuggestField(
                    doctype: "Currency",
                    text: optionalBinding($model.filterState.presentationCurrency))
            }
            labeled("Cost Center") {
                LinkSuggestField(
                    doctype: "Cost Center",
                    text: optionalBinding($model.filterState.costCenter))
            }
            labeled("Project") {
                LinkSuggestField(
                    doctype: "Project",
                    text: optionalBinding($model.filterState.project))
            }

            Divider()

            Toggle(
                "Accumulated Values",
                isOn: Binding(
                    get: {
                        model.filterState.accumulatedValues
                            ?? descriptor.accumulatedByDefault
                    },
                    set: { on in
                        model.filterState.accumulatedValues =
                            on == descriptor.accumulatedByDefault ? nil : on
                    }))
            Toggle(
                "Include Default FB Entries",
                isOn: $model.filterState.includeDefaultBookEntries)

            HStack {
                Spacer()
                Button("Reset") {
                    model.filterState.basedOnDateRange = false
                    model.filterState.periodStartDate = nil
                    model.filterState.periodEndDate = nil
                    model.filterState.toFiscalYear = nil
                    model.filterState.financeBook = nil
                    model.filterState.presentationCurrency = nil
                    model.filterState.costCenter = nil
                    model.filterState.project = nil
                    model.filterState.accumulatedValues = nil
                    model.filterState.includeDefaultBookEntries = true
                }
                .disabled(!model.filterState.hasAdvancedFilters)
            }
        }
    }
}

/// Caption-above-control layout shared by the report filter inspectors.
func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
        content()
    }
}

/// A wire-format ("2025-03-31") date field, shared by the report filter
/// inspectors.
func wireDatePicker(_ source: Binding<String?>) -> some View {
    DatePicker(
        "",
        selection: Binding(
            get: {
                ValueFormatting.wireDateValue(source.wrappedValue) ?? Date()
            },
            set: { source.wrappedValue = ValueFormatting.wireDateString($0) }),
        displayedComponents: [.date]
    )
    .labelsHidden()
    .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
    .fixedSize()
}

/// Empty string ↔ nil bridge for the link fields.
func optionalBinding(_ source: Binding<String?>) -> Binding<String> {
    Binding(
        get: { source.wrappedValue ?? "" },
        set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
}

struct SummaryTilesView: View {
    let items: [ReportSummaryItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            ValueFormatting.string(
                                for: item.value, fieldtype: item.datatype,
                                currencyCode: item.currency)
                        )
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(
                            item.indicator.flatMap(Color.init(indicatorName:)) ?? .primary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}
