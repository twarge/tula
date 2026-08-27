import Foundation

/// Frappe DocField `fieldtype` values.
///
/// Unknown types (server customizations, future Frappe versions) decode to
/// `.other` and render as plain text — the app degrades instead of breaking.
public enum FieldType: Sendable, Hashable, Codable {
    case data
    case int
    case float
    case currency
    case percent
    case check
    case date
    case datetime
    case time
    case duration
    case select
    case link
    case dynamicLink
    case text
    case smallText
    case longText
    case code
    case json
    case markdown
    case textEditor
    case htmlEditor
    case html
    case table
    case tableMultiSelect
    case attach
    case attachImage
    case image
    case signature
    case color
    case rating
    case barcode
    case geolocation
    case phone
    case autocomplete
    case password
    case readOnly
    case icon
    case sectionBreak
    case columnBreak
    case tabBreak
    case fold
    case heading
    case button
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "Data": self = .data
        case "Int", "Long Int": self = .int
        case "Float": self = .float
        case "Currency": self = .currency
        case "Percent": self = .percent
        case "Check": self = .check
        case "Date": self = .date
        case "Datetime": self = .datetime
        case "Time": self = .time
        case "Duration": self = .duration
        case "Select": self = .select
        case "Link": self = .link
        case "Dynamic Link": self = .dynamicLink
        case "Text": self = .text
        case "Small Text": self = .smallText
        case "Long Text": self = .longText
        case "Code": self = .code
        case "JSON": self = .json
        case "Markdown Editor": self = .markdown
        case "Text Editor": self = .textEditor
        case "HTML Editor": self = .htmlEditor
        case "HTML": self = .html
        case "Table": self = .table
        case "Table MultiSelect": self = .tableMultiSelect
        case "Attach": self = .attach
        case "Attach Image": self = .attachImage
        case "Image": self = .image
        case "Signature": self = .signature
        case "Color": self = .color
        case "Rating": self = .rating
        case "Barcode": self = .barcode
        case "Geolocation": self = .geolocation
        case "Phone": self = .phone
        case "Autocomplete": self = .autocomplete
        case "Password": self = .password
        case "Read Only": self = .readOnly
        case "Icon": self = .icon
        case "Section Break": self = .sectionBreak
        case "Column Break": self = .columnBreak
        case "Tab Break": self = .tabBreak
        case "Fold": self = .fold
        case "Heading": self = .heading
        case "Button": self = .button
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .data: return "Data"
        case .int: return "Int"
        case .float: return "Float"
        case .currency: return "Currency"
        case .percent: return "Percent"
        case .check: return "Check"
        case .date: return "Date"
        case .datetime: return "Datetime"
        case .time: return "Time"
        case .duration: return "Duration"
        case .select: return "Select"
        case .link: return "Link"
        case .dynamicLink: return "Dynamic Link"
        case .text: return "Text"
        case .smallText: return "Small Text"
        case .longText: return "Long Text"
        case .code: return "Code"
        case .json: return "JSON"
        case .markdown: return "Markdown Editor"
        case .textEditor: return "Text Editor"
        case .htmlEditor: return "HTML Editor"
        case .html: return "HTML"
        case .table: return "Table"
        case .tableMultiSelect: return "Table MultiSelect"
        case .attach: return "Attach"
        case .attachImage: return "Attach Image"
        case .image: return "Image"
        case .signature: return "Signature"
        case .color: return "Color"
        case .rating: return "Rating"
        case .barcode: return "Barcode"
        case .geolocation: return "Geolocation"
        case .phone: return "Phone"
        case .autocomplete: return "Autocomplete"
        case .password: return "Password"
        case .readOnly: return "Read Only"
        case .icon: return "Icon"
        case .sectionBreak: return "Section Break"
        case .columnBreak: return "Column Break"
        case .tabBreak: return "Tab Break"
        case .fold: return "Fold"
        case .heading: return "Heading"
        case .button: return "Button"
        case .other(let raw): return raw
        }
    }

    /// Persisted by raw value (report snapshots on disk).
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Layout-structuring pseudo-fields consumed by the layout parser.
    public var isLayoutBreak: Bool {
        switch self {
        case .sectionBreak, .columnBreak, .tabBreak, .fold: return true
        default: return false
        }
    }

    /// Whether a read-only client should render this field at all.
    /// Buttons are actions and passwords are secrets — neither is shown.
    public var isPresentable: Bool {
        switch self {
        case .button, .password, .signature, .geolocation, .barcode, .icon:
            return false
        default:
            return !isLayoutBreak
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .int, .float, .currency, .percent: return true
        default: return false
        }
    }
}
