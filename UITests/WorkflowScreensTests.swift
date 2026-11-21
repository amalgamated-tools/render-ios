import XCTest

/// Workflows, a task's runs and one run, against a real workflow.
///
/// `UI_WORKFLOW` picks the workflow by name (first one otherwise), `UI_TASK` the task (default
/// `square`). `testBrowseRuns` changes nothing. `testStartRun` starts a real run, so it only runs
/// with `UI_ALLOW_WRITES=1`.
@MainActor
final class WorkflowScreensTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private var taskName: String { AppDriver.value("UI_TASK") ?? "square" }

    private func openTaskRuns(_ driver: AppDriver) throws {
        driver.launch()
        try driver.signIn()
        driver.openTab("Workflows")
        driver.openRow(named: AppDriver.value("UI_WORKFLOW"))
        // A navigation row reads as a button labelled with its text, not as a cell holding a text.
        // The list is lazy, so a row below the fold doesn't exist until it's scrolled to.
        let task = driver.app.descendants(matching: .any).matching(identifier: taskName).firstMatch
        _ = driver.app.staticTexts["Repository"].waitForExistence(timeout: AppDriver.timeout)
        for _ in 0..<6 where !(task.exists && task.isHittable) {
            driver.app.swipeUp()
        }
        if !task.waitForExistence(timeout: AppDriver.timeout) {
            driver.screenshot("workflow-missing-task")
            XCTFail("No task named \(taskName)")
        }
        driver.screenshot("workflow")
        task.tap()
        XCTAssertTrue(driver.app.navigationBars[taskName].waitForExistence(timeout: AppDriver.timeout))
    }

    func testBrowseRuns() throws {
        let driver = AppDriver(self)
        try openTaskRuns(driver)
        let firstRun = driver.app.cells.firstMatch
        XCTAssertTrue(firstRun.waitForExistence(timeout: AppDriver.timeout), "\(taskName) has no runs")
        driver.screenshot("task-runs")

        firstRun.tap()
        XCTAssertTrue(driver.app.navigationBars["Task Run"].waitForExistence(timeout: AppDriver.timeout))
        XCTAssertTrue(driver.app.staticTexts["Input"].waitForExistence(timeout: AppDriver.timeout), "The run didn't load")
        driver.screenshot("task-run")
    }

    func testStartRun() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Starts a real run; set UI_ALLOW_WRITES=1")
        let driver = AppDriver(self)
        try openTaskRuns(driver)

        driver.app.buttons["runTask"].tap()
        let input = driver.app.textFields["taskInput"]
        XCTAssertTrue(input.waitForExistence(timeout: AppDriver.timeout))
        input.tap()
        input.typeText(AppDriver.value("UI_TASK_INPUT") ?? "[7]")
        driver.screenshot("start-run")
        driver.app.buttons["startRun"].tap()

        // Starting a run opens it, and the screen follows it to its result.
        XCTAssertTrue(driver.app.navigationBars["Task Run"].waitForExistence(timeout: AppDriver.timeout))
        XCTAssertTrue(driver.app.staticTexts["Result"].waitForExistence(timeout: 90), "The run didn't finish")
        driver.screenshot("started-run")
    }
}
