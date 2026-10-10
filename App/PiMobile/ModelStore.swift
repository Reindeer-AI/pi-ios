import Foundation
import Observation

/// On-device models: downloads GGUF files from Hugging Face links and lists what is on the phone.
///
/// Downloads run in a background URLSession, so they continue while the app is in the background, and a failed
/// download resumes from where it stopped.
@MainActor
@Observable
final class ModelStore: NSObject {
    /// One store per app: the background download session belongs to it.
    static let shared = ModelStore()

    struct Download: Equatable {
        let fileName: String
        var received: Int64 = 0
        var expected: Int64 = 0
        var error: String?

        var fraction: Double { expected > 0 ? Double(received) / Double(expected) : 0 }
    }

    /// Models are kept out of the user-visible Documents folder and excluded from backups.
    nonisolated static let directory = URL.applicationSupportDirectory.appending(path: "models", directoryHint: .isDirectory)
    private static let sessionIdentifier = "\(Bundle.main.bundleIdentifier ?? "dev.pimobile.PiMobile").models"

    private(set) var models: [String] = []
    private(set) var download: Download?
    var onLog: ((String) -> Void)?
    /// Called when the set of downloaded models changes.
    var onModelsChanged: (() -> Void)?
    /// Called by the app delegate when iOS relaunches the app to finish background download events.
    var backgroundEventsCompletion: (() -> Void)?

    private var session: URLSession!
    private var resumeData: [URL: Data] = [:]

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        var directory = Self.directory
        try? directory.setResourceValues(resources)
        refresh()
    }

    func path(of model: String) -> URL {
        Self.directory.appending(path: model)
    }

    /// Accepts a Hugging Face file link (`…/blob/<rev>/<file>.gguf` or `…/resolve/<rev>/<file>.gguf`).
    func startDownload(from link: String) throws {
        let url = try Self.downloadURL(for: link)
        let fileName = url.lastPathComponent
        download = Download(fileName: fileName)
        let task = resumeData[url].map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        task.taskDescription = fileName
        task.resume()
        onLog?("download started: \(url.absoluteString)")
    }

    func cancelDownload() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        download = nil
    }

    func delete(_ model: String) {
        try? FileManager.default.removeItem(at: path(of: model))
        refresh()
    }

    private func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        let current = files.filter { $0.hasSuffix(".gguf") }.sorted()
        if current != models {
            models = current
            onModelsChanged?()
        }
    }

    static func downloadURL(for link: String) throws -> URL {
        guard var components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, host == "huggingface.co" || host == "hf.co",
              components.path.hasSuffix(".gguf")
        else { throw ModelStoreError.unsupportedLink }
        components.host = "huggingface.co"
        components.path = components.path.replacingOccurrences(of: "/blob/", with: "/resolve/")
        guard components.path.contains("/resolve/") else { throw ModelStoreError.unsupportedLink }
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        return components.url!
    }
}

enum ModelStoreError: LocalizedError {
    case unsupportedLink

    var errorDescription: String? {
        "Paste a Hugging Face link to a .gguf file, like https://huggingface.co/<owner>/<repo>/blob/main/<file>.gguf"
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    // The session's delegate queue is the main queue.

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            let fileName = downloadTask.taskDescription ?? ""
            let previous = download?.received ?? 0
            download = Download(fileName: fileName, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
            // Log about every 256 MB.
            if totalBytesWritten / 268_435_456 != previous / 268_435_456 {
                onLog?(String(format: "download %@: %.0f%% (%.2f of %.2f GB)", fileName, (download?.fraction ?? 0) * 100,
                              Double(totalBytesWritten) / 1e9, Double(totalBytesExpectedToWrite) / 1e9))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns; move it synchronously.
        let fileName = downloadTask.taskDescription ?? downloadTask.originalRequest?.url?.lastPathComponent ?? "model.gguf"
        let destination = ModelStore.directory.appending(path: fileName)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let moved: Result<Void, Error> = Result {
            guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        }
        MainActor.assumeIsolated {
            switch moved {
            case .success:
                onLog?("download finished: \(fileName)")
                download = nil
                refresh()
            case .failure(let error):
                download?.error = "HTTP \(status): \(error.localizedDescription)"
                onLog?("download failed: \(fileName) HTTP \(status)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            if let url = task.originalRequest?.url, let resume { resumeData[url] = resume }
            guard download != nil else { return } // cancelled
            download?.error = error.localizedDescription + (resume != nil ? " — tap Download to resume" : "")
            onLog?("download error: \(error.localizedDescription) (resumable: \(resume != nil))")
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsCompletion?()
            backgroundEventsCompletion = nil
        }
    }
}
