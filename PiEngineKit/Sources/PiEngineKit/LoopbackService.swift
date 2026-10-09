import Foundation
import Network

/// The engine's `loopback` service: minimal HTTP servers on the loopback interface for OAuth redirects (pi-ai's callback server,
/// through the engine's node:http shim). Each request's head is forwarded to the engine as a `loopback.request`
/// command; the engine answers with `respond`, and the connection closes after the response.
@MainActor
public final class LoopbackService {
    private var listeners: [String: NWListener] = [:]
    private var connections: [String: NWConnection] = [:]
    private weak var engine: PiEngine?

    public init() {}

    public func install(on engine: PiEngine) {
        self.engine = engine
        engine.register(service: "loopback") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("loopback") }
            let arguments = JSONValue(bridged: params)
            switch method {
            case "listen":
                return try await self.listen(port: UInt16(arguments["port"]?.number ?? 0))
            case "respond":
                self.respond(arguments)
                return nil
            case "close":
                if let id = arguments["serverId"]?.string { self.listeners.removeValue(forKey: id)?.cancel() }
                return nil
            default:
                throw EngineError.unknownMethod("loopback.\(method)")
            }
        }
    }

    private func listen(port: UInt16) async throws -> [String: Any] {
        // The whole loopback interface, IPv4 and IPv6: browsers may resolve an OAuth redirect's "localhost" to ::1.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        let id = UUID().uuidString
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, serverId: id) }
        }
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Runs on the main queue; cleared after the first outcome so the continuation resumes once.
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? port)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
        listeners[id] = listener
        return ["serverId": id, "port": Int(boundPort)]
    }

    private func accept(_ connection: NWConnection, serverId: String) {
        connection.start(queue: .main)
        receiveHead(connection, buffer: Data()) { [weak self] head in
            // The connection runs on the main queue.
            MainActor.assumeIsolated { self?.forward(head, from: connection, serverId: serverId) }
        }
    }

    private func forward(_ head: Data?, from connection: NWConnection, serverId: String) {
        guard let head else { return connection.cancel() }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return connection.cancel() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let requestId = UUID().uuidString
        connections[requestId] = connection
        Task { @MainActor [weak self] in
            _ = try? await self?.engine?.command("loopback.request", [
                "serverId": serverId,
                "requestId": requestId,
                "method": String(requestLine[0]),
                "url": String(requestLine[1]),
                "headers": headers,
            ])
        }
    }

    /// Reads until the end of the request head (`\r\n\r\n`); OAuth redirects are GETs without a body.
    private nonisolated func receiveHead(_ connection: NWConnection, buffer: Data, completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                completion(buffer[..<end.lowerBound])
            } else if isComplete || error != nil || buffer.count > 65_536 {
                completion(nil)
            } else {
                self.receiveHead(connection, buffer: buffer, completion: completion)
            }
        }
    }

    private func respond(_ arguments: JSONValue) {
        guard let requestId = arguments["requestId"]?.string,
              let connection = connections.removeValue(forKey: requestId)
        else { return }
        let status = Int(arguments["status"]?.number ?? 200)
        let body = Data((arguments["body"]?.string ?? "").utf8)
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        var headers = (arguments["headers"]?.object ?? [:]).compactMapValues(\.string)
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
