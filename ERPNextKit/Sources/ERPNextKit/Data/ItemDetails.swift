import Foundation

/// What Desk does when an item is picked on a transaction line: it asks the
/// server for the item's details — name, UOM, list price, accounts, the
/// pricing rules that apply — and lays the answer over the row
/// (`erpnext.stock.get_item_details.get_item_details`, called from
/// `transaction.js`'s `item_code` handler). This is the pure-data half: which
/// lines it applies to, what to ask, and how an answer lands on a row.
public enum ItemDetails {
    /// The row field whose value the lookup is for.
    public static let itemField = "item_code"

    /// The transactions ERPNext prices this way — its own `sales_doctypes`
    /// and `purchase_doctypes`. The server refuses the call for anything
    /// outside its list, and other DocTypes with an item column (stock
    /// entries, BOMs) fill their lines by different rules.
    public static let transactionDoctypes: Set<String> = [
        "Quotation", "Sales Order", "Delivery Note", "Sales Invoice", "POS Invoice",
        "Material Request", "Supplier Quotation", "Purchase Order", "Purchase Receipt",
        "Purchase Invoice",
    ]

    /// Whether picking an item on a line of `childMeta`, in a `parentDoctype`
    /// document, fills the line from the server.
    public static func applies(parentDoctype: String?, childMeta: DocTypeMeta) -> Bool {
        guard let parentDoctype, transactionDoctypes.contains(parentDoctype),
            let field = childMeta.field(named: itemField)
        else { return false }
        return field.fieldtype == .link && field.options == "Item"
    }

    /// The pricing context Desk sends, from the document and the line as
    /// they stand. Nil while the line has no item.
    ///
    /// Three departures from Desk's call, all deliberate. The whole document
    /// is not sent along (`doc`): the request is a GET and has to fit a URL,
    /// so the one thing the server reads from it for a fresh line, the
    /// transaction date, travels in the context instead — as ERPNext's own
    /// Material Request form does. The line's UOM, conversion factor and
    /// weight are left out, because Desk blanks them before asking so the new
    /// item brings its own. And no rate is ever sent: the server can record a
    /// sent rate as the item's price.
    public static func arguments(
        parentDoctype: String, parent: [String: FrappeValue],
        row: [String: FrappeValue], childDoctype: String
    ) -> [String: FrappeValue]? {
        guard let item = row[itemField]?.nonEmptyString else { return nil }

        var context: [String: FrappeValue] = [
            itemField: .string(item),
            "doctype": .string(parentDoctype),
            "child_doctype": .string(childDoctype),
            "qty": row["qty"].flatMap { $0.isTruthy ? $0 : nil } ?? .int(1),
        ]
        // Empty values say nothing the server doesn't assume, and the
        // context has to stay short.
        func put(_ key: String, _ value: FrappeValue?) {
            if let value, value.isTruthy { context[key] = value }
        }

        put("name", parent["name"])
        put("company", parent["company"])
        put("customer", truthy(parent["customer"]) ?? parent["party_name"])
        for key in [
            "quotation_to", "supplier", "currency", "conversion_rate", "price_list_currency",
            "plc_conversion_rate", "is_internal_customer", "is_internal_supplier",
            "order_type", "is_pos", "is_return", "return_against", "is_subcontracted",
            "is_old_subcontracting_flow", "ignore_pricing_rule", "tax_category",
            "set_warehouse", "material_request_type", "posting_date",
        ] {
            put(key, parent[key])
        }
        put("price_list", truthy(parent["selling_price_list"]) ?? parent["buying_price_list"])
        put("transaction_date", truthy(parent["transaction_date"]) ?? parent["posting_date"])
        if parentDoctype == "Sales Invoice" || parentDoctype == "Purchase Invoice" {
            put("update_stock", parent["update_stock"])
        }
        if parentDoctype == "Purchase Invoice" {
            put("bill_date", parent["bill_date"])
        }
        if parent["is_pos"]?.isTruthy == true {
            put("pos_profile", parent["pos_profile"])
        }

        put("child_docname", row["name"])
        put("project", truthy(row["project"]) ?? parent["project"])
        for key in [
            "serial_no", "batch_no", "warehouse", "from_warehouse", "manufacturer",
            "cost_center", "item_tax_template", "use_serial_batch_fields",
            "serial_and_batch_bundle",
        ] {
            put(key, row[key])
        }
        return context
    }

    /// A row with the server's answer laid over it, as Desk lays it over the
    /// grid row — with one difference: a field edited since the question was
    /// asked (`asked` is the row as it stood then) keeps the edit, so a
    /// quantity typed while the answer was on its way isn't put back to 1.
    ///
    /// Only the child DocType's own fields are taken; the answer also carries
    /// working values that are no column of the row. The rate is then derived
    /// from the list price as Desk derives it, and the amount follows.
    public static func applying(
        _ details: [String: FrappeValue], to row: [String: FrappeValue],
        asked: [String: FrappeValue], meta: DocTypeMeta
    ) -> [String: FrappeValue] {
        var row = row
        func isUntouched(_ key: String) -> Bool {
            (row[key] ?? .null) == (asked[key] ?? .null)
        }

        let rateWasUntouched = isUntouched("rate")
        for field in meta.fields {
            let key = field.fieldname
            // Every field that holds a value of its own, shown or not: the
            // accounts and warehouse an item brings are mostly hidden ones.
            switch field.fieldtype {
            case .table, .tableMultiSelect, .button: continue
            default: if field.fieldtype.isLayoutBreak { continue }
            }
            guard let value = details[key], isUntouched(key),
                (row[key] ?? .null) != value
            else { continue }
            row[key] = value
        }

        if rateWasUntouched, let rateField = meta.field(named: "rate") {
            // The pricing the rate comes from: the row's own columns where
            // it has them, the answer's working values where it doesn't.
            var pricing: [String: FrappeValue] = [:]
            for key in pricingFields {
                pricing[key] = meta.field(named: key) != nil ? row[key] : details[key]
            }
            if let rate = lineRate(of: pricing, precision: rateField.precision) {
                row["rate"] = .double(rate)
            }
        }
        return meta.settingRowAmount(in: row)
    }

    private static let pricingFields = [
        "price_list_rate", "margin_type", "margin_rate_or_amount", "discount_percentage",
        "discount_amount", "rate",
    ]

    /// The line rate Desk shows once the details are in
    /// (`apply_pricing_rule_on_item`): the list price, plus the margin, less
    /// the discount — the same derivation the server repeats on save. Nil for
    /// a row with no list price to start from; Desk's answer for a material
    /// request, which carries a rate and no pricing, stands as sent.
    public static func lineRate(of row: [String: FrappeValue], precision: Int? = nil) -> Double? {
        guard let listPrice = row["price_list_rate"]?.doubleValue else {
            return row["rate"]?.doubleValue
        }
        let margin = row["margin_rate_or_amount"]?.doubleValue ?? 0
        let withMargin =
            row["margin_type"]?.nonEmptyString == "Percentage"
            ? listPrice + listPrice * margin / 100 : listPrice + margin

        var discount = row["discount_amount"]?.doubleValue ?? 0
        if discount == 0, let percentage = row["discount_percentage"]?.doubleValue,
            percentage != 0 {
            discount = withMargin * percentage / 100
        }
        let rate = discount > 0 ? withMargin - discount : withMargin

        // Nine places is what the server stores; rounding there only sheds
        // binary noise (85.00000000000001).
        let scale = pow(10, Double(precision ?? 9))
        return (rate * scale).rounded() / scale
    }

    private static func truthy(_ value: FrappeValue?) -> FrappeValue? {
        value.flatMap { $0.isTruthy ? $0 : nil }
    }
}
