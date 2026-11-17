import ERPNextKit
import Foundation

/// JSON as the server reads and writes it. `FrappeValue` is already a
/// lossless JSON value, so the protocol layer needs no second one.
public typealias JSON = FrappeValue

/// A Model Context Protocol server over an ERPNext `DataSource`.
///
/// It speaks JSON-RPC 2.0 one message at a time and has no I/O of its own:
/// the executable feeds it lines from stdin and prints what it returns. All
/// it can do to the ERPNext site is what `DataSource` can do, which is read
/// (ARCHITECTURE.md §6) — there is no write client anywhere in this target.
public struct MCPServer: Sendable {
    /// Newest first. A client asking for one of these gets it back; any
    /// other request is answered with the newest.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let source: any DataSource
    public let version: String
    let tools: [Tool]

    public init(source: any DataSource, version: String = "0.1.0") {
        self.source = source
        self.version = version
        self.tools = Tool.all
    }

    /// Handles one line of input. Returns the line to write back, or nil
    /// when the message was a notification (or a reply) and needs none.
    public func handle(line: String) async -> String? {
        let message: JSON
        do {
            message = try JSON.decode(from: Data(line.utf8))
        } catch {
            return Self.encode(Self.failure(id: .null, code: -32700, message: "Parse error"))
        }
        if let batch = message.arrayValue {
            var replies: [JSON] = []
            for entry in batch {
                if let reply = await handle(message: entry) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : Self.encode(.array(replies))
        }
        return await handle(message: message).map(Self.encode)
    }

    func handle(message: JSON) async -> JSON? {
        guard let object = message.objectValue else {
            return Self.failure(id: .null, code: -32600, message: "Invalid request")
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // A reply to something we sent; we send nothing, so drop it.
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.failure(id: id ?? .null, code: -32600, message: "Invalid request")
        }
        // No id: a notification, which is never answered.
        guard let id, !id.isNull else { return nil }
        let params = object["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue
            let agreed =
                asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil }
                ?? Self.protocolVersions[0]
            return Self.success(
                id: id,
                result: [
                    "protocolVersion": .string(agreed),
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": [
                        "name": "tula", "title": "Tula (ERPNext)", "version": .string(version),
                    ],
                    "instructions": .string(Self.instructions(site: source.displayName)),
                ])
        case "ping":
            return Self.success(id: id, result: [:])
        case "tools/list":
            return Self.success(id: id, result: ["tools": .array(tools.map(\.listing))])
        case "tools/call":
            guard let name = params["name"]?.stringValue,
                let tool = tools.first(where: { $0.name == name })
            else {
                return Self.failure(
                    id: id, code: -32602,
                    message: "Unknown tool: \(params["name"]?.stringValue ?? "(none)")")
            }
            let arguments = Arguments(values: params["arguments"]?.objectValue ?? [:])
            return Self.success(id: id, result: await call(tool, arguments))
        case "resources/list":
            return Self.success(id: id, result: ["resources": []])
        case "resources/templates/list":
            return Self.success(id: id, result: ["resourceTemplates": []])
        case "prompts/list":
            return Self.success(id: id, result: ["prompts": []])
        default:
            return Self.failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// A tool that fails is still a successful JSON-RPC call: the failure
    /// goes back as the tool's result, where the model can read it and try
    /// something else.
    private func call(_ tool: Tool, _ arguments: Arguments) async -> JSON {
        do {
            let text = Self.encode(try await tool.run(arguments, source))
            guard text.utf8.count <= Self.maximumResultBytes else {
                throw ToolError(
                    "The result is too large to return (\(text.utf8.count / 1024) KB). "
                        + "Ask for fewer rows (limit), fewer fields, or a narrower filter.")
            }
            return ["content": [["type": "text", "text": .string(text)]], "isError": false]
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return ["content": [["type": "text", "text": .string(text)]], "isError": true]
        }
    }

    static let maximumResultBytes = 400_000

    static func instructions(site: String) -> String {
        """
        Read-only access to the ERPNext site "\(site)", through the same GET-only client \
        the Tula app uses. Nothing here can create, change or delete data.

        ERPNext stores everything as documents of a DocType ("Sales Invoice", "Customer", \
        "Item", "GL Entry", ...). To answer a question:
        - Start with get_site_info for the companies, fiscal years and today's date.
        - Find the DocType with search_doctypes, then its fields with get_doctype_schema \
        before filtering or choosing fields; custom fields are common.
        - Use list_documents and count_documents for records, get_document for one record \
        with its child tables (line items, taxes).
        - For financial and analytical questions prefer the server's own reports \
        (list_reports, get_report_filters, run_report): Profit and Loss Statement, \
        Balance Sheet, General Ledger, Accounts Receivable, Stock Balance and the rest \
        apply ERPNext's accounting rules, which sums over raw documents do not.
        - Submittable documents carry docstatus: 0 draft, 1 submitted, 2 cancelled. Filter \
        on docstatus = 1 when totalling transactions.
        The API user's ERPNext permissions apply; a permission error means that user may \
        not read the DocType or report.
        """
    }

    // MARK: JSON-RPC envelopes

    static func success(id: JSON, result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func failure(id: JSON, code: Int, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    /// One line, always: stdio messages are newline-delimited, and
    /// JSONEncoder escapes any newline inside a string.
    static func encode(_ value: JSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

// Literals, so results read like the JSON they become.
extension FrappeValue: ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: FrappeValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, FrappeValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
