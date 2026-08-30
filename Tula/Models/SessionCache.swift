import CryptoKit
import ERPNextKit
import Foundation

/// A saved report result for offline viewing (ARCHITECTURE.md §11 tier 3).
struct ReportSnapshot: Codable {
    var result: ReportResult
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

    // MARK: Screens (tier 2 — memory, stale-while-revalidate)

    func screen<T>(_ key: String) -> (value: T, savedAt: Date)? {
        guard let entry = screens[key], let value = entry.value as? T else { return nil }
        return (value, entry.savedAt)
    }

    func setScreen<T>(_ key: String, _ value: T) {
        screens[key] = (value, Date())
    }

    /// Drops memoized metadata (manual-refresh hook) while keeping screens.
    func invalidateMeta() {
        metaBundles = [:]
        listColumns = [:]
    }

    func removeAll() {
        metaBundles = [:]
        listColumns = [:]
        screens = [:]
    }

    // MARK: Report snapshots (tier 3 — disk, offline viewing)

    nonisolated private static var snapshotsDirectory: URL? {
        guard
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let directory = base.appending(path: "Tula/Snapshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func snapshotURL(forKey key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return snapshotsDirectory?.appending(component: "\(digest).json")
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
