import ERPNextKit
import Foundation
import Observation

enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    var useDemo: Bool
    var serverURLString: String
    var apiKey: String
    var apiSecret: String

    private(set) var dataSource: any DataSource
    /// Bumped whenever the data source changes so `.task(id:)` reloads screens.
    private(set) var sourceGeneration = 0
    /// Session caches (metadata, screens, snapshots) — ARCHITECTURE.md §11.
    let cache = SessionCache()

    /// Set by menu commands (⌘1–5, ⌘K); consumed by RootView.
    var pendingRoute: Route?
    var omnibarRequested = false

    // Navigation history (browser-style): every displayed route in order,
    // with a cursor for back/forward. History jumps navigate through
    // pendingRoute with recording suppressed for that one transition.
    private(set) var history: [Route] = []
    private(set) var historyIndex = -1
    private var suppressNextHistoryRecord = false

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    func recordVisit(_ route: Route) {
        if suppressNextHistoryRecord {
            suppressNextHistoryRecord = false
            return
        }
        if history.indices.contains(historyIndex), history[historyIndex] == route {
            return
        }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(route)
        if history.count > 50 {
            history.removeFirst(history.count - 50)
        }
        historyIndex = history.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigateToCurrentHistoryEntry()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigateToCurrentHistoryEntry()
    }

    func jumpToHistory(_ index: Int) {
        guard history.indices.contains(index), index != historyIndex else { return }
        historyIndex = index
        navigateToCurrentHistoryEntry()
    }

    private func navigateToCurrentHistoryEntry() {
        suppressNextHistoryRecord = true
        pendingRoute = history[historyIndex]
    }

    /// The write gate (ARCHITECTURE.md §6): OFF by default, session-only,
    /// toggled by the toolbar lock. While locked, no write path exists.
    private(set) var writesUnlocked = false
    private(set) var writeSession: WriteSession?
    private(set) var writeGateError: String?

    var canUnlockWrites: Bool {
        !useDemo && liveConfiguration() != nil
    }

    func setWritesUnlocked(_ unlocked: Bool) async {
        writeGateError = nil
        guard unlocked else {
            writesUnlocked = false
            writeSession = nil
            return
        }
        guard let configuration = liveConfiguration() else { return }
        guard let user = (try? await dataSource.loggedUser()) ?? nil else {
            writeGateError = "Couldn't identify the signed-in user; writes stay locked."
            return
        }
        writeSession = WriteSession(
            client: WriteClient(configuration: configuration), user: user)
        writesUnlocked = true
    }

    var filterState = FinancialFilterState()
    private(set) var companies: [Company] = []
    private(set) var fiscalYears: [FiscalYear] = []
    private(set) var workspaces: [WorkspaceInfo] = []
    private(set) var filterOptionsError: String?
    private var filterOptionsLoadedForGeneration = -1

    init() {
        let defaults = UserDefaults.standard
        // Demo mode is the default until a server is configured, so first
        // launch shows a working P&L instead of an empty screen.
        useDemo = defaults.object(forKey: "useDemo") as? Bool ?? true
        serverURLString = defaults.string(forKey: "serverURL") ?? ""
        apiKey = Keychain.string(for: "apiKey") ?? ""
        apiSecret = Keychain.string(for: "apiSecret") ?? ""
        dataSource = DemoDataSource()
        dataSource = makeDataSource()
        cache.diskIdentity = diskIdentity
    }

    /// Keys on-disk caches (link catalogs) to the server+user they came
    /// from, so switching sites can never surface another site's names.
    private var diskIdentity: String {
        guard !useDemo, let configuration = liveConfiguration() else { return "demo" }
        return "\(configuration.baseURL.absoluteString)|\(configuration.apiKey)"
    }

    var isDemo: Bool { dataSource is DemoDataSource }

    /// DocTypes offered in the sidebar's Browse section. With a live server
    /// this is a starting set — any DocType renders through the same generic
    /// screens (Phase 3 replaces this with server-defined Workspaces).
    var browseDoctypes: [String] {
        isDemo
            ? ["Account", "Sales Invoice"]
            : [
                "Account", "Journal Entry", "Payment Entry", "Sales Invoice",
                "Purchase Invoice", "Customer", "Supplier", "Item",
            ]
    }

    func applySettings() {
        let defaults = UserDefaults.standard
        defaults.set(useDemo, forKey: "useDemo")
        defaults.set(serverURLString, forKey: "serverURL")
        Keychain.set(apiKey, for: "apiKey")
        Keychain.set(apiSecret, for: "apiSecret")

        dataSource = makeDataSource()
        sourceGeneration += 1
        writesUnlocked = false
        writeSession = nil
        writeGateError = nil
        cache.removeAll()
        cache.diskIdentity = diskIdentity
        companies = []
        fiscalYears = []
        workspaces = []
        filterState = FinancialFilterState()
        filterOptionsError = nil
        filterOptionsLoadedForGeneration = -1
    }

    private func makeDataSource() -> any DataSource {
        if !useDemo, let configuration = liveConfiguration() {
            return LiveDataSource(client: ReadOnlyClient(configuration: configuration))
        }
        return DemoDataSource()
    }

    func liveConfiguration() -> ServerConfiguration? {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return ServerConfiguration(baseURL: url, apiKey: apiKey, apiSecret: apiSecret)
    }

    /// Loads companies and fiscal years once per data source and picks
    /// defaults (first company, most recent fiscal year).
    func ensureFilterOptions() async {
        guard filterOptionsLoadedForGeneration != sourceGeneration else { return }
        do {
            let companies = try await dataSource.companies()
            let fiscalYears = try await dataSource.fiscalYears()
            self.companies = companies
            self.fiscalYears = fiscalYears
            self.workspaces = (try? await dataSource.workspaces()) ?? []
            filterOptionsError = nil
            if filterState.company == nil { filterState.company = companies.first }
            if filterState.fiscalYear == nil { filterState.fiscalYear = fiscalYears.first }
            filterOptionsLoadedForGeneration = sourceGeneration
        } catch {
            filterOptionsError = error.localizedDescription
        }
    }

    var fallbackCurrencyCode: String? {
        filterState.company?.defaultCurrency
    }

    /// Base URL of the connected site's web UI; nil in demo mode (nothing to
    /// open in a browser).
    var webBaseURL: URL? {
        (dataSource as? LiveDataSource)?.client.configuration.baseURL
    }
}
