import AppIntents

struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync now"
    static let description = IntentDescription("Rescan RooSync folders and sync available changes.")

    func perform() async -> some IntentResult & ProvidesDialog {
        let completed = await SyncStore.shared.syncNow()
        let message = completed
            ? "RooSync finished its sync window."
            : "RooSync started a sync window; some folders may still be syncing or paused."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct RooSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Sync with \(.applicationName)"],
            shortTitle: "Sync now",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
