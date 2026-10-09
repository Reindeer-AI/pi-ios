import Foundation
import LlamaServerSupport

/// Runs llama-server in-process for one downloaded model, serving an OpenAI-compatible endpoint on the loopback
/// interface. pi reaches it through the engine's native network proxy like any other provider.
@MainActor
final class LocalModel {
    static let port = 8088
    static let baseURL = "http://127.0.0.1:\(port)/v1"
    /// The default context window; the app's setting chooses the one the server runs with.
    static let contextSize = 8192

    private(set) var model: String?
    /// The running server's context window.
    private(set) var contextSize: Int?
    private var thread: Thread?
    private let log: (String, String) -> Void

    init(log: @escaping (String, String) -> Void) {
        self.log = log
    }

    /// Starts the server for `file` with `contextSize` (stopping another model, or this one at another size, first) and
    /// waits until it reports healthy.
    func start(_ file: URL, contextSize: Int = LocalModel.contextSize) async throws {
        if model == file.lastPathComponent, self.contextSize == contextSize {
            if await isHealthy() { return }
            log("local-model", "\(file.lastPathComponent) is loaded but not answering: restarting it")
        }
        await stop()
        let arguments = [
            "--model", file.path,
            "--host", "127.0.0.1", "--port", String(Self.port),
            "--ctx-size", String(contextSize),
            "--parallel", "1",
            "--n-gpu-layers", "99",
            "--jinja",
            // A model's thinking phase costs minutes per reply at on-device speeds.
            "--reasoning", "off",
        ]
        log("local-model", "starting llama-server: \(file.lastPathComponent)")
        let started = Date()
        let thread = ServerThread(arguments: arguments) { [weak self] status in
            self?.log("local-model", "llama-server exited with status \(status)")
            self?.model = nil
            self?.contextSize = nil
            self?.thread = nil
        }
        thread.name = "llama-server"
        thread.stackSize = 16 << 20
        thread.start()
        self.thread = thread

        // Loading maps the weights and prepares Metal; wait for /health.
        let health = URL(string: "http://127.0.0.1:\(Self.port)/health")!
        while true {
            if self.thread == nil { throw LocalModelError.exited }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 { break }
            if Date().timeIntervalSince(started) > 180 { throw LocalModelError.timedOut }
            try await Task.sleep(for: .milliseconds(250))
        }
        model = file.lastPathComponent
        self.contextSize = contextSize
        log("local-model", String(format: "ready in %.1fs · context %d · %@", Date().timeIntervalSince(started), contextSize, memoryReport()))
    }

    /// Whether the server answers its health check, trying three times over about a second and a half: after the app
    /// was suspended, iOS has taken back the server's listening socket, and the server listens again on a new one
    /// (our llama.cpp patch) once a connection finds the old one gone.
    func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        request.timeoutInterval = 2
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return true }
        }
        return false
    }

    /// Whether the server generates: one token from a short prompt. A server can answer its health check and still fail
    /// every generation: iOS refuses GPU work from an app in the background, and llama.cpp's Metal backend stays failed
    /// after that until the server restarts.
    func generates() async -> Bool {
        guard await isHealthy() else { return false }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/completion")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": "Hi", "n_predict": 1])
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Stops the server and waits for it, at most 15 seconds (a server that does not stop is left behind, logged).
    func stop() async {
        guard thread != nil else { return }
        LocalModelServer.terminate()
        let asked = Date()
        while thread != nil {
            if Date().timeIntervalSince(asked) > 15 {
                log("local-model", "llama-server did not stop within 15 s")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The app's physical memory footprint (what iOS's memory limit counts) and the limit's remaining headroom.
    func memoryReport() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e9 : -1
        return String(format: "footprint %.2f GB, headroom %.2f GB", footprint, Double(os_proc_available_memory()) / 1e9)
    }
}

enum LocalModelError: LocalizedError {
    case exited, timedOut

    var errorDescription: String? {
        switch self {
        case .exited: "llama-server stopped while loading the model (see the console log)"
        case .timedOut: "llama-server did not become ready within 3 minutes"
        }
    }
}

/// llama-server's own thread. A subclass, outside any main-actor type, so no closure runs on the thread: Xcode 26.3's
/// compiler made the `Thread { }` block main-actor isolated even from a nonisolated function, and the check it added
/// trapped as the thread started (0.1.76, 0.1.77).
private final class ServerThread: Thread, @unchecked Sendable {
    private let arguments: [String]
    private let exited: @MainActor @Sendable (Int32) -> Void

    init(arguments: [String], exited: @escaping @MainActor @Sendable (Int32) -> Void) {
        self.arguments = arguments
        self.exited = exited
        super.init()
    }

    override func main() {
        let status = LocalModelServer.run(arguments: arguments)
        let exited = exited
        Task { @MainActor in exited(status) }
    }
}
