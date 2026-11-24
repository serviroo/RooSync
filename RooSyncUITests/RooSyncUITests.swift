import XCTest

final class RooSyncUITests: XCTestCase {
    @MainActor
    func testFirstRunShowsDeviceIdentityAndSyncAction() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Device ID"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["device-id"].waitForExistence(timeout: 30))
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
    func testSetupE2ESyncFolder() {
        let app = XCUIApplication()
        app.launch()

        let deviceID = app.staticTexts["device-id"]
        XCTAssertTrue(deviceID.waitForExistence(timeout: 30))
        print("ROOSYNC_E2E_DEVICE_ID=\(deviceID.label)")

        app.buttons["Add"].tap()
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
        app.buttons["Add"].tap()
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
        XCTAssertTrue(conflicts.waitForExistence(timeout: 15))
        conflicts.tap()

        let keepCopy = app.buttons["Keep copy"].firstMatch
        XCTAssertTrue(keepCopy.waitForExistence(timeout: 30))
        keepCopy.tap()
        XCTAssertTrue(app.staticTexts["No conflicts"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func openE2EFolder(in app: XCUIApplication) {
        let folder = app.staticTexts["RooSync E2E Vault"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
    }
}
