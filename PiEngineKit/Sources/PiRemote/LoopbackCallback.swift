import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A one-use HTTP listener on 127.0.0.1 for a browser login that returns to this device (Crabbox's GitHub login):
/// it answers GET `<path>?<parameter>=…` with a short page and hands over the value; every other request is refused.
public final class LoopbackCallback: @unchecked Sendable {
    /// The address to give the server, `http://127.0.0.1:<port><path>`.
    public let url: URL
    private let channel: Channel
    private let received: Received

    /// Listens on a free port, at a path with a random part so other apps on the device cannot guess it.
    public static func start(parameter: String, title: String) async throws -> LoopbackCallback {
        let path = "/crabbox/oauth/\((0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())"
        let received = Received()
        let channel = try await ServerBootstrap(group: RemoteLoop.group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(
                        CallbackHandler(path: path, parameter: parameter, title: title, received: received)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 0
        return LoopbackCallback(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, channel: channel, received: received)
    }

    private init(url: URL, channel: Channel, received: Received) {
        self.url = url
        self.channel = channel
        self.received = received
    }

    /// The value the browser brought back, once it has.
    public var value: String? { received.value }

    public func close() {
        channel.close(promise: nil)
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? { lock.withLock { stored } }

    func set(_ value: String) {
        lock.withLock { if stored == nil { stored = value } }
    }
}

/// Used on its connection's event loop.
private final class CallbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let path: String
    private let parameter: String
    private let title: String
    private let received: Received
    private var head: HTTPRequestHead?

    init(path: String, parameter: String, title: String, received: Received) {
        self.path = path
        self.parameter = parameter
        self.title = title
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end:
            let components = head.flatMap { URLComponents(string: $0.uri) }
            let value = components?.queryItems?.first { $0.name == parameter }?.value
            if head?.method == .GET, components?.path == path, let value, !value.isEmpty {
                received.set(value)
                respond(context, status: .ok, body: "<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>\(title)</title><body style=\"font-family:-apple-system;margin:4rem 1.5rem\"><h1 style=\"font-size:1.3rem\">\(title)</h1><p>You can close this page and return to pi.</p>")
            } else {
                respond(context, status: .notFound, body: "Not found")
            }
        }
    }

    private func respond(_ context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: status == .ok ? "text/html; charset=utf-8" : "text/plain")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: body)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}
