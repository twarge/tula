import ERPNextKit
import SwiftUI

/// The field registry: renders any `FrappeValue` according to its Frappe
/// fieldtype (ARCHITECTURE.md §3). Used by list columns, form fields, child
/// tables, and report cells alike.
struct FieldValueView: View {
    var fieldname: String = ""
    let fieldtype: FieldType
    var options: String?
    let value: FrappeValue?
    var currencyCode: String?
    var precision: Int?
    /// Links render as navigation; callers inside non-navigable contexts turn
    /// this off to get plain text.
    var linkEnabled = true
    /// Sibling values of the row/document this value came from. Dynamic Links
    /// need them: `options` names the sibling field holding the DocType
    /// (GL's voucher_no → voucher_type).
    var rowValues: [String: FrappeValue] = [:]

    var body: some View {
        if let label = value?.nonEmptyString, label.isQuotedTotalLabel {
            // Frappe report pseudo-rows ('Opening', 'Total', …) are labels,
            // not documents — plain text even in Link columns.
            Text(label.strippingTotalQuotes)
        } else {
            typedContent
        }
    }

    @ViewBuilder
    private var typedContent: some View {
        switch fieldtype {
        case .check:
            Image(systemName: value?.boolValue == true ? "checkmark.square.fill" : "square")
                .foregroundStyle(value?.boolValue == true ? Color.accentColor : .secondary)

        case .link where linkTarget != nil, .dynamicLink where linkTarget != nil:
            let target = linkDocument!
            NavigationLink(value: linkTarget!) {
                Text(value?.nonEmptyString ?? "")
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .modifier(
                DocumentQuickViewModifier(doctype: target.doctype, name: target.name))

        case .select where isStatusField && value?.nonEmptyString != nil:
            StatusBadge(status: value!.nonEmptyString!)

        case .int, .float, .currency, .percent:
            Text(formatted).monospacedDigit()

        case .rating:
            let stars = value?.doubleValue.map { Int(($0 * 5).rounded()) } ?? 0
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: index < stars ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

        case .color:
            HStack(spacing: 6) {
                if let hex = value?.nonEmptyString, let color = Color(hex: hex) {
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 14)
                }
                Text(value?.nonEmptyString ?? "")
            }

        case .code, .json:
            Text(formatted)
                .font(.callout.monospaced())
                .textSelection(.enabled)

        case .text, .smallText, .longText, .textEditor, .htmlEditor, .html:
            // Some server fields carry pre-rendered HTML (tax breakup et al).
            // A contained <table> renders as a native grid; anything else
            // falls back to stripped text.
            if let table = HTMLTable.firstTable(in: value?.stringValue ?? "") {
                HTMLTableView(table: table)
            } else {
                Text(formatted)
                    .textSelection(.enabled)
            }

        default:
            Text(formatted)
                .textSelection(.enabled)
        }
    }

    private var formatted: String {
        ValueFormatting.string(
            for: value, fieldtype: fieldtype, currencyCode: currencyCode,
            precision: precision)
    }

    private var linkDocument: (doctype: String, name: String)? {
        guard linkEnabled, let name = value?.nonEmptyString else { return nil }
        switch fieldtype {
        case .link:
            guard let doctype = options else { return nil }
            return (doctype, name)
        case .dynamicLink:
            guard let reference = options,
                let doctype = rowValues[reference]?.nonEmptyString
            else { return nil }
            return (doctype, name)
        default:
            return nil
        }
    }

    private var linkTarget: Route? {
        linkDocument.map { .document(doctype: $0.doctype, name: $0.name) }
    }

    private var isStatusField: Bool {
        fieldname == "status" || fieldname.hasSuffix("_status")
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case "Paid", "Submitted", "Completed", "Active", "Approved", "Delivered":
            return .green
        case "Unpaid", "Partly Paid", "Pending", "To Deliver", "To Bill":
            return .orange
        case "Overdue", "Cancelled", "Rejected", "Failed", "Stopped":
            return .red
        case "Draft":
            return .gray
        default:
            return .blue
        }
    }
}

extension Color {
    /// Desk indicator names ("Green", "Red", …) → native colors.
    init?(indicatorName: String) {
        switch indicatorName.lowercased() {
        case "green": self = .green
        case "red": self = .red
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "blue": self = .blue
        case "purple": self = .purple
        case "gray", "grey": self = .gray
        default: return nil
        }
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255)
    }
}
