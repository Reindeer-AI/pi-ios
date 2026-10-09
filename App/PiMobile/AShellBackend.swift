import Foundation
import ios_system
import PiEngineKit

/// pi's shell on iOS, built from a-Shell's components: ios_system runs commands in-process (iOS has no
/// subprocesses), and dash interprets each command, so pi's bash tool gets POSIX shell syntax.
///
/// ios_system keeps its current session and working directory process-wide, so commands run one at a time on a
/// serial queue. Each command is written to a script file and run as `dash <file>`, which avoids re-quoting it.
final class AShellBackend: ShellBackend, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.pimobile.ashell")
    /// Shell functions every command starts with (pip, which); sourced on the command's first line, so the command's
    /// own line numbers stay as written.
    private let prelude: String = {
        guard let path = Bundle.main.path(forResource: "shell-prelude", ofType: "sh") else {
            preconditionFailure("shell-prelude.sh is missing from the app bundle")
        }
        return path
    }()
    private let session = UnsafePointer(strdup("pi-engine")!)
    private let lock = NSLock()
    private var runningID: String?
    private var runningPid: pid_t?
    /// Commands stopped while they waited for the shell.
    private var cancelled: Set<String> = []

    /// Size of ios_system's process table (IOS_MAX_THREADS); pids wrap within it.
    private static let maxPids: pid_t = 128

    init() {
        // curl, lg2, and Python's ssl module verify TLS against the bundled CA certificates.
        if let certificates = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            setenv("CURL_CA_BUNDLE", certificates, 1)
            setenv("SSL_CERT_FILE", certificates, 1)
        }
        // tar: no AppleDouble (._name) entries for extended attributes.
        setenv("COPYFILE_DISABLE", "1", 1)
        // python3: the standard library is in the (read-only) bundle; bytecode caches and `pip install --user`
        // packages go to the app's Library.
        let library = URL.libraryDirectory
        setenv("PYTHONHOME", Bundle.main.bundleURL.appending(path: "python").path, 1)
        setenv("PYTHONPYCACHEPREFIX", library.appending(path: "Caches/python").path, 1)
        setenv("PYTHONUSERBASE", library.appending(path: "python").path, 1)
        // Python finds its compiled modules (Frameworks/*.framework) next to sys.executable, which inside the shell is
        // just "python3"; sitecustomize.py sets it to the app's executable from this.
        setenv("PYTHONEXECUTABLE", Bundle.main.executablePath!, 1)
        initializeEnvironment()
        // ios_system globals, set through their symbols (Swift 6 rejects direct writes to imported C globals):
        // - joinMainThread = false, as in a-Shell: ios_system returns once a command has started; callers wait with
        //   ios_waitpid.
        // - numDashCommands = 1: ios_system's pipe handling and cleanup only recognize its primary `dash` copy (the
        //   dashA-E copies break pipelines). Commands run one at a time, so the primary copy is always free.
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        dlsym(defaultHandle, "joinMainThread")?.assumingMemoryBound(to: Bool.self).pointee = false
        dlsym(defaultHandle, "numDashCommands")?.assumingMemoryBound(to: Int32.self).pointee = 1
        // - numPythonInterpreters = 1: the same rotation for Python (copies we do not ship).
        dlsym(defaultHandle, "numPythonInterpreters")?.assumingMemoryBound(to: Int32.self).pointee = 1
    }

    func run(_ command: ShellCommand, output: @escaping @Sendable (Data) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: runNow(command, output: output))
            }
        }
    }

    func kill(id: String) {
        lock.withLock {
            // Still waiting for the shell (another session's command runs): it will not run at all.
            guard runningID == id, let pid = runningPid else {
                cancelled.insert(id)
                return
            }
            // A Python program: SystemExit, raised in it as Ctrl-C would (PythonCommand.m). Its thread must then not be cancelled
            // as well: cancelled while the interpreter cleans up, it would leave the output pipe open.
            var python: pthread_t?
            if let interrupt = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pimobile_python_interrupt") {
                let thread = unsafeBitCast(interrupt, to: (@convention(c) () -> UInt).self)()
                if thread != 0 { python = pthread_t(bitPattern: thread) }
            }
            // Our dash build unwinds at its next interrupt check instead of raising SIGINT (which would end the app).
            if let interrupt = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dash_ios_interrupt") { // RTLD_DEFAULT
                unsafeBitCast(interrupt, to: (@convention(c) () -> Void).self)()
            }
            // Commands dash started have the pids after its own (commands are serialized, so all of them belong to
            // this run). They block in cancellable system calls; cancelling runs ios_system's cleanup, which marks
            // them finished, so dash's waits return and it reaches the interrupt check.
            for offset in 1..<Self.maxPids {
                let child = (pid + offset) % Self.maxPids
                let thread = ios_getThreadId(child)
                if Int(bitPattern: thread) > 0, thread != python { pthread_cancel(thread!) }
            }
        }
    }

    private func runNow(_ command: ShellCommand, output: @escaping @Sendable (Data) -> Void) -> Int32 {
        if lock.withLock({ cancelled.remove(command.id) != nil }) { return 130 }
        let script = URL(filePath: NSTemporaryDirectory()).appending(path: "pi-\(command.id).sh")
        do {
            try Data(". '\(prelude)'; \(command.command)".utf8).write(to: script)
        } catch {
            output(Data("dash: cannot write script: \(error.localizedDescription)\n".utf8))
            return 127
        }
        defer { try? FileManager.default.removeItem(at: script) }

        // Combined stdout/stderr through one pipe, drained on its own thread so a full pipe never blocks the command.
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0, let writer = fdopen(descriptors[1], "w"), let input = fopen("/dev/null", "r") else {
            output(Data("dash: cannot create pipe\n".utf8))
            return 127
        }
        setvbuf(writer, nil, _IONBF, 0)
        let readEnd = descriptors[0]
        let drained = DispatchSemaphore(value: 0)
        // Set once the command has finished: the reader then takes what is left and stops, even if something the command
        // started still holds a copy of the pipe open (a stopped program can leave one), which would never give it EOF.
        let finished = Finished()
        OutputReader(descriptor: readEnd, commandDone: finished, output: output, drained: drained).start()

        ios_switchSession(session)
        ios_setDirectoryURL(URL(filePath: command.cwd))
        ios_setStreams(input, writer, writer)
        // The variables are this command's alone (an extension's secrets among them): the next command, perhaps the
        // agent's, finds the shell's environment as it was.
        let previous = command.environment.keys.map { name in (name, ios_getenv(name).map { String(cString: $0) }) }
        defer {
            for (name, value) in previous {
                if let value { ios_setenv(name, value, 1) } else { ios_unsetenv(name) }
            }
        }
        for (name, value) in command.environment { ios_setenv(name, value, 1) }

        let pid = ios_fork()
        lock.withLock { (runningID, runningPid) = (command.id, pid) }
        var status = ios_system("dash '\(script.path)'")
        ios_waitpid(pid)
        ios_releaseThreadId(pid)
        // A non-zero result means ios_system itself failed (e.g. command not found); otherwise the command's status.
        if status == 0 { status = ios_getCommandStatus() }
        lock.withLock { (runningID, runningPid) = (nil, nil) }

        fflush(writer)
        fclose(writer)
        fclose(input)
        finished.value = true
        drained.wait()
        return status
    }
}

/// A flag the command's thread sets and the output reader polls.
private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// Drains a command's output pipe on its own thread until the command has finished and the pipe is empty or closed.
/// A Thread subclass rather than `Thread { }`: Xcode 26.3's compiler made that block main-actor isolated, and the check
/// it added trapped when the block ran (0.1.78, at the first shell command).
private final class OutputReader: Thread, @unchecked Sendable {
    private let descriptor: Int32
    private let commandDone: Finished
    private let output: @Sendable (Data) -> Void
    private let drained: DispatchSemaphore

    init(descriptor: Int32, commandDone: Finished, output: @escaping @Sendable (Data) -> Void, drained: DispatchSemaphore) {
        self.descriptor = descriptor
        self.commandDone = commandDone
        self.output = output
        self.drained = drained
        super.init()
    }

    override func main() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&poller, 1, 200)
            if ready == 0 {
                if commandDone.value { break }
                continue
            }
            if ready < 0 && errno == EINTR { continue }
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            output(Data(buffer.prefix(count)))
        }
        close(descriptor)
        drained.signal()
    }
}
