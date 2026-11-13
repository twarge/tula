import ERPNextKit
import SwiftUI

/// Where the keyboard takes an inline cell's focus next. The grid owns the
/// rows, so a cell only reports the gesture.
struct InlineCellNavigation {
    /// Return: on to the next cell like `next`, except that on a last line
    /// still blank it ends the entry instead. False when nothing happened.
    var submit: () -> Bool
    /// The next editable cell: along the row, onto the next row, or onto a
    /// new one after the last. False when there is nowhere to go, so the key
    /// keeps its usual meaning.
    var next: () -> Bool
    var previous: () -> Bool
    /// The same column one row up (-1) or down (1); false at the table's edge.
    var vertical: (Int) -> Bool
    /// Leave the row (Escape).
    var exit: () -> Void
}

/// How far down the table the cell being typed in reaches — the focused
/// field, or the suggestion list open beneath it — in the table's
/// coordinate space. The table keeps that much on screen itself: its cells
/// sit in its own sideways scroll view, and neither the keyboard's
/// avoidance nor a scroll request looks past that to the form.
struct InlineCellRevealKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = max(value ?? next, next)
        }
    }
}

/// Whether a cell has a suggestion list open beneath it.
struct InlineCellListOpenKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Reports the bottom edge of the view it backs as `InlineCellRevealKey`.
private struct RevealBottomEdge: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: InlineCellRevealKey.self,
                value: geometry.frame(in: .named(InlineCellMetrics.tableSpace)).maxY)
        }
    }
}

enum InlineCellMetrics {
    /// The coordinate space a table gives its cells to report positions in.
    static let tableSpace = "inline-cell-table"

    /// Height of one cell's control, and so of every row while the table is
    /// being edited — a row doesn't change height when it turns editable.
    #if os(macOS)
        static let controlHeight: CGFloat = 22
    #else
        static let controlHeight: CGFloat = 32
    #endif

    /// Width a column keeps while its cells can turn into editors. Grid
    /// columns are otherwise content-sized, and a text field has no content
    /// width of its own.
    static func minWidth(for fieldtype: FieldType) -> CGFloat {
        switch fieldtype {
        case .link, .dynamicLink: return 180
        case .int, .float, .currency, .percent: return 92
        case .date: return 150
        case .datetime: return 220
        case .select: return 120
        case .check: return 0
        default: return 150
        }
    }
}

/// One cell of a child-table row being edited in place — Desk's editable
/// grid row, where clicking a line turns its columns into inputs. The
/// compact counterpart of `EditableFieldView`: the same value rules, sized
/// for a grid and wired for cell-to-cell keyboard movement.
struct InlineCellEditor: View {
    let field: DocField
    let value: Binding<FrappeValue?>
    /// The row's own session: its editability rules and sibling values.
    let row: EditSession
    var focus: FocusState<String?>.Binding
    let navigation: InlineCellNavigation

    /// Fieldtypes that edit in the grid. Rich text, code, attachments and
    /// multiselects stay with the full row form, as they do in Desk.
    static func supports(_ fieldtype: FieldType) -> Bool {
        switch fieldtype {
        case .data, .phone, .autocomplete, .int, .float, .currency, .percent,
            .check, .select, .link, .dynamicLink, .date, .datetime, .time,
            .smallText, .text, .longText:
            return true
        default:
            return false
        }
    }

    /// The cells the keyboard walks through — the ones you type into.
    static func takesKeyboardFocus(_ fieldtype: FieldType) -> Bool {
        switch fieldtype {
        case .check, .select, .date, .datetime: return false
        default: return supports(fieldtype)
        }
    }

    var body: some View {
        switch field.fieldtype {
        case .check:
            InlineCheckCell(label: field.label, value: value)

        case .select:
            InlineSelectCell(field: field, value: value, invalid: isMissing)

        case .link:
            InlineLinkCell(
                field: field, doctype: field.options ?? "", text: stringBinding,
                focus: focus, navigation: navigation, invalid: isMissing)

        case .dynamicLink:
            // options names the sibling field holding the target DocType.
            InlineLinkCell(
                field: field,
                doctype: row.value(field.options ?? "")?.nonEmptyString ?? "",
                text: stringBinding, focus: focus, navigation: navigation,
                invalid: isMissing)

        case .date:
            WireDateEditor(value: value, withTime: false)
                .frame(minHeight: InlineCellMetrics.controlHeight)

        case .datetime:
            WireDateEditor(value: value, withTime: true)
                .frame(minHeight: InlineCellMetrics.controlHeight)

        case .int:
            InlineNumberCell(
                field: field, value: value, integer: true, focus: focus,
                navigation: navigation, invalid: isMissing)

        case .float, .currency, .percent:
            InlineNumberCell(
                field: field, value: value, integer: false, focus: focus,
                navigation: navigation, invalid: isMissing)

        case .smallText, .text, .longText:
            InlineTextCell(
                field: field, text: stringBinding, multiline: true, focus: focus,
                navigation: navigation, invalid: isMissing)

        default:
            InlineTextCell(
                field: field, text: stringBinding, multiline: false, focus: focus,
                navigation: navigation, invalid: isMissing)
        }
    }

    /// Desk outlines a mandatory cell in red until it holds something.
    private var isMissing: Bool {
        guard row.isMandatory(field) else { return false }
        return value.wrappedValue?.nonEmptyString == nil
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { value.wrappedValue?.stringValue ?? "" },
            set: { value.wrappedValue = .string($0) })
    }
}

// MARK: - Shared cell behaviour

/// The box around a cell's input: quiet at rest, tinted with focus, red
/// while a mandatory value is missing.
private struct CellChrome: ViewModifier {
    let focused: Bool
    let invalid: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .frame(minHeight: InlineCellMetrics.controlHeight)
            .background(.background, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(stroke, lineWidth: focused ? 1.5 : 1))
    }

    private var stroke: AnyShapeStyle {
        if focused { return AnyShapeStyle(.tint) }
        if invalid { return AnyShapeStyle(Color.red.opacity(0.7)) }
        return AnyShapeStyle(.tertiary)
    }
}

/// Focus identity plus the grid's keys for a cell's text field: Return and
/// Tab go to the next cell, Shift-Tab back, ↑/↓ to the same column of the
/// neighbouring row, Escape out of the row. A cell with something open of
/// its own (the link cell's suggestions) gets each key first through the
/// hooks, so there is one handler per key and no ordering to rely on.
private struct CellKeyboard: ViewModifier {
    let fieldname: String
    var focus: FocusState<String?>.Binding
    let navigation: InlineCellNavigation
    /// Multi-line cells keep ↑/↓ for the caret.
    var arrowsMoveRows = true
    /// Runs before Return or a forward Tab moves on.
    var beforeAdvance: (_ viaTab: Bool) -> Void = { _ in }
    /// True when the cell used the arrow itself.
    var consumeArrow: (_ delta: Int) -> Bool = { _ in false }
    /// True when the cell used Escape itself.
    var consumeEscape: () -> Bool = { false }

    /// Shift-Tab arrives as its own character on macOS.
    private static let backTab = KeyEquivalent("\u{19}")

    func body(content: Content) -> some View {
        content
            .focused(focus, equals: fieldname)
            .background {
                if focus.wrappedValue == fieldname { RevealBottomEdge() }
            }
            .onSubmit {
                beforeAdvance(false)
                if !navigation.submit() { focus.wrappedValue = nil }
            }
            .onKeyPress(keys: [.tab, Self.backTab]) { press in
                if press.key == Self.backTab || press.modifiers.contains(.shift) {
                    return navigation.previous() ? .handled : .ignored
                }
                beforeAdvance(true)
                return navigation.next() ? .handled : .ignored
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let delta = press.key == .upArrow ? -1 : 1
                if consumeArrow(delta) { return .handled }
                guard arrowsMoveRows else { return .ignored }
                return navigation.vertical(delta) ? .handled : .ignored
            }
            .onKeyPress(.escape) {
                if !consumeEscape() { navigation.exit() }
                return .handled
            }
    }
}

// MARK: - Cells

private struct InlineTextCell: View {
    let field: DocField
    let text: Binding<String>
    let multiline: Bool
    var focus: FocusState<String?>.Binding
    let navigation: InlineCellNavigation
    let invalid: Bool

    var body: some View {
        Group {
            if multiline {
                TextField(field.label, text: text, axis: .vertical)
                    .lineLimit(1...4)
            } else {
                TextField(field.label, text: text)
            }
        }
        .textFieldStyle(.plain)
        .modifier(
            CellKeyboard(
                fieldname: field.fieldname, focus: focus, navigation: navigation,
                arrowsMoveRows: !multiline)
        )
        .modifier(
            CellChrome(focused: focus.wrappedValue == field.fieldname, invalid: invalid))
    }
}

/// The grid's numeric cell: `NumericText`'s typing rules, with the text
/// following the value whenever the cell isn't being typed in (an amount
/// recomputed from quantity and rate, say).
private struct InlineNumberCell: View {
    let field: DocField
    let value: Binding<FrappeValue?>
    let integer: Bool
    var focus: FocusState<String?>.Binding
    let navigation: InlineCellNavigation
    let invalid: Bool

    @State private var text: String

    init(
        field: DocField, value: Binding<FrappeValue?>, integer: Bool,
        focus: FocusState<String?>.Binding, navigation: InlineCellNavigation, invalid: Bool
    ) {
        self.field = field
        self.value = value
        self.integer = integer
        self.focus = focus
        self.navigation = navigation
        self.invalid = invalid
        _text = State(initialValue: NumericText.display(value.wrappedValue, integer: integer))
    }

    private var isFocused: Bool { focus.wrappedValue == field.fieldname }

    #if !os(macOS)
        /// A phone gets the number pad. An iPad gets the ordinary keyboard on
        /// its numbers plane: for the number-pad types iPadOS floats a pad
        /// over the field once a hardware keyboard is attached — over the
        /// lines above this one, taking the next tap outside it for its own
        /// dismissal — and on screen it shows this same plane anyway, less
        /// the Return key.
        private var keyboardType: UIKeyboardType {
            guard UIDevice.current.userInterfaceIdiom == .phone else {
                return .numbersAndPunctuation
            }
            return integer ? .numberPad : .decimalPad
        }
    #endif

    var body: some View {
        TextField(field.label, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if !os(macOS)
                .keyboardType(keyboardType)
            #endif
            .modifier(
                CellKeyboard(
                    fieldname: field.fieldname, focus: focus, navigation: navigation)
            )
            .modifier(CellChrome(focused: isFocused, invalid: invalid))
            .onChange(of: text) { _, newText in
                guard newText != NumericText.display(value.wrappedValue, integer: integer)
                else { return }
                if let parsed = NumericText.value(from: newText, integer: integer) {
                    value.wrappedValue = parsed
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    text = NumericText.display(value.wrappedValue, integer: integer)
                }
            }
            .onChange(of: value.wrappedValue) { _, newValue in
                if !isFocused {
                    text = NumericText.display(newValue, integer: integer)
                }
            }
    }
}

/// The same glyph the read-only grid draws, made tappable.
private struct InlineCheckCell: View {
    let label: String
    let value: Binding<FrappeValue?>

    private var isOn: Bool { value.wrappedValue?.boolValue ?? false }

    var body: some View {
        Button {
            value.wrappedValue = .int(isOn ? 0 : 1)
        } label: {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(minWidth: 24, minHeight: InlineCellMetrics.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A Select as one self-contained menu showing its current choice.
private struct InlineSelectCell: View {
    let field: DocField
    let value: Binding<FrappeValue?>
    let invalid: Bool

    private var current: String { value.wrappedValue?.stringValue ?? "" }

    private var choices: [String] {
        var choices = field.selectChoices
        // Keep an out-of-catalog current value selectable rather than
        // silently coercing it.
        if !current.isEmpty, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    var body: some View {
        Menu {
            Picker(field.label, selection: selection) {
                Text("—").tag("")
                ForEach(choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(current.isEmpty ? field.label : current)
                    .foregroundStyle(current.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .modifier(CellChrome(focused: false, invalid: invalid))
        .accessibilityLabel(field.label)
    }

    private var selection: Binding<String> {
        Binding(get: { current }, set: { value.wrappedValue = .string($0) })
    }
}

/// A Link cell with type-ahead. Suggestions open beneath the field, inside
/// the cell, so the row grows rather than anything floating over the grid
/// (popovers fight text-field focus cross-platform): ↑/↓ move the
/// highlight, Return or a tap picks and moves on to the next cell.
private struct InlineLinkCell: View {
    let field: DocField
    let doctype: String
    let text: Binding<String>
    var focus: FocusState<String?>.Binding
    let navigation: InlineCellNavigation
    let invalid: Bool

    @Environment(AppModel.self) private var model
    @State private var suggestions: [LinkOption] = []
    /// The arrow-key highlight; nil until an arrow moves it.
    @State private var highlighted: String?
    /// The value the cell last came to rest on — what it held when focus
    /// arrived, or the suggestion just picked. Suggestions wait until typing
    /// moves off it, so walking through a filled row opens nothing.
    @State private var settled: String?

    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// How many suggestions open at once. The list has to fit between the
    /// field and the keyboard, which on a phone isn't much.
    private var limit: Int {
        #if os(macOS)
            return 6
        #else
            if verticalSizeClass == .compact { return 2 }
            return horizontalSizeClass == .compact ? 4 : 6
        #endif
    }

    private var isFocused: Bool { focus.wrappedValue == field.fieldname }

    private var visible: [LinkOption] { Array(suggestions.prefix(limit)) }

    private var showsSuggestions: Bool {
        guard isFocused, !visible.isEmpty else { return false }
        // A lone suggestion that is already the value offers no choice.
        if visible.count == 1, visible[0].value == text.wrappedValue { return false }
        return text.wrappedValue.isEmpty || text.wrappedValue != settled
    }

    /// The highlight, when an arrow put it on something still listed.
    private var arrowHighlight: String? {
        guard let highlighted, visible.contains(where: { $0.value == highlighted })
        else { return nil }
        return highlighted
    }

    /// What Return picks: the arrow highlight, else an exact match, else the
    /// top suggestion — but nothing for an empty cell. There the list is only
    /// on offer, and Return on a line nobody typed into must not fill it in.
    private var highlightedValue: String? {
        if let arrowHighlight { return arrowHighlight }
        guard !text.wrappedValue.isEmpty else { return nil }
        if visible.contains(where: { $0.value == text.wrappedValue }) {
            return text.wrappedValue
        }
        return visible.first?.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(field.label, text: text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                #endif
                .modifier(
                    CellKeyboard(
                        fieldname: field.fieldname, focus: focus, navigation: navigation,
                        beforeAdvance: { viaTab in
                            guard showsSuggestions else { return }
                            // Return picks what's highlighted; Tab takes only
                            // an arrow-chosen suggestion, and typed text
                            // otherwise stands as typed.
                            let pick = viaTab ? arrowHighlight : highlightedValue
                            if let pick { settle(on: pick) }
                        },
                        consumeArrow: { delta in moveHighlight(by: delta) },
                        consumeEscape: {
                            guard showsSuggestions else { return false }
                            settled = text.wrappedValue
                            return true
                        })
                )
                .modifier(CellChrome(focused: isFocused, invalid: invalid))
            if showsSuggestions {
                suggestionList
                    // The list opens below the field: on a last line that
                    // is past the bottom of the window, or under the
                    // keyboard.
                    .background { RevealBottomEdge() }
                    .preference(key: InlineCellListOpenKey.self, value: true)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                settled = text.wrappedValue
            }
            highlighted = nil
        }
        .onAppear {
            if isFocused { settled = text.wrappedValue }
        }
        .task(id: "\(doctype)|\(text.wrappedValue)|\(isFocused)") {
            guard isFocused, !doctype.isEmpty else {
                suggestions = []
                return
            }
            guard
                let options = await LinkSuggestField.options(
                    doctype: doctype, query: text.wrappedValue, model: model)
            else { return }
            suggestions = options
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { option in
                Button {
                    settle(on: option.value)
                    if !navigation.next() { focus.wrappedValue = nil }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.value)
                            .lineLimit(1)
                        if let description = option.description,
                            description != option.value {
                            Text(description.strippingSimpleHTML())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        option.value == highlightedValue
                            ? Color.accentColor.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
    }

    private func settle(on value: String) {
        text.wrappedValue = value
        settled = value
        highlighted = nil
    }

    /// False when the arrow isn't the list's — it is closed, or ↑ was pressed
    /// with nothing highlighted — leaving it to the grid.
    private func moveHighlight(by delta: Int) -> Bool {
        guard showsSuggestions else { return false }
        guard let current = visible.firstIndex(where: { $0.value == highlightedValue })
        else {
            guard delta > 0 else { return false }
            highlighted = visible.first?.value
            return true
        }
        highlighted = visible[min(max(current + delta, 0), visible.count - 1)].value
        return true
    }
}
