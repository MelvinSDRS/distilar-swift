import XCTest

/// Drives the Example app against a live server, named by the test
/// runner's environment. Through xcodebuild:
///
///     TEST_RUNNER_DISTILAR_URL=http://127.0.0.1:8080 \
///     TEST_RUNNER_DISTILAR_KEY=dpk_… \
///     TEST_RUNNER_DISTILAR_MARKER=some-unique-text \
///     xcodebuild test -project Example/DistilarExample.xcodeproj -scheme DistilarExample …
///
/// Each report's text ends with the marker, so the server's database can
/// show that it stored each one once.
@MainActor
final class DistilarExampleUITests: XCTestCase {
    func testABugReportGoesOut() throws {
        let (app, marker) = try launch()

        send("Online report \(marker)", in: app)

        XCTAssertTrue(app.staticTexts["Your feedback was sent."].waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        XCTAssertEqual(app.staticTexts["last-result"].label, "Taken")
    }

    func testAScreenshotGoesWithTheReport() throws {
        let (app, marker) = try launch()
        app.buttons["Report a Bug"].tap()
        type("Report with a screenshot \(marker)", in: app)

        app.buttons["Attach a Screenshot"].tap()
        // The picker runs in another process; its photos show up as images
        // labeled with their date, under a banner that has an image too.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        photo.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 20))
        let attached = XCTAttachment(screenshot: app.screenshot())
        attached.lifetime = .keepAlways
        add(attached)

        app.buttons["distilar.send"].tap()
        XCTAssertTrue(app.staticTexts["Your feedback was sent."].waitForExistence(timeout: 30))
    }

    func testABugReportWaitsForAConnection() throws {
        let (app, marker) = try launch()
        let offline = app.switches["Simulate No Connection"].switches.firstMatch
        offline.tap()

        send("Offline report \(marker)", in: app)

        XCTAssertTrue(app.staticTexts["Your feedback is saved and will be sent automatically."].waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        // Back online: configuring the SDK again sends what waits. The
        // database check after this test shows it arrived, once.
        offline.tap()
        sleep(5)
    }

    private func launch() throws -> (XCUIApplication, String) {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["DISTILAR_URL"], let key = environment["DISTILAR_KEY"] else {
            throw XCTSkip("needs DISTILAR_URL and DISTILAR_KEY")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-server", server, "-key", key]
        app.launch()
        return (app, environment["DISTILAR_MARKER"] ?? UUID().uuidString)
    }

    private func send(_ text: String, in app: XCUIApplication) {
        app.buttons["Report a Bug"].tap()
        type(text, in: app)
        app.buttons["distilar.send"].tap()
    }

    private func type(_ text: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any)["distilar.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }
}
