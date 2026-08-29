import ERPNextKit
import SwiftUI

/// Browser for the server's whole report catalog (the Report DocType),
/// grouped by module. Every entry runs through the generic report screen —
/// the long tail beyond the built-in financial statements.
struct ReportBrowserScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[ReportInfo]> = .loading
    @State private var searchText = ""
    @State private var refreshToken = 0

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading reports…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Reports", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded(let reports):
                let visible = filtered(reports)
                if visible.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    list(visible)
                }
            }
        }
        .navigationTitle("Reports")
        .searchable(text: $searchText, prompt: Text("Search reports"))
        .toolbar {
            OpenInDeskToolbar(route: .reportBrowser)
            RefreshToolbar(lastUpdated: nil) { refreshToken += 1 }
        }
        .task(id: "\(model.sourceGeneration)-\(refreshToken)") {
            await load()
        }
    }

    private func filtered(_ reports: [ReportInfo]) -> [ReportInfo] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return reports }
        return reports.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.module ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func list(_ reports: [ReportInfo]) -> some View {
        let grouped = Dictionary(grouping: reports) { $0.module ?? "Other" }
        return List {
            ForEach(grouped.keys.sorted(), id: \.self) { module in
                Section(module) {
                    ForEach(grouped[module] ?? []) { report in
                        NavigationLink(value: Route.queryReport(name: report.name, extra: [:])) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.name)
                                if let refDoctype = report.refDoctype {
                                    Text(refDoctype)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        if case .loaded = state {} else {
            if case .loading = state,
                let cached: (value: [ReportInfo], savedAt: Date) = model.cache.screen(cacheKey) {
                state = .loaded(cached.value)
            }
        }
        do {
            let reports = try await model.dataSource.reports()
            state = .loaded(reports)
            model.cache.setScreen(cacheKey, reports)
        } catch {
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var cacheKey: String {
        "reports|\(model.sourceGeneration)"
    }
}
