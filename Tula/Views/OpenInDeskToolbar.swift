import ERPNextKit
import SwiftUI

/// "Open in Desk": jumps from any native screen to the same page in the
/// server's web UI. Route → URL is a direct translation because the Route
/// enum mirrors Desk's URL scheme (ARCHITECTURE.md §5); report options and
/// list and tree filters become Desk's filter query string, so those
/// screens pass the filters they run with and Desk opens with the same
/// selection. Hidden in demo mode.
struct OpenInDeskToolbar: ToolbarContent {
    let route: Route
    var placement: ToolbarItemPlacement = .primaryAction

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some ToolbarContent {
        if let url = webURL {
            ToolbarItem(placement: placement) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open in Desk", systemImage: "safari")
                }
                .help("Open this view on \(url.host() ?? "the server")")
            }
        }
    }

    private var webURL: URL? {
        guard let base = model.webBaseURL else { return nil }
        switch route {
        case .report(let descriptor):
            return DeskURL.queryReport(base: base, reportName: descriptor.name)
        case .queryReport(let name, let filters):
            return DeskURL.queryReport(base: base, reportName: name, filters: filters)
        case .reportBrowser:
            return DeskURL.list(base: base, doctype: "Report")
        case .workspace(let name):
            return DeskURL.workspace(base: base, name: name)
        case .doctypeList(let doctype):
            return DeskURL.list(base: base, doctype: doctype)
        case .tree(let doctype, let filters):
            return DeskURL.tree(base: base, doctype: doctype, filters: filters)
        case .linkedList(let doctype, let filters):
            return DeskURL.list(
                base: base, doctype: doctype,
                filters: filters.keys.sorted().map { ListFilter($0, "=", .string(filters[$0]!)) })
        case .filteredList(let doctype, let conditions):
            return DeskURL.list(base: base, doctype: doctype, filters: conditions)
        case .document(let doctype, let name):
            return DeskURL.document(base: base, doctype: doctype, name: name)
        }
    }
}
