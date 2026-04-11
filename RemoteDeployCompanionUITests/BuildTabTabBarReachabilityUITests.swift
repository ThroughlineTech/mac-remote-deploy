import XCTest

/// TKT-047 regression: when the Build tab's log disclosure is collapsed (the
/// default state), the bottom tab bar must remain tappable so the user can
/// navigate away. Before this fix, a greedy invisible ScrollView inside a
/// collapsed `DisclosureGroup` swallowed touches and effectively froze the
/// app on the Build tab until it was force-quit.
final class BuildTabTabBarReachabilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// With the Build Log collapsed (default state), tapping another tab must
    /// actually navigate. On the TKT-046 regressed build, this would fail
    /// because the tab bar button never received the touch.
    func test_buildTab_collapsedLog_allowsTabBarNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--auto-pair",
            "--pair-url", "http://localhost:8080",
            "--pair-token", "e2etest1",
            "--pair-name", "fubar's Mac mini"
        ]
        app.launch()

        XCTAssertTrue(waitForConnectedUI(in: app), "App did not reach a connected state")

        // Navigate to the Build tab. Default state should have the log
        // collapsed.
        tapTab("Build", in: app)

        // Sanity-check that the Build tab actually loaded. The Build Log
        // header is always rendered post-TKT-047, so the toggle button is a
        // reliable signal.
        let logToggle = app.buttons["BuildLogToggle"]
        XCTAssertTrue(
            logToggle.waitForExistence(timeout: 5),
            "Build Log toggle header was not visible on the Build tab"
        )

        // The "Build & Deploy" primary action should also be reachable
        // (anchored to the top of the content area, not shoved to the middle
        // by a runaway Spacer — second regression symptom from TKT-047).
        let buildButton = app.buttons["Build & Deploy"].firstMatch
        XCTAssertTrue(
            buildButton.waitForExistence(timeout: 5),
            "Build & Deploy button not visible on the Build tab"
        )

        // Core regression assertion: tapping Projects from the Build tab
        // (with log collapsed) must navigate away.
        tapTab("Projects", in: app)

        let projectsTitle = app.navigationBars["Projects"]
        let projectsStaticText = app.staticTexts["Projects"]
        let landedOnProjects = projectsTitle.waitForExistence(timeout: 5)
            || projectsStaticText.waitForExistence(timeout: 5)
        XCTAssertTrue(
            landedOnProjects,
            "Tapping Projects from Build tab (collapsed log) did not navigate — tab bar was unreachable"
        )

        // Round-trip: go back to Build, confirm the toggle is still the
        // collapsed-state chevron, then try Installs.
        tapTab("Build", in: app)
        XCTAssertTrue(
            logToggle.waitForExistence(timeout: 5),
            "Build tab did not re-display the log toggle after returning from Projects"
        )

        tapTab("Installs", in: app)
        let installsTitle = app.navigationBars["Installs"]
        let installsStaticText = app.staticTexts["Installs"]
        let landedOnInstalls = installsTitle.waitForExistence(timeout: 5)
            || installsStaticText.waitForExistence(timeout: 5)
        XCTAssertTrue(
            landedOnInstalls,
            "Tapping Installs from Build tab (collapsed log) did not navigate"
        )
    }

    /// Expand the Build Log, then collapse it again, and confirm the tab bar
    /// remains reachable afterwards. Covers the round-trip path.
    func test_buildTab_expandThenCollapse_preservesTabBarReachability() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--auto-pair",
            "--pair-url", "http://localhost:8080",
            "--pair-token", "e2etest1",
            "--pair-name", "fubar's Mac mini"
        ]
        app.launch()

        XCTAssertTrue(waitForConnectedUI(in: app), "App did not reach a connected state")

        tapTab("Build", in: app)

        let logToggle = app.buttons["BuildLogToggle"]
        XCTAssertTrue(
            logToggle.waitForExistence(timeout: 5),
            "Build Log toggle header was not visible on the Build tab"
        )

        // Expand the log.
        logToggle.tap()
        // Collapse it again.
        logToggle.tap()

        // Tab bar must still respond.
        tapTab("Settings", in: app)
        let settingsTitle = app.navigationBars["Settings"]
        let settingsStaticText = app.staticTexts["Settings"]
        let landedOnSettings = settingsTitle.waitForExistence(timeout: 5)
            || settingsStaticText.waitForExistence(timeout: 5)
        XCTAssertTrue(
            landedOnSettings,
            "Tapping Settings from Build tab (after expand/collapse round trip) did not navigate"
        )
    }

    // MARK: - Helpers
    // Kept as inline copies of the ProjectDetailReactiveStatusUITests helpers
    // to avoid introducing a shared helper file just for two tests.

    private func waitForConnectedUI(in app: XCUIApplication) -> Bool {
        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 8) {
            return true
        }

        // iPad can render tabs in the top bar; Projects title is a good
        // fallback signal that the main connected UI is visible.
        return app.staticTexts["Projects"].waitForExistence(timeout: 10)
    }

    private func tapTab(_ name: String, in app: XCUIApplication) {
        let bottomTab = app.tabBars.buttons[name]
        if bottomTab.exists {
            bottomTab.tap()
            return
        }

        let buttons = app.buttons.matching(identifier: name)
        if buttons.count > 0 {
            buttons.firstMatch.tap()
        }
    }
}
