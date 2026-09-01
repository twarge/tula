import ERPNextKit
import SwiftUI

/// Finite-choice filter chip (Select options, Yes/No checks).
struct SelectFilterChip: View {
    let label: String
    let choices: [String]
    @Binding var value: String?
    /// Optional display transform (e.g. "1" → "Yes").
    var display: (String) -> String = { $0 }
    /// Check filters are strictly one-of; no "Any" row, no cleared state.
    var allowsAny = true

    var body: some View {
        Menu {
            if allowsAny {
                Button("Any \(label)") { value = nil }
                Divider()
            }
            ForEach(choices, id: \.self) { choice in
                Toggle(isOn: Binding {
                    value == choice
                } set: { isOn in
                    if isOn {
                        value = choice
                    } else if allowsAny {
                        value = nil
                    }
                }) {
                    Text(display(choice))
                }
            }
        } label: {
            FilterChipLabel(
                title: value.map { "\(label): \(display($0))" } ?? label,
                isActive: value != nil)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Date filter chip: popover calendar, value stored in wire format.
struct DateFilterChip: View {
    let label: String
    @Binding var value: String?

    @State private var showingPopover = false
    @State private var date = Date()

    var body: some View {
        Button {
            date = ValueFormatting.wireDateValue(value) ?? Date()
            showingPopover = true
        } label: {
            FilterChipLabel(
                title: value.map { "\(label): \(displayValue($0))" } ?? label,
                isActive: value != nil)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
                HStack {
                    if value != nil {
                        Button("Clear") {
                            value = nil
                            showingPopover = false
                        }
                    }
                    Spacer()
                    Button("Apply") {
                        value = ValueFormatting.wireDateString(date)
                        showingPopover = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            #if os(macOS)
                .frame(width: 320)
            #else
                .presentationDetents([.medium])
            #endif
        }
    }

    private func displayValue(_ raw: String) -> String {
        ValueFormatting.string(for: .string(raw), fieldtype: .date)
    }
}
