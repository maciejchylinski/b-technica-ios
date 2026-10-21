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
        XCTAssertTrue(signInButton.isEnabled, "Sign In should enable after email/password entry")
        signInButton.tap()
        let errorVisible =
            element(id: "loginErrorLabel").waitForExistence(timeout: 20)
            || app.staticTexts["Incorrect email or password."].waitForExistence(timeout: 5)
        XCTAssertTrue(errorVisible, "Expected visible error for invalid password")
        XCTAssertFalse(isSignedInShellVisible(timeout: 2), "Invalid password must not enter the app")
        assertLoginVisible()

        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE"]
        app.launch()
        ensureSignedOut()

        typeLogin(email: email, password: password)
        XCTAssertTrue(signInButton.isEnabled)
        signInButton.tap()
        assertSignedInShellVisible()

        signOutFromSignedInShell()
        assertLoginVisible()

        typeLogin(email: email, password: password)
        signInButton.tap()
        assertSignedInShellVisible()
    }

    func testSessionPersistsAfterRelaunch() throws {
        let email = credentials.email
        let password = credentials.password

        app.launch()
        if isSignedInShellVisible(timeout: 5) == false {
            assertLoginVisible()
            typeLogin(email: email, password: password)
            signInButton.tap()
        }
        assertSignedInShellVisible()

        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE"]
        app.launch()

        assertSignedInShellVisible(message: "Expected Keychain session restore into app")
        XCTAssertFalse(loginScreen.exists)
    }

    /// Confirms auth + project shell survive restart/logout.
    /// Legacy Documents data is intentionally not auto-assigned to cloud projects.
    func testLegacyMigrationSurvivesRestartAndLogout() throws {
        let email = credentials.email
        let password = credentials.password

        app.launch()
        ensureSignedOut()

        typeLogin(email: email, password: password)
        signInButton.tap()
        assertSignedInShellVisible(message: "Expected signed-in shell after login")

        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["UI_TEST_MODE"]
        app.launch()
        assertSignedInShellVisible(message: "Session after restart")

        signOutFromSignedInShell()
        assertLoginVisible()
    }

    /// Switch to the second QA account and leave the app signed in so the host
    /// can verify Documents/Users/<id> isolation on disk.
    func testSwitchToSecondAccountForIsolationProbe() throws {
        let primary = credentials
        let second = loadSecondCredentials()

        app.launch()
        ensureSignedOut()

        typeLogin(email: primary.email, password: primary.password)
        signInButton.tap()
        assertSignedInShellVisible()

        signOutFromSignedInShell()
        assertLoginVisible()

        typeLogin(email: second.email, password: second.password)
        signInButton.tap()
        assertSignedInShellVisible(message: "Expected signed-in shell for second account")
        XCTAssertTrue(
            app.staticTexts[second.email].waitForExistence(timeout: 8)
                || element(id: "signOutButton").exists,
            "Expected second-account signed-in UI"
        )
    }

    /// Keychain sessions survive simulator reinstall; start each flow from signed-out.
    private func ensureSignedOut() {
        if isSignedInShellVisible(timeout: 8) {
            signOutFromSignedInShell()
        }
        assertLoginVisible()
    }

    private func signOutFromSignedInShell() {
        if app.tabBars.firstMatch.exists {
            openMoreTab()
        }
        let signOut = element(id: "signOutButton")
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "Expected Sign Out")
        signOut.tap()
    }

    private func openMoreTab() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        let candidates: [XCUIElement] = [
            tabBar.buttons["More"],
            element(id: "moreTab"),
            tabBar.buttons.element(boundBy: max(0, tabBar.buttons.count - 1))
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            if candidate.isHittable {
                candidate.tap()
            } else {
                candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
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
        if value == "Email" || value == "Password" { return }
        let deleteCount = max(value.count, 64)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount))
    }

    // MARK: - Helpers

    private var loginScreen: XCUIElement { element(id: "loginScreen") }
    private var projectsScreen: XCUIElement { element(id: "projectsScreen") }
    private var signInButton: XCUIElement { app.buttons["loginSignInButton"] }

    private func isSignedInShellVisible(timeout: TimeInterval) -> Bool {
        projectsScreen.waitForExistence(timeout: timeout)
            || app.navigationBars["Projects"].waitForExistence(timeout: 1)
            || app.tabBars.firstMatch.waitForExistence(timeout: 1)
            || element(id: "mainTabView").waitForExistence(timeout: 1)
    }

    private func assertSignedInShellVisible(message: String = "Expected projects list or project workspace") {
        XCTAssertTrue(isSignedInShellVisible(timeout: 25), message)
    }

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
