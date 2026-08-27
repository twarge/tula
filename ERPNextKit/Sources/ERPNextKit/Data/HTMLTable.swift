import Foundation

/// A table extracted from server-generated HTML.
///
/// Several ERPNext fields carry pre-rendered HTML rather than data — most
/// prominently the tax breakup (`other_charges_calculation`, a Long Text
/// holding a `<table>`). Desk injects that HTML directly; we parse the table
/// and render it as a native grid instead (no WebKit).
public struct HTMLTable: Sendable, Hashable {
    public var headers: [String]
    public var rows: [[String]]

    /// Extracts the first `<table>` from an HTML fragment. Returns nil when
    /// there is no table or it has no content — callers then fall back to
    /// plain stripped text.
    public static func firstTable(in html: String) -> HTMLTable? {
        guard html.range(of: "<table", options: .caseInsensitive) != nil,
            let tableRegex = try? NSRegularExpression(
                pattern: "<table[^>]*>(.*?)</table>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let rowRegex = try? NSRegularExpression(
                pattern: "<tr[^>]*>(.*?)</tr>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let cellRegex = try? NSRegularExpression(
                pattern: "<(th|td)[^>]*>(.*?)</\\1>",
                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }

        let range = NSRange(html.startIndex..., in: html)
        guard let tableMatch = tableRegex.firstMatch(in: html, range: range),
            let tableRange = Range(tableMatch.range(at: 1), in: html)
        else { return nil }
        let tableHTML = String(html[tableRange])

        var headers: [String] = []
        var rows: [[String]] = []

        let rowMatches = rowRegex.matches(
            in: tableHTML, range: NSRange(tableHTML.startIndex..., in: tableHTML))
        for rowMatch in rowMatches {
            guard let rowRange = Range(rowMatch.range(at: 1), in: tableHTML) else { continue }
            let rowHTML = String(tableHTML[rowRange])

            var cells: [String] = []
            var isHeaderRow = false
            let cellMatches = cellRegex.matches(
                in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML))
            for cellMatch in cellMatches {
                guard let tagRange = Range(cellMatch.range(at: 1), in: rowHTML),
                    let contentRange = Range(cellMatch.range(at: 2), in: rowHTML)
                else { continue }
                if rowHTML[tagRange].lowercased() == "th" { isHeaderRow = true }
                let text = String(rowHTML[contentRange])
                    .replacingOccurrences(
                        of: "<br\\s*/?>", with: " ",
                        options: [.regularExpression, .caseInsensitive])
                    .strippingSimpleHTML()
                cells.append(text)
            }

            guard cells.contains(where: { !$0.isEmpty }) else { continue }
            if isHeaderRow && headers.isEmpty {
                headers = cells
            } else {
                rows.append(cells)
            }
        }

        guard !headers.isEmpty || !rows.isEmpty else { return nil }
        return HTMLTable(headers: headers, rows: rows)
    }

    /// Whether every populated data cell in a column reads as a number,
    /// currency, or percentage — used for trailing alignment.
    public func columnIsNumeric(_ index: Int) -> Bool {
        let values = rows.compactMap { row in
            index < row.count ? row[index] : nil
        }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return false }
        return values.allSatisfy { value in
            value.range(of: "^[-()\\s$€£¥%\\d.,]+$", options: .regularExpression) != nil
                && value.rangeOfCharacter(from: .decimalDigits) != nil
        }
    }
}
