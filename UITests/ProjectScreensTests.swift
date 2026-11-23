import XCTest

/// Signs in, opens Projects from the account menu, then a project and one of its environments,
/// saving a screenshot of each. Changes nothing.
///
/// `UI_PROJECT` and `UI_ENVIRONMENT` pick by name; without them the first of each opens.
///
/// `testMoveResourceAndBack` changes real data, so it needs `UI_ALLOW_WRITES=1` and names for
/// everything it touches: it moves `UI_MOVE_RESOURCE` from `UI_ENVIRONMENT` to `UI_MOVE_TO` in
/// `UI_PROJECT`, checks it arrived, then moves it back. `testRenameAndSettingsAndBack` renames
/// `UI_PROJECT` and `UI_ENVIRONMENT` and turns each switch on, then puts all of it back.
/// `testRemoveResource` removes `UI_REMOVE_RESOURCE` from `UI_ENVIRONMENT` and can't put it back
/// (it leaves the project), so restore it afterwards.
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

    func testMoveResourceAndBack() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Moves a real resource; set UI_ALLOW_WRITES=1")
        let project = try XCTUnwrap(AppDriver.value("UI_PROJECT"), "Set UI_PROJECT")
        let source = try XCTUnwrap(AppDriver.value("UI_ENVIRONMENT"), "Set UI_ENVIRONMENT to where the resource is now")
        let target = try XCTUnwrap(AppDriver.value("UI_MOVE_TO"), "Set UI_MOVE_TO to the environment to move it to")
        let resource = try XCTUnwrap(AppDriver.value("UI_MOVE_RESOURCE"), "Set UI_MOVE_RESOURCE to the resource's name")
        let driver = AppDriver(self)
        driver.launch()
        try driver.signIn()
        driver.app.buttons["Account"].firstMatch.tap()
        let projects = driver.app.buttons["Projects"].firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: AppDriver.timeout))
        projects.tap()
        try open(rowsWith: "projectRow", named: project, driver)

        try move(resource, from: source, to: target, driver)
        driver.screenshot("moved")
        try move(resource, from: target, to: source, driver)
        driver.screenshot("moved-back")
    }

    func testRenameAndSettingsAndBack() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Renames a real project; set UI_ALLOW_WRITES=1")
        let project = try XCTUnwrap(AppDriver.value("UI_PROJECT"), "Set UI_PROJECT")
        let environment = try XCTUnwrap(AppDriver.value("UI_ENVIRONMENT"), "Set UI_ENVIRONMENT")
        let driver = try openProjects()
        try open(rowsWith: "projectRow", named: project, driver)

        try rename("Rename Project", from: project, to: project + "-renamed", driver)
        try rename("Rename Project", from: project + "-renamed", to: project, driver)

        try open(rowsWith: "environmentRow", named: environment, driver)
        try rename("Rename Environment", from: environment, to: environment + "-renamed", driver)
        try rename("Rename Environment", from: environment + "-renamed", to: environment, driver)

        let isolation = driver.app.switches["Network Isolation"].firstMatch
        XCTAssertTrue(isolation.waitForExistence(timeout: AppDriver.timeout))
        XCTAssertEqual(isolation.value as? String, "0", "Expected network isolation off to start")
        isolation.switches.firstMatch.tap()
        try expectBanner("Network isolation on.", driver)
        isolation.switches.firstMatch.tap()
        try expectBanner("Network isolation off.", driver)

        let protected = driver.app.switches["Protected"].firstMatch
        XCTAssertEqual(protected.value as? String, "0", "Expected the environment unprotected to start")
        protected.switches.firstMatch.tap()
        try expectBanner("\(environment) is protected.", driver)
        driver.screenshot("protected")
        protected.switches.firstMatch.tap()
        let confirm = driver.app.buttons["Remove Protection"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: AppDriver.timeout), "No confirmation")
        confirm.tap()
        try expectBanner("\(environment) is no longer protected.", driver)
        driver.screenshot("settings-restored")
    }

    func testRemoveResource() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Removes a real resource; set UI_ALLOW_WRITES=1")
        let project = try XCTUnwrap(AppDriver.value("UI_PROJECT"), "Set UI_PROJECT")
        let environment = try XCTUnwrap(AppDriver.value("UI_ENVIRONMENT"), "Set UI_ENVIRONMENT")
        let resource = try XCTUnwrap(AppDriver.value("UI_REMOVE_RESOURCE"), "Set UI_REMOVE_RESOURCE to the resource's name")
        let driver = try openProjects()
        try open(rowsWith: "projectRow", named: project, driver)
        try open(rowsWith: "environmentRow", named: environment, driver)

        let row = driver.app.buttons.matching(NSPredicate(format: "label == %@", resource)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: AppDriver.timeout), "\(resource) isn't in \(environment)")
        row.press(forDuration: 1.2)
        let remove = driver.app.buttons["Remove from Environment"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: AppDriver.timeout), "No Remove item")
        remove.tap()
        // The menu has closed, so the only match left is the confirmation's button.
        let confirm = driver.app.buttons["Remove from Environment"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: AppDriver.timeout), "No confirmation")
        confirm.tap()
        try expectBanner("Removed \(resource) from \(environment).", driver)
        XCTAssertTrue(row.waitForNonExistence(timeout: AppDriver.timeout), "\(resource) still shows")
        driver.screenshot("removed")
    }

    private func openProjects() throws -> AppDriver {
        let driver = AppDriver(self)
        driver.launch()
        try driver.signIn()
        let account = driver.app.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: AppDriver.timeout), "No account menu")
        account.tap()
        let projects = driver.app.buttons["Projects"].firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: AppDriver.timeout))
        projects.tap()
        return driver
    }

    /// Renames through the toolbar's pencil and waits for Render's answer in the title.
    private func rename(_ button: String, from old: String, to new: String, _ driver: AppDriver) throws {
        let pencil = driver.app.buttons[button].firstMatch
        XCTAssertTrue(pencil.waitForExistence(timeout: AppDriver.timeout), "No \(button) button")
        pencil.tap()
        let field = driver.app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: AppDriver.timeout), "No name field")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + new)
        driver.app.alerts.buttons["Save"].tap()
        try expectBanner("Renamed to \(new).", driver)
        XCTAssertTrue(driver.app.navigationBars[new].waitForExistence(timeout: AppDriver.timeout), "Title isn't \(new)")
    }

    private func expectBanner(_ message: String, _ driver: AppDriver) throws {
        XCTAssertTrue(driver.app.staticTexts[message].waitForExistence(timeout: AppDriver.timeout), "No banner: \(message)")
    }

    /// Opens `source`, moves `resource` to `target` from its row's menu, waits for the success
    /// banner and for the row to leave, then returns to the project screen.
    private func move(_ resource: String, from source: String, to target: String, _ driver: AppDriver) throws {
        try open(rowsWith: "environmentRow", named: source, driver)
        let row = driver.app.buttons.matching(NSPredicate(format: "label == %@", resource)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: AppDriver.timeout), "\(resource) isn't in \(source)")
        row.press(forDuration: 1.2)
        let moveTo = driver.app.buttons["Move to"].firstMatch
        XCTAssertTrue(moveTo.waitForExistence(timeout: AppDriver.timeout), "No Move to menu")
        moveTo.tap()
        let destination = driver.app.buttons[target].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: AppDriver.timeout), "\(target) isn't offered")
        destination.tap()
        let banner = driver.app.staticTexts["Moved \(resource) to \(target)."]
        XCTAssertTrue(banner.waitForExistence(timeout: AppDriver.timeout), "No success banner")
        XCTAssertTrue(row.waitForNonExistence(timeout: AppDriver.timeout), "\(resource) still shows in \(source)")
        driver.app.navigationBars.buttons.firstMatch.tap()
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
