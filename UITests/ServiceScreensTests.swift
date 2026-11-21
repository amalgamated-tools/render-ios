import XCTest

/// Signs in and opens a service, saving a screenshot of each screen on the way.
///
/// `UI_SERVICE` picks the service by name; without it the first one in the list opens. Nothing
/// here changes anything in the workspace.
@MainActor
final class ServiceScreensTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testServiceList() throws {
        let driver = AppDriver(self)
        driver.launch()
        try driver.signIn()
        driver.openTab("Services")
        XCTAssertTrue(driver.app.cells.firstMatch.waitForExistence(timeout: AppDriver.timeout), "The service list is empty")
        driver.screenshot("services")

        driver.openRow(named: AppDriver.value("UI_SERVICE"))
        // The detail screen's own list replaces the service list; its nav bar shows the name.
        XCTAssertTrue(driver.app.navigationBars.element(boundBy: 0).buttons.firstMatch.waitForExistence(timeout: AppDriver.timeout))
        driver.screenshot("service")
    }
}
