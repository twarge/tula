import CryptoKit
import ERPNextKit
import Foundation

/// A saved report result for offline viewing (ARCHITECTURE.md §11 tier 3).
struct ReportSnapshot: Codable {
    var result: ReportResult
    var savedAt: Date
}

/// The complete set of a Link target's documents, held locally so type-ahead
/// filters with zero network latency. Only doctypes small enough to enumerate
/// (`SessionCache.linkCatalogLimit`) get one; bigger targets stay on live
/// `search_link`. The fingerprint is "(count)|(max modified)" — the same
/// cheap probe pair auto-refresh uses — checked once per session before the
/// catalog is trusted further.
struct LinkCatalog: Codable {
    var options: [LinkOption]
    var fingerprint: String
    var savedAt: Date
}

/// The session's caches (ARCHITECTURE.md §11): metadata memoized for the
/// session, last-loaded screens for stale-while-revalidate, and report
/// snapshots persisted to disk for offline opens. Owned by `AppModel` and
/// cleared whenever the data source changes.
@MainActor
final class SessionCache {
    private var metaBundles: [String: MetaBundle] = [:]
    private var listColumns: [String: [String]?] = [:]
    private var screens: [String: (value: Any, savedAt: Date)] = [:]

    // MARK: Metadata (tier 1 — memory, session-long)

    func metaBundle(for doctype: String, using source: any DataSource) async throws
        -> MetaBundle {
        if let cached = metaBundles[doctype] { return cached }
        let bundle = try await source.metaBundle(for: doctype)
        metaBundles[doctype] = bundle
        return bundle
    }

    func listViewColumns(for doctype: String, using source: any DataSource) async
        -> [String]? {
        if let cached = listColumns[doctype] { return cached }
        let columns = (try? await source.listViewColumns(doctype: doctype)) ?? nil
        listColumns[doctype] = columns
        return columns
    }

    // MARK: Search catalogs (session-long, for awesomebar suggestions)

    private var doctypeNamesCache: [String]?
    private var reportsCatalogCache: [ReportInfo]?
    private var workflowsCache: [String: WorkflowInfo?] = [:]
    private var printFormatsCache: [String: [String]] = [:]

    /// All non-child, non-single DocType names — Desk's navigation universe.
    /// Falls back to empty (callers merge in known doctypes) when the API
    /// user can't read the DocType doctype.
    func doctypeNames(using source: any DataSource) async -> [String] {
        if let doctypeNamesCache { return doctypeNamesCache }
        let docs =
            (try? await source.list(
                "DocType", fields: ["name"],
                filters: [
                    ListFilter("istable", "=", .int(0)),
                    ListFilter("issingle", "=", .int(0)),
                ],
                orderBy: "name asc", limitStart: 0, limitPageLength: 1000)) ?? []
        let names = docs.map(\.name)
        doctypeNamesCache = names
        return names
    }

    func printFormats(for doctype: String, using source: any DataSource) async -> [String] {
        if let cached = printFormatsCache[doctype] { return cached }
        let formats = (try? await source.printFormats(doctype: doctype)) ?? ["Standard"]
        printFormatsCache[doctype] = formats
        return formats
    }

    func workflow(for doctype: String, using source: any DataSource) async -> WorkflowInfo? {
        if let cached = workflowsCache[doctype] { return cached }
        let info = (try? await source.workflow(for: doctype)) ?? nil
        workflowsCache[doctype] = info
        return info
    }

    func reportsCatalog(using source: any DataSource) async -> [ReportInfo] {
        if let reportsCatalogCache { return reportsCatalogCache }
        let reports = (try? await source.reports()) ?? []
        reportsCatalogCache = reports
        return reports
    }

    // MARK: Link catalogs (instant autocomplete, memory + disk)

    /// Doctypes with at most this many rows get a complete local catalog.
    private static let linkCatalogLimit = 5000
    /// Suggestion lists match Desk's `page_length`.
    private static let suggestionLimit = 20

    private var linkCatalogs: [String: LinkCatalog] = [:]
    /// Doctypes found too large (or uncountable) this session — live search only.
    private var uncatalogable: Set<String> = []
    /// One background build/revalidate per doctype at a time.
    private var catalogTasks: [String: Task<Void, Never>] = [:]
    /// Doctypes whose fingerprint has been checked against the server this
    /// session; cleared by ⌘R so a manual refresh re-probes.
    private var revalidatedCatalogs: Set<String> = []
    /// Server+user identity prefixed into disk keys so a catalog from one
    /// site can never surface on another. Set by `AppModel`.
    var diskIdentity = ""

    /// Local suggestions for a Link field, or nil when this doctype has no
    /// catalog (too big, not built yet, or probe failed) and the caller
    /// should use live `searchLink`. Triggers the background build or the
    /// once-per-session revalidation as a side effect, so callers get
    /// stale-while-revalidate for free.
    func linkSuggestions(doctype: String, query: String, using source: any DataSource)
        -> [LinkOption]? {
        guard !uncatalogable.contains(doctype) else { return nil }
        guard let catalog = loadedCatalog(for: doctype) else {
            startCatalogTask(for: doctype) { await self.buildCatalog(doctype, using: source) }
            return nil
        }
        if !revalidatedCatalogs.contains(doctype) {
            startCatalogTask(for: doctype) {
                await self.revalidateCatalog(doctype, using: source)
            }
        }
        return Self.match(query, in: catalog.options)
    }

    private func loadedCatalog(for doctype: String) -> LinkCatalog? {
        if let cached = linkCatalogs[doctype] { return cached }
        guard let saved = Self.linkCatalog(forKey: diskKey(for: doctype)) else { return nil }
        linkCatalogs[doctype] = saved
        return saved
    }

    private func startCatalogTask(for doctype: String, _ work: @escaping () async -> Void) {
        guard catalogTasks[doctype] == nil else { return }
        catalogTasks[doctype] = Task {
            await work()
            // A cancelled task (source switch) was already dropped by
            // removeAll — don't clobber a successor's entry.
            if !Task.isCancelled { catalogTasks[doctype] = nil }
        }
    }

    /// Fetches the full document set (name + title field) when the doctype is
    /// small enough. Failures other than "too big" are transient: the next
    /// field focus retries, and live search covers the meantime.
    private func buildCatalog(_ doctype: String, using source: any DataSource) async {
        let filters = Self.catalogFilters(for: doctype)
        let count: Int?
        do { count = try await source.count(doctype, filters: filters) } catch {
            return  // transient (offline etc.) — the next field focus retries
        }
        guard let count, count <= Self.linkCatalogLimit else {
            uncatalogable.insert(doctype)
            return
        }
        let titleField = (try? await metaBundle(for: doctype, using: source))?
            .metas.first?.titleField
        var fields = ["name", "modified"]
        if let titleField, titleField != "name" { fields.append(titleField) }
        guard
            let docs = try? await source.list(
                doctype, fields: fields, filters: filters,
                orderBy: "modified desc", limitStart: 0,
                limitPageLength: Self.linkCatalogLimit)
        else { return }
        // A source switch cancels catalog tasks mid-flight; results fetched
        // from the old server must not land under the new identity.
        guard !Task.isCancelled else { return }
        let options = docs.map { doc in
            LinkOption(
                value: doc.name,
                description: titleField.flatMap { doc[$0]?.nonEmptyString })
        }
        let catalog = LinkCatalog(
            options: options,
            fingerprint: Self.fingerprint(count: count, maxModified: docs.first),
            savedAt: Date())
        linkCatalogs[doctype] = catalog
        revalidatedCatalogs.insert(doctype)
        Self.saveLinkCatalog(catalog, forKey: diskKey(for: doctype))
    }

    /// Two one-row probes; a moved fingerprint rebuilds the whole catalog.
    private func revalidateCatalog(_ doctype: String, using source: any DataSource) async {
        revalidatedCatalogs.insert(doctype)
        let filters = Self.catalogFilters(for: doctype)
        guard let count = try? await source.count(doctype, filters: filters),
            let newest = try? await source.list(
                doctype, fields: ["modified"], filters: filters,
                orderBy: "modified desc", limitStart: 0, limitPageLength: 1)
        else {
            revalidatedCatalogs.remove(doctype)
            return
        }
        let fingerprint = Self.fingerprint(count: count, maxModified: newest.first)
        if fingerprint != linkCatalogs[doctype]?.fingerprint {
            await buildCatalog(doctype, using: source)
        }
    }

    private static func fingerprint(count: Int, maxModified: Document?) -> String {
        "\(count)|\(maxModified?.raw["modified"]?.nonEmptyString ?? "")"
    }

    /// Desk's `search_link` for User applies the standard user query
    /// (enabled system users only); mirror that so catalogs don't surface
    /// Guest, bots, or disabled accounts in assignment/share pickers.
    private static func catalogFilters(for doctype: String) -> [ListFilter] {
        doctype == "User"
            ? [
                ListFilter("enabled", "=", .int(1)),
                ListFilter("user_type", "=", .string("System User")),
            ]
            : []
    }

    /// Desk-flavored local ranking: prefix matches on ID or title first,
    /// then substring matches, recency order preserved within each group.
    static func match(_ query: String, in options: [LinkOption]) -> [LinkOption] {
        guard !query.isEmpty else { return Array(options.prefix(suggestionLimit)) }
        let needle = query.lowercased()
        var prefixed: [LinkOption] = []
        var contained: [LinkOption] = []
        for option in options {
            let value = option.value.lowercased()
            let description = option.description?.lowercased() ?? ""
            if value.hasPrefix(needle) || description.hasPrefix(needle) {
                prefixed.append(option)
                if prefixed.count >= suggestionLimit { break }
            } else if contained.count < suggestionLimit,
                value.contains(needle) || description.contains(needle) {
                contained.append(option)
            }
        }
        return Array((prefixed + contained).prefix(suggestionLimit))
    }

    // MARK: Screens (tier 2 — memory, stale-while-revalidate)

    func screen<T>(_ key: String) -> (value: T, savedAt: Date)? {
        guard let entry = screens[key], let value = entry.value as? T else { return nil }
        return (value, entry.savedAt)
    }

    func setScreen<T>(_ key: String, _ value: T) {
        screens[key] = (value, Date())
    }

    /// Drops memoized metadata (manual-refresh hook) while keeping screens.
    /// Link catalogs stay too (stale-while-revalidate), but their
    /// once-per-session revalidation marks reset so the next field focus
    /// re-probes the server.
    func invalidateMeta() {
        metaBundles = [:]
        listColumns = [:]
        doctypeNamesCache = nil
        reportsCatalogCache = nil
        workflowsCache = [:]
        printFormatsCache = [:]
        uncatalogable = []
        revalidatedCatalogs = []
    }

    func removeAll() {
        metaBundles = [:]
        listColumns = [:]
        doctypeNamesCache = nil
        reportsCatalogCache = nil
        workflowsCache = [:]
        printFormatsCache = [:]
        screens = [:]
        linkCatalogs = [:]
        uncatalogable = []
        revalidatedCatalogs = []
        for task in catalogTasks.values { task.cancel() }
        catalogTasks = [:]
    }

    // MARK: Report snapshots (tier 3 — disk, offline viewing)

    nonisolated private static func cacheDirectory(_ name: String) -> URL? {
        guard
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let directory = base.appending(path: "Tula/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func fileURL(directory: String, key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDirectory(directory)?.appending(component: "\(digest).json")
    }

    nonisolated private static func snapshotURL(forKey key: String) -> URL? {
        fileURL(directory: "Snapshots", key: key)
    }

    private func diskKey(for doctype: String) -> String {
        "\(diskIdentity)|\(doctype)"
    }

    nonisolated private static func linkCatalog(forKey key: String) -> LinkCatalog? {
        guard let url = fileURL(directory: "LinkCatalogs", key: key),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(LinkCatalog.self, from: data)
    }

    nonisolated private static func saveLinkCatalog(_ catalog: LinkCatalog, forKey key: String) {
        guard let url = fileURL(directory: "LinkCatalogs", key: key),
            let data = try? JSONEncoder().encode(catalog)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func reportSnapshot(forKey key: String) -> ReportSnapshot? {
        guard let url = snapshotURL(forKey: key),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ReportSnapshot.self, from: data)
    }

    nonisolated static func saveReportSnapshot(_ result: ReportResult, forKey key: String) {
        guard let url = snapshotURL(forKey: key),
            let data = try? JSONEncoder().encode(ReportSnapshot(result: result, savedAt: Date()))
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
