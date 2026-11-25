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
        let addButton = app.buttons.matching(identifier: "Add").firstMatch
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

        let configuredFolder = app.staticTexts["RooSync E2E Vault"]
        XCTAssertTrue(configuredFolder.waitForExistence(timeout: 30))
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

        let browse = app.buttons["Browse"]
        if browse.waitForExistence(timeout: 5), !browse.isSelected { browse.tap() }
        let vaults = app.cells.matching(identifier: "Vaults, Folder").firstMatch
        if !vaults.exists {
            let appFolder = app.cells.matching(identifier: "RooSync, Container").firstMatch
            XCTAssertTrue(appFolder.waitForExistence(timeout: 15))
            appFolder.tap()
        }
        XCTAssertTrue(vaults.waitForExistence(timeout: 15))
        vaults.tap()
        let candidate = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "RooSync E2E Vault")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        candidate.tap()
        app.buttons["Open"].tap()

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
        let folder = app.staticTexts["RooSync E2E Vault"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
    }
}
