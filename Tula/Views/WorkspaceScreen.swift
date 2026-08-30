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
            let loaded = Loaded(
                shortcuts: Self.entries(from: doc.raw["shortcuts"]?.arrayValue ?? []),
                cards: Self.cards(from: doc.raw["links"]?.arrayValue ?? []))
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
