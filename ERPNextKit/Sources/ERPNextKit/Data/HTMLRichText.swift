import Foundation

/// Server-generated HTML as native blocks of styled runs, rendered without
/// WebKit (like `HTMLTable`). Covers the subset Desk content actually uses —
/// a report's `message` first of all: headings, paragraphs and `<br>` lines,
/// bulleted and numbered lists, bold/italic/code, links, and Bootstrap's
/// `text-*` color classes, which nested content inherits as Desk's CSS does.
/// Anything else contributes its text and nothing more.
public struct HTMLRichText: Sendable, Hashable {
    /// Bootstrap's semantic text colors (`text-muted`, `text-warning`, …).
    public enum Tone: String, Sendable, Hashable {
        case muted, warning, danger, success, primary
    }

    public struct Run: Sendable, Hashable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false
        public var tone: Tone?
        /// The `href` exactly as written (often relative, e.g. `/app/...`).
        public var link: String?

        public init(
            _ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false,
            tone: Tone? = nil, link: String? = nil
        ) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.tone = tone
            self.link = link
        }

        fileprivate func hasSameStyle(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic && code == other.code
                && tone == other.tone && link == other.link
        }
    }

    public enum Block: Sendable, Hashable {
        case heading(level: Int, runs: [Run])
        case paragraph([Run])
        /// One line of a list item. `marker` is "•" or "3." on the item's
        /// first line and nil on lines after a `<br>` inside it; `depth` is
        /// 1 for a top-level list.
        case listItem(marker: String?, depth: Int, runs: [Run])
        case rule
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// Nil when the HTML holds no visible text.
    public init?(html: String) {
        var parser = Parser()
        parser.parse(html)
        guard !parser.blocks.isEmpty else { return nil }
        blocks = parser.blocks
    }
}

// MARK: - Parsing

private struct Parser {
    struct Element {
        var name: String
        var bold = false
        var italic = false
        var code = false
        var tone: HTMLRichText.Tone?
        var link: String?
    }

    struct List {
        var ordered: Bool
        var counter = 0
    }

    private(set) var blocks: [HTMLRichText.Block] = []
    private var stack: [Element] = []
    private var lists: [List] = []
    private var line: [HTMLRichText.Run] = []
    /// The marker for the open `<li>`'s first line, consumed by its flush.
    private var pendingMarker: String?

    private static let voidElements: Set<String> = [
        "br", "hr", "img", "input", "meta", "link", "wbr", "col", "source",
    ]
    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "blockquote", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "tr", "dl", "dt", "dd",
    ]

    mutating func parse(_ html: String) {
        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                appendText(String(html[index...]))
                break
            }
            if open > index {
                appendText(String(html[index..<open]))
            }
            if html[open...].hasPrefix("<!--") {
                let end = html.range(of: "-->", range: open..<html.endIndex)?.upperBound
                index = end ?? html.endIndex
                continue
            }
            guard let close = html[open...].firstIndex(of: ">") else {
                // A stray "<" with no tag after it is text.
                appendText(String(html[open...]))
                break
            }
            let tag = String(html[html.index(after: open)..<close])
            index = html.index(after: close)
            if let skipTo = handleTag(tag, in: html, after: index) {
                index = skipTo
            }
        }
        flush()
    }

    /// Returns where to resume when the tag's content is skipped
    /// (`<script>`, `<style>`).
    private mutating func handleTag(
        _ raw: String, in html: String, after position: String.Index
    ) -> String.Index? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("?") else {
            return nil
        }
        let isClosing = trimmed.hasPrefix("/")
        let body = isClosing ? String(trimmed.dropFirst()) : trimmed
        let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard !name.isEmpty else { return nil }

        if isClosing {
            close(name)
            return nil
        }

        if name == "script" || name == "style" {
            let end = html.range(
                of: "</\(name)", options: .caseInsensitive, range: position..<html.endIndex)
            guard let end else { return html.endIndex }
            return html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) }
                ?? html.endIndex
        }

        let attributes = Self.attributes(in: body)
        switch name {
        case "br":
            flush()
            return nil
        case "hr":
            flush()
            blocks.append(.rule)
            return nil
        case _ where Self.voidElements.contains(name):
            return nil
        default:
            break
        }

        if Self.blockElements.contains(name) { flush() }
        if name == "ul" || name == "ol" {
            lists.append(List(ordered: name == "ol"))
        }
        if name == "li" {
            if lists.isEmpty {
                pendingMarker = "•"  // a stray <li> outside any list
            } else {
                lists[lists.count - 1].counter += 1
                let list = lists[lists.count - 1]
                pendingMarker = list.ordered ? "\(list.counter)." : "•"
            }
        }

        var element = Element(name: name)
        switch name {
        case "b", "strong", "th": element.bold = true
        case "i", "em": element.italic = true
        case "code", "kbd", "samp": element.code = true
        case "a": element.link = attributes["href"].flatMap { $0.isEmpty ? nil : $0 }
        default: break
        }
        element.tone = Self.tone(fromClass: attributes["class"])
        if !body.hasSuffix("/") {
            stack.append(element)
        }
        return nil
    }

    private mutating func close(_ name: String) {
        if Self.blockElements.contains(name) { flush() }
        // Pop to the matching element, tolerating sloppy nesting; a stray
        // closing tag with no opener is ignored.
        guard let match = stack.lastIndex(where: { $0.name == name }) else { return }
        let popped = stack[match...].map(\.name)
        stack.removeSubrange(match...)
        for poppedName in popped.reversed() where poppedName == "ul" || poppedName == "ol" {
            if !lists.isEmpty { lists.removeLast() }
        }
        if name == "li" { pendingMarker = nil }
        // A table row reads as one line, its cells space-separated.
        if name == "td" || name == "th" { appendText(" ") }
    }

    /// HTML whitespace rules: runs collapse to one space, a line never
    /// starts with one; entities decode after collapsing so `&nbsp;` holds.
    private mutating func appendText(_ raw: String) {
        var collapsed = raw.replacingOccurrences(
            of: "[ \\t\\n\\r\\f]+", with: " ", options: .regularExpression)
        if line.last?.text.hasSuffix(" ") ?? true, collapsed.hasPrefix(" ") {
            collapsed.removeFirst()
        }
        guard !collapsed.isEmpty else { return }
        var run = currentStyle()
        run.text = Self.decodeEntities(collapsed)
        if let last = line.last, last.hasSameStyle(as: run) {
            line[line.count - 1].text += run.text
        } else {
            line.append(run)
        }
    }

    private func currentStyle() -> HTMLRichText.Run {
        var run = HTMLRichText.Run("")
        for element in stack {
            run.bold = run.bold || element.bold
            run.italic = run.italic || element.italic
            run.code = run.code || element.code
            if let tone = element.tone { run.tone = tone }
            if let link = element.link { run.link = link }
        }
        return run
    }

    private mutating func flush() {
        // Trim the line's outer whitespace, dropping runs it empties.
        var runs = line
        line = []
        while let last = runs.indices.last {
            while runs[last].text.hasSuffix(" ") { runs[last].text.removeLast() }
            if !runs[last].text.isEmpty { break }
            runs.removeLast()
        }
        while let first = runs.indices.first {
            runs[first].text = String(runs[first].text.drop { $0 == " " })
            if !runs[first].text.isEmpty { break }
            runs.removeFirst()
        }
        guard !runs.isEmpty else { return }

        if let heading = stack.last(where: { Self.headingLevel($0.name) != nil }),
            let level = Self.headingLevel(heading.name) {
            blocks.append(.heading(level: level, runs: runs))
        } else if stack.contains(where: { $0.name == "li" }) {
            blocks.append(.listItem(marker: pendingMarker, depth: max(1, lists.count), runs: runs))
            pendingMarker = nil
        } else {
            blocks.append(.paragraph(runs))
        }
    }

    private static func headingLevel(_ name: String) -> Int? {
        guard name.count == 2, name.first == "h", let level = Int(name.dropFirst()),
            (1...6).contains(level)
        else { return nil }
        return level
    }

    private static func tone(fromClass value: String?) -> HTMLRichText.Tone? {
        guard let value else { return nil }
        for token in value.split(whereSeparator: \.isWhitespace) {
            switch token {
            case "text-muted", "text-secondary": return .muted
            case "text-warning": return .warning
            case "text-danger", "text-error": return .danger
            case "text-success": return .success
            case "text-primary", "text-info": return .primary
            default: continue
            }
        }
        return nil
    }

    /// `name="value"`, `name='value'`, or `name=value`; names lowercased.
    private static func attributes(in tagBody: String) -> [String: String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>/]+))"#)
        else { return [:] }
        var result: [String: String] = [:]
        let range = NSRange(tagBody.startIndex..., in: tagBody)
        for match in regex.matches(in: tagBody, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tagBody) else { continue }
            let value = (3...5).lazy
                .compactMap { Range(match.range(at: $0), in: tagBody) }
                .first.map { String(tagBody[$0]) } ?? ""
            result[tagBody[nameRange].lowercased()] = decodeEntities(value)
        }
        return result
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "middot": "·", "bull": "•",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®",
        "trade": "™", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±",
        "rarr": "→", "larr": "←", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
    ]

    /// Named and numeric (`&#8212;`, `&#x2014;`) entities; unknown ones stay
    /// as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while let ampersand = text[index...].firstIndex(of: "&") {
            result += text[index..<ampersand]
            guard let semicolon = text[ampersand...].prefix(12).firstIndex(of: ";") else {
                result.append("&")
                index = text.index(after: ampersand)
                continue
            }
            let entity = text[text.index(after: ampersand)..<semicolon]
            var decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16)
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst())
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = namedEntities[entity.lowercased()]
            }
            if let decoded {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append("&")
                index = text.index(after: ampersand)
            }
        }
        result += text[index...]
        return result
    }
}
