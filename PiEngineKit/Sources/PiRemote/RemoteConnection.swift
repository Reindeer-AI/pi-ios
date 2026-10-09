import Foundation
import Network
import NIOCore
import NIOTransportServices

/// Outgoing TCP connections for SSH and plain HTTP, through Network.framework (NIOTransportServices) rather than BSD
/// sockets: on iOS, BSD sockets don't start a VPN On Demand tunnel (WARP) or bring up cellular, and a failure says only
/// "error 1". A connection waits out a moment without a network until its timeout, then names what it was waiting on.
enum RemoteConnection {
    static let group = NIOTSEventLoopGroup(loopCount: 1)
    static let timeout = 20

    static func open(
        host: String,
        port: Int,
        initializer: @escaping @Sendable (Channel) throws -> Void
    ) async throws -> Channel {
        let waiting = WaitingReason()
        do {
            return try await NIOTSConnectionBootstrap(group: group)
                .connectTimeout(.seconds(Int64(timeout)))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(waiting)
                        try initializer(channel)
                    }
                }
                .connect(host: host, port: port).get()
        } catch {
            throw RemoteConnectionError(host: host, port: port, reason: reason(error, waiting: waiting.error))
        }
    }

    private static func reason(_ error: Error, waiting: NWError?) -> String {
        switch error {
        case ChannelError.connectTimeout:
            waiting.map { "no connection within \(timeout) seconds: \(describe($0))" } ?? "no answer within \(timeout) seconds"
        case let error as NWError: describe(error)
        default: String(describing: error)
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): String(cString: strerror(code.rawValue))
        case .dns(let code): "DNS lookup failed (\(dnsNames[code] ?? "error \(code)"))"
        default: error.debugDescription
        }
    }

    private static let dnsNames: [Int32: String] = [
        -65538: "no such name", -65554: "no such record", -65563: "DNS service not running",
        -65568: "timed out", -65569: "no network", -65570: "refused by policy",
    ]
}

public struct RemoteConnectionError: LocalizedError {
    public let host: String
    public let port: Int
    public let reason: String

    public var errorDescription: String? { "can't connect to \(host):\(port): \(reason)" }
}

/// The last reason Network.framework gave for waiting on a connection.
private final class WaitingReason: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let lock = NSLock()
    private var stored: NWError?

    var error: NWError? { lock.withLock { stored } }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let waiting = event as? NIOTSNetworkEvents.WaitingForConnectivity {
            lock.withLock { stored = waiting.transientError }
        }
        context.fireUserInboundEventTriggered(event)
    }
}
