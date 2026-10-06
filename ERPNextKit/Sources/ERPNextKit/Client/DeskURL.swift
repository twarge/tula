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

    /// `{base}/app/{doctype-slug}?{filters}` — the list view under exactly
    /// `filters`, written the way Desk writes its own list URL
    /// (`get_search_params`): equality as `field=value`, any other operator
    /// as `field=["op",value]`, a field repeated per condition. Desk replaces
    /// the list's filters with these on load; with none, `reset_filters`
    /// clears the ones Desk remembered, so the list opens unfiltered.
    public static func list(base: URL, doctype: String, filters: [ListFilter]) -> URL {
        let pairs = filters.isEmpty
            ? [("reset_filters", "1")]
            : filters.compactMap { filter -> (String, String)? in
                if filter.op == "=", let text = filter.value.stringValue,
                    !(text.hasPrefix("[") && text.hasSuffix("]")) {
                    return (filter.fieldname, text)
                }
                // Desk `JSON.parse`s values in brackets, so an equality
                // value that looks like JSON goes out operator-qualified too.
                let condition = FrappeValue.array([.string(filter.op), filter.value])
                return (try? condition.encodedJSONString()).map { (filter.fieldname, $0) }
            }
        return withQuery(list(base: base, doctype: doctype), pairs)
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

    /// `{base}/app/query-report/{Report Name}?{filters}` — a query/script
    /// report. `filters` go in the query string the way Desk bookmarks its
    /// own reports (`get_url_with_filters`), and Desk seeds each matching
    /// filter from them on load (`set_route_filters`).
    public static func queryReport(
        base: URL, reportName: String, filters: [String: FrappeValue] = [:]
    ) -> URL {
        let url = base.appending(path: "app/query-report").appending(component: reportName)
        return withQuery(
            url,
            filters.keys.sorted().compactMap { key in
                queryValue(filters[key]!).map { (key, $0) }
            })
    }

    /// `url` with `pairs` as its query string; `url` itself when empty.
    private static func withQuery(_ url: URL, _ pairs: [(String, String)]) -> URL {
        guard !pairs.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.percentEncodedQuery = pairs.map {
            "\(queryEncoded($0.0))=\(queryEncoded($0.1))"
        }.joined(separator: "&")
        return components.url ?? url
    }

    /// A filter value as Desk's query string writes it: MultiSelectList
    /// arrays as JSON (Desk `JSON.parse`s values starting with "["), checks
    /// as 1/0. Empty values are left out, as Desk leaves them out; an
    /// unchecked 0 is kept, so a check that defaults on stays off.
    private static func queryValue(_ value: FrappeValue) -> String? {
        switch value {
        case .array(let items):
            return items.isEmpty ? nil : try? value.encodedJSONString()
        case .object, .null:
            return nil
        default:
            return value.nonEmptyString
        }
    }

    /// Strict form encoding: Desk reads the query with `URLSearchParams`,
    /// which decodes "+" as a space, so only unreserved characters pass.
    private static func queryEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? text
    }

    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

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
