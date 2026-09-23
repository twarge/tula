import Foundation
import JavaScriptCore

/// A server-defined report (the `Report` DocType): the long tail beyond the
/// built-in financial statements. Every Query/Script report renders through
/// the same generic report screen.
public struct ReportInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var reportType: String
    public var refDoctype: String?
    public var module: String?

    public init(name: String, reportType: String, refDoctype: String? = nil, module: String? = nil) {
        self.name = name
        self.reportType = reportType
        self.refDoctype = refDoctype
        self.module = module
    }

    public var id: String { name }
}

/// One filter of a query/script report, parsed from the report's client
/// script (ARCHITECTURE.md §7 v2 / §12 Phase 3).
public struct ReportFilterDefinition: Sendable, Hashable, Identifiable {
    public var fieldname: String
    public var label: String
    public var fieldtype: FieldType
    /// Link target for Link filters.
    public var options: String?
    /// Normalized Select choices (script options come as newline strings,
    /// string arrays, or {label, value} dicts).
    public var selectOptions: [String]
    public var defaultValue: String?
    public var required: Bool
    public var hidden: Bool
    /// Desk MultiSelectList filters take list values on the wire even when
    /// only one entry is set — `party in %(party)s` server-side.
    public var isMultiSelect: Bool = false

    public var id: String { fieldname }
}

/// Extracts a report's filter definitions from its Desk client script.
///
/// This is the one place ERPNext is not metadata-driven: filters live in
/// JavaScript (`frappe.query_reports["X"] = { filters: [...] }`). We do what
/// Desk does — evaluate the script — inside a sandboxed JavaScriptCore
/// context with a stub `frappe` API. Function-valued keys (get_query,
/// formatters) drop out via JSON serialization; date/default helpers are
/// stubbed with real implementations so script-computed defaults (month
/// start, today, session company) resolve to real values. Anything that
/// fails evaluates to nil and the caller falls back gracefully.
public enum ReportFilterParser {
    public static func definitions(
        reportName: String, script: String, defaultCompany: String? = nil,
        defaultFiscalYear: String? = nil
    ) -> [ReportFilterDefinition]? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { context, exception in
            context?.exception = exception
        }

        guard let nameJSON = jsonLiteral(reportName),
            let companyJSON = jsonLiteral(defaultCompany ?? ""),
            let fiscalYearJSON = jsonLiteral(defaultFiscalYear ?? "")
        else { return nil }

        context.evaluateScript(
            stubEnvironment(companyJSON: companyJSON, fiscalYearJSON: fiscalYearJSON))
        context.exception = nil
        context.evaluateScript("try { \(script) \n} catch (e) {}")

        context.exception = nil
        let result = context.evaluateScript(
            """
            (function() {
                var report = frappe.query_reports[\(nameJSON)];
                if (!report || !report.filters) { return null; }
                try { return JSON.stringify(report.filters); } catch (e) { return null; }
            })()
            """)
        guard context.exception == nil, let json = result?.toString(), json != "null",
            let decoded = try? FrappeValue.decode(from: Data(json.utf8)),
            let entries = decoded.arrayValue
        else { return nil }

        let definitions = entries.compactMap { entry -> ReportFilterDefinition? in
            guard let dict = entry.objectValue,
                let fieldname = dict["fieldname"]?.nonEmptyString
            else { return nil }
            let rawFieldtype = dict["fieldtype"]?.nonEmptyString ?? "Data"
            let fieldtype = FieldType(rawValue: rawFieldtype)

            var linkTarget: String?
            var choices: [String] = []
            if let optionsString = dict["options"]?.nonEmptyString {
                if fieldtype == .select {
                    choices = optionsString.split(separator: "\n").map(String.init)
                        .filter { !$0.isEmpty }
                } else {
                    linkTarget = optionsString
                }
            } else if let optionsArray = dict["options"]?.arrayValue {
                choices = optionsArray.compactMap { option in
                    option.nonEmptyString ?? option.objectValue?["value"]?.nonEmptyString
                }
            }

            return ReportFilterDefinition(
                fieldname: fieldname,
                label: dict["label"]?.nonEmptyString
                    ?? fieldname.replacingOccurrences(of: "_", with: " ").capitalized,
                fieldtype: fieldtype,
                options: linkTarget,
                selectOptions: choices,
                defaultValue: dict["default"]?.nonEmptyString,
                required: dict["reqd"]?.boolValue ?? false,
                hidden: dict["hidden"]?.boolValue ?? false,
                isMultiSelect: rawFieldtype == "MultiSelectList")
        }
        return definitions.isEmpty ? nil : definitions
    }

    private static func jsonLiteral(_ string: String) -> String? {
        guard let data = try? JSONEncoder().encode(string) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The minimal Desk surface report scripts touch at filter-definition
    /// time. Date helpers return real dates so defaults come out usable; the
    /// session company and fiscal year are the app's current ones.
    private static func stubEnvironment(companyJSON: String, fiscalYearJSON: String) -> String {
        """
        function __(s) { return s; }
        function _pad(n) { return (n < 10 ? "0" : "") + n; }
        function _fmt(d) {
            return d.getFullYear() + "-" + _pad(d.getMonth() + 1) + "-" + _pad(d.getDate());
        }
        var frappe = {
            query_reports: {},
            _company: \(companyJSON),
            _fiscalYear: \(fiscalYearJSON),
            provide: function(namespace) {
                var parts = namespace.split(".");
                var obj = globalThis;
                for (var i = 0; i < parts.length; i++) {
                    obj[parts[i]] = obj[parts[i]] || {};
                    obj = obj[parts[i]];
                }
                return obj;
            },
            _default: function(key) {
                if (key === "Company" || key === "company") { return frappe._company; }
                if (key === "fiscal_year" || key === "Fiscal Year") { return frappe._fiscalYear; }
                return "";
            },
            defaults: {
                get_user_default: function(key) { return frappe._default(key); },
                get_default: function(key) { return frappe._default(key); }
            },
            user_defaults: { company: \(companyJSON), fiscal_year: \(fiscalYearJSON) },
            sys_defaults: { company: \(companyJSON), fiscal_year: \(fiscalYearJSON) },
            boot: { sysdefaults: { company: \(companyJSON), fiscal_year: \(fiscalYearJSON) } },
            datetime: {
                get_today: function() { return _fmt(new Date()); },
                nowdate: function() { return _fmt(new Date()); },
                now_date: function() { return _fmt(new Date()); },
                month_start: function() {
                    var d = new Date();
                    return _fmt(new Date(d.getFullYear(), d.getMonth(), 1));
                },
                month_end: function() {
                    var d = new Date();
                    return _fmt(new Date(d.getFullYear(), d.getMonth() + 1, 0));
                },
                year_start: function() {
                    return _fmt(new Date(new Date().getFullYear(), 0, 1));
                },
                year_end: function() {
                    return _fmt(new Date(new Date().getFullYear(), 11, 31));
                },
                add_months: function(dateString, months) {
                    var d = new Date(dateString);
                    d.setMonth(d.getMonth() + months);
                    return _fmt(d);
                },
                add_days: function(dateString, days) {
                    var d = new Date(dateString);
                    d.setDate(d.getDate() + days);
                    return _fmt(d);
                },
                obj_to_str: function(d) { return typeof d === "string" ? d : _fmt(d); },
                str_to_obj: function(s) { return new Date(s); }
            },
            query_report: { refresh: function() {} },
            model: { get_list: function() { return []; } },
            db: { get_list: function() { return { then: function() {} }; },
                  get_value: function() { return { then: function() {} }; } },
            call: function() { return { then: function() {} }; },
            ui: { form: { make_control: function() { return {}; } } }
        };
        var erpnext = {
            utils: {
                get_fiscal_year: function() { return null; },
                add_dimensions: function() {},
                add_inventory_dimensions: function() {}
            },
            get_fiscal_year: function() { return null; }
        };
        var locals = {};
        var cur_frm = null;
        """
    }
}
