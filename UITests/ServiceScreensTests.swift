import XCTest

/// Signs in and opens a service, saving a screenshot of each screen on the way.
///
/// `UI_SERVICE` picks the service by name; without it the first one in the list opens.
/// `testServiceList` changes nothing.
///
/// `testRestoreNewestSnapshot` overwrites a real disk, so it needs `UI_ALLOW_WRITES=1` and
/// `UI_DISK_SERVICE` naming a throwaway service with a disk. It restores the newest snapshot, the one
/// that loses the least, and checks Render accepted it.
///
/// `testAddAndDeleteDisk` needs the same two settings, but a `UI_DISK_SERVICE` with **no** disk. It
/// adds a 1 GB disk with a random name, then deletes it through the confirmation sheet, so the service
/// ends as it started.
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

    func testRestoreNewestSnapshot() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Overwrites a real disk; set UI_ALLOW_WRITES=1")
        let service = try XCTUnwrap(AppDriver.value("UI_DISK_SERVICE"), "Set UI_DISK_SERVICE to a throwaway service with a disk")
        let driver = AppDriver(self)
        driver.launch()
        try driver.signIn()
        driver.openTab("Services")
        driver.openRow(named: service)

        let diskRow = driver.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Disk'")).firstMatch
        for _ in 0..<6 where !diskRow.exists { driver.app.swipeUp() }
        XCTAssertTrue(diskRow.waitForExistence(timeout: AppDriver.timeout), "\(service) shows no disk")
        diskRow.tap()
        XCTAssertTrue(driver.app.navigationBars["Disk"].waitForExistence(timeout: AppDriver.timeout))

        // Snapshots are newest first, so the first Restore button is the newest.
        let restore = driver.app.buttons["Restore"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: AppDriver.timeout), "The disk has no snapshots")
        driver.screenshot("disk")
        restore.tap()
        let confirm = driver.app.buttons["Restore and Overwrite"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: AppDriver.timeout), "No restore confirmation")
        driver.screenshot("restore-confirmation")
        confirm.tap()

        let done = driver.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Restoring the snapshot'")).firstMatch
        let failed = driver.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nothing was restored'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "Render didn't accept the restore\(failed.exists ? ": \(failed.label)" : "")")
        driver.screenshot("restored")
    }

    func testAddAndDeleteDisk() throws {
        try XCTSkipUnless(AppDriver.value("UI_ALLOW_WRITES") == "1", "Adds and deletes a real disk; set UI_ALLOW_WRITES=1")
        let service = try XCTUnwrap(AppDriver.value("UI_DISK_SERVICE"), "Set UI_DISK_SERVICE to a throwaway service with no disk")
        let name = "ui-disk-\(UUID().uuidString.prefix(6).lowercased())"
        let driver = AppDriver(self)
        driver.launch()
        try driver.signIn()
        driver.openTab("Services")
        driver.openRow(named: service)

        let add = driver.app.buttons["addDisk"].firstMatch
        for _ in 0..<6 where !add.exists { driver.app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: AppDriver.timeout), "\(service) offers no Add Disk; does it already have one?")
        add.tap()

        let confirmAdd = driver.app.buttons["addDiskConfirm"]
        XCTAssertTrue(confirmAdd.waitForExistence(timeout: AppDriver.timeout), "No Add Disk sheet")
        XCTAssertFalse(confirmAdd.isEnabled, "Add is enabled with an empty form")
        let nameField = driver.app.textFields["diskName"]
        nameField.tap()
        nameField.typeText(name)
        let mountField = driver.app.textFields["diskMountPath"]
        mountField.tap()
        mountField.typeText("/data")
        XCTAssertTrue(confirmAdd.isEnabled, "Add is still disabled with a valid form")
        driver.screenshot("add-disk")
        confirmAdd.tap()

        let added = driver.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Added \(name)")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 30), "Render didn't add the disk")
        let diskRow = driver.app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        for _ in 0..<6 where !diskRow.exists { driver.app.swipeUp() }
        XCTAssertTrue(diskRow.waitForExistence(timeout: AppDriver.timeout), "The new disk isn't shown")
        driver.screenshot("disk-added")
        diskRow.tap()
        XCTAssertTrue(driver.app.navigationBars["Disk"].waitForExistence(timeout: AppDriver.timeout))

        let delete = driver.app.buttons["deleteDisk"].firstMatch
        for _ in 0..<4 where !delete.isHittable { driver.app.swipeUp() }
        delete.tap()
        let confirmDelete = driver.app.buttons["deleteConfirmButton"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: AppDriver.timeout), "No confirmation sheet")
        XCTAssertFalse(confirmDelete.isEnabled, "Delete is enabled before the name is typed")
        let typed = driver.app.textFields["deleteConfirmName"]
        typed.tap()
        typed.typeText(name)
        XCTAssertTrue(confirmDelete.isEnabled, "Delete is still disabled after typing \(name)")
        driver.screenshot("delete-disk")
        confirmDelete.tap()

        let deleted = driver.app.staticTexts["Deleted \(name)."].firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 30), "Render didn't delete the disk")
        XCTAssertTrue(add.waitForExistence(timeout: AppDriver.timeout), "Add Disk isn't offered again")
        driver.screenshot("disk-deleted")
    }
}
