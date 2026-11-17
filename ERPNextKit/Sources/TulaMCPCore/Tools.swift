import ERPNextKit
import Foundation

/// One MCP tool: what the model is told about it, and what it does. Every
/// tool reads through `DataSource` and nothing else.
struct Tool: Sendable {
    let name: String
    let title: String
    let description: String
    var properties: [String: JSON] = [:]
    var required: [String] = []
    let run: @Sendable (Arguments, any DataSource) async throws -> JSON

    var listing: JSON {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map(JSON.string)),
                "additionalProperties": false,
            ],
            "annotations": [
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }

    static let all: [Tool] = [
        siteInfo, searchDoctypes, doctypeSchema, listDocuments, countDocuments, getDocument,
        search, findDocuments, listReports, reportFilters, runReport,
    ]
}

// MARK: Shared argument schemas

private func text(_ description: String) -> JSON {
    ["type": "string", "description": .string(description)]
}

private func integer(_ description: String, default value: Int, maximum: Int) -> JSON {
    [
        "type": "integer", "description": .string(description), "default": .int(value),
        "minimum": 0, "maximum": .int(maximum),
    ]
}

private let doctypeArgument = text(
    "Exact DocType name, with its spaces and capitals: \"Sales Invoice\", \"Customer\", \"GL Entry\".")

private let filtersArgument: JSON = [
    "type": "array",
    "description": """
        Conditions, all of which must hold, each as [field, operator, value]. Operators: \
        =, !=, >, <, >=, <=, like (with % wildcards), not like, in and not in (value is a \
        list), between (value is [low, high]), is (value "set" or "not set"). Dates are \
        "YYYY-MM-DD". Example: [["docstatus", "=", 1], ["posting_date", "between", \
        ["2026-01-01", "2026-03-31"]], ["customer", "like", "%Acme%"]].
        """,
    "items": ["type": "array"],
]

// MARK: Site

extension Tool {
    static let siteInfo = Tool(
        name: "get_site_info",
        title: "Site overview",
        description: """
            Which ERPNext site this is, the signed-in API user, the companies with their \
            currencies, the fiscal years with their date ranges, and today's date. Call it \
            first: most reports need a company and a fiscal year or date range.
            """
    ) { _, source in
        try await source.ping()
        var info: [String: JSON] = [
            "site": .string(source.displayName),
            "today": .string(isoDate(Date())),
        ]
        if let user = try? await source.loggedUser() { info["user"] = .string(user) }
        info["companies"] = .array(
            try await source.companies().map {
                JSON.object(["name": .string($0.name), "default_currency": $0.defaultCurrency.map(JSON.string) ?? .null])
                    .compacted
            })
        info["fiscal_years"] = .array(
            try await source.fiscalYears().map {
                ["name": .string($0.name), "start": .string($0.startDate), "end": .string($0.endDate)]
            })
        return .object(info)
    }

    static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: DocTypes

extension Tool {
    static let searchDoctypes = Tool(
        name: "search_doctypes",
        title: "Find DocTypes",
        description: """
            Finds DocTypes (ERPNext's record types) whose name contains the query, with the \
            module each belongs to. Use it to learn what a kind of record is called on this \
            site before listing it — including custom DocTypes. Child-table DocTypes \
            (is_child_table) hold the rows of a parent document and are read through it.
            """,
        properties: [
            "query": text("Part of a DocType name, e.g. \"invoice\". Leave out to list them all."),
            "module": text("Only DocTypes of this module, e.g. \"Accounts\", \"Stock\", \"Selling\"."),
            "limit": integer("Most DocTypes to return.", default: 50, maximum: 500),
        ]
    ) { arguments, source in
        var filters: [ListFilter] = []
        if let query = arguments.string("query") {
            filters.append(ListFilter("name", "like", .string("%\(query)%")))
        }
        if let module = arguments.string("module") {
            filters.append(ListFilter("module", "=", .string(module)))
        }
        let docs = try await source.list(
            "DocType", fields: ["name", "module", "istable", "issingle", "is_submittable", "custom"],
            filters: filters, orderBy: "name asc", limitStart: 0,
            limitPageLength: arguments.int("limit", default: 50, in: 1...500))
        return [
            "doctypes": .array(
                docs.map { doc in
                    var entry: [String: JSON] = ["name": .string(doc.name)]
                    if let module = doc["module"]?.nonEmptyString { entry["module"] = .string(module) }
                    if doc["istable"]?.boolValue == true { entry["is_child_table"] = true }
                    if doc["issingle"]?.boolValue == true { entry["is_single"] = true }
                    if doc["is_submittable"]?.boolValue == true { entry["is_submittable"] = true }
                    if doc["custom"]?.boolValue == true { entry["custom"] = true }
                    return .object(entry)
                })
        ]
    }

    static let doctypeSchema = Tool(
        name: "get_doctype_schema",
        title: "DocType fields",
        description: """
            The fields of a DocType: fieldname (what filters, fields and order_by use), \
            label, type, and for Link fields the DocType they point to, for Select fields \
            their choices. Child tables come with their own fields. Call it before filtering \
            or picking fields on a DocType you haven't looked at; sites add custom fields.
            """,
        properties: ["doctype": doctypeArgument],
        required: ["doctype"]
    ) { arguments, source in
        let bundle = try await source.metaBundle(for: try arguments.required("doctype"))
        guard let meta = bundle.metas.first else {
            throw ToolError("The server returned no metadata for that DocType.")
        }
        var schema: [String: JSON] = [
            "doctype": .string(meta.name),
            "fields": .array(meta.fields.compactMap(describe)),
        ]
        if let module = meta.raw["module"]?.nonEmptyString { schema["module"] = .string(module) }
        if let titleField = meta.titleField { schema["title_field"] = .string(titleField) }
        if meta.isSubmittable {
            schema["is_submittable"] = true
            schema["docstatus"] = "0 = draft, 1 = submitted, 2 = cancelled"
        }
        if meta.isSingle { schema["is_single"] = true }
        if meta.isTree { schema["is_tree"] = true }
        if meta.isTable { schema["is_child_table"] = true }
        schema["standard_fields"] = [
            "name", "owner", "creation", "modified", "modified_by", "docstatus",
        ]
        let children = bundle.childMetas
        if !children.isEmpty {
            schema["child_tables"] = .object(
                children.mapValues { .array($0.fields.compactMap(describe)) })
        }
        return .object(schema)
    }

    /// Layout breaks and buttons carry no data.
    private static let layoutTypes: Set<String> = [
        "Section Break", "Column Break", "Tab Break", "Fold", "Heading", "Button", "HTML",
    ]

    private static func describe(_ field: DocField) -> JSON? {
        let fieldtype = field.raw["fieldtype"]?.nonEmptyString ?? "Data"
        guard !field.fieldname.isEmpty, !layoutTypes.contains(fieldtype) else { return nil }
        var entry: [String: JSON] = [
            "fieldname": .string(field.fieldname),
            "label": .string(field.label),
            "fieldtype": .string(fieldtype),
        ]
        if let options = field.options {
            if fieldtype == "Select" {
                entry["choices"] = .array(field.selectChoices.map(JSON.string))
            } else {
                // Link → target DocType; Table → child DocType; Currency → currency field.
                entry["options"] = .string(options)
            }
        }
        if field.reqd { entry["required"] = true }
        if field.hidden { entry["hidden"] = true }
        if field.raw["is_custom_field"]?.boolValue == true { entry["custom"] = true }
        return .object(entry)
    }
}

// MARK: Documents

extension Tool {
    static let listDocuments = Tool(
        name: "list_documents",
        title: "List documents",
        description: """
            Lists documents of a DocType, filtered, sorted and paged. Returns the chosen \
            fields of each; without `fields`, the columns ERPNext's own list view shows. \
            Only parent-level fields can be listed or filtered — for line items, taxes and \
            other child tables, open the document with get_document. has_more says another \
            page follows (raise offset by limit). For totals over many documents, a report \
            (run_report) is usually both faster and more correct.
            """,
        properties: [
            "doctype": doctypeArgument,
            "fields": [
                "type": "array", "items": ["type": "string"],
                "description": "Fieldnames to return, e.g. [\"name\", \"customer\", \"grand_total\", \"posting_date\"].",
            ],
            "filters": filtersArgument,
            "order_by": text("Fieldname and direction, e.g. \"posting_date desc\". Default: \"modified desc\"."),
            "limit": integer("Most documents to return.", default: 20, maximum: 500),
            "offset": integer("Documents to skip, for paging.", default: 0, maximum: 10_000_000),
        ],
        required: ["doctype"]
    ) { arguments, source in
        let doctype = try arguments.required("doctype")
        let limit = arguments.int("limit", default: 20, in: 1...500)
        let offset = arguments.int("offset", default: 0, in: 0...10_000_000)
        var fields = arguments.strings("fields")
        if fields.isEmpty {
            // What Desk's list shows; a DocType whose metadata this user
            // can't read still lists by name.
            fields = (try? await source.metaBundle(for: doctype))?.metas.first?.listFieldnames ?? ["name"]
        }
        // One more than asked for, to know whether another page follows.
        let fetched = try await source.list(
            doctype, fields: fields, filters: try arguments.filters(),
            orderBy: arguments.string("order_by") ?? "modified desc",
            limitStart: offset, limitPageLength: limit + 1)
        let docs = fetched.prefix(limit)
        return [
            "doctype": .string(doctype),
            "offset": .int(offset),
            "returned": .int(docs.count),
            "has_more": .bool(fetched.count > limit),
            "documents": .array(docs.map { JSON.object($0.raw).compacted }),
        ]
    }

    static let countDocuments = Tool(
        name: "count_documents",
        title: "Count documents",
        description: "How many documents of a DocType match the filters (all of them, with none).",
        properties: ["doctype": doctypeArgument, "filters": filtersArgument],
        required: ["doctype"]
    ) { arguments, source in
        let doctype = try arguments.required("doctype")
        guard let count = try await source.count(doctype, filters: try arguments.filters()) else {
            throw ToolError(
                "The server wouldn't count \"\(doctype)\". Check the name with search_doctypes, "
                    + "the filter fields with get_doctype_schema, and that the API user may read it.")
        }
        return ["doctype": .string(doctype), "count": .int(count)]
    }

    static let getDocument = Tool(
        name: "get_document",
        title: "Read a document",
        description: """
            One whole document by its name (ID), with every field that has a value and its \
            child tables — an invoice's items and taxes, a BOM's materials. Names come from \
            list_documents, find_documents or search.
            """,
        properties: [
            "doctype": doctypeArgument,
            "name": text("The document's name (ID), e.g. \"ACC-SINV-2026-00042\"."),
        ],
        required: ["doctype", "name"]
    ) { arguments, source in
        let document = try await source.document(
            try arguments.required("doctype"), name: try arguments.required("name"))
        return .object(document.raw.mapValues(trimmingChildRows)).compacted
    }

    /// A child row repeats its parent's identity on every line.
    private static func trimmingChildRows(_ value: JSON) -> JSON {
        guard let rows = value.arrayValue else { return value }
        return .array(
            rows.map { row in
                guard var object = row.objectValue else { return row }
                for key in ["parent", "parentfield", "parenttype", "doctype"] { object[key] = nil }
                return .object(object)
            })
    }

    static let search = Tool(
        name: "search",
        title: "Search everything",
        description: """
            ERPNext's global search (the search bar in Desk): documents of any DocType whose \
            indexed text matches. Use it when you have a name, number or phrase and don't \
            know which DocType holds it. Not every DocType is indexed; if this finds \
            nothing, try find_documents on the likely DocType.
            """,
        properties: ["query": text("Words to look for.")],
        required: ["query"]
    ) { arguments, source in
        let hits = try await source.globalSearch(query: try arguments.required("query"))
        return [
            "results": .array(
                hits.map {
                    JSON.object([
                        "doctype": .string($0.doctype), "name": .string($0.name),
                        "content": $0.content.map(JSON.string) ?? .null,
                    ]).compacted
                })
        ]
    }

    static let findDocuments = Tool(
        name: "find_documents",
        title: "Find documents by name",
        description: """
            Finds documents of one DocType by a fragment of their name or title, ranked as \
            Desk's link fields rank them: "acme" → the Customer "Acme Corporation". Use it \
            to turn what a person calls something into the exact name that filters and \
            get_document need. Returns up to 20.
            """,
        properties: [
            "doctype": doctypeArgument,
            "query": text("Part of the name or title. Empty returns the server's top suggestions."),
        ],
        required: ["doctype"]
    ) { arguments, source in
        let options = try await source.searchLink(
            doctype: try arguments.required("doctype"), query: arguments.string("query") ?? "")
        return [
            "matches": .array(
                options.map {
                    JSON.object([
                        "name": .string($0.value),
                        "description": $0.description.map(JSON.string) ?? .null,
                    ]).compacted
                })
        ]
    }
}

// MARK: Reports

extension Tool {
    static let listReports = Tool(
        name: "list_reports",
        title: "List reports",
        description: """
            The site's query and script reports — Profit and Loss Statement, Balance Sheet, \
            General Ledger, Accounts Receivable, Stock Balance, Sales Analytics and the \
            rest, custom ones included — with the module and DocType each is about.
            """,
        properties: [
            "query": text("Only reports whose name, module or DocType contains this, e.g. \"stock\".")
        ]
    ) { arguments, source in
        let needle = arguments.string("query")?.lowercased()
        let reports = try await source.reports().filter { report in
            guard let needle else { return true }
            return [report.name, report.module ?? "", report.refDoctype ?? ""]
                .contains { $0.lowercased().contains(needle) }
        }
        return [
            "reports": .array(
                reports.map {
                    JSON.object([
                        "name": .string($0.name), "type": .string($0.reportType),
                        "module": $0.module.map(JSON.string) ?? .null,
                        "doctype": $0.refDoctype.map(JSON.string) ?? .null,
                    ]).compacted
                })
        ]
    }

    static let reportFilters = Tool(
        name: "get_report_filters",
        title: "Report filters",
        description: """
            The filters a report takes: fieldname, type, whether it is required, its \
            default, and the choices or linked DocType. Call it before run_report — reports \
            fail or come back empty without their required filters. For the standard \
            financial statements it also returns example_filters that run as they are.
            """,
        properties: ["report": text("Exact report name, from list_reports.")],
        required: ["report"]
    ) { arguments, source in
        let report = try arguments.required("report")
        let company = try? await source.companies().first
        // Newest first, so the example covers the current year.
        let fiscalYear = try? await source.fiscalYears().first

        var result: [String: JSON] = ["report": .string(report)]
        let script = try? await source.reportScript(name: report)
        if let script,
            let definitions = ReportFilterParser.definitions(
                reportName: report, script: script, defaultCompany: company?.name,
                defaultFiscalYear: fiscalYear?.name) {
            result["filters"] = .array(definitions.filter { !$0.hidden }.map(describe))
        }
        if let standard = StandardReports.financialStatements.first(where: { $0.name == report }) {
            result["example_filters"] = .object(
                standard.filters(
                    for: FinancialFilterState(company: company, fiscalYear: fiscalYear)))
            result["note"] = """
                periodicity is Monthly, Quarterly, Half-Yearly or Yearly. To report on a date \
                range instead of fiscal years, set filter_based_on to "Date Range" with \
                period_start_date and period_end_date.
                """
        } else if result["filters"] == nil {
            result["note"] = """
                This report's filters couldn't be read from the server. Most reports take \
                company, and from_date and to_date; try those, and read the error if it asks \
                for more.
                """
        }
        return .object(result)
    }

    private static func describe(_ filter: ReportFilterDefinition) -> JSON {
        var entry: [String: JSON] = [
            "fieldname": .string(filter.fieldname),
            "label": .string(filter.label),
        ]
        if filter.isMultiSelect {
            entry["type"] = "list"
        } else {
            switch filter.fieldtype {
            case .check: entry["type"] = "0 or 1"
            case .date: entry["type"] = "date (YYYY-MM-DD)"
            case .int, .float, .currency, .percent: entry["type"] = "number"
            default: entry["type"] = "string"
            }
        }
        if let target = filter.options { entry["links_to"] = .string(target) }
        if !filter.selectOptions.isEmpty {
            entry["choices"] = .array(filter.selectOptions.map(JSON.string))
        }
        if let value = filter.defaultValue { entry["default"] = .string(value) }
        if filter.required { entry["required"] = true }
        return .object(entry)
    }

    static let runReport = Tool(
        name: "run_report",
        title: "Run a report",
        description: """
            Runs a report on the server and returns its table: `columns`, then `rows` as \
            lists of values in column order. Tree reports (financial statements) add a final \
            `indent` column giving each row's depth, and name their total rows in quotes. \
            `summary` holds the report's headline figures when it has any. Long reports are \
            paged with limit and offset; total_rows is the full length.
            """,
        properties: [
            "report": text("Exact report name, from list_reports."),
            "filters": [
                "type": "object",
                "description": """
                    The report's filters by fieldname, from get_report_filters, e.g. \
                    {"company": "Acme Inc", "from_date": "2026-01-01", "to_date": "2026-03-31"}.
                    """,
            ],
            "limit": integer("Most rows to return.", default: 200, maximum: 2000),
            "offset": integer("Rows to skip, for paging.", default: 0, maximum: 10_000_000),
        ],
        required: ["report"]
    ) { arguments, source in
        let report = try arguments.required("report")
        let filters: [String: JSON]
        if arguments.values["filters"].map({ !$0.isNull }) == true {
            guard let object = arguments.structured("filters")?.objectValue else {
                throw ToolError("\"filters\" must be an object of fieldname → value.")
            }
            filters = object
        } else {
            filters = [:]
        }
        let limit = arguments.int("limit", default: 200, in: 1...2000)
        let offset = arguments.int("offset", default: 0, in: 0...10_000_000)

        let result = try await source.runReport(report, filters: filters)
        var columns = result.visibleColumns
        let rows = result.rows.filter { !$0.isBlank }
        let isTree = rows.contains { $0.indent > 0 }
        let page = rows.dropFirst(offset).prefix(limit)

        var columnList = columns.map { column -> JSON in
            var entry: [String: JSON] = [
                "fieldname": .string(column.fieldname), "label": .string(column.label),
            ]
            if let options = column.options { entry["options"] = .string(options) }
            return .object(entry)
        }
        // A tree report usually declares no indent column of its own.
        columns.removeAll { $0.fieldname == "indent" }
        columnList.removeAll { $0.objectValue?["fieldname"] == "indent" }
        if isTree {
            columnList.append(["fieldname": "indent", "label": "Depth in the tree"])
        }

        var output: [String: JSON] = [
            "report": .string(report),
            "columns": .array(columnList),
            "rows": .array(
                page.map { row in
                    var values = columns.map { row.values[$0.fieldname] ?? .null }
                    if isTree { values.append(.int(row.indent)) }
                    return .array(values)
                }),
            "total_rows": .int(rows.count),
            "offset": .int(offset),
            "returned": .int(page.count),
            "has_more": .bool(offset + page.count < rows.count),
        ]
        if !result.summary.isEmpty {
            output["summary"] = .array(
                result.summary.map {
                    JSON.object([
                        "label": .string($0.label), "value": $0.value,
                        "currency": $0.currency.map(JSON.string) ?? .null,
                    ]).compacted
                })
        }
        if let message = result.message { output["message"] = .string(message) }
        return .object(output)
    }
}
