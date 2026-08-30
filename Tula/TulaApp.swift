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
                .keyboardShortcut("k", modifiers: .command)
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
