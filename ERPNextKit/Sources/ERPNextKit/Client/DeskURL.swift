import Foundation

/// Builds Desk (web UI) URLs for the screens Tula renders natively — the
/// inverse of the Route↔Desk-URL mapping in ARCHITECTURE.md §5.
public enum DeskURL {
    /// Frappe's router slug: lowercased, spaces → hyphens
    /// ("Sales Invoice" → "sales-invoice").
    public static func slug(_ doctype: String) -> String {
        doctype.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// `{base}/app/{doctype-slug}` — the list view.
    public static func list(base: URL, doctype: String) -> URL {
        base.appending(path: "app").appending(component: slug(doctype))
    }

    /// `{base}/app/{doctype-slug}/{name}` — the form view.
    public static func document(base: URL, doctype: String, name: String) -> URL {
        list(base: base, doctype: doctype).appending(component: name)
    }

    /// `{base}/app/{doctype-slug}/view/tree` — the tree view.
    public static func tree(base: URL, doctype: String) -> URL {
        list(base: base, doctype: doctype).appending(path: "view/tree")
    }

    /// `{base}/app/{workspace-slug}` — a workspace page.
    public static func workspace(base: URL, name: String) -> URL {
        base.appending(path: "app").appending(component: slug(name))
    }

    /// `{base}/app/query-report/{Report Name}` — a query/script report.
    public static func queryReport(base: URL, reportName: String) -> URL {
        base.appending(path: "app/query-report").appending(component: reportName)
    }

    /// A Desk screen Tula renders natively, read back from a link in
    /// server HTML (`get_link_to_form` and friends).
    public enum Target: Hashable, Sendable {
        /// The DocType arrives as its URL slug; resolve it against the
        /// site's DocType names (`slug(_:)` isn't reversible for case).
        case document(slug: String, name: String)
        case queryReport(name: String)
    }

    /// Reads `/app/{slug}/{name}` and `/app/query-report/{name}` links —
    /// relative, or absolute on `base`'s host. Nil for anything else, which
    /// callers open in the browser.
    public static func target(of url: URL, base: URL?) -> Target? {
        if let host = url.host(percentEncoded: false) {
            guard let base, host.lowercased() == base.host(percentEncoded: false)?.lowercased()
            else { return nil }
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, parts[0] == "app", !parts[2].isEmpty else { return nil }
        if parts[1] == "query-report" {
            return .queryReport(name: parts[2])
        }
        return .document(slug: parts[1], name: parts[2])
    }
}
