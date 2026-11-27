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
    @Published private(set) var pendingFolderWarning: String?
    @Published private(set) var foldersNeedingReauthorization = Set<String>()
    @Published private(set) var errorMessage: String?
    @Published private(set) var passiveRefreshWarning: String?
#if DEBUG
    @Published private(set) var isE2ECoreStopped = false
#endif
    @Published private(set) var isCellular = false
    @Published private(set) var isOnBattery = false
    @Published var preferences = NetworkPreferences()
    @Published var sceneIsActive = false

    private let api: SyncthingAPI
    private let apiKey: String
    private let coreStartupTask: Task<Void, Error>
#if DEBUG
    private let coreConfigDirectory: URL
    private let coreDataDirectory: URL
    private let coreDefaultFolder: URL
    let e2eCoreControlsEnabled: Bool
#endif
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
#if DEBUG
        coreDefaultFolder = defaultFolder
        coreConfigDirectory = configDirectory
        coreDataDirectory = dataDirectory
        e2eCoreControlsEnabled = ProcessInfo.processInfo.arguments.contains("--roosync-e2e-core-controls")
#endif
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
                await self?.applyPowerPolicy(isPassive: true)
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
                await self.applyPowerPolicy(isPassive: true)
                self.updateKeepAwake()
            }
        }
        updateKeepAwake()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(isPassive: true)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh(isPassive: Bool = false) async {
        do {
            try await coreStartupTask.value
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        do {
            let refreshedDeviceID = try await api.status()
            var refreshedFolders = try await loadConfiguredFolders()
            let bookmarksUpdated = await restoreBookmarksIfNeeded(for: refreshedFolders)
            let pathsReconciled = try await reconcileAppDocumentsFolderPaths(for: refreshedFolders)
            if bookmarksUpdated || pathsReconciled {
                refreshedFolders = try await loadConfiguredFolders()
            }
            let refreshedDevices = try await api.devices()
                .filter {
                    Self.canonicalDeviceID(normalizeDeviceID($0.deviceID)) != Self.canonicalDeviceID(refreshedDeviceID)
                }
                .sorted {
                    let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    return order == .orderedSame ? $0.deviceID < $1.deviceID : order == .orderedAscending
                }
            let refreshedPendingDevices = try await api.pendingDevices()
            let refreshedPendingFolders: [PendingFolder]
            let refreshedPendingFolderWarning: String?
            do {
                refreshedPendingFolders = try await api.pendingFolders()
                refreshedPendingFolderWarning = nil
            } catch {
                refreshedPendingFolders = []
                refreshedPendingFolderWarning = error.localizedDescription
            }
            var statusWarning: String?
            var refreshedStatuses: [String: FolderStatus] = [:]
            for folder in refreshedFolders {
                do {
                    refreshedStatuses[folder.id] = try await api.folderStatus(folder.id)
                } catch {
                    statusWarning = statusWarning ?? error.localizedDescription
                }
            }
            let optionValues = try await api.options()
            try await applyLANRestriction(mergeNetworkPreferences(from: optionValues).lanOnly)
            let reauthorizationWarning = foldersNeedingReauthorization.isEmpty
                ? nil
                : "RooSync needs folder access again. Open each affected folder and choose its location."
            let refreshWarning = reauthorizationWarning ?? statusWarning

            if deviceID != refreshedDeviceID { deviceID = refreshedDeviceID }
            if folders != refreshedFolders { folders = refreshedFolders }
            foldersLoaded = true
            if devices != refreshedDevices { devices = refreshedDevices }
            if pendingDevices != refreshedPendingDevices { pendingDevices = refreshedPendingDevices }
            if pendingFolders != refreshedPendingFolders { pendingFolders = refreshedPendingFolders }
            if pendingFolderWarning != refreshedPendingFolderWarning { pendingFolderWarning = refreshedPendingFolderWarning }
            if statuses != refreshedStatuses { statuses = refreshedStatuses }
            let refreshedPreferences = mergeNetworkPreferences(from: optionValues)
            if preferences != refreshedPreferences { preferences = refreshedPreferences }
            if isPassive {
                if passiveRefreshWarning != refreshWarning { passiveRefreshWarning = refreshWarning }
            } else {
                if passiveRefreshWarning != nil { passiveRefreshWarning = nil }
                if errorMessage != refreshWarning { errorMessage = refreshWarning }
            }
            await applyPowerPolicy(isPassive: isPassive)
        } catch {
            reportRefreshError(error, isPassive: isPassive)
        }
    }

#if DEBUG
    func stopCoreForE2ETest() async {
        guard e2eCoreControlsEnabled, !isE2ECoreStopped else { return }
        do {
            try await Task.detached { try GoCoreBridge.stop() }.value
            isE2ECoreStopped = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restartCoreForE2ETest() async {
        guard e2eCoreControlsEnabled, isE2ECoreStopped else { return }
        let configDirectory = coreConfigDirectory
        let dataDirectory = coreDataDirectory
        let defaultFolder = coreDefaultFolder
        let apiKey = self.apiKey
        do {
            try await Task.detached {
                try GoCoreBridge.start(
                    configDirectory: configDirectory,
                    dataDirectory: dataDirectory,
                    defaultFolder: defaultFolder,
                    apiKey: apiKey
                )
            }.value
            isE2ECoreStopped = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
#endif

    func syncNow(window: Duration = .seconds(20)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: window)
        do {
            try await coreStartupTask.value
            try await waitForCore(until: min(deadline, clock.now.advanced(by: .seconds(5))))
            var syncedFolders = try await loadConfiguredFolders()
            let bookmarksUpdated = await restoreBookmarksIfNeeded(for: syncedFolders)
            let pathsReconciled = try await reconcileAppDocumentsFolderPaths(for: syncedFolders)
            if bookmarksUpdated || pathsReconciled {
                syncedFolders = try await loadConfiguredFolders()
            }
            if folders != syncedFolders { folders = syncedFolders }
            foldersLoaded = true
            let optionValues = try await api.options()
            let loadedPreferences = mergeNetworkPreferences(from: optionValues)
            if preferences != loadedPreferences { preferences = loadedPreferences }
            try await applyLANRestriction(preferences.lanOnly)
            await applyPowerPolicy()
            folders = try await loadConfiguredFolders()
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
        try await coreStartupTask.value
        guard !isLocalDeviceID(normalizedID) else {
            throw SyncStoreError.localDeviceCannotBeAdded
        }
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
        try await ensureFolderIDAvailable(folderID)
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
        guard !isLocalDeviceID(deviceID) else {
            errorMessage = SyncStoreError.localDeviceCannotBeShared.localizedDescription
            return
        }
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

    func sharerName(for deviceID: String) -> String {
        nonBlank(devices.first { $0.deviceID == deviceID }?.name ?? "", or: "\(deviceID.prefix(7))…")
    }

    func accept(_ device: PendingDevice) async {
        await run {
            try await self.addDevice(id: device.id, name: device.name)
        }
    }

    func accept(_ folder: PendingFolder) async {
        do {
            try await coreStartupTask.value
            guard !isLocalDeviceID(folder.deviceID) else {
                throw SyncStoreError.localDeviceCannotBeShared
            }
            let configuredFolders = try await loadConfiguredFolders()
            if let existing = configuredFolders.first(where: { folderIDsMatchExactly($0.id, folder.id) }) {
                var deviceIDs = existing.devices.map(\.deviceID)
                if !deviceIDs.contains(folder.deviceID) {
                    deviceIDs.append(folder.deviceID)
                }
                try await api.setFolderSharing(existing.id, deviceIDs: Array(Set(deviceIDs)))
                await refresh()
            } else if configuredFolders.contains(where: { $0.id == folder.id }) {
                throw SyncStoreError.canonicalFolderIDCollision
            } else {
                try await addFolder(id: folder.id, name: folder.name, sharedWith: [folder.deviceID])
            }
        } catch {
            errorMessage = error.localizedDescription
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
            guard let (originalName, extensionSuffix) = conflictNameParts(name) else {
                throw SyncStoreError.invalidConflictName
            }
            let parent = conflict.url.deletingLastPathComponent()
            var candidate = parent.appendingPathComponent("\(originalName) (conflict copy)\(extensionSuffix)")
            var suffix = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = parent.appendingPathComponent("\(originalName) (conflict copy \(suffix))\(extensionSuffix)")
                suffix += 1
            }
            try fileManager.moveItem(at: conflict.url, to: candidate)
        } else {
            try fileManager.removeItem(at: conflict.url)
        }
        try await api.scan(folderID)
    }

    private func conflictNameParts(_ name: String) -> (String, String)? {
        guard let marker = name.range(of: ".sync-conflict-", options: .backwards) else { return nil }
        let suffix = String(name[marker.upperBound...])
        let extensionStart = suffix.firstIndex(of: ".")
        let metadata = extensionStart.map { String(suffix[..<$0]) } ?? suffix
        guard metadata.range(of: #"^\d{8}-\d{6}(?:-.+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let fileExtension = extensionStart.map { String(suffix[$0...]) } ?? ""
        return (String(name[..<marker.lowerBound]), fileExtension)
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

    private func reportRefreshError(_ error: Error, isPassive: Bool) {
        if isPassive {
            passiveRefreshWarning = error.localizedDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func applyPowerPolicy(isPassive: Bool = false) async {
        guard foldersLoaded else { return }
        var changed = false
        if isPolicyRestricted {
            for folder in folders where !folder.paused {
                do {
                    try await api.setPaused(true, folderID: folder.id)
                    policyPausedFolders.insert(folder.id)
                    changed = true
                } catch {
                    reportRefreshError(error, isPassive: isPassive)
                }
            }
        } else {
            for folder in folders where policyPausedFolders.contains(folder.id) {
                do {
                    try await api.setPaused(false, folderID: folder.id)
                    policyPausedFolders.remove(folder.id)
                    changed = true
                } catch {
                    reportRefreshError(error, isPassive: isPassive)
                }
            }
        }
        let currentFolderIDs = Set(folders.map(\.id))
        policyPausedFolders.formIntersection(currentFolderIDs)
        savePolicyPausedFolders()
        if changed {
            do {
                folders = try await loadConfiguredFolders()
            } catch {
                reportRefreshError(error, isPassive: isPassive)
            }
        }
    }

    private func updateKeepAwake() {
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        UIApplication.shared.isIdleTimerDisabled = sceneIsActive && preferences.keepAliveWhileCharging && charging
    }

    private func mergeNetworkPreferences(from values: [String: Any]) -> NetworkPreferences {
        let defaults = UserDefaults.standard
        var loaded = preferences
        if defaults.bool(forKey: "networkPreferencesSaved") {
            loaded.discoveryEnabled = defaults.object(forKey: "discoveryEnabled") as? Bool ?? true
            loaded.relaysEnabled = defaults.object(forKey: "relaysEnabled") as? Bool ?? true
            loaded.lanOnly = defaults.object(forKey: "lanOnly") as? Bool ?? false
            loaded.maxSendKbps = defaults.object(forKey: "maxSendKbps") as? Int ?? 0
            loaded.maxReceiveKbps = defaults.object(forKey: "maxReceiveKbps") as? Int ?? 0
        } else {
            loaded.discoveryEnabled = values["localAnnounceEnabled"] as? Bool ?? true
            loaded.relaysEnabled = values["relaysEnabled"] as? Bool ?? true
            loaded.lanOnly = false
            loaded.maxSendKbps = values["maxSendKbps"] as? Int ?? 0
            loaded.maxReceiveKbps = values["maxRecvKbps"] as? Int ?? 0
        }
        return loaded
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

    private func restoreBookmarksIfNeeded(for configuredFolders: [SyncthingFolder]) async -> Bool {
        guard !bookmarksRestored else { return false }
        bookmarksRestored = true
        let storedBookmarks = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        var bookmarks = storedBookmarks
        var updatedPath = false
        let folderIDs = Set(configuredFolders.map(\.id))
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
            if let folder = configuredFolders.first(where: { $0.id == folderID }), folder.path != url.path {
                do {
                    try await api.updateFolderPath(folderID, path: url.path)
                    updatedPath = true
                } catch {
                    foldersNeedingReauthorization.insert(folderID)
                }
            }
        }
        bookmarks = bookmarks.filter { folderIDs.contains($0.key) }
        UserDefaults.standard.set(bookmarks, forKey: "folderBookmarks")
        return updatedPath
    }

    private func reconcileAppDocumentsFolderPaths(for configuredFolders: [SyncthingFolder]) async throws -> Bool {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
        let bookmarks = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
        let bookmarkedFolderIDs = Set(bookmarks.keys)
        var updatedPath = false
        for folder in configuredFolders where !bookmarkedFolderIDs.contains(folder.id) {
            guard let path = rebasedAppDocumentsPath(folder.path, to: documentsDirectory), path != folder.path else {
                continue
            }
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                withIntermediateDirectories: true
            )
            try await api.updateFolderPath(folder.id, path: path)
            updatedPath = true
        }
        return updatedPath
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
        try await addDocumentsFolder(id: id, name: name, sharedWith: sharedWith, incomingLabel: true)
    }

    private func addDocumentsFolder(id: String, name: String, sharedWith: [String], incomingLabel: Bool = false) async throws {
        let folderID = try normalizedFolderID(id)
        let label: String
        var component: String
        if incomingLabel {
            label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            component = safeFolderComponent(label, fallbackID: folderID)
        } else {
            label = try normalizedFolderName(name)
            component = label
        }
        try await ensureFolderIDAvailable(folderID)
        let fileManager = FileManager.default
        let vaults = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaults", isDirectory: true).standardizedFileURL
        try fileManager.createDirectory(at: vaults, withIntermediateDirectories: true)
        let idSuffix = folderID.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .joined()
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

    private func safeFolderComponent(_ label: String, fallbackID: String) -> String {
        let sanitized = String(label.unicodeScalars.map { scalar in
            scalar == "/" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar)
                ? "-"
                : String(scalar)
        }.joined())
        let component = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !component.isEmpty && component != "." && component != ".." {
            return component
        }
        let safeID = String(fallbackID.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        return safeID.isEmpty ? "syncthing-folder" : safeID
    }

    private func ensureFolderIDAvailable(_ folderID: String) async throws {
        try await coreStartupTask.value
        let existingFolders = try await loadConfiguredFolders()
        guard !existingFolders.contains(where: { folderIDsMatchExactly($0.id, folderID) }) else {
            throw SyncStoreError.folderAlreadyExists
        }
        guard !existingFolders.contains(where: { $0.id == folderID }) else {
            throw SyncStoreError.canonicalFolderIDCollision
        }
    }

    private func loadConfiguredFolders() async throws -> [SyncthingFolder] {
        let loadedFolders = try await api.folders()
        guard !hasCanonicalFolderIDCollision(loadedFolders.map(\.id)) else {
            folders = []
            statuses = [:]
            pendingFolders = []
            foldersLoaded = false
            let error = SyncStoreError.canonicalFolderIDCollision
            throw error
        }
        return loadedFolders
    }

    private func hasCanonicalFolderIDCollision(_ folderIDs: [String]) -> Bool {
        var normalizedIDs = Set<String>()
        for folderID in folderIDs {
            if !normalizedIDs.insert(folderID.precomposedStringWithCanonicalMapping).inserted {
                return true
            }
        }
        return false
    }

    private func folderIDsMatchExactly(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
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

    func isLocalDeviceID(_ candidate: String) -> Bool {
        guard !deviceID.isEmpty else { return false }
        return Self.canonicalDeviceID(normalizeDeviceID(candidate)) == Self.canonicalDeviceID(deviceID)
    }

    private static func canonicalDeviceID(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber }.uppercased()
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

#if DEBUG
    static func stop() throws {
        var error: NSError?
        let stopped = RoosyncmobileStopCore(&error)
        guard stopped else {
            throw error ?? SyncStoreError.coreStartFailed
        }
    }
#endif
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
    case localDeviceCannotBeShared
    case localDeviceCannotBeAdded
    case canonicalFolderIDCollision
    case folderAccessDenied
    case invalidFolderID
    case invalidFolderName
    case invalidConflictName
    case folderAlreadyExists

    var errorDescription: String? {
        switch self {
        case .coreStartFailed: "The Syncthing core could not be started."
        case .localDeviceCannotBeShared: "The local RooSync device cannot be selected as a remote peer."
        case .localDeviceCannotBeAdded: "This is this device’s own ID; it cannot be added as a peer."
        case .canonicalFolderIDCollision: "A folder ID differs only by Unicode normalization; RooSync stopped to avoid sharing the wrong folder."
        case .folderAccessDenied: "RooSync could not access the selected folder."
        case .invalidFolderID: "Enter a valid folder ID without path separators."
        case .invalidFolderName: "Choose a folder name without path separators."
        case .invalidConflictName: "The conflict file name is not a valid Syncthing conflict copy."
        case .folderAlreadyExists: "A folder with this Syncthing ID already exists."
        }
    }
}
