import Foundation
import Network

public struct HTTPReply: Sendable {
    public let status: Int
    /// Header names in lowercase.
    public let headers: [String: String]
    public let body: Data
}

public enum PlainHTTPError: LocalizedError {
    case notHTTP(URL)
    case closedEarly
    case timedOut
    case malformedReply
    /// After the connection opened: what was under way, and why it stopped.
    case failed(host: String, stage: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notHTTP(let url): "\(url) is not an http:// address"
        case .closedEarly: "the server closed the connection before replying"
        case .timedOut: "the server did not reply in time"
        case .malformedReply: "the server's reply is not HTTP"
        case .failed(let host, let stage, let reason): "connected to \(host), then \(stage) failed: \(reason)"
        }
    }
}

/// One HTTP/1.1 request over a plain TCP connection (`Connection: close`). iOS's App Transport Security refuses plain
/// HTTP from URLSession except to local addresses; a broker reached through a private tunnel (WARP) is plain HTTP on
/// a public-looking name, and the tunnel already encrypts it. Use URLSession for https.
///
/// Network.framework directly: through WARP on an iPhone, NIOTransportServices' channel was cancelled as soon as it
/// connected, while a plain NWConnection to the same broker works.
public enum PlainHTTP {
    public static func send(
        _ method: String,
        _ url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> HTTPReply {
        guard url.scheme?.lowercased() == "http", let host = url.host(), let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80))
        else { throw PlainHTTPError.notHTTP(url) }
        let target = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let uri = target + (url.query(percentEncoded: true).map { "?\($0)" } ?? "")
        var lines = ["\(method) \(uri) HTTP/1.1", "Host: \(port.rawValue == 80 ? host : "\(host):\(port.rawValue)")", "Connection: close", "Content-Length: \(body?.count ?? 0)"]
        lines += headers.map { "\($0.key): \($0.value)" }
        var request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { request.append(body) }

        let exchange = Exchange(connection: NWConnection(host: .init(host), port: port, using: .tcp), host: host, port: Int(port.rawValue))
        return try await withTaskCancellationHandler {
            try await exchange.run(request, timeout: timeout)
        } onCancel: {
            exchange.cancel()
        }
    }
}

/// One request and its reply on one connection; its state is used only on `queue`.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let host: String
    private let port: Int
    private let queue = DispatchQueue(label: "dev.pimobile.plain-http")
    private var continuation: CheckedContinuation<HTTPReply, Error>?
    private var received = Data()
    private var connected = false
    private var waiting: NWError?

    init(connection: NWConnection, host: String, port: Int) {
        self.connection = connection
        self.host = host
        self.port = port
    }

    func run(_ request: Data, timeout: TimeInterval) async throws -> HTTPReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .waiting(let error): waiting = error
                    case .ready:
                        connected = true
                        connection.send(content: request, completion: .contentProcessed { [self] error in
                            if let error { finish(.failure(failure("sending the request", error))) }
                        })
                        receive()
                    case .failed(let error):
                        finish(.failure(connected ? failure("the connection", error) : RemoteConnectionError(host: host, port: port, reason: RemoteConnection.describe(error))))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(RemoteConnection.timeout)) { [self] in
                    guard !connected else { return }
                    let reason = waiting.map { "no connection within \(RemoteConnection.timeout) seconds: \(RemoteConnection.describe($0))" }
                    finish(.failure(RemoteConnectionError(host: host, port: port, reason: reason ?? "no answer within \(RemoteConnection.timeout) seconds")))
                }
                queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.failure(PlainHTTPError.timedOut)) }
            }
        }
    }

    func cancel() {
        queue.async { [self] in finish(.failure(CancellationError())) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            if let data { received.append(data) }
            if let error { return finish(.failure(failure("waiting for the reply", error))) }
            // The whole reply: the server closed (Connection: close), or the body its Content-Length gives arrived.
            if isComplete || Self.parse(received, final: false) != nil {
                return finish(Self.parse(received, final: true).map { .success($0) } ?? .failure(received.isEmpty ? PlainHTTPError.closedEarly : PlainHTTPError.malformedReply))
            }
            receive()
        }
    }

    private func failure(_ stage: String, _ error: NWError) -> Error {
        PlainHTTPError.failed(host: "\(host):\(port)", stage: stage, reason: RemoteConnection.describe(error))
    }

    private func finish(_ result: Result<HTTPReply, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }

    /// The reply in `data`, or nil while it is incomplete. A body without Content-Length runs to the end of the
    /// connection (`final`); a chunked one is decoded.
    private static func parse(_ data: Data, final: Bool) -> HTTPReply? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = head.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(data[end.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = dechunk(body) else { return final ? HTTPReply(status: status, headers: headers, body: body) : nil }
            return HTTPReply(status: status, headers: headers, body: decoded)
        }
        if let length = headers["content-length"].flatMap(Int.init) {
            guard body.count >= length else { return nil }
            return HTTPReply(status: status, headers: headers, body: body.prefix(length))
        }
        return final ? HTTPReply(status: status, headers: headers, body: body) : nil
    }

    /// A chunked body, or nil until its last chunk has arrived.
    private static func dechunk(_ body: Data) -> Data? {
        var decoded = Data()
        var index = body.startIndex
        while let lineEnd = body[index...].firstRange(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: body[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            if size == 0 { return decoded }
            let start = lineEnd.upperBound
            guard body.distance(from: start, to: body.endIndex) >= size + 2 else { return nil }
            let chunkEnd = body.index(start, offsetBy: size)
            decoded.append(body[start..<chunkEnd])
            index = body.index(chunkEnd, offsetBy: 2)
        }
        return nil
    }
}
