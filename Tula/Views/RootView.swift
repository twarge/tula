import ERPNextKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Route? = RootView.initialSelection

    /// Debug/automation hook: `TULA_ROUTE=list:<DocType>` or
    /// `TULA_ROUTE=doc:<DocType>:<Name>` (via `SIMCTL_CHILD_TULA_ROUTE` on
    /// the simulator) opens a screen directly.
    private static var initialSelection: Route? {
        if let raw = ProcessInfo.processInfo.environment["TULA_ROUTE"] {
            if raw.hasPrefix("list:") {
                return .doctypeList(String(raw.dropFirst("list:".count)))
            }
            if raw.hasPrefix("doc:") {
                let parts = raw.dropFirst("doc:".count)
                    .split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    return .document(doctype: parts[0], name: parts[1])
                }
            }
            if raw == "reports" {
                return .reportBrowser
            }
            if raw.hasPrefix("query:") {
                return .queryReport(name: String(raw.dropFirst("query:".count)), extra: [:])
            }
        }
        return .report(StandardReports.profitAndLoss)
    }
    @State private var path = NavigationPath()
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, showingSettings: $showingSettings)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if let selection {
                        RouteView(route: selection)
                    } else {
                        ContentUnavailableView(
                            "Select a Report", systemImage: "chart.bar.doc.horizontal")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route)
                }
            }
        }
        .onChange(of: selection) {
            path = NavigationPath()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

/// The single Route → screen mapping. Three generic screens cover every
/// destination in the app (ARCHITECTURE.md §5).
struct RouteView: View {
    let route: Route

    var body: some View {
        // .id keeps per-screen @State (search text, quick filters, tab) from
        // leaking across sidebar selections, which reuse the same view slot.
        Group {
            switch route {
            case .report(let descriptor):
                ReportScreen(descriptor: descriptor)
            case .queryReport(let name, let extra):
                if let descriptor = StandardReports.financialStatements.first(where: {
                    $0.name == name
                }) {
                    ReportScreen(descriptor: descriptor, extra: extra)
                } else {
                    GenericReportScreen(reportName: name, extra: extra)
                }
            case .reportBrowser:
                ReportBrowserScreen()
            case .doctypeList(let doctype):
                ListScreen(doctype: doctype)
            case .document(let doctype, let name):
                DocumentScreen(doctype: doctype, name: name)
            }
        }
        .id(route.stableID)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?
    @Binding var showingSettings: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Financial Statements") {
                ForEach(StandardReports.financialStatements) { descriptor in
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                        .tag(Route.report(descriptor))
                }
            }
            Section("Reports") {
                Label("All Reports", systemImage: "doc.text.magnifyingglass")
                    .tag(Route.reportBrowser)
            }
            Section("Browse") {
                ForEach(model.browseDoctypes, id: \.self) { doctype in
                    Label(doctype, systemImage: "doc.text")
                        .tag(Route.doctypeList(doctype))
                }
            }
        }
        .navigationTitle("Tula")
        .safeAreaInset(edge: .bottom) {
            connectionFooter
        }
    }

    private var connectionFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isDemo ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.dataSource.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("Read-only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Server settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
