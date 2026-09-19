import ERPNextKit
import SwiftUI
import UniformTypeIdentifiers

/// The editable counterpart of `FieldValueView` (W3): one editor per
/// fieldtype, all writing `FrappeValue`s into the enclosing `EditSession`
/// draft. HTML-ish fields edit as plain text in v1; types without a
/// sensible native editor never reach here (`EditSession.hasEditor`).
struct EditableFieldView: View {
    let field: DocField
    let session: EditSession

    var body: some View {
        switch field.fieldtype {
        case .check:
            Toggle(field.label, isOn: boolBinding)
                .toggleStyle(.checkbox)

        case .select:
            Picker(field.label, selection: stringBinding) {
                Text("—").tag("")
                ForEach(selectChoices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

        case .link:
            LinkSuggestField(
                doctype: field.options ?? "", text: stringBinding)

        case .dynamicLink:
            // options names the sibling field holding the target DocType.
            LinkSuggestField(
                doctype: session.value(field.options ?? "")?.nonEmptyString ?? "",
                text: stringBinding)

        case .date:
            WireDateEditor(value: session.binding(for: field.fieldname), withTime: false)

        case .datetime:
            WireDateEditor(value: session.binding(for: field.fieldname), withTime: true)

        case .int:
            NumericField(
                value: session.binding(for: field.fieldname), integer: true)

        case .float, .currency, .percent:
            NumericField(
                value: session.binding(for: field.fieldname), integer: false)

        case .smallText, .text, .longText, .textEditor, .htmlEditor, .markdown,
            .code, .json:
            TextEditor(text: stringBinding)
                .font(
                    field.fieldtype == .code || field.fieldtype == .json
                        ? .body.monospaced() : .body)
                .frame(minHeight: 64, maxHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary))

        case .attach, .attachImage:
            AttachFieldEditor(field: field, session: session)

        default:
            TextField(field.label, text: stringBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
    }

    private var selectChoices: [String] {
        var choices = field.selectChoices
        // Keep an out-of-catalog current value selectable rather than
        // silently coercing it.
        if let current = session.value(field.fieldname)?.nonEmptyString,
            !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { session.value(field.fieldname)?.stringValue ?? "" },
            set: { session.set(field.fieldname, .string($0)) })
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { session.value(field.fieldname)?.boolValue ?? false },
            set: { session.set(field.fieldname, .int($0 ? 1 : 0)) })
    }
}

extension ToggleStyle where Self == SwitchToggleStyle {
    /// iOS has no `.checkbox`; a switch is the native equivalent.
    #if !os(macOS)
        static var checkbox: SwitchToggleStyle { .init() }
    #endif
}

/// Numeric editor that tolerates in-progress typing ("3.", "-"): the text
/// is local state, committed into the draft whenever it parses. Both
/// directions follow the system locale — typed grouping separators are
/// accepted ("100,000"), and the value reads back grouped like the display
/// formatters print it.
private struct NumericField: View {
    let value: Binding<FrappeValue?>
    let integer: Bool

    @State private var text: String
    @FocusState private var focused: Bool

    init(value: Binding<FrappeValue?>, integer: Bool) {
        self.value = value
        self.integer = integer
        _text = State(initialValue: Self.display(value.wrappedValue, integer: integer))
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(maxWidth: 160)
            .focused($focused)
            #if !os(macOS)
                .keyboardType(integer ? .numberPad : .decimalPad)
            #endif
            .onChange(of: text) { _, newText in
                // The canonical text of the current value (set on blur) is
                // not an edit; reparsing it would only shed precision.
                guard newText != Self.display(value.wrappedValue, integer: integer)
                else { return }
                if newText.isEmpty {
                    value.wrappedValue = integer ? .int(0) : .double(0)
                } else if integer, let parsed = NumberInput.int(from: newText) {
                    value.wrappedValue = .int(parsed)
                } else if !integer, let parsed = NumberInput.double(from: newText) {
                    value.wrappedValue = .double(parsed)
                }
            }
            .onChange(of: focused) { _, isFocused in
                // Re-canonicalize on blur so "3." becomes "3" and "100000"
                // becomes "100,000".
                if !isFocused {
                    text = Self.display(value.wrappedValue, integer: integer)
                }
            }
    }

    private static func display(_ value: FrappeValue?, integer: Bool) -> String {
        if integer { return value?.intValue?.formatted() ?? "" }
        guard let number = value?.doubleValue else { return "" }
        return number.formatted(.number.precision(.fractionLength(0...9)))
    }
}

/// Date / datetime editor over Frappe's wire strings, pinned to UTC like
/// the display formatters.
private struct WireDateEditor: View {
    let value: Binding<FrappeValue?>
    let withTime: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let date = currentDate {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { date },
                        set: { setDate($0) }),
                    displayedComponents: withTime ? [.date, .hourAndMinute] : [.date]
                )
                .labelsHidden()
                .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
                Button {
                    value.wrappedValue = .string("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear date")
            } else {
                Button("Set Date") { setDate(Date()) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var currentDate: Date? {
        ValueFormatting.wireDateValue(value.wrappedValue?.nonEmptyString)
    }

    private func setDate(_ date: Date) {
        value.wrappedValue = .string(
            withTime
                ? ValueFormatting.wireDatetimeString(date)
                : ValueFormatting.wireDateString(date))
    }
}

/// Link-field type-ahead: instant local filtering when the target has a
/// link catalog (ARCHITECTURE.md §11), Desk's `search_link` endpoint
/// otherwise; suggestions render inline below the field (popovers fight
/// text-field focus cross-platform).
struct LinkSuggestField: View {
    let doctype: String
    let text: Binding<String>

    @Environment(AppModel.self) private var model
    @State private var suggestions: [LinkOption] = []
    @State private var showSuggestions = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(doctype.isEmpty ? "Value" : doctype, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .focused($focused)
                .autocorrectionDisabled()
            if showSuggestions && focused && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions.prefix(6)) { option in
                        Button {
                            text.wrappedValue = option.value
                            showSuggestions = false
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.value)
                                if let description = option.description,
                                    description != option.value {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 320)
            }
        }
        .task(id: "\(doctype)|\(text.wrappedValue)|\(focused)") {
            guard focused, !doctype.isEmpty else {
                showSuggestions = false
                return
            }
            guard
                let options = await Self.options(
                    doctype: doctype, query: text.wrappedValue, model: model)
            else { return }
            // Typing the exact match needs no suggestion list.
            suggestions = options.filter { $0.value != text.wrappedValue }
            showSuggestions = !suggestions.isEmpty
        }
    }

    /// Type-ahead options for a link target, shared with the multiselect
    /// editor. Catalog hit: filtered locally with no debounce and no request
    /// (the catalog revalidates itself in the background); otherwise a
    /// debounced `search_link`. Nil when cancelled mid-debounce.
    static func options(doctype: String, query: String, model: AppModel) async
        -> [LinkOption]? {
        if let local = model.cache.linkSuggestions(
            doctype: doctype, query: query, using: model.dataSource) {
            return local
        }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return nil }
        return (try? await model.dataSource.searchLink(doctype: doctype, query: query)) ?? []
    }
}

/// Attach / Attach Image editor: shows the stored file reference and swaps
/// it via file picker + the gated upload (which also attaches the File to
/// the document, as Desk does).
private struct AttachFieldEditor: View {
    let field: DocField
    let session: EditSession

    @State private var showingImporter = false
    @State private var uploading = false

    var body: some View {
        HStack(spacing: 8) {
            if let current = session.value(field.fieldname)?.nonEmptyString {
                Text((current as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    session.set(field.fieldname, .string(""))
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            if uploading {
                ProgressView().controlSize(.small)
            } else {
                Button(session.uploadFile == nil ? "Choose… (locked)" : "Choose…") {
                    showingImporter = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.uploadFile == nil)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: field.fieldtype == .attachImage ? [.image] : [.item]
        ) { result in
            guard let url = try? result.get(),
                let upload = session.uploadFile
            else { return }
            uploading = true
            Task {
                defer { uploading = false }
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let fileURL = try await upload(url.lastPathComponent, data)
                    session.set(field.fieldname, .string(fileURL))
                } catch {
                    session.error = error.localizedDescription
                }
            }
        }
    }
}
