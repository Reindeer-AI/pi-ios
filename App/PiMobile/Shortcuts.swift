import AppIntents

// Shortcuts' actions: send pi a message (in a new session or one chosen) and get its reply, and start a session to send
// messages to later. They run without opening pi; a request the agent is still on after a while asks to continue in
// pi, since iOS gives a shortcut little time in the background.

struct AskPiIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask pi"
    static let description = IntentDescription(
        "Sends a message to pi, in a new session or one you choose, and gives back pi's reply once the agent is done, for the next action (Speak Text, Show Result, …).",
        categoryName: "Sessions"
    )
    /// In the background for a short question; in pi (asked for, `continueInForeground`) for a long one.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    /// How long a request runs in the background before pi asks to continue in the foreground.
    static let backgroundTime: Duration = .seconds(20)

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @Parameter(title: "Session", description: "The session to send it to; a new session when empty.", default: nil)
    var session: SessionEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask pi \(\.$message) in \(\.$session)")
    }

    /// The reply, as the action's output only: the shortcut decides what to do with it (Speak Text, Show Result, …).
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app = AppModel.shared else { throw AppError.message("pi isn't running.") }
        let message = message, sessionId = session?.id
        let background = systemContext.currentMode == .background
        let asking = Task { try await app.ask(message, in: sessionId, show: !background) }
        if background, !(await Self.finishes(asking, within: Self.backgroundTime)), systemContext.currentMode.canContinueInForeground {
            try await continueInForeground(IntentDialog("pi is still working on it. Open pi to see it finish?"), alwaysConfirm: false)
            if let id = app.askedSession { app.requestedSession = id }
        }
        return .result(value: try await asking.value)
    }

    /// Whether `task` ends within `duration` (it keeps running either way).
    @MainActor
    private static func finishes(_ task: Task<String, Error>, within duration: Duration) async -> Bool {
        let race = Race()
        return await withCheckedContinuation { continuation in
            Task { _ = try? await task.value; race.end(true, continuation) }
            Task { try? await Task.sleep(for: duration); race.end(false, continuation) }
        }
    }

    @MainActor
    private final class Race {
        private var ended = false

        func end(_ finished: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
            guard !ended else { return }
            ended = true
            continuation.resume(returning: finished)
        }
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start pi Session"
    static let description = IntentDescription(
        "Starts a new pi session, to send messages to with Ask pi, so they continue one conversation.",
        categoryName: "Sessions"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Title")
    var title: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        guard let app = AppModel.shared else { throw AppError.message("pi isn't running.") }
        let session = try await app.startSession(title: title, show: systemContext.currentMode == .foreground)
        return .result(value: SessionEntity(id: session.id, title: session.title))
    }
}

struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "pi Session"
    static let defaultQuery = SessionQuery()

    let id: Int
    @Property(title: "Title")
    var title: String

    init(id: Int, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// Sessions from the list pi keeps (the engine needn't run for Shortcuts to pick one).
struct SessionQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [SessionEntity] {
        let wanted = Set(identifiers)
        return await sessions().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SessionEntity] {
        await sessions().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [SessionEntity] {
        Array(await sessions().prefix(30))
    }

    @MainActor
    private func sessions() -> [SessionEntity] {
        AppModel.savedSessions().map { SessionEntity(id: $0.id, title: $0.title) }
    }
}

struct PiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPiIntent(),
            phrases: ["Ask \(.applicationName)", "Send a message to \(.applicationName)"],
            shortTitle: "Ask pi",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: ["Start a \(.applicationName) session"],
            shortTitle: "Start Session",
            systemImageName: "square.and.pencil"
        )
    }
}
