import Foundation

/// One result of a link-field autocomplete (`frappe.desk.search.search_link`).
public struct LinkOption: Sendable, Hashable, Identifiable {
    public var value: String
    public var description: String?

    public init(value: String, description: String? = nil) {
        self.value = value
        self.description = description
    }

    public var id: String { value }
}

/// Everything the UI needs from a server, as read operations only.
/// Two implementations: `LiveDataSource` (a real ERPNext site over
/// `ReadOnlyClient`) and `DemoDataSource` (bundled fixtures, no network).
public protocol DataSource: Sendable {
    var displayName: String { get }

    func ping() async throws
    func companies() async throws -> [Company]
    func fiscalYears() async throws -> [FiscalYear]
    func runReport(_ reportName: String, filters: [String: FrappeValue]) async throws -> ReportResult

    /// The DocType's metadata, its child-table DocTypes, and the user's Desk
    /// view settings that arrive in the same response (grid columns).
    func metaBundle(for doctype: String) async throws -> MetaBundle
    /// Link-field autocomplete. Declared as a requirement (not just an
    /// extension convenience) so calls through `any DataSource` dispatch to
    /// the concrete implementation — an extension-only method silently
    /// resolves to the default and returns nothing.
    func searchLink(doctype: String, query: String) async throws -> [LinkOption]
    /// Ordered column fieldnames from Desk's list settings for this DocType
    /// (the "List View Settings" document users edit via the list's gear in
    /// the web UI), or nil when none are configured.
    func listViewColumns(doctype: String) async throws -> [String]?
    /// Total matching documents (`frappe.client.get_count`), or nil when the
    /// source can't say.
    func count(_ doctype: String, filters: [ListFilter]) async throws -> Int?
    func list(
        _ doctype: String, fields: [String], filters: [ListFilter],
        orderBy: String?, limitStart: Int, limitPageLength: Int
    ) async throws -> [Document]
    func document(_ doctype: String, name: String) async throws -> Document
}

extension DataSource {
    /// Link-field autocomplete: candidate documents of `doctype` matching
    /// `query` (empty query returns the server's top suggestions). Default is
    /// empty so conformances without a search backend still compile.
    public func searchLink(doctype: String, query: String) async throws -> [LinkOption] {
        []
    }

    public func listViewColumns(doctype: String) async throws -> [String]? {
        nil
    }

    public func count(_ doctype: String, filters: [ListFilter]) async throws -> Int? {
        nil
    }

    /// Cheap change probe: the `modified` timestamp of the most recently
    /// changed row of a DocType, via a one-row GET. Every financial statement
    /// derives from GL Entry postings, so polling this for "GL Entry" is a
    /// near-free signal that any report on screen is stale. Returns nil when
    /// the source has no signal (demo mode, empty tables) — callers treat
    /// that as "never auto-refresh".
    public func latestModified(_ doctype: String) async throws -> String? {
        let rows = try await list(
            doctype, fields: ["modified"], filters: [],
            orderBy: "modified desc", limitStart: 0, limitPageLength: 1)
        return rows.first?.raw["modified"]?.nonEmptyString
    }
}

public struct LiveDataSource: DataSource {
    public let client: ReadOnlyClient

    public init(client: ReadOnlyClient) {
        self.client = client
    }

    public var displayName: String {
        client.configuration.baseURL.host() ?? client.configuration.baseURL.absoluteString
    }

    public func ping() async throws {
        _ = try await client.data(for: .method(.ping, parameters: [:]))
    }

    public func companies() async throws -> [Company] {
        let data = try await client.data(
            for: .resourceList(
                doctype: "Company",
                fields: ["name", "default_currency"],
                filters: [], orderBy: "name asc", limitStart: 0, limitPageLength: 100))
        return try Document.list(from: data).map {
            Company(
                name: $0.name,
                defaultCurrency: $0["default_currency"]?.nonEmptyString)
        }
    }

    public func fiscalYears() async throws -> [FiscalYear] {
        let data = try await client.data(
            for: .resourceList(
                doctype: "Fiscal Year",
                fields: ["name", "year_start_date", "year_end_date"],
                filters: [ListFilter("disabled", "=", .int(0))],
                orderBy: "year_start_date desc", limitStart: 0, limitPageLength: 50))
        return try Document.list(from: data).compactMap { doc in
            guard let start = doc["year_start_date"]?.nonEmptyString,
                let end = doc["year_end_date"]?.nonEmptyString
            else { return nil }
            return FiscalYear(name: doc.name, startDate: start, endDate: end)
        }
    }

    public func runReport(_ reportName: String, filters: [String: FrappeValue]) async throws
        -> ReportResult {
        let data = try await client.data(
            for: .method(
                .runQueryReport,
                parameters: [
                    "report_name": reportName,
                    "filters": try FrappeValue.object(filters).encodedJSONString(),
                    "ignore_prepared_report": "1",
                ]))
        return try ReportResult.decode(from: data)
    }

    public func metaBundle(for doctype: String) async throws -> MetaBundle {
        let data = try await client.data(
            for: .method(.getDocType, parameters: ["doctype": doctype, "with_parent": "1"]))
        return try MetaDecoder.bundle(from: data)
    }

    public func list(
        _ doctype: String, fields: [String], filters: [ListFilter],
        orderBy: String?, limitStart: Int, limitPageLength: Int
    ) async throws -> [Document] {
        let data = try await client.data(
            for: .resourceList(
                doctype: doctype, fields: fields, filters: filters,
                orderBy: orderBy, limitStart: limitStart, limitPageLength: limitPageLength))
        return try Document.list(from: data)
    }

    public func document(_ doctype: String, name: String) async throws -> Document {
        let data = try await client.data(for: .resource(doctype: doctype, name: name))
        return try Document.single(from: data)
    }

    public func searchLink(doctype: String, query: String) async throws -> [LinkOption] {
        // Primary: Desk's ranked autocomplete. Servers differ in whether this
        // succeeds for API users (permission model, version quirks), so an
        // empty or failed result falls back below rather than ending here.
        if let ranked = try? await searchLinkMethod(doctype: doctype, query: query),
            !ranked.isEmpty {
            return ranked
        }
        // Fallback: the plain list endpoint — the same call and permissions
        // every list screen uses, so wherever lists work, suggestions work.
        // Empty query → the 20 most recently modified documents.
        let filters: [ListFilter] =
            query.isEmpty ? [] : [ListFilter("name", "like", .string("%\(query)%"))]
        let docs = try await list(
            doctype, fields: ["name"], filters: filters,
            orderBy: "modified desc", limitStart: 0, limitPageLength: 20)
        return docs.map { LinkOption(value: $0.name) }
    }

    public func count(_ doctype: String, filters: [ListFilter]) async throws -> Int? {
        var parameters = ["doctype": doctype]
        if !filters.isEmpty {
            let encoded = FrappeValue.array(filters.map {
                .array([.string($0.fieldname), .string($0.op), $0.value])
            })
            parameters["filters"] = try encoded.encodedJSONString()
        }
        guard let data = try? await client.data(for: .method(.getCount, parameters: parameters))
        else { return nil }
        return try? FrappeValue.decode(from: data).objectValue?["message"]?.intValue
    }

    public func listViewColumns(doctype: String) async throws -> [String]? {
        // Missing settings, or a server that restricts reading them, simply
        // means "use the in_list_view defaults".
        guard
            let data = try? await client.data(
                for: .resource(doctype: "List View Settings", name: doctype)),
            let doc = try? Document.single(from: data)
        else { return nil }
        return Self.columns(fromListViewSettings: doc)
    }

    /// The settings document's `fields` property is a JSON string holding an
    /// array of `{"fieldname": ...}` dicts (older servers: bare strings).
    static func columns(fromListViewSettings doc: Document) -> [String]? {
        guard let raw = doc["fields"]?.nonEmptyString,
            let decoded = try? FrappeValue.decode(from: Data(raw.utf8)),
            let entries = decoded.arrayValue
        else { return nil }
        let names = entries.compactMap { entry in
            entry.objectValue?["fieldname"]?.nonEmptyString ?? entry.nonEmptyString
        }
        return names.isEmpty ? nil : names
    }

    private func searchLinkMethod(doctype: String, query: String) async throws -> [LinkOption] {
        let data = try await client.data(
            for: .method(
                .searchLink,
                parameters: ["doctype": doctype, "txt": query, "page_length": "20"]))
        guard let root = try FrappeValue.decode(from: data).objectValue else { return [] }
        let results =
            root["results"]?.arrayValue
            ?? root["message"]?.arrayValue
            ?? root["message"]?.objectValue?["results"]?.arrayValue
            ?? []
        return results.compactMap { entry in
            if let dict = entry.objectValue, let value = dict["value"]?.nonEmptyString {
                return LinkOption(
                    value: value, description: dict["description"]?.nonEmptyString)
            }
            if let value = entry.nonEmptyString {
                return LinkOption(value: value)
            }
            return nil
        }
    }
}
