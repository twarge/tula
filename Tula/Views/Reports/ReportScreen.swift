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
        let filters = model.filterState
        return "report|\(model.sourceGeneration)|\(descriptor.name)|"
            + "\(filters.company?.name ?? "-")|\(filters.fiscalYear?.name ?? "-")|"
            + "\(filters.periodicity.rawValue)|\(extraKey)"
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
        if let fiscalYear = model.filterState.fiscalYear {
            extra["from_date"] = .string(fiscalYear.startDate)
            extra["to_date"] = .string(fiscalYear.endDate)
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
                    model.filterState.company?.name, model.filterState.fiscalYear?.name,
                ].compactMap { $0 }.joined(separator: " · "),
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
            Spacer()
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
