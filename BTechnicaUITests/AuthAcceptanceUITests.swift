import XCTest

/// End-to-end auth acceptance against the real Supabase project.
/// Credentials are loaded from gitignored `Credentials.local.env` in the test bundle.
final class AuthAcceptanceUITests: XCTestCase {
    private var app: XCUIApplication!
    private lazy var credentials: (email: String, password: String) = loadCredentials()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE"]
        app.launchEnvironment["UITEST_DISABLE_ANIMATIONS"] = "1"
    }

    func testInvalidPasswordThenLoginLogoutRelogin() throws {
        let email = credentials.email
        let password = credentials.password

        app.launch()
        ensureSignedOut()

        typeLogin(email: email, password: "not-the-real-password")
        XCTAssertTrue(signInButton.waitForExistence(timeout: 5))
        // Ensure the control is enabled before tapping (disabled taps are no-ops).
        XCTAssertTrue(signInButton.isEnabled, "Sign In should enable after email/password entry")
        signInButton.tap()
        let errorVisible =
            element(id: "loginErrorLabel").waitForExistence(timeout: 20)
            || app.staticTexts["Incorrect email or password."].waitForExistence(timeout: 5)
        XCTAssertTrue(errorVisible, "Expected visible error for invalid password")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Invalid password must not enter the app")
        assertLoginVisible()

        // Fresh launch avoids SecureField clear flakiness after the failed attempt.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE"]
        app.launch()
        ensureSignedOut()

        typeLogin(email: email, password: password)
        XCTAssertTrue(signInButton.isEnabled)
        signInButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25), "Expected tabs after valid login")
        XCTAssertTrue(element(id: "mainTabView").waitForExistence(timeout: 5))

        openMoreTab()
        let signOut = element(id: "signOutButton")
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "Expected Sign Out on More tab")
        signOut.tap()
        assertLoginVisible()

        typeLogin(email: email, password: password)
        signInButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25), "Expected tabs after re-login")
    }

    func testSessionPersistsAfterRelaunch() throws {
        let email = credentials.email
        let password = credentials.password

        app.launch()
        if app.tabBars.firstMatch.waitForExistence(timeout: 5) == false {
            assertLoginVisible()
            typeLogin(email: email, password: password)
            signInButton.tap()
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25))

        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE"]
        app.launch()

        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 25),
            "Expected Keychain session restore into main app"
        )
        XCTAssertFalse(loginScreen.exists)
    }

    /// First primary login should adopt pre-auth Documents (appdata, PDFs, issues, photos)
    /// into Users/<primary>/ while leaving the legacy originals in place.
    func testLegacyMigrationSurvivesRestartAndLogout() throws {
        let email = credentials.email
        let password = credentials.password

        app.launch()
        ensureSignedOut()

        typeLogin(email: email, password: password)
        signInButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25), "Expected tabs after migration login")

        // Adopted fixture content should appear in Drawings / Issues lists.
        assertMigratedLibraryVisible()

        // Survive cold restart.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25), "Session + adopted data after restart")
        assertMigratedLibraryVisible()

        // Logout must not wipe adopted or legacy files (host verifies disk); UI returns to login.
        openMoreTab()
        element(id: "signOutButton").tap()
        assertLoginVisible()
    }

    /// Switch to the second QA account and leave the app signed in so the host
    /// can verify Documents/Users/<id> isolation on disk.
    func testSwitchToSecondAccountForIsolationProbe() throws {
        let primary = credentials
        let second = loadSecondCredentials()

        app.launch()
        ensureSignedOut()

        // Establish primary session first (creates/uses primary user root).
        typeLogin(email: primary.email, password: primary.password)
        signInButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25))

        openMoreTab()
        element(id: "signOutButton").tap()
        assertLoginVisible()

        typeLogin(email: second.email, password: second.password)
        signInButton.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25), "Expected tabs for second account")
        openMoreTab()
        // Confirm More shows the second account email when available.
        XCTAssertTrue(
            app.staticTexts[second.email].waitForExistence(timeout: 8)
                || element(id: "signOutButton").exists,
            "Expected second-account More screen"
        )
    }

    /// Keychain sessions survive simulator reinstall; start each flow from signed-out.
    private func ensureSignedOut() {
        if app.tabBars.firstMatch.waitForExistence(timeout: 8) {
            openMoreTab()
            let signOut = element(id: "signOutButton")
            XCTAssertTrue(signOut.waitForExistence(timeout: 10), "Expected Sign Out on More tab")
            signOut.tap()
        }
        assertLoginVisible()
    }

    private func openMoreTab() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        // Prefer label, then identifier, then last tab button.
        let candidates: [XCUIElement] = [
            tabBar.buttons["More"],
            element(id: "moreTab"),
            tabBar.buttons.element(boundBy: max(0, tabBar.buttons.count - 1))
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            if candidate.isHittable {
                candidate.tap()
            } else {
                // Tab item hit targets can be reported as non-hittable; force a mid-point tap.
                candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            // Confirm More content appeared.
            if element(id: "signOutButton").waitForExistence(timeout: 3)
                || app.navigationBars["More"].waitForExistence(timeout: 2) {
                return
            }
        }
        XCTFail("Unable to open More tab")
    }

    private func clearAndTypeLogin(email: String, password: String) {
        let emailField = element(id: "loginEmailField")
        let passwordField = element(id: "loginPasswordField")
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))

        emailField.tap()
        clearField(emailField)
        emailField.typeText(email)

        passwordField.tap()
        clearField(passwordField)
        passwordField.typeText(password)
    }

    private func clearField(_ field: XCUIElement) {
        guard let value = field.value as? String, !value.isEmpty else { return }
        // Placeholders like "Email"/"Password" are not real values to clear.
        if value == "Email" || value == "Password" { return }
        // Secure fields report length as bullet characters; delete by count.
        let deleteCount = max(value.count, 64)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount))
    }

    // MARK: - Helpers

    private var loginScreen: XCUIElement { element(id: "loginScreen") }
    private var signInButton: XCUIElement { app.buttons["loginSignInButton"] }

    private func assertLoginVisible() {
        XCTAssertTrue(
            loginScreen.waitForExistence(timeout: 25)
                || app.staticTexts["Sign in to B Technica"].waitForExistence(timeout: 5)
                || signInButton.waitForExistence(timeout: 5),
            "Expected login screen"
        )
    }

    private func element(id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    private func assertMigratedLibraryVisible() {
        // Confirm workspace loaded via Home overview counts (fixture: 2 drawings).
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["2"].waitForExistence(timeout: 8),
            "Expected Home overview drawing count 2 from migrated appdata"
        )

        openRootTab(named: "Drawings", navTitle: "Drawings")
        let testDrawing = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label CONTAINS[c] %@", "Test Drawing", "Test Drawing"))
            .firstMatch
        XCTAssertTrue(testDrawing.waitForExistence(timeout: 10), "Expected migrated Test Drawing")
        XCTAssertTrue(labelContaining("Apartment floor plan").waitForExistence(timeout: 5))

        openRootTab(named: "Issues", navTitle: "Issues")
        XCTAssertTrue(labelContaining("Photo test issue").waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("Sample pin test").waitForExistence(timeout: 5))
    }

    private func openRootTab(named name: String, navTitle: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Expected \(name) tab")
        if tab.isHittable {
            tab.tap()
        } else {
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(
            app.navigationBars[navTitle].waitForExistence(timeout: 5),
            "Expected \(navTitle) navigation after selecting tab"
        )
    }

    private func typeLogin(email: String, password: String) {
        clearAndTypeLogin(email: email, password: password)
    }

    private func loadCredentials() -> (email: String, password: String) {
        let vals = loadCredentialFile()
        let email = vals["INITIAL_AUTH_EMAIL"] ?? ""
        let password = vals["INITIAL_AUTH_PASSWORD"] ?? ""
        precondition(!email.isEmpty && !password.isEmpty, "Credentials.local.env incomplete")
        return (email, password)
    }

    private func loadSecondCredentials() -> (email: String, password: String) {
        let vals = loadCredentialFile()
        let email = vals["SECOND_AUTH_EMAIL"] ?? ""
        let password = vals["SECOND_AUTH_PASSWORD"] ?? ""
        precondition(!email.isEmpty && !password.isEmpty, "SECOND_AUTH_* missing from Credentials.local.env")
        return (email, password)
    }

    private func loadCredentialFile() -> [String: String] {
        let url = Bundle(for: AuthAcceptanceUITests.self).url(
            forResource: "Credentials.local",
            withExtension: "env"
        )
        precondition(url != nil, "Missing Credentials.local.env in UITest bundle (gitignored local file)")
        let contents = (try? String(contentsOf: url!, encoding: .utf8)) ?? ""
        var vals: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            vals[parts[0]] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return vals
    }
}
