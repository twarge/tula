import Foundation

/// Carries the ERPNext server URL between the user's devices through iCloud's
/// key-value store, so a second device doesn't need it typed again.
///
/// The setting stays in `UserDefaults`; this only mirrors a fixed list of keys
/// in both directions. Everything else stays on the device: demo mode, the API
/// key and secret (Keychain), the session cache and every per-screen
/// preference.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    static let serverURLKey = "serverURL"
    static let syncedKeys: [String] = [serverURLKey]

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var observers: [NSObjectProtocol] = []
    private var apply: (String, String) -> Void = { _, _ in }

    init(defaults: UserDefaults = .standard, store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
    }

    /// Begins syncing. Without the iCloud entitlement, or signed out of
    /// iCloud, the store simply never reports or accepts anything.
    ///
    /// A value arriving from iCloud is not written to `UserDefaults` here: it
    /// is handed to `apply` (key, value), which must take the same route as an
    /// edit in Settings, so the connection is rebuilt and writes relock.
    func start(apply: @escaping (_ key: String, _ value: String) -> Void) {
        guard observers.isEmpty else { return }
        self.apply = apply
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.pull(keys: keys ?? Self.syncedKeys) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        })
        store.synchronize()
        pull(keys: Self.syncedKeys)
        // Uploads a URL set before syncing existed; a no-op when the cloud
        // already had one, since the pull above just adopted it.
        push()
    }

    /// Cloud to device, for keys the cloud has a usable value for.
    private func pull(keys: [String]) {
        for key in keys where Self.syncedKeys.contains(key) {
            guard let value = store.string(forKey: key), Self.isSyncable(value),
                defaults.string(forKey: key) != value
            else { continue }
            apply(key, value)
        }
    }

    /// Device to cloud, for keys the user has actually set. An unset or empty
    /// value is not a choice and must not overwrite one made elsewhere.
    private func push() {
        let chosen = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in Self.syncedKeys {
            guard let value = chosen[key] as? String, Self.isSyncable(value),
                store.string(forKey: key) != value
            else { continue }
            store.set(value, forKey: key)
        }
    }

    /// Whether a server URL may leave, or be accepted onto, this device: a
    /// plain address with a host and nothing that could be a credential. The
    /// field is free text, so a URL typed as `https://user:password@host` or
    /// with a query (`?token=…`) stays local, as does an empty one.
    static func isSyncable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("@") else { return false }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { return false }
        return true
    }
}
