import Foundation
import Observation
import UIKit
import OSLog
import PiEngineKit
import PiWatchLink

/// The app's state: the pi engine with its native services, every session (each its own durable pi agent with its
/// own workspace), model providers and accounts, and on-device models.
///
/// Launch arguments for automated runs: `-autorun "prompt"` (new session with the default model, the session
/// `-autorunSession ID`, or the fork `-fork SESSION:ENTRY` makes; `-autorunOnActive "prompt"` prompts it again each time
/// the app returns to the foreground), `-openSession ID`, `-uiAnswer VALUE`, `-baseURL URL`
/// (network endpoint), `-model ID`, `-localModel <downloaded .gguf>`, `-downloadModel <Hugging Face link>`,
/// `-shellTest YES` / `-shellCommands "a ;; b"`, `-storage NAME`, `-debugTools YES`,
/// `-testCrabboxBroker URL -testCrabboxToken TOKEN`, `-testCrabboxSignOut YES`, `-testGitHubToken TOKEN` (checked with
/// GitHub), `-testGitHubUncheckedToken TOKEN` (kept as is, for a test box), `-testGitHubSignOut YES`, `-engineCommands 'method {json} ;; …'`, `-testExtensionSecret NAME=VALUE`, `-abortAfter SECONDS`, `-afterAbort PROMPT`, `-steerAfter SECONDS -steer TEXT`, `-setNetworkEndpoint URL`, `-setDefaultModel PROVIDER:MODEL`. Milestones go to the unified log
/// (subsystem `dev.pimobile`) and stderr as `[tag] message` lines.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting, ready
        case failed(String)
    }

    struct ModelRef: Codable, Hashable {
        var provider: String
        var modelId: String
    }

    struct Session: Identifiable {
        let id: Int
        var title: String
        var model: ModelRef
        /// How much its model thinks: one of pi's levels (`ThinkingLevel`), "off" unless set.
        var thinkingLevel = "off"
        /// The browser profile key the session's agent browses with, or none.
        var browser: String?
        var createdAt: Date
        /// When the user last sent it a message (its creation, for sessions from before this was kept).
        var lastActive: Date
        var items: [TranscriptItem] = []
        /// Messages sent during a run that the agent hasn't taken yet, shown after the transcript until it does.
        var queued: [QueuedMessage] = []
        /// Extensions working for the user in this session (their commands, say), which Stop ends.
        var extensionTasks: [ExtensionTask] = []
        var draft: DraftMessage?
        var tools: [ToolRun] = []
        var running = false
        var loaded = false
        var error: String?
        /// How full its context is (`session.context`), and whether pi is compacting it.
        var context: ContextUsage?
        var compacting = false
        /// What the session's extensions show: status lines and text widgets (by key), the latest notification,
        /// input text to put in the composer, and their slash commands.
        var statuses: [String: String] = [:]
        var widgets: [String: [String]] = [:]
        var notice: Notice?
        var editorText: EditorText?
        var commands: [Command] = []
    }

    /// A session's context use, as pi's automatic compaction measures it.
    struct ContextUsage: Equatable {
        let tokens: Int
        let contextWindow: Int
        let autoCompact: Bool
        /// Above this, pi compacts before the next request; it starts in the background above `backgroundThreshold`.
        let threshold: Int
        let backgroundThreshold: Int
        let keepRecentTokens: Int
        let reserveTokens: Int

        init?(_ value: [String: Any]) {
            guard let tokens = value["tokens"] as? Int else { return nil }
            self.tokens = tokens
            contextWindow = value["contextWindow"] as? Int ?? 0
            autoCompact = value["autoCompact"] as? Bool ?? false
            threshold = value["threshold"] as? Int ?? 0
            backgroundThreshold = value["backgroundThreshold"] as? Int ?? 0
            keepRecentTokens = value["keepRecentTokens"] as? Int ?? 0
            reserveTokens = value["reserveTokens"] as? Int ?? 0
        }

        /// The share of the window in use (0…1).
        var fraction: Double { contextWindow > 0 ? min(1, Double(tokens) / Double(contextWindow)) : 0 }
    }

    struct Notice: Equatable {
        let extensionName: String
        let message: String
        let level: String
        let date = Date()
    }

    /// A message sent during a run, waiting: a steer for the run's next step, a follow-up for its end. It shows from the
    /// moment it's sent, before the engine has it (an extension may be keeping the engine busy).
    struct QueuedMessage: Identifiable, Equatable {
        let id = UUID()
        /// Its submission, once the engine has it; until then it's sending.
        var submission: Int?
        var text: String
        let delivery: Delivery
    }

    /// What an extension is doing in a session for the user: a command, or reading a message before it's sent.
    struct ExtensionTask: Identifiable, Equatable {
        let id: Int
        let extensionName: String
        let what: String
        let startedAt: Date
    }

    struct EditorText: Equatable {
        let text: String
        let append: Bool
        let id = UUID()
    }

    struct Command: Identifiable, Equatable {
        let name: String
        let description: String?
        let extensionName: String
        var id: String { "\(extensionName)/\(name)" }
    }

    /// A dialog an extension shows (pi's `ctx.ui.select`, `confirm`, `input`, `editor`), waiting for the user.
    struct ExtensionDialog: Identifiable, Equatable {
        let id: String
        let sessionId: Int
        let extensionName: String
        let kind: String
        let title: String
        let message: String?
        let options: [String]
        let placeholder: String?
        let prefill: String?
    }

    /// A panel an extension shows (`ctx.ui.custom`, a component widget, `ctx.ui.panel`): its HTML page or its pi-tui
    /// component as views, in a sheet or above the session's message box. Observed on its own, so its updates redraw
    /// only the panel.
    @MainActor
    @Observable
    final class Panel: Identifiable {
        let id: String
        let sessionId: Int
        let extensionName: String
        let placement: String
        let title: String?
        var content: PanelWebView.Content
        /// What the extension posted to the page, as JSON.
        var messages: [String] = []
        /// An app's page (`apps.ts`): it minimizes to the session's dock instead of closing, and keeps running there.
        let app: PanelApp?
        let page: AppPage?
        /// On screen (an app's page may be minimized to the dock).
        var visible = true
        /// An app's page has loaded (until then its sheet shows a spinner, not a blank page).
        var pageReady = false
        /// On a wide screen: across the whole screen, not beside its session (remembered per app).
        var expanded = false
        /// Left for the sessions list while on screen: on screen again when its session shows.
        var reopenWithSession = false
        /// When it was last on screen, to unload the minimized page shown longest ago first.
        var lastShown = Date.now

        init(id: String, sessionId: Int, extensionName: String, placement: String, title: String?, content: PanelWebView.Content,
             app: PanelApp? = nil, state: String = "null") {
            self.id = id
            self.sessionId = sessionId
            self.extensionName = extensionName
            self.placement = placement
            self.title = title
            self.content = content
            self.app = app
            if app != nil, case .html(let html) = content {
                page = AppPage(html: html, state: state, extensionName: extensionName)
            } else {
                page = nil
            }
        }
    }

    /// What makes a panel an app's page.
    struct PanelApp {
        let key: String
        let name: String
        let icon: String?
        let shared: Bool
    }

    /// A session's apps: the ones it runs (its dock) and the ones its extensions offer (the launcher).
    struct SessionApps {
        var running: [DockApp] = []
        var available: [CatalogApp] = []
    }

    struct DockApp: Identifiable {
        let key: String
        let extensionName: String
        let name: String
        let title: String
        let icon: String?
        let badge: String?
        let shared: Bool
        let visible: Bool
        /// On screen when the app last showed it (it opens again with its session after a relaunch).
        let open: Bool
        var id: String { key }
    }

    struct CatalogApp: Identifiable {
        let key: String
        let title: String
        let icon: String?
        let description: String?
        let running: Bool
        var id: String { key }
    }

    struct Provider: Identifiable {
        struct Model: Identifiable, Hashable {
            let id: String
            let name: String
            let contextWindow: Int
            /// The thinking levels it takes, "off" first (just "off" for a model that doesn't reason).
            var thinkingLevels: [String] = ["off"]
        }

        let id: String
        let name: String
        let custom: Bool
        let configured: Bool
        let apiKeyName: String?
        let canEnterAPIKey: Bool
        let oauthName: String?
        let oauthLabel: String?
        let isSubscription: Bool
        let models: [Model]
    }

    /// The state of a login flow run by pi-ai, shown in the login sheet.
    struct AuthFlow {
        struct Prompt {
            let id: String
            let kind: String
            let message: String
            let placeholder: String?
            let options: [(id: String, label: String)]
        }

        let providerId: String
        var url: URL?
        var instructions: String?
        var deviceCode: (code: String, uri: URL?)?
        var prompt: Prompt?
        var progress: [String] = []
        var done = false
        var error: String?
    }

    @ObservationIgnored lazy var watchCompanion = WatchCompanion(app: self, storage: storage)

    private(set) var phase: Phase = .starting
    /// The app's model, for Shortcuts' actions (`Shortcuts.swift`).
    static weak var shared: AppModel?
    /// A session to show (a shortcut's): the root view opens it.
    var requestedSession: Int?
    private(set) var environment = ""
    private(set) var sessions: [Session] = []
    private(set) var providers: [Provider] = []
    var authFlow: AuthFlow?
    /// Extension dialogs, oldest first; the first is on screen.
    var dialogs: [ExtensionDialog] = []
    /// Extension panels, oldest first; the first sheet is on screen when no dialog is.
    var panels: [Panel] = []
    var sheetPanel: Panel? { panels.first { $0.placement == "sheet" && $0.visible } }
    /// Each session's apps, once its screen asked for them.
    var apps: [Int: SessionApps] = [:]
    /// A shared extension the user opened in pi, waiting for them to add it (`SharedExtension.swift`).
    var sharedExtension: SharedExtensionOffer?
    /// A shared session file opened in pi, waiting for the user's answer.
    var sharedSession: SharedSessionOffer?
    /// Asks the screen for the sessions list (an app's Sessions button), each time it changes.
    private(set) var sessionsRequested = 0
    /// Minimized app pages that keep running; the ones shown longest ago are unloaded (opening them draws them again).
    private static let pageLimit = 4
    var defaultModel: ModelRef? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(defaultModel), forKey: Self.defaultModelKey) }
    }
    /// How much new sessions' models think (as each model takes it); synced, like the default model.
    var defaultThinkingLevel: String {
        didSet { UserDefaults.standard.set(defaultThinkingLevel, forKey: Self.defaultThinkingLevelKey) }
    }

    /// An OpenAI-compatible server on the network (e.g. Ollama on a Mac); its models are discovered from `/models`.
    var networkEndpoint: String {
        didSet { UserDefaults.standard.set(networkEndpoint, forKey: "networkEndpoint") }
    }
    /// What sessions call the network server ("Network (Mac Studio)"); empty for its host.
    var networkName: String = UserDefaults.standard.string(forKey: "networkName") ?? "" {
        didSet { UserDefaults.standard.set(networkName, forKey: "networkName") }
    }

    let models = ModelStore.shared
    /// A downloaded model to keep loaded from launch, so sessions using it start warm (the in-app server holds one).
    var preloadedModel: String? {
        didSet {
            UserDefaults.standard.set(preloadedModel, forKey: Self.preloadedModelKey)
            preload()
        }
    }
    /// The on-device model's context window, in tokens: more holds longer conversations and more tools, and takes more
    /// memory. A change restarts a loaded model.
    var localContextSize: Int {
        didSet {
            guard localContextSize != oldValue else { return }
            UserDefaults.standard.set(localContextSize, forKey: Self.localContextSizeKey)
            Task { await applyLocalContextSize() }
        }
    }
    static let localContextSizes = [4096, 8192, 16384, 32768]
    let browser = BrowserService(log: log)
    private(set) var localModelStatus: String?

    let engine: PiEngine
    private let storage = UserDefaults.standard.string(forKey: "storage") ?? "pi"
    private let sessionsRoot = URL.documentsDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    /// Installed pi extension packages (npm and git); a session's own files stay in its workspace.
    private let extensionsRoot = URL.applicationSupportDirectory.appending(path: "extensions", directoryHint: .isDirectory)
    private let sqlite = SQLiteService(directory: URL.applicationSupportDirectory.appending(path: "pi", directoryHint: .isDirectory))
    private let files = FileService()
    private let shell = ShellService(backend: AShellBackend())
    /// Real Linux machines from a Crabbox broker, for the agent's `crabbox_*` tools.
    let crabbox = CrabboxService()
    /// The user's GitHub account: github_api on the phone, gh and git on Crabbox boxes.
    let github = GitHubService()
    /// Secrets the user gives extensions (API keys), in the Keychain.
    let extensionSecrets = ExtensionSecretsService()
    /// MCP servers for every session (Settings → MCP servers): the list, header values, and sign-ins.
    let mcp = MCPServersService()
    /// Hardware-backed keys for extensions (`pi.keys`): Secure Enclave, Face ID, TLS client certificates.
    let extensionKeys = ExtensionKeysService()
    /// The user's sensitive values behind Face ID (`pi.vault`, Settings → Vault; `VaultViews.swift`).
    let vault = VaultService()
    /// The servers as the engine has them: state, tools.
    var mcpServers: [MCPServerStatus] = []
    /// A sign-in in progress: the server's authorization page, shown in a Safari sheet.
    var mcpLogin: MCPLogin?
    private let keychain = KeychainService(synchronizable: true)
    private let loopback = LoopbackService()
    private let backgroundRun = BackgroundRun(log: log)
    private let localModel = LocalModel(log: log)
    private let images = ImageService()
    private var backgroundActive = false
    /// UIKit's background time while runs are in progress and the app is not in front: a few more seconds even when
    /// iOS refuses or has not yet started continued processing (Low Power Mode, for one).
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var heartbeat: Timer?
    private var wentToBackground = false
    /// Sessions whose on-device model was replying when the app went to the background.
    private var localRunsInBackground: Set<Int> = []
    private var autorunSessions: Set<Int> = []

    private static let defaultModelKey = "defaultModel"
    private static let defaultThinkingLevelKey = "defaultThinkingLevel"
    private static let preloadedModelKey = "preloadedModel"
    private static let localContextSizeKey = "localContextSize"
    /// The model the in-app server is loading, so a session and the preload never start it twice.
    private var localModelLoad: (file: String, task: Task<Void, Error>)?

    init() {
        networkEndpoint = UserDefaults.standard.string(forKey: "baseURL")
            ?? UserDefaults.standard.string(forKey: "networkEndpoint") ?? ""
        preloadedModel = UserDefaults.standard.string(forKey: Self.preloadedModelKey)
        let contextSize = UserDefaults.standard.integer(forKey: Self.localContextSizeKey)
        localContextSize = contextSize > 0 ? contextSize : LocalModel.contextSize
        if let data = UserDefaults.standard.data(forKey: Self.defaultModelKey) {
            defaultModel = try? JSONDecoder().decode(ModelRef.self, from: data)
        }
        defaultThinkingLevel = UserDefaults.standard.string(forKey: Self.defaultThinkingLevelKey) ?? "off"
        let bundle = Bundle.main.url(forResource: "engine", withExtension: nil)!
        engine = PiEngine(bundleDirectory: bundle)
        for install in [images.install, sqlite.install, files.install, shell.install, keychain.install, loopback.install, browser.install, crabbox.install, github.install, extensionSecrets.install, mcp.install, extensionKeys.install] {
            install(engine)
        }
        engine.useVault(vault)
        browser.vault = vault
        crabbox.github = github
        // Extensions' synced storage (`pi.synced`): small JSON values per extension in "extensionData", which
        // SyncedSettings merges key by key across the user's devices.
        engine.register(service: "synced") { method, params in
            let arguments = params as? [String: Any] ?? [:]
            let owner = arguments["requester"] as? String ?? "?"
            let prefix = "\(owner)/"
            let defaults = UserDefaults.standard
            var data = defaults.dictionary(forKey: "extensionData") as? [String: String] ?? [:]
            switch method {
            case "get": return data[prefix + (arguments["key"] as? String ?? "")] ?? NSNull()
            case "keys": return data.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
            case "set":
                guard let key = arguments["key"] as? String, !key.isEmpty, let value = arguments["value"] as? String else {
                    throw AppError.message("synced.set needs a key and a value")
                }
                data[prefix + key] = value
                let used = data.filter { $0.key.hasPrefix(prefix) }.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
                guard used <= 128 * 1024 else { throw AppError.message("\(owner)'s synced storage is full (128 KB)") }
                defaults.set(data, forKey: "extensionData")
                return nil
            case "delete":
                data.removeValue(forKey: prefix + (arguments["key"] as? String ?? ""))
                defaults.set(data, forKey: "extensionData")
                return nil
            default: throw EngineError.unknownMethod("synced.\(method)")
            }
        }
        // Asks before the agent adds an extension from the internet (`extension_add` with npm:, git:, or github:): its
        // code runs in pi only once the user agrees. One the agent wrote in the session's workspace needs no asking.
        engine.register(service: "consent") { method, params in
            guard method == "addExtension" else { throw EngineError.unknownMethod("consent.\(method)") }
            let arguments = params as? [String: Any] ?? [:]
            let source = arguments["source"] as? String ?? "?"
            let everySession = arguments["scope"] as? String == "default"
            return await UserDialog.confirm(
                title: "Add this extension?",
                message: "The agent wants to add \(source)\(everySession ? " for every session" : " to this session"). Its code runs in pi; you can read and change it in Settings → Extensions.",
                confirmLabel: "Add"
            )
        }
        // The device's location for an extension (`pi.location()`), and its notifications (`pi.notify()`), once the user
        // allows it (ExtensionPermissions).
        engine.register(service: "device") { method, params in
            let arguments = params as? [String: Any] ?? [:]
            let requester = arguments["requester"] as? String ?? "?"
            switch method {
            case "location":
                return try await ExtensionPermissions.shared.location(for: requester)
            case "notify":
                try await ExtensionPermissions.shared.notify(for: requester, title: arguments["title"] as? String ?? "",
                                                             body: arguments["body"] as? String ?? "",
                                                             session: arguments["session"] as? Int, prompt: arguments["prompt"] as? String)
                return nil
            // pi.mcp (mcp.ts): whether the extension may call a server, and its answers so far.
            case "mcpAccess":
                try await ExtensionPermissions.shared.mcpAccess(arguments["server"] as? String ?? "", for: requester)
                return nil
            case "mcpPermissions":
                return ExtensionPermissions.shared.mcpDecisions(for: requester)
            default:
                throw EngineError.unknownMethod("device.\(method)")
            }
        }
        // The pasteboard, for extensions (pi-coding-agent's `copyToClipboard`).
        engine.register(service: "clipboard") { method, params in
            guard method == "write" else { throw EngineError.unknownMethod("clipboard.\(method)") }
            UIPasteboard.general.string = (params as? [String: Any])?["text"] as? String ?? ""
            return nil
        }
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: extensionsRoot, withIntermediateDirectories: true)
        loadSessionList()
        SyncedSettings.shared.onPulled = { [weak self] keys in self?.applySyncedSettings(keys) }
        Self.shared = self
        engine.onLog = { level, message in log("console.\(level)", message) }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.onTermination = { [weak self] in
            log("engine", "WebKit content process terminated")
            self?.shell.stopAll()
            Task { await self?.restartEngine() }
        }
        browser.profileForSession = { [weak self] id in self?.sessions.first { $0.id == id }?.browser }
        models.onLog = { message in log("model", message) }
        models.onModelsChanged = { [weak self] in Task { await self?.updateCustomProviders() } }
        watchCompanion.activate()
    }

    // MARK: - Startup

    private var startup: Task<Void, Never>?

    /// Starts the engine, once: the root view's task and a shortcut that launched the app wait for the same start.
    func start() async {
        if startup == nil { startup = Task { await startEngine() } }
        await startup?.value
    }

    private func startEngine() async {
        connectVault()
        do {
            // `-testDelayEngine SECONDS`: the engine starts late, as on a slow phone (the saved session list is up first).
            let delay = UserDefaults.standard.double(forKey: "testDelayEngine")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let ready = try await engine.start()
            environment = "secure context: \(ready.secureContext) · WebAssembly: \(ready.webAssembly)"
            log("ready", environment)
            await open()
            startWatchdog()
            try await runLaunchArguments()
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Watchdog

    /// While pi is in front, the engine answers a ping at once unless code that never yields (an extension's) holds its
    /// only thread, which nothing inside the engine can stop. Unanswered for 10 seconds, its page is replaced.
    private var watchdog: Task<Void, Never>?
    private var recovering = false
    /// What the next `open` tells the engine after a frozen page: the extensions to keep off, the runs to abort.
    private var recovery: (extensions: [String], abort: [Int])?

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.phase == .ready, !self.recovering, UIApplication.shared.applicationState == .active else { continue }
                if await !self.engineAnswers(within: .seconds(10)) { await self.recoverFrozenEngine() }
            }
        }
    }

    /// Whether the engine answers a ping in time (an answer that's an error counts: only silence is a frozen page).
    private func engineAnswers(within limit: Duration) async -> Bool {
        await finishes(within: limit) { [engine] in _ = try? await engine.command("ping") }
    }

    /// Whether `work` finishes within `limit`, told as soon as either happens. (A task group would wait for `work` even
    /// after the time ran out: waiting on a frozen engine can't be cancelled.)
    func finishes(within limit: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        final class Race { var settled = false }
        let race = Race()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await work()
                if !race.settled { race.settled = true; continuation.resume(returning: true) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if !race.settled { race.settled = true; continuation.resume(returning: false) }
            }
        }
    }

    /// A page that stopped answering: replaced (`PiEngine.replacePage`), with the extensions that were working turned
    /// off and the busy sessions' runs aborted, so whatever froze it doesn't run again; those sessions say why.
    private func recoverFrozenEngine() async {
        recovering = true
        defer { recovering = false }
        let busy = sessions.filter { $0.running || !$0.extensionTasks.isEmpty }
        let culprits = Array(Set(busy.flatMap { $0.extensionTasks.map(\.extensionName) })).sorted()
        log("engine", "no answer for 10 s\(culprits.isEmpty ? "" : " (\(culprits.joined(separator: ", ")) working)"): replacing its page")
        recovery = (culprits, busy.map(\.id))
        dialogs.removeAll()
        for panel in panels { panel.page?.discard() }
        panels.removeAll()
        let began = Date()
        do {
            _ = try await engine.replacePage()
            await open()
            for id in apps.keys { await loadApps(id) }
            log("engine", String(format: "page replaced in %.2fs", Date().timeIntervalSince(began)))
        } catch {
            fail(error.localizedDescription)
        }
        recovery = nil
        let who = culprits.isEmpty ? nil : culprits.joined(separator: ", ")
        for session in busy {
            guard let index = index(of: session.id) else { continue }
            sessions[index].running = false
            sessions[index].extensionTasks = []
            sessions[index].queued = []
            sessions[index].draft = nil
            sessions[index].tools = []
            sessions[index].error = who.map {
                "\($0) froze pi's engine, so pi restarted it and turned \($0) off (Settings → Extensions turns it back on). This session's run stopped."
            } ?? "pi's engine stopped answering, so pi restarted it. This session's run stopped."
        }
        updateBackground()
    }

    /// Opens the durable store; sessions resume any run a previous launch or engine left unfinished.
    private func open() async {
        do {
            if case .failed = phase { phase = .starting }
            let result = try await engine.command("open", [
                "storage": storage,
                "sessionsRoot": sessionsRoot.path,
                "extensionsRoot": extensionsRoot.path,
                "tmp": FileManager.default.temporaryDirectory.path,
                "cache": URL.cachesDirectory.appending(path: "transpiled").path,
                "providers": await customProviders(),
                "debugTools": UserDefaults.standard.bool(forKey: "debugTools"),
                // `-compactReserveTokens N`, `-compactKeepRecentTokens N`, `-compactBackgroundTokens N` (tests): automatic
                // compaction's thresholds, over pi's.
                "compaction": Self.compactionOverride(),
                // After a frozen page (recoverFrozenEngine): what not to load or resume.
                "recover": recovery.map { ["extensions": $0.extensions, "abort": $0.abort] as [String: Any] } ?? NSNull(),
            ]) as? [String: Any] ?? [:]
            // A session listed twice keeps its first entry rather than ending the app (uniqueKeysWithValues traps).
            let previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<Int>()
            let listed = (result["sessions"] as? [[String: Any]] ?? []).compactMap(Self.session(from:)).filter { seen.insert($0.id).inserted }
            sessions = listed.map { meta in
                var session = previous[meta.id] ?? meta
                session.title = meta.title
                session.model = meta.model
                session.browser = meta.browser
                session.loaded = false
                return session
            }.sorted { $0.createdAt > $1.createdAt }
            log("open", "\(sessions.count) sessions")
            saveSessionList()
            // Extensions load and unfinished runs resume after this (`sessions_resumed`); what needs them waits for it.
            phase = .ready
            await refreshProviders()
            // Now with the providers' names for the rows.
            saveSessionList()
            Task { await syncExtensions() }
            if defaultModel == nil { defaultModel = firstAvailableModel() }
            preload()
            // The store opened with the network models of the last launch; the endpoint's current list follows.
            Task { await refreshNetworkModels() }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func compactionOverride() -> [String: Int] {
        var policy: [String: Int] = [:]
        for (key, argument) in [("reserveTokens", "compactReserveTokens"), ("keepRecentTokens", "compactKeepRecentTokens"),
                                ("backgroundTokens", "compactBackgroundTokens")]
        where UserDefaults.standard.object(forKey: argument) != nil {
            policy[key] = UserDefaults.standard.integer(forKey: argument)
        }
        if !policy.isEmpty { log("compaction", "thresholds over pi's: \(policy)") }
        return policy
    }

    /// Reloads the engine after WebKit's content process died, then reopens the store, which resumes unfinished runs.
    private func restartEngine() async {
        let began = Date()
        // Dialogs and panels belonged to the engine that ended.
        dialogs.removeAll()
        for panel in panels { panel.page?.discard() }
        panels.removeAll()
        do {
            _ = try await engine.start()
            await open()
            for id in apps.keys { await loadApps(id) }
            log("engine", String(format: "restarted in %.2fs", Date().timeIntervalSince(began)))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func runLaunchArguments() async throws {
        let defaults = UserDefaults.standard
        // `-runDueChecks YES` (tests): every background check runs, as when iOS wakes pi, once the extensions load.
        if defaults.bool(forKey: "runDueChecks") { Task { await BackgroundChecks.shared.runDue(within: BackgroundChecks.budget, all: true) } }
        if let link = defaults.string(forKey: "downloadModel") { try models.startDownload(from: link) }
        // `-localModel FILE` or `-baseURL URL -model ID` pick the model for `-autorun` without changing the saved default.
        var autorunModel = defaultModel
        if let file = defaults.string(forKey: "localModel") { autorunModel = ModelRef(provider: "ondevice", modelId: file) }
        if defaults.string(forKey: "baseURL") != nil, let model = defaults.string(forKey: "model") {
            autorunModel = ModelRef(provider: "network", modelId: model)
        }
        if defaults.bool(forKey: "shellTest") { await runShellTest() }
        // `-netProbe URL`: a GET of a plain-http URL through each transport, for network diagnostics.
        if let link = defaults.string(forKey: "netProbe"), let url = URL(string: link) {
            await CrabboxService.probe(url) { line in log("probe", line) }
            log("probe", "done")
        }
        // `-engineCommands 'method {json} ;; method {json}'`: runs engine commands in order and logs each reply.
        if let script = defaults.string(forKey: "engineCommands") {
            for step in script.components(separatedBy: ";;").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
                let method = String(step.prefix { !$0.isWhitespace })
                let json = step.dropFirst(method.count).trimmingCharacters(in: .whitespaces)
                let params = (json.isEmpty ? nil : try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
                do {
                    let reply = try await engine.command(method, params)
                    let text = reply.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) } ?? "null"
                    log("command", "\(method) → \(text)")
                } catch {
                    log("command", "\(method) failed: \(error.localizedDescription)")
                }
            }
        }
        // `-openSharedFile PATH`: opens a shared file (.pisession, .piext) as if it came from AirDrop.
        if let path = defaults.string(forKey: "openSharedFile") { openShared(URL(fileURLWithPath: path)) }
        // `-listExtensions <session id>`: logs the session's extensions (its own and the defaults).
        if defaults.object(forKey: "listExtensions") != nil {
            let id = defaults.integer(forKey: "listExtensions")
            let list = (try? await engine.command("extensions.list", ["id": id])) as? [[String: Any]] ?? []
            log("extensions", "[\(id)] \(list.count) extensions")
            for item in list {
                let tools = (item["tools"] as? [String])?.joined(separator: ", ") ?? ""
                let notes = (item["notes"] as? [String])?.filter { $0.hasPrefix("failed") } ?? []
                log("extensions", "[\(id)] \(item["name"] ?? "?") (\(item["scope"] ?? "?")): tools \(tools)\(notes.isEmpty ? "" : " — \(notes.joined(separator: "; "))")")
            }
        }
        // `-loginTest provider:type` starts a login; `-loginTestValue X` answers its prompts (menus: first option).
        if let spec = defaults.string(forKey: "loginTest") {
            let parts = spec.split(separator: ":").map(String.init)
            if parts.count == 2 { login(parts[0], type: parts[1]) }
        }
        // `-testCrabboxSignOut YES`: signs out of the Crabbox broker.
        if defaults.bool(forKey: "testCrabboxSignOut") {
            crabbox.signOut()
            await crabboxChanged()
        }
        // `-testCrabboxBroker URL -testCrabboxToken TOKEN`: signs in to a test Crabbox broker with that token.
        if let broker = defaults.string(forKey: "testCrabboxBroker"), let token = defaults.string(forKey: "testCrabboxToken") {
            crabbox.setBroker(broker)
            do {
                let identity = try await crabbox.signIn(token: token)
                log("crabbox", "signed in to \(broker) as \(identity["owner"] as? String ?? "?")")
                await crabboxChanged()
            } catch {
                log("crabbox", "sign-in failed: \(error.localizedDescription)")
            }
        }
        if defaults.bool(forKey: "testGitHubSignOut") {
            github.signOut()
            await githubChanged()
        }
        if let token = defaults.string(forKey: "testGitHubToken") {
            do {
                let identity = try await github.signIn(token: token)
                log("github", "signed in as \(identity["login"] as? String ?? "?")")
            } catch {
                log("github", "sign-in failed: \(error.localizedDescription)")
            }
            await githubChanged()
        }
        // `-setNetworkEndpoint URL` and `-setDefaultModel PROVIDER:MODEL` (such as network:anthropic/claude-sonnet-5-5):
        // kept like the same choices in Settings, to ready a phone without taps.
        if let endpoint = defaults.string(forKey: "setNetworkEndpoint") {
            networkEndpoint = endpoint
            await updateCustomProviders()
            log("network", "server set to \(endpoint)")
        }
        if let spec = defaults.string(forKey: "setDefaultModel"), let colon = spec.firstIndex(of: ":") {
            defaultModel = ModelRef(provider: String(spec[..<colon]), modelId: String(spec[spec.index(after: colon)...]))
            log("models", "default model set to \(spec)")
        }
        // `-testExtensionSecret NAME=VALUE`: a secret every extension may read.
        if let spec = defaults.string(forKey: "testExtensionSecret"), let equals = spec.firstIndex(of: "=") {
            try? extensionSecrets.set(String(spec[..<equals]), value: String(spec[spec.index(after: equals)...]), extensions: nil)
            await secretsChanged()
        }
        if let token = defaults.string(forKey: "testGitHubUncheckedToken") {
            try? github.signInUnchecked(token: token)
            await githubChanged()
        }
        // `-fork SESSION:ENTRY`: forks a session at an entry; `-autorun` then prompts the fork.
        var forked: Int?
        if let spec = defaults.string(forKey: "fork") {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { forked = try await fork(parts[0], at: parts[1]) }
            log("fork", forked.map { "\(spec) → \($0)" } ?? "\(spec) cancelled")
        }
        if let prompt = defaults.string(forKey: "autorun"), let model = autorunModel {
            // `-autorunSessions N`: the same prompt in N new sessions at once; `-autorunSession ID`: in that session.
            var ids: [Int] = []
            if let forked {
                ids.append(forked)
            } else if defaults.object(forKey: "autorunSession") != nil {
                ids.append(defaults.integer(forKey: "autorunSession"))
            } else {
                for _ in 0..<max(1, defaults.integer(forKey: "autorunSessions")) { ids.append(try await createSession(model: model)) }
            }
            autorunSessions = Set(ids)
            // `-steerAfter SECONDS -steer TEXT`: steers the run that long after the prompt.
            let steerAfter = defaults.double(forKey: "steerAfter")
            if steerAfter > 0, let steer = defaults.string(forKey: "steer") {
                Task {
                    try? await Task.sleep(for: .seconds(steerAfter))
                    for id in ids { await send(steer, to: id, delivery: .steer) }
                }
            }
            // `-abortAfter SECONDS`: presses Stop that long after the prompt, for timing how fast a run stops.
            let abortAfter = defaults.double(forKey: "abortAfter")
            if abortAfter > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(abortAfter))
                    for id in ids {
                        log("abort", "[\(id)] Stop pressed")
                        abort(id)
                    }
                    // `-afterAbort PROMPT`: once the stopped run settles, prompts the session again (is the shell free?).
                    if let next = defaults.string(forKey: "afterAbort") {
                        while ids.contains(where: { id in sessions.first { $0.id == id }?.running == true }) {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        for id in ids { await send(next, to: id) }
                    }
                }
            }
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { await self.send(prompt, to: id) } }
            }
        }
    }

    // MARK: - Providers and accounts

    /// The app's own providers, next to pi's built-in ones: downloaded on-device models and a network endpoint.
    private func customProviders() async -> [[String: Any]] {
        var providers: [[String: Any]] = []
        if !models.models.isEmpty {
            providers.append([
                "id": "ondevice", "name": "On device", "baseUrl": LocalModel.baseURL,
                "models": models.models.map {
                    ["id": $0, "contextWindow": localContextSize, "maxTokens": min(2048, localContextSize / 4)]
                },
            ])
        }
        if let base = URL(string: networkEndpoint), !networkEndpoint.isEmpty {
            var discovered = savedNetworkModels() ?? []
            if discovered.isEmpty { discovered = await discoverNetworkModels(at: base) }
            providers.append([
                "id": "network", "name": "Network (\(networkName.isEmpty ? base.host() ?? networkEndpoint : networkName))", "baseUrl": networkEndpoint,
                "models": discovered,
            ])
        }
        return providers
    }

    /// Settings taken from iCloud after launch (a device's first sync, chosen once pi runs): the ones the app holds.
    private func applySyncedSettings(_ keys: [String]) {
        let defaults = UserDefaults.standard
        if keys.contains("networkEndpoint") { networkEndpoint = defaults.string(forKey: "networkEndpoint") ?? "" }
        if keys.contains("networkName") { networkName = defaults.string(forKey: "networkName") ?? "" }
        if keys.contains("defaultModel"), let data = defaults.data(forKey: Self.defaultModelKey) {
            defaultModel = try? JSONDecoder().decode(ModelRef.self, from: data)
        }
        if keys.contains(Self.defaultThinkingLevelKey) {
            defaultThinkingLevel = defaults.string(forKey: Self.defaultThinkingLevelKey) ?? "off"
        }
        Task {
            await updateCustomProviders()
            await syncExtensions()
        }
    }

    /// Default extensions follow the user's devices (`SyncedSettings`): each records the ones it added and removed, the
    /// newest change winning per source, and installs or removes the others' (from GitHub, npm or git; one installed from
    /// a file stays on its device).
    private func syncExtensions() async {
        guard let inventory = try? await engine.command("extensions.installed") as? [String: Any],
              let installed = inventory["defaults"] as? [[String: Any]]
        else { return }
        let defaults = UserDefaults.standard
        let syncable = { (source: String) in !source.hasPrefix("/") && !source.hasPrefix("shared:") && !source.hasPrefix("file:") }
        var here: [String: String] = [:]
        for extensionInfo in installed {
            if let source = extensionInfo["source"] as? String, let name = extensionInfo["name"] as? String, syncable(source) { here[source] = name }
        }
        var events: [String: [String: Any]] = [:]
        for event in defaults.array(forKey: SyncedSettings.syncedExtensionsKey) as? [[String: Any]] ?? [] {
            if let source = event["source"] as? String { events[source] = event }
        }
        // What changed here since this device last synced them.
        let before = Set(defaults.stringArray(forKey: "syncedExtensionsHere") ?? [])
        let now = Date().timeIntervalSince1970
        for source in Set(here.keys).subtracting(before) { events[source] = ["source": source, "at": now, "removed": false] }
        for source in before.subtracting(here.keys) { events[source] = ["source": source, "at": now, "removed": true] }
        // What changed on the others.
        for (source, event) in events {
            let removed = event["removed"] as? Bool == true
            if removed, let name = here[source] {
                _ = try? await engine.command("extensions.remove", ["name": name])
                here.removeValue(forKey: source)
                log("sync", "extension \(name) removed (on another device)")
            } else if !removed, here[source] == nil {
                do {
                    let added = try await engine.command("extensions.addDefault", ["source": source]) as? [String: Any]
                    here[source] = added?["name"] as? String ?? source
                    log("sync", "extension \(source) added (from another device)")
                } catch {
                    log("sync", "extension \(source): \(error.localizedDescription)")
                }
            }
        }
        defaults.set(events.keys.sorted().compactMap { events[$0] }, forKey: SyncedSettings.syncedExtensionsKey)
        defaults.set(here.keys.sorted(), forKey: "syncedExtensionsHere")
    }

    /// The network endpoint's models as last discovered, so the store opens without waiting for the endpoint (through a
    /// VPN it can take seconds, and the sessions wait for the store); `refreshNetworkModels` asks again once it's open.
    private var networkModelsFile: URL { URL.applicationSupportDirectory.appending(path: "network-models.json") }

    private func savedNetworkModels() -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: networkModelsFile),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              saved["endpoint"] as? String == networkEndpoint
        else { return nil }
        return saved["models"] as? [[String: Any]]
    }

    /// The endpoint's models, kept for the next launch when it lists any.
    private func discoverNetworkModels(at base: URL) async -> [[String: Any]] {
        let discovered = await Self.discoverModels(at: base)
        if !discovered.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["endpoint": networkEndpoint, "models": discovered]) {
            try? data.write(to: networkModelsFile, options: .atomic)
        }
        return discovered
    }

    /// The endpoint's models again, given to the engine if they changed since they were kept.
    private func refreshNetworkModels() async {
        guard let base = URL(string: networkEndpoint), !networkEndpoint.isEmpty else { return }
        let kept = savedNetworkModels().flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        let discovered = await discoverNetworkModels(at: base)
        guard !discovered.isEmpty, kept != (try? JSONSerialization.data(withJSONObject: discovered, options: .sortedKeys)) else { return }
        await updateCustomProviders()
    }

    /// The endpoint's models from `GET /models` (OpenAI's list), with the limits a gateway reports (`context_length`,
    /// `max_output_tokens`, and a `name`, as OpenRouter-style gateways do); none, with the reason logged,
    /// when that fails. Without limits, a model gets a 32K window and 16K tokens per reply; replies are capped at 32K
    /// tokens (a 4K cap cut long edits short, and the run ended without a word).
    private static func discoverModels(at base: URL) async -> [[String: Any]] {
        var request = URLRequest(url: base.appending(path: "models"))
        // A server inside a VPN (WARP) can take a few seconds to answer.
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else {
                log("network", "\(base.absoluteString)/models: HTTP \(status), not a model list")
                return []
            }
            let models: [[String: Any]] = list.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                let context = (entry["context_length"] as? Int) ?? (entry["max_input_tokens"] as? Int) ?? 32768
                let output = min((entry["max_output_tokens"] as? Int) ?? 16384, 32768, max(context / 2, 1024))
                var model: [String: Any] = ["id": id, "contextWindow": context, "maxTokens": output]
                if let name = entry["name"] as? String, !name.isEmpty { model["name"] = name }
                return model
            }
            log("network", "\(base.absoluteString): \(models.count) models")
            return models
        } catch {
            log("network", "\(base.absoluteString)/models: \(error.localizedDescription)")
            return []
        }
    }

    /// After signing in to a Crabbox broker or out: sessions get or lose its tools.
    func crabboxChanged() async {
        let result = try? await engine.command("crabbox.changed") as? [String: Any]
        log("crabbox", "tools \(result?["available"] as? Bool == true ? "available" : "unavailable")")
    }

    /// After signing in to GitHub or out: sessions get or lose github_api, and boxes get or lose the token.
    func githubChanged() async {
        let result = try? await engine.command("github.changed") as? [String: Any]
        log("github", (result?["login"] as? String).map { "signed in as \($0)" } ?? "signed out")
    }

    // MARK: - MCP servers

    struct MCPServerStatus: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let url: String
        let enabled: Bool
        let exposure: String
        let effectiveExposure: String
        /// disabled, connecting, connected, disconnected, sign-in, or error.
        let state: String
        let error: String?
        let tools: [Tool]
        let instructions: String?

        struct Tool: Hashable {
            let name: String
            let description: String
        }
    }

    struct MCPLogin: Identifiable {
        var id: String { server }
        let server: String
        let url: URL
        /// The redirect URL the app's own sign-in view must catch (not a loopback one, which the engine serves).
        let redirect: URL?
    }

    func refreshMCP() async {
        guard let list = try? await engine.command("mcp.list") as? [[String: Any]] else { return }
        mcpServers = Self.mcpStatuses(list)
    }

    private static func mcpStatuses(_ list: [[String: Any]]) -> [MCPServerStatus] {
        list.map { server in
            MCPServerStatus(
                name: server["name"] as? String ?? "", url: server["url"] as? String ?? "",
                enabled: server["enabled"] as? Bool ?? true, exposure: server["exposure"] as? String ?? "auto",
                effectiveExposure: server["effectiveExposure"] as? String ?? "direct", state: server["state"] as? String ?? "disconnected",
                error: server["error"] as? String,
                tools: (server["tools"] as? [[String: Any]] ?? []).map { .init(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "") },
                instructions: server["instructions"] as? String
            )
        }
    }

    /// Adds or changes a server (`headers` and `clientSecret` nil keep the stored values); the engine connects it.
    func saveMCP(_ entry: MCPServersService.Entry, headers: [String: String]?, clientSecret: String? = nil) async throws {
        try mcp.save(entry, headers: headers, clientSecret: clientSecret)
        await mcpChanged()
    }

    /// The sign-in view caught the server's redirect.
    func mcpAuthorizationResponse(_ url: URL) async {
        log("mcp", "\(mcpLogin?.server ?? "?"): sign-in response")
        mcpLogin = nil
        _ = try? await engine.command("mcp.authorizationResponse", ["url": url.absoluteString])
    }

    func deleteMCP(_ name: String) async {
        mcp.delete(name)
        await mcpChanged()
    }

    func setMCPEnabled(_ name: String, _ enabled: Bool) async {
        mcp.setEnabled(name, enabled)
        await mcpChanged()
    }

    func setMCPExposure(_ name: String, _ exposure: String) async {
        mcp.setExposure(name, exposure)
        await mcpChanged()
    }

    private func mcpChanged() async {
        if let list = try? await engine.command("mcp.changed") as? [[String: Any]] { mcpServers = Self.mcpStatuses(list) }
    }

    /// Signs in: the engine runs pi-mcp's OAuth flow and sends the authorization page (`mcp_auth_url`), shown in a sheet;
    /// returns once signed in and connected, or with the reason it wasn't.
    func signInMCP(_ name: String) async -> String? {
        log("mcp", "\(name): signing in")
        do {
            if let list = try await engine.command("mcp.signIn", ["name": name]) as? [[String: Any]] { mcpServers = Self.mcpStatuses(list) }
            log("mcp", "\(name): \(mcpServers.first { $0.name == name }?.state ?? "?")")
            return nil
        } catch {
            log("mcp", "\(name): sign-in failed: \(error.localizedDescription)")
            await refreshMCP()
            return error.localizedDescription
        }
    }

    /// The user closed the authorization page.
    func cancelMCPSignIn() async {
        mcpLogin = nil
        _ = try? await engine.command("mcp.cancelSignIn")
    }

    func signOutMCP(_ name: String) async {
        mcp.signOut(name)
        _ = try? await engine.command("mcp.signedOut", ["name": name])
        await refreshMCP()
    }

    func reconnectMCP(_ name: String) async {
        if let list = try? await engine.command("mcp.reconnect", ["name": name]) as? [[String: Any]] { mcpServers = Self.mcpStatuses(list) }
    }

    /// After the user changed extension secrets: extensions see the change at once.
    func secretsChanged() async {
        _ = try? await engine.command("secrets.changed")
    }

    func updateCustomProviders() async {
        _ = try? await engine.command("providers.setCustom", ["providers": await customProviders()])
        await refreshProviders()
    }

    func refreshProviders() async {
        guard let list = try? await engine.command("providers.list") as? [[String: Any]] else { return }
        let configured = list.filter { $0["configured"] as? Bool == true }.compactMap { $0["id"] as? String }
        log("providers", "\(list.count) providers; configured: \(configured.joined(separator: ", "))")
        providers = list.map { item in
            let apiKey = item["apiKey"] as? [String: Any]
            let oauth = item["oauth"] as? [String: Any]
            return Provider(
                id: item["id"] as? String ?? "",
                name: item["name"] as? String ?? "",
                custom: item["custom"] as? Bool ?? false,
                configured: item["configured"] as? Bool ?? false,
                apiKeyName: apiKey?["name"] as? String,
                canEnterAPIKey: apiKey?["canLogin"] as? Bool ?? false,
                oauthName: oauth?["name"] as? String,
                oauthLabel: oauth?["loginLabel"] as? String,
                isSubscription: oauth?["isSubscription"] as? Bool ?? false,
                models: (item["models"] as? [[String: Any]] ?? []).map {
                    Provider.Model(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
                                   contextWindow: $0["contextWindow"] as? Int ?? 0,
                                   thinkingLevels: $0["thinkingLevels"] as? [String] ?? ["off"])
                }
            )
        }
    }

    /// Providers with models pi can use now: custom ones first, then accounts the user signed in to.
    var usableProviders: [Provider] {
        providers.filter { $0.configured && !$0.models.isEmpty }.sorted { ($0.custom ? 0 : 1, $0.name) < ($1.custom ? 0 : 1, $1.name) }
    }

    func displayName(of model: ModelRef) -> String {
        let provider = providers.first { $0.id == model.provider }
        let name = provider?.models.first { $0.id == model.modelId }?.name ?? model.modelId
        return "\(name) · \(provider?.name ?? model.provider)"
    }

    /// The session's model and, when it has one, its browser profile.
    func subtitle(of session: Session) -> String {
        if providers.isEmpty, let saved = savedSubtitles[session.id] { return saved }
        var model = displayName(of: session.model)
        if session.thinkingLevel != "off" { model += " · \(Self.thinkingTitle(session.thinkingLevel).lowercased()) thinking" }
        guard let key = session.browser, let profile = browser.profiles.name(of: key) else { return model }
        return "\(model) · \(profile)"
    }

    private func firstAvailableModel() -> ModelRef? {
        usableProviders.first.flatMap { provider in provider.models.first.map { ModelRef(provider: provider.id, modelId: $0.id) } }
    }

    /// Runs one of pi-ai's login flows (`api_key` or `oauth`); its prompts and steps appear in the login sheet.
    func login(_ providerId: String, type: String) {
        log("auth", "login \(providerId) (\(type))")
        authFlow = AuthFlow(providerId: providerId)
        Task {
            do {
                let result = try await engine.command("auth.login", ["providerId": providerId, "type": type]) as? [String: Any]
                if result?["ok"] as? Bool == true { await refreshProviders() }
            } catch {
                log("auth", "login \(providerId) failed: \(error.localizedDescription)")
                if authFlow?.providerId == providerId { authFlow?.error = error.localizedDescription }
            }
        }
    }

    func answerAuthPrompt(_ value: String?) {
        guard let prompt = authFlow?.prompt else { return }
        authFlow?.prompt = nil
        var params: [String: Any] = ["promptId": prompt.id]
        if let value { params["value"] = value }
        Task { _ = try? await engine.command("auth.respond", params) }
    }

    func cancelLogin() {
        Task { _ = try? await engine.command("auth.cancel") }
        authFlow = nil
    }

    func logout(_ providerId: String) async {
        _ = try? await engine.command("auth.logout", ["providerId": providerId])
        await refreshProviders()
    }

    // MARK: - Sessions

    /// The sessions as last listed: shown at launch while the engine opens the store, which takes seconds. What a
    /// session needs from the engine before then waits for it (`PiEngine.command`, and the engine's own gate).
    private var sessionListFile: URL { URL.applicationSupportDirectory.appending(path: "sessions-\(storage).json") }

    private func loadSessionList() {
        guard let data = try? Data(contentsOf: sessionListFile),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        sessions = list.compactMap(Self.session(from:)).sorted { $0.createdAt > $1.createdAt }
        for meta in list {
            if let id = meta["id"] as? Int, let subtitle = meta["subtitle"] as? String { savedSubtitles[id] = subtitle }
        }
    }

    /// Rows' second lines as last shown (model and provider names), until the engine lists the providers.
    private var savedSubtitles: [Int: String] = [:]

    private func saveSessionList() {
        watchCompanion.changed()
        let list: [[String: Any]] = sessions.map { session in
            var meta: [String: Any] = [
                "id": session.id, "title": session.title,
                "model": ["provider": session.model.provider, "modelId": session.model.modelId],
                "createdAt": session.createdAt.timeIntervalSince1970 * 1000,
                "lastActiveAt": session.lastActive.timeIntervalSince1970 * 1000,
            ]
            if let browser = session.browser { meta["browser"] = browser }
            if session.thinkingLevel != "off" { meta["thinkingLevel"] = session.thinkingLevel }
            if let subtitle = providers.isEmpty ? savedSubtitles[session.id] : subtitle(of: session) { meta["subtitle"] = subtitle }
            return meta
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        try? data.write(to: sessionListFile, options: .atomic)
    }

    @discardableResult
    func createSession(model: ModelRef? = nil, requestID: UUID? = nil) async throws -> Int {
        guard let model = model ?? defaultModel else { throw AppError.noModel }
        var params: [String: Any] = [
            "provider": model.provider, "modelId": model.modelId, "browser": browser.profiles.defaultKey,
            "thinkingLevel": defaultThinkingLevel,
        ]
        if let requestID { params["requestId"] = requestID.uuidString }
        let result = try await engine.command("session.create", params) as? [String: Any]
        guard let result, var session = Self.session(from: result) else { throw AppError.noModel }
        session.loaded = true
        if let index = index(of: session.id) { sessions[index] = session } else { sessions.insert(session, at: 0) }
        saveSessionList()
        log("session", "created \(session.id) with \(model.provider)/\(model.modelId)")
        return session.id
    }

    func loadTranscript(_ id: Int) async {
        guard let index = index(of: id), !sessions[index].loaded,
              let result = try? await engine.command("session.transcript", ["id": id]) as? [String: Any],
              let index = self.index(of: id)
        else { return }
        sessions[index].items = (result["items"] as? [[String: Any]] ?? []).compactMap(TranscriptItem.init(item:))
        sessions[index].running = result["running"] as? Bool ?? false
        sessions[index].loaded = true
        await refreshContext(id)
    }

    /// How full the session's context is now.
    func refreshContext(_ id: Int) async {
        guard let value = try? await engine.command("session.context", ["id": id]) as? [String: Any],
              let index = index(of: id)
        else { return }
        sessions[index].context = ContextUsage(value)
    }

    /// Compacts the session's context now (pi's `/compact`).
    func compact(_ id: Int, instructions: String? = nil) async {
        log("compaction", "[\(id)] requested")
        if let index = index(of: id) { sessions[index].compacting = true }
        do {
            _ = try await engine.command("session.compact", ["id": id, "instructions": instructions ?? ""])
        } catch {
            if let index = index(of: id) {
                sessions[index].compacting = false
                sessions[index].error = error.localizedDescription
            }
        }
    }

    /// Where a message sent while the agent works goes.
    enum Delivery: String {
        /// After the agent's current tool call, before its next step.
        case steer
        /// Once the run is done, as the next prompt.
        case followUp
    }

    func send(_ text: String, to id: Int, delivery: Delivery = .steer) async {
        do {
            try await submit(text, to: id, delivery: delivery)
        } catch {
            if let index = self.index(of: id) {
                sessions[index].error = error.localizedDescription
                sessions[index].running = false
            }
            log("error", "[\(id)] \(error.localizedDescription)")
            updateBackground()
        }
    }

    /// Moves files the user attached into the session's workspace (`attachments/`), under names not yet taken there; their
    /// paths in the workspace, for the message's `attachment:` lines.
    func attach(_ files: [URL], to id: Int) throws -> [String] {
        let folder = sessionsRoot.appending(path: String(id), directoryHint: .isDirectory).appending(path: "attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.map { file in
            let name = file.lastPathComponent
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var target = folder.appending(path: name)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
                number += 1
            }
            try FileManager.default.moveItem(at: file, to: target)
            log("attach", "[\(id)] attachments/\(target.lastPathComponent)")
            return "attachments/\(target.lastPathComponent)"
        }
    }

    /// Sends a prompt; the submission of the run it starts, or nil when none does.
    @discardableResult
    private func submit(_ text: String, to id: Int, delivery: Delivery, requestID: UUID? = nil) async throws -> Int? {
        guard let index = index(of: id), !text.isEmpty else { return nil }
        sessions[index].error = nil
        log("prompt", "[\(id)] \(text)")
        if sessions[index].model.provider == "ondevice" { try await loadLocalModel(sessions[index].model.modelId) }
        // During a run, or while an extension works for the user, the message shows at once, as sending: the engine
        // may not answer for a while.
        var pending: UUID?
        if sessions[index].running || !sessions[index].extensionTasks.isEmpty {
            let message = QueuedMessage(text: text, delivery: delivery)
            sessions[index].queued.append(message)
            pending = message.id
        }
        sessions[index].running = true
        updateBackground()
        var params: [String: Any] = ["id": id, "text": text, "whenBusy": delivery.rawValue]
        if let requestID { params["requestId"] = requestID.uuidString }
        let result: [String: Any]?
        do {
            result = try await engine.command("session.prompt", params) as? [String: Any]
        } catch {
            if let pending, let index = self.index(of: id) { sessions[index].queued.removeAll { $0.id == pending } }
            throw error
        }
        // Waiting for the run: queued until it's in the transcript (or dropped). Not waiting (the run had ended, or an
        // extension took it), the sending one goes: the transcript shows it, if anything.
        let queuedNow = result?["queued"] as? Bool == true
        if let index = self.index(of: id) {
            let at = pending.flatMap { pending in sessions[index].queued.firstIndex { $0.id == pending } }
            if queuedNow, let submission = result?["submissionId"] as? Int {
                let shown = result?["text"] as? String ?? text
                if let at {
                    sessions[index].queued[at].submission = submission
                    sessions[index].queued[at].text = shown
                } else if pending == nil {
                    sessions[index].queued.append(QueuedMessage(submission: submission, text: shown, delivery: delivery))
                }
            } else if let at {
                sessions[index].queued.remove(at: at)
            }
        }
        // A `!command`, an extension's `/command`, or a prompt an extension took (pi's `input` event): no run starts.
        if result?["submissionId"] is NSNull, let index = self.index(of: id) {
            sessions[index].running = false
            let kind = result?["kind"] as? String
            log("settled", "[\(id)] \(kind == "bash" ? "ran a command" : kind == "command" ? "ran an extension command" : kind == "compact" ? "compacting" : "handled by an extension")")
            updateBackground()
            return nil
        }
        return result?["submissionId"] as? Int
    }

    /// Takes back a queued message, whose text goes back to the message box; too late (the agent took it), it stays.
    func withdraw(_ message: QueuedMessage, in id: Int) async {
        guard let submission = message.submission else { return }
        let result = try? await engine.command("session.withdraw", ["submissionId": submission]) as? [String: Any]
        guard let index = index(of: id) else { return }
        if result?["result"] as? String == "aborted" {
            withdrawnSubmissions.insert(submission)
            sessions[index].queued.removeAll { $0.id == message.id }
            sessions[index].editorText = EditorText(text: message.text, append: true)
        } else {
            await refreshQueued(id)
        }
    }

    /// Submissions taken back, whose settling (unanswered) is no error.
    private var withdrawnSubmissions: Set<Int> = []

    /// Drops the queued messages that are in the transcript now, or were dropped (a run stopped), as the engine says.
    private func refreshQueued(_ id: Int) async {
        guard let index = index(of: id) else { return }
        let ids = sessions[index].queued.compactMap(\.submission)
        guard !ids.isEmpty, let result = try? await engine.command("session.queued", ["ids": ids]) as? [String: Any],
              let waiting = result["queued"] as? [Int], let index = self.index(of: id)
        else { return }
        sessions[index].queued.removeAll { message in message.submission.map { !waiting.contains($0) } ?? false }
    }

    func submitFromWatch(_ text: String, sessionID: Int, requestID: UUID) async throws -> Int? {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { throw WatchCompanion.Failure.sessionMissing }
        if session.model.provider == "ondevice", UIApplication.shared.applicationState != .active {
            throw WatchCompanion.Failure.onDeviceBackground
        }
        if UIApplication.shared.applicationState != .active { beginBackgroundTask() }
        return try await submit(text, to: sessionID, delivery: .followUp, requestID: requestID)
    }

    /// A tapped notification from an extension (`pi.notify`): its session opens, and gets its prompt if it has one; a
    /// prompt with no session (or one deleted since) goes to a new session.
    func openFromNotification(session: Int?, prompt: String?) async {
        await start()
        guard phase == .ready else { return }
        var id = session.flatMap { index(of: $0) != nil ? $0 : nil }
        if id == nil, prompt != nil { id = try? await createSession() }
        guard let id else { return }
        log("notification", "[\(id)] opened\(prompt == nil ? "" : " with its prompt")")
        requestedSession = id
        if let prompt { await send(prompt, to: id) }
    }

    /// The session of the last Ask pi, to show if its shortcut continues in pi.
    private(set) var askedSession: Int?

    /// The extensions have loaded (`sessions_resumed`): their background checks are known.
    private var extensionsReady = false
    private var extensionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until the engine has loaded the extensions (after `open`).
    func extensionsLoaded() async {
        if extensionsReady { return }
        await withCheckedContinuation { extensionWaiters.append($0) }
    }

    /// A shortcut's message: sent to a session (a new one when none is given), and the agent's reply once its run is
    /// done. A session already working gets it when it's done. `show`: pi opens that session (the shortcut runs in pi,
    /// not in the background).
    func ask(_ text: String, in sessionId: Int?, show: Bool = true) async throws -> String {
        await start()
        guard phase == .ready else { throw AppError.message("pi couldn't start: \(String(describing: phase))") }
        let id: Int
        if let sessionId {
            guard index(of: sessionId) != nil else { throw AppError.message("That pi session no longer exists.") }
            id = sessionId
        } else {
            id = try await createSession()
        }
        askedSession = id
        if show { requestedSession = id }
        log("shortcut", "[\(id)] ask\(show ? "" : " (in the background)")")
        guard let submission = try await submit(text, to: id, delivery: .followUp) else { return "" }
        let reply = try await engine.command("session.reply", ["id": id, "submissionId": submission]) as? [String: Any] ?? [:]
        let status = reply["status"] as? String ?? "done"
        let text = reply["text"] as? String ?? ""
        log("shortcut", "[\(id)] \(status), \(text.count) characters")
        let problem = (reply["error"] as? String) ?? (reply["detail"] as? String) ?? (reply["reason"] as? String)
        if status != "done" { throw AppError.message(problem ?? "The agent's run ended: \(status).") }
        if text.isEmpty, let problem { throw AppError.message(problem) }
        return text
    }

    /// A new session for a shortcut (to send it messages later), which pi shows.
    func startSession(title: String?, show: Bool = true) async throws -> Session {
        await start()
        guard phase == .ready else { throw AppError.message("pi couldn't start: \(String(describing: phase))") }
        let id = try await createSession()
        if let title, !title.isEmpty { await rename(id, to: title) }
        if show { requestedSession = id }
        guard var session = sessions.first(where: { $0.id == id }) else { throw AppError.message("The session wasn't created.") }
        if let title, !title.isEmpty { session.title = title }
        return session
    }

    /// A session the engine added from a shared file (`session.import`), listed first.
    func addImportedSession(_ meta: [String: Any]) {
        guard var session = Self.session(from: meta) else { return }
        session.loaded = false
        if index(of: session.id) == nil { sessions.insert(session, at: 0) }
        saveSessionList()
    }

    /// The sessions as last listed (the engine may not be running: a shortcut's session picker).
    static func savedSessions() -> [(id: Int, title: String, lastActive: Date)] {
        let storage = UserDefaults.standard.string(forKey: "storage") ?? "pi"
        let file = URL.applicationSupportDirectory.appending(path: "sessions-\(storage).json")
        guard let data = try? Data(contentsOf: file), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap(session(from:)).sorted { $0.lastActive > $1.lastActive }.map { ($0.id, $0.title, $0.lastActive) }
    }

    /// Stops whatever the session is doing: its run, or an extension working for the user (whose questions on screen go
    /// too). An extension holding the engine itself (code that never yields) keeps it from answering: then it says so.
    func abort(_ id: Int) {
        for dialog in dialogs where dialog.sessionId == id { respond(to: dialog, with: nil) }
        Task {
            let answered = await finishes(within: .seconds(4)) { [engine] in _ = try? await engine.command("session.abort", ["id": id]) }
            guard !answered, let index = index(of: id) else { return }
            let holder = sessions[index].extensionTasks.first?.extensionName ?? "An extension"
            log("engine", "[\(id)] Stop unanswered for 4 s: \(holder) holds the engine")
            sessions[index].notice = Notice(extensionName: holder, message: "\(holder) is keeping pi's engine busy: Stop takes effect once it lets go.", level: "warning")
        }
    }

    /// Stops one of an extension's tasks in the session (the indicator's list), leaving the run and the others.
    func stopTask(_ task: ExtensionTask, in id: Int) {
        log("prompt", "[\(id)] stopping \(task.extensionName): \(task.what)")
        Task { _ = try? await engine.command("session.stopTask", ["id": id, "task": task.id]) }
    }

    /// Stops the run, whatever it's doing (a tool, writing, thinking), and sends `text` at once as the next prompt, after
    /// any messages still queued (stopping drops them, so they go with it, in order, rather than being lost).
    func sendNow(_ text: String, to id: Int) async {
        guard let index = index(of: id) else { return }
        let queued = sessions[index].queued
        for message in queued { if let submission = message.submission { withdrawnSubmissions.insert(submission) } }
        sessions[index].queued.removeAll()
        // The stopped run's settling is no error: the user stopped it.
        stoppedForSendNow.insert(id)
        log("prompt", "[\(id)] send now: stopping the run")
        _ = try? await engine.command("session.abort", ["id": id])
        await send((queued.map(\.text) + [text]).joined(separator: "\n\n"), to: id)
    }

    /// Sessions whose run Send now stopped: its submission settling unanswered shows no error.
    private var stoppedForSendNow: Set<Int> = []

    func setModel(_ model: ModelRef, for id: Int) async {
        let result = try? await engine.command("session.setModel", ["id": id, "provider": model.provider, "modelId": model.modelId]) as? [String: Any]
        if let index = index(of: id) {
            sessions[index].model = model
            // As far as the new model goes.
            if let level = result?["thinkingLevel"] as? String { sessions[index].thinkingLevel = level }
        }
        await refreshContext(id)
    }

    /// How much the session's model thinks; the engine sets the nearest level the model takes.
    func setThinkingLevel(_ level: String, for id: Int) async {
        do {
            let result = try await engine.command("session.setThinkingLevel", ["id": id, "level": level]) as? [String: Any]
            if let index = index(of: id) { sessions[index].thinkingLevel = result?["thinkingLevel"] as? String ?? level }
        } catch {
            log("error", "[\(id)] thinking level: \(error.localizedDescription)")
        }
    }

    /// The thinking levels a model takes ("off" alone for one that doesn't reason, or isn't listed).
    func thinkingLevels(of model: ModelRef) -> [String] {
        providers.first { $0.id == model.provider }?.models.first { $0.id == model.modelId }?.thinkingLevels ?? ["off"]
    }

    /// A thinking level as the app names it.
    static func thinkingTitle(_ level: String) -> String {
        switch level {
        case "off": "Off"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Max"
        default: level.capitalized
        }
    }

    /// Moves the session's agent to another browser profile, or detaches it (`nil`); its open tabs close.
    func setBrowser(_ key: String?, for id: Int) async {
        _ = try? await engine.command("session.setBrowser", ["id": id, "browser": key.map { $0 as Any } ?? NSNull()])
        if let index = index(of: id) { sessions[index].browser = key }
        browser.close(sessionId: id)
    }

    /// Deletes a browser profile and its site data; sessions using it are left without a browser.
    func deleteBrowserProfile(_ key: String) async throws {
        for session in sessions where session.browser == key { await setBrowser(nil, for: session.id) }
        try await browser.deleteProfile(key)
    }

    /// Answers an extension's dialog: the chosen option or entered text, "yes" for a confirmation, nil to dismiss.
    func respond(to dialog: ExtensionDialog, with value: String?) {
        dialogs.removeAll { $0.id == dialog.id }
        log("ui", "[\(dialog.sessionId)] \(dialog.kind) answered: \(value ?? "(dismissed)")")
        Task { _ = try? await engine.command("ui.respond", ["id": dialog.id, "value": value.map { $0 as Any } ?? NSNull()]) }
    }

    /// `-uiAnswer VALUE` answers dialogs in automated runs: confirmations with yes (VALUE "yes") or no, selections with
    /// the option VALUE names (else the first), text with VALUE.
    private func answerTestDialog(_ dialog: ExtensionDialog) {
        guard let value = UserDefaults.standard.string(forKey: "uiAnswer") else { return }
        switch dialog.kind {
        case "confirm": respond(to: dialog, with: value == "yes" ? "yes" : nil)
        case "select": respond(to: dialog, with: dialog.options.first { $0 == value } ?? dialog.options.first)
        default: respond(to: dialog, with: value)
        }
    }

    /// What the user did in a panel: a tap or text for its component, a page's message or result, or (from the agent's
    /// cards) a message to send.
    func panelEvent(_ event: [String: Any], panelId: String) {
        log("ui", "\(panelId) \(event["type"] as? String ?? "?")")
        Task {
            do {
                _ = try await engine.command("panel.event", ["id": panelId, "event": event])
            } catch {
                log("error", "\(panelId): \(error.localizedDescription)")
            }
        }
    }

    /// The user closed a panel (an app's page: closed the app).
    func dismiss(_ panel: Panel) {
        panels.removeAll { $0.id == panel.id }
        panel.page?.discard()
        log("ui", "[\(panel.sessionId)] \(panel.extensionName) \(panel.app == nil ? "panel" : "app") closed")
        Task { _ = try? await engine.command("panel.dismissed", ["id": panel.id]) }
    }

    // MARK: - Apps

    /// A session's dock and launcher.
    func loadApps(_ id: Int) async {
        do {
            let result = try await engine.command("apps.list", ["sessionId": id]) as? [String: Any] ?? [:]
            let running = (result["running"] as? [[String: Any]] ?? []).compactMap { entry -> DockApp? in
                guard let key = entry["key"] as? String else { return nil }
                return DockApp(key: key, extensionName: entry["extension"] as? String ?? "", name: entry["name"] as? String ?? key,
                               title: entry["title"] as? String ?? key, icon: entry["icon"] as? String, badge: entry["badge"] as? String,
                               shared: entry["shared"] as? Bool ?? false, visible: entry["visible"] as? Bool ?? false,
                               open: entry["open"] as? Bool ?? false)
            }
            let available = (result["available"] as? [[String: Any]] ?? []).compactMap { entry -> CatalogApp? in
                guard let key = entry["key"] as? String else { return nil }
                return CatalogApp(key: key, title: entry["title"] as? String ?? key, icon: entry["icon"] as? String,
                                  description: entry["description"] as? String, running: entry["running"] as? Bool ?? false)
            }
            apps[id] = SessionApps(running: running, available: available)
        } catch {
            log("error", "[\(id)] apps: \(error.localizedDescription)")
        }
    }

    /// An app's title as its extension set it last (`app.setTitle`), for its sheet.
    func title(of panel: Panel) -> String {
        apps[panel.sessionId]?.running.first { $0.key == panel.app?.key }?.title ?? panel.title ?? panel.extensionName
    }

    /// Opens an app from the dock or the launcher: its running page again, or one its extension draws now.
    func openApp(_ key: String, in sessionId: Int) {
        if let panel = panels.first(where: { $0.sessionId == sessionId && $0.app?.key == key }) {
            restore(panel)
            return
        }
        log("ui", "[\(sessionId)] open app \(key)")
        Task {
            do {
                _ = try await engine.command("apps.open", ["sessionId": sessionId, "key": key])
            } catch {
                log("error", "[\(sessionId)] \(key): \(error.localizedDescription)")
                if let index = index(of: sessionId) {
                    sessions[index].notice = Notice(extensionName: "Apps", message: error.localizedDescription, level: "error")
                }
            }
        }
    }

    /// Back to the sessions list with an app still open: on a phone it waits in its session's dock and is on screen
    /// again when the session shows; expanded on a wide screen, it goes back beside its session.
    func showSessions(leaving panel: Panel, wide: Bool) {
        if wide {
            panel.expanded = false
        } else {
            minimize(panel)
            panel.reopenWithSession = true
        }
        sessionsRequested += 1
    }

    /// The session's apps that were on screen when the app last showed them (before a relaunch, or when the user went
    /// to the sessions list) open again.
    func reopenApps(in sessionId: Int) {
        for panel in panels where panel.sessionId == sessionId && panel.reopenWithSession { restore(panel) }
        for docked in apps[sessionId]?.running ?? [] where docked.open && !docked.visible {
            if panels.contains(where: { $0.sessionId == sessionId && $0.app?.key == docked.key }) { continue }
            openApp(docked.key, in: sessionId)
        }
    }

    /// Closes an app from its dock entry.
    func closeApp(_ key: String, in sessionId: Int) {
        if let panel = panels.first(where: { $0.sessionId == sessionId && $0.app?.key == key }) { return dismiss(panel) }
        Task { _ = try? await engine.command("apps.close", ["sessionId": sessionId, "key": key]) }
    }

    /// Takes an app's page off screen, to the session's dock, where it keeps running.
    func minimize(_ panel: Panel) {
        guard panel.app != nil, panel.visible else { return }
        panel.visible = false
        log("ui", "[\(panel.sessionId)] \(panel.extensionName) app minimized")
        Task { _ = try? await engine.command("panel.minimized", ["id": panel.id]) }
        unloadExtraPages()
    }

    /// On a wide screen, an app across the whole screen or beside its session; the next time it opens the same way.
    func setExpanded(_ panel: Panel, _ expanded: Bool) {
        panel.expanded = expanded
        guard let key = panel.app?.key else { return }
        var keys = Set(UserDefaults.standard.stringArray(forKey: Self.expandedAppsKey) ?? [])
        if expanded { keys.insert(key) } else { keys.remove(key) }
        UserDefaults.standard.set(keys.sorted(), forKey: Self.expandedAppsKey)
    }

    private static let expandedAppsKey = "expandedApps"

    /// Puts a minimized app's page back on screen.
    func restore(_ panel: Panel) {
        panel.lastShown = .now
        panel.reopenWithSession = false
        guard !panel.visible else { return }
        panel.visible = true
        log("ui", "[\(panel.sessionId)] \(panel.extensionName) app restored")
        Task { _ = try? await engine.command("panel.restored", ["id": panel.id]) }
    }

    /// Keeps at most `pageLimit` minimized pages running: the ones shown longest ago are unloaded.
    private func unloadExtraPages() {
        let minimized = panels.filter { $0.app != nil && !$0.visible }.sorted { $0.lastShown > $1.lastShown }
        for panel in minimized.dropFirst(Self.pageLimit) {
            panels.removeAll { $0.id == panel.id }
            panel.page?.discard()
            log("ui", "[\(panel.sessionId)] \(panel.extensionName) app page unloaded")
            Task { _ = try? await engine.command("panel.suspended", ["id": panel.id]) }
        }
    }

    /// What an app's page asked of the app: to minimize, to send a message to the session (minimizing so it shows),
    /// or something for its extension.
    private func appPageEvent(_ event: [String: Any], panel: Panel) {
        switch event["type"] as? String {
        case "minimize":
            minimize(panel)
        case "prompt":
            guard let text = event["text"] as? String, !text.isEmpty else { return }
            minimize(panel)
            Task { await send(text, to: panel.sessionId) }
        default:
            panelEvent(event, panelId: panel.id)
        }
    }

    func clearNotice(_ id: Int) {
        if let index = index(of: id) { sessions[index].notice = nil }
    }

    /// The slash commands the session's extensions registered, for the composer to suggest.
    func loadCommands(_ id: Int) async {
        let result = (try? await engine.command("session.commands", ["id": id])) as? [[String: Any]] ?? []
        guard let index = index(of: id) else { return }
        sessions[index].commands = result.map {
            Command(name: $0["name"] as? String ?? "", description: $0["description"] as? String, extensionName: $0["extension"] as? String ?? "")
        }
    }

    /// Forks a session at an entry into a new session (with a copy of its workspace); nil when an extension cancels.
    func fork(_ id: Int, at entryId: Int) async throws -> Int? {
        let result = try await engine.command("session.fork", ["id": id, "entryId": entryId]) as? [String: Any]
        guard let result, result["cancelled"] as? Bool != true, let session = Self.session(from: result) else { return nil }
        // The engine's `session_added` for the fork can arrive first and list it.
        if index(of: session.id) == nil { sessions.insert(session, at: 0) }
        saveSessionList()
        log("session", "forked \(id) at \(entryId) into \(session.id)")
        return session.id
    }

    func rename(_ id: Int, to title: String) async {
        _ = try? await engine.command("session.rename", ["id": id, "title": title])
    }

    func delete(_ id: Int) async {
        _ = try? await engine.command("session.delete", ["id": id])
        sessions.removeAll { $0.id == id }
        saveSessionList()
        browser.close(sessionId: id)
        try? FileManager.default.removeItem(at: sessionsRoot.appending(path: String(id)))
        updateBackground()
    }

    /// Sessions not used since `cutoff` (every session when nil), leaving out running ones.
    func idleSessions(since cutoff: Date?) -> [Session] {
        sessions.filter { session in !session.running && (cutoff.map { session.lastActive < $0 } ?? true) }
    }

    /// Deletes sessions and their workspaces, one after another.
    func delete(_ ids: [Int]) async {
        for id in ids { await delete(id) }
    }

    func workspace(of id: Int) -> URL {
        sessionsRoot.appending(path: String(id), directoryHint: .isDirectory)
    }

    private func index(of id: Int?) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    private static func session(from meta: [String: Any]) -> Session? {
        guard let id = meta["id"] as? Int else { return nil }
        let model = meta["model"] as? [String: Any] ?? [:]
        return Session(
            id: id,
            title: meta["title"] as? String ?? "Session",
            model: ModelRef(provider: model["provider"] as? String ?? "", modelId: model["modelId"] as? String ?? ""),
            thinkingLevel: meta["thinkingLevel"] as? String ?? "off",
            browser: meta["browser"] as? String,
            createdAt: Date(timeIntervalSince1970: (meta["createdAt"] as? Double ?? 0) / 1000),
            lastActive: Date(timeIntervalSince1970: (meta["lastActiveAt"] as? Double ?? meta["createdAt"] as? Double ?? 0) / 1000)
        )
    }

    /// A value as JSON (null for none).
    private static func json(_ value: Any?) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: .fragmentsAllowed) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A panel's HTML, or its view tree as JSON for `panel.html`.
    private static func panelContent(_ value: Any?) -> PanelWebView.Content? {
        guard let content = value as? [String: Any] else { return nil }
        if content["kind"] as? String == "html" { return .html(content["html"] as? String ?? "") }
        guard let data = try? JSONSerialization.data(withJSONObject: content) else { return nil }
        return .view(String(decoding: data, as: UTF8.self))
    }

    // MARK: - On-device model

    /// Loads a downloaded model into the in-app llama-server (one at a time). A load of the same model already under
    /// way (the preload, or another session) is awaited rather than restarted.
    func loadLocalModel(_ file: String) async throws {
        if let load = localModelLoad, load.file == file { return try await load.task.value }
        localModelStatus = "Loading \(file)…"
        let contextSize = localContextSize
        let task = Task { try await localModel.start(models.path(of: file), contextSize: contextSize) }
        localModelLoad = (file, task)
        defer { if localModelLoad?.file == file { localModelLoad = nil } }
        do {
            try await task.value
            localModelStatus = "Loaded \(file) · \(localModel.memoryReport())"
        } catch {
            localModelStatus = error.localizedDescription
            throw error
        }
    }

    /// After the context window changes: pi plans to the new size, and a loaded model restarts with it (the kept one
    /// right away, another on its next use).
    private func applyLocalContextSize() async {
        await updateCustomProviders()
        guard localModel.model != nil else { return }
        log("local-model", "context window \(localContextSize): restarting")
        await localModel.stop()
        preload()
    }

    /// Starts loading the preloaded model once the engine is up, if it is downloaded.
    private func preload() {
        guard phase == .ready, let file = preloadedModel, models.models.contains(file) else { return }
        log("local-model", "preloading \(file)")
        Task { try? await loadLocalModel(file) }
    }

    // MARK: - Engine events

    private func handle(_ event: [String: Any]) {
        defer { watchCompanion.changed() }
        switch event["type"] as? String {
        case "agent_events":
            guard let index = index(of: event["sessionId"] as? Int) else { return }
            for agentEvent in event["events"] as? [[String: Any]] ?? [] { apply(agentEvent, to: index) }
        case "submission_settled":
            let record = event["record"] as? [String: Any] ?? [:]
            let id = event["sessionId"] as? Int
            let status = record["status"] as? String ?? "?"
            // A queued message dropped (taken back, or its run stopped) is no error: it just leaves the queue.
            let submission = record["id"] as? Int
            var wasQueued = false
            if let index = index(of: id), let submission {
                wasQueued = sessions[index].queued.contains { $0.submission == submission } || withdrawnSubmissions.remove(submission) != nil
                sessions[index].queued.removeAll { $0.submission == submission }
            }
            // The run Send now stopped settles unanswered: no error over the new run.
            let stoppedOnPurpose = status == "unanswered" && id.map { stoppedForSendNow.remove($0) != nil } == true
            if let index = index(of: id), status != "done", !wasQueued, !stoppedOnPurpose {
                sessions[index].error = record["reason"] as? String == "no_model"
                    ? "\(displayName(of: sessions[index].model)) isn't available. Choose another model from the title."
                    : localRunsInBackground.contains(sessions[index].id)
                    ? "The on-device model stopped when pi went to the background: iOS doesn't let apps use the GPU there. Send your message again to continue."
                    : record["detail"] as? String ?? record["reason"] as? String ?? status
            }
            if let id { localRunsInBackground.remove(id) }
            log("settled", "[\(id ?? -1)] \(status)")
            if let id, autorunSessions.contains(id), let index = index(of: id) {
                if case .assistant(_, let text, _, _, _) = sessions[index].items.last { log("answer", "[\(id)] \(text)") }
                if localModel.model != nil { log("local-model", "after run: \(localModel.memoryReport())") }
            }
        case "extension_tasks":
            guard let index = index(of: event["sessionId"] as? Int) else { return }
            sessions[index].extensionTasks = (event["tasks"] as? [[String: Any]] ?? []).compactMap { task in
                guard let id = task["id"] as? Int else { return nil }
                return ExtensionTask(id: id, extensionName: task["extension"] as? String ?? "An extension", what: task["what"] as? String ?? "working",
                                     startedAt: Date(timeIntervalSince1970: (task["startedAt"] as? Double ?? 0) / 1000))
            }
        case "ui_request":
            guard let sessionId = event["sessionId"] as? Int, let id = event["id"] as? String else { return }
            let dialog = ExtensionDialog(
                id: id, sessionId: sessionId, extensionName: event["extension"] as? String ?? "",
                kind: event["kind"] as? String ?? "input", title: event["title"] as? String ?? "",
                message: event["message"] as? String, options: event["options"] as? [String] ?? [],
                placeholder: event["placeholder"] as? String, prefill: event["prefill"] as? String
            )
            log("ui", "[\(sessionId)] \(dialog.extensionName) \(dialog.kind): \(dialog.title)")
            dialogs.append(dialog)
            answerTestDialog(dialog)
        case "ui_closed":
            dialogs.removeAll { $0.id == event["id"] as? String }
        case "ui_notify":
            guard let index = index(of: event["sessionId"] as? Int) else { return }
            let notice = Notice(extensionName: event["extension"] as? String ?? "", message: event["message"] as? String ?? "",
                                level: event["level"] as? String ?? "info")
            sessions[index].notice = notice
            log("ui", "[\(sessions[index].id)] \(notice.extensionName) notify (\(notice.level)): \(notice.message)")
        case "ui_status":
            guard let index = index(of: event["sessionId"] as? Int), let key = event["key"] as? String else { return }
            sessions[index].statuses[key] = event["text"] as? String
        case "ui_widget":
            guard let index = index(of: event["sessionId"] as? Int), let key = event["key"] as? String else { return }
            sessions[index].widgets[key] = event["lines"] as? [String]
        case "ui_editor_text":
            guard let index = index(of: event["sessionId"] as? Int) else { return }
            sessions[index].editorText = EditorText(text: event["text"] as? String ?? "", append: event["append"] as? Bool ?? false)
        case "mcp_status":
            Task { await refreshMCP() }
        case "mcp_auth_url":
            if let server = event["server"] as? String, let url = (event["url"] as? String).flatMap(URL.init(string:)) {
                let redirect = (event["redirect"] as? String).flatMap(URL.init(string:))
                log("mcp", "\(server): authorization page \(url.host() ?? "")\(redirect.map { ", caught at \($0.host() ?? $0.scheme ?? "")" } ?? "")")
                mcpLogin = MCPLogin(server: server, url: url, redirect: redirect)
            }
        case "mcp_auth_done":
            if mcpLogin?.server == event["server"] as? String { mcpLogin = nil }
        case "panel_open":
            guard let id = event["id"] as? String, let sessionId = event["sessionId"] as? Int,
                  let content = Self.panelContent(event["content"]) else { return }
            let info = event["app"] as? [String: Any]
            let app = info.flatMap { info in
                (info["key"] as? String).map {
                    PanelApp(key: $0, name: info["name"] as? String ?? $0, icon: info["icon"] as? String, shared: info["shared"] as? Bool ?? false)
                }
            }
            let panel = Panel(id: id, sessionId: sessionId, extensionName: event["extension"] as? String ?? "",
                              placement: event["placement"] as? String ?? "sheet", title: event["title"] as? String, content: content,
                              app: app, state: Self.json(info?["state"]))
            panel.page?.onEvent = { [weak self, weak panel] event in
                guard let self, let panel else { return }
                appPageEvent(event, panel: panel)
            }
            panel.page?.onReady = { [weak panel] in panel?.pageReady = true }
            if let app { panel.expanded = (UserDefaults.standard.stringArray(forKey: Self.expandedAppsKey) ?? []).contains(app.key) }
            log("ui", "[\(sessionId)] \(panel.extensionName) \(app == nil ? "panel (\(panel.placement))" : "app \(app!.name)")")
            // An app opened again replaces its unloaded page.
            if let app { panels.filter { $0.app?.key == app.key && $0.sessionId == sessionId }.forEach { $0.page?.discard() } }
            panels.removeAll { $0.app != nil && $0.app?.key == app?.key && $0.sessionId == sessionId }
            panels.append(panel)
        case "panel_update":
            guard let panel = panels.first(where: { $0.id == event["id"] as? String }),
                  let content = Self.panelContent(event["content"]) else { return }
            if let page = panel.page, case .html(let html) = content { page.load(html) } else { panel.content = content }
        case "panel_message":
            guard let panel = panels.first(where: { $0.id == event["id"] as? String }) else { return }
            let json = Self.json(event["data"])
            if let page = panel.page { page.deliver(json) } else { panel.messages.append(json) }
        case "panel_close":
            panels.filter { $0.id == event["id"] as? String }.forEach { $0.page?.discard() }
            panels.removeAll { $0.id == event["id"] as? String }
        case "panel_show":
            if let panel = panels.first(where: { $0.id == event["id"] as? String }) {
                panel.lastShown = .now
                panel.visible = true
            }
        case "panel_hide":
            if let panel = panels.first(where: { $0.id == event["id"] as? String }), panel.visible {
                panel.visible = false
                unloadExtraPages()
            }
        case "panel_state":
            panels.first { $0.id == event["id"] as? String }?.page?.setState(Self.json(event["state"]))
        case "apps_changed":
            let ids = (event["sessionId"] as? Int).map { [$0] } ?? Array(apps.keys)
            Task { for id in ids where apps[id] != nil { await loadApps(id) } }
        case "sessions_resumed":
            let resumed = event["resumed"] as? [[String: Any]] ?? []
            for run in resumed {
                if let index = index(of: run["sessionId"] as? Int) { sessions[index].running = true }
            }
            log("open", "extensions loaded, \(resumed.count) resumed")
            updateBackground()
            extensionsReady = true
            let waiting = extensionWaiters
            extensionWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
            Task { await BackgroundChecks.shared.refresh(from: engine) }
        case "session_added":
            // A session the engine made (an extension's fork); one the app asked for is already listed.
            if let session = Self.session(from: event["session"] as? [String: Any] ?? [:]), index(of: session.id) == nil {
                sessions.insert(session, at: 0)
                saveSessionList()
            }
        case "session_updated":
            let meta = event["session"] as? [String: Any] ?? [:]
            if let updated = Self.session(from: meta), let index = index(of: updated.id) {
                sessions[index].title = updated.title
                sessions[index].model = updated.model
                sessions[index].browser = updated.browser
                sessions[index].lastActive = updated.lastActive
                saveSessionList()
            }
        case "auth_prompt", "auth_prompt_closed", "auth_event", "auth_done", "auth_failed":
            handleAuth(event)
        default:
            break
        }
    }

    private func apply(_ event: [String: Any], to index: Int) {
        switch event["type"] as? String {
        case "run_start":
            sessions[index].running = true
            updateBackground()
        case "run_end":
            sessions[index].running = false
            sessions[index].tools = []
            updateBackground()
            let id = sessions[index].id
            Task { await refreshContext(id) }
        case "compaction_start":
            sessions[index].compacting = true
            log("compaction", "[\(sessions[index].id)] \(event["reason"] as? String ?? "?")\(event["blocking"] as? Bool == true ? ", blocking" : "")")
        case "compaction_end":
            sessions[index].compacting = false
            log("compaction", "[\(sessions[index].id)] done")
            let id = sessions[index].id
            Task { await refreshContext(id) }
        case "message_start":
            if let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" {
                sessions[index].draft = DraftMessage(message: message)
            }
        case "message_update":
            for change in event["changes"] as? [[String: Any]] ?? [] { sessions[index].draft?.apply(change) }
            backgroundRun.progress(sessions[index].draft?.text.isEmpty == false ? "Writing" : "Thinking")
        case "message_end", "entry_appended":
            guard let entry = event["entry"] as? [String: Any], let item = TranscriptItem(entry: entry) else { return }
            if case .assistant = item { sessions[index].draft = nil }
            if !sessions[index].items.contains(where: { $0.id == item.id }) { sessions[index].items.append(item) }
            // A queued message the agent took: in the transcript now (by its text at once, then as the engine says).
            if case .user(_, let text) = item, !sessions[index].queued.isEmpty {
                if let taken = sessions[index].queued.firstIndex(where: { $0.text == text }) { sessions[index].queued.remove(at: taken) }
                let id = sessions[index].id
                Task { await refreshQueued(id) }
            }
        case "tool_execution_start":
            let tool = ToolRun(id: event["toolCallId"] as? String ?? "", name: event["toolName"] as? String ?? "",
                               arguments: TranscriptItem.arguments(event["args"]))
            sessions[index].tools.append(tool)
            log("tool", "[\(sessions[index].id)] start \(tool.name)")
            backgroundRun.progress("Running \(tool.name)")
        case "tool_execution_update":
            guard let toolIndex = sessions[index].tools.firstIndex(where: { $0.id == event["toolCallId"] as? String }) else { return }
            if let output = event["output"] as? [String: Any] {
                if let set = output["set"] as? String {
                    sessions[index].tools[toolIndex].output = set
                } else {
                    let trim = output["trimStart"] as? Int ?? 0
                    var text = sessions[index].tools[toolIndex].output
                    if trim > 0 { text = String(text.dropFirst(trim)) }
                    sessions[index].tools[toolIndex].output = text + (output["append"] as? String ?? "")
                }
            }
            backgroundRun.progress("Running \(sessions[index].tools[toolIndex].name)")
        case "tool_execution_end":
            sessions[index].tools.removeAll { $0.id == event["toolCallId"] as? String }
            log("tool", "[\(sessions[index].id)] end \(event["toolName"] as? String ?? "")")
        case "snapshot":
            sessions[index].loaded = false
            let id = sessions[index].id
            Task { await loadTranscript(id) }
        default:
            break
        }
    }

    private func handleAuth(_ event: [String: Any]) {
        guard authFlow?.providerId == event["providerId"] as? String else { return }
        log("auth", "\(event["type"] as? String ?? "?") \(Self.describe(event["prompt"] ?? event["event"] ?? event["message"] ?? ""))")
        defer { answerTestPrompt() }
        switch event["type"] as? String {
        case "auth_prompt":
            let prompt = event["prompt"] as? [String: Any] ?? [:]
            authFlow?.prompt = AuthFlow.Prompt(
                id: event["promptId"] as? String ?? "",
                kind: prompt["type"] as? String ?? "text",
                message: prompt["message"] as? String ?? "",
                placeholder: prompt["placeholder"] as? String,
                options: (prompt["options"] as? [[String: Any]] ?? []).map {
                    (id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "")
                }
            )
        case "auth_prompt_closed":
            if authFlow?.prompt?.id == event["promptId"] as? String { authFlow?.prompt = nil }
        case "auth_event":
            let step = event["event"] as? [String: Any] ?? [:]
            switch step["type"] as? String {
            case "auth_url":
                authFlow?.url = (step["url"] as? String).flatMap(URL.init(string:))
                authFlow?.instructions = step["instructions"] as? String
            case "device_code":
                authFlow?.deviceCode = (code: step["userCode"] as? String ?? "",
                                        uri: (step["verificationUri"] as? String).flatMap(URL.init(string:)))
            default:
                if let message = step["message"] as? String { authFlow?.progress.append(message) }
            }
        case "auth_done":
            authFlow?.done = true
            authFlow?.prompt = nil
        case "auth_failed":
            authFlow?.error = event["message"] as? String ?? "Sign-in failed"
            authFlow?.prompt = nil
        default:
            break
        }
    }

    /// Test hook for `-loginTestValue`.
    private func answerTestPrompt() {
        // Not "paste the code" prompts: those race the browser callback being tested.
        guard let value = UserDefaults.standard.string(forKey: "loginTestValue"), let prompt = authFlow?.prompt,
              prompt.kind != "manual_code"
        else { return }
        let answer = prompt.kind == "select" ? prompt.options.first?.id : value
        log("auth", "test answers \(prompt.kind) prompt")
        answerAuthPrompt(answer)
    }

    private static func describe(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value)
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Background

    /// One continued-processing task covers every running session.
    private func updateBackground() {
        let running = sessions.contains { $0.running }
        // While pi works in front, the screen stays on: auto-lock would send the app to the background mid-run.
        UIApplication.shared.isIdleTimerDisabled = running
        if !running { endBackgroundTask() }
        if running && !backgroundActive {
            backgroundActive = true
            backgroundRun.begin(title: "pi is working")
        } else if !running && backgroundActive {
            backgroundActive = false
            backgroundRun.end(success: true)
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        // iOS calls the expiration handler on the main thread.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pi run") { [weak self] in
            MainActor.assumeIsolated {
                log("background", "background time expired")
                self?.endBackgroundTask()
            }
        }
        // backgroundTimeRemaining is Double.greatestFiniteMagnitude until iOS starts counting (Int() of it traps).
        let remaining = UIApplication.shared.backgroundTimeRemaining
        log("background", remaining < 3600 ? "background time requested (\(Int(remaining))s left)" : "background time requested")
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func lifecycle(_ state: String) {
        watchCompanion.changed()
        log("lifecycle", state)
        if state == "background" {
            wentToBackground = true
            BackgroundChecks.shared.schedule()
            if sessions.contains(where: \.running) { beginBackgroundTask() }
            // iOS refuses GPU work in the background, so an on-device model's reply in progress fails now.
            for session in sessions where session.running && session.model.provider == "ondevice" {
                localRunsInBackground.insert(session.id)
            }
        }
        if state == "active" {
            endBackgroundTask()
            // What background checks wanted to ask while pi couldn't.
            Task { await ExtensionPermissions.shared.askPending() }
        }
        if state == "active", wentToBackground {
            wentToBackground = false
            // MCP connections the phone dropped while away reconnect now, before the agent needs them.
            Task { _ = try? await engine.command("mcp.resume") }
            // Extensions installed from GitHub that changed (the engine checks at most every few hours).
            Task { _ = try? await engine.command("extensions.checkUpdates") }
            Task { await resumed() }
        }
        // Diagnostics: shows whether the app process keeps running in the background.
        heartbeat?.invalidate()
        heartbeat = state == "background" && sessions.contains(where: \.running)
            ? Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in log("heartbeat", "app running") }
            : nil
    }

    /// Back in the foreground: a loaded on-device model that stopped working while the app was in the background (its
    /// listener gone, or its GPU backend failed by work iOS refused) starts again now, before the user sends anything.
    /// `-autorunOnActive "prompt"` (automated runs) then prompts the autorun session again.
    private func resumed() async {
        // A reply in progress (it holds the server's one slot) is left alone.
        if let loaded = localModel.model, !sessions.contains(where: { $0.running && $0.model.provider == "ondevice" }) {
            let generates = await localModel.generates()
            log("local-model", "after resume: \(generates ? "generating" : "not generating") · \(localModel.memoryReport())")
            if !generates {
                await localModel.stop()
                try? await loadLocalModel(loaded)
            }
        }
        if let prompt = UserDefaults.standard.string(forKey: "autorunOnActive"), let id = autorunSessions.first {
            await send(prompt, to: id)
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        log("error", message)
    }

    // MARK: - Shell diagnostics

    /// `-shellTest YES`: runs commands through the engine's ExecutionEnv, as pi's bash tool would, and logs each result.
    private func runShellTest() async {
        let custom = UserDefaults.standard.string(forKey: "shellCommands")?.components(separatedBy: " ;; ")
        for command in custom ?? ["echo hello", "ls -la | grep -c .", "python3 -c 'print(6 * 7)'"] {
            do {
                let result = try await engine.command("debug.exec", ["command": command, "timeout": 10]) as? [String: Any] ?? [:]
                let output = (result["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ⏎ ")
                let status = result["error"].map { "error=\($0)" } ?? "exit=\(result["exitCode"] ?? "?")"
                log("shell", "\(status) \(result["ms"] ?? "?")ms $ \(command) → \(output.prefix(240))")
            } catch {
                log("shell", "bridge error $ \(command) → \(error.localizedDescription)")
            }
        }
        log("shell", "battery done")
    }
}

enum AppError: LocalizedError {
    case noModel
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noModel: "No model available. Sign in to a provider, download an on-device model, or add a network endpoint in Settings."
        case .message(let text): text
        }
    }
}

private let logger = Logger(subsystem: "dev.pimobile", category: "engine")

func log(_ tag: String, _ message: String) {
    logger.notice("[\(tag, privacy: .public)] \(message, privacy: .public)")
    // Also on stderr (unbuffered), where `devicectl device process launch --console` shows it for device runs.
    let time = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    FileHandle.standardError.write(Data("\(time) [\(tag)] \(message)\n".utf8))
}
