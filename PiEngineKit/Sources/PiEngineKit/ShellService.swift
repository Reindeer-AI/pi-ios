import Foundation

/// One command for a `ShellBackend`.
public struct ShellCommand: Sendable {
    public let id: String
    public let command: String
    public let cwd: String
    /// Variables to set for this command, on top of the inherited environment.
    public let environment: [String: String]
}

/// Runs shell commands. iOS has no subprocesses, so the app supplies an in-process backend (ios_system); the macOS
/// harness uses `/bin/sh`.
public protocol ShellBackend: Sendable {
    /// Runs the command, calling `output` with combined stdout/stderr bytes in order, and returns its exit status.
    func run(_ command: ShellCommand, output: @escaping @Sendable (Data) -> Void) async -> Int32
    /// Stops a running command. The engine settles the call as aborted or timed out.
    func kill(id: String)
}

/// The engine's `shell` service: `exec` streams output back as `shell.output` engine commands, in order, and replies
/// with the exit code once all output has been delivered; `kill` stops a command.
@MainActor
public final class ShellService {
    private let backend: any ShellBackend
    private weak var engine: PiEngine?
    private var running: Set<String> = []

    public init(backend: any ShellBackend) {
        self.backend = backend
    }

    public func install(on engine: PiEngine) {
        self.engine = engine
        engine.register(service: "shell") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("shell") }
            let arguments = JSONValue(bridged: params)
            switch method {
            case "exec": return try await self.exec(arguments)
            case "kill":
                self.backend.kill(id: arguments["id"]?.string ?? "")
                return nil
            default: throw EngineError.unknownMethod("shell.\(method)")
            }
        }
    }

    /// Stops every running command, for when the engine that started them is gone (WebKit's process was killed). The
    /// restarted engine settles their tool calls as interrupted.
    public func stopAll() {
        for id in running { backend.kill(id: id) }
    }

    private func exec(_ arguments: JSONValue) async throws -> Any? {
        guard let id = arguments["id"]?.string, let command = arguments["command"]?.string,
              let cwd = arguments["cwd"]?.string
        else { throw EngineError.unknownMethod("shell.exec: missing id, command, or cwd") }
        let environment = (arguments["env"]?.object ?? [:]).compactMapValues(\.string)
        let shellCommand = ShellCommand(id: id, command: command, cwd: cwd, environment: environment)

        // Output chunks are forwarded strictly in order; the reply waits until the last one is delivered.
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        let forwarding = Task { @MainActor [weak engine] in
            for await chunk in chunks {
                _ = try? await engine?.command("shell.output", ["id": id, "data": chunk.base64EncodedString()])
            }
        }
        running.insert(id)
        let status = await backend.run(shellCommand) { continuation.yield($0) }
        running.remove(id)
        continuation.finish()
        await forwarding.value
        return ["exitCode": Int(status)]
    }
}

#if os(macOS)
/// `/bin/sh -c` backend for the macOS harness.
public final class ProcessShellBackend: ShellBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: Process] = [:]

    public init() {}

    public func run(_ command: ShellCommand, output: @escaping @Sendable (Data) -> Void) async -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command.command]
        process.currentDirectoryURL = URL(filePath: command.cwd)
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            let reader = pipe.fileHandleForReading
            let drained = DispatchSemaphore(value: 0)
            reader.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    drained.signal()
                } else {
                    output(data)
                }
            }
            process.terminationHandler = { [weak self] process in
                drained.wait()
                self?.forget(command.id)
                continuation.resume(returning: process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus)
            }
            do {
                try process.run()
                lock.withLock { running[command.id] = process }
            } catch {
                reader.readabilityHandler = nil
                output(Data("sh: \(error.localizedDescription)\n".utf8))
                continuation.resume(returning: 127)
            }
        }
    }

    public func kill(id: String) {
        lock.withLock { running[id] }?.terminate()
    }

    private func forget(_ id: String) {
        lock.withLock { _ = running.removeValue(forKey: id) }
    }
}
#endif
