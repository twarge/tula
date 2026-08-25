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

    var filterState = FinancialFilterState()
    private(set) var companies: [Company] = []
    private(set) var fiscalYears: [FiscalYear] = []
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
        companies = []
        fiscalYears = []
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
}
