import XCTest

/// Signs in, opens Blueprints from the account menu, and opens one, saving a screenshot of each.
///
/// `UI_BLUEPRINT` picks the Blueprint by name; without it the first one opens. Nothing here
/// changes anything in the workspace.
@MainActor
final class BlueprintScreensTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testBrowseBlueprints() throws {
        let driver = AppDriver(self)
        driver.launch()
        try driver.signIn()

        let account = driver.app.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: AppDriver.timeout), "No account menu")
        account.tap()
        let blueprints = driver.app.buttons["Blueprints"].firstMatch
        XCTAssertTrue(blueprints.waitForExistence(timeout: AppDriver.timeout), "No Blueprints item in the account menu")
        blueprints.tap()

        XCTAssertTrue(driver.app.navigationBars["Blueprints"].waitForExistence(timeout: AppDriver.timeout))
        XCTAssertTrue(driver.app.cells.firstMatch.waitForExistence(timeout: AppDriver.timeout), "The Blueprint list is empty")
        driver.screenshot("blueprints")

        driver.openRow(named: AppDriver.value("UI_BLUEPRINT"))
        XCTAssertTrue(driver.app.staticTexts["Recent Syncs"].firstMatch.waitForExistence(timeout: AppDriver.timeout)
                      || driver.app.staticTexts["RECENT SYNCS"].firstMatch.exists, "The Blueprint screen didn't open")
        XCTAssertTrue(driver.app.staticTexts["Resources"].firstMatch.exists || driver.app.staticTexts["RESOURCES"].firstMatch.exists)
        driver.screenshot("blueprint")
    }
}
