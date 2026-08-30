import Charts
import ERPNextKit
import SwiftUI

/// A Desk workspace rendered natively: the server-defined navigation page of
/// shortcuts and link cards (Workspace DocType). Links route to the existing
/// generic screens, so whatever modules the server defines appear with zero
/// app code (ARCHITECTURE.md §12 Phase 4).
struct WorkspaceScreen: View {
    let workspaceName: String

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<Loaded> = .loading

    struct Entry: Identifiable {
        let id = UUID()
        var label: String
        var route: Route
        var systemImage: String
    }

    struct Card: Identifiable {
        let id = UUID()
        var label: String?
        var entries: [Entry]
    }

    struct Loaded {
        var shortcuts: [Entry]
        var cards: [Card]
        var numberCards: [NumberCardValue]
        var charts: [DashboardChartData]
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading workspace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Workspace", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded(let loaded):
                List {
                    if !loaded.numberCards.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(loaded.numberCards, id: \.label) { card in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(card.label)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(
                                                card.value.doubleValue?.formatted(
                                                    .number.precision(.fractionLength(0...2)))
                                                    ?? (card.value.stringValue ?? "—"))
                                                .font(.title3.weight(.semibold))
                                                .monospacedDigit()
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            .quaternary.opacity(0.5),
                                            in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }
                    ForEach(loaded.charts) { chart in
                        Section(chart.label) {
                            WorkspaceChartView(chart: chart)
                                .frame(height: 220)
                                .padding(.vertical, 6)
                        }
                    }
                    if !loaded.shortcuts.isEmpty {
                        Section("Shortcuts") {
                            ForEach(loaded.shortcuts) { entry in
                                row(entry)
                            }
                        }
                    }
                    ForEach(loaded.cards) { card in
                        Section(card.label ?? "") {
                            ForEach(card.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(workspaceName)
        .toolbar {
            OpenInDeskToolbar(route: .workspace(workspaceName))
        }
        .task(id: "\(model.sourceGeneration)-\(workspaceName)") {
            await load()
        }
    }

    private func row(_ entry: Entry) -> some View {
        NavigationLink(value: entry.route) {
            Label(entry.label, systemImage: entry.systemImage)
        }
    }

    private func load() async {
        if case .loading = state,
            let cached: (value: Loaded, savedAt: Date) = model.cache.screen(cacheKey) {
            state = .loaded(cached.value)
        }
        do {
            let doc = try await model.dataSource.document("Workspace", name: workspaceName)

            var numberCards: [NumberCardValue] = []
            for row in (doc.raw["number_cards"]?.arrayValue ?? []).prefix(6) {
                guard
                    let cardName = row.objectValue?["number_card_name"]?.nonEmptyString
                        ?? row.objectValue?["label"]?.nonEmptyString,
                    let value = try? await model.dataSource.numberCardValue(cardName: cardName)
                else { continue }
                numberCards.append(value)
            }
            var charts: [DashboardChartData] = []
            for row in (doc.raw["charts"]?.arrayValue ?? []).prefix(4) {
                guard
                    let chartName = row.objectValue?["chart_name"]?.nonEmptyString
                        ?? row.objectValue?["label"]?.nonEmptyString,
                    let chart = try? await model.dataSource.dashboardChart(name: chartName)
                else { continue }
                charts.append(chart)
            }

            let loaded = Loaded(
                shortcuts: Self.entries(from: doc.raw["shortcuts"]?.arrayValue ?? []),
                cards: Self.cards(from: doc.raw["links"]?.arrayValue ?? []),
                numberCards: numberCards,
                charts: charts)
            state = .loaded(loaded)
            model.cache.setScreen(cacheKey, loaded)
        } catch {
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var cacheKey: String {
        "workspace|\(model.sourceGeneration)|\(workspaceName)"
    }

    private static func entries(from rows: [FrappeValue]) -> [Entry] {
        rows.compactMap { row in
            guard let dict = row.objectValue,
                let linkTo = dict["link_to"]?.nonEmptyString
            else { return nil }
            return entry(
                label: dict["label"]?.nonEmptyString ?? linkTo,
                linkType: dict["type"]?.nonEmptyString ?? dict["link_type"]?.nonEmptyString,
                linkTo: linkTo,
                isQueryReport: dict["is_query_report"]?.boolValue ?? false)
        }
    }

    /// Workspace links are a flat list partitioned by "Card Break" rows.
    private static func cards(from rows: [FrappeValue]) -> [Card] {
        var cards: [Card] = []
        var current = Card(label: nil, entries: [])
        for row in rows {
            guard let dict = row.objectValue else { continue }
            if dict["hidden"]?.boolValue == true { continue }
            if dict["type"]?.nonEmptyString == "Card Break" {
                if !current.entries.isEmpty { cards.append(current) }
                current = Card(label: dict["label"]?.nonEmptyString, entries: [])
                continue
            }
            guard let linkTo = dict["link_to"]?.nonEmptyString,
                let entry = entry(
                    label: dict["label"]?.nonEmptyString ?? linkTo,
                    linkType: dict["link_type"]?.nonEmptyString,
                    linkTo: linkTo,
                    isQueryReport: dict["is_query_report"]?.boolValue ?? false)
            else { continue }
            current.entries.append(entry)
        }
        if !current.entries.isEmpty { cards.append(current) }
        return cards
    }

    private static func entry(
        label: String, linkType: String?, linkTo: String, isQueryReport: Bool
    ) -> Entry? {
        if isQueryReport || linkType == "Report" {
            return Entry(
                label: label, route: .queryReport(name: linkTo, extra: [:]),
                systemImage: "chart.bar.doc.horizontal")
        }
        if linkType == "DocType" {
            return Entry(label: label, route: .doctypeList(linkTo), systemImage: "doc.text")
        }
        // Pages, dashboards and other Desk-only surfaces are skipped.
        return nil
    }
}


/// A Desk Dashboard Chart as native Swift Charts. Line and Bar map
/// directly; other Desk styles (Pie, Donut, Percentage, Heatmap) fall back
/// to bars, which stays legible for the underlying series data.
struct WorkspaceChartView: View {
    let chart: DashboardChartData

    var body: some View {
        Chart {
            ForEach(chart.datasets, id: \.name) { dataset in
                ForEach(
                    Array(dataset.values.enumerated()), id: \.offset
                ) { index, value in
                    if chart.chartStyle == "Line" {
                        LineMark(
                            x: .value("Period", label(at: index)),
                            y: .value(dataset.name, value)
                        )
                        .foregroundStyle(by: .value("Series", dataset.name))
                    } else {
                        BarMark(
                            x: .value("Period", label(at: index)),
                            y: .value(dataset.name, value)
                        )
                        .foregroundStyle(by: .value("Series", dataset.name))
                        .position(by: .value("Series", dataset.name))
                    }
                }
            }
        }
        .chartLegend(chart.datasets.count > 1 ? .visible : .hidden)
    }

    private func label(at index: Int) -> String {
        index < chart.labels.count ? chart.labels[index] : String(index + 1)
    }
}
