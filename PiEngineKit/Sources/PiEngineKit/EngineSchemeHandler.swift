import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `pi://app/…`: engine bundle files from `bundleDirectory`, `pi://app/net` through `NetProxy`, and
/// `pi://app/sync`, which runs a native service call for a synchronous XMLHttpRequest (the engine's Node shims need
/// blocking calls such as `readFileSync`). The page waits; native work never needs the page, so it cannot deadlock.
@MainActor
final class EngineSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pi"

    private let bundleDirectory: URL
    let netProxy = NetProxy()
    /// Handles a `pi://app/sync` call: `{ service, method, params }` in, the service's result out.
    var syncHandler: (@MainActor (_ service: String, _ method: String, _ params: Any?) async throws -> Any?)?

    init(bundleDirectory: URL) {
        self.bundleDirectory = bundleDirectory.standardizedFileURL
    }

    /// Whether a web view is the engine's current page (`PiEngine.replacePage`): a replaced one gets no native service.
    var isCurrentPage: ((WKWebView) -> Bool)?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "app" else {
            return respond(urlSchemeTask, status: 404)
        }
        if url.path == "/net" || url.path == "/sync", isCurrentPage?(webView) == false {
            return respond(urlSchemeTask, status: 410)
        }
        if url.path == "/net" {
            return netProxy.start(urlSchemeTask)
        }
        if url.path == "/sync" {
            return sync(urlSchemeTask)
        }
        serveFile(at: url.path, to: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        netProxy.stop(urlSchemeTask)
    }

    private func sync(_ task: any WKURLSchemeTask) {
        guard let body = task.request.httpBody,
              let call = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let service = call["service"] as? String, let method = call["method"] as? String
        else { return respond(task, status: 400) }
        Task {
            var reply: [String: Any]
            do {
                reply = ["ok": true, "value": try await syncHandler?(service, method, call["params"]) ?? NSNull()]
            } catch {
                reply = ["ok": false, "error": (error as? LocalizedError)?.errorDescription ?? String(describing: error)]
            }
            let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed])) ?? Data("{\"ok\":false}".utf8)
            respond(task, status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
    }

    private func serveFile(at path: String, to task: any WKURLSchemeTask) {
        let file = bundleDirectory.appending(path: String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        // Stay inside the bundle directory.
        guard file.path.hasPrefix(bundleDirectory.path + "/"), let data = try? Data(contentsOf: file) else {
            return respond(task, status: 404)
        }
        // WebAssembly must be served as such for streaming compilation.
        let mimeType = file.pathExtension == "wasm"
            ? "application/wasm"
            : UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        respond(task, status: 200, headers: ["Content-Type": mimeType, "Cache-Control": "no-store"], body: data)
    }

    private func respond(_ task: any WKURLSchemeTask, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        let response = HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
