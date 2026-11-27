import Foundation

struct SyncthingDevice: Decodable, Identifiable, Equatable, Sendable {
    let deviceID: String
    let name: String
    let addresses: [String]?

    var id: String { deviceID }
    var displayName: String { nonBlank(name, or: String(deviceID.prefix(7))) }
}

struct SyncthingFolder: Decodable, Identifiable, Equatable, Sendable {
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

    var displayName: String { nonBlank(label, or: id) }

    private enum CodingKeys: String, CodingKey {
        case id, label, path, paused, devices
    }
}

struct FolderShare: Decodable, Identifiable, Equatable, Sendable {
    let deviceID: String
    var id: String { deviceID }
}

struct FolderStatus: Decodable, Equatable, Sendable {
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

struct PendingDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    var displayName: String { nonBlank(name, or: String(id.prefix(7))) }
}

struct PendingFolder: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let deviceID: String

    var displayName: String { nonBlank(name, or: id) }
}

func nonBlank(_ name: String, or fallback: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : name
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
        }.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func pendingFolders() async throws -> [PendingFolder] {
        let data = try await request("/rest/cluster/pending/folders")
        let folderIDs = try topLevelObjectKeys(in: data)
        guard !hasCanonicalFolderIDCollision(folderIDs) else {
            throw APIError.canonicalFolderIDCollision
        }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: [String: Any]] ?? [:]
        return value.flatMap { folderID, info in
            let offers = info["offeredBy"] as? [String: [String: Any]] ?? [:]
            return offers.map { deviceID, offer in
                PendingFolder(id: folderID, name: offer["label"] as? String ?? folderID, deviceID: deviceID)
            }
        }.sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.deviceID < $1.deviceID
        }
    }

    private func topLevelObjectKeys(in data: Data) throws -> [String] {
        let bytes = Array(data)
        var index = 0

        func skipWhitespace() {
            while index < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == 0x22 else { throw APIError.invalidResponse }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
            }
            throw APIError.invalidResponse
        }

        func skipValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw APIError.invalidResponse }
            if bytes[index] == 0x22 {
                _ = try parseString()
                return
            }

            var depth = 0
            var insideString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if insideString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        insideString = false
                    }
                } else if byte == 0x22 {
                    insideString = true
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    if depth == 0 { return }
                    depth -= 1
                    index += 1
                    if depth == 0 { return }
                    continue
                } else if byte == 0x2C && depth == 0 {
                    return
                }
                index += 1
            }
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7B else { throw APIError.invalidResponse }
        index += 1
        var keys: [String] = []
        while true {
            skipWhitespace()
            guard index < bytes.count else { throw APIError.invalidResponse }
            if bytes[index] == 0x7D {
                return keys
            }
            keys.append(try parseString())
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else { throw APIError.invalidResponse }
            index += 1
            try skipValue()
            skipWhitespace()
            guard index < bytes.count else { throw APIError.invalidResponse }
            if bytes[index] == 0x2C {
                index += 1
            } else if bytes[index] == 0x7D {
                return keys
            } else {
                throw APIError.invalidResponse
            }
        }
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
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
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
    case canonicalFolderIDCollision
    case server(String)
    case folderHasErrors(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The Syncthing API URL is invalid."
        case .invalidResponse: "Syncthing returned an unexpected response."
        case .canonicalFolderIDCollision: "The peer has folder IDs that differ only by Unicode normalization, so RooSync cannot safely display these offers."
        case let .server(message): message
        case let .folderHasErrors(folderID): "Syncthing reported pull errors for folder \(folderID)."
        }
    }
}
