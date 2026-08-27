import ERPNextKit
import SwiftUI

/// The native rendering of Desk's sidebar quick filters: one chip per
/// `in_standard_filter` field (ARCHITECTURE.md §10).
///
/// Select and Check fields have finite choices → menu chips. Link fields are
/// open-ended → the chip opens a type-ahead popover backed by the server's
/// `search_link` autocomplete, like Desk's own link control.
///
/// Layout note: chips are self-contained `Menu`s/`Button`s in a horizontal
/// ScrollView — deliberately not the Picker-with-Text-sibling HStack pattern
/// that corrupts layout on the current beta SDK.
struct QuickFiltersBar: View {
    let meta: DocTypeMeta
    @Binding var values: [String: String]

    private var fields: [DocField] {
        meta.standardFilterFields.filter { supports($0.fieldtype) }
    }

    private func supports(_ fieldtype: FieldType) -> Bool {
        switch fieldtype {
        case .select, .link, .check: return true
        default: return false
        }
    }

    var body: some View {
        if !fields.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(fields) { field in
                        chip(for: field)
                    }
                    if !values.isEmpty {
                        Button {
                            values = [:]
                        } label: {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private func chip(for field: DocField) -> some View {
        switch field.fieldtype {
        case .link:
            LinkFilterChip(field: field, value: $values[field.fieldname])
        default:
            Menu {
                Button("Any \(field.label)") {
                    values[field.fieldname] = nil
                }
                Divider()
                switch field.fieldtype {
                case .select:
                    ForEach(field.selectChoices, id: \.self) { choice in
                        optionToggle(field: field, value: choice, label: choice)
                    }
                case .check:
                    optionToggle(field: field, value: "1", label: "Yes")
                    optionToggle(field: field, value: "0", label: "No")
                default:
                    EmptyView()
                }
            } label: {
                FilterChipLabel(
                    title: chipTitle(for: field), isActive: values[field.fieldname] != nil)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func optionToggle(field: DocField, value: String, label: String) -> some View {
        Toggle(isOn: Binding {
            values[field.fieldname] == value
        } set: { isOn in
            values[field.fieldname] = isOn ? value : nil
        }) {
            Text(label)
        }
    }

    private func chipTitle(for field: DocField) -> String {
        guard let value = values[field.fieldname] else { return field.label }
        if field.fieldtype == .check {
            return "\(field.label): \(value == "1" ? "Yes" : "No")"
        }
        return "\(field.label): \(value)"
    }
}

/// Shared capsule styling for all chips.
struct FilterChipLabel: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isActive
                ? AnyShapeStyle(.tint.opacity(0.18))
                : AnyShapeStyle(.quaternary.opacity(0.6)),
            in: Capsule())
        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}

/// A Link-field quick filter: tapping the chip opens a type-ahead search
/// popover; each keystroke queries `search_link` (debounced), and picking a
/// result applies the filter.
private struct LinkFilterChip: View {
    let field: DocField
    @Binding var value: String?

    @Environment(AppModel.self) private var model
    @State private var showingPopover = false
    @State private var query = ""
    @State private var results: [LinkOption] = []
    @State private var searchError: String?
    @State private var hasSearched = false
    @FocusState private var searchFocused: Bool

    private var target: String { field.options ?? field.label }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            FilterChipLabel(
                title: value.map { "\(field.label): \($0)" } ?? field.label,
                isActive: value != nil)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            // On iPhone this adapts to a half-height sheet (forcing a true
            // popover renders empty on the current beta SDK); on macOS/iPad
            // it stays an anchored popover.
            popoverContent
                #if !os(macOS)
                    .presentationDetents([.medium])
                #endif
        }
        .onAppear {
            // Headless-verification hook (paired with TULA_ROUTE): auto-open
            // this chip's popover when requested via launch environment.
            if ProcessInfo.processInfo.environment["TULA_AUTOOPEN_FILTER"] == field.fieldname {
                showingPopover = true
            }
        }
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            TextField("Search \(target)…", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($searchFocused)
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                #endif
                .padding(10)

            Divider()

            if value != nil {
                Button {
                    apply(nil)
                } label: {
                    Label("Any \(field.label)", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(12)
            } else if results.isEmpty && hasSearched {
                Text(query.isEmpty ? "Type to search" : "No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(results) { option in
                    Button {
                        apply(option.value)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.value)
                            if let description = option.description,
                                description != option.value {
                                Text(description.strippingSimpleHTML())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        #if os(macOS)
            .frame(width: 300, height: 360)
        #endif
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            do {
                results = try await model.dataSource.searchLink(
                    doctype: target, query: query)
                searchError = nil
            } catch {
                results = []
                searchError = error.localizedDescription
            }
            hasSearched = true
        }
        .onAppear { searchFocused = true }
    }

    private func apply(_ newValue: String?) {
        value = newValue
        showingPopover = false
    }
}
