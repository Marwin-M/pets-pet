import Foundation

public struct SidebarTarget: Decodable, Sendable {
    public let id: String
    public let type: String
    public let url: String
    public let webSocketDebuggerUrl: String?

    public var isMainWindow: Bool {
        guard type == "page", let parsed = URLComponents(string: url), parsed.scheme == "app",
              parsed.host == "-", parsed.path == "/index.html" else { return false }
        return !(url.removingPercentEncoding ?? url).lowercased().contains("overlay")
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Constrain discovery and WebSockets to the same loopback port. No cookies or cache.
public final class SidebarDiscovery {
    public let port: Int
    private let session: URLSession
    public init(port: Int = 39222) {
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func targets() async throws -> [SidebarTarget] {
        guard (1...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { throw SidebarError.protocolError }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else { throw SidebarError.protocolError }
        return Array(try JSONDecoder().decode([SidebarTarget].self, from: data).filter(\.isMainWindow).prefix(32))
    }

    public func allows(_ url: URL) -> Bool {
        url.scheme == "ws" && ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "") && url.port == port
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    public func connect(_ target: SidebarTarget, timeout: TimeInterval = 4) async throws -> SidebarCDPConnection {
        guard target.isMainWindow, let raw = target.webSocketDebuggerUrl, let url = URL(string: raw), allows(url) else { throw SidebarError.protocolError }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1_000_000
        let connection = SidebarCDPConnection(socket: socket, timeout: timeout)
        await connection.start()
        do { _ = try await connection.call("Runtime.enable"); return connection }
        catch { await connection.close(); throw error }
    }
}

public actor SidebarCDPConnection {
    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timer: Task<Void, Never>
    }
    private let socket: URLSessionWebSocketTask
    private let timeout: TimeInterval
    private var serial = 0
    private var pending: [Int: Pending] = [:]
    private var receiver: Task<Void, Never>?
    private var closed = false

    init(socket: URLSessionWebSocketTask, timeout: TimeInterval) { self.socket = socket; self.timeout = timeout }

    func start() {
        socket.resume()
        let socket = socket
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw SidebarError.protocolError
                    }
                    await self?.receive(data)
                }
            } catch { await self?.close() }
        }
    }

    public func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed else { throw SidebarError.disconnected }
        try Task.checkCancellation()
        serial += 1
        let id = serial
        let json = try SidebarScript.json(["id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.fail(id, error: SidebarError.timeout)
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                Task { [weak self, socket] in
                    do { try await socket.send(.string(json)) }
                    catch { await self?.fail(id, error: SidebarError.disconnected) }
                }
            }
        }, onCancel: { Task { await self.fail(id, error: SidebarError.cancelled) } })
    }

    public func evaluate(_ expression: String) async throws -> [String: Any] {
        let response = try await call("Runtime.evaluate", params: ["expression": expression, "returnByValue": true, "awaitPromise": true])
        guard response["exceptionDetails"] == nil, let result = response["result"] as? [String: Any] else { throw SidebarError.protocolError }
        return result["value"] as? [String: Any] ?? [:]
    }

    private func receive(_ data: Data) {
        guard data.count <= 1_000_000, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = message["id"] as? Int, let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
            request.continuation.resume(throwing: SidebarError.protocolError); return
        }
        request.continuation.resume(returning: result)
    }
    private func fail(_ id: Int, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel(); request.continuation.resume(throwing: error)
    }
    public func close() {
        guard !closed else { return }
        closed = true; receiver?.cancel(); receiver = nil
        socket.cancel(with: .goingAway, reason: nil)
        for id in Array(pending.keys) { fail(id, error: SidebarError.disconnected) }
    }
}
