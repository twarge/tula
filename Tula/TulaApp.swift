import ERPNextKit
import SwiftUI

@main
struct TulaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .commands {
            CommandMenu("Go") {
                Button("Back") {
                    model.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
                Button("Forward") {
                    model.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
                Menu("History") {
                    // Newest first; the current entry gets a checkmark.
                    ForEach(
                        Array(model.history.enumerated().reversed()).prefix(20),
                        id: \.offset
                    ) { index, route in
                        Button {
                            model.jumpToHistory(index)
                        } label: {
                            if index == model.historyIndex {
                                Label(route.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(route.displayTitle)
                            }
                        }
                    }
                }
                .disabled(model.history.isEmpty)
                Divider()
                ForEach(
                    Array(StandardReports.financialStatements.enumerated()),
                    id: \.element.id
                ) { index, descriptor in
                    Button(descriptor.title) {
                        model.pendingRoute = .report(descriptor)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
                Button("All Reports") {
                    model.pendingRoute = .reportBrowser
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Global Search…") {
                    model.omnibarRequested = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(model)
            }
        #endif
    }
}
