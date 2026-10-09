import AppKit
import PiEngineKit

// Spike harness: runs the engine in macOS WebKit (same WebKit/URLSession code paths as iOS) against an
// OpenAI-compatible endpoint.
//
//   swift run pi-engine-harness [options] [prompt...]
//
//   --bundle DIR                engine bundle (default: ../engine/dist)
//   --base-url URL              OpenAI-compatible endpoint (default: local Ollama)
//   --model ID                  model id (default: gemma4:12b)
//   --storage NAME              durable native SQLite storage (default: a fresh store per run)
//   --resume                    send no prompt; wait for the run a previous process left unfinished
//   --kill-on KIND:N            exit abruptly after N `delta`s or `tool` updates (simulates the app being killed)
//   --kill-webcontent-on KIND:N kill WebKit's content process after N deltas/tool updates, then restart the engine
//
// Environment: PI_HARNESS_API_KEY (endpoint key), PI_NET_TRACE (proxy trace), PI_HARNESS_OFFSCREEN (offscreen window).
// Exit status: 0 when the run settles `done`.

struct Trigger {
    enum Kind: String { case delta, tool }
    let kind: Kind
    let count: Int

    init?(_ text: String?) {
        guard let parts = text?.split(separator: ":"), parts.count == 2,
              let kind = Kind(rawValue: String(parts[0])), let count = Int(parts[1])
        else { return nil }
        self.kind = kind
        self.count = count
    }
}

struct Options {
    var bundle = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "engine/dist")
    var baseURL = "http://127.0.0.1:11434/v1"
    var model = "gemma4:12b"
    var prompt = "In one short sentence: what is the capital of France?"
    var storage: String?
    var resume = false
    var killOn: Trigger?
    var killWebContentOn: Trigger?

    init(arguments: [String]) {
        var rest = arguments.dropFirst()
        var words: [String] = []
        while let argument = rest.popFirst() {
            switch argument {
            case "--bundle": bundle = URL(filePath: rest.popFirst() ?? "")
            case "--base-url": baseURL = rest.popFirst() ?? baseURL
            case "--model": model = rest.popFirst() ?? model
            case "--storage": storage = rest.popFirst()
            case "--resume": resume = true
            case "--kill-on": killOn = Trigger(rest.popFirst())
            case "--kill-webcontent-on": killWebContentOn = Trigger(rest.popFirst())
            default: words.append(argument)
            }
        }
        if !words.isEmpty { prompt = words.joined(separator: " ") }
    }
}

@MainActor
final class Harness {
    let options = Options(arguments: CommandLine.arguments)
    let engine: PiEngine
    let sqlite = SQLiteService(
        directory: URL.applicationSupportDirectory.appending(path: "pi-engine-harness", directoryHint: .isDirectory)
    )
    let files = FileService()
    let shell = ShellService(backend: ProcessShellBackend())
    let keychain = KeychainService(service: "dev.pimobile.harness")
    let loopback = LoopbackService()
    let workspace = URL.applicationSupportDirectory.appending(path: "pi-engine-harness/workspace", directoryHint: .isDirectory)
    let window = NSWindow(
        contentRect: ProcessInfo.processInfo.environment["PI_HARNESS_OFFSCREEN"] != nil
            ? NSRect(x: -10_000, y: -10_000, width: 1, height: 1)
            : NSRect(x: 0, y: 0, width: 1, height: 1),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    var started = Date()
    var deltaTimes: [TimeInterval] = []
    var toolUpdates = 0
    var awaiting: Set<Int> = []
    var webContentKilled = false

    init() {
        engine = PiEngine(bundleDirectory: options.bundle)
        sqlite.install(on: engine)
        files.install(on: engine)
        shell.install(on: engine)
        keychain.install(on: engine)
        loopback.install(on: engine)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // Keep the engine attached to an on-screen window: WebKit stops running pages whose window is offscreen.
        window.contentView?.addSubview(engine.webView)
        window.orderFrontRegardless()
    }

    func run() async {
        engine.onLog = { level, message in log("console.\(level)", message) }
        if ProcessInfo.processInfo.environment["PI_NET_TRACE"] != nil {
            engine.onNetTrace = { line in log("net", line) }
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.onTermination = { [weak self] in
            log("engine", "WebKit content process terminated")
            Task { @MainActor in await self?.restartEngine() }
        }
        if let storage = options.storage { log("storage", sqlite.path(for: storage).path) }
        log("workspace", workspace.path)

        do {
            let ready = try await engine.start()
            log("ready", "secureContext=\(ready.secureContext) webAssembly=\(ready.webAssembly)")
            started = Date()
            try await configure()
            if options.resume {
                if awaiting.isEmpty { log("resume", "nothing to resume"); exit(1) }
            } else {
                try await prompt()
            }
        } catch {
            log("error", error.localizedDescription)
            exit(1)
        }

        try? await Task.sleep(for: .seconds(300))
        log("timeout", "no settlement after 300s")
        exit(2)
    }

    /// Opens the durable store; a run a previous process left unfinished resumes (and is awaited).
    func configure() async throws {
        var provider: [String: Any] = [
            "id": "local",
            "name": "Local OpenAI-compatible",
            "baseUrl": options.baseURL,
            "models": [["id": options.model, "contextWindow": 32768, "maxTokens": 4096]],
        ]
        if let key = ProcessInfo.processInfo.environment["PI_HARNESS_API_KEY"] { provider["apiKey"] = key }
        let result = try await engine.command("open", [
            "storage": options.storage ?? "harness-\(ProcessInfo.processInfo.processIdentifier)",
            "sessionsRoot": workspace.path,
            "providers": [provider],
            "debugTools": true,
        ]) as? [String: Any] ?? [:]
        for resumed in result["resumed"] as? [[String: Any]] ?? [] {
            if let id = resumed["submissionId"] as? Int { awaiting.insert(id) }
        }
        log("open", json(result))
    }

    /// A new session on the configured endpoint, prompted with `options.prompt`.
    func prompt() async throws {
        let session = try await engine.command("session.create", ["provider": "local", "modelId": options.model]) as? [String: Any]
        guard let id = session?["id"] as? Int else { throw EngineError.unknownMethod("session.create") }
        log("prompt", options.prompt)
        let result = try await engine.command("session.prompt", ["id": id, "text": options.prompt]) as? [String: Any]
        if let submission = result?["submissionId"] as? Int { awaiting.insert(submission) }
        log("submitted", "session \(id): \(json(result ?? [:]))")
    }

    /// After WebKit's content process dies: reload the engine page and reopen the same storage.
    func restartEngine() async {
        do {
            let restartBegan = Date()
            _ = try await engine.start()
            try await configure()
            log("engine", String(format: "restarted and reconfigured in %.2fs", Date().timeIntervalSince(restartBegan)))
        } catch {
            log("error", "engine restart failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "agent_events":
            for agentEvent in event["events"] as? [[String: Any]] ?? [] { handleAgentEvent(agentEvent) }
        case "submission_settled":
            let record = event["record"] as? [String: Any] ?? [:]
            guard let id = record["id"] as? Int, awaiting.remove(id) != nil else { return }
            let status = record["status"] as? String ?? "?"
            print()
            log("settled", "submission \(id) status=\(status)")
            if status != "done" { log("record", json(record)) }
            report()
            exit(status == "done" ? 0 : 1)
        case "submission_failed":
            log("failed", json(event))
            exit(1)
        default:
            log("event", json(event))
        }
    }

    func handleAgentEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? "?"
        switch type {
        case "message_update":
            for change in event["changes"] as? [[String: Any]] ?? [] {
                // A block's first text arrives in its `*_start` change; later text in `*_delta` changes.
                let block = change["block"] as? [String: Any]
                let (kind, delta): (String?, String?) = switch change["type"] as? String {
                case "text_start": ("text_delta", block?["text"] as? String)
                case "thinking_start": ("thinking_delta", block?["thinking"] as? String)
                case let type: (type, change["delta"] as? String)
                }
                guard let kind, kind == "text_delta" || kind == "thinking_delta", let delta, !delta.isEmpty else { continue }
                if deltaTimes.isEmpty { print() }
                deltaTimes.append(Date().timeIntervalSince(started))
                FileHandle.standardOutput.write(Data((kind == "thinking_delta" ? "\u{1B}[2m\(delta)\u{1B}[0m" : delta).utf8))
                checkTriggers(.delta, deltaTimes.count)
            }
        case "message_end":
            print()
            // Assistant messages that failed carry stopReason "error" and the provider's message.
            let message = entryMessage(event)
            if let stopReason = message["stopReason"] as? String, stopReason == "error" || stopReason == "aborted" {
                log("agent", "message_end \(stopReason): \(message["errorMessage"] as? String ?? json(message))")
            } else {
                log("agent", "message_end \(message["role"] as? String ?? "")")
            }
        case "tool_execution_start":
            log("tool", "start \(event["toolName"] as? String ?? "?") \(json(event["args"] ?? [:]))")
        case "tool_execution_update":
            toolUpdates += 1
            if let output = event["output"] as? [String: Any], let text = output["append"] as? String ?? output["set"] as? String {
                log("tool", "output \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            checkTriggers(.tool, toolUpdates)
        case "tool_execution_end":
            let result = entryMessage(event)
            log("tool", "end \(event["toolName"] as? String ?? "?") isError=\(result["isError"] as? Bool ?? false) \(json(result["content"] ?? []))")
        case "snapshot":
            log("agent", "snapshot entries=\((event["entries"] as? [Any])?.count ?? 0)")
        case "task_failed", "auto_retry_start":
            log("agent", json(event))
        default:
            log("agent", type)
        }
    }

    func checkTriggers(_ kind: Trigger.Kind, _ count: Int) {
        if let trigger = options.killOn, trigger.kind == kind, trigger.count == count {
            print()
            log("kill", "exiting abruptly after \(count) \(kind) events")
            _exit(9)
        }
        if let trigger = options.killWebContentOn, trigger.kind == kind, trigger.count == count, !webContentKilled {
            webContentKilled = true
            // Test-only private accessor for the content process pid.
            guard let pid = (engine.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else {
                log("error", "cannot find WebKit content process")
                exit(1)
            }
            print()
            log("kill", "killing WebKit content process \(pid) after \(count) \(kind) events")
            kill(pid, SIGKILL)
        }
    }

    /// An entry's model-facing message: entry records keep it in `model[0]`; `data` holds entry metadata.
    func entryMessage(_ event: [String: Any]) -> [String: Any] {
        ((event["entry"] as? [String: Any])?["model"] as? [[String: Any]])?.first ?? [:]
    }

    func report() {
        guard let first = deltaTimes.first, let last = deltaTimes.last else {
            return log("stream", "no text deltas received")
        }
        log("stream", String(format: "%d deltas · first after %.2fs · last after %.2fs", deltaTimes.count, first, last))
    }
}

@MainActor
func log(_ tag: String, _ message: String) {
    print("[\(tag)] \(message)")
}

func json(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let harness = Harness()
Task { @MainActor in await harness.run() }
app.run()
