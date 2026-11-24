import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import CoreImage
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = SyncStore.shared

    var body: some View {
        TabView {
            FolderListView()
                .tabItem { Label("Folders", systemImage: "folder") }
            NetworkSettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .tint(.indigo)
        .task { store.start() }
        .onAppear { store.updateSceneActivity(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            store.updateSceneActivity(phase == .active)
        }
        .alert("RooSync", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

private struct FolderListView: View {
    @StateObject private var store = SyncStore.shared
    @State private var showingAddDevice = false
    @State private var showingAddFolder = false

    var body: some View {
        NavigationStack {
            List {
                Section("This device") {
                    DeviceIdentityView(deviceID: store.deviceID)
                }
                if store.pendingFolderWarning != nil || !store.pendingDevices.isEmpty || !store.pendingFolders.isEmpty {
                    Section("Pending shares") {
                        if let warning = store.pendingFolderWarning {
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("pending-folder-warning")
                        }
                        ForEach(store.pendingDevices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.id).font(.caption.monospaced()).lineLimit(1)
                                }
                                Spacer()
                                Button("Accept") { Task { await store.accept(device) } }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                        ForEach(store.pendingFolders) { folder in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(folder.name)
                                    Text("Shared by \(folder.deviceID.prefix(7))…")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Accept") { Task { await store.accept(folder) } }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .accessibilityIdentifier("accept-folder-\(folder.id)")
                            }
                        }
                    }
                }
                Section("Folders") {
                    if store.folders.isEmpty {
                        ContentUnavailableView("No folders yet", systemImage: "folder.badge.plus", description: Text("Add a folder to start syncing."))
                    }
                    ForEach(store.folders) { folder in
                        NavigationLink {
                            FolderDetailView(folderID: folder.id)
                        } label: {
                            FolderRow(folder: folder, status: store.statuses[folder.id], conflicts: store.conflicts(in: folder).count)
                        }
                    }
                }
                Section("Devices") {
                    if store.devices.isEmpty {
                        Text("Add a trusted Syncthing device to share folders.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.devices) { device in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                            Text(device.deviceID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("RooSync")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await store.syncNow() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Sync now")
                    Menu {
                        Button("Add app folder", systemImage: "folder.badge.plus") { showingAddFolder = true }
                        Button("Add device", systemImage: "plus.viewfinder") { showingAddDevice = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $showingAddDevice) { AddDeviceView() }
            .sheet(isPresented: $showingAddFolder) { AddFolderView() }
        }
    }
}

private struct DeviceIdentityView: View {
    let deviceID: String

    var body: some View {
        HStack(spacing: 16) {
            if let image = makeQRCode(deviceID) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .padding(8)
                    .background(Color.white)
                    .accessibilityLabel("QR code for this device")
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 60))
                    .frame(width: 88, height: 88)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Device ID").font(.headline)
                if deviceID.isEmpty {
                    ProgressView()
                } else {
                    Text(deviceID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .accessibilityIdentifier("device-id")
                    ShareLink(item: deviceID) {
                        Label("Share ID", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func makeQRCode(_ value: String) -> UIImage? {
        guard !value.isEmpty,
              let data = value.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct FolderRow: View {
    let folder: SyncthingFolder
    let status: FolderStatus?
    let conflicts: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(folder.label, systemImage: folder.paused ? "pause.circle" : "folder")
                    .font(.headline)
                Spacer()
                if conflicts > 0 {
                    Label("\(conflicts)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(conflicts) conflicts")
                }
            }
            Text(folder.paused ? "Paused" : status?.summary ?? "Starting")
                .font(.subheadline)
                .foregroundStyle(!folder.paused && (status?.pullErrors ?? 0) > 0 ? .red : .secondary)
            if let status, !folder.paused, status.isSyncing {
                ProgressView(value: status.fractionComplete)
                    .accessibilityLabel("Sync progress")
                Text("\(status.percentComplete)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = SyncStore.shared
    @State private var deviceID = ""
    @State private var name = ""
    @State private var address = ""
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Device ID or QR code", text: $deviceID, axis: .vertical)
                        .accessibilityIdentifier("device-id-entry")
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if store.isLocalDeviceID(deviceID) {
                        Text("This is this device’s own ID.")
                            .foregroundStyle(.red)
                    }
                    TextField("Name", text: $name)
                    TextField("Address (optional)", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button { showingScanner = true } label: {
                        Label("Scan device QR code", systemImage: "qrcode.viewfinder")
                    }
                }
                Section {
                    Text("Only add devices you trust. Device IDs are public identifiers, not passwords.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                try await store.addDevice(id: deviceID, name: name, address: address.isEmpty ? nil : address)
                                dismiss()
                            } catch {
                                store.report(error)
                            }
                        }
                    }
                    .disabled(deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLocalDeviceID(deviceID))
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { value in
                    deviceID = value
                    showingScanner = false
                }
            }
        }
    }
}

private struct AddFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = SyncStore.shared
    @State private var name = ""
    @State private var folderID = ""
    @State private var showingPicker = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Folder details") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { oldValue, newValue in
                            if folderID.isEmpty || folderID == slug(oldValue) { folderID = slug(newValue) }
                        }
                    TextField("Syncthing folder ID", text: $folderID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Location") {
                    Button { createInDocuments() } label: {
                        Label("Create in RooSync Documents", systemImage: "folder.badge.plus")
                    }
                    .disabled(working || !validInputs)
                    Button { showingPicker = true } label: {
                        Label("Choose an existing folder…", systemImage: "folder")
                    }
                    .disabled(working || !validExternalInputs)
                    Text("RooSync can access locations granted by Files. Whether another app, including Obsidian, can open a selected folder depends on that app and the file provider.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                Task {
                    await addExternal(url)
                }
            }
            .overlay {
                if working { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .alert("RooSync", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func createInDocuments() {
        Task {
            working = true
            defer { working = false }
            do {
                try await store.addFolder(id: normalizedID, name: name)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addExternal(_ url: URL) async {
        working = true
        defer { working = false }
        do {
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.lastPathComponent : name
            try await store.addFolder(id: normalizedID, name: label, externalURL: url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var normalizedID: String {
        let value = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? slug(name) : value
    }

    private var validInputs: Bool {
        Self.isValidFolderName(name) && Self.isValidFolderID(normalizedID)
    }

    private var validExternalInputs: Bool {
        (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.isValidFolderName(name))
            && Self.isValidFolderID(normalizedID)
    }

    private static func isValidFolderName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isValidFolderID(_ value: String) -> Bool {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !id.contains("/") && !id.contains("\\")
            && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func slug(_ value: String) -> String {
        let normalized = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(normalized).split(separator: "-").joined(separator: "-")
    }
}

private struct FolderDetailView: View {
    @StateObject private var store = SyncStore.shared
    @State private var showingFolderPicker = false
    let folderID: String

    private var folder: SyncthingFolder? { store.folders.first { $0.id == folderID } }

    var body: some View {
        Group {
            if let folder {
                List {
                    Section("Status") {
                        LabeledContent("State", value: folder.paused ? "Paused" : store.statuses[folder.id]?.summary ?? "Starting")
                        if let status = store.statuses[folder.id], !folder.paused, status.isSyncing {
                            ProgressView(value: status.fractionComplete)
                            LabeledContent("Progress", value: "\(status.percentComplete)%")
                            LabeledContent("Remaining", value: ByteCountFormatter.string(fromByteCount: status.needBytes, countStyle: .file))
                        }
                        if let status = store.statuses[folder.id], status.pullErrors > 0 {
                            LabeledContent("Errors", value: "\(status.pullErrors)")
                                .foregroundStyle(.red)
                        }
                        LabeledContent("Path", value: folder.path)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                    Section("Actions") {
                        Button(folder.paused ? "Resume syncing" : "Pause syncing", systemImage: folder.paused ? "play.fill" : "pause.fill") {
                            Task { await store.togglePause(folder) }
                        }
                        .disabled(store.isPolicyRestricted && folder.paused)
                        Button("Rescan now", systemImage: "arrow.clockwise") {
                            Task { await store.rescan(folder) }
                        }
                    }
                    Section("Manage") {
                        if store.foldersNeedingReauthorization.contains(folder.id) {
                            Button("Choose folder location again") { showingFolderPicker = true }
                        }
                        NavigationLink("Share with devices") { FolderSharingView(folderID: folder.id) }
                        NavigationLink("Ignore patterns") { IgnorePatternsView(folder: folder) }
                        NavigationLink {
                            ConflictListView(folder: folder)
                        } label: {
                            HStack {
                                Text("Conflicts")
                                Spacer()
                                Text("\(store.conflicts(in: folder).count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle(folder.label)
                .navigationBarTitleDisplayMode(.inline)
                .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                    guard case let .success(urls) = result, let url = urls.first else { return }
                    Task {
                        do {
                            try await store.relinkFolder(folder, to: url)
                        } catch {
                            store.report(error)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark")
            }
        }
    }
}

private struct FolderSharingView: View {
    @StateObject private var store = SyncStore.shared
    let folderID: String

    private var folder: SyncthingFolder? { store.folders.first { $0.id == folderID } }

    var body: some View {
        List {
            if store.devices.isEmpty {
                ContentUnavailableView("No devices", systemImage: "desktopcomputer", description: Text("Add a device before sharing this folder."))
            }
            ForEach(store.devices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { folder?.devices.contains { $0.deviceID == device.deviceID } ?? false },
                    set: { shared in
                        guard let folder else { return }
                        Task { await store.setSharing(folder, deviceID: device.deviceID, shared: shared) }
                    }
                ))
            }
        }
        .navigationTitle("Share folder")
    }
}

private struct IgnorePatternsView: View {
    @StateObject private var store = SyncStore.shared
    @State private var patterns = ""
    @State private var isSaving = false
    let folder: SyncthingFolder

    var body: some View {
        Form {
            Section("Presets") {
                Button("Obsidian workspace files") { addPreset(".obsidian/workspace*.json") }
                Button("Trash folder") { addPreset(".trash") }
            }
            Section("One pattern per line") {
                TextEditor(text: $patterns)
                    .font(.body.monospaced())
                    .frame(minHeight: 240)
                    .accessibilityLabel("Ignore patterns")
            }
            Section {
                Button(isSaving ? "Saving…" : "Save patterns") { save() }
                    .disabled(isSaving)
            }
        }
        .navigationTitle("Ignore patterns")
        .task {
            patterns = (try? await store.ignorePatterns(for: folder.id)) ?? ""
        }
    }

    private func addPreset(_ value: String) {
        var lines = patterns.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if !lines.contains(value) { lines.append(value) }
        patterns = lines.joined(separator: "\n")
    }

    private func save() {
        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                try await store.saveIgnorePatterns(patterns, folderID: folder.id)
            } catch {
                store.report(error)
            }
        }
    }
}

private struct ConflictListView: View {
    @StateObject private var store = SyncStore.shared
    @State private var conflicts: [ConflictFile] = []
    let folder: SyncthingFolder

    var body: some View {
        List {
            if conflicts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No conflicts")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Syncthing conflict copies will appear here.")
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            ForEach(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.url.lastPathComponent).font(.subheadline).textSelection(.enabled)
                    HStack {
                        Button("Keep copy") { resolve(conflict, keep: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Delete", role: .destructive) { resolve(conflict, keep: false) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Conflicts")
        .onAppear(perform: reload)
    }

    private func reload() {
        conflicts = store.conflicts(in: folder)
    }

    private func resolve(_ conflict: ConflictFile, keep: Bool) {
        Task {
            do {
                try await store.resolve(conflict, keep: keep, folderID: folder.id)
            } catch {
                store.report(error)
            }
            reload()
        }
    }
}

private struct NetworkSettingsView: View {
    @StateObject private var store = SyncStore.shared
    @State private var draft = NetworkPreferences()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connectivity") {
                    Toggle("Local discovery", isOn: $draft.discoveryEnabled)
                    Toggle("Relays", isOn: $draft.relaysEnabled)
                    Toggle("LAN only", isOn: $draft.lanOnly)
                }
                Section("Bandwidth limits (KB/s, 0 = unlimited)") {
                    Stepper("Send: \(draft.maxSendKbps)", value: $draft.maxSendKbps, in: 0...100_000, step: 64)
                    Stepper("Receive: \(draft.maxReceiveKbps)", value: $draft.maxReceiveKbps, in: 0...100_000, step: 64)
                }
                Section("Power and data") {
                    Toggle("Pause on cellular", isOn: $draft.pauseOnCellular)
                    Toggle("Pause on battery", isOn: $draft.pauseOnBattery)
                    Toggle("Keep awake while charging", isOn: $draft.keepAliveWhileCharging)
                    Text("Keep-awake only applies while RooSync is open and the device is charging. Background tasks are scheduled opportunistically; processing requests require external power.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    NavigationLink("Syncthing logs") { LogsView() }
                    LabeledContent("Current network", value: store.isCellular ? "Cellular" : "Wi-Fi or other")
                    LabeledContent("Power", value: store.isOnBattery ? "Battery" : "External power")
                }
                Section {
                    Button(isSaving ? "Saving…" : "Save settings") { save() }
                        .disabled(isSaving)
                }
            }
            .navigationTitle("Settings")
            .onAppear { draft = store.preferences }
        }
    }

    private func save() {
        Task {
            isSaving = true
            defer { isSaving = false }
            await store.savePreferences(draft)
        }
    }
}

private struct LogsView: View {
    @StateObject private var store = SyncStore.shared
    @State private var logs = "Loading logs…"

    var body: some View {
        ScrollView {
            Text(logs)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("Syncthing logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: logs) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export logs")
            }
        }
        .task {
            logs = (try? await store.logs()) ?? "Unable to load logs."
        }
    }
}

private struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerController(onScan: onScan)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text("Paste the device ID instead."))
                }
            }
            .navigationTitle("Scan device QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct QRScannerController: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didScan else { return }
            for item in addedItems {
                if case let .barcode(code) = item, let value = code.payloadStringValue {
                    didScan = true
                    dataScanner.stopScanning()
                    onScan(value)
                    return
                }
            }
        }
    }
}
