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
            attachLogsShareSheetHierarchy(in: app, attachmentPrefix: attachmentPrefix)
            attachScreenshot(named: "\(attachmentPrefix)-logs-share-sheet-empty")
            XCTFail("Export logs did not render a Copy action within 30 seconds.")
            return
        }
        let copyHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: copyLogs
        )
        guard XCTWaiter.wait(for: [copyHittable], timeout: 30) == .completed,
              copyLogs.isHittable else {
            attachLogsShareSheetHierarchy(in: app, attachmentPrefix: attachmentPrefix)
            attachScreenshot(named: "\(attachmentPrefix)-logs-share-sheet-copy-not-hittable")
            XCTFail("The Copy action did not become hittable within 30 seconds.")
            return
        }
        attachLogsShareSheetHierarchy(in: app, attachmentPrefix: attachmentPrefix)
        attachScreenshot(named: "\(attachmentPrefix)-logs-share-sheet")
        copyLogs.tap()
    }

    @MainActor
    private func attachLogsShareSheetHierarchy(in app: XCUIApplication, attachmentPrefix: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(attachmentPrefix) logs share-sheet accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func attachPairedDeviceFailureDiagnostics(
        in app: XCUIApplication,
        folderList: XCUIElement,
        pairedDevice: XCUIElement
    ) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Docker peer row failure accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        attachScreenshot(named: "Docker peer row failure")

        let state: String
        if pairedDevice.exists {
            state = """
            pairedDeviceExists=true
            pairedDeviceFrame=\(pairedDevice.frame)
            pairedDeviceHittable=\(pairedDevice.isHittable)
            folderListFrame=\(folderList.frame)
            """
        } else {
            state = """
            pairedDeviceExists=false
            pairedDeviceFrame=unavailable
            pairedDeviceHittable=unavailable
            folderListFrame=\(folderList.frame)
            """
        }
        let stateAttachment = XCTAttachment(string: state)
        stateAttachment.name = "Docker peer row failure state"
        stateAttachment.lifetime = .keepAlways
        add(stateAttachment)
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
    func testFolderStatusHandlesPlusInFolderID() {
        let app = XCUIApplication()
        app.launch()

        let folderList = app.collectionViews.firstMatch
        XCTAssertTrue(folderList.waitForExistence(timeout: 15))
        let folderRow = app.descendants(matching: .any)
            .matching(identifier: "folder-row-notes+work")
            .firstMatch
        for _ in 0..<12 {
            if folderRow.exists && folderRow.isHittable { break }
            folderList.swipeUp()
        }
        XCTAssertTrue(folderRow.waitForExistence(timeout: 30))
        XCTAssertTrue(
            folderRow.staticTexts["Up to date"].waitForExistence(timeout: 30),
            "The embedded core did not resolve status for the exact plus-containing folder ID."
        )
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
        let pairedDevice = app.descendants(matching: .any)
            .matching(identifier: "paired-device-name-Docker Syncthing E2E")
            .firstMatch
        let isVisiblePeerFrame: (CGRect, CGRect, CGRect) -> Bool = { peerFrame, appFrame, folderListFrame in
            !peerFrame.isEmpty &&
                peerFrame.minX.isFinite &&
                peerFrame.minY.isFinite &&
                peerFrame.maxX.isFinite &&
                peerFrame.maxY.isFinite &&
                appFrame.width > 0 &&
                appFrame.height > 0 &&
                folderListFrame.width > 0 &&
                folderListFrame.height > 0 &&
                appFrame.contains(peerFrame) &&
                folderListFrame.contains(peerFrame)
        }
        var pairedDeviceTapped = false
        for _ in 0..<30 {
            folderList.swipeUp()
            guard pairedDevice.waitForExistence(timeout: 1) else { continue }
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate { element, _ in
                    guard let element = element as? XCUIElement else { return false }
                    let peerFrame = element.frame
                    let appFrame = app.frame
                    let folderListFrame = folderList.frame
                    return isVisiblePeerFrame(peerFrame, appFrame, folderListFrame) && element.isHittable
                },
                object: pairedDevice
            )
            guard XCTWaiter.wait(for: [hittable], timeout: 1) == .completed else { continue }

            let peerFrame = pairedDevice.frame
            let appFrame = app.frame
            let folderListFrame = folderList.frame
            guard isVisiblePeerFrame(peerFrame, appFrame, folderListFrame),
                  pairedDevice.isHittable else { continue }
            let peerTapOffset = CGVector(
                dx: (peerFrame.midX - appFrame.minX) / appFrame.width,
                dy: (peerFrame.midY - appFrame.minY) / appFrame.height
            )
            let peerTap = app.coordinate(withNormalizedOffset: peerTapOffset)
            guard pairedDevice.exists else { continue }
            let tapFrame = pairedDevice.frame
            let tapAppFrame = app.frame
            let tapFolderListFrame = folderList.frame
            guard tapFrame == peerFrame,
                  tapAppFrame == appFrame,
                  isVisiblePeerFrame(tapFrame, tapAppFrame, tapFolderListFrame),
                  pairedDevice.isHittable else { continue }
            peerTap.tap()
            pairedDeviceTapped = true
            break
        }
        guard pairedDeviceTapped else {
            attachPairedDeviceFailureDiagnostics(in: app, folderList: folderList, pairedDevice: pairedDevice)
            XCTFail("The Docker Syncthing device did not remain visible and hittable after scrolling the folder list.")
            return
        }
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
    func testPassiveRefreshFailurePreservesFolderDraftAndRecovers() {
        let app = XCUIApplication()
        app.launchArguments.append("--roosync-e2e-core-controls")
        app.launch()
        XCTAssertTrue(app.staticTexts["device-id"].waitForExistence(timeout: 30))

        tapAddMenu(in: app)
        app.buttons["Add app folder"].tap()
        let name = app.textFields["Name"]
        let folderID = app.textFields["Syncthing folder ID"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        name.typeText("Passive failure draft")
        let folderIDUpdated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "passive-failure-draft"),
            object: folderID
        )
        _ = XCTWaiter.wait(for: [folderIDUpdated], timeout: 5)
        XCTAssertEqual(folderID.value as? String, "passive-failure-draft")

        let coreControl = app.buttons["e2e-core-control"]
        XCTAssertTrue(coreControl.waitForExistence(timeout: 15))
        coreControl.tap()
        let warning = app.staticTexts["passive-refresh-warning-form"]
        XCTAssertTrue(warning.waitForExistence(timeout: 30))
        XCTAssertTrue(warning.isHittable)
        XCTAssertFalse(app.alerts["RooSync"].exists)
        XCTAssertEqual(name.value as? String, "Passive failure draft")
        XCTAssertEqual(folderID.value as? String, "passive-failure-draft")

        let restartControl = app.buttons["Restart embedded core"]
        XCTAssertTrue(restartControl.waitForExistence(timeout: 15))
        XCTAssertTrue(restartControl.isHittable)
        restartControl.tap()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 30))
        XCTAssertEqual(name.value as? String, "Passive failure draft")
        XCTAssertEqual(folderID.value as? String, "passive-failure-draft")
        app.buttons["Cancel"].tap()
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

        let documentManager = XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore.Service")
        guard documentManager.wait(for: .runningForeground, timeout: 10) else {
            let serviceState = XCTAttachment(string: "Document manager service state: \(documentManager.state.rawValue)")
            serviceState.name = "Document manager service state"
            serviceState.lifetime = .keepAlways
            add(serviceState)
            attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Picker-unavailable")
            XCTFail("The active document manager picker did not appear.")
            return
        }
        let browse = documentManager.buttons["Browse"]
        guard browse.waitForExistence(timeout: 5) else {
            attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Browse-unavailable")
            XCTFail("The active document manager picker did not expose Browse from Recents.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Recents")
        if !browse.isSelected { browse.tap() }

        let onMyIPhone = documentManager.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "On My iPhone"))
            .firstMatch
        guard onMyIPhone.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "On-My-iPhone-unavailable")
            XCTFail("Browse did not expose On My iPhone.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Browse")
        onMyIPhone.tap()

        let rooSyncContainer = documentManager.cells.matching(identifier: "RooSync, Container").firstMatch
        guard rooSyncContainer.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "RooSync-unavailable")
            XCTFail("On My iPhone did not expose the RooSync container.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "On-My-iPhone")
        rooSyncContainer.tap()

        let vaults = documentManager.cells
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Vaults"))
            .firstMatch
        guard vaults.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Vaults-unavailable")
            XCTFail("The RooSync container did not expose Vaults.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "RooSync")
        vaults.tap()

        let candidate = documentManager.cells
            .matching(NSPredicate(format: "label BEGINSWITH %@", "RooSync E2E Vault"))
            .firstMatch
        guard candidate.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Vault-candidate-unavailable")
            XCTFail("Vaults did not expose the RooSync E2E Vault folder.")
            return
        }
        attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Vaults")
        candidate.tap()
        let open = documentManager.buttons["Open"]
        guard open.waitForExistence(timeout: 15) else {
            attachDocumentPickerDiagnostics(in: app, picker: nil, service: documentManager, state: "Open-unavailable")
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
    func testConflictCopyCanBeDeleted() {
        let app = XCUIApplication()
        app.launch()
        openE2EFolder(in: app)

        let conflicts = app.staticTexts["Conflicts"]
        let folderDetails = app.collectionViews.firstMatch
        for _ in 0..<8 where !conflicts.isHittable {
            folderDetails.swipeUp()
        }
        guard conflicts.waitForExistence(timeout: 15) else {
            XCTFail("The Conflicts control did not appear.")
            return
        }
        guard conflicts.isHittable else {
            XCTFail("The Conflicts control remained unhittable after scrolling.")
            return
        }
        conflicts.tap()

        let conflict = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Delete action fixture.sync-conflict-")
        ).firstMatch
        guard conflict.waitForExistence(timeout: 15) else {
            XCTFail("The distinct Delete conflict fixture did not appear.")
            return
        }
        let deleteButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Delete"))
        guard deleteButtons.count == 1 else {
            XCTFail("Expected one Delete action for the isolated conflict fixture.")
            return
        }
        let delete = deleteButtons.firstMatch
        guard delete.isHittable else {
            XCTFail("The Delete action for the isolated conflict fixture was not hittable.")
            return
        }
        delete.tap()
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
    private func attachDocumentPickerDiagnostics(
        in app: XCUIApplication,
        picker: XCUIElement?,
        service: XCUIApplication? = nil,
        state: String
    ) {
        if let service {
            let serviceHierarchy = XCTAttachment(string: service.debugDescription)
            serviceHierarchy.name = "Document manager service \(state) accessibility hierarchy"
            serviceHierarchy.lifetime = .keepAlways
            add(serviceHierarchy)
        }
        if let picker {
            let pickerHierarchy = XCTAttachment(string: picker.debugDescription)
            pickerHierarchy.name = "Document picker \(state) accessibility hierarchy"
            pickerHierarchy.lifetime = .keepAlways
            add(pickerHierarchy)
        }
        let hostHierarchy = XCTAttachment(string: "Host app state: \(app.state.rawValue)\n\(app.debugDescription)")
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
