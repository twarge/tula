import Foundation

/// Parses what a person types into a numeric field, in a locale's own
/// conventions — the same ones the display formatters print with, so a
/// value can be retyped the way it's shown.
public enum NumberInput {
    /// Grouping separators ("100,000"), spaces, and currency or percent
    /// symbols are dropped; the locale's decimal mark is the only one
    /// honored. Nil when the text isn't a number yet ("", "-").
    public static func double(from text: String, locale: Locale = .current) -> Double? {
        let decimal = locale.decimalSeparator ?? "."
        var normalized = ""
        var rest = Substring(text)
        while let character = rest.first {
            if rest.hasPrefix(decimal) {
                normalized.append(".")
                rest = rest.dropFirst(decimal.count)
                continue
            }
            rest = rest.dropFirst()
            if character.isASCII, character.isNumber {
                normalized.append(character)
            } else if character == "-" || character == "−" {
                normalized.append("-")
            }
            // Anything else — grouping marks, spaces, symbols — is dropped.
        }
        return Double(normalized)
    }

    /// Whole numbers only: "100,000" is 100000, "1.5" is not an integer.
    public static func int(from text: String, locale: Locale = .current) -> Int? {
        guard let number = double(from: text, locale: locale),
            number == number.rounded(), abs(number) < 9e15
        else { return nil }
        return Int(number)
    }
}
