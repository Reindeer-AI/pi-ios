import BackgroundTasks
import Foundation
import PiEngineKit

/// Extensions' background checks (`pi.registerCheck`): iOS wakes pi now and then (background refresh, as often as it
/// decides), and pi runs the checks that are due, each for a few seconds; a check may post a notification (`pi.notify`).
/// Settings → Extensions lists them with their last result, and runs one on demand.
@MainActor
@Observable
final class BackgroundChecks {
    static let shared = BackgroundChecks()
    /// Under the app's bundle ID, as `BGTaskSchedulerPermittedIdentifiers` declares it.
    static let identifier = "\(Bundle.main.bundleIdentifier ?? "dev.pimobile.PiMobile").checks"
    /// How long iOS's wake-up lasts, about: the due checks share it.
    static let budget: Duration = .seconds(25)

    struct Check: Identifiable, Equatable {
        let key: String
        let extensionName: String
        let name: String
        let description: String?
        /// Minutes between runs, at the soonest.
        let every: Int
        var id: String { key }
    }

    struct Run: Codable, Equatable {
        var at: Date
        var result: String?
        var error: String?
    }

    private(set) var checks: [Check] = []
    private(set) var runs: [String: Run] = [:]
    /// The keys of the checks running now.
    private(set) var running: Set<String> = []
    private static let runsKey = "backgroundCheckRuns"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.runsKey), let saved = try? JSONDecoder().decode([String: Run].self, from: data) {
            runs = saved
        }
    }

    /// Registers the handler for iOS's wake-ups; must run while the app launches.
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated { BackgroundChecks.shared.handle(task) }
        }
    }

    /// The checks the extensions registered now, and a wake-up asked for the soonest due one.
    func refresh(from engine: PiEngine) async {
        let listed = (try? await engine.command("checks.list") as? [[String: Any]]) ?? []
        checks = listed.compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            return Check(key: key, extensionName: item["extension"] as? String ?? "", name: item["name"] as? String ?? key,
                         description: item["description"] as? String, every: item["every"] as? Int ?? 60)
        }
        schedule()
    }

    /// Asks iOS to wake pi when the soonest check is due (iOS picks the time: not sooner, often later).
    func schedule() {
        guard let soonest = checks.map(\.every).min() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(15, soonest) * 60))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch let error as BGTaskScheduler.Error where error.code == .unavailable {
            log("checks", "background refresh is unavailable here (the simulator, or turned off in Settings)")
        } catch {
            log("checks", "background refresh request failed: \(error.localizedDescription)")
        }
    }

    private func handle(_ task: BGTask) {
        log("checks", "woken by iOS")
        let work = Task { await runDue(within: Self.budget) }
        task.expirationHandler = onAnyThread {
            log("checks", "iOS ended the wake-up")
            work.cancel()
        }
        Task {
            await work.value
            schedule()
            task.setTaskCompleted(success: true)
        }
    }

    /// Starts pi's engine if it isn't running and runs the checks that are due (`all`: every one), within `budget`.
    func runDue(within budget: Duration, all: Bool = false) async {
        guard let app = AppModel.shared else { return }
        await app.start()
        await app.extensionsLoaded()
        await refresh(from: app.engine)
        let deadline = ContinuousClock.now + budget
        for check in checks where all || isDue(check) {
            let left = deadline - ContinuousClock.now
            guard left > .seconds(2), !Task.isCancelled else { break }
            await run(check, within: min(left, .seconds(20)))
        }
    }

    /// Runs one check now (Settings, or a wake-up).
    func run(_ check: Check, within limit: Duration = .seconds(20)) async {
        guard let app = AppModel.shared, !running.contains(check.key) else { return }
        running.insert(check.key)
        defer { running.remove(check.key) }
        let milliseconds = Int(limit.components.seconds) * 1000
        do {
            let reply = try await app.engine.command("checks.run", ["key": check.key, "timeoutMs": milliseconds]) as? [String: Any]
            runs[check.key] = Run(at: .now, result: reply?["result"] as? String)
            log("checks", "\(check.key): \(reply?["result"] as? String ?? "done")")
        } catch {
            runs[check.key] = Run(at: .now, error: error.localizedDescription)
            log("checks", "\(check.key) failed: \(error.localizedDescription)")
        }
        if let data = try? JSONEncoder().encode(runs) { UserDefaults.standard.set(data, forKey: Self.runsKey) }
    }

    /// Due a minute early, so a wake-up iOS gives a little before the time still runs it.
    private func isDue(_ check: Check) -> Bool {
        guard let last = runs[check.key]?.at else { return true }
        return Date.now.timeIntervalSince(last) >= TimeInterval(check.every * 60 - 60)
    }
}

/// iOS calls a task's expiration handler on a background queue: made here, at file scope, the closure is not main-actor
/// isolated, and hands the work to the main actor (as BackgroundRun's does).
private func onAnyThread(_ work: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
    { Task { @MainActor in work() } }
}
