import ERPNextKit
import SwiftUI

/// Generic query/script-report screen: native filter bar → `query_report.run`
/// → summary tiles + hierarchical table. Every financial statement (and any
/// other server report routed here) uses this one screen.
struct ReportScreen: View {
    let descriptor: ReportDescriptor
    /// Pinned filters carried by drill-down routes; merged over the filter
    /// bar's values, so e.g. GL arrives scoped to one account.
    var extra: [String: FrappeValue] = [:]

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<ReportResult> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0
    @State private var pdfURL: URL?

    private struct TaskKey: Hashable {
        var generation: Int
        var filters: FinancialFilterState
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
        VStack(spacing: 0) {
            FilterBar(descriptor: descriptor)
            Divider()
            content
        }
        .navigationTitle(descriptor.title)
        .toolbar {
            SearchToolbar()
            PDFExportToolbar(url: pdfURL)
            OpenInDeskToolbar(route: .report(descriptor))
            RefreshToolbar(lastUpdated: lastUpdated) { refreshToken += 1 }
        }
        .autoRefresh(signalDoctype: descriptor.changeSignalDoctype) { refreshToken += 1 }
        .task(
            id: TaskKey(
                generation: model.sourceGeneration,
                filters: model.filterState,
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
                drillRoute: drillRoute(for:))
        }
    }

    /// P&L / Balance Sheet / Cash Flow account rows drill into the General
    /// Ledger for that account over the selected period — Desk's core
    /// accountant motion.
    private func drillRoute(for row: ReportRow) -> Route? {
        guard case .financialStatement = descriptor.filterStyle else { return nil }
        guard let account = row.values["account"]?.nonEmptyString,
            !account.isQuotedTotalLabel
        else { return nil }
        var extra: [String: FrappeValue] = [
            "account": .array([.string(account)]),
            "group_by": .string("Group by Voucher (Consolidated)"),
        ]
        if let company = model.filterState.company {
            extra["company"] = .string(company.name)
        }
        if let span = model.filterState.effectiveDateSpan {
            extra["from_date"] = .string(span.start)
            extra["to_date"] = .string(span.end)
        }
        return .queryReport(name: StandardReports.generalLedger.name, extra: extra)
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
            var filters = descriptor.filters(for: model.filterState)
            for (key, value) in extra {
                filters[key] = value
            }
            let result = try await model.dataSource.runReport(descriptor.name, filters: filters)
            state = .loaded(result)
            lastUpdated = Date()
            model.cache.setScreen(cacheKey, result)
            if !model.isDemo {
                SessionCache.saveReportSnapshot(result, forKey: cacheKey)
            }
            pdfURL = ReportPDF.render(
                title: descriptor.title,
                subtitle: [
                    model.filterState.company?.name,
                    model.filterState.basedOnDateRange
                        ? model.filterState.effectiveDateSpan.map { "\($0.start) – \($0.end)" }
                        : [
                            model.filterState.fiscalYear?.name,
                            model.filterState.toFiscalYear?.name,
                        ].compactMap { $0 }.joined(separator: " – "),
                ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                result: result, fallbackCurrency: model.fallbackCurrencyCode)
        } catch {
            // Keep the cached/snapshot content on refresh failure (offline);
            // only surface errors when there's nothing to show.
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Native pickers standing in for the report's Desk filter bar.
// NOTE: keep this bar free of Text siblings next to the menu pickers — on the
// current iOS beta SDK any Text in that HStack corrupts the whole screen's
// layout. The "Updated" stamp therefore lives in the macOS toolbar only
// (RefreshToolbar); iOS relies on the refresh button + auto-refresh.
struct FilterBar: View {
    let descriptor: ReportDescriptor
    @Environment(AppModel.self) private var model
    @State private var showingAdvanced = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            if !model.companies.isEmpty {
                Picker("Company", selection: $model.filterState.company) {
                    ForEach(model.companies) { company in
                        Text(company.name).tag(Optional(company))
                    }
                }
                .fixedSize()
            }
            if !model.fiscalYears.isEmpty {
                Picker("Fiscal Year", selection: $model.filterState.fiscalYear) {
                    ForEach(model.fiscalYears) { year in
                        Text(year.name).tag(Optional(year))
                    }
                }
                .fixedSize()
            }
            if descriptor.usesPeriodicity {
                Picker("Periodicity", selection: $model.filterState.periodicity) {
                    ForEach(Periodicity.allCases) { periodicity in
                        Text(periodicity.rawValue).tag(periodicity)
                    }
                }
                .fixedSize()
            }
            if descriptor.usesPeriodicity {
                Button {
                    showingAdvanced = true
                } label: {
                    Label(
                        "More Filters",
                        systemImage: model.filterState.hasAdvancedFilters
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Finance book, currency, cost center, and more")
                .popover(isPresented: $showingAdvanced, arrowEdge: .top) {
                    AdvancedReportFilters(descriptor: descriptor)
                        #if !os(macOS)
                            .presentationDetents([.medium, .large])
                        #endif
                }
            }
            Spacer()
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The rest of Desk's financial-statement filter set (finance book,
/// presentation currency, cost center, project, fiscal-year span or date
/// range, and the two checkboxes), in a popover off the filter bar. Values
/// apply immediately — the report task re-runs on every state change, the
/// same way the inline pickers behave.
struct AdvancedReportFilters: View {
    let descriptor: ReportDescriptor

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
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
            .padding(16)
        }
        // Popovers size to intrinsic content; give the form real room on
        // every platform (the iPhone sheet adaptation is unaffected).
        .frame(minWidth: 360, minHeight: 500)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Empty string ↔ nil bridge for the link fields.
    private func optionalBinding(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func wireDatePicker(_ source: Binding<String?>) -> some View {
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
