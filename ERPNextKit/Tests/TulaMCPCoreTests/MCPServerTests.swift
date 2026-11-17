import ERPNextKit
import XCTest

@testable import TulaMCPCore

/// The server end to end — a JSON-RPC line in, a line out — over the demo
/// data, which is shaped exactly like a live site's responses.
final class MCPServerTests: XCTestCase {
    private let server = MCPServer(source: DemoDataSource())

    private func send(_ line: String) async throws -> [String: JSON] {
        let handled = await server.handle(line: line)
        let reply = try XCTUnwrap(handled)
        XCTAssertFalse(reply.contains("\n"), "a reply must be a single line")
        return try XCTUnwrap(JSON.decode(from: Data(reply.utf8)).objectValue)
    }

    /// Calls a tool and returns its decoded result and whether it failed.
    private func call(_ tool: String, _ arguments: String = "{}") async throws
        -> (result: JSON, text: String, isError: Bool) {
        let reply = try await send(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
        let result = try XCTUnwrap(reply["result"]?.objectValue)
        let text = try XCTUnwrap(
            result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        let isError = result["isError"]?.boolValue ?? false
        return ((try? JSON.decode(from: Data(text.utf8))) ?? .null, text, isError)
    }

    // MARK: Protocol

    func testInitializeAgreesOnAVersionTheClientAskedFor() async throws {
        let reply = try await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(reply["id"], 1)
        let result = try XCTUnwrap(reply["result"]?.objectValue)
        XCTAssertEqual(result["protocolVersion"], "2025-03-26")
        XCTAssertEqual(result["serverInfo"]?.objectValue?["name"], "tula")
        XCTAssertNotNil(result["capabilities"]?.objectValue?["tools"])
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("Demo Data") == true)
    }

    func testInitializeOffersItsNewestVersionForOneItDoesNotKnow() async throws {
        let reply = try await send(
            #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(reply["id"], "a")
        XCTAssertEqual(
            reply["result"]?.objectValue?["protocolVersion"]?.stringValue,
            MCPServer.protocolVersions[0])
    }

    func testNotificationsGetNoReply() async {
        let reply = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(reply)
    }

    func testUnknownMethodAndBadJSONAreJSONRPCErrors() async throws {
        let unknown = try await send(#"{"jsonrpc":"2.0","id":2,"method":"nope"}"#)
        XCTAssertEqual(unknown["error"]?.objectValue?["code"], -32601)
        let garbage = try await send("{not json")
        XCTAssertEqual(garbage["error"]?.objectValue?["code"], -32700)
        let ping = try await send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        XCTAssertEqual(ping["result"], [:])
    }

    func testEveryToolIsListedReadOnlyWithAnObjectSchema() async throws {
        let reply = try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(reply["result"]?.objectValue?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, Tool.all.count)
        XCTAssertEqual(Set(Tool.all.map(\.name)).count, Tool.all.count, "tool names are unique")
        for tool in tools {
            let object = try XCTUnwrap(tool.objectValue)
            XCTAssertEqual(object["inputSchema"]?.objectValue?["type"], "object")
            XCTAssertEqual(object["annotations"]?.objectValue?["readOnlyHint"], true)
            let properties = object["inputSchema"]?.objectValue?["properties"]?.objectValue ?? [:]
            for name in object["inputSchema"]?.objectValue?["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(properties[name.stringValue ?? ""], "required argument is declared")
            }
        }
    }

    func testUnknownToolIsAProtocolError() async throws {
        let reply = try await send(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_everything"}}"#)
        XCTAssertEqual(reply["error"]?.objectValue?["code"], -32602)
    }

    // MARK: Tools

    func testSiteInfo() async throws {
        let (result, _, isError) = try await call("get_site_info")
        XCTAssertFalse(isError)
        XCTAssertEqual(result.objectValue?["site"], "Demo Data")
        XCTAssertEqual(
            result.objectValue?["companies"]?.arrayValue?.first?.objectValue?["name"],
            "Wind Power LLC")
        XCTAssertEqual(
            result.objectValue?["fiscal_years"]?.arrayValue?.first?.objectValue?["end"],
            "2025-12-31")
    }

    func testSchemaListsDataFieldsAndSkipsLayout() async throws {
        let (result, _, isError) = try await call("get_doctype_schema", #"{"doctype":"Sales Invoice"}"#)
        XCTAssertFalse(isError)
        let fields = try XCTUnwrap(result.objectValue?["fields"]?.arrayValue)
        XCTAssertFalse(fields.isEmpty)
        let types = Set(fields.compactMap { $0.objectValue?["fieldtype"]?.stringValue })
        XCTAssertTrue(types.isDisjoint(with: ["Section Break", "Column Break", "Tab Break"]))
        XCTAssertTrue(fields.allSatisfy { $0.objectValue?["fieldname"]?.nonEmptyString != nil })
    }

    func testListDocumentsFiltersAndPages() async throws {
        let (all, _, _) = try await call("list_documents", #"{"doctype":"Sales Invoice","limit":500}"#)
        let documents = try XCTUnwrap(all.objectValue?["documents"]?.arrayValue)
        XCTAssertGreaterThan(documents.count, 1)
        XCTAssertEqual(all.objectValue?["has_more"], false)

        // The demo source ignores the page length; a server that returns
        // more than was asked for must not overrun the limit either.
        let (page, _, _) = try await call(
            "list_documents", #"{"doctype":"Sales Invoice","limit":1,"order_by":"name asc"}"#)
        XCTAssertEqual(page.objectValue?["returned"], 1)
        XCTAssertEqual(page.objectValue?["has_more"], true)

        let first = try XCTUnwrap(documents.first?.objectValue?["name"]?.stringValue)
        let (one, _, _) = try await call(
            "list_documents",
            #"{"doctype":"Sales Invoice","filters":[["name","=","\#(first)"]]}"#)
        XCTAssertEqual(one.objectValue?["returned"], 1)
        let (count, _, _) = try await call(
            "count_documents", #"{"doctype":"Sales Invoice","filters":{"name":"\#(first)"}}"#)
        XCTAssertEqual(count.objectValue?["count"], 1)
    }

    func testGetDocumentDropsEmptyValuesAndChildRowBoilerplate() async throws {
        // The one invoice the demo data fixtures in full.
        let name = "ACC-SINV-2025-00042"
        let (document, text, isError) = try await call(
            "get_document", #"{"doctype":"Sales Invoice","name":"\#(name)"}"#)
        XCTAssertFalse(isError, text)
        XCTAssertEqual(document.objectValue?["name"]?.stringValue, name)
        XCTAssertFalse(text.contains(":null"))
        XCTAssertFalse(text.contains("\"parenttype\""))
    }

    func testRunReportReturnsRowsInColumnOrderWithDepth() async throws {
        let (result, text, isError) = try await call(
            "run_report", #"{"report":"Profit and Loss Statement","filters":{"company":"Wind Power LLC"},"limit":5}"#)
        XCTAssertFalse(isError, text)
        let columns = try XCTUnwrap(result.objectValue?["columns"]?.arrayValue)
        let rows = try XCTUnwrap(result.objectValue?["rows"]?.arrayValue)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(result.objectValue?["has_more"], true)
        XCTAssertEqual(columns.last?.objectValue?["fieldname"], "indent")
        XCTAssertEqual(
            columns.filter { $0.objectValue?["fieldname"] == "indent" }.count, 1)
        for row in rows {
            XCTAssertEqual(row.arrayValue?.count, columns.count)
        }
        let total = try XCTUnwrap(result.objectValue?["total_rows"]?.intValue)
        let (rest, _, _) = try await call(
            "run_report", #"{"report":"Profit and Loss Statement","offset":5,"limit":2000}"#)
        XCTAssertEqual(rest.objectValue?["returned"]?.intValue, total - 5)
        XCTAssertEqual(rest.objectValue?["has_more"], false)
    }

    func testStandardStatementsComeWithFiltersThatRun() async throws {
        let (result, _, _) = try await call("get_report_filters", #"{"report":"Balance Sheet"}"#)
        let example = try XCTUnwrap(result.objectValue?["example_filters"]?.objectValue)
        XCTAssertEqual(example["company"], "Wind Power LLC")
        XCTAssertEqual(example["from_fiscal_year"], "2025")
        XCTAssertEqual(example["accumulated_values"], 1)
    }

    func testSearchAndFind() async throws {
        let (search, _, _) = try await call("search", #"{"query":"SINV"}"#)
        XCTAssertFalse(search.objectValue?["results"]?.arrayValue?.isEmpty ?? true)
        let (found, _, _) = try await call("find_documents", #"{"doctype":"Customer","query":"north"}"#)
        XCTAssertEqual(
            found.objectValue?["matches"]?.arrayValue?.first?.objectValue?["name"],
            "Northwind Research")
    }

    func testAToolFailureIsAResultTheModelCanRead() async throws {
        let (_, missing, missingIsError) = try await call("get_document", #"{"doctype":"Sales Invoice"}"#)
        XCTAssertTrue(missingIsError)
        XCTAssertTrue(missing.contains("\"name\""))

        let (_, server, serverIsError) = try await call("run_report", #"{"report":"No Such Report"}"#)
        XCTAssertTrue(serverIsError)
        XCTAssertTrue(server.contains("No Such Report"))

        let (_, filter, filterIsError) = try await call(
            "list_documents", #"{"doctype":"Account","filters":[["name","~","x"]]}"#)
        XCTAssertTrue(filterIsError)
        XCTAssertTrue(filter.contains("operator"))
    }

    // MARK: Arguments

    func testFiltersAcceptTheWireFormAndTheShorthands() throws {
        func parse(_ json: String) throws -> [ListFilter] {
            try Arguments(values: ["filters": JSON.decode(from: Data(json.utf8))]).filters()
        }
        let expected = [ListFilter("status", "=", "Paid")]
        XCTAssertEqual(try parse(#"[["status","=","Paid"]]"#), expected)
        XCTAssertEqual(try parse(#"[["Sales Invoice","status","=","Paid"]]"#), expected)
        XCTAssertEqual(try parse(#"["status","=","Paid"]"#), expected)
        XCTAssertEqual(try parse(#"{"status":"Paid"}"#), expected)
        XCTAssertEqual(try parse(#""[[\"status\",\"=\",\"Paid\"]]""#), expected)
        XCTAssertEqual(
            try parse(#"{"grand_total":[">",100],"status":["in",["Paid","Unpaid"]]}"#),
            [
                ListFilter("grand_total", ">", 100),
                ListFilter("status", "in", ["Paid", "Unpaid"]),
            ])
        // A two-element list that isn't [operator, value] is a plain value.
        XCTAssertEqual(
            try parse(#"{"cost_center":["Main","West"]}"#),
            [ListFilter("cost_center", "=", ["Main", "West"])])
        XCTAssertThrowsError(try parse(#"[["status","Paid"]]"#))
        XCTAssertThrowsError(try parse(#""not json""#))
    }
}
