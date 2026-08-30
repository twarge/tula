import ERPNextKit
import Foundation

/// One formatting rulebook for every surface (report cells, list columns,
/// form fields, child tables) so a Currency value looks identical everywhere.
enum ValueFormatting {
    private static let wireDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let wireDatetime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Wire dates are calendar dates with no timezone; parse and display must
    /// use the same (UTC) zone or the shown day drifts by one.
    private static let displayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Frappe datetimes carry the site's local wall-clock time with no zone;
    /// shown as-is rather than shifted into the device zone.
    private static let displayDatetime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func string(
        for value: FrappeValue?, fieldtype: FieldType, currencyCode: String? = nil,
        precision: Int? = nil
    ) -> String {
        guard let value, !value.isNull else { return "" }

        switch fieldtype {
        case .currency:
            guard let number = value.doubleValue else { return value.stringValue ?? "" }
            if let currencyCode {
                return number.formatted(
                    .currency(code: currencyCode).precision(.fractionLength(precision ?? 2)))
            }
            return number.formatted(.number.precision(.fractionLength(precision ?? 2)))

        case .float:
            guard let number = value.doubleValue else { return value.stringValue ?? "" }
            return number.formatted(.number.precision(.fractionLength(0...(precision ?? 3))))

        case .int:
            return value.intValue?.formatted() ?? (value.stringValue ?? "")

        case .percent:
            guard let number = value.doubleValue else { return value.stringValue ?? "" }
            return number.formatted(.number.precision(.fractionLength(0...2))) + "%"

        case .date:
            guard let raw = value.nonEmptyString else { return "" }
            if let date = wireDate.date(from: raw) {
                return displayDate.string(from: date)
            }
            return raw

        case .datetime:
            guard let raw = value.nonEmptyString else { return "" }
            if let date = wireDatetime.date(from: String(raw.prefix(19))) {
                return displayDatetime.string(from: date)
            }
            return raw

        case .duration:
            guard let seconds = value.doubleValue else { return value.stringValue ?? "" }
            return Duration.seconds(seconds).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .narrow))

        case .check:
            return value.boolValue == true ? "Yes" : "No"

        case .textEditor, .htmlEditor, .html:
            return (value.stringValue ?? "").strippingSimpleHTML()

        default:
            return value.stringValue ?? ""
        }
    }

    /// Wire-format helpers for the filter editor's date pickers.
    static func wireDateValue(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return wireDate.date(from: String(raw.prefix(10)))
    }

    static func wireDateString(_ date: Date) -> String {
        wireDate.string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Desk-style "11 h ago" from a wire `modified` timestamp.
    static func relativeModified(_ raw: String?) -> String? {
        guard let raw, let date = wireDatetime.date(from: String(raw.prefix(19))) else {
            return nil
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Currency-code resolution, in Desk's order: the column/field `options`
    /// names a sibling field holding the code (usually `currency`); failing
    /// that, `options` may itself be a code; failing that, the company default.
    static func currencyCode(
        options: String?, rowValues: [String: FrappeValue],
        parentValues: [String: FrappeValue] = [:], fallback: String?
    ) -> String? {
        if let options {
            if let code = rowValues[options]?.nonEmptyString { return code }
            if let code = parentValues[options]?.nonEmptyString { return code }
            if options.count == 3, options == options.uppercased() { return options }
        }
        if let code = rowValues["currency"]?.nonEmptyString { return code }
        return fallback
    }
}
