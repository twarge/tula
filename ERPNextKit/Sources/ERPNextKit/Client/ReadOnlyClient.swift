import Foundation

/// Connection details for one ERPNext site.
///
/// Authentication uses Frappe token auth (`Authorization: token key:secret`).
/// Recommend pairing with a server-side user that holds only read/report
/// permissions — see docs/ARCHITECTURE.md §6.
public struct ServerConfiguration: Sendable, Hashable {
    public var baseURL: URL
    public var apiKey: String
    public var apiSecret: String

    public init(baseURL: URL, apiKey: String, apiSecret: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }

    var authorizationHeader: String { "token \(apiKey):\(apiSecret)" }
}

public struct ERPNextError: Error, LocalizedError, Sendable {
    public var message: String
    public var statusCode: Int?

    public init(message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    public var errorDescription: String? { message }
}

/// RPC methods this client is allowed to call.
///
/// Part of the read-only guarantee: arbitrary `/api/method/...` calls are not
/// expressible. Every entry here must be a side-effect-free read on the server.
public enum ReadMethod: String, Sendable, CaseIterable {
    case ping = "frappe.ping"
    case runQueryReport = "frappe.desk.query_report.run"
    case getDocType = "frappe.desk.form.load.getdoctype"
    case treeChildren = "frappe.desk.treeview.get_children"
    case getCount = "frappe.client.get_count"
    case searchLink = "frappe.desk.search.search_link"
    case getReportScript = "frappe.desk.query_report.get_script"
    case globalSearch = "frappe.utils.global_search.search"
}

/// A list-endpoint filter, serialized as Frappe's `[fieldname, operator, value]`.
public struct ListFilter: Sendable, Hashable {
    public var fieldname: String
    public var op: String
    public var value: FrappeValue

    public init(_ fieldname: String, _ op: String, _ value: FrappeValue) {
        self.fieldname = fieldname
        self.op = op
        self.value = value
    }
}

/// The full set of requests the app can make. All of them are HTTP GETs.
public enum Endpoint: Sendable {
    case resourceList(
        doctype: String, fields: [String], filters: [ListFilter],
        orderBy: String?, limitStart: Int, limitPageLength: Int)
    case resource(doctype: String, name: String)
    case method(ReadMethod, parameters: [String: String])

    func url(relativeTo base: URL) throws -> URL {
        var path: String
        var query: [URLQueryItem] = []

        switch self {
        case .resourceList(let doctype, let fields, let filters, let orderBy, let start, let length):
            path = "/api/resource/\(doctype)"
            if !fields.isEmpty {
                query.append(URLQueryItem(
                    name: "fields",
                    value: try FrappeValue.array(fields.map { .string($0) }).encodedJSONString()))
            }
            if !filters.isEmpty {
                let encoded = FrappeValue.array(filters.map {
                    .array([.string($0.fieldname), .string($0.op), $0.value])
                })
                query.append(URLQueryItem(name: "filters", value: try encoded.encodedJSONString()))
            }
            if let orderBy {
                query.append(URLQueryItem(name: "order_by", value: orderBy))
            }
            query.append(URLQueryItem(name: "limit_start", value: String(start)))
            query.append(URLQueryItem(name: "limit_page_length", value: String(length)))

        case .resource(let doctype, let name):
            path = "/api/resource/\(doctype)/\(name)"

        case .method(let method, let parameters):
            path = "/api/method/\(method.rawValue)"
            for (name, value) in parameters.sorted(by: { $0.key < $1.key }) {
                query.append(URLQueryItem(name: name, value: value))
            }
        }

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ERPNextError(message: "Invalid server URL")
        }
        components.path = components.path.trimmingSuffix("/") + path
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw ERPNextError(message: "Could not build request URL")
        }
        return url
    }
}

/// The only HTTP transport in the app. It can issue exactly one HTTP method:
/// GET. There is no code path that produces a POST, PUT, PATCH, or DELETE, so
/// no view or feature can mutate server state, by construction.
public final class ReadOnlyClient: Sendable {
    public let configuration: ServerConfiguration
    private let session: URLSession

    public init(configuration: ServerConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func data(for endpoint: Endpoint) async throws -> Data {
        var request = URLRequest(url: try endpoint.url(relativeTo: configuration.baseURL))
        request.httpMethod = "GET"
        request.setValue(configuration.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ERPNextError(message: "Unexpected response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ERPNextError(
                message: Self.serverMessage(from: data, statusCode: http.statusCode),
                statusCode: http.statusCode)
        }
        return data
    }

    /// Pull a human-readable message out of a Frappe error payload.
    private static func serverMessage(from data: Data, statusCode: Int) -> String {
        let fallback = "Server returned HTTP \(statusCode)"
        guard let root = try? FrappeValue.decode(from: data).objectValue else { return fallback }

        // Newer Frappe: {"errors": [{"message": ...}]}
        if let errors = root["errors"]?.arrayValue,
            let message = errors.first?.objectValue?["message"]?.nonEmptyString {
            return message
        }
        // {"_server_messages": "[\"{\\\"message\\\": ...}\"]"} — doubly encoded.
        if let raw = root["_server_messages"]?.nonEmptyString,
            let outer = try? FrappeValue.decode(from: Data(raw.utf8)).arrayValue,
            let innerRaw = outer.first?.stringValue,
            let inner = try? FrappeValue.decode(from: Data(innerRaw.utf8)).objectValue,
            let message = inner["message"]?.nonEmptyString {
            return message.strippingSimpleHTML()
        }
        if let excType = root["exc_type"]?.nonEmptyString {
            if excType == "PermissionError" {
                return "Permission denied (HTTP \(statusCode)). Check the API user's read permissions."
            }
            return "\(excType) (HTTP \(statusCode))"
        }
        if let message = root["message"]?.nonEmptyString {
            return message
        }
        return fallback
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    /// Cheap tag-stripper for short server-message HTML. Not a general HTML
    /// renderer — rich text fields get their own converter in the app layer.
    public func strippingSimpleHTML() -> String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
