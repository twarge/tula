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
    case doctypeList(String)
    case document(doctype: String, name: String)
}
