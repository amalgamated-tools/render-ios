import XCTest

/// Signs in, opens Projects from the account menu, then a project and one of its environments,
/// saving a screenshot of each. Changes nothing.
///
/// `UI_PROJECT` and `UI_ENVIRONMENT` pick by name; without them the first of each opens.
@MainActor
final class ProjectScreensTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testBrowseProjects() throws {
        let driver = AppDriver(self)
        driver.launch()
        try driver.signIn()

        let account = driver.app.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: AppDriver.timeout), "No account menu")
        account.tap()
        let projects = driver.app.buttons["Projects"].firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: AppDriver.timeout), "No Projects item in the account menu")
        projects.tap()
        XCTAssertTrue(driver.app.navigationBars["Projects"].waitForExistence(timeout: AppDriver.timeout))

        try open(rowsWith: "projectRow", named: AppDriver.value("UI_PROJECT"), driver)
        try open(rowsWith: "environmentRow", named: AppDriver.value("UI_ENVIRONMENT"), driver)
        driver.screenshot("environment")
    }

    /// Waits for a row with `identifier` (so a loading spinner can't be tapped), optionally one
    /// containing `name`, and taps it. Screenshots the list first.
    private func open(rowsWith identifier: String, named name: String?, _ driver: AppDriver) throws {
        var rows = driver.app.buttons.matching(identifier: identifier)
        if let name {
            rows = rows.matching(NSPredicate(format: "label CONTAINS %@", name))
        }
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: AppDriver.timeout), "No \(identifier) \(name ?? "")")
        driver.screenshot(identifier == "projectRow" ? "project-list" : "project")
        row.tap()
    }
}
