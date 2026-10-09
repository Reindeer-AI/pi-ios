import AppIntents

// Shortcuts' actions: send pi a message (in a new session or one chosen) and get its reply, and start a session to send
// messages to later. They open pi, which shows the session while the agent works.

struct AskPiIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask pi"
    static let description = IntentDescription(
        "Sends a message to pi, in a new session or one you choose, and gives back pi's reply once the agent is done.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @Parameter(title: "Session", description: "The session to send it to; a new session when empty.", default: nil)
    var session: SessionEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask pi \(\.$message) in \(\.$session)")
    }

    /// The reply, as the action's output and, run on its own (Siri, the Shortcuts app's pi actions), shown or spoken.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let app = AppModel.shared else { throw AppError.message("pi isn't running.") }
        let reply = try await app.ask(message, in: session?.id)
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply.isEmpty ? "Done." : reply))
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start pi Session"
    static let description = IntentDescription(
        "Starts a new pi session, to send messages to with Ask pi, so they continue one conversation.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var title: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        guard let app = AppModel.shared else { throw AppError.message("pi isn't running.") }
        let session = try await app.startSession(title: title)
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
