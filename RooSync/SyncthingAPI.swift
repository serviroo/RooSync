import Foundation

struct SyncthingDevice: Decodable, Identifiable, Sendable {
    let deviceID: String
    let name: String
    let addresses: [String]?

    var id: String { deviceID }
}

struct SyncthingFolder: Decodable, Identifiable, Sendable {
    let id: String
    let label: String
    let path: String
    let paused: Bool
    let devices: [FolderShare]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? id
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        devices = try values.decodeIfPresent([FolderShare].self, forKey: .devices) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, path, paused, devices
    }
}

struct FolderShare: Decodable, Identifiable, Sendable {
    let deviceID: String
    var id: String { deviceID }
}

struct FolderStatus: Decodable, Sendable {
    let state: String
    let globalBytes: Int64
    let inSyncBytes: Int64
    let needBytes: Int64
    let pullErrors: Int

    var fractionComplete: Double {
        guard globalBytes > 0 else { return 1 }
        return min(1, max(0, Double(inSyncBytes) / Double(globalBytes)))
    }

    var summary: String {
        if pullErrors > 0 || state == "error" { return "Error" }
        if state == "stopped" || state == "unavailable" { return "Stopped" }
        if state == "paused" { return "Paused" }
        if needBytes > 0 || isSyncing { return "Syncing" }
        return state == "idle" ? "Up to date" : state.capitalized
    }

    var isSyncing: Bool {
        ["syncing", "scanning", "sync-waiting", "cleaning"].contains(state)
    }

    var percentComplete: Int {
        Int((fractionComplete * 100).rounded())
    }
}

struct PendingDevice: Identifiable, Sendable {
    let id: String
    let name: String
}

struct PendingFolder: Identifiable, Sendable {
    let id: String
    let name: String
    let deviceID: String
}

@MainActor
final class SyncthingAPI {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration)
    }

    func status() async throws -> String {
        let value = try await json("/rest/system/status") as? [String: Any]
        guard let deviceID = value?["myID"] as? String else { throw APIError.invalidResponse }
        return deviceID
    }

    func devices() async throws -> [SyncthingDevice] {
        try await decoded("/rest/config/devices")
    }

    func folders() async throws -> [SyncthingFolder] {
        try await decoded("/rest/config/folders")
    }

    func folderStatus(_ id: String) async throws -> FolderStatus {
        try await decoded("/rest/db/status", query: [URLQueryItem(name: "folder", value: id)])
    }

    func addDevice(id: String, name: String, address: String? = nil, allowedNetworks: [String]? = nil) async throws {
        var value = try await json("/rest/config/defaults/device") as? [String: Any] ?? [:]
        value["deviceID"] = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        value["name"] = name.isEmpty ? "Syncthing device" : name
        if let address, !address.isEmpty { value["addresses"] = [address] }
        if let allowedNetworks { value["allowedNetworks"] = allowedNetworks }
        try await send("/rest/config/devices", method: "POST", json: value)
    }

    func deviceConfigurations() async throws -> [[String: Any]] {
        try await json("/rest/config/devices") as? [[String: Any]] ?? []
    }

    func setAllowedNetworks(_ networks: [String], deviceID: String) async throws {
        try await send(try deviceConfigPath(deviceID), method: "PATCH", json: ["allowedNetworks": networks])
    }

    func addFolder(id: String, name: String, path: String, sharedWith: [String] = []) async throws {
        var value = try await json("/rest/config/defaults/folder") as? [String: Any] ?? [:]
        value["id"] = id
        value["label"] = name
        value["path"] = path
        value["devices"] = sharedWith.map { ["deviceID": $0] }
        try await send("/rest/config/folders", method: "POST", json: value)
    }

    func updateFolderPath(_ folderID: String, path: String) async throws {
        try await send(try folderConfigPath(folderID), method: "PATCH", json: ["path": path])
    }

    func setFolderSharing(_ folderID: String, deviceIDs: [String]) async throws {
        let route = try folderConfigPath(folderID)
        var value = try await json(route) as? [String: Any] ?? [:]
        value["devices"] = deviceIDs.map { ["deviceID": $0] }
        try await send(route, method: "PUT", json: value)
    }

    func setPaused(_ paused: Bool, folderID: String) async throws {
        try await send(try folderConfigPath(folderID), method: "PATCH", json: ["paused": paused])
    }

    func scan(_ folderID: String) async throws {
        try await send("/rest/db/scan", query: [URLQueryItem(name: "folder", value: folderID)], method: "POST")
    }

    func ignores(_ folderID: String) async throws -> String {
        let data = try await request("/rest/db/ignores", query: [URLQueryItem(name: "folder", value: folderID)])
        if let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let patterns = value["ignore"] as? [String] {
            return patterns.joined(separator: "\n")
        }
        return ""
    }

    func setIgnores(_ content: String, folderID: String) async throws {
        let patterns = content.components(separatedBy: .newlines)
        try await send("/rest/db/ignores", query: [URLQueryItem(name: "folder", value: folderID)], method: "POST", json: ["ignore": patterns])
    }

    func pendingDevices() async throws -> [PendingDevice] {
        let value = try await json("/rest/cluster/pending/devices") as? [String: [String: Any]] ?? [:]
        return value.map { key, info in
            PendingDevice(id: key, name: info["name"] as? String ?? info["deviceName"] as? String ?? key)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func pendingFolders() async throws -> [PendingFolder] {
        let value = try await json("/rest/cluster/pending/folders") as? [String: [String: Any]] ?? [:]
        return value.flatMap { folderID, info in
            let offers = info["offeredBy"] as? [String: [String: Any]] ?? [:]
            return offers.map { deviceID, offer in
                PendingFolder(id: folderID, name: offer["label"] as? String ?? folderID, deviceID: deviceID)
            }
        }
    }

    func options() async throws -> [String: Any] {
        try await json("/rest/config/options") as? [String: Any] ?? [:]
    }

    func saveOptions(_ options: [String: Any]) async throws {
        try await send("/rest/config/options", method: "PUT", json: options)
    }

    func logs() async throws -> String {
        let data = try await request("/rest/system/log.txt")
        return String(decoding: data, as: UTF8.self)
    }

    private func decoded<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func json(_ path: String, query: [URLQueryItem] = []) async throws -> Any? {
        let data = try await request(path, query: query)
        guard !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func send(_ path: String, query: [URLQueryItem] = [], method: String, json: Any? = nil) async throws {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        _ = try await request(path, query: query, method: method, body: body)
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 8384
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func folderConfigPath(_ id: String) throws -> String {
        let pathComponentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: pathComponentCharacters) else {
            throw APIError.invalidURL
        }
        return "/rest/config/folders/\(encodedID)"
    }

    private func deviceConfigPath(_ id: String) throws -> String {
        let pathComponentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: pathComponentCharacters) else {
            throw APIError.invalidURL
        }
        return "/rest/config/devices/\(encodedID)"
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(String)
    case folderHasErrors(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The Syncthing API URL is invalid."
        case .invalidResponse: "Syncthing returned an unexpected response."
        case let .server(message): message
        case let .folderHasErrors(folderID): "Syncthing reported pull errors for folder \(folderID)."
        }
    }
}
