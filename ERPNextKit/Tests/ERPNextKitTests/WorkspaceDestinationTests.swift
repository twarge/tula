import XCTest

@testable import ERPNextKit

final class WorkspaceDestinationTests: XCTestCase {
    private let base = URL(string: "https://erp.example.com/site")!

    private func destination(_ json: String, baseURL: URL? = nil) throws -> WorkspaceDestination {
        let document = try Document.single(from: Data(json.utf8))
        return try WorkspaceDestination(document: document, baseURL: baseURL)
    }

    func testLegacyAndV16ContentWorkspaces() throws {
        XCTAssertEqual(
            try destination(#"{"data":{"name":"Accounting","shortcuts":[],"links":[]}}"#),
            .content)
        XCTAssertEqual(
            try destination(#"{"data":{"name":"Buying","type":"Workspace","links":[]}}"#),
            .content)
    }

    func testDocTypeAndReportLinksUseTheirTargets() throws {
        // Labels differ from destinations; cards left over from an older
        // workspace must not override a v16 link's target.
        XCTAssertEqual(
            try destination(#"{"data":{"name":"Invoices","type":"Link","link_type":"DocType","link_to":"Sales Invoice","links":[{"link_to":"Customer"}]}}"#),
            .doctype("Sales Invoice"))
        XCTAssertEqual(
            try destination(#"{"data":{"name":"Profit","type":"Link","link_type":"Report","link_to":"Profit and Loss Statement"}}"#),
            .report("Profit and Loss Statement"))
    }

    func testDeskPagesPreserveTheSitePrefix() throws {
        XCTAssertEqual(
            try destination(
                #"{"data":{"name":"Overview","type":"Link","link_type":"Page","link_to":"stock-dashboard"}}"#,
                baseURL: base),
            .web(URL(string: "https://erp.example.com/site/app/stock-dashboard")!))
    }

    func testExternalAndRelativeURLs() throws {
        XCTAssertEqual(
            try destination(
                #"{"data":{"type":"URL","external_link":"https://docs.example.com/guide?section=buying#orders"}}"#,
                baseURL: base),
            .web(URL(string: "https://docs.example.com/guide?section=buying#orders")!))
        XCTAssertEqual(
            try destination(
                #"{"data":{"type":"URL","external_link":"help?section=buying"}}"#,
                baseURL: base),
            .web(URL(string: "https://erp.example.com/site/help?section=buying")!))
        XCTAssertEqual(
            try destination(
                #"{"data":{"type":"URL","external_link":"/desk/sales-invoice"}}"#,
                baseURL: base),
            .web(URL(string: "https://erp.example.com/desk/sales-invoice")!))
    }

    func testIncompleteLinksFailInsteadOfRenderingAnEmptyWorkspace() {
        for json in [
            #"{"data":{"type":"Link","link_type":"DocType"}}"#,
            #"{"data":{"type":"Link","link_type":"Report","link_to":""}}"#,
            #"{"data":{"type":"Link","link_type":"Unknown","link_to":"Target"}}"#,
            #"{"data":{"type":"URL"}}"#,
        ] {
            XCTAssertThrowsError(try destination(json, baseURL: base))
        }
        XCTAssertThrowsError(try destination(
            #"{"data":{"type":"Link","link_type":"Page","link_to":"stock-dashboard"}}"#))
        XCTAssertThrowsError(try destination(
            #"{"data":{"type":"URL","external_link":"/desk/home"}}"#))
    }

    func testNonWebSchemesAreRejected() {
        for target in ["javascript:alert(1)", "file:///tmp/example", "mailto:user@example.com"] {
            let document = Document(raw: ["type": .string("URL"), "external_link": .string(target)])
            XCTAssertThrowsError(try WorkspaceDestination(document: document, baseURL: base))
        }
    }
}
