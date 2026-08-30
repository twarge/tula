import ERPNextKit
import SwiftUI

/// One condition in the detailed filter editor: field → operator → value,
/// translating to Frappe's `[fieldname, operator, value]` wire tuples
/// (ARCHITECTURE.md §10).
struct FilterCondition: Identifiable, Hashable {
    var id = UUID()
    var fieldname: String = "name"
    var op: FilterOperator = .equals
    var value: String = ""

    /// Content-only key (excludes id) for cache/task identity.
    var key: String { "\(fieldname)\u{1}\(op.rawValue)\u{1}\(value)" }

    func listFilter() -> ListFilter? {
        switch op {
        case .isSet:
            return ListFilter(fieldname, "is", .string("set"))
        case .isNotSet:
            return ListFilter(fieldname, "is", .string("not set"))
        case .like:
            guard !value.isEmpty else { return nil }
            return ListFilter(fieldname, "like", .string("%\(value)%"))
        case .notLike:
            guard !value.isEmpty else { return nil }
            return ListFilter(fieldname, "not like", .string("%\(value)%"))
        case .between:
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return ListFilter(
                fieldname, "between", .array([.string(parts[0]), .string(parts[1])]))
        case .timespan:
            guard !value.isEmpty else { return nil }
            return ListFilter(fieldname, "timespan", .string(value))
        default:
            guard !value.isEmpty else { return nil }
            return ListFilter(fieldname, op.rawValue, .string(value))
        }
    }
}

enum FilterOperator: String, CaseIterable, Identifiable {
    case equals = "="
    case notEquals = "!="
    case like = "like"
    case notLike = "not like"
    case greaterThan = ">"
    case lessThan = "<"
    case greaterOrEqual = ">="
    case lessOrEqual = "<="
    case between = "between"
    case timespan = "timespan"
    case isSet = "is set"
    case isNotSet = "is not set"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .equals: return "Equals"
        case .notEquals: return "Not Equals"
        case .like: return "Like"
        case .notLike: return "Not Like"
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .greaterOrEqual: return "≥"
        case .lessOrEqual: return "≤"
        case .between: return "Between"
        case .timespan: return "Timespan"
        case .isSet: return "Is Set"
        case .isNotSet: return "Is Not Set"
        }
    }

    var takesValue: Bool {
        switch self {
        case .isSet, .isNotSet: return false
        default: return true
        }
    }

    /// Mirrors Desk's operator sets per fieldtype (ARCHITECTURE.md §10).
    static func operators(for fieldtype: FieldType) -> [FilterOperator] {
        switch fieldtype {
        case .select:
            return [.equals, .notEquals, .isSet, .isNotSet]
        case .check:
            return [.equals]
        case .int, .float, .currency, .percent:
            return [
                .equals, .notEquals, .greaterThan, .lessThan, .greaterOrEqual,
                .lessOrEqual, .between, .isSet, .isNotSet,
            ]
        case .date, .datetime:
            return [
                .equals, .between, .timespan, .greaterThan, .lessThan,
                .greaterOrEqual, .lessOrEqual, .isSet, .isNotSet,
            ]
        case .link, .dynamicLink:
            return [.equals, .notEquals, .like, .notLike, .isSet, .isNotSet]
        default:
            return [.like, .notLike, .equals, .notEquals, .isSet, .isNotSet]
        }
    }
}

/// A field offered by the filter editor.
struct FilterableField: Identifiable, Hashable {
    var fieldname: String
    var label: String
    var fieldtype: FieldType
    var options: String?

    var id: String { fieldname }

    /// Presentable document fields plus the standard columns every DocType has.
    static func all(for meta: DocTypeMeta) -> [FilterableField] {
        var fields: [FilterableField] = [
            FilterableField(fieldname: "name", label: "ID", fieldtype: .data, options: nil)
        ]
        for field in meta.fields
        where field.fieldtype.isPresentable && !field.hidden
            && field.fieldtype != .table && field.fieldtype != .tableMultiSelect
            && field.fieldtype != .attach && field.fieldtype != .attachImage {
            fields.append(
                FilterableField(
                    fieldname: field.fieldname, label: field.label,
                    fieldtype: field.fieldtype, options: field.options))
        }
        fields.append(
            FilterableField(fieldname: "owner", label: "Owner", fieldtype: .data, options: nil))
        fields.append(
            FilterableField(
                fieldname: "creation", label: "Created", fieldtype: .date, options: nil))
        fields.append(
            FilterableField(
                fieldname: "modified", label: "Modified", fieldtype: .date, options: nil))
        return fields
    }
}

/// Desk's "Filter" popover, natively: condition rows with field/operator/value
/// controls, Add / Clear / Apply. Works on a draft; Apply publishes.
struct FilterEditorView: View {
    let meta: DocTypeMeta
    @Binding var applied: [FilterCondition]

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var draft: [FilterCondition] = []
    @State private var presets: [(name: String, conditions: [FilterCondition])] = []

    private var fields: [FilterableField] { FilterableField.all(for: meta) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($draft) { $condition in
                        FilterConditionRow(
                            condition: $condition, fields: fields,
                            onRemove: { draft.removeAll { $0.id == condition.id } })
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                Button {
                    draft.append(FilterCondition())
                } label: {
                    Label("Add a Filter", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                if !presets.isEmpty {
                    Menu {
                        ForEach(presets, id: \.name) { preset in
                            Button(preset.name) { draft = preset.conditions }
                        }
                    } label: {
                        Label("Presets", systemImage: "bookmark")
                    }
                    .fixedSize()
                }

                Spacer()

                Button("Clear Filters") {
                    applied = []
                    dismiss()
                }
                Button("Apply Filters") {
                    applied = draft.filter { $0.listFilter() != nil }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        #if os(macOS)
            .frame(minWidth: 540, minHeight: 220)
        #endif
        .onAppear {
            draft = applied.isEmpty ? [FilterCondition()] : applied
        }
        .task {
            await loadPresets()
        }
    }

    /// Desk's saved filters (the List Filter DocType) offered read-only.
    private func loadPresets() async {
        guard
            let docs = try? await model.dataSource.list(
                "List Filter", fields: ["name", "filter_name", "filters"],
                filters: [ListFilter("reference_doctype", "=", .string(meta.name))],
                orderBy: "modified desc", limitStart: 0, limitPageLength: 20)
        else { return }
        presets = docs.compactMap { doc in
            guard let label = doc["filter_name"]?.nonEmptyString,
                let raw = doc["filters"]?.nonEmptyString,
                let decoded = try? FrappeValue.decode(from: Data(raw.utf8)),
                let rows = decoded.arrayValue
            else { return nil }
            let conditions = rows.compactMap { Self.condition(from: $0) }
            guard !conditions.isEmpty else { return nil }
            return (label, conditions)
        }
    }

    /// `[doctype, fieldname, operator, value]` (or the 3-tuple form) → a
    /// native condition; unsupported operators are skipped.
    private static func condition(from row: FrappeValue) -> FilterCondition? {
        guard var parts = row.arrayValue, parts.count >= 3 else { return nil }
        if parts.count >= 4 { parts.removeFirst() }
        guard let fieldname = parts[0].nonEmptyString,
            let opRaw = parts[1].nonEmptyString?.lowercased()
        else { return nil }
        let rawValue = parts.count > 2 ? parts[2] : .null

        var op: FilterOperator
        var value: String
        switch opRaw {
        case "is":
            op = rawValue.stringValue == "not set" ? .isNotSet : .isSet
            value = ""
        case "between":
            op = .between
            value = (rawValue.arrayValue ?? []).compactMap { $0.stringValue }
                .joined(separator: "|")
        case "like", "not like":
            op = opRaw == "like" ? .like : .notLike
            value = (rawValue.stringValue ?? "").replacingOccurrences(of: "%", with: "")
        default:
            guard let known = FilterOperator(rawValue: opRaw) else { return nil }
            op = known
            value = rawValue.stringValue ?? ""
        }
        return FilterCondition(fieldname: fieldname, op: op, value: value)
    }
}

private struct FilterConditionRow: View {
    @Binding var condition: FilterCondition
    let fields: [FilterableField]
    let onRemove: () -> Void

    private var field: FilterableField? {
        fields.first { $0.fieldname == condition.fieldname }
    }

    private var operators: [FilterOperator] {
        FilterOperator.operators(for: field?.fieldtype ?? .data)
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(fields) { candidate in
                    Button(candidate.label) {
                        condition.fieldname = candidate.fieldname
                        let ops = FilterOperator.operators(for: candidate.fieldtype)
                        if !ops.contains(condition.op) {
                            condition.op = ops[0]
                        }
                        condition.value = ""
                    }
                }
            } label: {
                Text(field?.label ?? condition.fieldname)
                    .frame(minWidth: 90, alignment: .leading)
            }
            .fixedSize()

            Menu {
                ForEach(operators) { op in
                    Button(op.label) { condition.op = op }
                }
            } label: {
                Text(condition.op.label)
                    .frame(minWidth: 70, alignment: .leading)
            }
            .fixedSize()

            valueEditor
                .frame(maxWidth: .infinity)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    /// Frappe's named ranges for the `timespan` operator.
    static let timespans = [
        "today", "yesterday", "this week", "this month", "this quarter",
        "this year", "last week", "last month", "last quarter",
        "last 6 months", "last year",
    ]

    private func betweenComponent(_ index: Int) -> Binding<String> {
        Binding {
            let parts = condition.value.split(
                separator: "|", maxSplits: 1, omittingEmptySubsequences: false
            ).map(String.init)
            return index < parts.count ? parts[index] : ""
        } set: { newValue in
            var parts = condition.value.split(
                separator: "|", maxSplits: 1, omittingEmptySubsequences: false
            ).map(String.init)
            while parts.count < 2 { parts.append("") }
            parts[index] = newValue
            condition.value = parts.joined(separator: "|")
        }
    }

    private func betweenDateBinding(_ index: Int) -> Binding<Date> {
        Binding {
            ValueFormatting.wireDateValue(betweenComponent(index).wrappedValue) ?? Date()
        } set: { date in
            betweenComponent(index).wrappedValue = ValueFormatting.wireDateString(date)
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        if !condition.op.takesValue {
            Spacer()
        } else if condition.op == .timespan {
            Menu {
                ForEach(Self.timespans, id: \.self) { span in
                    Button(span.capitalized) { condition.value = span }
                }
            } label: {
                Text(condition.value.isEmpty ? "Choose…" : condition.value.capitalized)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if condition.op == .between {
            if field?.fieldtype == .date || field?.fieldtype == .datetime {
                HStack(spacing: 6) {
                    DatePicker("", selection: betweenDateBinding(0), displayedComponents: .date)
                        .labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("", selection: betweenDateBinding(1), displayedComponents: .date)
                        .labelsHidden()
                }
            } else {
                HStack(spacing: 6) {
                    TextField("From", text: betweenComponent(0))
                        .textFieldStyle(.roundedBorder)
                    Text("–").foregroundStyle(.secondary)
                    TextField("To", text: betweenComponent(1))
                        .textFieldStyle(.roundedBorder)
                }
            }
        } else {
            switch field?.fieldtype {
            case .select:
                Menu {
                    ForEach(selectChoices, id: \.self) { choice in
                        Button(choice) { condition.value = choice }
                    }
                } label: {
                    Text(condition.value.isEmpty ? "Choose…" : condition.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .check:
                Menu {
                    Button("Yes") { condition.value = "1" }
                    Button("No") { condition.value = "0" }
                } label: {
                    Text(
                        condition.value.isEmpty
                            ? "Choose…" : (condition.value == "1" ? "Yes" : "No")
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .date, .datetime:
                DatePicker(
                    "", selection: dateBinding, displayedComponents: .date
                )
                .labelsHidden()
            default:
                TextField("Value", text: $condition.value)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
        }
    }

    private var selectChoices: [String] {
        (field?.options ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private var dateBinding: Binding<Date> {
        Binding {
            ValueFormatting.wireDateValue(condition.value) ?? Date()
        } set: { date in
            condition.value = ValueFormatting.wireDateString(date)
        }
    }
}
