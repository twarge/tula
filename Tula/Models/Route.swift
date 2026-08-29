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
    case doctypeList(String)
    case document(doctype: String, name: String)

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
        case .doctypeList(let doctype):
            return "list|\(doctype)"
        case .document(let doctype, let name):
            return "doc|\(doctype)|\(name)"
        }
    }
}
