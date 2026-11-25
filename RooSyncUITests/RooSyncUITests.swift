import XCTest

final class RooSyncUITests: XCTestCase {
    @MainActor
    func testFirstRunShowsDeviceIdentityAndSyncAction() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Device ID"].waitForExistence(timeout: 30))
        let ownDeviceID = app.staticTexts["device-id"]
        XCTAssertTrue(ownDeviceID.waitForExistence(timeout: 30))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", ownDeviceID.label)).count,
            1
        )
        XCTAssertTrue(app.buttons["Sync now"].exists)
    }

    @MainActor
    func testDuoAdaptiveLayoutAndFormsInStartingPose() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ROOSYNC_DUO_LAYOUT_TESTS"] == "1",
              environment["ROOSYNC_DUO_SIMULATOR_VERIFIED"] == "1" else {
            throw XCTSkip("The Duo layout smoke test requires the exact-profile Duo simulator preflight.")
        }

        let app = XCUIApplication()
        app.launch()

        let deviceID = app.staticTexts["device-id"]
        XCTAssertTrue(deviceID.waitForExistence(timeout: 30))
        XCTAssertTrue(deviceID.isHittable)
        let qrCode = app.images["device-qr-code"]
        XCTAssertTrue(qrCode.waitForExistence(timeout: 15))
        XCTAssertTrue(qrCode.isHittable)
        XCTAssertGreaterThanOrEqual(qrCode.frame.width, 80)
        XCTAssertGreaterThanOrEqual(qrCode.frame.height, 80)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        for element in [deviceID, qrCode] {
            XCTAssertGreaterThanOrEqual(element.frame.minX, window.frame.minX)
            XCTAssertLessThanOrEqual(element.frame.maxX, window.frame.maxX)
            XCTAssertGreaterThanOrEqual(element.frame.minY, window.frame.minY)
            XCTAssertLessThanOrEqual(element.frame.maxY, window.frame.maxY)
        }

        let syncButton = app.buttons["Sync now"]
        let addButton = app.buttons["Add"]
        XCTAssertTrue(syncButton.waitForExistence(timeout: 15))
        XCTAssertTrue(syncButton.isHittable)
        XCTAssertTrue(addButton.waitForExistence(timeout: 15))
        XCTAssertTrue(addButton.isHittable)
        syncButton.tap()
        attachScreenshot(named: "Duo-starting-pose-folders")

        tapAddMenu(in: app)
        app.buttons["Add device"].tap()
        let deviceIDField = app.descendants(matching: .any)
            .matching(identifier: "device-id-entry")
            .firstMatch
        XCTAssertTrue(deviceIDField.waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["Name"].exists)
        XCTAssertTrue(app.textFields["Address (optional)"].exists)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        attachScreenshot(named: "Duo-add-device-form")
        app.buttons["Cancel"].tap()

        tapAddMenu(in: app)
        app.buttons["Add app folder"].tap()
        let folderName = app.textFields["Name"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["Syncthing folder ID"].exists)
        XCTAssertTrue(app.buttons["Create in RooSync Documents"].exists)
        folderName.tap()
        folderName.typeText("Duo smoke draft")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        attachScreenshot(named: "Duo-add-folder-form")
        app.buttons["Cancel"].tap()

        openE2EFolder(in: app)
        let folderAction = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Pause syncing", "Resume syncing"])
        ).firstMatch
        XCTAssertTrue(folderAction.waitForExistence(timeout: 15))
        let sharingLink = app.descendants(matching: .any)
            .matching(identifier: "folder-share-devices-link")
            .firstMatch
        let folderDetailList = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if sharingLink.exists,
               sharingLink.frame.minY >= folderDetailList.frame.minY,
               sharingLink.frame.maxY <= folderDetailList.frame.maxY { break }
            folderDetailList.swipeUp()
        }
        XCTAssertTrue(sharingLink.waitForExistence(timeout: 15))
        XCTAssertTrue(sharingLink.isHittable)
        attachScreenshot(named: "Duo-folder-detail")

        sharingLink.tap()
        XCTAssertTrue(app.navigationBars["Share folder"].waitForExistence(timeout: 15))
        attachScreenshot(named: "Duo-folder-sharing")

        verifyLogsExportCopyAction(in: app, attachmentPrefix: "Duo")
    }

    @MainActor
    func testLogsExportRendersCopyActionOnOrdinarySimulator() {
        let app = XCUIApplication()
        app.launch()

        verifyLogsExportCopyAction(in: app, attachmentPrefix: "Ordinary")
    }

    @MainActor
    private func verifyLogsExportCopyAction(in app: XCUIApplication, attachmentPrefix: String) {
        app.buttons["Settings"].tap()
        let settingsList = app.collectionViews.firstMatch
        XCTAssertTrue(settingsList.waitForExistence(timeout: 15))
        let logsLink = app.descendants(matching: .any)
            .matching(identifier: "settings-syncthing-logs-link")
            .firstMatch
        for _ in 0..<12 {
            if logsLink.exists,
               logsLink.frame.minY >= settingsList.frame.minY,
               logsLink.frame.maxY <= settingsList.frame.maxY { break }
            settingsList.swipeUp()
        }
        XCTAssertTrue(logsLink.waitForExistence(timeout: 15))
        logsLink.tap()
        let exportLogs = app.buttons["Export logs"]
        XCTAssertTrue(exportLogs.waitForExistence(timeout: 15))
        XCTAssertTrue(exportLogs.isHittable)
        attachScreenshot(named: "\(attachmentPrefix)-logs-toolbar")
        exportLogs.tap()
        attachScreenshot(named: "\(attachmentPrefix)-logs-share-sheet-open")
        let copyLogs = app.cells["Copy"]
        guard copyLogs.waitForExistence(timeout: 30) else {
            let hierarchy = XCTAttachment(string: String(app.debugDescription.prefix(20000)))
            hierarchy.name = "\(attachmentPrefix) logs share-sheet accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            attachScreenshot(named: "\(attachmentPrefix)-logs-share-sheet-empty")
            XCTFail("Export logs did not render a Copy action within 30 seconds.")
            return
        }
        attachScreenshot(named: "\(attachmentPrefix)-logs-share-sheet")
        copyLogs.tap()
    }

    @MainActor
    func testEmbeddedRESTRejectsRequestsWithoutAPIKey() async throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["device-id"].waitForExistence(timeout: 30))

        let url = URL(string: "http://127.0.0.1:8384/rest/system/status")!
        let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let response = response as? HTTPURLResponse else {
            XCTFail("The local Syncthing API returned no HTTP response.")
            return
        }
        XCTAssertTrue([401, 403].contains(response.statusCode))
    }

    @MainActor
    func testCannotAddLocalDeviceID() {
        let app = XCUIApplication()
        app.launch()

        let ownDeviceID = app.staticTexts["device-id"]
        XCTAssertTrue(ownDeviceID.waitForExistence(timeout: 30))
        tapAddMenu(in: app)
        app.buttons["Add device"].tap()

        let idField = app.descendants(matching: .any).matching(identifier: "device-id-entry").firstMatch
        XCTAssertTrue(idField.waitForExistence(timeout: 15))
        idField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let keyboardAppeared = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        if !keyboardAppeared {
            attachKeyboardFocusFailureDiagnostics(in: app, field: idField)
        }
        XCTAssertTrue(keyboardAppeared, "The device ID field did not receive keyboard focus.")
        idField.typeText(ownDeviceID.label)

        XCTAssertTrue(app.staticTexts["This is this device’s own ID."].exists)
        let addButton = app.buttons["add-device-confirmation"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15))
        XCTAssertFalse(addButton.isEnabled)
    }

    @MainActor
    func testAcceptingOfferForExistingFolderSharesWithoutReplacingIt() {
        let app = XCUIApplication()
        app.launch()
        let accept = app.buttons["accept-folder-roosync-e2e-existing-offer"]
        XCTAssertTrue(accept.waitForExistence(timeout: 60))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 30))

        let folderList = app.collectionViews.firstMatch
        XCTAssertTrue(folderList.waitForExistence(timeout: 15))
        let foldersTab = app.buttons["Folders"]
        XCTAssertTrue(foldersTab.waitForExistence(timeout: 15))
        let pairedDevice = app.staticTexts["paired-device-name-Docker Syncthing E2E"]
        for _ in 0..<12 {
            if pairedDevice.exists && pairedDevice.frame.maxY < foldersTab.frame.minY { break }
            folderList.swipeUp()
        }
        XCTAssertTrue(pairedDevice.waitForExistence(timeout: 15))
        XCTAssertTrue(pairedDevice.isHittable)
        pairedDevice.tap()
        XCTAssertFalse(
            app.staticTexts["Folder unavailable"].waitForExistence(timeout: 2),
            "Tapping a paired device must not select a folder detail."
        )
    }

    @MainActor
    func testCanonicalEquivalentFolderOfferDoesNotShareExistingFolder() {
        let app = XCUIApplication()
        app.launch()
        let decomposedID = "cafe\u{0301}-e2e"
        let accept = app.buttons["accept-folder-\(decomposedID)"]
        XCTAssertTrue(accept.waitForExistence(timeout: 60))
        accept.tap()
        XCTAssertTrue(app.alerts.staticTexts["A folder ID differs only by Unicode normalization; RooSync stopped to avoid sharing the wrong folder."].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(accept.waitForExistence(timeout: 15))
    }

    @MainActor
    func testCanonicalEquivalentPendingFolderIDsFailClosed() {
        let app = XCUIApplication()
        app.launch()
        let message = "The peer has folder IDs that differ only by Unicode normalization, so RooSync cannot safely display these offers."
        let warning = app.staticTexts["pending-folder-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 30))
        XCTAssertEqual(warning.label, message)
        let pendingFolderAccepts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "accept-folder-"))
        XCTAssertEqual(pendingFolderAccepts.count, 0)

        let folderList = app.collectionViews.firstMatch
        XCTAssertTrue(folderList.waitForExistence(timeout: 15))
        let configuredFolder = app.buttons["folder-row-roosync-e2e-vault"]
        for _ in 0..<8 {
            if configuredFolder.exists && configuredFolder.isHittable { break }
            folderList.swipeUp()
        }
        XCTAssertTrue(configuredFolder.waitForExistence(timeout: 30))
        XCTAssertTrue(configuredFolder.isHittable)
        configuredFolder.tap()
        let refreshedStatus = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "State, ")
        ).firstMatch
        XCTAssertTrue(refreshedStatus.waitForExistence(timeout: 30))
        XCTAssertTrue(["Up to date", "Syncing", "Error", "Stopped"].contains {
            refreshedStatus.label.hasSuffix($0)
        })
        XCTAssertTrue(app.buttons["Pause syncing"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testAcceptingUnsafeFolderLabelsUsesSafePaths() {
        let app = XCUIApplication()
        app.launch()
        let slashOffer = app.buttons["accept-folder-roosync-e2e-slash-label"]
        XCTAssertTrue(slashOffer.waitForExistence(timeout: 60))
        slashOffer.tap()
        XCTAssertTrue(slashOffer.waitForNonExistence(timeout: 30))
        let emptyOffer = app.buttons["accept-folder-roosync-e2e-empty-label"]
        XCTAssertTrue(emptyOffer.waitForExistence(timeout: 30))
        emptyOffer.tap()
        XCTAssertTrue(emptyOffer.waitForNonExistence(timeout: 30))
    }

    @MainActor
    func testDuplicateExternalFolderIDIsRejected() {
        let app = XCUIApplication()
        app.launch()
        tapAddMenu(in: app)
        app.buttons["Add app folder"].tap()

        let folderID = app.textFields["Syncthing folder ID"]
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        folderID.tap()
        folderID.typeText("roosync-e2e-vault")
        name.tap()
        name.typeText("Duplicate external folder")
        app.buttons["Choose an existing folder…"].tap()

        let picker = app
        let browse = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Browse"))
            .firstMatch
        guard browse.waitForExistence(timeout: 30) else {
            attachDocumentPickerDiagnostics(in: app, picker: picker, state: "Browse-unavailable")
            XCTFail("The active document manager picker did not expose Browse from Recents.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: picker, state: "Recents")
        if !browse.isSelected { browse.tap() }

        let onMyIPhone = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "On My iPhone"))
            .firstMatch
        guard onMyIPhone.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: picker, state: "On-My-iPhone-unavailable")
            XCTFail("Browse did not expose On My iPhone.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: picker, state: "Browse")
        onMyIPhone.tap()

        let rooSyncContainer = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "RooSync"))
            .firstMatch
        guard rooSyncContainer.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: picker, state: "RooSync-unavailable")
            XCTFail("On My iPhone did not expose the RooSync container.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: picker, state: "On-My-iPhone")
        rooSyncContainer.tap()

        let vaults = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Vaults"))
            .firstMatch
        guard vaults.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: picker, state: "Vaults-unavailable")
            XCTFail("The RooSync container did not expose Vaults.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: picker, state: "RooSync")
        vaults.tap()

        let candidate = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "RooSync E2E Vault"))
            .firstMatch
        guard candidate.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: picker, state: "Vault-candidate-unavailable")
            XCTFail("Vaults did not expose the RooSync E2E Vault folder.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: picker, state: "Vaults")
        candidate.tap()
        let open = picker.buttons["Open"]
        guard open.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: picker, state: "Open-unavailable")
            XCTFail("The selected vault did not expose Open.")
            return
        }
        open.tap()

        XCTAssertTrue(app.alerts.staticTexts["A folder with this Syncthing ID already exists."].waitForExistence(timeout: 30))
    }

    @MainActor
    func testSetupE2ESyncFolder() {
        let app = XCUIApplication()
        app.launch()

        let deviceID = app.staticTexts["device-id"]
        XCTAssertTrue(deviceID.waitForExistence(timeout: 30))
        print("ROOSYNC_E2E_DEVICE_ID=\(deviceID.label)")

        tapAddMenu(in: app)
        app.buttons["Add app folder"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        name.typeText("RooSync E2E Vault")
        app.buttons["Create in RooSync Documents"].tap()
        XCTAssertTrue(app.staticTexts["RooSync E2E Vault"].waitForExistence(timeout: 30))
    }

    @MainActor
    func testAddE2EDeviceAndShareVault() {
        let environment = ProcessInfo.processInfo.environment
        guard let peerID = environment["ROOSYNC_E2E_PEER_ID"],
              let peerAddress = environment["ROOSYNC_E2E_PEER_ADDRESS"] else {
            XCTFail("Docker peer setup was not provided.")
            return
        }

        let app = XCUIApplication()
        app.launch()
        tapAddMenu(in: app)
        app.buttons["Add device"].tap()

        let idField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Device ID or QR code"))
            .firstMatch
        XCTAssertTrue(idField.waitForExistence(timeout: 15))
        idField.tap()
        idField.typeText(peerID)

        let nameField = app.textFields["Name"]
        nameField.tap()
        nameField.typeText("Docker Syncthing E2E")
        let addressField = app.textFields["Address (optional)"]
        addressField.tap()
        addressField.typeText(peerAddress)
        let addButtons = app.buttons.matching(identifier: "Add")
        XCTAssertGreaterThan(addButtons.count, 0)
        addButtons.element(boundBy: addButtons.count - 1).tap()

        let folder = app.staticTexts["RooSync E2E Vault"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        app.staticTexts["Share with devices"].tap()
        let peerSwitch = app.switches["Docker Syncthing E2E"]
        XCTAssertTrue(peerSwitch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.switches.count, 1)
        if peerSwitch.value as? String == "0" {
            peerSwitch.tap()
        }
    }

    @MainActor
    func testPauseE2ESyncFolder() {
        let app = XCUIApplication()
        app.launch()
        openE2EFolder(in: app)
        app.buttons["Pause syncing"].tap()
        XCTAssertTrue(app.buttons["Resume syncing"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testResumeE2ESyncFolder() {
        let app = XCUIApplication()
        app.launch()
        openE2EFolder(in: app)
        app.buttons["Resume syncing"].tap()
        XCTAssertTrue(app.buttons["Pause syncing"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testConflictCopyCanBeKept() {
        let app = XCUIApplication()
        app.launch()
        openE2EFolder(in: app)

        let conflicts = app.staticTexts["Conflicts"]
        let folderDetails = app.collectionViews.firstMatch
        for _ in 0..<8 where !conflicts.isHittable {
            folderDetails.swipeUp()
        }
        XCTAssertTrue(conflicts.waitForExistence(timeout: 15))
        guard conflicts.isHittable else { return }
        conflicts.tap()

        for _ in 0..<4 {
            let keepCopy = app.buttons["Keep copy"].firstMatch
            XCTAssertTrue(keepCopy.waitForExistence(timeout: 30))
            keepCopy.tap()
        }
        XCTAssertTrue(app.staticTexts["No conflicts"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func tapAddMenu(in app: XCUIApplication) {
        let addMenu = app.buttons["Add"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 30))
        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachDocumentPickerDiagnostics(in app: XCUIApplication, picker: XCUIApplication, state: String) {
        let hierarchy = XCTAttachment(string: "Process state: \(picker.state.rawValue)\n\(picker.debugDescription.prefix(20000))")
        hierarchy.name = "Document picker \(state) accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let hostHierarchy = XCTAttachment(string: String(app.debugDescription.prefix(20000)))
        hostHierarchy.name = "Host app \(state) accessibility hierarchy"
        hostHierarchy.lifetime = .keepAlways
        add(hostHierarchy)
        attachScreenshot(named: "Document picker \(state)")
    }

    @MainActor
    private func attachKeyboardFocusFailureDiagnostics(in app: XCUIApplication, field: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        let state = """
        appState=\(app.state)
        fieldExists=\(field.exists)
        fieldHittable=\(field.isHittable)
        keyboardExists=\(keyboard.exists)
        """

        let stateAttachment = XCTAttachment(string: String(state.prefix(2048)))
        stateAttachment.name = "Self-add keyboard focus state"
        add(stateAttachment)

        let hierarchyAttachment = XCTAttachment(string: String(app.debugDescription.prefix(12000)))
        hierarchyAttachment.name = "Self-add failure-time UI hierarchy"
        add(hierarchyAttachment)

        let screenshotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshotAttachment.name = "Self-add failure-time screenshot"
        add(screenshotAttachment)
    }

    @MainActor
    private func openE2EFolder(in app: XCUIApplication) {
        let folderList = app.collectionViews.firstMatch
        XCTAssertTrue(folderList.waitForExistence(timeout: 15))
        let folder = app.descendants(matching: .any)
            .matching(identifier: "folder-row-roosync-e2e-vault")
            .firstMatch
        for _ in 0..<12 {
            if folder.exists,
               folder.frame.minY >= folderList.frame.minY,
               folder.frame.maxY <= folderList.frame.maxY { break }
            folderList.swipeUp()
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        XCTAssertTrue(folder.isHittable)
        folder.tap()
    }
}
