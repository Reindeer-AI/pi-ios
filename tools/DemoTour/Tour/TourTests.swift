import XCTest

/// Demo tours of pi, run on a phone or Simulator while its screen is recorded: XCUITest taps through the installed app
/// (by bundle ID), with pauses so a viewer can follow. Run one with
/// `xcodebuild test -project tools/DemoTour/DemoTour.xcodeproj -scheme DemoTour -destination … -only-testing:DemoTourUITests/TourTests/testSettingsAndSecrets`.
final class TourTests: XCTestCase {
    /// pi by its bundle ID: PI_BUNDLE_ID for another build (an App Store one from TestFlight), else the development one.
    private let pi = XCUIApplication(bundleIdentifier: ProcessInfo.processInfo.environment["PI_BUNDLE_ID"] ?? "dev.pimobile.PiMobile")

    override func setUp() {
        continueAfterFailure = false
    }

    /// Settings (model, network server, Crabbox, GitHub), Extensions and skills, a new secret for every extension, then a
    /// session whose agent writes a weather extension that shows a widget and uses the secret without seeing it.
    func testSettingsAndSecrets() throws {
        pi.launch()
        pause(2)

        tap(pi.buttons["Settings"])
        pause(2.5)
        // Down through the accounts, browsers, Crabbox, GitHub, models, and the network server.
        for _ in 0..<4 {
            pi.swipeUp(velocity: .slow)
            pause(1.6)
        }
        // Back up only until the row shows: a swipe down at the top would close the Settings sheet.
        let extensions = pi.buttons["Extensions and skills"].firstMatch
        let bar = pi.navigationBars.firstMatch
        // Visible below the title bar (a row under the translucent bar still counts as hittable).
        let clear = { extensions.exists && extensions.isHittable && extensions.frame.minY > bar.frame.maxY + 8 }
        for _ in 0..<8 where !clear() {
            pi.swipeDown(velocity: .slow)
            pause(0.6)
        }
        pause(1)

        tap(extensions, orText: "Extensions and skills")
        pause(2.5)

        // Down to the Secrets section.
        let addSecret = pi.buttons["Add secret…"]
        for _ in 0..<6 where !(addSecret.exists && addSecret.isHittable) {
            pi.swipeUp(velocity: .slow)
            pause(1)
        }
        pause(1.5)
        tap(addSecret)
        pause(1)
        let name = pi.textFields["NAME, such as TAVILY_API_KEY"]
        tap(name)
        name.typeText("WEATHER_API_KEY")
        pause(0.8)
        let value = pi.secureTextFields["Value"]
        tap(value)
        value.typeText("demo-key-not-real-123")
        pause(1.5)
        tap(pi.buttons["Save"])
        pause(2)
        dismissSavePassword()
        pause(1)

        // Back to Settings with the edge swipe (iOS 26's back button is not in the navigation bar's buttons).
        pi.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pi.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        pause(1.5)
        tap(pi.buttons["Done"])
        pause(1.5)

        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("Write a pi extension with a tool show_weather(city) that gets the current weather from Open-Meteo (no key needed) and shows it as a widget above the message box with ctx.ui.setWidget, with a line saying whether WEATHER_API_KEY is set and its length (never the key). Add it to this session and show the weather in Tel Aviv.")
        pause(1)
        tap(pi.buttons["Send"].firstMatch)
        pause(0.5)
        // The keyboard down, so the answer has the screen.
        let hide = pi.buttons["Hide keyboard"].firstMatch
        if hide.waitForExistence(timeout: 2) { hide.tap() }

        // Until the agent answers (Stop goes away), then a moment on the answer.
        let stop = pi.buttons["Stop"].firstMatch
        _ = stop.waitForExistence(timeout: 15)
        let deadline = Date().addingTimeInterval(240)
        while stop.exists && Date() < deadline { pause(1) }
        pause(4)
        pi.swipeUp(velocity: .slow)
        pause(3)
    }

    /// Readies a phone for the demos by deleting every session (Clean Up → All sessions). The network server and the
    /// default model are set by launch arguments instead (-setNetworkEndpoint, -setDefaultModel): typing into a filled
    /// text field is unreliable in UI tests.
    func testCleanUpSessions() throws {
        launchReady()
        let cleanUp = pi.buttons["Clean Up"]
        _ = cleanUp.waitForExistence(timeout: 10)
        // Enabled once the sessions have loaded (disabled while the list is empty).
        let loaded = Date().addingTimeInterval(15)
        while cleanUp.exists, !cleanUp.isEnabled, Date() < loaded { pause(0.5) }
        guard cleanUp.exists, cleanUp.isEnabled else { return }
        cleanUp.tap()
        pause(1)
        let all = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All sessions'")).firstMatch
        guard all.waitForExistence(timeout: 3), all.isEnabled else { return }
        all.tap()
        pause(1)
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch)
        pause(3)
        XCTAssertFalse(pi.buttons["Clean Up"].isEnabled, "sessions remain")
    }

    /// A new session sent PI_PROMPT; waits (up to PI_WAIT_MINUTES, default 40) until the agent is done, for long demos
    /// such as a pull request built on a Crabbox machine. Optional: PI_LAUNCH_ARGS (pi's launch arguments, separated by
    /// "|"), PI_STEER sent PI_STEER_AFTER seconds into the run (default 10), and PI_RESTART_AFTER seconds into the run,
    /// pi force-quit and opened again on the session, to show the run carrying on.
    func testPrompt() throws {
        let environment = ProcessInfo.processInfo.environment
        let prompt = try XCTUnwrap(environment["PI_PROMPT"], "PI_PROMPT")
        let minutes = Double(environment["PI_WAIT_MINUTES"] ?? "") ?? 40
        executionTimeAllowance = minutes * 60 + 120
        if let arguments = environment["PI_LAUNCH_ARGS"], !arguments.isEmpty {
            pi.launchArguments = arguments.components(separatedBy: "|")
        }
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText(prompt)
        pause(1)
        tap(pi.buttons["Send"].firstMatch)
        pause(0.5)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        if hide.waitForExistence(timeout: 2) { hide.tap() }

        let stop = pi.buttons["Stop"].firstMatch
        _ = stop.waitForExistence(timeout: 20)
        let started = Date()
        let deadline = started.addingTimeInterval(minutes * 60)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var steer = environment["PI_STEER"].flatMap { $0.isEmpty ? nil : $0 }
        let steerAfter = Double(environment["PI_STEER_AFTER"] ?? "") ?? 10
        var restartAfter = Double(environment["PI_RESTART_AFTER"] ?? "")
        while Date() < deadline {
            let elapsed = Date().timeIntervalSince(started)
            if let text = steer, elapsed >= steerAfter, stop.exists {
                steer = nil
                let field = pi.textFields["Steer pi"]
                tap(field)
                field.typeText(text)
                pause(1)
                tap(pi.buttons["Steer"].firstMatch)
                pause(0.5)
                if hide.waitForExistence(timeout: 2) { hide.tap() }
                continue
            }
            if let after = restartAfter, elapsed >= after {
                restartAfter = nil
                pi.terminate()
                pause(3)
                launchReady()
                let row = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(prompt.prefix(24)))).firstMatch
                tap(row)
                pause(2)
                _ = stop.waitForExistence(timeout: 30)
                continue
            }
            // A system dialog over pi hides the app: handle it (an MDM's "App Update" stops the run) and keep watching.
            if springboard.alerts.count > 0 {
                declineSystemDialog()
                pause(1)
                continue
            }
            if !stop.exists { break }
            pause(2)
        }
        pause(5)
    }

    /// The UI-integration tour: a new session asked (PI_PROMPT) to write an extension with a command, then the command
    /// (PI_COMMAND) run, its dialogs answered: an option or "Yes" from PI_ANSWERS ("|"-separated), text fields typed with
    /// PI_TEXT, editors accepted as they are.
    func testCommandTour() throws {
        let environment = ProcessInfo.processInfo.environment
        let prompt = try XCTUnwrap(environment["PI_PROMPT"], "PI_PROMPT")
        let command = try XCTUnwrap(environment["PI_COMMAND"], "PI_COMMAND")
        let answers = (environment["PI_ANSWERS"] ?? "Yes").components(separatedBy: "|")
        let text = environment["PI_TEXT"] ?? "Demo"
        executionTimeAllowance = 40 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        func send(_ message: String, hideKeyboard: Bool = true) {
            let field = pi.textFields["Message pi"]
            tap(field)
            field.typeText(message)
            pause(1)
            tap(pi.buttons["Send"].firstMatch)
            pause(0.5)
            // Not after a command: its dialog may already cover where the button was.
            if hideKeyboard, hide.waitForExistence(timeout: 2) { hide.tap() }
        }
        send(prompt)
        _ = stop.waitForExistence(timeout: 20)
        let built = Date().addingTimeInterval(20 * 60)
        while stop.exists && Date() < built { pause(2) }
        pause(4)

        send(command, hideKeyboard: false)
        // Answers dialogs until none has come for 15 seconds.
        var quiet = Date()
        let tourEnd = Date().addingTimeInterval(5 * 60)
        while Date().timeIntervalSince(quiet) < 15 && Date() < tourEnd {
            let cancel = pi.buttons["Cancel"].firstMatch
            guard cancel.exists else { pause(0.5); continue }
            pause(2)
            if let option = answers.first(where: { pi.buttons[$0].firstMatch.exists }) {
                // The sheet may still be moving to its height: tap once the row has settled.
                let button = pi.buttons[option].firstMatch
                var frame = button.frame
                for _ in 0..<10 {
                    pause(0.4)
                    if button.isHittable && button.frame == frame { break }
                    frame = button.frame
                }
                tap(button)
            } else if pi.textViews.count > 0 {
                tap(pi.buttons["Done"].firstMatch)
            } else if pi.textFields.count > 1, let field = pi.sheets.textFields.allElementsBoundByIndex.first ?? pi.textFields.allElementsBoundByIndex.last {
                tap(field)
                field.typeText(text)
                pause(1)
                tap(pi.buttons["Done"].firstMatch)
            } else {
                tap(cancel)
            }
            pause(1)
            quiet = Date()
        }
        pause(3)
    }

    /// The flights demo: /flights opens the extension's preferences sheet, filled in (Tel Aviv, PI_CABIN (default
    /// Economy), direct, euros, and the traveller from PI_FIRST_NAME, PI_LAST_NAME, PI_GENDER); the agent is asked for a trip, the browser is watched while it searches; then it is asked to book, and the
    /// browser is watched again up to checkout. PI_BOOK (default "Book the first option.") is the booking request.
    func testFlights() throws {
        let environment = ProcessInfo.processInfo.environment
        let trip = environment["PI_PROMPT"] ?? "I wish to meet the Earendil team in Vienna next week"
        let book = environment["PI_BOOK"] ?? "Book the first option."
        executionTimeAllowance = 50 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        func send(_ message: String) {
            let field = pi.textFields["Message pi"]
            tap(field)
            field.typeText(message)
            pause(1)
            tap(pi.buttons["Send"].firstMatch)
            pause(0.5)
            if hide.waitForExistence(timeout: 2) { hide.tap() }
        }

        // Preferences.
        send("/flights")
        let from = pi.textFields["From airport"]
        XCTAssertTrue(from.waitForExistence(timeout: 20), "the preferences sheet")
        pause(2)
        tap(from)
        from.typeText("tel av")
        pause(1.5)
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tel Aviv, Israel")).firstMatch)
        pause(1.5)
        tap(pi.buttons[environment["PI_CABIN"] ?? "Economy"].firstMatch)
        pause(1)
        let direct = pi.switches["Direct flights only"].firstMatch
        if direct.exists, (direct.value as? String) != "1" { tap(direct) }
        pause(1)
        tap(pi.buttons["€ EUR"].firstMatch)
        pause(1)
        // The traveller (loyalty programs are left empty).
        if let first = environment["PI_FIRST_NAME"], let last = environment["PI_LAST_NAME"] {
            for (label, text) in [("First name", first), ("Last name", last)] {
                let field = pi.textFields[label].firstMatch
                tap(field)
                field.typeText(text)
                pause(0.8)
            }
            tap(pi.buttons[environment["PI_GENDER"] ?? "Male"].firstMatch)
            pause(1.5)
        }
        tap(pi.buttons["Save preferences"].firstMatch)
        pause(3)
        if environment["PI_PANEL_ONLY"] != nil { return }

        // The trip: watch the browser while the agent searches, then read its recommendations.
        send(trip)
        watchBrowser(minutes: 8, idle: 25)
        waitWhile(stop, minutes: 10)
        pause(4)
        pi.swipeDown(velocity: .slow)
        pause(3)
        pi.swipeUp(velocity: .slow)
        pause(3)

        // Booking, up to checkout.
        send(book)
        watchBrowser(minutes: 15, idle: 40)
        waitWhile(stop, minutes: 15)
        pause(8)
    }

    /// Opens the session's browser once the agent uses it, and watches until the page has not changed for `idle`
    /// seconds (the agent done with it, or thinking), then goes back to the chat.
    private func watchBrowser(minutes: Double, idle: TimeInterval) {
        let card = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Browser:")).firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        let appear = Date().addingTimeInterval(180)
        while !card.exists && stop.exists && Date() < appear { declineSystemDialog(); pause(1) }
        guard card.exists else { return }
        pause(2)
        tap(card)
        pause(2)
        let end = Date().addingTimeInterval(minutes * 60)
        var last = Data()
        var changed = Date()
        while Date() < end {
            declineSystemDialog()
            let frame = pi.screenshot().pngRepresentation
            if frame != last { last = frame; changed = Date() }
            if Date().timeIntervalSince(changed) > idle { break }
            pause(3)
        }
        tap(pi.buttons["Done"].firstMatch)
        pause(2)
    }

    private func waitWhile(_ element: XCUIElement, minutes: Double) {
        let end = Date().addingTimeInterval(minutes * 60)
        while element.exists && Date() < end { declineSystemDialog(); pause(2) }
    }

    /// A system dialog over pi. An MDM's app update or install prompt is accepted, and the run stops there (the update
    /// ends pi): declining it leaves the MDM showing the install as "Installing" for good, with no later version sent to
    /// that device either. Anything else is declined.
    private func declineSystemDialog() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return }
        if let accept = ["Update", "Install"].map({ alert.buttons[$0] }).first(where: \.exists) {
            accept.tap()
            XCTFail("an MDM is installing pi (its prompt was accepted): run again once it is installed")
            return
        }
        for label in ["Cancel", "Not Now", "Close"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    /// MCP servers: adds PI_MCP_NAME at PI_MCP_URL (default: tools/mcp-mock's server) in Settings → MCP servers, signs in
    /// where it asks (its authorization page in a Safari sheet), waits until it is connected; then a new session asks
    /// for one of its tools (PI_PROMPT) and the answer must contain PI_EXPECT. PI_BACKGROUND_SECONDS: before a second
    /// prompt, pi goes to the background that long and comes back, to check the connection is picked up again;
    /// PI_MCP_EXPIRE_URL is POSTed meanwhile (the mock's /admin/expire), so the server has also forgotten the session.
    func testMCPServer() throws {
        let environment = ProcessInfo.processInfo.environment
        let name = environment["PI_MCP_NAME"] ?? "mock"
        let url = environment["PI_MCP_URL"] ?? "http://127.0.0.1:8765/mcp"
        let prompt = environment["PI_PROMPT"] ?? "Call the \(name) MCP server's get_secret_number tool and tell me the number."
        let expect = environment["PI_EXPECT"] ?? "4217"
        executionTimeAllowance = 15 * 60
        launchReady()

        tap(pi.buttons["Settings"])
        pause(2)
        let row = pi.buttons["MCP servers"].firstMatch
        let bar = pi.navigationBars.firstMatch
        for _ in 0..<10 where !(row.exists && row.isHittable && row.frame.minY > bar.frame.maxY + 8) {
            pi.swipeUp(velocity: .slow)
            pause(0.8)
        }
        tap(row)
        pause(2)
        let server = pi.buttons.matching(identifier: "mcp-server-\(name)").firstMatch
        // PI_MCP_FRESH: remove the server first (and its sign-in), to start over.
        if environment["PI_MCP_FRESH"] != nil, server.waitForExistence(timeout: 3) {
            tap(server)
            pause(1.5)
            let remove = pi.buttons["Remove server"]
            for _ in 0..<6 where !(remove.exists && remove.isHittable) { pi.swipeUp(velocity: .slow); pause(0.6) }
            tap(remove)
            pause(2)
        }
        if !server.waitForExistence(timeout: 3) {
            tap(pi.buttons["Add server"])
            pause(1)
            let nameField = pi.textFields["Name, such as linear"]
            tap(nameField)
            nameField.typeText(name)
            let urlField = pi.textFields["https://mcp.example.com/mcp"]
            tap(urlField)
            urlField.typeText(url)
            pause(1)
            // An OAuth app registered with the server (PI_MCP_CLIENT_ID, _CLIENT_SECRET, _SCOPE, _REDIRECT).
            if let clientId = environment["PI_MCP_CLIENT_ID"] {
                let fields: [(XCUIElement, String?)] = [
                    (pi.textFields["Client ID"], clientId),
                    (pi.secureTextFields["Client secret"], environment["PI_MCP_CLIENT_SECRET"]),
                    (pi.textFields["Scopes, separated by spaces"], environment["PI_MCP_SCOPE"]),
                    (pi.textFields["Redirect URL (optional)"], environment["PI_MCP_REDIRECT"]),
                ]
                for (field, value) in fields {
                    guard let value else { continue }
                    for _ in 0..<4 where !(field.exists && field.isHittable) {
                        pi.swipeUp(velocity: .slow)
                        pause(0.5)
                    }
                    tap(field)
                    field.typeText(value)
                    pause(0.6)
                }
            }
            tap(pi.buttons["Save"])
            pause(3)
        }
        tap(server)
        pause(2)
        let connected = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Connected")).firstMatch
        let signIn = pi.buttons["Sign in"]
        let decided = Date().addingTimeInterval(30)
        while !connected.exists && !signIn.exists && Date() < decided { pause(0.5) }
        if !connected.exists && signIn.exists {
            tap(signIn)
        }
        XCTAssertTrue(connected.waitForExistence(timeout: 90), "\(name) connected")
        pause(3)

        // A session uses it.
        pi.terminate()
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        func ask(_ message: String) {
            let field = pi.textFields["Message pi"]
            tap(field)
            field.typeText(message)
            pause(1)
            tap(pi.buttons["Send"].firstMatch)
            pause(0.5)
            if hide.waitForExistence(timeout: 2) { hide.tap() }
            _ = stop.waitForExistence(timeout: 20)
            let end = Date().addingTimeInterval(5 * 60)
            while stop.exists && Date() < end { pause(1) }
            pause(2)
        }
        let answer = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expect))
        ask(prompt)
        XCTAssertGreaterThan(answer.count, 0, "the answer has \(expect)")

        if let seconds = Double(environment["PI_BACKGROUND_SECONDS"] ?? "") {
            let before = answer.count
            XCUIDevice.shared.press(.home)
            if let expire = environment["PI_MCP_EXPIRE_URL"].flatMap(URL.init(string:)) {
                var request = URLRequest(url: expire)
                request.httpMethod = "POST"
                let done = expectation(description: "expired")
                URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
                wait(for: [done], timeout: 10)
            }
            pause(seconds)
            pi.activate()
            pause(3)
            ask(environment["PI_PROMPT_AGAIN"] ?? "Call it once more and tell me the number again.")
            XCTAssertGreaterThan(answer.count, before, "the second answer has \(expect)")
        }
        pause(3)
    }

    /// Session apps, with the Flights app (extensions/flights.ts, installed): /flights opens it; Minimize puts it in the
    /// session's dock with its page still running (what was typed is there when it opens again), and so does swiping the
    /// sheet away; after a relaunch the dock still has it, and it opens with the edit it kept (pi.state); the agent opens
    /// it (app_open); holding its dock entry closes it.
    func testApps() throws {
        executionTimeAllowance = 15 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        func send(_ message: String) {
            let field = pi.textFields["Message pi"]
            tap(field)
            field.typeText(message)
            pause(1)
            tap(pi.buttons["Send"].firstMatch)
            pause(0.5)
        }
        func waitForRun() {
            _ = stop.waitForExistence(timeout: 20)
            let end = Date().addingTimeInterval(4 * 60)
            while stop.exists && Date() < end { pause(1) }
            pause(1)
        }
        let minimize = pi.buttons["Minimize"].firstMatch
        let dock = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Flights. Open app")).firstMatch
        let first = pi.textFields["First name"].firstMatch
        let name = "Ada\(Int.random(in: 100...999))"

        send("Apps test: reply with the word ok, nothing else.")
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        waitForRun()
        send("/flights")
        XCTAssertTrue(minimize.waitForExistence(timeout: 20), "/flights opened the app")
        pause(2)
        // At the end of what the field has, then over it.
        tap(first)
        pause(1)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        pause(0.5)
        let current = first.value as? String ?? ""
        first.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + name)
        pause(1)
        tap(minimize)
        XCTAssertTrue(dock.waitForExistence(timeout: 5), "minimized to the dock")
        XCTAssertFalse(minimize.exists, "off screen")

        // Again: the same page, with what was typed.
        tap(dock)
        XCTAssertTrue(minimize.waitForExistence(timeout: 5), "opened from the dock")
        pause(1.5)
        XCTAssertEqual(first.value as? String, name, "the page kept running")
        // Swiping the sheet away (from full height, to half, then away) minimizes it too.
        for _ in 0..<2 where minimize.exists {
            // The sheet's own header, beside its Minimize button.
            let header = minimize.coordinate(withNormalizedOffset: CGVector(dx: 4, dy: 0.5))
            header.press(forDuration: 0.1, thenDragTo: header.withOffset(CGVector(dx: 0, dy: 700)))
            pause(1.5)
        }
        XCTAssertFalse(minimize.exists, "swiped away")
        XCTAssertTrue(dock.exists, "in the dock")

        // Back to the sessions with the app open: it waits in the dock, and is on screen again with its session.
        tap(dock)
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        pause(1)
        tap(pi.buttons["Sessions"].firstMatch)
        XCTAssertTrue(pi.buttons["New session"].firstMatch.waitForExistence(timeout: 5), "the sessions list")
        XCTAssertFalse(minimize.exists, "off screen")
        pause(1)
        let row = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apps test")).firstMatch
        print("session row: \(row.label)")
        XCTAssertTrue(row.label.contains("Flights"), "its row shows the app")
        tap(row)
        XCTAssertTrue(minimize.waitForExistence(timeout: 10), "on screen again with its session")

        // A relaunch with the app on screen: the session opens it again, with the edit it kept.
        pause(1.5)
        pi.terminate()
        pause(2)
        launchReady()
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apps test")).firstMatch)
        XCTAssertTrue(minimize.waitForExistence(timeout: 20), "on screen again after a relaunch")
        pause(2)
        XCTAssertEqual(first.value as? String, name, "the edit it kept")
        XCTAssertTrue(dock.exists, "in the dock")
        tap(minimize)
        pause(1)

        // The agent opens it.
        send("Open the Flights app for me with app_open, then say done. Nothing else.")
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        XCTAssertTrue(minimize.waitForExistence(timeout: 180), "the agent opened it (app_open)")
        pause(1)
        tap(minimize)
        waitForRun()

        // Holding its dock entry closes it.
        dock.press(forDuration: 1.2)
        tap(pi.buttons["Close Flights"].firstMatch)
        pause(2)
        XCTAssertFalse(dock.exists, "closed")
    }

    /// The session apps demo, paced for a recording (prints "MARK name epoch" lines to cut it by): /flights opens the
    /// Flights app, set to Tokyo in business, which minimizes to the dock while the chat goes on and opens again as it
    /// was; after a relaunch Flights is still in the dock with its unsaved edit, which is saved; the agent opens the app;
    /// holding its dock entry closes it.
    func testAppsDemo() throws {
        executionTimeAllowance = 25 * 60
        func mark(_ name: String) { print("MARK \(name) \(Date().timeIntervalSince1970)") }
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        func send(_ message: String) {
            let field = pi.textFields["Message pi"]
            tap(field)
            field.typeText(message)
            pause(1)
            tap(pi.buttons["Send"].firstMatch)
            pause(0.5)
        }
        func waitForRun() {
            _ = stop.waitForExistence(timeout: 20)
            let end = Date().addingTimeInterval(5 * 60)
            while stop.exists && Date() < end { pause(1) }
        }
        let minimize = pi.buttons["Minimize"].firstMatch
        let flights = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Flights. Open app")).firstMatch

        launchReady()
        mark("start")
        tap(pi.buttons["New session"].firstMatch)
        pause(2)

        mark("flights-open")
        send("/flights")
        XCTAssertTrue(minimize.waitForExistence(timeout: 20))
        pause(3)
        let to = pi.textFields["To airport"].firstMatch
        tap(to)
        to.typeText("Tokyo")
        pause(1.5)
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "HND")).firstMatch)
        pause(1.5)
        tap(pi.buttons["Business"].firstMatch)
        pause(2.5)
        mark("minimize")
        tap(minimize)
        pause(3)

        mark("chat")
        send("In one short sentence: when is cherry blossom season in Tokyo?")
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        waitForRun()
        mark("chat-done")
        pause(3)
        mark("reopen")
        tap(flights)
        pause(4)
        tap(minimize)
        pause(2)

        mark("relaunch")
        pi.terminate()
        pause(1.5)
        launchReady()
        mark("relaunched")
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In one short sentence")).firstMatch)
        XCTAssertTrue(flights.waitForExistence(timeout: 20))
        pause(3)
        mark("restore")
        tap(flights)
        // The page as it opens: the route and class kept from before the relaunch.
        _ = pi.textFields["To airport"].firstMatch.waitForExistence(timeout: 15)
        pause(5)
        mark("save")
        tap(pi.buttons["Save preferences"].firstMatch)
        pause(4)

        mark("agent")
        send("Open the Flights app for me.")
        // No tap to hide the keyboard: the app may already cover where the button was.
        XCTAssertTrue(minimize.waitForExistence(timeout: 180))
        mark("agent-opened")
        pause(3)
        tap(minimize)
        waitForRun()
        pause(2)

        mark("close")
        flights.press(forDuration: 1.2)
        pause(1)
        tap(pi.buttons["Close Flights"].firstMatch)
        pause(3)
        mark("end")
    }


    /// Opening a shared extension (a .piext file, opened from outside while this waits, as AirDrop would): the sheet says
    /// what it is and what it brings, and adds it for every session.
    func testSharedExtension() throws {
        executionTimeAllowance = 5 * 60
        launchReady()
        let add = pi.buttons["Add to Every Session"]
        XCTAssertTrue(add.waitForExistence(timeout: 120), "the shared extension's sheet")
        pause(2)
        add.tap()
        let added = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Added")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 30), "added")
        print("added: \(added.label)")
        pause(2)
        tap(pi.buttons["Done"].firstMatch)
    }

    /// Sharing an app from the dock: holding its entry offers Share, which opens iOS's share sheet with its extension.
    func testShareApp() throws {
        executionTimeAllowance = 5 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let field = pi.textFields["Message pi"]
        tap(field)
        field.typeText("/flights")
        pause(1)
        tap(pi.buttons["Send"].firstMatch)
        let minimize = pi.buttons["Minimize"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 20))
        pause(1.5)
        tap(minimize)
        let dock = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Flights. Open app")).firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 5))
        dock.press(forDuration: 1.2)
        tap(pi.buttons["Share Flights…"].firstMatch)
        let files = pi.staticTexts["Save to Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 15), "the share sheet")
        let file = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "flights")).firstMatch
        print("share sheet: \(file.exists ? file.label : "(no file name shown)")")
        pause(2)
        pi.swipeDown(velocity: .fast)
        pause(1)
        dock.press(forDuration: 1.2)
        tap(pi.buttons["Close Flights"].firstMatch)
    }

    /// The vault with Personal details (installed, with the vault-probe test extension; the vault test server on
    /// 127.0.0.1:8781; Face ID enrolled and matched from outside while this runs): a card saved in the app goes to the vault
    /// through pi's secure sheet; the agent fills it into a checkout page (the consent sheet, Face ID, then the second field
    /// within the window without asking); a revealed value comes back masked; a placeholder sends it; Settings → Vault
    /// lists it.
    func testVault() throws {
        executionTimeAllowance = 25 * 60
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        let minimize = pi.buttons["Minimize"].firstMatch
        func send(_ message: String) {
            let field = pi.textFields["Message pi"]
            tap(field)
            field.typeText(message)
            pause(1)
            tap(pi.buttons["Send"].firstMatch)
            pause(0.5)
            if hide.waitForExistence(timeout: 2) { hide.tap() }
        }
        func waitForRun() {
            _ = stop.waitForExistence(timeout: 20)
            let end = Date().addingTimeInterval(6 * 60)
            while stop.exists && Date() < end { pause(1) }
            pause(1)
        }
        func replace(_ field: XCUIElement, with text: String) {
            tap(field)
            pause(0.5)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            pause(0.5)
            let current = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
        }
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)

        // A card in Personal details: the public details in the app, the numbers in pi's secure sheet.
        send("/personal")
        XCTAssertTrue(minimize.waitForExistence(timeout: 20), "Personal details opened")
        pause(2)
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Card")).firstMatch)
        pause(1.5)
        replace(pi.textFields["Name"].firstMatch, with: "Chase Sapphire Preferred")
        replace(pi.textFields["Name on card"].firstMatch, with: "Dana Levi")
        replace(pi.textFields["Expires"].firstMatch, with: "08/29")
        tap(pi.buttons["Save"].firstMatch)
        let number = pi.textFields["Card number"].firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 20), "pi's secure sheet")
        pause(1)
        tap(number)
        number.typeText("4111111111111111")
        let cvv = pi.textFields["Security code"].firstMatch
        tap(cvv)
        cvv.typeText("123")
        tap(pi.navigationBars["Add to Vault"].buttons["Save"])
        let row = pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1111")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the card in the app")
        print("card row: \(row.label)")
        pause(1.5)
        tap(minimize)

        // The agent fills it into a page: the consent sheet and Face ID once, then the window.
        send("Open http://127.0.0.1:8781/checkout.html and fill in my Chase Sapphire Preferred card: the name on card and expiry from personal_details, the card number and security code with browser_fill_from_vault. Don't submit. Then say what the page's status line says.")
        let window = pi.buttons["Allow for 5 Minutes"]
        XCTAssertTrue(window.waitForExistence(timeout: 300), "the consent sheet")
        pause(1.5)
        window.tap()
        waitForRun()
        if pi.buttons["Allow for 5 Minutes"].exists { XCTFail("asked again within the window") }

        // An extension's revealed value comes back masked.
        send("Call vault_probe_reveal once and quote exactly what it returned.")
        let once = pi.buttons["Allow Once"]
        XCTAssertTrue(once.waitForExistence(timeout: 180), "the consent sheet for the extension")
        pause(1)
        once.tap()
        waitForRun()

        // A placeholder sends the value.
        send("Call vault_probe_send once and quote what it returned.")
        XCTAssertTrue(once.waitForExistence(timeout: 180), "the consent sheet for sending")
        pause(1)
        once.tap()
        waitForRun()

        // Settings → Vault lists it.
        pi.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Vault"].firstMatch)
        XCTAssertTrue(pi.staticTexts["Chase Sapphire Preferred"].firstMatch.waitForExistence(timeout: 10), "in Settings → Vault")
        pause(2)
    }

    /// Other information in Personal details (installed): an entry with a public field and one locked in the vault (entered
    /// in pi's secure sheet), what the agent's personal_details says of it, and its field's name in Settings → Vault.
    func testPersonalInfo() throws {
        executionTimeAllowance = 15 * 60
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        let minimize = pi.buttons["Minimize"].firstMatch
        func replace(_ field: XCUIElement, with text: String) {
            tap(field)
            pause(0.5)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            pause(0.5)
            let current = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
        }
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("/personal")
        pause(1)
        tap(pi.buttons["Send"].firstMatch)
        XCTAssertTrue(minimize.waitForExistence(timeout: 20), "Personal details opened")
        pause(2)
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Other information")).firstMatch)
        pause(1.5)
        replace(pi.textFields["Name"].firstMatch, with: "Gym membership")
        let names = pi.textFields.matching(identifier: "Field name")
        let values = pi.textFields.matching(identifier: "Value")
        tap(names.element(boundBy: 0))
        names.element(boundBy: 0).typeText("Location")
        tap(values.element(boundBy: 0))
        values.element(boundBy: 0).typeText("Downtown")
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add field")).firstMatch)
        pause(1)
        tap(names.element(boundBy: 1))
        names.element(boundBy: 1).typeText("Member number")
        tap(pi.buttons.matching(NSPredicate(format: "label == %@", "Lock in the vault")).element(boundBy: 1))
        pause(1)
        tap(pi.buttons["Save"].firstMatch)
        let member = pi.textFields["Member number"].firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 20), "pi's secure sheet asks for the locked field")
        tap(member)
        member.typeText("GYM-42-9876")
        tap(pi.navigationBars["Add to Vault"].buttons["Save"])
        let row = pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Gym membership")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the entry in the app")
        print("info row: \(row.label)")
        XCTAssertTrue(row.label.contains("1 in the vault"), "its locked field is in the vault")
        pause(1.5)
        tap(minimize)

        tap(message)
        message.typeText("What does my Gym membership entry say? Use personal_details and list its fields.")
        tap(pi.buttons["Send"].firstMatch)
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        _ = stop.waitForExistence(timeout: 20)
        let end = Date().addingTimeInterval(4 * 60)
        while stop.exists && Date() < end { pause(1) }
        pause(1)

        pi.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Vault"].firstMatch)
        // The session behind is named after the question, so the vault's row is the one from the extension.
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Gym membership", "personal-details")).firstMatch)
        let field = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Member number")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the field's name in Settings → Vault")
        pause(2)
    }

    /// A cold launch lists the sessions of the last launch at once, before the engine opens the store; one opened right
    /// away shows its transcript once the store is open.
    func testLaunchList() throws {
        pi.launchArguments += ["-testDelayEngine", "4"]
        pi.launch()
        let began = Date()
        // The newest session: its title begins with its first message.
        let row = pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", " · ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved list")
        let listed = Date().timeIntervalSince(began)
        let title = String(row.label.prefix { $0 != "," }.prefix(20))
        let newSession = pi.buttons["New session"].firstMatch
        let early = !newSession.isEnabled
        row.tap()
        let message = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "the transcript loads once the store is open")
        print(String(format: "launch list: listed after %.2fs (store still opening: %@), transcript after %.2fs", listed, early ? "yes" : "no", Date().timeIntervalSince(began)))
        pause(1)
    }

    /// Shortcuts: a shortcut with pi's Ask pi action (a new session) runs with pi not running: pi starts in the background,
    /// never comes to the front, and shows no popup (the reply is the action's output); the reply is in the session.
    func testShortcut() throws {
        executionTimeAllowance = 10 * 60
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // A prompt an earlier run left up.
        dismissShortcutLeftovers(springboard, shortcuts)
        pi.terminate()
        shortcuts.terminate()
        shortcuts.launch()
        pause(3)
        for label in ["Continue", "Not Now", "OK"] where shortcuts.buttons[label].exists { shortcuts.buttons[label].tap(); pause(1) }
        deleteTestShortcuts(shortcuts)
        let ask = shortcuts.buttons["bubble.left.and.text.bubble.right"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "pi's actions in the Shortcuts library")
        ask.tap()
        // Shortcuts asks for the message (in a view another process shows).
        var field: XCUIElement?
        let asked = Date().addingTimeInterval(15)
        while field == nil && Date() < asked {
            field = [shortcuts, springboard].map { $0.textViews.firstMatch }.first { $0.exists }
            if field == nil { pause(0.5) }
        }
        guard let field else {
            print("SHORTCUTS 2:\n\(springboard.debugDescription)\n\(shortcuts.debugDescription)")
            return XCTFail("Shortcuts asks for the message")
        }
        field.typeText("Reply with exactly the word pong, in lowercase, and nothing else.")
        [shortcuts, springboard].map { $0.buttons["Done"].firstMatch }.first { $0.exists }?.tap()
        // pi stays in the background, and nothing shows the reply (the shortcut's next action would get it).
        expectNoReplyShown("pong", in: [springboard, shortcuts], for: 45)
        pi.activate()
        backToSessions()
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply with exactly the word pong")).firstMatch)
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "pong")).firstMatch.waitForExistence(timeout: 60),
                      "the reply in the session")
        pause(2)
        dismissShortcutLeftovers(springboard, shortcuts)
    }

    /// Shortcuts: a shortcut built in the editor sends Ask pi to a session chosen from pi's sessions and shows the reply.
    func testShortcutSession() throws {
        executionTimeAllowance = 10 * 60
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        dismissShortcutLeftovers(springboard, shortcuts)
        shortcuts.terminate()
        shortcuts.launch()
        pause(3)
        deleteTestShortcuts(shortcuts)
        shortcuts.buttons["Create Shortcut"].firstMatch.tap()
        let search = shortcuts.searchFields["Search Actions"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the editor")
        search.tap()
        search.typeText("Ask pi")
        pause(2)
        let action = shortcuts.cells.matching(NSPredicate(format: "label CONTAINS %@", "Ask pi")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), "pi's Ask pi action")
        action.tap()
        pause(2)
        let row = shortcuts.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask pi")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the action in the shortcut")
        // Its Session token (the second line): pi's sessions to choose from.
        let corner = row.coordinate(withNormalizedOffset: .zero)
        corner.withOffset(CGVector(dx: 59, dy: 49)).tap()
        let chosen = shortcuts.cells.matching(NSPredicate(format: "label CONTAINS %@", "Reply with exactly the word pong")).firstMatch
        let pong = shortcuts.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply with exactly the word pong")).firstMatch
        XCTAssertTrue(pong.waitForExistence(timeout: 10), "pi's sessions to choose from (run testShortcut first)")
        (chosen.exists ? chosen : pong).tap()
        pause(2)
        // The message is left empty: running the shortcut asks for it.
        shortcuts.buttons["play"].firstMatch.tap()
        var field: XCUIElement?
        let asked = Date().addingTimeInterval(15)
        while field == nil && Date() < asked {
            field = [shortcuts, springboard].map { $0.textViews.firstMatch }.first { $0.exists }
            if field == nil { pause(0.5) }
        }
        guard let field else { return XCTFail("Shortcuts asks for the message") }
        field.typeText("Now reply with exactly the word ping, in lowercase, and nothing else.")
        [shortcuts, springboard].map { $0.buttons["Done"].firstMatch }.first { $0.exists }?.tap()
        expectNoReplyShown("ping", in: [springboard, shortcuts], for: 45)
        dismissShortcutLeftovers(springboard, shortcuts)
        // In pi, the chosen session has both messages.
        pi.activate()
        backToSessions()
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply with exactly the word pong")).firstMatch)
        let followUp = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Now reply with exactly the word ping")).firstMatch
        XCTAssertTrue(followUp.waitForExistence(timeout: 30), "the chosen session has the second message")
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "ping")).firstMatch.waitForExistence(timeout: 60),
                      "and its reply")
        pause(2)
    }

    /// Shortcuts: Ask pi with a request that outlasts the background time (20 seconds) asks to continue in pi, which then
    /// opens on that session, where the reply arrives.
    func testShortcutLong() throws {
        executionTimeAllowance = 10 * 60
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        dismissShortcutLeftovers(springboard, shortcuts)
        shortcuts.terminate()
        shortcuts.launch()
        pause(3)
        deleteTestShortcuts(shortcuts)
        let ask = shortcuts.buttons["bubble.left.and.text.bubble.right"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "pi's actions in the Shortcuts library")
        ask.tap()
        var field: XCUIElement?
        let asked = Date().addingTimeInterval(15)
        while field == nil && Date() < asked {
            field = [shortcuts, springboard].map { $0.textViews.firstMatch }.first { $0.exists }
            if field == nil { pause(0.5) }
        }
        guard let field else { return XCTFail("Shortcuts asks for the message") }
        field.typeText("Run sleep 30 in bash, then reply with exactly the word slept, in lowercase, and nothing else.")
        [shortcuts, springboard].map { $0.buttons["Done"].firstMatch }.first { $0.exists }?.tap()
        // After the background time: the system's question (or, without one, pi itself).
        let end = Date().addingTimeInterval(90)
        var confirmed = false
        while pi.state != .runningForeground && Date() < end {
            for app in [springboard, shortcuts] {
                if let button = ["Continue", "Open", "Open pi", "Yes"].map({ app.buttons[$0].firstMatch }).first(where: \.exists) {
                    print("continue in pi: \(app == springboard ? "springboard" : "shortcuts") asks, \(button.label)")
                    button.tap()
                    confirmed = true
                }
            }
            pause(1)
        }
        print("asked to continue: \(confirmed)")
        XCTAssertTrue(pi.wait(for: .runningForeground, timeout: 10), "pi opens to finish")
        let prompt = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Run sleep 30 in bash")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "on the shortcut's session")
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "slept")).firstMatch.waitForExistence(timeout: 180),
                      "the reply in the session")
        pause(2)
        dismissShortcutLeftovers(springboard, shortcuts)
    }

    /// Shortcuts: Start pi Session makes a new, empty session, in the background.
    func testShortcutStart() throws {
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        dismissShortcutLeftovers(springboard, shortcuts)
        shortcuts.terminate()
        shortcuts.launch()
        deleteTestShortcuts(shortcuts)
        let start = shortcuts.buttons["square.and.pencil"].firstMatch
        guard start.waitForExistence(timeout: 10) else {
            print("START 1:\n\(shortcuts.debugDescription)")
            return XCTFail("pi's Start Session in the Shortcuts library")
        }
        let before = Date()
        start.tap()
        // The shortcut ends (Shortcuts shows its result) without pi coming to the front.
        var cameForward = false
        while Date().timeIntervalSince(before) < 20 {
            if pi.state == .runningForeground { cameForward = true }
            pause(1)
        }
        XCTAssertFalse(cameForward, "pi stayed in the background")
        pi.activate()
        backToSessions()
        let newest = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New session, ")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 20), "the new session in pi's list")
        print("newest session: \(newest.label)")
        XCTAssertTrue(newest.label.contains("now") || newest.label.contains("second") || newest.label.contains("1 minute"), "made just now")
        pause(2)
    }

    /// Context use and pi's compaction: with the threshold lowered to 12.5K tokens (after one exchange pi measures about
    /// 13.2K: the system prompt and tools, the message and the reply), the first message has nothing before it to cut,
    /// and the second compacts the context automatically before its request; the earlier messages still show above the
    /// summary; the ring by the composer shows the use, and its Compact Now compacts again.
    func testCompaction() throws {
        executionTimeAllowance = 12 * 60
        pi.launchArguments += ["-compactReserveTokens", "987500", "-compactKeepRecentTokens", "60", "-compactBackgroundTokens", "0"]
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        func ask(_ text: String) {
            tap(message)
            message.typeText(text)
            tap(pi.buttons["Send"].firstMatch)
            _ = stop.waitForExistence(timeout: 20)
            let end = Date().addingTimeInterval(4 * 60)
            while stop.exists && Date() < end { pause(1) }
            pause(2)
        }
        ask("Write two short paragraphs about the history of the bicycle.")
        let gauge = pi.buttons["Context"].firstMatch
        XCTAssertTrue(gauge.waitForExistence(timeout: 10), "the context ring by the composer")
        print("context after one reply: \(gauge.value as? String ?? "?")")
        ask("Now two short paragraphs about the history of the telephone.")
        let compacted = pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Context compacted"))
        XCTAssertTrue(compacted.firstMatch.waitForExistence(timeout: 30), "pi compacted the context automatically")
        print("compaction row: \(compacted.firstMatch.label)")
        let first = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "history of the bicycle")).firstMatch
        for _ in 0..<6 where !first.exists { pi.swipeDown(); pause(0.5) }
        XCTAssertTrue(first.exists, "the first message still shows")
        for _ in 0..<6 { pi.swipeUp() }
        pause(1)
        // The summary, unfolded.
        compacted.firstMatch.tap()
        pause(2)
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        gauge.tap()
        let now = pi.buttons["Compact Now"].firstMatch
        XCTAssertTrue(now.waitForExistence(timeout: 5), "the context details")
        print("context details: \(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "tokens")).allElementsBoundByIndex.map(\.label))")
        pause(2)
        now.tap()
        let end = Date().addingTimeInterval(120)
        while compacted.count < 2 && Date() < end { pause(1) }
        XCTAssertGreaterThanOrEqual(compacted.count, 2, "Compact Now compacted again")
        print("compactions: \(compacted.allElementsBoundByIndex.map(\.label))")
        pause(2)
    }

    /// Forking from a message lists the fork once (the engine's session_added could arrive before the fork's reply).
    func testFork() throws {
        executionTimeAllowance = 6 * 60
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let marker = "Fork test \(Int(Date().timeIntervalSince1970) % 100000)"
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("\(marker): reply with the word ok, nothing else.")
        tap(pi.buttons["Send"].firstMatch)
        let stop = pi.buttons["Stop"].firstMatch
        _ = stop.waitForExistence(timeout: 20)
        let end = Date().addingTimeInterval(120)
        while stop.exists && Date() < end { pause(1) }
        pause(1.5)
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        // The reply (the message's text is selectable, so a long press there selects).
        let reply = pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "ok", "ok.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "the reply")
        reply.press(forDuration: 1.2)
        let forkButton = pi.buttons["Fork from Here"].firstMatch
        guard forkButton.waitForExistence(timeout: 5) else {
            print("FORK MENU:\n\(pi.debugDescription)")
            return XCTFail("the message's menu")
        }
        forkButton.tap()
        pause(3)
        pi.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        if pi.navigationBars.buttons.element(boundBy: 0).exists, !pi.buttons["Settings"].exists { pi.navigationBars.buttons.element(boundBy: 0).tap() }
        pause(1.5)
        let forks = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fork: \(marker)"))
        let originals = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", marker))
        print("fork rows: \(forks.count), original rows: \(originals.count)")
        XCTAssertEqual(forks.count, 1, "the fork is listed once")
        XCTAssertEqual(originals.count, 1, "the session it forked is listed once")
    }

    /// Attachments: a photo picked from Photos waits as a chip, goes into the session's workspace when sent, shows as a
    /// file in the message (its `attachment:` line), and the agent looks at it with read (images come back as images).
    func testAttachments() throws {
        executionTimeAllowance = 8 * 60
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        tap(pi.buttons["Attach"].firstMatch)
        tap(pi.buttons["Photos…"].firstMatch)
        pause(3)
        // The first photo in the picker.
        // The first photo (the grid's cells aren't exposed), then Done (the checkmark).
        let done = pi.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the photo picker")
        pi.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 67, dy: 380)).tap()
        pause(1)
        done.tap()
        let chip = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove Photo")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the photo waits as a chip")
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("What's in the photo I attached? Answer in one short sentence.")
        tap(pi.buttons["Send"].firstMatch)
        if pi.buttons["Hide keyboard"].waitForExistence(timeout: 2) { pi.buttons["Hide keyboard"].tap() }
        let label = pi.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Attached Photo")).firstMatch
        let anyLabel = pi.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Attached Photo")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5) || anyLabel.exists, "the message shows the attached file")
        let stop = pi.buttons["Stop"].firstMatch
        _ = stop.waitForExistence(timeout: 20)
        let end = Date().addingTimeInterval(4 * 60)
        while stop.exists && Date() < end { pause(1) }
        pause(2)
        // The simulator's first photo: pink flowers. The agent reads it, and sees it.
        let words = ["flower", "bloom", "blossom", "petal", "bougainvillea", "azalea"]
        let reply = pi.staticTexts.allElementsBoundByIndex.map(\.label).filter { label in words.contains { label.lowercased().contains($0) } }
        print("attachment reply: \(reply)")
        XCTAssertFalse(reply.isEmpty, "the agent saw the photo")
        XCTAssertFalse(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not supported")).firstMatch.exists, "read took the image")
        pause(2)
    }

    /// The composer's buttons go two by two once the message wraps past one line.
    func testComposerButtons() throws {
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        launchReady()
        // The newest session (it has messages, so the context ring shows).
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", " · ")).firstMatch)
        let message = pi.textFields["Message pi"]
        tap(message)
        pause(1)
        // pi's mic by its identifier: the keyboard has a Dictate key too.
        let buttons = ["Hide keyboard", "Context", "Attach"].map { pi.buttons[$0].firstMatch } + [pi.buttons.matching(identifier: "mic").firstMatch]
        let row = buttons.map(\.frame)
        print("composer one line: \(row.map { "(\(Int($0.midX)),\(Int($0.midY)))" })")
        // Rows: centers within a few points (the ring and the icons differ a little).
        func rows(_ frames: [CGRect]) -> Int {
            var starts: [CGFloat] = []
            for y in frames.map(\.midY).sorted() where starts.last.map({ y - $0 > 6 }) ?? true { starts.append(y) }
            return starts.count
        }
        XCTAssertEqual(rows(row), 1, "one row beside a one-line message")
        message.typeText("A longer message that wraps onto a second line in the message box, and then a third one too.")
        pause(1.5)
        let square = buttons.map(\.frame)
        print("composer wrapped: \(square.map { "(\(Int($0.midX)),\(Int($0.midY)))" })")
        XCTAssertEqual(rows(square), 2, "two rows beside a wrapped message")
        let typed = pi.textFields.matching(NSPredicate(format: "value BEGINSWITH %@", "A longer message")).firstMatch
        XCTAssertLessThan(typed.frame.minX, row.map(\.maxX).max()!, "the message is wider")
        pause(2)
    }

    /// iCloud sync, a device's first time, differing from iCloud (set up before the test: no sync state, another network
    /// server): pi asks which to keep, showing both; iCloud's is then the app's.
    func testSyncChoice() throws {
        pi.launch()
        let sheet = pi.navigationBars["Your Other Devices"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "pi asks which settings to keep")
        let rows = pi.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("http") || $0 == "Network server" }
        print("sync choice: \(rows)")
        XCTAssertTrue(pi.staticTexts["Network server"].exists, "the network server differs")
        pause(2)
        tap(pi.buttons["Use iCloud's Settings"].firstMatch)
        pause(2)
        tap(pi.buttons["Settings"])
        // iCloud's server: anything but the one this device was set up with.
        let field = pi.textFields.matching(NSPredicate(format: "value BEGINSWITH %@ AND NOT (value CONTAINS %@)", "http", "other.example")).firstMatch
        for _ in 0..<8 where !field.exists { pi.swipeUp(); pause(0.5) }
        XCTAssertTrue(field.exists, "iCloud's network server in Settings")
        print("network server now: \(field.value as? String ?? "?")")
    }

    /// The vault's items saved on this device only (before it synced) move to iCloud Keychain from Settings → Vault, with
    /// Face ID once. (Face ID matches come from the shell while it runs.)
    func testVaultSyncMove() throws {
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        launchReady()
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Vault"].firstMatch)
        let toggle = pi.switches["Sync with iCloud Keychain"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the iCloud switch")
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        let move = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sync ")).firstMatch
        guard move.waitForExistence(timeout: 5) else { return print("vault move: nothing to move") }
        print("vault move: \(move.label)")
        move.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: move)
        waitForExpectations(timeout: 30)
        print("vault move: done")
        pause(1)
    }

    /// Share Session (the session's ⋯ menu) packs the session into a .pisession file and offers the share sheet. Takes the
    /// newest session whose title begins with `-shareSessionTitle` (default: the compaction test's).
    func testShareSession() throws {
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        launchReady()
        let title = UserDefaults.standard.string(forKey: "shareSessionTitle") ?? "What's in the photo I attached"
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch)
        pause(1.5)
        tap(pi.buttons["More"].firstMatch)
        tap(pi.buttons["Share Session…"].firstMatch)
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let shown = pi.otherElements["ActivityListView"].firstMatch.waitForExistence(timeout: 15)
            || pi.buttons["Save to Files"].firstMatch.waitForExistence(timeout: 2) || sheet.buttons["Copy"].firstMatch.exists
        print("share session sheet: \(shown)")
        XCTAssertTrue(shown, "the share sheet with the session file")
        pause(2)
    }

    /// The App Store screenshots' requests, oldest first (the list shows the newest on top). Each starts with the line its
    /// session is named after.
    static let screenshotPrompts = [
        "Which pi packages have the most TypeScript? Clone https://github.com/earendil-works/pi with git (shallow), count the .ts files in each package, and reply with a short markdown table sorted by count.",
        "Top stories on Hacker News right now? Open news.ycombinator.com in the browser and list the top three with their points, briefly.",
        "Chart the planets by their number of moons. Use Python to write the data as a CSV, then show a bar chart with show_html: an inline SVG sized for a phone screen, clean and colorful. Reply in one sentence.",
        "Build me a tip-splitting app. Write a pi extension with an app named Tip Split: the bill amount, a tip slider from 0 to 30%, the number of people, and the total per person, in large iOS-style type that looks right in light and dark mode. Add it to this session and open it.",
    ]

    /// The App Store screenshots' sessions: a new session for each of `screenshotPrompts`, waited on until the agent is
    /// done. Run on a simulator whose sessions were cleared (testCleanUpSessions), with a public provider's model as the
    /// default, so no internal host shows.
    func testScreenshotSessions() throws {
        executionTimeAllowance = 40 * 60
        launchReady()
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        for prompt in Self.screenshotPrompts {
            tap(pi.buttons["New session"].firstMatch)
            pause(1.5)
            tap(message)
            message.typeText(prompt)
            tap(pi.buttons["Send"].firstMatch)
            _ = stop.waitForExistence(timeout: 30)
            let end = Date().addingTimeInterval(10 * 60)
            while stop.exists && Date() < end { pause(2) }
            pause(3)
            print("screenshot session done: \(prompt.prefix(48))")
            if pi.buttons["Minimize"].exists { pi.buttons["Minimize"].firstMatch.tap(); pause(1) }
            if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
            pi.navigationBars.buttons.element(boundBy: 0).tap()
            pause(1.5)
        }
    }

    /// App Store screenshots, saved to SCREENSHOT_DIR as <iphone|ipad>-<n>-<name>.png: the sessions, the app the agent
    /// built, its chart, a repository's numbers, and the browser's stories, from testScreenshotSessions' sessions.
    func testScreenshots() throws {
        executionTimeAllowance = 10 * 60
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], "where to save the screenshots")
        // By pi's window (the test runner, an iPhone app, reports a phone even on an iPad).
        launchReady()
        let pad = pi.windows.firstMatch.frame.width > 700
        func shot(_ name: String) {
            let file = URL(fileURLWithPath: folder).appending(path: "\(pad ? "ipad" : "iphone")-\(name).png")
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
            print("screenshot \(file.lastPathComponent)")
        }
        func open(_ title: String) {
            if !pad, !pi.buttons["New session"].isHittable { pi.navigationBars.buttons.element(boundBy: 0).tap(); pause(1.5) }
            let row = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            // An iPad hides the sessions list beside a session and its app: its sidebar button, or a swipe from the edge.
            if pad, !(row.exists && row.isHittable) {
                let sidebar = pi.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sidebar")).firstMatch
                if sidebar.exists && sidebar.isHittable {
                    sidebar.tap()
                } else {
                    pi.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
                        .press(forDuration: 0.1, thenDragTo: pi.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                }
                pause(1.5)
                if !(row.exists && row.isHittable) {
                    try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "debug-sidebar.png"))
                }
            }
            tap(row)
            pause(3)
            if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap(); pause(0.5) }
        }
        pause(2)
        if !pad { shot("1-sessions") }

        open("Build me a tip-splitting app")
        // From the dock: the page may be loaded already, parked off screen.
        let dockEntry = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tip Split")).firstMatch
        if dockEntry.waitForExistence(timeout: 10) { dockEntry.tap() }
        _ = pi.buttons["Minimize"].firstMatch.waitForExistence(timeout: 20)
        pause(3)
        // A bill to split, then the keyboard away.
        let bill = pi.webViews.textFields.firstMatch
        if bill.waitForExistence(timeout: 5), ["", "0", "0.00"].contains((bill.value as? String) ?? "") {
            bill.tap()
            pause(1)
            bill.typeText("86.40")
            // The keyboard's checkmark on an iPhone, its hide key on an iPad (tapping the page's text doesn't end the editing).
            let done = pi.buttons["Done"].firstMatch
            let hide = pi.keyboards.buttons["Hide keyboard"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() } else if hide.exists { hide.tap() } else { bill.typeText("\n") }
        }
        pause(3)
        shot(pad ? "1-app" : "2-app")
        if pi.buttons["Minimize"].exists { pi.buttons["Minimize"].firstMatch.tap(); pause(1.5) }

        open("Chart the planets")
        _ = pi.webViews.firstMatch.waitForExistence(timeout: 20)
        pause(3)
        shot(pad ? "2-chart" : "3-chart")

        open("Which pi packages")
        shot(pad ? "3-repository" : "4-repository")

        open("Top stories on Hacker News")
        shot(pad ? "4-browser" : "5-browser")
    }

    /// Settings → Default model for new sessions: picks the model named DEFAULT_MODEL (as the picker shows it, e.g.
    /// "Claude Sonnet 5.5"), the way a user does, so iCloud's copy of the setting follows.
    func testSetDefaultModel() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["DEFAULT_MODEL"], "the model's name")
        launchReady()
        tap(pi.buttons["Settings"])
        // The setting's row reads "model · provider"; the sessions' rows behind the sheet also have a title before a comma.
        let setting = NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", " · ", ", ")
        let current = pi.buttons.matching(setting).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10), "the default model's row")
        print("default model was: \(current.label)")
        tap(current)
        let row = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<6 where !row.isHittable { pi.swipeUp(); pause(0.5) }
        tap(row)
        pause(1.5)
        let now = pi.buttons.matching(setting).firstMatch
        print("default model now: \(now.label)")
        XCTAssertTrue(now.label.hasPrefix(name), "the default model")
        tap(pi.buttons["Done"].firstMatch)
        pause(1)
    }

    /// A message's menu copies it (an answer as its Markdown, pasted back into the message box here) and opens it for
    /// selecting part of its text.
    func testCopyMessage() throws {
        executionTimeAllowance = 5 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        tap(message)
        message.typeText("Reply with only a Python code block that prints copy test, nothing else.")
        tap(pi.buttons["Send"].firstMatch)
        _ = stop.waitForExistence(timeout: 20)
        let end = Date().addingTimeInterval(3 * 60)
        while stop.exists && Date() < end { pause(1) }
        pause(2)
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }

        // The answer's row, by its code (the request says "copy test" too).
        let answer = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "print(")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the answer")
        answer.press(forDuration: 1.0)
        tap(pi.buttons["Copy"].firstMatch)
        pause(1)
        tap(message)
        message.press(forDuration: 1.2)
        tap(pi.menuItems["Paste"].firstMatch)
        pause(1)
        // The message box, holding text (it loses its "Message pi" label then; several lines can make it a text view).
        let composer = pi.textViews.firstMatch.exists ? pi.textViews.firstMatch : pi.textFields.firstMatch
        let pasted = composer.value as? String ?? ""
        print("pasted: \(pasted)")
        XCTAssertTrue(pasted.contains("```") && pasted.contains("copy test"), "the answer's Markdown, code fence and all")
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: pasted.count + 2))
        pause(1)

        tap(message)
        message.typeText("!echo first line; echo second line")
        tap(pi.buttons["Send"].firstMatch)
        let output = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "echo first line")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 20), "the command's row")
        pause(2)
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        output.press(forDuration: 1.0)
        tap(pi.buttons["Select Text"].firstMatch)
        let text = pi.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the Select Text sheet")
        let value = text.value as? String ?? ""
        print("select text: \(value)")
        XCTAssertTrue(value.contains("second line"), "the command and its output")
        tap(pi.buttons["Done"].firstMatch)
        pause(1)
    }

    /// The watchdog when an extension freezes the engine as it loads: SHARED_FILE is loadfreeze.piext
    /// (Fixtures/loadfreeze.ts, 60 seconds of top-level code that never yields). Added, it holds the engine; the page is
    /// replaced, an alert names loadfreeze, it isn't loaded again (it never got added, or it's off), and pi works. Then
    /// it's removed. Nothing is read while the engine is held: reading the app waits for the engine's page then.
    func testEngineFreezeOnLoad() throws {
        executionTimeAllowance = 5 * 60
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(45)
        let alert = pi.alerts["loadfreeze froze pi's engine"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "an alert says what happened")
        print("alert: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
        alert.buttons["OK"].tap()
        pause(1)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        backToSessions()
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        XCTAssertTrue(pi.switches.firstMatch.waitForExistence(timeout: 15), "the extensions, listed (pi works)")
        // It froze as it was being added, so it isn't (or, if it got that far, it's off): never loaded again.
        let toggle = pi.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "loadfreeze")).firstMatch
        print("loadfreeze listed: \(toggle.exists)\(toggle.exists ? " = \(toggle.value ?? "?")" : "")")
        if toggle.exists { XCTAssertEqual(toggle.value as? String, "0", "turned off, not loaded again") }
        // Removed, for the next run.
        pi.terminate()
        pi.launchArguments = ["-engineCommands", #"extensions.remove {"name":"loadfreeze"}"#]
        launchReady()
    }

    /// The watchdog: an extension holding the engine (busytest's /busyfreeze, 60 seconds of code that never yields, sent
    /// at launch) gets the engine's page replaced in about 15 seconds; the session then says busytest froze pi's engine
    /// and was turned off, and busytest is off in Settings (turned back on at the end, as its switch does, for the next
    /// run). SHARED_FILE is
    /// busytest.piext. The test reads nothing while the engine is held: reading the app waits for the engine's page then.
    func testEngineFreezeRecovery() throws {
        executionTimeAllowance = 5 * 60
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        // Only the session that freezes, to find afterwards.
        deleteAllSessions()
        pi.terminate()

        pi.launchArguments = ["-engineCommands", #"extensions.setEnabled {"name":"busytest","enabled":true}"#, "-autorun", "/busyfreeze"]
        pi.launch()
        pause(45)

        // The only session (a command doesn't name it).
        let session = pi.staticTexts["New session"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 20), "the session that froze, listed")
        tap(session)
        let froze = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "froze pi's engine")).firstMatch
        XCTAssertTrue(froze.waitForExistence(timeout: 10), "the session says what happened")
        print("message: \(froze.label)")
        XCTAssertTrue(froze.label.hasPrefix("busytest"), "names the extension")

        backToSessions()
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        let toggle = pi.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "busytest")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "busytest among the extensions")
        print("busytest switch: \(toggle.value ?? "?")")
        XCTAssertEqual(toggle.value as? String, "0", "turned off")
        // Back on for the next run, as Settings' switch does (the engine's extensions.setEnabled).
        pi.terminate()
        pi.launchArguments = ["-engineCommands", #"extensions.setEnabled {"name":"busytest","enabled":true}"#]
        launchReady()
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        let again = pi.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "busytest")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "busytest among the extensions")
        XCTAssertEqual(again.value as? String, "1", "back on")
    }

    /// Stop ends an extension's work for the user, and the indicator names the extension: SHARED_FILE is busytest.piext
    /// (Fixtures/busytest.ts). A slow command shows as "busytest: /busywait", a message sent meanwhile shows at once, and
    /// Stop ends the command (it hears the abort). Two at once show as "2 extension tasks running", which opens to a row
    /// each with its own Stop. One that ignores Stop still frees the session at once. pi.exec given ctx.signal ends its
    /// shell command on Stop. (/busyblock, holding the engine
    /// itself, is for trying by hand: a UI test can't act meanwhile, as reading the app waits for the engine's page.)
    func testExtensionStop() throws {
        executionTimeAllowance = 6 * 60
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        func command(_ text: String) {
            tap(message)
            message.typeText(text)
            tap(pi.buttons["Send"].firstMatch)
        }
        func notice(_ prefix: String) -> XCUIElement {
            pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }

        command("/busywait")
        let working = pi.staticTexts["busytest: /busywait"]
        XCTAssertTrue(working.waitForExistence(timeout: 5), "the indicator names the extension and its command")
        let field = pi.textFields.firstMatch
        tap(field)
        field.typeText("Reply with exactly the word yes.")
        tap(pi.buttons["Steer"].firstMatch)
        let sent = pi.staticTexts["Reply with exactly the word yes."]
        XCTAssertTrue(sent.waitForExistence(timeout: 3), "a message sent while the extension works shows at once")
        tap(stop)
        XCTAssertTrue(notice("busywait: stopped").waitForExistence(timeout: 5), "the command heard Stop")
        XCTAssertFalse(working.exists, "the indicator gone")
        pause(5)

        command("/busyignore")
        let ignoring = pi.staticTexts["busytest: /busyignore"]
        XCTAssertTrue(ignoring.waitForExistence(timeout: 5), "working")
        // A second task beside it: the indicator counts them and opens to a row each, each with its own Stop.
        tap(field)
        field.typeText("/busywait")
        tap(pi.buttons["Steer"].firstMatch)
        let two = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "2 extension tasks running")).firstMatch
        XCTAssertTrue(two.waitForExistence(timeout: 5), "two tasks, counted")
        tap(two)
        tap(pi.buttons["Stop busytest: /busywait"].firstMatch)
        XCTAssertTrue(notice("busywait: stopped").waitForExistence(timeout: 5), "that one stopped")
        XCTAssertTrue(ignoring.waitForExistence(timeout: 5), "the other still running, alone")
        tap(stop)
        let freed = Date().addingTimeInterval(5)
        while (ignoring.exists || stop.exists) && Date() < freed { pause(0.3) }
        XCTAssertFalse(ignoring.exists, "the session freed though the command ignores Stop")
        XCTAssertFalse(stop.exists, "nothing to stop any more")
        pause(2)

        // pi.exec with ctx.signal: Stop ends the shell command too.
        command("/busyexec")
        XCTAssertTrue(pi.staticTexts["busytest: /busyexec"].waitForExistence(timeout: 5), "running sleep 30")
        pause(1)
        tap(stop)
        XCTAssertTrue(notice("busyexec: stopped").waitForExistence(timeout: 5), "the shell command ended by Stop")
        pause(2)

        let end = Date().addingTimeInterval(60)
        while stop.exists && Date() < end { pause(1) }
    }

    /// Send now (the Steer button's menu) stops the run mid-tool and sends at once: a 30-second sleep ends within seconds,
    /// the message queued before it goes with it (one prompt, in order), nothing stays queued, no error shows, and the
    /// model answers the new prompt. Needs a model that runs tools.
    func testSendNow() throws {
        executionTimeAllowance = 6 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        tap(message)
        message.typeText("Use the bash tool to run exactly: sleep 30. Then reply with exactly the word late.")
        tap(pi.buttons["Send"].firstMatch)
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "the run")
        let sleeping = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "sleep 30")).firstMatch
        XCTAssertTrue(sleeping.waitForExistence(timeout: 60), "the sleep running")
        let field = pi.textFields.firstMatch
        // One queued first (Steer), then Send now.
        tap(field)
        field.typeText("Remember the word one.")
        tap(pi.buttons["Steer"].firstMatch)
        XCTAssertTrue(pi.staticTexts["Steering: after the current step"].waitForExistence(timeout: 3), "queued")
        tap(field)
        field.typeText("Reply with exactly the words one now.")
        pi.buttons["Steer"].firstMatch.press(forDuration: 1.0)
        let sent = Date()
        tap(pi.buttons["Send now"].firstMatch)

        let combined = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Remember the word one.", "Reply with exactly the words one now.")).firstMatch
        XCTAssertTrue(combined.waitForExistence(timeout: 15), "one prompt: the queued message, then the new one")
        XCTAssertFalse(pi.staticTexts["Steering: after the current step"].exists, "nothing left queued")
        let answer = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "one now")).allElementsBoundByIndex
        let end = Date().addingTimeInterval(90)
        while stop.exists && Date() < end { pause(0.5) }
        let took = Date().timeIntervalSince(sent)
        print("send now to the answer: \(Int(took)) s; answers: \(answer.count)")
        XCTAssertLessThan(took, 25, "the 30-second sleep stopped, not waited out")
        let reply = pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "one now", "one now.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the model answered the new prompt")
        XCTAssertFalse(pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "late")).firstMatch.exists, "the stopped run didn't answer")
        for word in ["aborted", "unanswered"] {
            XCTAssertFalse(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", word)).firstMatch.exists, "no error")
        }
    }

    /// A message sent during a run shows at once, queued ("Steering: after the current step"), and becomes the user's
    /// message when the agent takes it; one taken back (Cancel) leaves the queue, its text back in the message box, with
    /// no error and no message in the transcript. Needs a model that runs tools.
    func testQueuedSteering() throws {
        executionTimeAllowance = 8 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        let queuedLabel = pi.staticTexts["Steering: after the current step"]
        func runSleep(_ word: String) {
            tap(message)
            message.typeText("Use the bash tool to run exactly: sleep 12. Then reply with exactly the word \(word).")
            tap(pi.buttons["Send"].firstMatch)
            XCTAssertTrue(stop.waitForExistence(timeout: 20), "the run")
            let tool = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "sleep 12")).firstMatch
            XCTAssertTrue(tool.waitForExistence(timeout: 60), "the sleep running")
        }
        func steer(_ text: String) {
            let field = pi.textFields.firstMatch
            tap(field)
            field.typeText(text)
            tap(pi.buttons["Steer"].firstMatch)
        }

        runSleep("done")
        steer("Also add the word hi.")
        XCTAssertTrue(queuedLabel.waitForExistence(timeout: 3), "queued at once, before the agent takes it")
        XCTAssertTrue(pi.staticTexts["Also add the word hi."].exists, "its text, queued")
        // Taken at the run's next step: the queue empties and the message stays, as the user's.
        let taken = Date().addingTimeInterval(90)
        while queuedLabel.exists && Date() < taken { pause(1) }
        XCTAssertFalse(queuedLabel.exists, "taken by the agent")
        XCTAssertTrue(pi.staticTexts["Also add the word hi."].exists, "now the user's message")
        let end = Date().addingTimeInterval(2 * 60)
        while stop.exists && Date() < end { pause(1) }
        pause(2)

        runSleep("second")
        steer("This one is taken back.")
        XCTAssertTrue(queuedLabel.waitForExistence(timeout: 3), "queued")
        tap(pi.buttons["Cancel queued message"].firstMatch)
        pause(1.5)
        XCTAssertFalse(queuedLabel.exists, "out of the queue")
        let box = pi.textFields.firstMatch.value as? String ?? ""
        print("box after cancel: \(box)")
        XCTAssertTrue(box.contains("This one is taken back."), "its text back in the message box")
        let end2 = Date().addingTimeInterval(2 * 60)
        while stop.exists && Date() < end2 { pause(1) }
        pause(2)
        // In the message box (a text field), not in the transcript (a text).
        XCTAssertEqual(pi.staticTexts.matching(NSPredicate(format: "label == %@", "This one is taken back.")).count, 0, "not in the transcript")
        XCTAssertFalse(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "aborted")).firstMatch.exists, "no error")
        XCTAssertFalse(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "unanswered")).firstMatch.exists, "no error")
    }

    /// Typing during a run, letter by letter, past the point where the message wraps and the buttons beside it go two by
    /// two (Stop and Steer take room then): the layout settles (each keystroke waits for the app to idle, which a layout
    /// flipping back and forth never does) and the box holds what was typed. Then shorter again, and empty.
    func testComposerWrapWhileRunning() throws {
        executionTimeAllowance = 5 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        // A reply first, so the context gauge joins the buttons (four of them, two columns when they go two by two).
        tap(message)
        message.typeText("Reply with exactly the word ok.")
        tap(pi.buttons["Send"].firstMatch)
        _ = stop.waitForExistence(timeout: 20)
        let replied = Date().addingTimeInterval(2 * 60)
        while stop.exists && Date() < replied { pause(1) }
        pause(2)
        tap(message)
        message.typeText("!sleep 60")
        tap(pi.buttons["Send"].firstMatch)
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "the command running")
        let field = pi.textFields.firstMatch
        tap(field)
        let text = "Also check whether the README mentions the license, and which one it is, please"
        for character in text {
            field.typeText(String(character))
        }
        pause(1)
        let typed = field.value as? String ?? ""
        print("typed: \(typed)")
        XCTAssertEqual(typed, text, "the box holds what was typed")
        // Shorter, past where it wrapped, and empty: no flipping either way.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        pause(1)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        pause(1)
        XCTAssertTrue(stop.exists, "still running")
        tap(stop)
        pause(1)
    }

    /// The session's thinking level, from its ⋯ menu: High shows in its subtitle and the answer comes without an error;
    /// with PI_EXPECT_THINKING=1, the answer must also show its thinking (a provider that returns it: a gateway may drop
    /// it). Off, the next answer comes without. The default for new sessions is in Settings. Needs a reasoning model as
    /// the default (a provider's, or one through the network server that pi-ai's catalog knows).
    func testThinkingLevel() throws {
        executionTimeAllowance = 8 * 60
        let expectThinking = ProcessInfo.processInfo.environment["PI_EXPECT_THINKING"] == "1"
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let more = pi.navigationBars.buttons["More"].firstMatch
        func choose(_ level: String) {
            tap(more)
            tap(pi.buttons["Thinking"].firstMatch)
            tap(pi.buttons[level].firstMatch)
            pause(1.5)
        }
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        func ask(_ prompt: String) {
            tap(message)
            message.typeText(prompt)
            tap(pi.buttons["Send"].firstMatch)
            if pi.buttons["Hide keyboard"].waitForExistence(timeout: 2) { pi.buttons["Hide keyboard"].tap() }
            _ = stop.waitForExistence(timeout: 30)
            let end = Date().addingTimeInterval(4 * 60)
            while stop.exists && Date() < end { pause(1) }
            pause(2)
        }
        choose("High")
        let subtitle = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "high thinking")).firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5), "the level in the session's subtitle")
        print("subtitle: \(subtitle.label)")
        ask("A bat and a ball cost $1.10 together; the bat costs $1.00 more than the ball. What does the ball cost? Answer in one short sentence.")
        let thinking = pi.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Thinking")).firstMatch
        let shown = thinking.waitForExistence(timeout: 10)
        print("thinking shown: \(shown)")
        if expectThinking { XCTAssertTrue(shown, "the answer came with its thinking") }
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0.05")).firstMatch.exists, "the answer")
        XCTAssertFalse(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "error")).firstMatch.exists, "no error")
        let thoughtBefore = pi.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Thinking")).count

        choose("Off")
        XCTAssertFalse(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "thinking")).firstMatch.exists, "no level in the subtitle")
        ask("Reply with exactly the word ok.")
        let thoughtAfter = pi.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Thinking")).count
        print("thinking sections: \(thoughtBefore) before, \(thoughtAfter) after")
        XCTAssertEqual(thoughtAfter, thoughtBefore, "off: the next answer came without thinking")

        // The default for new sessions, in Settings.
        backToSessions()
        tap(pi.buttons["Settings"])
        let defaultThinking = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Thinking")).firstMatch
        XCTAssertTrue(defaultThinking.waitForExistence(timeout: 10), "the default thinking level in Settings")
        print("default: \(defaultThinking.label)")
        pause(1)
    }

    /// An extension's code calling an MCP server (pi.mcp), only once the user allows it: SHARED_FILE is mcptest.piext
    /// (Fixtures/mcptest.ts), with the mock MCP server added as "mock" and signed in (testMCPServer). The first call asks;
    /// refused, the extension gets the refusal and nothing reaches the server; allowed in Settings, the call goes through
    /// without a question, and the server's tools are listed to it. Set back to Ask at the end, so it runs again.
    func testExtensionMCP() throws {
        executionTimeAllowance = 6 * 60
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        let message = pi.textFields["Message pi"]
        func command(_ text: String) {
            tap(message)
            message.typeText(text)
            tap(pi.buttons["Send"].firstMatch)
        }
        func notice(_ prefix: String) -> XCUIElement {
            pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)

        command("/mcptest")
        let ask = pi.alerts["Allow “mcptest” to use the MCP server “mock”?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 20), "pi asks before the extension's code uses the server")
        pause(1)
        ask.buttons["Don’t Allow"].tap()
        let refused = notice("mcp error")
        XCTAssertTrue(refused.waitForExistence(timeout: 15), "the refusal reaches the extension")
        print("refused: \(refused.label)")
        XCTAssertTrue(refused.label.contains("didn't allow"), "refused by the user")
        pause(5)

        command("/mcpservers")
        let listed = notice("servers:")
        XCTAssertTrue(listed.waitForExistence(timeout: 15), "the servers, as the extension sees them")
        print("servers (refused): \(listed.label)")
        XCTAssertTrue(listed.label.contains("mock=denied:0"), "refused, and its tools not listed")
        pause(5)

        // Allowed in Settings → Extensions → mcptest → MCP servers.
        backToSessions()
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        let row = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "mcptest")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "mcptest among the extensions")
        for _ in 0..<5 where !row.isHittable { pi.swipeUp(); pause(0.5) }
        tap(row)
        let server = permissionRow("mock")
        for _ in 0..<4 where !(server.exists && server.isHittable) { pi.swipeUp(); pause(0.5) }
        XCTAssertTrue(server.waitForExistence(timeout: 10), "the mock server among its MCP servers")
        print("in Settings: \(server.label)")
        XCTAssertTrue(server.label.hasSuffix("Don’t Allow"), "refused, in Settings")
        setPermission(server, to: "Allow")
        XCTAssertFalse(permissionRow("mock").label.hasSuffix("Don’t Allow"), "allowed in Settings")
        for _ in 0..<3 where !pi.buttons["Done"].exists {
            pi.navigationBars.buttons.element(boundBy: 0).tap()
            pause(1)
        }
        tap(pi.buttons["Done"].firstMatch)
        pause(1)

        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        command("/mcptest")
        let echoed = notice("mcp: ")
        XCTAssertTrue(echoed.waitForExistence(timeout: 30), "the server's answer")
        print("allowed: \(echoed.label)")
        XCTAssertFalse(pi.alerts.firstMatch.exists, "no question: allowed in Settings")
        XCTAssertTrue(echoed.label.contains("hello from code"), "the echo tool's result, from the extension's code")
        pause(5)
        command("/mcpservers")
        let allowedList = notice("servers:")
        XCTAssertTrue(allowedList.waitForExistence(timeout: 15), "the servers again")
        print("servers (allowed): \(allowedList.label)")
        XCTAssertTrue(allowedList.label.contains("mock=allowed:2"), "allowed, with its two tools")
        pause(1)

        // Back to Ask, for the next run.
        backToSessions()
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        for _ in 0..<5 where !row.isHittable { pi.swipeUp(); pause(0.5) }
        tap(row)
        for _ in 0..<4 where !(permissionRow("mock").exists && permissionRow("mock").isHittable) { pi.swipeUp(); pause(0.5) }
        setPermission(permissionRow("mock"), to: "Ask")
    }

    /// Before testAppReviewRecording: iCloud's settings taken if pi asks (its accounts with them), and every session
    /// deleted, so the recording starts from an empty list.
    func testAppReviewPrep() throws {
        pi.launch()
        let choice = pi.buttons["Use iCloud's Settings"].firstMatch
        if choice.waitForExistence(timeout: 10) {
            choice.tap()
            pause(2)
        }
        deleteAllSessions()
        print("sessions list: \(pi.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))")
    }

    /// Clean Up → All sessions → Delete, on the sessions list.
    private func deleteAllSessions() {
        let cleanUp = pi.buttons["Clean Up"]
        XCTAssertTrue(cleanUp.waitForExistence(timeout: 15), "the sessions list")
        let loaded = Date().addingTimeInterval(15)
        while !cleanUp.isEnabled, Date() < loaded { pause(0.5) }
        guard cleanUp.isEnabled else { return }
        cleanUp.tap()
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All sessions'")).firstMatch)
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch)
        pause(3)
        XCTAssertFalse(pi.buttons["Clean Up"].isEnabled, "sessions remain")
    }

    /// The screen recording App Review asks for, made on a phone while the Mac records its screen: pi opened from the
    /// Home Screen, Settings with a signed-in account, a session that charts the planets (shell, Python, a chart), a git
    /// clone, the browser, and an extension's permissions and source. Run after testAppReviewPrep, with an account
    /// signed in and its model the default. PI_REVIEW_EXTENSION names the extension shown (default flights);
    /// PI_REVIEW_RECORD_SCREEN=1 starts and stops iOS's screen recording from Control Center (otherwise start it first).
    /// "REVIEW:" lines mark each step, for cutting the video.
    func testAppReviewRecording() throws {
        executionTimeAllowance = 15 * 60
        let extensionName = ProcessInfo.processInfo.environment["PI_REVIEW_EXTENSION"] ?? "flights"
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        pi.terminate()
        XCUIDevice.shared.press(.home)
        pause(2)
        // iOS's own screen recording (the red indicator in the status bar), from Control Center, unless it's already on.
        let recordScreen = ProcessInfo.processInfo.environment["PI_REVIEW_RECORD_SCREEN"] == "1"
        if recordScreen { toggleScreenRecording(springboard) }
        pause(4)
        print("REVIEW: home screen")
        let icon = springboard.icons["pi"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "pi on the Home Screen")
        // Over to its page, like a person would.
        for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft(velocity: .slow); pause(1.5) }
        pause(1)
        icon.tap()
        let newSession = pi.buttons["New session"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 30), "pi open")
        let ready = Date().addingTimeInterval(60)
        while !newSession.isEnabled && Date() < ready { pause(0.5) }
        pause(2)

        print("REVIEW: settings")
        tap(pi.buttons["Settings"])
        pause(2)
        let addAccount = pi.buttons["Add account"].firstMatch
        for _ in 0..<4 where !(addAccount.exists && addAccount.isHittable) { pi.swipeUp(velocity: .slow); pause(1) }
        print("settings texts: \(pi.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label))")
        pause(3)
        tap(pi.buttons["Done"].firstMatch)
        pause(1.5)

        print("REVIEW: session")
        tap(newSession)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        let stop = pi.buttons["Stop"].firstMatch
        func ask(_ prompt: String, minutes: Double) {
            tap(message)
            pause(0.6)
            // A few words at a time, like a person typing, into the focused box (it loses its "Message pi" label once it
            // has text).
            let focused = pi.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            let words = prompt.split(separator: " ")
            for start in stride(from: 0, to: words.count, by: 6) {
                focused.typeText(words[start..<min(start + 6, words.count)].joined(separator: " ") + (start + 6 < words.count ? " " : ""))
                pause(0.1)
            }
            pause(1)
            tap(pi.buttons["Send"].firstMatch)
            if pi.buttons["Hide keyboard"].waitForExistence(timeout: 2) { pi.buttons["Hide keyboard"].tap() }
            _ = stop.waitForExistence(timeout: 30)
            let end = Date().addingTimeInterval(minutes * 60)
            while stop.exists && Date() < end { pause(1) }
            pause(3)
        }
        ask(Self.screenshotPrompts[2], minutes: 5)
        // The chart opens as an app: looked at, then minimized to the session.
        if pi.buttons["Minimize"].exists {
            pause(3)
            pi.buttons["Minimize"].firstMatch.tap()
            pause(2)
        }

        print("REVIEW: git")
        ask("Clone octocat/Spoon-Knife from GitHub and list its files.", minutes: 3)
        pi.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1.5)

        print("REVIEW: browser")
        let address = pi.textFields["Search or enter website"].firstMatch
        tap(address)
        pause(0.6)
        address.typeText("en.wikipedia.org/wiki/Planet\n")
        pause(6)
        pi.swipeUp(velocity: .slow)
        pause(2.5)
        tap(pi.buttons["Done"].firstMatch)
        pause(1.5)

        print("REVIEW: extensions")
        tap(pi.buttons["Settings"])
        pause(1.5)
        let extensions = pi.buttons["Extensions and skills"].firstMatch
        for _ in 0..<4 where !(extensions.exists && extensions.isHittable) { pi.swipeUp(velocity: .slow); pause(0.8) }
        tap(extensions)
        pause(2)
        print("extensions texts: \(pi.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))")
        let row = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", extensionName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(extensionName) among the extensions")
        for _ in 0..<5 where !row.isHittable { pi.swipeUp(velocity: .slow); pause(0.6) }
        pause(1)
        tap(row)
        pause(2)
        // Down past its permissions, to Source.
        let source = pi.buttons["Source"].firstMatch
        for _ in 0..<4 where !(source.exists && source.isHittable) { pi.swipeUp(velocity: .slow); pause(1) }
        pause(2.5)
        tap(source)
        pause(2)
        tap(pi.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ".ts")).firstMatch)
        pause(3)
        pi.swipeUp(velocity: .slow)
        pause(2)
        print("REVIEW: end")
        if recordScreen { toggleScreenRecording(springboard) }
        pause(2)
    }

    /// Starts or stops iOS's screen recording from Control Center (a swipe down from the top-right corner), which needs
    /// its Screen Recording control; started, the countdown runs before Control Center closes.
    private func toggleScreenRecording(_ springboard: XCUIApplication) {
        let corner = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.003))
        corner.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.55)))
        pause(1.5)
        let control = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Screen Recording")).firstMatch
        guard control.waitForExistence(timeout: 5) else {
            print("control center buttons: \(springboard.buttons.allElementsBoundByIndex.map(\.label))")
            XCTFail("Control Center has no Screen Recording control")
            return
        }
        print("screen recording control: \(control.label)")
        // Control Center opens on the page last used: up a page at a time (down, if need be) until the control shows.
        for _ in 0..<3 where !control.isHittable {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            pause(1)
        }
        for _ in 0..<3 where !control.isHittable {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            pause(1)
        }
        control.tap()
        pause(4.5)
        // Closed by tapping outside the controls, near the bottom (the countdown has run).
        if control.exists { springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap() }
        pause(1)
    }

    /// While the agent writes, the reader can scroll up and stay there (new output doesn't pull the transcript down); the
    /// arrow takes them back to the end, which follows again.
    func testScrollWhileStreaming() throws {
        executionTimeAllowance = 5 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("Write 50 numbered paragraphs, three sentences each, every one about a different animal. No tools.")
        tap(pi.buttons["Send"].firstMatch)
        if pi.buttons["Hide keyboard"].waitForExistence(timeout: 2) { pi.buttons["Hide keyboard"].tap() }
        let stop = pi.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "the run")
        // Followed, the request leaves the top once the answer is taller than the screen (the transcript's, not the title).
        let transcript = pi.scrollViews.firstMatch
        let request = transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Write 50 numbered")).firstMatch
        let tall = Date().addingTimeInterval(60)
        while request.isHittable && stop.exists && Date() < tall { pause(0.5) }
        XCTAssertFalse(request.isHittable, "followed to the end")

        // Up to the request, while the answer still streams.
        for _ in 0..<12 where !request.isHittable { transcript.swipeDown(velocity: .fast); pause(0.5) }
        XCTAssertTrue(request.isHittable, "scrolled up to the request")
        XCTAssertTrue(stop.exists, "still streaming")
        let place = request.frame.minY
        pause(4)
        print("request moved from \(place) to \(request.frame.minY)")
        XCTAssertEqual(request.frame.minY, place, accuracy: 2, "the transcript stayed where the reader left it")

        let arrow = pi.buttons["Scroll to the End"].firstMatch
        XCTAssertTrue(arrow.exists, "the arrow to the end")
        tap(arrow)
        pause(2)
        XCTAssertFalse(request.isHittable, "back at the end")
        XCTAssertFalse(arrow.exists, "following again")
        let done = Date().addingTimeInterval(2 * 60)
        while stop.exists && Date() < done { pause(1) }
    }

    /// Python's compiled modules, each a framework of its own (renamed for the App Store by the embed script), import in
    /// pi's shell: a `!` command, no model. Escaped, not quoted (the keyboard may make quotes curly).
    func testPythonModules() throws {
        executionTimeAllowance = 3 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("!python3 -c import\\ asyncio,ctypes,hashlib,sqlite3,ssl,compression.zstd\\;print\\(37\\*41\\)")
        tap(pi.buttons["Send"].firstMatch)
        let row = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "python3 -c")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the command's row")
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        // The row is collapsed: its output is read through Select Text, once the command has finished.
        var value = ""
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            pause(3)
            row.press(forDuration: 1.0)
            tap(pi.buttons["Select Text"].firstMatch)
            let text = pi.textViews.firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5), "the Select Text sheet")
            value = text.value as? String ?? ""
            tap(pi.buttons["Done"].firstMatch)
            if value.contains("1517") || value.contains("Error") { break }
        }
        print("python: \(value)")
        // 37 × 41: in the output only, not in the command.
        XCTAssertTrue(value.contains("1517"), "the modules imported")
        pause(1)
    }

    /// Settings → About → Acknowledgements: every component's license, searchable, each with its full text.
    func testAcknowledgements() throws {
        launchReady()
        tap(pi.buttons["Settings"])
        let link = pi.buttons["Acknowledgements"].firstMatch
        for _ in 0..<8 where !link.isHittable { pi.swipeUp(); pause(0.5) }
        tap(link)
        let first = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ios_system")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the components")
        let search = pi.searchFields.firstMatch
        tap(search)
        search.typeText("curl")
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "curl")).firstMatch)
        let text = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "COPYRIGHT AND PERMISSION NOTICE")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "curl's license text")
        pause(1)
    }

    /// An extension's source in Settings → Extensions: its files listed, one opened, changed and saved (the extension
    /// loads again), then changed back.
    func testExtensionSource() throws {
        launchReady()
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        // A default's row is a toggle: its name opens it.
        let row = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "personal-details")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Personal details among the extensions")
        for _ in 0..<5 where !row.isHittable { pi.swipeUp(); pause(0.5) }
        tap(row)
        tap(pi.buttons["Source"].firstMatch)
        let file = pi.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ".ts")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), "the extension's files")
        print("source files: \(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", ".")).allElementsBoundByIndex.map(\.label))")
        tap(file)
        let editor = pi.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the file's text")
        let original = editor.value as? String ?? ""
        XCTAssertTrue(original.contains("export default"), "the extension's code")
        // A tap on a line of text focuses the editor (one in its middle, in the simulator, did not).
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap()
        pause(1)
        let mark = "// edited in Settings\n"
        editor.typeText(mark)
        tap(pi.buttons["Save"].firstMatch)
        XCTAssertTrue(pi.staticTexts["Saved and loaded."].waitForExistence(timeout: 20), "saved, and the extension loaded again")
        pause(2)
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: mark.count))
        tap(pi.buttons["Save"].firstMatch)
        pause(3)
        XCTAssertEqual(editor.value as? String, original, "changed back")
        pause(1)
    }

    /// The agent adding an extension from the internet asks first; declined, nothing is added.
    func testExtensionConsent() throws {
        executionTimeAllowance = 6 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("Call the extension_add tool once with source github:example/pi-extension-demo, then tell me exactly what it returned.")
        tap(pi.buttons["Send"].firstMatch)
        let alert = pi.alerts["Add this extension?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 120), "pi asks before adding an extension from GitHub")
        print("consent: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
        pause(2)
        alert.buttons["Cancel"].tap()
        let stop = pi.buttons["Stop"].firstMatch
        let end = Date().addingTimeInterval(3 * 60)
        while stop.exists && Date() < end { pause(1) }
        pause(2)
        let declined = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "allow")).firstMatch
        XCTAssertTrue(declined.waitForExistence(timeout: 10), "the agent heard the user didn't allow it")
        print("reply: \(declined.label)")
        // pip takes pure-Python packages only: numpy (compiled) has none, six does.
        tap(message)
        message.typeText("!pip install --user numpy 2>&1 | tail -1; pip install --user six 2>&1 | tail -1")
        tap(pi.buttons["Send"].firstMatch)
        // The command's card, opened once pip is done.
        pause(60)
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        tap(pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "pip install --user numpy")).firstMatch)
        let refused = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No matching distribution found for numpy")).firstMatch
        let shown = refused.waitForExistence(timeout: 60)
        print("pip texts: \(pi.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("pip") || $0.contains("numpy") || $0.contains("ERROR") || $0.contains("six") })")
        XCTAssertTrue(shown, "pip refused numpy's compiled wheels")
        let installed = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Successfully installed six")).firstMatch
        XCTAssertTrue(installed.waitForExistence(timeout: 60), "pip installed six")
        pause(2)
    }

    /// An extension's app page asks for the microphone and the location (Fixtures/permtest.ts, packed by make-piext.py and
    /// opened with -openSharedFile from SHARED_FILE): pi asks the user about each, once; a refusal reaches the page, and
    /// Settings → Extensions → permtest → Permissions changes it. The shell grants pi itself the microphone and location
    /// (simctl privacy), sets the simulator's location, and clears pi's earlier answers.
    func testExtensionPermissions() throws {
        executionTimeAllowance = 6 * 60
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        let message = pi.textFields["Message pi"]
        func openApp() {
            tap(message)
            message.typeText("/permtest")
            tap(pi.buttons["Send"].firstMatch)
        }
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        openApp()
        let mic = pi.webViews.buttons["Microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 30), "the test app's page")
        let output = pi.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "mic", "location")).firstMatch

        mic.tap()
        let askMic = pi.alerts["Allow “permtest” to use the microphone?"]
        XCTAssertTrue(askMic.waitForExistence(timeout: 10), "pi asks before the page gets the microphone")
        pause(1)
        askMic.buttons["Allow"].tap()
        XCTAssertTrue(output.waitForExistence(timeout: 15), "the page's result")
        print("microphone: \(output.label)")
        XCTAssertTrue(output.label.hasPrefix("mic: granted"), "the page has the microphone")

        pi.webViews.buttons["Location"].tap()
        let askLocation = pi.alerts["Allow “permtest” to use your location?"]
        XCTAssertTrue(askLocation.waitForExistence(timeout: 10), "pi asks before the page gets the location")
        pause(1)
        askLocation.buttons["Don’t Allow"].tap()
        let refused = pi.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "location error")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 10), "the refusal reaches the page")
        print("location refused: \(refused.label)")

        // Asked once: the page asks again, and pi doesn't.
        mic.tap()
        pause(2)
        XCTAssertFalse(pi.alerts.firstMatch.exists, "no second question")

        tap(pi.buttons["Minimize"].firstMatch)
        pi.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        let row = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "permtest")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "permtest among the extensions")
        for _ in 0..<5 where !row.isHittable { pi.swipeUp(); pause(0.5) }
        tap(row)
        let micRow = permissionRow("Microphone")
        let locationRow = permissionRow("Location")
        XCTAssertTrue(locationRow.waitForExistence(timeout: 10), "its Permissions")
        print("permissions: \(micRow.label); \(locationRow.label)")
        XCTAssertTrue(micRow.label.hasSuffix("Allow") && !micRow.label.hasSuffix("Don’t Allow"), "the microphone allowed")
        XCTAssertTrue(locationRow.label.hasSuffix("Don’t Allow"), "the location refused")
        setPermission(locationRow, to: "Allow")
        XCTAssertTrue(permissionRow("Location").label.hasSuffix("Allow") && !permissionRow("Location").label.hasSuffix("Don’t Allow"),
                      "allowed in Settings")
        pause(1)
        // Back to Settings, and out.
        for _ in 0..<3 where !pi.buttons["Done"].exists {
            pi.navigationBars.buttons.element(boundBy: 0).tap()
            pause(1)
        }
        tap(pi.buttons["Done"].firstMatch)
        pause(1)

        // Another session's page of the same extension: allowed now, without a question.
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        openApp()
        // The first session's page still runs, parked behind everything (and counted as hittable): the page on screen,
        // in the sheet presented since, comes last.
        let pages = pi.webViews.buttons.matching(identifier: "Location")
        let end = Date().addingTimeInterval(30)
        while pages.count < 2 && Date() < end { pause(0.5) }
        let location = try XCTUnwrap(pages.allElementsBoundByIndex.last, "the test app again")
        pause(1)
        location.tap()
        let found = pi.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "location: ")).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 30), "the page has the location")
        print("location: \(found.label)")
        XCTAssertFalse(pi.alerts.firstMatch.exists, "no question: allowed in Settings")
        pause(1)

        // From the extension's own code: the same answer holds.
        tap(pi.buttons["Minimize"].firstMatch)
        tap(message)
        message.typeText("/permwhere")
        tap(pi.buttons["Send"].firstMatch)
        let notified = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "where")).firstMatch
        XCTAssertTrue(notified.waitForExistence(timeout: 30), "the extension's notice")
        print("from the extension: \(notified.label)")
        XCTAssertTrue(notified.label.hasPrefix("where: 37."), "the extension's code has the location")
        pause(2)
    }

    /// A background check (Fixtures/checktest.ts, packed by make-piext.py, opened with -openSharedFile from SHARED_FILE)
    /// in Settings → Extensions: Run Now asks the user about the extension's notifications, then iOS for pi's, and the
    /// notification shows; the row has its result. Then a launch with -runDueChecks runs it as when iOS wakes pi, without
    /// asking again. The shell clears pi's earlier answers.
    func testBackgroundCheck() throws {
        executionTimeAllowance = 6 * 60
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        dismissShortcutLeftovers(springboard)
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        // Below the extensions, which the list draws as they scroll in.
        let runNow = pi.buttons["Run Now"].firstMatch
        _ = pi.staticTexts["Every session"].waitForExistence(timeout: 15)
        for _ in 0..<12 where !(runNow.exists && runNow.isHittable) { pi.swipeUp(); pause(0.7) }
        XCTAssertTrue(runNow.exists, "the check in Settings")
        tap(runNow)
        let ask = pi.alerts["Allow “checktest” to send you notifications?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 15), "pi asks about the extension's notifications")
        pause(1)
        ask.buttons["Allow"].tap()
        // iOS's own question for pi, the first time any extension notifies.
        let system = springboard.alerts.firstMatch
        if system.waitForExistence(timeout: 5) {
            print("iOS asks: \(system.label)")
            system.buttons["Allow"].tap()
        }
        let ran = NSPredicate(format: "label CONTAINS %@", "Background check ran at")
        let banner = springboard.descendants(matching: .any).matching(ran).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the notification")
        print("notification: \(banner.label)")
        let status = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "notified at")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the check's result in Settings")
        print("check status: \(status.label)")
        pause(5)

        // As when iOS wakes pi: a launch that runs the due checks, with the answer kept.
        pi.terminate()
        pi.launchArguments = ["-runDueChecks", "YES"]
        pi.launch()
        let again = springboard.descendants(matching: .any).matching(ran).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 60), "the notification from the launch's run")
        print("notification again: \(again.label)")
        XCTAssertFalse(pi.alerts.firstMatch.exists, "no question this time")
        pause(2)
    }

    /// Notifications allowed ahead of time in an extension's Settings (Fixtures/checktest.ts, from SHARED_FILE): its
    /// Permissions list every permission as Ask; set to Allow, Run Now notifies without a question.
    func testAllowNotificationsAhead() throws {
        executionTimeAllowance = 4 * 60
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        dismissShortcutLeftovers(springboard)
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        tap(pi.buttons["Settings"])
        tap(pi.buttons["Extensions and skills"].firstMatch)
        let row = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "checktest")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "checktest among the extensions")
        for _ in 0..<5 where !row.isHittable { pi.swipeUp(); pause(0.5) }
        tap(row)
        let notifications = permissionRow("Notifications")
        XCTAssertTrue(notifications.waitForExistence(timeout: 10), "every permission listed, asked or not")
        print("before: \(notifications.label)")
        XCTAssertTrue(notifications.label.hasSuffix("Ask"), "not asked yet")
        setPermission(notifications, to: "Allow")
        print("after: \(permissionRow("Notifications").label)")
        pi.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        let runNow = pi.buttons["Run Now"].firstMatch
        for _ in 0..<12 where !(runNow.exists && runNow.isHittable) { pi.swipeUp(); pause(0.7) }
        tap(runNow)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Background check ran at")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the notification")
        XCTAssertFalse(pi.alerts.firstMatch.exists, "no question: allowed ahead")
        pause(2)
    }

    /// Tapping an extension's notification (Fixtures/checktest.ts, from SHARED_FILE): one posted from a session (/notifyme)
    /// opens that session from the sessions list; one with a prompt (/notifyask) opens it and sends it the prompt; one
    /// with session "new" and a prompt (/notifyprompt) opens a new session that gets it.
    func testNotificationTap() throws {
        executionTimeAllowance = 6 * 60
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        dismissShortcutLeftovers(springboard)
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        let message = pi.textFields["Message pi"]
        func send(_ text: String) {
            tap(message)
            message.typeText(text)
            tap(pi.buttons["Send"].firstMatch)
        }
        // Answers pi's question about the extension's notifications, and iOS's for pi, when they come.
        func allowNotifications() {
            let ask = pi.alerts["Allow “checktest” to send you notifications?"]
            if ask.waitForExistence(timeout: 8) { ask.buttons["Allow"].tap() }
            let system = springboard.alerts.firstMatch
            if system.waitForExistence(timeout: 3) { system.buttons["Allow"].tap() }
        }
        func banner(_ text: String) -> XCUIElement {
            springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }

        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        send("!echo marker for notifyme")
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "echo marker for notifyme")).firstMatch
            .waitForExistence(timeout: 20), "the session's command")
        send("/notifyme")
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        backToSessions()
        allowNotifications()
        let back = banner("Back to the session")
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the notification")
        back.tap()
        let marker = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "echo marker for notifyme")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "tapping it opened its session")
        pause(2)

        send("/notifyask")
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        backToSessions()
        let here = banner("Tap to ask here")
        XCTAssertTrue(here.waitForExistence(timeout: 20), "the notification with a prompt for its session")
        here.tap()
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply with exactly the word here")).firstMatch
            .waitForExistence(timeout: 20), "its session got the message")
        XCTAssertTrue(marker.exists, "the same session")
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "here")).firstMatch.waitForExistence(timeout: 120),
                      "the agent answered it there")
        pause(2)

        send("/notifyprompt")
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        backToSessions()
        let ask = banner("Tap to ask pi")
        XCTAssertTrue(ask.waitForExistence(timeout: 20), "the notification with a prompt")
        ask.tap()
        let prompt = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply with exactly the word tapped")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "a new session with its message")
        XCTAssertFalse(marker.exists, "not the earlier session")
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "tapped")).firstMatch.waitForExistence(timeout: 120),
                      "the agent answered it")
        pause(2)
    }

    /// Opening a shared session (-openSharedFile, set by the shell to a .pisession in the app's tmp): the sheet, then the
    /// session, opened as a new one with its history.
    func testOpenSharedSession() throws {
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"] ?? UserDefaults.standard.string(forKey: "sharedFile"), "the file's path")
        pi.launchArguments += ["-openSharedFile", path]
        pi.launch()
        let open = pi.buttons["Open Session"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30), "the shared session's sheet")
        print("shared session sheet: \(pi.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))")
        pause(1.5)
        open.tap()
        XCTAssertTrue(pi.textFields["Message pi"].waitForExistence(timeout: 30), "the session opens")
        pause(3)
        print("opened shared session: \(pi.navigationBars.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    /// Personal details reads its entries from pi.synced (what follows the user's devices), not its file (the shell deletes
    /// it first): its card is still listed.
    func testPersonalSynced() throws {
        dismissShortcutLeftovers(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let message = pi.textFields["Message pi"]
        tap(message)
        message.typeText("/personal")
        tap(pi.buttons["Send"].firstMatch)
        let card = pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chase Sapphire Preferred")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the card, from synced storage")
        print("personal synced: \(card.label)")
        pause(1.5)
    }

    /// Session apps on a wide screen (an iPad): /flights opens the Flights app in a column beside the session, with the
    /// message box still usable; Minimize puts it in the dock, which opens it again; Close (its menu) ends it.
    func testAppsWide() throws {
        executionTimeAllowance = 10 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let field = pi.textFields["Message pi"]
        tap(field)
        field.typeText("/flights")
        pause(1)
        tap(pi.buttons["Send"].firstMatch)
        let minimize = pi.buttons["Minimize"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 20), "the app opened")
        pause(2)
        XCTAssertTrue(pi.textFields["First name"].exists, "its page")
        XCTAssertTrue(pi.textFields["Message pi"].isHittable, "beside the session, whose message box is still there")
        // Expanded across the screen, and back beside the session.
        tap(pi.buttons["Expand"].firstMatch)
        XCTAssertTrue(pi.buttons["Collapse"].firstMatch.waitForExistence(timeout: 5), "expanded")
        pause(1.5)
        XCTAssertTrue(pi.textFields["First name"].exists, "the same page, expanded")
        XCTAssertFalse(pi.textFields["Message pi"].isHittable, "across the session")
        tap(pi.buttons["Collapse"].firstMatch)
        XCTAssertTrue(pi.buttons["Expand"].firstMatch.waitForExistence(timeout: 5), "beside the session again")
        pause(1.5)
        XCTAssertTrue(pi.textFields["Message pi"].isHittable, "the message box again")
        tap(minimize)
        let dock = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Flights. Open app")).firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 5), "in the dock")
        XCTAssertFalse(minimize.exists, "the column closed")
        tap(dock)
        XCTAssertTrue(minimize.waitForExistence(timeout: 5), "opened from the dock")
        pause(1.5)
        // Expanded, Sessions goes back to the list, with the app beside its session again.
        tap(pi.buttons["Expand"].firstMatch)
        XCTAssertTrue(pi.buttons["Collapse"].firstMatch.waitForExistence(timeout: 5))
        pause(1)
        tap(pi.buttons["Sessions"].firstMatch)
        XCTAssertTrue(pi.buttons["Expand"].firstMatch.waitForExistence(timeout: 5), "beside its session")
        XCTAssertTrue(pi.buttons["New session"].firstMatch.waitForExistence(timeout: 5), "the sessions list")
        pause(1.5)
        // It opens beside the session again next time.
        tap(pi.buttons["Expand"].firstMatch)
        tap(pi.buttons["Collapse"].firstMatch)
        pause(1)
        tap(pi.buttons["App menu"].firstMatch)
        tap(pi.buttons["Close App"].firstMatch)
        pause(2)
        XCTAssertFalse(minimize.exists, "closed")
        XCTAssertFalse(dock.exists, "off the dock")
    }


    /// The message box with the keyboard up in an empty session (no gap above it). For looking at the recording.
    func testComposerKeyboard() throws {
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        tap(pi.textFields["Message pi"])
        pause(3)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        if hide.exists { tap(hide) }
        pause(3)
    }

    /// The iPad layout: a session opened from the sidebar, the keyboard up, then landscape. For looking at the recording.
    func testIPadLayout() throws {
        launchReady()
        let row = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", ProcessInfo.processInfo.environment["PI_SESSION"] ?? "In two")).firstMatch
        tap(row)
        pause(3)
        tap(pi.textFields["Message pi"])
        pause(3)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        if hide.exists { tap(hide) }
        pause(1)
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(4)
        tap(pi.textFields["Message pi"])
        pause(3)
        if hide.exists { tap(hide) }
        pause(2)
        XCUIDevice.shared.orientation = .portrait
        pause(2)
    }

    /// Simulator setup: a device passcode (PI_PASSCODE, default 123456) in Settings → Face ID & Passcode, which keys
    /// behind Face ID need.
    func testSimulatorPasscode() throws {
        let code = ProcessInfo.processInfo.environment["PI_PASSCODE"] ?? "123456"
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        pause(2)
        let row = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["Face ID & Passcode", "Touch ID & Passcode", "Passcode"])).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { settings.swipeUp(velocity: .slow); pause(0.6) }
        row.tap()
        pause(2)
        let turnOn = settings.staticTexts["Turn Passcode On"].firstMatch
        if !turnOn.waitForExistence(timeout: 5) { print("passcode already set? \(settings.debugDescription.prefix(2000))"); return }
        turnOn.tap()
        pause(2)
        settings.typeText(code)
        pause(2)
        settings.typeText(code)
        pause(3)
        print("passcode set")
    }

    /// A system dialog on screen (an MDM's install prompt, say), answered as declineSystemDialog does, with a screenshot of
    /// the screen before and after, without touching pi.
    func testSystemDialog() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let found = springboard.alerts.firstMatch.waitForExistence(timeout: 5)
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "before"
        before.lifetime = .keepAlways
        add(before)
        print("system dialog: \(found ? springboard.alerts.firstMatch.label : "none") \(springboard.alerts.firstMatch.buttons.allElementsBoundByIndex.map(\.label))")
        continueAfterFailure = true
        declineSystemDialog()
        pause(2)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "after"
        after.lifetime = .keepAlways
        add(after)
    }

    /// Handles a system dialog over pi (see declineSystemDialog), then scrolls the open session to its end, for reading
    /// how a run finished.
    func testShowEnd() throws {
        _ = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.waitForExistence(timeout: 2)
        declineSystemDialog()
        pi.activate()
        pause(1)
        for _ in 0..<4 {
            pi.swipeUp(velocity: .fast)
            pause(0.8)
        }
        pause(3)
        for _ in 0..<3 {
            pi.swipeDown(velocity: .slow)
            pause(2.5)
        }
    }

    /// Settings → Crabbox → Machines from: the provider new machines come from (PI_CRABBOX_PROVIDER, default Google Cloud).
    func testSetCrabboxProvider() throws {
        let provider = ProcessInfo.processInfo.environment["PI_CRABBOX_PROVIDER"] ?? "Google Cloud"
        pi.launch()
        tap(pi.buttons["Settings"])
        pause(1.5)
        let picker = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Machines from'")).firstMatch
        for _ in 0..<10 where !(picker.exists && picker.isHittable) {
            pi.swipeUp(velocity: .slow)
            pause(0.5)
        }
        tap(picker)
        pause(1)
        tap(pi.buttons[provider].firstMatch, orText: provider)
        pause(1)
        XCTAssertTrue(picker.label.contains(provider), "Machines from shows \(picker.label)")
        tap(pi.buttons["Done"])
    }

    // MARK: - Helpers

    /// Launches pi and waits until it is ready: its engine started and sessions loaded ("New session" enabled), which
    /// takes longer on the first launch after an update.
    /// For `seconds` after a shortcut runs: pi stays in the background, and no popup shows `reply`.
    private func expectNoReplyShown(_ reply: String, in apps: [XCUIApplication], for seconds: TimeInterval) {
        let match = NSPredicate(format: "label ==[c] %@", reply)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            XCTAssertNotEqual(pi.state, .runningForeground, "pi stayed in the background")
            for app in apps where app.staticTexts.matching(match).firstMatch.exists {
                return XCTFail("a popup shows the reply (\(app == apps.first ? "springboard" : "shortcuts"))")
            }
            pause(1)
        }
    }

    /// A permission's row in an extension's Settings (its menu: Ask, Allow, Don't Allow), labeled with the answer.
    private func permissionRow(_ title: String) -> XCUIElement {
        pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
    }

    private func setPermission(_ row: XCUIElement, to answer: String) {
        tap(row)
        tap(pi.buttons[answer].firstMatch)
        pause(1)
    }

    /// Home Screen widgets (pi.widget): SHARED_FILE is widgettest.piext (Fixtures/widgettest.ts). A layout pi refuses
    /// reaches the extension as an error; its command draws the widget and opens its app, whose menu shows the widget as
    /// it looks (Add to Home Screen…). On the Home Screen, the widget added from the gallery shows what the extension
    /// drew, and a tap opens the app full screen; Back to pi goes to its session.
    func testHomeScreenWidget() throws {
        executionTimeAllowance = 10 * 60
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        let message = pi.textFields["Message pi"]
        func command(_ text: String) {
            tap(message)
            message.typeText(text)
            tap(pi.buttons["Send"].firstMatch)
        }
        func notice(_ prefix: String) -> XCUIElement {
            pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)

        command("/widgetbad")
        let refused = notice("widget error")
        XCTAssertTrue(refused.waitForExistence(timeout: 20), "the refusal reaches the extension")
        print("refused: \(refused.label)")
        XCTAssertTrue(refused.label.contains("unknown type \"txt\""), "named, with where it is")
        pause(4)

        command("/widgettest")
        let drawn = notice("widget drawn")
        XCTAssertTrue(drawn.waitForExistence(timeout: 20), "the extension drew its widget")
        print("drawn: \(drawn.label)")
        XCTAssertFalse(drawn.label.contains("not saved"), "pi saved it (in the App Group)")
        // The app, in its sheet: its menu's Add to Home Screen… shows the widget as it looks.
        tap(pi.buttons["App menu"].firstMatch)
        tap(pi.buttons["Add to Home Screen…"].firstMatch)
        let preview = pi.descendants(matching: .any)["widget-preview-medium"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "the widget's preview")
        XCTAssertTrue(pi.staticTexts["TLV → LHR"].firstMatch.exists, "the preview shows what the extension drew")
        pause(1)
        shot("add-to-home-screen")
        tap(pi.buttons["Done"].firstMatch)
        pause(1.5)

        // The Home Screen: the widget, added from the gallery.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        pause(2)
        // A widget an earlier run left.
        removePiWidget(springboard)
        addPiWidget(springboard)
        shot("home-screen-widget")
        func widgetText(_ text: String) -> XCUIElement {
            springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        let widget = widgetText("TLV")
        XCTAssertTrue(widget.waitForExistence(timeout: 20), "the widget shows what the extension drew")
        print("widget: \(widget.label)")
        XCTAssertTrue(widgetText("Draw 1").waitForExistence(timeout: 10), "its first draw")

        // Its refresh button runs the extension's action in pi, which draws it again, without opening pi.
        let refresh = springboard.buttons["Refresh flights"].firstMatch
        if !refresh.waitForExistence(timeout: 10) { print("SPRINGBOARD (no refresh button):\n\(springboard.debugDescription)") }
        refresh.tap()
        XCTAssertTrue(widgetText("Draw 2").waitForExistence(timeout: 30), "the action ran in pi and drew the widget again")
        XCTAssertNotEqual(pi.state, .runningForeground, "pi stayed in the background")
        print("pi after the action: \(pi.state.rawValue)")
        shot("widget-refreshed")
        // Details: another look, and Back to the main one, in the widget itself.
        tap(springboard.buttons["Details"].firstMatch)
        XCTAssertTrue(widgetText("Gate B7").waitForExistence(timeout: 10), "the widget's other look")
        shot("widget-details")
        tap(springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Back")).firstMatch)
        XCTAssertTrue(widget.waitForExistence(timeout: 10), "the main look again")
        XCTAssertNotEqual(pi.state, .runningForeground, "pi stayed in the background")

        widget.tap()

        // pi, with only the app, full screen.
        let back = pi.buttons["Back to pi"]
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the app full screen, with a way back")
        XCTAssertTrue(pi.webViews.staticTexts["Flights board"].waitForExistence(timeout: 15), "its page")
        pause(1.5)
        print("page: \(pi.webViews.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("app-full-screen")
        back.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 10), "back in the app's session")
        XCTAssertTrue(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Flights")).firstMatch.waitForExistence(timeout: 10),
                      "the app in the session's dock")
        pause(1)
        shot("back-to-pi")

        // From a cold start: pi launches into the app.
        pi.terminate()
        pause(2)
        if !widget.waitForExistence(timeout: 10) {
            shot("after-terminate")
            print("SPRINGBOARD (after terminate):\n\(springboard.debugDescription)")
        }
        XCTAssertTrue(widget.exists, "the widget, still there")
        widget.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 60), "pi launched into the app, full screen")
        XCTAssertTrue(pi.webViews.staticTexts["target: LY315"].waitForExistence(timeout: 30), "its page, with the tap area's target")
        pause(1.5)
        shot("cold-start")
        back.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 10), "back in the app's session")

        // The action with pi not running: iOS launches it in the background for it (the extension starts over).
        pi.terminate()
        pause(2)
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), "the refresh button")
        refresh.tap()
        XCTAssertTrue(widgetText("Draw 1").waitForExistence(timeout: 60), "pi, launched in the background, ran the action")
        XCTAssertNotEqual(pi.state, .runningForeground, "pi stayed in the background")
        print("pi after the action from a cold start: \(pi.state.rawValue)")
        shot("widget-refreshed-cold")
        removePiWidget(springboard)
    }

    /// Live Activities (pi.liveActivity): SHARED_FILE is widgettest.piext (Fixtures/widgettest.ts). Its command starts
    /// one (pi asks the first time); with pi in the background it's in the Dynamic Island, whose expanded view's button
    /// runs the extension's action in pi, which draws it again, and in Notification Center (as on the Lock Screen). A
    /// tap opens the app full screen; the commands update it (with an alert) and end it.
    func testLiveActivity() throws {
        executionTimeAllowance = 8 * 60
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        let message = pi.textFields["Message pi"]
        func command(_ text: String) {
            tap(message)
            message.typeText(text)
            tap(pi.buttons["Send"].firstMatch)
        }
        func notice(_ prefix: String) -> XCUIElement {
            pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func text(_ label: String) -> XCUIElement {
            springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        }
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)

        command("/activitystart")
        let ask = pi.alerts["Allow “widgettest” to show Live Activities on your Lock Screen?"]
        if ask.waitForExistence(timeout: 15) {
            pause(1)
            ask.buttons["Allow"].tap()
        }
        let started = notice("activity")
        XCTAssertTrue(started.waitForExistence(timeout: 20), "the extension heard back")
        print("start: \(started.label)")
        XCTAssertTrue(started.label.hasPrefix("activity started"), "the Live Activity started")
        pause(2)

        // The Dynamic Island, with pi in the background.
        XCUIDevice.shared.press(.home)
        pause(2)
        let compact = text("B7")
        if !compact.waitForExistence(timeout: 10) { print("SPRINGBOARD (no island):\n\(springboard.debugDescription)") }
        XCTAssertTrue(compact.exists, "the compact Dynamic Island")
        shot("island-compact")
        // Expanded (touch and hold): its button runs the extension's action in pi.
        compact.press(forDuration: 1.5)
        let refresh = springboard.buttons["Refresh activity"].firstMatch
        if !refresh.waitForExistence(timeout: 10) { print("SPRINGBOARD (no expanded island):\n\(springboard.debugDescription)") }
        XCTAssertTrue(text("Gate B7").exists, "the expanded Dynamic Island")
        shot("island-expanded")
        refresh.tap()
        XCTAssertTrue(text("Refreshed 1").waitForExistence(timeout: 30), "the action ran in pi and drew it again")
        XCTAssertNotEqual(pi.state, .runningForeground, "pi stayed in the background")
        pause(1)
        shot("island-refreshed")
        XCUIDevice.shared.press(.home)
        pause(2)

        // As on the Lock Screen: in Notification Center.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        pause(2)
        XCTAssertTrue(text("LY315 to London").waitForExistence(timeout: 10), "the Lock Screen's view")
        shot("lock-screen-view")
        // A tap opens the app full screen.
        text("LY315 to London").tap()
        let back = pi.buttons["Back to pi"]
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the app full screen")
        pause(1)
        back.tap()

        command("/activityupdate")
        XCTAssertTrue(notice("activity updated").waitForExistence(timeout: 20), "updated, with an alert")
        pause(3)
        command("/activityend")
        let ended = notice("activity ended")
        XCTAssertTrue(ended.waitForExistence(timeout: 20), "ended")
        XCTAssertEqual(ended.label, "activity ended 1")
        XCUIDevice.shared.press(.home)
        pause(2)
        XCTAssertFalse(text("B7").exists, "gone from the Dynamic Island")
    }

    /// Typing in a very long session stays quick: SHARED_FILE is floodtest.piext (Fixtures/floodtest.ts), whose /flood
    /// fills a session with thousands of messages. Times typing a sentence in the message box (XCUITest waits for the
    /// app between keystrokes, so slow keystrokes show), in the session as it filled and after a relaunch (its whole
    /// transcript loaded), and prints the times. FLOOD_COUNT sets how many (default 3000).
    func testLongSessionTyping() throws {
        executionTimeAllowance = 30 * 60
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHARED_FILE"], "the test extension's .piext")
        let count = Int(ProcessInfo.processInfo.environment["FLOOD_COUNT"] ?? "") ?? 3000
        pi.launchArguments += ["-openSharedFile", path]
        launchReady()
        tap(pi.buttons["Add to Every Session"].firstMatch)
        pause(2)
        if pi.buttons["Done"].exists { pi.buttons["Done"].firstMatch.tap() }
        let message = pi.textFields["Message pi"]
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        tap(message)
        message.typeText("/flood \(count)")
        tap(pi.buttons["Send"].firstMatch)
        let flooded = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "flooded")).firstMatch
        XCTAssertTrue(flooded.waitForExistence(timeout: 5 * 60), "the extension sent them")
        // They arrive after the notice: until the last one is in the transcript.
        let last = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Entry \(count - 1)\n")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 20 * 60), "the last message arrived")
        pause(5)
        let sentence = "The quick brown fox jumps over the lazy dog 0123456789"
        func timeTyping(_ label: String) {
            tap(message)
            pause(1)
            let start = Date()
            message.typeText(sentence)
            let seconds = Date().timeIntervalSince(start)
            print("typing \(label): \(String(format: "%.2f", seconds)) s for \(sentence.count) characters")
            // With text in it, the box no longer goes by its placeholder.
            pi.textFields.firstMatch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: sentence.count))
        }
        timeTyping("as it filled")
        pi.terminate()
        pause(2)
        launchReady()
        backToSessions()
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Flood test")).firstMatch)
        XCTAssertTrue(message.waitForExistence(timeout: 60), "the session, opened again")
        pause(5)
        timeTyping("after a relaunch")
        // pi's own CPU time for typing the sentence and deleting it (the clock time is mostly the test's).
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: pi), XCTClockMetric()], options: options) {
            pi.textFields.firstMatch.typeText(sentence)
            pi.textFields.firstMatch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: sentence.count))
        }

        // Only its latest rows loaded (150): at their top (a tap on the status bar), Earlier messages loads the page before,
        // with the row that was first staying at the top; scrolling up shows the earlier rows.
        if pi.buttons["Hide keyboard"].exists { pi.buttons["Hide keyboard"].tap() }
        func shownEntries() -> [Int] {
            pi.staticTexts.allElementsBoundByIndex.compactMap { element in
                element.label.firstMatch(of: /^Entry (\d+)\n/).flatMap { Int($0.1) }
            }
        }
        pi.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        let more = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Earlier messages")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "more to load, at the top")
        pause(1)
        let top = shownEntries().min() ?? 0
        print("at the top: rows from \(top)")
        XCTAssertEqual(top, count - 150, "the latest 150 rows")
        // The row that was first, still on screen (the lazy stack estimates the new rows' heights, so it lands within a
        // row of where it was; and it lays out a few rows above the screen, so the lowest number shown isn't the top one).
        let firstRow = pi.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Entry \(top)\n")).firstMatch
        let before = firstRow.frame.minY
        more.tap()
        pause(2)
        print("after Earlier messages: rows from \(shownEntries().min() ?? 0); the first row moved \(Int(firstRow.frame.minY - before)) points")
        XCTAssertTrue(firstRow.isHittable, "the row that was first, still on screen")
        pi.swipeDown()
        pause(1)
        XCTAssertLessThan(shownEntries().min() ?? top, top, "the earlier rows, above")
    }

    /// Adds pi's widget to the Home Screen from the widget gallery (Edit → Add Widget → pi).
    private func addPiWidget(_ springboard: XCUIApplication) {
        func dump(_ what: String) { print("SPRINGBOARD (\(what)):\n\(springboard.debugDescription)") }
        // Touch and hold an empty spot until the icons jiggle.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 2)
        pause(1.5)
        let edit = springboard.buttons["Edit"].firstMatch
        guard edit.waitForExistence(timeout: 5) else { return dump("no Edit") }
        edit.tap()
        pause(1)
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch
        guard add.waitForExistence(timeout: 5) else { return dump("no Add Widget") }
        add.tap()
        pause(2)
        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 5) else { return dump("no search") }
        search.tap()
        search.typeText("pi")
        pause(2)
        let result = springboard.cells.matching(NSPredicate(format: "label ==[c] %@ OR label BEGINSWITH[c] %@", "pi", "pi,")).firstMatch
        guard result.waitForExistence(timeout: 5) else { return dump("no pi result") }
        result.tap()
        pause(2)
        dump("pi's widgets")
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch
        guard addWidget.waitForExistence(timeout: 5) else { return dump("no Add Widget button") }
        addWidget.tap()
        pause(2)
        let done = springboard.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        pause(2)
    }

    /// Takes the test's widget off the Home Screen again.
    private func removePiWidget(_ springboard: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        pause(2)
        let widget = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "TLV")).firstMatch
        guard widget.waitForExistence(timeout: 5) else { return }
        widget.press(forDuration: 1.5)
        let remove = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Remove Widget")).firstMatch
        guard remove.waitForExistence(timeout: 5) else { return print("SPRINGBOARD (no Remove Widget):\n\(springboard.debugDescription)") }
        remove.tap()
        let confirm = springboard.alerts.buttons["Remove"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        pause(1)
    }

    /// From a session (pi may reopen on the last one shown) back to the sessions list.
    private func backToSessions() {
        pause(1.5)
        for _ in 0..<3 where !pi.buttons["New session"].isHittable && pi.navigationBars.buttons.element(boundBy: 0).exists {
            pi.navigationBars.buttons.element(boundBy: 0).tap()
            pause(1)
        }
    }

    private func launchReady() {
        pi.launch()
        let newSession = pi.buttons["New session"].firstMatch
        _ = newSession.waitForExistence(timeout: 20)
        let ready = Date().addingTimeInterval(60)
        while !(newSession.exists && newSession.isEnabled) && Date() < ready { pause(0.5) }
        pause(1.5)
    }

    /// Deletes the shortcuts testShortcutSession saved ("Ask pi 1", …), so pi's actions show at the top of the library.
    private func deleteTestShortcuts(_ shortcuts: XCUIApplication) {
        let saved = shortcuts.cells.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Ask pi", "action"))
        let done = shortcuts.buttons["library.button.done"]
        for _ in 0..<3 {
            guard saved.firstMatch.waitForExistence(timeout: 3) else { break }
            if !done.exists { shortcuts.buttons["Edit"].firstMatch.tap(); pause(1) }
            let tiles = shortcuts.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask pi"))
            for index in 0..<tiles.count where tiles.element(boundBy: index).isHittable { tiles.element(boundBy: index).tap() }
            let delete = shortcuts.buttons["Delete"].firstMatch
            guard delete.waitForExistence(timeout: 3) else { break }
            delete.tap()
            pause(1)
            // The confirmation ("Delete N Shortcuts").
            let confirm = shortcuts.sheets.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete")).firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            pause(2)
            if done.exists { done.tap(); pause(1) }
        }
    }

    /// A prompt or a reply card an earlier shortcut run left up.
    private func dismissShortcutLeftovers(_ apps: XCUIApplication...) {
        for app in apps {
            for label in ["Cancel", "Done"] where app.buttons[label].firstMatch.exists {
                app.buttons[label].firstMatch.tap()
                pause(1)
            }
        }
    }

    /// iOS's Passwords app may offer to save what was typed in a secure field: not now.
    private func dismissSavePassword() {
        for app in [pi, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = app.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) {
                notNow.tap()
                return
            }
        }
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func tap(_ element: XCUIElement, orText text: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: 10) {
            element.tap()
        } else if let text, pi.staticTexts[text].waitForExistence(timeout: 2) {
            pi.staticTexts[text].tap()
        } else {
            print("SCREEN:\n\(pi.debugDescription)")
            XCTFail("not on screen: \(element)", file: file, line: line)
        }
    }
}
