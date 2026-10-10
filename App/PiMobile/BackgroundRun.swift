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
    private var task: AnyObject?
    private var completedUnits: Int64 = 0

    init(log: @escaping (String, String) -> Void) {
        self.log = log
    }

    /// Asks the system to keep running while a run is in progress.
    func begin(title: String) {
        end(success: false)
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
            log("background", "continued processing requested")
        } catch {
            log("background", "continued processing request failed: \(error.localizedDescription)")
        }
    }

    /// Reports progress; the system ends tasks that stop reporting first.
    func progress(_ subtitle: String) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        completedUnits = min(completedUnits + 1, task.progress.totalUnitCount - 1)
        task.progress.completedUnitCount = completedUnits
        task.updateTitle(task.title, subtitle: subtitle)
    }

    func end(success: Bool) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: success)
        self.task = nil
        log("background", "continued processing ended (success: \(success))")
    }

    private func attach(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        self.task = task
        completedUnits = 0
        task.progress.totalUnitCount = 1_000
        task.expirationHandler = onAnyThread { [weak self] in
            self?.log("background", "continued processing expired")
            self?.task = nil
        }
        log("background", "continued processing started")
    }
}

/// iOS calls a task's expiration handler on a background queue. A closure written in a main-actor type would be
/// main-actor isolated, and Swift traps when it runs anywhere else (it ended the app when a background run expired).
/// Made here, at file scope, it is not isolated and hands the work to the main actor.
private func onAnyThread(_ work: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
    { Task { @MainActor in work() } }
}
