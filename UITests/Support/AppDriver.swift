import XCTest

/// Launches the app, signs in with the key from `.env`, and saves screenshots, for UI tests that
/// look at real screens without the Simulator window.
///
/// These tests run through `make ui-test` (Scripts/ui-test.sh), never `make test`: they reach
/// Render's live API with a real key, so they can't run in CI or offline. xcodebuild hands any
/// `TEST_RUNNER_<NAME>` variable to the test runner as `<NAME>`, which is how the key gets here
/// without ever being written into the project or the scheme.
@MainActor
struct AppDriver {
    let app = XCUIApplication()
    private let testCase: XCTestCase

    /// Network calls and the 700ms splash both sit between a tap and the next screen.
    static let timeout: TimeInterval = 20

    init(_ testCase: XCTestCase) {
        self.testCase = testCase
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Launches the app, at the Dynamic Type size named by `UI_TEXT_SIZE` (for example
    /// `AccessibilityM`, or `L` for the default) when it's set.
    func launch() {
        if let size = Self.environment["UI_TEXT_SIZE"], !size.isEmpty {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"]
        }
        app.launch()
    }

    /// Signs in with `RENDER_API_KEY` unless a session is already restored, then waits for the tab
    /// bar. Skips the test when there's no key, so running the target by hand doesn't fail.
    func signIn() throws {
        guard let key = Self.environment["RENDER_API_KEY"], !key.isEmpty else {
            throw XCTSkip("RENDER_API_KEY isn't set. Run these through `make ui-test`.")
        }
        let services = app.tabBars.buttons["Services"]
        let useKey = app.buttons["Use an API key instead"]
        // Whichever appears first: a restored session goes straight to the tabs.
        let deadline = Date().addingTimeInterval(Self.timeout)
        while Date() < deadline, !services.exists, !useKey.exists {
            _ = services.waitForExistence(timeout: 0.5)
        }
        if services.exists { return }

        XCTAssertTrue(useKey.exists, "Neither the tabs nor the sign-in screen appeared")
        // At large text sizes the screen scrolls, and a tap that lands while it's still settling is
        // spent on the scroll view, leaving the disclosure shut. So wait until it's hittable, and
        // tap again if the field doesn't open.
        let field = app.secureTextFields.firstMatch
        for _ in 0..<3 where !field.exists {
            let hittable = NSPredicate(format: "isHittable == true")
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: useKey)], timeout: 5)
            useKey.tap()
            _ = field.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(field.exists, "The API key field didn't open")
        field.tap()
        field.typeText(key)
        app.buttons["Continue"].tap()
        XCTAssertTrue(services.waitForExistence(timeout: Self.timeout), "Signing in didn't reach the tabs")
    }

    /// Opens a tab by its title.
    func openTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: Self.timeout), "No \(title) tab")
        tab.tap()
    }

    /// Taps the list row whose text includes `name`, or the first row when `name` is nil.
    func openRow(named name: String?) {
        let row = name.map { app.cells.containing(.staticText, identifier: $0).firstMatch } ?? app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout), "No row named \(name ?? "(first)")")
        row.tap()
    }

    /// Saves the screen as `<name>.png` in the result bundle. Scripts/ui-test.sh copies these out
    /// to build/ui-tests/screens.
    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    /// A value from the environment, set as `TEST_RUNNER_<name>` for xcodebuild.
    static func value(_ name: String) -> String? {
        environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }
}
