import BackgroundTasks
import Foundation

/// Keeps a user-started run going after the app leaves the foreground, using iOS 26 continued processing
/// (`BGContinuedProcessingTask`). The system shows the run's progress and may still end it under resource pressure;
/// pi-durable resumes the run on the next launch in that case.
@MainActor
final class BackgroundRun {
    /// Under the app's bundle ID, as `BGTaskSchedulerPermittedIdentifiers` declares (`$(PRODUCT_BUNDLE_IDENTIFIER).run.*`).
    static let identifierPrefix = "\(Bundle.main.bundleIdentifier ?? "dev.pimobile.PiMobile").run"

    private let log: (String, String) -> Void
    /// The task the current run asked for; nil once the run is over.
    private var requested: String?
    private var task: AnyObject?
    private var started = Date.now
    private var subtitle = ""
    private var ticker: Task<Void, Never>?

    init(log: @escaping (String, String) -> Void) {
        self.log = log
    }

    /// Asks the system to keep running while a run is in progress.
    func begin(title: String) {
        end()
        // `-noBackgroundTask YES` measures the baseline: what happens to a run in the background without this task.
        guard !UserDefaults.standard.bool(forKey: "noBackgroundTask") else {
            return log("background", "continued processing disabled by launch argument")
        }
        // Continued-processing handlers may be registered at any time. Each run registers one concrete identifier
        // under the `BGTaskSchedulerPermittedIdentifiers` wildcard; submitting without a registered handler crashes.
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated { self?.attach(task) }
        }
        guard registered else {
            return log("background", "launch handler registration rejected for \(identifier)")
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            requested = identifier
            log("background", "continued processing requested")
        } catch {
            log("background", "continued processing request failed: \(error.localizedDescription)")
        }
    }

    /// Reports what the run is doing.
    func progress(_ subtitle: String) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        if subtitle != self.subtitle {
            self.subtitle = subtitle
            task.updateTitle(task.title, subtitle: subtitle)
        }
        advance(task)
    }

    /// The run is over, however it ended: its task leaves the Live Activities.
    func end() {
        requested = nil
        guard let task = task as? BGContinuedProcessingTask else { return }
        finish(task)
        log("background", "continued processing ended")
    }

    private func attach(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        // The run ended (or another began) before iOS started this task: left alone, it would expire as failed.
        guard task.identifier == requested else {
            task.setTaskCompleted(success: true)
            return log("background", "continued processing started after its run ended; finished it")
        }
        self.task = task
        started = .now
        subtitle = ""
        task.progress.totalUnitCount = 1_000_000_000
        let identifier = task.identifier
        task.expirationHandler = onAnyThread { [weak self] in
            guard let self, let task = self.task as? BGContinuedProcessingTask, task.identifier == identifier else { return }
            self.log("background", "continued processing expired")
            self.finish(task)
        }
        // The system ends a task whose progress stops moving, and a tool can run for minutes without a word.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let task = self.task as? BGContinuedProcessingTask else { return }
                self.advance(task)
            }
        }
        log("background", "continued processing started")
    }

    /// Moves with time, nearing the end without reaching it for hours (a count of updates reached its cap within one long
    /// reply and stood still from then on).
    private func advance(_ task: BGContinuedProcessingTask) {
        let total = task.progress.totalUnitCount
        let elapsed = Double(total) * (1 - exp(-Date.now.timeIntervalSince(started) / 600))
        task.progress.completedUnitCount = min(max(Int64(elapsed), task.progress.completedUnitCount + 1), total - 1)
    }

    /// Always as a success: a failed task stays in the Live Activities until dismissed, and pi-durable resumes a run iOS
    /// cut short on the next launch anyway.
    private func finish(_ task: BGContinuedProcessingTask) {
        ticker?.cancel()
        ticker = nil
        self.task = nil
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: true)
    }
}

/// iOS calls a task's expiration handler on a background queue. A closure written in a main-actor type would be
/// main-actor isolated, and Swift traps when it runs anywhere else (it ended the app when a background run expired).
/// Made here, at file scope, it is not isolated and hands the work to the main actor.
private func onAnyThread(_ work: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
    { Task { @MainActor in work() } }
}
