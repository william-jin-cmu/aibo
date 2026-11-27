import XCTest

/// End-to-end journey against the deployed backend with demo connector data:
/// email sign-in (test account) → in-chat onboarding → insights → home + today card → chat (memory + list) →
/// Today sheet → You sheet → her room. Screenshots go to $AIBO_SHOTS (default /tmp/aibo-shots).
final class JourneyTests: XCTestCase {
    private var app: XCUIApplication!
    private var shot = 0
    private var shotsDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIBO_SHOTS"] ?? "/tmp/aibo-shots")
    }

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-AiboDemoData", "-AiboReset"]
        app.launch()
    }

    private func snap(_ name: String, settle: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: settle)
        shot += 1
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: shotsDir.appendingPathComponent(String(format: "%02d-%@.png", shot, name)))
    }

    private func waitFor(_ el: XCUIElement, _ timeout: TimeInterval = 30, _ what: String) {
        if !el.waitForExistence(timeout: timeout) {
            snap("FAILED-\(what.replacingOccurrences(of: " ", with: "-"))", settle: 0)
            XCTFail("Timed out waiting for \(what)")
        }
    }

    private var composer: XCUIElement {
        app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
    }

    private var replies: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "assistantMessage")
    }

    private func waitForReplies(atLeast n: Int, _ what: String) {
        let p = NSPredicate { _, _ in self.replies.count >= n }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: 90), .completed, what)
    }

    func testFullJourney() {
        // 0. Sign in with the review account (code is fixed server-side).
        let env = ProcessInfo.processInfo.environment
        guard let email = env["AIBO_TEST_EMAIL"], let code = env["AIBO_TEST_CODE"] else {
            return XCTFail("Set TEST_RUNNER_AIBO_TEST_EMAIL and TEST_RUNNER_AIBO_TEST_CODE")
        }
        let withEmail = app.buttons["Continue with email"]
        waitFor(withEmail, 20, "sign-in screen")
        snap("signin", settle: 1)
        withEmail.tap()
        let emailField = app.textFields["emailField"]
        waitFor(emailField, 5, "email field")
        emailField.typeText(email)
        snap("signin-email", settle: 0.5)
        app.buttons["Send me a code"].tap()
        let codeField = app.textFields["codeField"]
        waitFor(codeField, 20, "code field")
        snap("signin-code", settle: 0.5)
        codeField.tap()
        codeField.typeText(code)

        // 1. She introduces herself and asks your name.
        waitFor(app.textFields["composer"], 40, "name composer")
        snap("onboarding-hello", settle: 1)
        composer.typeText("William")
        app.buttons["sendButton"].tap()

        // 2. Connect sources inline.
        waitFor(app.buttons["Connect"].firstMatch, 15, "connector cards")
        snap("onboarding-connect", settle: 1)
        while app.buttons["Connect"].firstMatch.exists {
            app.buttons["Connect"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 2.5)
        }
        let cont = app.buttons["Continue"]
        XCTAssertTrue(cont.waitForEnabled(10), "Continue stays disabled")
        snap("onboarding-connected", settle: 0.5)
        cont.tap()

        // 3. What she noticed.
        let keep = app.buttons["Keep these"]
        waitFor(keep, 60, "insights")
        snap("onboarding-insights", settle: 1)
        keep.tap()

        // 4. Morning greeting → not now.
        let notNow = app.buttons["Not now"]
        waitFor(notNow, 20, "morning question")
        snap("onboarding-morning", settle: 0.5)
        notNow.tap()

        // 5. Home with today card + recommended.
        let suggestion = app.buttons["suggestion"].firstMatch
        waitFor(suggestion, 60, "recommended cards")
        snap("home-today", settle: 2)

        // 6. Chat.
        suggestion.tap()
        waitForReplies(atLeast: 1, "reply to suggestion")
        snap("home-reply-1", settle: 1.5)

        composer.tap()
        composer.typeText("我不吃香菜。最近想看几部轻松的日剧，帮我列个清单吧")
        app.buttons["sendButton"].tap()
        waitForReplies(atLeast: 2, "reply with memory + list")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()  // dismiss keyboard
        snap("home-reply-2", settle: 2)

        // 7. Today sheet.
        app.buttons["Today"].firstMatch.tap()
        snap("today-sheet", settle: 3)
        app.swipeUp()
        snap("today-sheet-scrolled", settle: 1.5)
        app.buttons["Done"].tap()

        // 8. You sheet.
        app.buttons["You"].firstMatch.tap()
        snap("you-sheet", settle: 2)
        app.swipeUp()
        snap("you-sheet-scrolled", settle: 1.5)
        app.buttons["Done"].tap()

        // 9. About her.
        app.buttons["header"].tap()
        snap("about-her", settle: 2)
    }
}

private extension XCUIElement {
    func waitForEnabled(_ timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "isEnabled == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: self)], timeout: timeout) == .completed
    }
}
