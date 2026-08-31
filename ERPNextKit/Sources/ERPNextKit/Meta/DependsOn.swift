import Foundation
import JavaScriptCore

/// Evaluates Frappe `depends_on` visibility expressions against a document.
///
/// Desk evaluates these as JavaScript (`eval:doc.is_return`, or a bare
/// fieldname meaning truthiness). We do exactly the same via JavaScriptCore —
/// pure expression evaluation in an empty context, no web content and no
/// rendering, so the project's no-WebKit (UI) constraint is untouched.
///
/// Anything unevaluable (unknown helpers, syntax errors) counts as visible:
/// we show more, never less.
public final class DependsOnEvaluator {
    private let context: JSContext?

    public init(document: Document) {
        let context = JSContext()
        context?.exceptionHandler = { context, exception in
            context?.exception = exception
        }
        if let context,
            let data = try? JSONEncoder().encode(FrappeValue.object(document.raw)),
            let json = String(data: data, encoding: .utf8) {
            context.evaluateScript(
                """
                var doc = \(json);
                var parent = doc;
                function in_list(list, item) {
                    return Array.isArray(list) && list.includes(item);
                }
                """)
        }
        self.context = context
    }

    public func isVisible(_ expression: String?) -> Bool {
        evaluate(expression) ?? true
    }

    /// Truthiness for `read_only_depends_on`/`mandatory_depends_on`: unlike
    /// visibility, an absent or unevaluable rule counts as *not* triggered
    /// (Desk leaves the field editable when a rule errors).
    public func isTruthy(_ expression: String?) -> Bool {
        evaluate(expression) ?? false
    }

    private func evaluate(_ expression: String?) -> Bool? {
        guard
            let expression = expression?.trimmingCharacters(in: .whitespacesAndNewlines),
            !expression.isEmpty
        else { return nil }
        guard let context else { return nil }

        let js: String
        if expression.hasPrefix("eval:") {
            js = String(expression.dropFirst("eval:".count))
        } else if let quoted = try? JSONEncoder().encode(expression),
            let name = String(data: quoted, encoding: .utf8) {
            // Bare fieldname → truthiness of that field.
            js = "doc[\(name)]"
        } else {
            return nil
        }

        context.exception = nil
        let result = context.evaluateScript("!!(\(js))")
        guard context.exception == nil else { return nil }
        return result?.toBool()
    }
}
