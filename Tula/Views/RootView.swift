import ERPNextKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Route? = .report(StandardReports.profitAndLoss)
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
        switch route {
        case .report(let descriptor):
            ReportScreen(descriptor: descriptor)
        case .doctypeList(let doctype):
            ListScreen(doctype: doctype)
        case .document(let doctype, let name):
            DocumentScreen(doctype: doctype, name: name)
        }
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
