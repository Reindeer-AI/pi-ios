import Foundation
import Network
import NIOCore
import NIOHTTP1
import NIOPosix

/// Diagnostics: one GET of a plain-http URL three ways (Network.framework directly, NIO on BSD sockets, URLSession),
/// reported line by line, to tell a transport's failure from the network's.
public enum NetProbe {
    public static func run(_ url: URL, log: @escaping @Sendable (String) -> Void) async {
        guard let host = url.host() else { return log("no host in \(url)") }
        let port = url.port ?? 80
        let request = "GET \(url.path().isEmpty ? "/" : url.path()) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nAccept: */*\r\n\r\n"
        await network(host: host, port: port, request: request, log: log)
        await posix(host: host, port: port, request: request, log: log)
        await session(url, log: log)
    }

    private static func network(host: String, port: Int, request: String, log: @escaping @Sendable (String) -> Void) async {
        let started = Date()
        let elapsed = { String(format: "%.0fms", Date().timeIntervalSince(started) * 1000) }
        let connection = NWConnection(host: .init(host), port: .init(integerLiteral: UInt16(port)), using: .tcp)
        let queue = DispatchQueue(label: "probe")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finished = Once()
            let finish = { (line: String) in if finished.first() { log(line); connection.cancel(); done.resume() } }
            connection.pathUpdateHandler = { path in log("nw path \(elapsed()): \(path.status) via \(path.availableInterfaces.map { "\($0.name)(\($0.type))" }) remote=\(String(describing: path.remoteEndpoint))") }
            connection.viabilityUpdateHandler = { log("nw viable \(elapsed()): \($0)") }
            connection.stateUpdateHandler = { state in
                log("nw state \(elapsed()): \(state)")
                switch state {
                case .ready:
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        log("nw sent \(elapsed()): \(error.map { "\($0)" } ?? "ok")")
                    })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                        finish("nw received \(elapsed()): \(data.map { String(decoding: $0.prefix(160), as: UTF8.self).replacingOccurrences(of: "\r\n", with: " | ") } ?? "nothing") complete=\(complete) error=\(error.map { "\($0)" } ?? "none")")
                    }
                case .failed(let error): finish("nw failed \(elapsed()): \(error)")
                case .cancelled: finish("nw cancelled \(elapsed())")
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { finish("nw gave up after 15s") }
        }
    }

    private static func posix(host: String, port: Int, request: String, log: @escaping @Sendable (String) -> Void) async {
        let started = Date()
        do {
            let channel = try await ClientBootstrap(group: RemoteLoop.group).connectTimeout(.seconds(15))
                .connect(host: host, port: port).get()
            log("posix connected \(Int(Date().timeIntervalSince(started) * 1000))ms to \(channel.remoteAddress.map { "\($0)" } ?? "?")")
            try await channel.writeAndFlush(channel.allocator.buffer(string: request)).get()
            log("posix sent")
            try? await channel.close().get()
        } catch {
            log("posix failed \(Int(Date().timeIntervalSince(started) * 1000))ms: \(error)")
        }
    }

    private static func session(_ url: URL, log: @escaping @Sendable (String) -> Void) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            log("urlsession \((response as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data.prefix(120), as: UTF8.self))")
        } catch {
            log("urlsession failed: \(error.localizedDescription)")
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
