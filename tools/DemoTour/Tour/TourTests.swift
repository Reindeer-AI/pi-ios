import XCTest

/// Demo tours of pi, run on a phone or Simulator while its screen is recorded: XCUITest taps through the installed app
/// (by bundle ID), with pauses so a viewer can follow. Run one with
/// `xcodebuild test -project tools/DemoTour/DemoTour.xcodeproj -scheme DemoTour -destination … -only-testing:DemoTourUITests/TourTests/testSettingsAndSecrets`.
final class TourTests: XCTestCase {
    private let pi = XCUIApplication(bundleIdentifier: "dev.pimobile.PiMobile")

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

    /// The Gmail widget's buttons: the agent fills it with made-up messages (no browser), then Low signal → Archive all
    /// must send the request to the agent, and Reply must put a draft request in the message box.
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
    /// was; a sample triage puts Gmail in the dock with a badge; after a relaunch both are there and Flights still has its
    /// unsaved edit, which is saved; the agent opens the app; holding its dock entry closes it.
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
        let gmail = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Gmail")).firstMatch

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

        mark("gmail")
        send("Demo with sample data, don't use the browser: call gmail_triage once with accounts [dana@example.com], account dana@example.com, reviewed 24, and made-up messages: 2 requiring attention (Lee Park: contract signature needed; Google: security alert), 1 calendar invite (Design review, Thursday 10:00), 21 low signal (newsletters and receipts). Then just say done.")
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        waitForRun()
        mark("gmail-docked")
        pause(3)
        tap(gmail)
        pause(3)
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Invites")).firstMatch)
        pause(2.5)
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

    /// The Gmail scene of the apps demo, recorded on its own: a sample triage puts Gmail in the dock; it opens, shows its
    /// invites, and minimizes.
    func testAppsDemoGmail() throws {
        executionTimeAllowance = 10 * 60
        func mark(_ name: String) { print("MARK \(name) \(Date().timeIntervalSince1970)") }
        let stop = pi.buttons["Stop"].firstMatch
        let minimize = pi.buttons["Minimize"].firstMatch
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let field = pi.textFields["Message pi"]
        tap(field)
        field.typeText("Demo with sample data, don't use the browser: call gmail_triage once with accounts [dana@example.com], account dana@example.com, reviewed 24, and made-up messages: 2 requiring attention (Lee Park: contract signature needed; Google: security alert), 1 calendar invite (Design review, Thursday 10:00), 21 low signal (newsletters and receipts). Then just say done.")
        tap(pi.buttons["Send"].firstMatch)
        if pi.buttons["Hide keyboard"].firstMatch.waitForExistence(timeout: 2) { pi.buttons["Hide keyboard"].firstMatch.tap() }
        _ = stop.waitForExistence(timeout: 20)
        let end = Date().addingTimeInterval(4 * 60)
        while stop.exists && Date() < end { pause(1) }
        pause(2)
        mark("open")
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Gmail")).firstMatch)
        pause(3.5)
        mark("invites")
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Invites")).firstMatch)
        pause(3)
        mark("minimize")
        tap(minimize)
        pause(2)
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

    /// Shortcuts: a shortcut with pi's Ask pi action (a new session) runs, opens pi on the session, and returns the reply.
    func testShortcut() throws {
        executionTimeAllowance = 10 * 60
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // A prompt an earlier run left up.
        dismissShortcutLeftovers(springboard, shortcuts)
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
        XCTAssertTrue(pi.wait(for: .runningForeground, timeout: 30), "pi opens")
        let prompt = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply with exactly the word pong")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "pi shows the new session with the message")
        // The reply comes back to Shortcuts, which shows it (the action's dialog).
        let reply = NSPredicate(format: "label ==[c] %@", "pong")
        let end = Date().addingTimeInterval(180)
        var shown: XCUIElement?
        while shown == nil && Date() < end {
            for app in [springboard, shortcuts] {
                let match = app.staticTexts.matching(reply).firstMatch
                if match.exists { shown = match; print("shortcut reply shown by \(app == springboard ? "springboard" : "shortcuts")") }
            }
            if shown == nil { pause(1) }
        }
        print("SHORTCUTS 3 (springboard):\n\(springboard.debugDescription)")
        XCTAssertNotNil(shown, "the reply shown by Shortcuts")
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
        XCTAssertTrue(pi.wait(for: .runningForeground, timeout: 30), "pi opens")
        let followUp = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Now reply with exactly the word ping")).firstMatch
        XCTAssertTrue(followUp.waitForExistence(timeout: 30), "pi shows the chosen session with the message")
        XCTAssertTrue(pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reply with exactly the word pong")).firstMatch.exists,
                      "the same session: its earlier message is there")
        let reply = NSPredicate(format: "label ==[c] %@", "ping")
        let end = Date().addingTimeInterval(180)
        var shown = false
        while !shown && Date() < end {
            for app in [springboard, shortcuts] where app.staticTexts.matching(reply).firstMatch.exists {
                shown = true
                print("shortcut reply shown by \(app == springboard ? "springboard" : "shortcuts")")
            }
            if !shown { pause(1) }
        }
        XCTAssertTrue(shown, "the reply shown by Shortcuts")
        pause(2)
        dismissShortcutLeftovers(springboard, shortcuts)
    }

    /// Shortcuts: Start pi Session opens pi on a new, empty session.
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
        start.tap()
        XCTAssertTrue(pi.wait(for: .runningForeground, timeout: 30), "pi opens")
        XCTAssertTrue(pi.textFields["Message pi"].waitForExistence(timeout: 20), "on a session")
        XCTAssertTrue(pi.staticTexts["New session"].firstMatch.waitForExistence(timeout: 5), "a new one")
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

    func testGmailWidget() throws {
        executionTimeAllowance = 10 * 60
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let hide = pi.buttons["Hide keyboard"].firstMatch
        let stop = pi.buttons["Stop"].firstMatch
        let field = pi.textFields["Message pi"]
        tap(field)
        field.typeText("Widget test, don't use the browser: call gmail_triage once with accounts [you@example.com], account you@example.com, reviewed 20, and made-up messages: 2 requiring attention, 1 calendar invite, 17 low signal. Then just say done.")
        tap(pi.buttons["Send"].firstMatch)
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        _ = stop.waitForExistence(timeout: 20)
        let end = Date().addingTimeInterval(4 * 60)
        while stop.exists && Date() < end { pause(1) }
        pause(2)

        // The triage put the Gmail app in the dock, badged with what requires attention.
        let dock = pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Gmail")).firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 10), "Gmail in the dock")
        print("dock: \(dock.label)")
        tap(dock)
        pause(2)
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Low signal")).firstMatch)
        pause(1.5)
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Archive all")).firstMatch)
        pause(1)
        // The request shows in the session, under the app.
        tap(pi.buttons["Minimize"].firstMatch)
        let request = pi.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "low-signal messages")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 15), "Archive all sent a request")
        pause(3)
        if stop.exists { tap(stop) }
        pause(3)

        tap(dock)
        pause(2)
        tap(pi.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Attention")).firstMatch)
        pause(1.5)
        tap(pi.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply to")).firstMatch)
        pause(1.5)
        // With text in it, the message box is a text view.
        let box = pi.textViews.firstMatch.exists ? pi.textViews.firstMatch : pi.textFields.firstMatch
        let draft = (box.value as? String) ?? ""
        XCTAssertTrue(draft.hasPrefix("Draft a reply to"), "Reply filled the message box: \(draft)")
        pause(2)
    }

    /// The message box with the keyboard up: in an empty session (no gap above it), then with a widget (/gmail's) in its
    /// short strip. For looking at the recording.
    func testComposerKeyboard() throws {
        launchReady()
        tap(pi.buttons["New session"].firstMatch)
        pause(1.5)
        let field = pi.textFields["Message pi"]
        tap(field)
        pause(3)
        field.typeText("/gmail")
        pause(1)
        tap(pi.buttons["Send"].firstMatch)
        pause(4)
        let stop = pi.buttons["Stop"].firstMatch
        if stop.exists { tap(stop) }
        pause(3)
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
