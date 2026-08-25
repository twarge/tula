import ERPNextKit
import SwiftUI

/// Generic query/script-report screen: native filter bar → `query_report.run`
/// → summary tiles + hierarchical table. Every financial statement (and any
/// other server report routed here) uses this one screen.
struct ReportScreen: View {
    let descriptor: ReportDescriptor

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<ReportResult> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0

    private struct TaskKey: Hashable {
        var generation: Int
        var filters: FinancialFilterState
        var report: String
        var token: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(descriptor: descriptor)
            Divider()
            content
        }
        .navigationTitle(descriptor.title)
        .toolbar {
            RefreshToolbar(lastUpdated: lastUpdated) { refreshToken += 1 }
        }
        .autoRefresh(signalDoctype: descriptor.changeSignalDoctype) { refreshToken += 1 }
        .task(
            id: TaskKey(
                generation: model.sourceGeneration,
                filters: model.filterState,
                report: descriptor.name,
                token: refreshToken)
        ) {
            await load()
        }
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
            VStack(spacing: 0) {
                if !result.summary.isEmpty {
                    SummaryTilesView(items: result.summary)
                    Divider()
                }
                ReportTableView(
                    result: result,
                    fallbackCurrency: model.fallbackCurrencyCode)
            }
        }
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
            let filters = descriptor.filters(for: model.filterState)
            let result = try await model.dataSource.runReport(descriptor.name, filters: filters)
            state = .loaded(result)
            lastUpdated = Date()
        } catch {
            state = .failed(error.localizedDescription)
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
