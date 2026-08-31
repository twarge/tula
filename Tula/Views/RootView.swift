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
            if raw.hasPrefix("tree:") {
                return .tree(String(raw.dropFirst("tree:".count)))
            }
            if raw.hasPrefix("workspace:") {
                return .workspace(String(raw.dropFirst("workspace:".count)))
            }
            if raw.hasPrefix("query:") {
                return .queryReport(name: String(raw.dropFirst("query:".count)), extra: [:])
            }
        }
        return .report(StandardReports.profitAndLoss)
    }
    /// Typed so the currently displayed route (`path.last ?? selection`)
    /// is readable for history recording.
    @State private var path: [Route] = []
    @State private var showingSettings = false
    @State private var showingOmnibar = false

    /// What the detail column is actually showing.
    private var currentRoute: Route? {
        path.last ?? selection
    }

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
            path = []
        }
        .onChange(of: currentRoute) { _, route in
            if let route { model.recordVisit(route) }
        }
        .onAppear {
            if let route = currentRoute { model.recordVisit(route) }
        }
        .onChange(of: model.pendingRoute) { _, route in
            if let route {
                selection = route
                model.pendingRoute = nil
            }
        }
        .onChange(of: model.omnibarRequested) { _, requested in
            if requested {
                showingOmnibar = true
                model.omnibarRequested = false
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingOmnibar) {
            OmnibarView { route in
                showingOmnibar = false
                path.append(route)
            }
        }
        #if !os(macOS)
            .background(
                // Hardware-keyboard shortcuts; on macOS the Go menu owns
                // these.
                Group {
                    Button("") { showingOmnibar = true }
                        .keyboardShortcut("k", modifiers: .command)
                    Button("") { model.goBack() }
                        .keyboardShortcut("[", modifiers: .command)
                    Button("") { model.goForward() }
                        .keyboardShortcut("]", modifiers: .command)
                }
                .hidden()
            )
        #endif
        .onAppear {
            if ProcessInfo.processInfo.environment["TULA_OMNIBAR"] == "1" {
                showingOmnibar = true
            }
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
            case .workspace(let name):
                WorkspaceScreen(workspaceName: name)
            case .doctypeList(let doctype):
                ListScreen(doctype: doctype)
            case .tree(let doctype):
                TreeScreen(doctype: doctype)
            case .linkedList(let doctype, let filters):
                ListScreen(doctype: doctype, initialFilters: filters)
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
            if !model.workspaces.isEmpty {
                Section("Workspaces") {
                    ForEach(model.workspaces) { workspace in
                        Label(workspace.title, systemImage: workspaceSymbol(workspace.icon))
                            .tag(Route.workspace(workspace.name))
                    }
                }
            }
            Section("Browse") {
                ForEach(model.browseDoctypes, id: \.self) { doctype in
                    Label(doctype, systemImage: "doc.text")
                        .tag(doctype == "Account" ? Route.tree(doctype) : Route.doctypeList(doctype))
                }
            }
        }
        .navigationTitle("Tula")
        .safeAreaInset(edge: .bottom) {
            connectionFooter
        }
    }

    /// Desk workspace icon names → SF Symbols.
    private func workspaceSymbol(_ icon: String?) -> String {
        switch icon {
        case "accounting": return "dollarsign.circle"
        case "buying": return "cart"
        case "sell", "selling": return "tag"
        case "stock": return "shippingbox"
        case "hr", "users": return "person.2"
        case "organization": return "building.2"
        case "manufacturing": return "gearshape.2"
        case "project", "projects": return "list.clipboard"
        case "crm": return "person.crop.circle.badge.checkmark"
        case "support": return "lifepreserver"
        case "asset", "assets": return "building.columns"
        case "quality": return "checkmark.seal"
        case "website": return "globe"
        case "tool", "tools": return "wrench.and.screwdriver"
        case "home": return "house"
        case "integration", "integrations": return "puzzlepiece.extension"
        case "setting", "settings": return "gearshape"
        case "file": return "folder"
        case "money-coins-1", "loan": return "banknote"
        default: return "square.grid.2x2"
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
