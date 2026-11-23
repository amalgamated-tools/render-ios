import XCTest

/// Signs in, opens Blueprints from the account menu, and opens one, saving a screenshot of each.
///
/// `testBrowseBlueprints` changes nothing: `UI_BLUEPRINT` picks the Blueprint by name, and without
/// it the first one opens.
///
/// The write tests need `UI_ALLOW_WRITES=1` and act only on a Blueprint named explicitly, never the
/// first one listed. `testToggleAutoSync` switches `UI_BLUEPRINT`'s auto-sync off and back on.
/// `testDisconnectBlueprint` disconnects `UI_DISCONNECT_BLUEPRINT`, which can't be undone, so it has
/// its own variable: point it only at a throwaway Blueprint.
@MainActor
final class BlueprintScreensTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testBrowseBlueprints() throws {
        let driver = AppDriver(self)
        try openList(driver)
        driver.screenshot("blueprints")

        if let name = AppDriver.value("UI_BLUEPRINT") {
            try openBlueprint(named: name, driver)
        } else {
            blueprintRows(driver).firstMatch.tap()
            try waitForDetail(driver)
        }
        driver.screenshot("blueprint")
    }

    func testToggleAutoSync() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Changes a real Blueprint; set UI_ALLOW_WRITES=1")
        let name = try XCTUnwrap(AppDriver.value("UI_BLUEPRINT"), "Set UI_BLUEPRINT to the Blueprint to change")
        let driver = AppDriver(self)
        try openList(driver)
        try openBlueprint(named: name, driver)

        let toggle = driver.app.switches["Auto-Sync"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: AppDriver.timeout), "No auto-sync switch")
        let wasOn = toggle.value as? String == "1"
        for expectOn in [!wasOn, wasOn] {
            // Tap the switch itself; tapping the row's centre lands on the label.
            toggle.switches.firstMatch.tap()
            let banner = driver.app.staticTexts[expectOn ? "Auto-sync on." : "Auto-sync off."].firstMatch
            XCTAssertTrue(banner.waitForExistence(timeout: AppDriver.timeout), "Render didn't confirm the change")
            XCTAssertEqual(toggle.value as? String, expectOn ? "1" : "0")
            driver.screenshot(expectOn ? "auto-sync-on" : "auto-sync-off")
        }
    }

    func testDisconnectBlueprint() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Disconnects a real Blueprint; set UI_ALLOW_WRITES=1")
        let name = try XCTUnwrap(AppDriver.value("UI_DISCONNECT_BLUEPRINT"),
                                 "Set UI_DISCONNECT_BLUEPRINT to a throwaway Blueprint's name")
        let driver = AppDriver(self)
        try openList(driver)
        try openBlueprint(named: name, driver)

        let button = driver.app.buttons["Disconnect Blueprint"].firstMatch
        if !button.waitForExistence(timeout: 2) { driver.app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: AppDriver.timeout), "No Disconnect button")
        // Captured now: `button` is a query, and once the dialog is up it may resolve to the
        // dialog's copy instead.
        let listButtonFrame = button.frame
        button.tap()
        // The dialog repeats the button's title. Depending on the device it's a popover or an action
        // sheet, so the order of the two matches varies; the list's button is the one covered up.
        let matches = driver.app.buttons.matching(identifier: "Disconnect Blueprint")
        XCTAssertTrue(matches.element(boundBy: 1).waitForExistence(timeout: AppDriver.timeout), "No confirmation")
        driver.screenshot("disconnect-confirm")
        let confirm = try XCTUnwrap(matches.allElementsBoundByIndex.first { $0.isHittable && $0.frame != listButtonFrame },
                                    "Can't find the confirmation's button")
        confirm.tap()

        let banner = driver.app.staticTexts["Disconnected \(name). Its resources stay."].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: AppDriver.timeout), "The list didn't report the disconnect")
        XCTAssertFalse(blueprintRows(driver).containing(.staticText, identifier: name).firstMatch.exists)
        driver.screenshot("disconnected")
    }

    // MARK: - Helpers

    private func blueprintRows(_ driver: AppDriver) -> XCUIElementQuery {
        // The loading spinner is also a cell, so `cells.firstMatch` can match before anything has
        // loaded; Blueprint rows carry their own identifier.
        driver.app.descendants(matching: .any).matching(identifier: "blueprintRow")
    }

    private func openList(_ driver: AppDriver) throws {
        driver.launch()
        try driver.signIn()

        let account = driver.app.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: AppDriver.timeout), "No account menu")
        account.tap()
        let blueprints = driver.app.buttons["Blueprints"].firstMatch
        XCTAssertTrue(blueprints.waitForExistence(timeout: AppDriver.timeout), "No Blueprints item in the account menu")
        blueprints.tap()

        XCTAssertTrue(driver.app.navigationBars["Blueprints"].waitForExistence(timeout: AppDriver.timeout))
        XCTAssertTrue(blueprintRows(driver).firstMatch.waitForExistence(timeout: AppDriver.timeout), "The Blueprint list is empty")
    }

    private func openBlueprint(named name: String, _ driver: AppDriver) throws {
        let row = blueprintRows(driver).containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: AppDriver.timeout), "No Blueprint named \(name)")
        row.tap()
        try waitForDetail(driver)
    }

    private func waitForDetail(_ driver: AppDriver) throws {
        XCTAssertTrue(driver.app.staticTexts["Recent Syncs"].firstMatch.waitForExistence(timeout: AppDriver.timeout)
                      || driver.app.staticTexts["RECENT SYNCS"].firstMatch.exists, "The Blueprint screen didn't open")
        XCTAssertTrue(driver.app.staticTexts["Resources"].firstMatch.exists || driver.app.staticTexts["RESOURCES"].firstMatch.exists)
    }
}
