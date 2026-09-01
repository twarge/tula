import ERPNextKit
import Foundation

/// `Document` alone is ambiguous in app files (a system module also exports
/// one); this module-scope alias pins it to the ERPNextKit type everywhere.
typealias Document = ERPNextKit.Document

/// Every navigable destination, mirroring Desk's URL scheme
/// (`/app/query-report/X`, `/app/{doctype}`, `/app/{doctype}/{name}`).
/// Link fields anywhere in the app navigate by producing one of these.
enum Route: Hashable {
    case report(ReportDescriptor)
    /// Any server report by name (`/app/query-report/{name}`), optionally
    /// with pinned filters (drill-downs). Standard statements route to their
    /// descriptor screen; everything else gets parsed filters.
    case queryReport(name: String, extra: [String: FrappeValue])
    case reportBrowser
    case workspace(String)
    case doctypeList(String)
    case tree(String)
    /// A DocType list pre-filtered by equality filters (Dashboard-tab
    /// connection routes; may carry several, e.g. party + party_type).
    case linkedList(doctype: String, filters: [String: String])
    case document(doctype: String, name: String)

    /// Human-readable name for menus (the Go menu's History list).
    var displayTitle: String {
        switch self {
        case .report(let descriptor):
            return descriptor.title
        case .queryReport(let name, let extra):
            // Drill-downs read as their scope in the Go menu, not as a bare
            // duplicate of the plain report.
            let scope = ["account", "party", "party_account", "item_code"]
                .lazy
                .compactMap { key in
                    extra[key]?.arrayValue?.first?.nonEmptyString
                        ?? extra[key]?.nonEmptyString
                }
                .first
            return scope.map { "\(name) · \($0)" } ?? name
        case .reportBrowser:
            return "All Reports"
        case .workspace(let name):
            return name
        case .doctypeList(let doctype):
            return "\(doctype) · List"
        case .tree(let doctype):
            return "\(doctype) · Tree"
        case .linkedList(let doctype, _):
            return "\(doctype) · Filtered List"
        case .document(let doctype, let name):
            return "\(doctype) · \(name)"
        }
    }

    /// Deterministic identity for `.id()` — keeps per-screen @State scoped
    /// to one destination (dictionary description order is not stable).
    var stableID: String {
        switch self {
        case .report(let descriptor):
            return "report|\(descriptor.name)"
        case .queryReport(let name, let extra):
            let extraKey = extra.keys.sorted().map { key in
                "\(key)=\((try? extra[key]?.encodedJSONString()) ?? "")"
            }.joined(separator: "&")
            return "query|\(name)|\(extraKey)"
        case .reportBrowser:
            return "reportBrowser"
        case .workspace(let name):
            return "workspace|\(name)"
        case .doctypeList(let doctype):
            return "list|\(doctype)"
        case .tree(let doctype):
            return "tree|\(doctype)"
        case .linkedList(let doctype, let filters):
            let filterKey = filters.keys.sorted().map { "\($0)=\(filters[$0] ?? "")" }
                .joined(separator: "&")
            return "linked|\(doctype)|\(filterKey)"
        case .document(let doctype, let name):
            return "doc|\(doctype)|\(name)"
        }
    }
}
