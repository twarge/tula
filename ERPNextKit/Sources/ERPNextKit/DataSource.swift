import Foundation

/// A public Desk workspace (sidebar module page).
public struct WorkspaceInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var title: String
    public var icon: String?

    public init(name: String, title: String, icon: String? = nil) {
        self.name = name
        self.title = title
        self.icon = icon
    }

    public var id: String { name }
}

/// One hit from Frappe's global search.
public struct GlobalSearchHit: Sendable, Hashable, Identifiable {
    public var doctype: String
    public var name: String
    public var content: String?

    public init(doctype: String, name: String, content: String? = nil) {
        self.doctype = doctype
        self.name = name
        self.content = content
    }

    public var id: String { "\(doctype)/\(name)" }
}

/// A Desk Number Card evaluated server-side.
public struct NumberCardValue: Sendable, Hashable {
    public let label: String
    public let value: FrappeValue

    public init(label: String, value: FrappeValue) {
        self.label = label
        self.value = value
    }
}

/// A Desk Dashboard Chart's data, ready for native charting.
public struct DashboardChartData: Sendable, Hashable, Identifiable {
    public struct Dataset: Sendable, Hashable {
        public let name: String
        public let values: [Double]

        public init(name: String, values: [Double]) {
            self.name = name
            self.values = values
        }
    }

    public let name: String
    public let label: String
    /// Desk chart type: Line, Bar, Percentage, Pie, Donut, Heatmap.
    public let chartStyle: String
    public let labels: [String]
    public let datasets: [Dataset]

    public init(
        name: String, label: String, chartStyle: String, labels: [String],
        datasets: [Dataset]
    ) {
        self.name = name
        self.label = label
        self.chartStyle = chartStyle
        self.labels = labels
        self.datasets = datasets
    }

    public var id: String { name }
}

/// Counts for one linked DocType on a form dashboard: the total number of
/// linked documents, and how many are "open" (Desk's orange badge). For
/// internal links the server also resolves the referenced names.
public struct LinkCount: Sendable, Hashable {
    public var total: Int?
    public var open: Int?
    public var names: [String]?

    public init(total: Int? = nil, open: Int? = nil, names: [String]? = nil) {
        self.total = total
        self.open = open
        self.names = names
    }
}

/// One transition of a Desk Workflow (fully metadata-driven).
public struct WorkflowTransition: Sendable, Hashable {
    public let state: String
    public let action: String
    public let nextState: String

    public init(state: String, action: String, nextState: String) {
        self.state = state
        self.action = action
        self.nextState = nextState
    }
}

public struct WorkflowInfo: Sendable, Hashable {
    public let name: String
    /// Field on the document holding the workflow state.
    public let stateField: String
    public let transitions: [WorkflowTransition]

    public init(name: String, stateField: String, transitions: [WorkflowTransition]) {
        self.name = name
        self.stateField = stateField
        self.transitions = transitions
    }

    /// Ordered, de-duplicated actions available from a state.
    public func actions(fromState state: String) -> [String] {
        var seen = Set<String>()
        return transitions.filter { $0.state == state }.compactMap { transition in
            seen.insert(transition.action).inserted ? transition.action : nil
        }
    }
}

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
    /// The server's Query/Script reports (the Report DocType).
    func reports() async throws -> [ReportInfo]
    /// Public Desk workspaces, in sidebar order.
    func workspaces() async throws -> [WorkspaceInfo]
    /// Frappe global search ("awesomebar") hits.
    func globalSearch(query: String) async throws -> [GlobalSearchHit]
    /// Raw bytes of a server-stored file (attachment paths only).
    func fileData(path: String) async throws -> Data
    /// A Desk Number Card's current value.
    func numberCardValue(cardName: String) async throws -> NumberCardValue?
    /// A Desk Dashboard Chart's series data.
    func dashboardChart(name: String) async throws -> DashboardChartData?
    /// Linked-document counts for a document's dashboard, keyed by DocType
    /// (Desk's batched get_open_count).
    func openCounts(doctype: String, name: String) async throws -> [String: LinkCount]?
    /// The signed-in user's identifier (email), when the source knows it.
    func loggedUser() async throws -> String?
    /// Whether `user` follows the document (nil when unknown).
    func isFollowing(doctype: String, name: String, user: String) async throws -> Bool?
    /// The active Workflow for a DocType, if any.
    func workflow(for doctype: String) async throws -> WorkflowInfo?
    /// The `__onload` payload Desk receives with a document (party
    /// dashboard stats, etc.); nil when the source has none.
    func documentOnload(doctype: String, name: String) async throws -> [String: FrappeValue]?
    /// The Desk client script for a report; its filters are parsed from this.
    func reportScript(name: String) async throws -> String?
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

    public func reports() async throws -> [ReportInfo] {
        []
    }

    public func workspaces() async throws -> [WorkspaceInfo] {
        []
    }

    public func globalSearch(query: String) async throws -> [GlobalSearchHit] {
        []
    }

    public func fileData(path: String) async throws -> Data {
        throw ERPNextError(message: "Files aren't available for this data source.")
    }

    public func numberCardValue(cardName: String) async throws -> NumberCardValue? {
        nil
    }

    public func dashboardChart(name: String) async throws -> DashboardChartData? {
        nil
    }

    public func openCounts(doctype: String, name: String) async throws -> [String: LinkCount]? {
        nil
    }

    public func loggedUser() async throws -> String? {
        nil
    }

    public func isFollowing(doctype: String, name: String, user: String) async throws -> Bool? {
        nil
    }

    public func workflow(for doctype: String) async throws -> WorkflowInfo? {
        nil
    }

    public func documentOnload(doctype: String, name: String) async throws
        -> [String: FrappeValue]? {
        nil
    }

    public func reportScript(name: String) async throws -> String? {
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

    public func reports() async throws -> [ReportInfo] {
        let data = try await client.data(
            for: .resourceList(
                doctype: "Report",
                fields: ["name", "report_type", "ref_doctype", "module"],
                filters: [
                    ListFilter("disabled", "=", .int(0)),
                    ListFilter(
                        "report_type", "in",
                        .array([.string("Query Report"), .string("Script Report")])),
                ],
                orderBy: "name asc", limitStart: 0, limitPageLength: 500))
        return try Document.list(from: data).map { doc in
            ReportInfo(
                name: doc.name,
                reportType: doc["report_type"]?.nonEmptyString ?? "Script Report",
                refDoctype: doc["ref_doctype"]?.nonEmptyString,
                module: doc["module"]?.nonEmptyString)
        }
    }

    public func fileData(path: String) async throws -> Data {
        try await client.data(for: .file(path: path))
    }

    public func loggedUser() async throws -> String? {
        let data = try await client.data(for: .method(.loggedUser, parameters: [:]))
        return try FrappeValue.decode(from: data).objectValue?["message"]?.nonEmptyString
    }

    public func isFollowing(doctype: String, name: String, user: String) async throws -> Bool? {
        let data = try await client.data(
            for: .method(
                .isFollowed,
                parameters: ["doctype": doctype, "doc_name": name, "user": user]))
        return try FrappeValue.decode(from: data).objectValue?["message"]?.boolValue
    }

    public func openCounts(doctype: String, name: String) async throws -> [String: LinkCount]? {
        let data = try await client.data(
            for: .method(.openCount, parameters: ["doctype": doctype, "name": name]))
        return Self.parseOpenCounts(data)
    }

    /// `get_open_count` has two dialects: v13 returns `count` as a flat array
    /// of `{name, open_count, count}`; v14+ returns an object with
    /// `external_links_found` (`{doctype, count, open_count}` — `count` is
    /// the string "?" on a statement timeout) and `internal_links_found`
    /// (`{doctype, count, names}`).
    static func parseOpenCounts(_ data: Data) -> [String: LinkCount]? {
        guard let root = try? FrappeValue.decode(from: data).objectValue,
            let count = root["message"]?.objectValue?["count"]
        else { return nil }
        var counts: [String: LinkCount] = [:]
        if let entries = count.arrayValue {
            for entry in entries {
                guard let dict = entry.objectValue,
                    let doctype = dict["name"]?.nonEmptyString ?? dict["doctype"]?.nonEmptyString
                else { continue }
                counts[doctype] = LinkCount(
                    total: dict["count"]?.intValue, open: dict["open_count"]?.intValue)
            }
        } else if let object = count.objectValue {
            for entry in object["external_links_found"]?.arrayValue ?? [] {
                guard let dict = entry.objectValue,
                    let doctype = dict["doctype"]?.nonEmptyString
                else { continue }
                counts[doctype] = LinkCount(
                    total: dict["count"]?.intValue, open: dict["open_count"]?.intValue)
            }
            for entry in object["internal_links_found"]?.arrayValue ?? [] {
                guard let dict = entry.objectValue,
                    let doctype = dict["doctype"]?.nonEmptyString
                else { continue }
                counts[doctype] = LinkCount(
                    total: dict["count"]?.intValue,
                    open: dict["open_count"]?.intValue,
                    names: dict["names"]?.arrayValue?.compactMap(\.nonEmptyString))
            }
        }
        return counts.isEmpty ? nil : counts
    }

    public func documentOnload(doctype: String, name: String) async throws
        -> [String: FrappeValue]? {
        let data = try await client.data(
            for: .method(.getDoc, parameters: ["doctype": doctype, "name": name]))
        guard let root = try FrappeValue.decode(from: data).objectValue else { return nil }
        let docs =
            root["docs"]?.arrayValue ?? root["message"]?.objectValue?["docs"]?.arrayValue
        return docs?.first?.objectValue?["__onload"]?.objectValue
    }

    public func workflow(for doctype: String) async throws -> WorkflowInfo? {
        let matches = try await list(
            "Workflow", fields: ["name", "workflow_state_field"],
            filters: [
                ListFilter("document_type", "=", .string(doctype)),
                ListFilter("is_active", "=", .int(1)),
            ],
            orderBy: nil, limitStart: 0, limitPageLength: 1)
        guard let match = matches.first else { return nil }
        let doc = try await document("Workflow", name: match.name)
        let transitions = (doc.raw["transitions"]?.arrayValue ?? []).compactMap {
            row -> WorkflowTransition? in
            guard let dict = row.objectValue,
                let state = dict["state"]?.nonEmptyString,
                let action = dict["action"]?.nonEmptyString,
                let next = dict["next_state"]?.nonEmptyString
            else { return nil }
            return WorkflowTransition(state: state, action: action, nextState: next)
        }
        return WorkflowInfo(
            name: doc.name,
            stateField: doc["workflow_state_field"]?.nonEmptyString ?? "workflow_state",
            transitions: transitions)
    }

    public func numberCardValue(cardName: String) async throws -> NumberCardValue? {
        // Desk evaluates a card by posting the card document to get_result;
        // the same call works as a GET with the doc as a JSON parameter.
        let card = try await document("Number Card", name: cardName)
        let docJSON = try FrappeValue.object(card.raw).encodedJSONString()
        let data = try await client.data(
            for: .method(.numberCardResult, parameters: ["doc": docJSON]))
        guard let root = try FrappeValue.decode(from: data).objectValue else { return nil }
        return NumberCardValue(
            label: card["label"]?.nonEmptyString ?? cardName,
            value: root["message"] ?? .null)
    }

    public func dashboardChart(name: String) async throws -> DashboardChartData? {
        let chartDoc = try? await document("Dashboard Chart", name: name)
        let data = try await client.data(
            for: .method(
                .dashboardChartGet, parameters: ["chart_name": name, "refresh": "1"]))
        guard let root = try FrappeValue.decode(from: data).objectValue,
            let message = root["message"]?.objectValue
        else { return nil }
        let labels = (message["labels"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let datasets = (message["datasets"]?.arrayValue ?? []).compactMap {
            entry -> DashboardChartData.Dataset? in
            guard let dict = entry.objectValue else { return nil }
            return DashboardChartData.Dataset(
                name: dict["name"]?.nonEmptyString ?? "Values",
                values: (dict["values"]?.arrayValue ?? []).map { $0.doubleValue ?? 0 })
        }
        guard !labels.isEmpty, !datasets.isEmpty else { return nil }
        return DashboardChartData(
            name: name,
            label: chartDoc?["chart_name"]?.nonEmptyString ?? name,
            chartStyle: chartDoc?["type"]?.nonEmptyString ?? "Bar",
            labels: labels, datasets: datasets)
    }

    public func workspaces() async throws -> [WorkspaceInfo] {
        let data = try await client.data(
            for: .resourceList(
                doctype: "Workspace",
                fields: ["name", "title", "icon"],
                filters: [ListFilter("public", "=", .int(1))],
                orderBy: "sequence_id asc", limitStart: 0, limitPageLength: 100))
        return try Document.list(from: data).map { doc in
            WorkspaceInfo(
                name: doc.name,
                title: doc["title"]?.nonEmptyString ?? doc.name,
                icon: doc["icon"]?.nonEmptyString)
        }
    }

    public func globalSearch(query: String) async throws -> [GlobalSearchHit] {
        let data = try await client.data(
            for: .method(
                .globalSearch, parameters: ["text": query, "limit": "20"]))
        guard let root = try FrappeValue.decode(from: data).objectValue else { return [] }
        let hits = root["message"]?.arrayValue ?? root["results"]?.arrayValue ?? []
        return hits.compactMap { hit in
            guard let dict = hit.objectValue,
                let doctype = dict["doctype"]?.nonEmptyString,
                let name = dict["name"]?.nonEmptyString
            else { return nil }
            return GlobalSearchHit(
                doctype: doctype, name: name,
                content: dict["content"]?.nonEmptyString?.strippingSimpleHTML())
        }
    }

    public func reportScript(name: String) async throws -> String? {
        let data = try await client.data(
            for: .method(.getReportScript, parameters: ["report_name": name]))
        guard let root = try FrappeValue.decode(from: data).objectValue else { return nil }
        return root["message"]?.objectValue?["script"]?.nonEmptyString
            ?? root["script"]?.nonEmptyString
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
