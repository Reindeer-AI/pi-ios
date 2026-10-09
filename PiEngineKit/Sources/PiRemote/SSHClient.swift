import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A machine to run commands on over SSH, with an ed25519 key. `hostKey` (OpenSSH `algorithm base64`) pins the
/// server's key; without it any key is accepted and reported back, for the caller to pin from then on.
public struct SSHTarget: Sendable {
    public let host: String
    public let port: Int
    public let user: String
    public let privateKey: Curve25519.Signing.PrivateKey
    public let hostKey: String?

    public init(host: String, port: Int, user: String, privateKey: Curve25519.Signing.PrivateKey, hostKey: String?) {
        self.host = host
        self.port = port
        self.user = user
        self.privateKey = privateKey
        self.hostKey = hostKey
    }
}

public struct SSHExecResult: Sendable {
    /// The command's exit status; nil when the server closed the channel without one (the command was killed).
    public let exitStatus: Int32?
    /// The server's host key, in OpenSSH form.
    public let hostKey: String
}

public enum SSHError: LocalizedError {
    case hostKeyMismatch(expected: String, presented: String)
    case authenticationFailed
    case invalidHostKey(String)
    case notSession

    public var errorDescription: String? {
        switch self {
        case .hostKeyMismatch(let expected, let presented):
            "the server's host key \(presented) is not the expected \(expected)"
        case .authenticationFailed: "the server did not accept the key"
        case .invalidHostKey(let key): "not an OpenSSH public key: \(key)"
        case .notSession: "the server opened an unexpected channel"
        }
    }
}

/// ed25519 keys in OpenSSH's text form.
public enum SSHKeys {
    public static func publicKey(of privateKey: Curve25519.Signing.PrivateKey, comment: String) -> String {
        "\(String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: privateKey).publicKey)) \(comment)"
    }
}

/// The event loop for listening on this device (LoopbackCallback); outgoing connections use RemoteConnection.
enum RemoteLoop {
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

/// Runs one command per connection: connects, authenticates with the key, checks the host key, runs `command`, feeds
/// it `stdin` (a file, then end of input), streams its output, and returns its exit status. Cancelling the task closes
/// the connection.
public enum SSHClient {
    public static func exec(
        _ target: SSHTarget,
        command: String,
        stdin: URL? = nil,
        output: @escaping @Sendable (_ data: Data, _ isError: Bool) -> Void
    ) async throws -> SSHExecResult {
        let expected = try target.hostKey.map { key in
            do { return try NIOSSHPublicKey(openSSHPublicKey: key) } catch { throw SSHError.invalidHostKey(key) }
        }
        let hostKeys = HostKeyCheck(expected: expected)
        let auth = KeyAuthentication(user: target.user, key: NIOSSHPrivateKey(ed25519Key: target.privateKey))
        let connection = try await RemoteConnection.open(host: target.host, port: target.port) { channel in
            try channel.pipeline.syncOperations.addHandler(
                NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: hostKeys)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
            )
        }
        defer { connection.close(promise: nil) }

        let finished = connection.eventLoop.makePromise(of: Int32?.self)
        let session: Channel
        do {
            session = try await withTaskCancellationHandler {
                try await connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    let created = connection.eventLoop.makePromise(of: Channel.self)
                    ssh.createChannel(created) { child, type in
                        guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.notSession) }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, output: output, finished: finished))
                        }
                    }
                    return created.futureResult
                }.get()
            } onCancel: {
                connection.close(promise: nil)
            }
        } catch {
            // No command ran: the host key or our key was refused (the reason, not NIO's closed channel), or the
            // connection dropped.
            let reason = hostKeys.failure ?? auth.failure ?? error
            finished.fail(reason)
            throw reason
        }

        return try await withTaskCancellationHandler {
            if let stdin {
                let handle = try FileHandle(forReadingFrom: stdin)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    var buffer = session.allocator.buffer(capacity: chunk.count)
                    buffer.writeBytes(chunk)
                    try await session.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
                }
            }
            // End of input, so a command reading stdin (tar) finishes.
            try? await session.close(mode: .output).get()
            let status = try await finished.futureResult.get()
            return SSHExecResult(exitStatus: status, hostKey: hostKeys.presented.map { String(openSSHPublicKey: $0) } ?? "")
        } onCancel: {
            session.close(promise: nil)
            connection.close(promise: nil)
        }
    }
}

/// Used on the connection's event loop; `failure` is read after the connection settles.
private final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private let key: NIOSSHPrivateKey
    private var offered = false
    private(set) var failure: SSHError?

    init(user: String, key: NIOSSHPrivateKey) {
        self.user = user
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            failure = .authenticationFailed
            nextChallengePromise.fail(SSHError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Used on the connection's event loop; `presented` and `failure` are read after the connection settles.
private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expected: NIOSSHPublicKey?
    private(set) var presented: NIOSSHPublicKey?
    private(set) var failure: SSHError?

    init(expected: NIOSSHPublicKey?) {
        self.expected = expected
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        presented = hostKey
        if let expected, expected != hostKey {
            let mismatch = SSHError.hostKeyMismatch(
                expected: String(openSSHPublicKey: expected), presented: String(openSSHPublicKey: hostKey)
            )
            failure = mismatch
            validationCompletePromise.fail(mismatch)
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

/// A session channel running one command: output goes to `output`, and `finished` completes with the exit status when
/// the channel closes.
private final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let output: @Sendable (Data, Bool) -> Void
    private let finished: EventLoopPromise<Int32?>
    private var exitStatus: Int32?
    private var done = false

    init(command: String, output: @escaping @Sendable (Data, Bool) -> Void, finished: EventLoopPromise<Int32?>) {
        self.command = command
        self.output = output
        self.finished = finished
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // The command's output may outlive our end of input.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request).whenFailure { error in
            self.finish(.failure(error))
            context.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int32(status.exitStatus)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        switch message.type {
        case .channel: output(Data(buffer.readableBytesView), false)
        case .stdErr: output(Data(buffer.readableBytesView), true)
        default: break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.success(exitStatus))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    /// Completes `finished` once (an error is usually followed by the channel closing).
    private func finish(_ result: Result<Int32?, Error>) {
        guard !done else { return }
        done = true
        finished.completeWith(result)
    }
}
