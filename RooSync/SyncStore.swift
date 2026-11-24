import Foundation
import Combine
import Network
import Security
import UIKit
import RooSyncCore

struct NetworkPreferences: Equatable {
    var discoveryEnabled = true
    var relaysEnabled = true
    var lanOnly = false
    var maxSendKbps = 0
    var maxReceiveKbps = 0
    var pauseOnCellular = false
    var pauseOnBattery = false
    var keepAliveWhileCharging = false
}

@MainActor
final class SyncStore: ObservableObject {
    static let shared = SyncStore()

    private static let lanOnlyNetworks = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8",
        "fc00::/7", "fe80::/10", "::1/128"
    ]

    @Published private(set) var deviceID = ""
    @Published private(set) var folders: [SyncthingFolder] = []
    @Published private(set) var devices: [SyncthingDevice] = []
    @Published private(set) var statuses: [String: FolderStatus] = [:]
    @Published private(set) var pendingDevices: [PendingDevice] = []
    @Published private(set) var pendingFolders: [PendingFolder] = []
    @Published private(set) var foldersNeedingReauthorization = Set<String>()
    @Published private(set) var errorMessage: String?
    @Published private(set) var isCellular = false
    @Published private(set) var isOnBattery = false
    @Published var preferences = NetworkPreferences()
    @Published var sceneIsActive = false

    private let api: SyncthingAPI
    private let apiKey: String
    private let coreStartupTask: Task<Void, Error>
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.rooindustries.roosync.network")
    private var refreshTask: Task<Void, Never>?
    private var activeScopes: [String: URL] = [:]
    private var policyPausedFolders = Set<String>()
    private var bookmarksRestored = false
    private var foldersLoaded = false

    private init() {
        apiKey = APIKeyStore.loadOrCreate()
        api = SyncthingAPI(apiKey: apiKey)
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RooSync", isDirectory: true)
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let defaultFolder = documents.appendingPathComponent("RooSync", isDirectory: true)
        let configDirectory = support.appendingPathComponent("config", isDirectory: true)
        let dataDirectory = support.appendingPathComponent("data", isDirectory: true)
        let startupAPIKey = apiKey
        coreStartupTask = Task.detached(priority: .userInitiated) {
            try GoCoreBridge.start(
                configDirectory: configDirectory,
                dataDirectory: dataDirectory,
                defaultFolder: defaultFolder,
                apiKey: startupAPIKey
            )
        }

        preferences.pauseOnCellular = UserDefaults.standard.bool(forKey: "pauseOnCellular")
        preferences.pauseOnBattery = UserDefaults.standard.bool(forKey: "pauseOnBattery")
        preferences.keepAliveWhileCharging = UserDefaults.standard.bool(forKey: "keepAliveWhileCharging")
        policyPausedFolders = Set(UserDefaults.standard.stringArray(forKey: "policyPausedFolders") ?? [])
        UIDevice.current.isBatteryMonitoringEnabled = true
        isOnBattery = UIDevice.current.batteryState == .unplugged

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isCellular = path.usesInterfaceType(.cellular)
                await self?.applyPowerPolicy()
            }
        }
        pathMonitor.start(queue: pathQueue)
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnBattery = UIDevice.current.batteryState == .unplugged
                await self.applyPowerPolicy()
                self.updateKeepAwake()
            }
        }
        updateKeepAwake()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh() async {
        do {
            try await coreStartupTask.value
            deviceID = try await api.status()
            folders = try await api.folders()
            await restoreBookmarksIfNeeded()
            try await reconcileAppDocumentsFolderPaths()
            folders = try await api.folders()
            foldersLoaded = true
            devices = try await api.devices()
            pendingDevices = try await api.pendingDevices()
            pendingFolders = try await api.pendingFolders()
            for folder in folders {
                if let status = try? await api.folderStatus(folder.id) {
                    statuses[folder.id] = status
                } else {
                    statuses.removeValue(forKey: folder.id)
                }
            }
            await loadNetworkPreferences()
            try await applyLANRestriction(preferences.lanOnly)
            errorMessage = foldersNeedingReauthorization.isEmpty
                ? nil
                : "RooSync needs folder access again. Open each affected folder and choose its location."
            await applyPowerPolicy()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncNow(window: Duration = .seconds(20)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: window)
        do {
            try await coreStartupTask.value
            try await waitForCore(until: min(deadline, clock.now.advanced(by: .seconds(5))))
            folders = try await api.folders()
            await restoreBookmarksIfNeeded()
            try await reconcileAppDocumentsFolderPaths()
            folders = try await api.folders()
            foldersLoaded = true
            await loadNetworkPreferences()
            try await applyLANRestriction(preferences.lanOnly)
            await applyPowerPolicy()
            folders = try await api.folders()
            for folder in folders where !folder.paused {
                try await api.scan(folder.id)
            }

            let activeFolders = folders.filter { !$0.paused }
            guard !activeFolders.isEmpty else { return folders.isEmpty }
            let minimumWindowEnd = clock.now.advanced(by: .seconds(2))
            while true {
                try Task.checkCancellation()
                var complete = true
                for folder in activeFolders {
                    let status = try await api.folderStatus(folder.id)
                    statuses[folder.id] = status
                    if status.pullErrors > 0 {
                        throw APIError.folderHasErrors(folder.id)
                    }
                    if status.needBytes > 0 || status.state != "idle" {
                        complete = false
                    }
                }
                if complete && clock.now >= minimumWindowEnd {
                    errorMessage = nil
                    return true
                }
                guard clock.now < deadline else {
                    return false
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func waitForCore(until deadline: ContinuousClock.Instant) async throws {
        let clock = ContinuousClock()
        var lastError: Error?
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                deviceID = try await api.status()
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        if let lastError {
            throw lastError
        }
        throw APIError.invalidResponse
    }

    func addDevice(id: String, name: String, address: String? = nil) async throws {
        let normalizedID = normalizeDeviceID(id)
        let allowedNetworks = preferences.lanOnly ? Self.lanOnlyNetworks : nil
        try await api.addDevice(id: normalizedID, name: name, address: address, allowedNetworks: allowedNetworks)
        if preferences.lanOnly {
            rememberOriginalAllowedNetworks([], deviceID: normalizedID)
        }
        await refresh()
    }

    func addFolder(id: String, name: String) async throws {
        try await addDocumentsFolder(id: id, name: name, sharedWith: [])
    }

    func addFolder(id: String, name: String, externalURL: URL) async throws {
        let folderID = try normalizedFolderID(id)
        let label = try normalizedFolderName(name)
        guard externalURL.startAccessingSecurityScopedResource() else {
            throw SyncStoreError.folderAccessDenied
        }
        let previousScope = activeScopes[folderID]
        let previousBookmarks = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        var bookmarks = previousBookmarks
        do {
            let bookmark = try externalURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            bookmarks[folderID] = bookmark
            UserDefaults.standard.set(bookmarks, forKey: "folderBookmarks")
            try await api.addFolder(id: folderID, name: label, path: externalURL.path)
            activeScopes[folderID] = externalURL
            previousScope?.stopAccessingSecurityScopedResource()
            foldersNeedingReauthorization.remove(folderID)
            await refresh()
        } catch {
            externalURL.stopAccessingSecurityScopedResource()
            UserDefaults.standard.set(previousBookmarks, forKey: "folderBookmarks")
            activeScopes[folderID] = previousScope
            throw error
        }
    }

    func relinkFolder(_ folder: SyncthingFolder, to url: URL) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw SyncStoreError.folderAccessDenied
        }
        let bookmarks = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        var updatedBookmarks = bookmarks
        let previousScope = activeScopes[folder.id]
        do {
            updatedBookmarks[folder.id] = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try await api.updateFolderPath(folder.id, path: url.path)
            UserDefaults.standard.set(updatedBookmarks, forKey: "folderBookmarks")
            activeScopes[folder.id] = url
            previousScope?.stopAccessingSecurityScopedResource()
            foldersNeedingReauthorization.remove(folder.id)
            await refresh()
        } catch {
            url.stopAccessingSecurityScopedResource()
            UserDefaults.standard.set(bookmarks, forKey: "folderBookmarks")
            activeScopes[folder.id] = previousScope
            throw error
        }
    }

    func togglePause(_ folder: SyncthingFolder) async {
        if isPolicyRestricted && folder.paused {
            return
        }
        do {
            try await api.setPaused(!folder.paused, folderID: folder.id)
            policyPausedFolders.remove(folder.id)
            savePolicyPausedFolders()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rescan(_ folder: SyncthingFolder) async {
        do {
            try await api.scan(folder.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSharing(_ folder: SyncthingFolder, deviceID: String, shared: Bool) async {
        var deviceIDs = folder.devices.map(\.deviceID)
        if shared {
            deviceIDs.append(deviceID)
        } else {
            deviceIDs.removeAll { $0 == deviceID }
        }
        do {
            try await api.setFolderSharing(folder.id, deviceIDs: Array(Set(deviceIDs)))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func accept(_ device: PendingDevice) async {
        await run {
            try await self.addDevice(id: device.id, name: device.name)
        }
    }

    func accept(_ folder: PendingFolder) async {
        await run {
            try await self.addFolder(id: folder.id, name: folder.name, sharedWith: [folder.deviceID])
        }
    }

    func ignorePatterns(for folderID: String) async throws -> String {
        try await api.ignores(folderID)
    }

    func saveIgnorePatterns(_ patterns: String, folderID: String) async throws {
        try await api.setIgnores(patterns, folderID: folderID)
    }

    func conflicts(in folder: SyncthingFolder) -> [ConflictFile] {
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: folder.path), includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.contains(".sync-conflict-") }
            .map(ConflictFile.init(url:))
            .sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    func resolve(_ conflict: ConflictFile, keep: Bool, folderID: String) async throws {
        let fileManager = FileManager.default
        if keep {
            let name = conflict.url.lastPathComponent
            guard let range = name.range(of: ".sync-conflict-") else { return }
            let originalName = String(name[..<range.lowerBound])
            let ext = conflict.url.pathExtension
            let parent = conflict.url.deletingLastPathComponent()
            var candidate = parent.appendingPathComponent("\(originalName) (conflict copy)").appendingPathExtension(ext)
            var suffix = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = parent.appendingPathComponent("\(originalName) (conflict copy \(suffix))").appendingPathExtension(ext)
                suffix += 1
            }
            try fileManager.moveItem(at: conflict.url, to: candidate)
        } else {
            try fileManager.removeItem(at: conflict.url)
        }
        try await api.scan(folderID)
    }

    func logs() async throws -> String {
        try await api.logs()
    }

    func savePreferences(_ value: NetworkPreferences) async {
        do {
            var options = try await api.options()
            options["localAnnounceEnabled"] = value.discoveryEnabled
            options["globalAnnounceEnabled"] = value.discoveryEnabled && !value.lanOnly
            options["relaysEnabled"] = value.relaysEnabled && !value.lanOnly
            options["natEnabled"] = !value.lanOnly
            options["maxSendKbps"] = value.maxSendKbps
            options["maxRecvKbps"] = value.maxReceiveKbps
            try await api.saveOptions(options)
            try await applyLANRestriction(value.lanOnly)
            preferences = value
            UserDefaults.standard.set(value.discoveryEnabled, forKey: "discoveryEnabled")
            UserDefaults.standard.set(value.relaysEnabled, forKey: "relaysEnabled")
            UserDefaults.standard.set(value.lanOnly, forKey: "lanOnly")
            UserDefaults.standard.set(value.maxSendKbps, forKey: "maxSendKbps")
            UserDefaults.standard.set(value.maxReceiveKbps, forKey: "maxReceiveKbps")
            UserDefaults.standard.set(true, forKey: "networkPreferencesSaved")
            UserDefaults.standard.set(value.pauseOnCellular, forKey: "pauseOnCellular")
            UserDefaults.standard.set(value.pauseOnBattery, forKey: "pauseOnBattery")
            UserDefaults.standard.set(value.keepAliveWhileCharging, forKey: "keepAliveWhileCharging")
            await applyPowerPolicy()
            updateKeepAwake()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSceneActivity(_ active: Bool) {
        sceneIsActive = active
        updateKeepAwake()
    }

    var isPolicyRestricted: Bool {
        (preferences.pauseOnCellular && isCellular) || (preferences.pauseOnBattery && isOnBattery)
    }

    func clearError() {
        errorMessage = nil
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func applyPowerPolicy() async {
        guard foldersLoaded else { return }
        var changed = false
        if isPolicyRestricted {
            for folder in folders where !folder.paused {
                do {
                    try await api.setPaused(true, folderID: folder.id)
                    policyPausedFolders.insert(folder.id)
                    changed = true
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            for folder in folders where policyPausedFolders.contains(folder.id) {
                do {
                    try await api.setPaused(false, folderID: folder.id)
                    policyPausedFolders.remove(folder.id)
                    changed = true
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        let currentFolderIDs = Set(folders.map(\.id))
        policyPausedFolders.formIntersection(currentFolderIDs)
        savePolicyPausedFolders()
        if changed, let updatedFolders = try? await api.folders() {
            folders = updatedFolders
        }
    }

    private func updateKeepAwake() {
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        UIApplication.shared.isIdleTimerDisabled = sceneIsActive && preferences.keepAliveWhileCharging && charging
    }

    private func loadNetworkPreferences() async {
        guard let values = try? await api.options() else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "networkPreferencesSaved") {
            preferences.discoveryEnabled = defaults.object(forKey: "discoveryEnabled") as? Bool ?? true
            preferences.relaysEnabled = defaults.object(forKey: "relaysEnabled") as? Bool ?? true
            preferences.lanOnly = defaults.object(forKey: "lanOnly") as? Bool ?? false
            preferences.maxSendKbps = defaults.object(forKey: "maxSendKbps") as? Int ?? 0
            preferences.maxReceiveKbps = defaults.object(forKey: "maxReceiveKbps") as? Int ?? 0
        } else {
            preferences.discoveryEnabled = values["localAnnounceEnabled"] as? Bool ?? true
            preferences.relaysEnabled = values["relaysEnabled"] as? Bool ?? true
            preferences.lanOnly = false
            preferences.maxSendKbps = values["maxSendKbps"] as? Int ?? 0
            preferences.maxReceiveKbps = values["maxRecvKbps"] as? Int ?? 0
        }
    }

    private func applyLANRestriction(_ enabled: Bool) async throws {
        let configurations = try await api.deviceConfigurations()
        var originalNetworks = UserDefaults.standard.dictionary(forKey: "originalAllowedNetworks") as? [String: [String]] ?? [:]
        let deviceIDs = Set(configurations.compactMap { $0["deviceID"] as? String })
        for configuration in configurations {
            guard let deviceID = configuration["deviceID"] as? String else { continue }
            let configuredNetworks = configuration["allowedNetworks"] as? [String] ?? []
            if enabled {
                if originalNetworks[deviceID] == nil {
                    originalNetworks[deviceID] = configuredNetworks
                    UserDefaults.standard.set(originalNetworks, forKey: "originalAllowedNetworks")
                }
                if configuredNetworks != Self.lanOnlyNetworks {
                    try await api.setAllowedNetworks(Self.lanOnlyNetworks, deviceID: deviceID)
                }
            } else if let previousNetworks = originalNetworks.removeValue(forKey: deviceID),
                      configuredNetworks != previousNetworks {
                try await api.setAllowedNetworks(previousNetworks, deviceID: deviceID)
            }
        }
        originalNetworks = originalNetworks.filter { deviceIDs.contains($0.key) }
        UserDefaults.standard.set(originalNetworks, forKey: "originalAllowedNetworks")
    }

    private func rememberOriginalAllowedNetworks(_ networks: [String], deviceID: String) {
        var originalNetworks = UserDefaults.standard.dictionary(forKey: "originalAllowedNetworks") as? [String: [String]] ?? [:]
        if originalNetworks[deviceID] == nil {
            originalNetworks[deviceID] = networks
            UserDefaults.standard.set(originalNetworks, forKey: "originalAllowedNetworks")
        }
    }

    private func savePolicyPausedFolders() {
        UserDefaults.standard.set(policyPausedFolders.sorted(), forKey: "policyPausedFolders")
    }

    private func restoreBookmarksIfNeeded() async {
        guard !bookmarksRestored else { return }
        bookmarksRestored = true
        let storedBookmarks = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        var bookmarks = storedBookmarks
        let folderIDs = Set(folders.map(\.id))
        for (folderID, bookmark) in storedBookmarks where folderIDs.contains(folderID) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else {
                foldersNeedingReauthorization.insert(folderID)
                continue
            }
            activeScopes[folderID] = url
            if stale, let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[folderID] = refreshed
            }
            if let folder = folders.first(where: { $0.id == folderID }), folder.path != url.path {
                do {
                    try await api.updateFolderPath(folderID, path: url.path)
                } catch {
                    foldersNeedingReauthorization.insert(folderID)
                }
            }
        }
        bookmarks = bookmarks.filter { folderIDs.contains($0.key) }
        UserDefaults.standard.set(bookmarks, forKey: "folderBookmarks")
    }

    private func reconcileAppDocumentsFolderPaths() async throws {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
        let bookmarks = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        let bookmarkedFolderIDs = Set(bookmarks.keys)
        for folder in folders where !bookmarkedFolderIDs.contains(folder.id) {
            guard let path = rebasedAppDocumentsPath(folder.path, to: documentsDirectory), path != folder.path else {
                continue
            }
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                withIntermediateDirectories: true
            )
            try await api.updateFolderPath(folder.id, path: path)
        }
    }

    private func rebasedAppDocumentsPath(_ path: String, to documentsDirectory: URL) -> String? {
        guard let containerRange = path.range(of: "/Containers/Data/Application/"),
              let documentsRange = path.range(of: "/Documents/", range: containerRange.upperBound..<path.endIndex) else {
            return nil
        }
        let containerID = String(path[containerRange.upperBound..<documentsRange.lowerBound])
        guard UUID(uuidString: containerID) != nil else { return nil }
        let relativePath = String(path[documentsRange.upperBound...])
        let components = relativePath.split(separator: "/")
        guard relativePath == "RooSync" || relativePath.hasPrefix("RooSync/") || relativePath.hasPrefix("Vaults/"),
              !components.contains("..") else {
            return nil
        }
        let documentsPath = documentsDirectory.standardizedFileURL.path
        let rebasedPath = URL(
            fileURLWithPath: (documentsPath as NSString).appendingPathComponent(relativePath),
            isDirectory: true
        ).standardizedFileURL.path
        guard rebasedPath.hasPrefix(documentsPath + "/") else { return nil }
        return rebasedPath
    }

    private func addFolder(id: String, name: String, sharedWith: [String]) async throws {
        try await addDocumentsFolder(id: id, name: name, sharedWith: sharedWith)
    }

    private func addDocumentsFolder(id: String, name: String, sharedWith: [String]) async throws {
        let folderID = try normalizedFolderID(id)
        let label = try normalizedFolderName(name)
        let existingFolders = try await api.folders()
        guard !existingFolders.contains(where: { $0.id == folderID }) else {
            throw SyncStoreError.folderAlreadyExists
        }
        let fileManager = FileManager.default
        let vaults = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaults", isDirectory: true).standardizedFileURL
        try fileManager.createDirectory(at: vaults, withIntermediateDirectories: true)
        let idSuffix = folderID.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .joined()
        var component = label
        var path = vaults.appendingPathComponent(component, isDirectory: true)
        if fileManager.fileExists(atPath: path.path) {
            component += " (\(idSuffix.prefix(8).isEmpty ? "folder" : String(idSuffix.prefix(8))))"
            path = vaults.appendingPathComponent(component, isDirectory: true)
            var collision = 2
            while fileManager.fileExists(atPath: path.path) {
                path = vaults.appendingPathComponent("\(component) \(collision)", isDirectory: true)
                collision += 1
            }
        }
        let resolvedVaults = vaults.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = path.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(resolvedVaults + "/") else {
            throw SyncStoreError.invalidFolderName
        }
        try fileManager.createDirectory(at: path, withIntermediateDirectories: false)
        do {
            try await api.addFolder(id: folderID, name: label, path: path.path, sharedWith: sharedWith)
            await refresh()
        } catch {
            try? fileManager.removeItem(at: path)
            throw error
        }
    }

    private func normalizedFolderID(_ value: String) throws -> String {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"),
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SyncStoreError.invalidFolderID
        }
        return id
    }

    private func normalizedFolderName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SyncStoreError.invalidFolderName
        }
        return name
    }

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizeDeviceID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let id = components.queryItems?.first(where: { $0.name == "id" })?.value {
            return id
        }
        return trimmed
    }
}

struct ConflictFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private enum GoCoreBridge {
    static func start(configDirectory: URL, dataDirectory: URL, defaultFolder: URL, apiKey: String) throws {
        var error: NSError?
        let started = RoosyncmobileStartCore(
            configDirectory.path,
            dataDirectory.path,
            defaultFolder.path,
            "127.0.0.1:8384",
            apiKey,
            &error
        )
        guard started else {
            throw error ?? SyncStoreError.coreStartFailed
        }
    }
}

private enum APIKeyStore {
    static func loadOrCreate() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.rooindustries.roosync",
            kSecAttrAccount as String: "apiKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = status == errSecSuccess
            ? bytes.map { String(format: "%02x", $0) }.joined()
            : UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.rooindustries.roosync",
            kSecAttrAccount as String: "apiKey",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(key.utf8)
        ]
        SecItemAdd(item as CFDictionary, nil)
        return key
    }
}

private enum SyncStoreError: LocalizedError {
    case coreStartFailed
    case folderAccessDenied
    case invalidFolderID
    case invalidFolderName
    case folderAlreadyExists

    var errorDescription: String? {
        switch self {
        case .coreStartFailed: "The Syncthing core could not be started."
        case .folderAccessDenied: "RooSync could not access the selected folder."
        case .invalidFolderID: "Enter a valid folder ID without path separators."
        case .invalidFolderName: "Choose a folder name without path separators."
        case .folderAlreadyExists: "A folder with this Syncthing ID already exists."
        }
    }
}
