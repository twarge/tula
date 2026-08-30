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
}
