import ERPNextKit
import SwiftUI

/// Keeps a screen fresh without push infrastructure: while the screen is
/// visible, poll `DataSource.latestModified` for a signal DocType on an
/// interval (plus once whenever the app returns to the foreground) and invoke
/// `onDataChanged` when the timestamp moves. The probe is one tiny GET, so
/// this stays entirely inside the read-only client (ARCHITECTURE.md §6).
///
/// The `.task` lifetime scopes polling to the visible screen — pushing a new
/// screen or leaving the tab cancels the loop automatically.
private struct AutoRefreshModifier: ViewModifier {
    let signalDoctype: String?
    let onDataChanged: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastSignal: String?

    private static let interval: Duration = .seconds(45)

    func body(content: Content) -> some View {
        content
            .task(id: "\(model.sourceGeneration)-\(signalDoctype ?? "none")") {
                lastSignal = nil
                guard signalDoctype != nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.interval)
                    guard !Task.isCancelled else { return }
                    await check()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await check() }
                }
            }
    }

    private func check() async {
        guard let signalDoctype else { return }
        // Probe failures (offline, permissions) are silent: auto-refresh is
        // best-effort, and the screen's own loads surface real errors.
        guard let signal = try? await model.dataSource.latestModified(signalDoctype) else {
            return
        }
        if let lastSignal, lastSignal != signal {
            onDataChanged()
        }
        lastSignal = signal
    }
}

extension View {
    func autoRefresh(signalDoctype: String?, onDataChanged: @escaping () -> Void) -> some View {
        modifier(
            AutoRefreshModifier(signalDoctype: signalDoctype, onDataChanged: onDataChanged))
    }
}

extension ToolbarItemPlacement {
    /// A busy screen's less-used actions (past its first three): the overflow
    /// menu on iOS, where a phone's bar — or the Duo's vertical bar — fits
    /// only a few items. macOS keeps them in the toolbar as before.
    static var demotedAction: ToolbarItemPlacement {
        #if os(macOS)
            .primaryAction
        #else
            .secondaryAction
        #endif
    }
}

/// Shared toolbar affordance: a refresh button (⌘R), with an "Updated 12:41"
/// stamp beside it on macOS. iOS nav bars drop toolbar text, so there the
/// button stands alone and auto-refresh keeps content current.
struct RefreshToolbar: ToolbarContent {
    let lastUpdated: Date?
    /// Optional extra status shown beside the stamp on macOS ("50 of 1,234").
    var detail: String? = nil
    var placement: ToolbarItemPlacement = .primaryAction
    let action: () -> Void

    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: placement) {
            #if os(macOS)
                HStack(spacing: 10) {
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    UpdatedStamp(lastUpdated: lastUpdated)
                    refreshButton
                }
            #else
                refreshButton
            #endif
        }
    }

    private var refreshButton: some View {
        Button {
            // Manual refresh also busts the session meta cache, so schema
            // changes on the server are picked up without a relaunch.
            model.cache.invalidateMeta()
            action()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh (⌘R)")
    }
}

struct UpdatedStamp: View {
    let lastUpdated: Date?

    var body: some View {
        if let lastUpdated {
            Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}


/// The write-gate lock: read-only by default, tap to unlock writes for this
/// session (ARCHITECTURE.md §6). Hidden in demo mode and when no live server
/// is configured.
struct WriteGateToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        if model.canUnlockWrites {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.setWritesUnlocked(!model.writesUnlocked) }
                } label: {
                    Label(
                        model.writesUnlocked ? "Lock (read-only)" : "Unlock writes",
                        systemImage: model.writesUnlocked ? "lock.open.fill" : "lock.fill")
                }
                .tint(model.writesUnlocked ? .orange : nil)
                .help(
                    model.writesUnlocked
                        ? "Writes enabled for this session — click to return to read-only"
                        : "Read-only — click to enable collaboration and document lifecycle actions")
            }
        }
    }
}
