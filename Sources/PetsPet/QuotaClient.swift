import AppKit
import Darwin
import PetsPetCore

enum QuotaClientError: Error, LocalizedError {
    case unavailable, timeout, stopped, protocolError, loginRequired, serviceUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "未找到 Codex 自带的命令行组件，请更新或重新安装 Codex"
        case .timeout: return "额度查询超时，请检查网络后重试"
        case .stopped: return "Codex 额度服务已退出，请稍后重试"
        case .protocolError: return "Codex 返回的数据格式暂不受支持"
        case .loginRequired: return "请先在 Codex 中登录支持额度查询的 ChatGPT 账号"
        case .serviceUnavailable: return "额度服务暂时不可用，请检查登录状态或网络后重试"
        }
    }
}

final class QuotaClient {
    private let queue = DispatchQueue(label: "com.marwin.petspet.quota", qos: .utility)
    private let lock = NSLock()
    private var active: Process?
    private var busy = false
    private var stopped = false

    func refresh(completion: @escaping (Result<QuotaSnapshot, Error>) -> Void) {
        lock.lock()
        guard !busy, !stopped else { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            let result = Result { try request() }
            lock.lock(); busy = false; lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop() {
        lock.lock(); stopped = true; let process = active; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    private func executable() -> URL? {
        var apps: [URL] = []
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" })?.bundleURL { apps.append(running) }
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { apps.append(installed) }
        apps += [URL(fileURLWithPath: "/Applications/Codex.app"), URL(fileURLWithPath: "/Applications/ChatGPT.app")]
        for app in apps {
            guard Bundle(url: app)?.bundleIdentifier == "com.openai.codex" else { continue }
            let candidate = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func request() throws -> QuotaSnapshot {
        guard let executable = executable() else { throw QuotaClientError.unavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // The upstream service may log private account metadata. Never retain its stderr.
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        lock.lock()
        if stopped { lock.unlock(); throw QuotaClientError.stopped }
        // Keep launch inside the lock so shutdown cannot miss an about-to-start process.
        do { try process.run(); active = process; lock.unlock() }
        catch { lock.unlock(); throw QuotaClientError.unavailable }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let limit = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); active = nil; lock.unlock()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "pets_pet", "title": "Pet's Pet", "version": version]]])
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var buffer = Data()
        var quotaData: Data?
        var accountData: Data?
        var accountFinished = false
        var accountWaitUntil: Date?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            lock.lock(); let cancelled = stopped; lock.unlock()
            if cancelled { throw QuotaClientError.stopped }
            if let quotaData, accountFinished || Date() >= (accountWaitUntil ?? deadline) {
                return try QuotaParser.parse(quotaData, accountData: accountData)
            }
            var descriptorEvent = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let count = Darwin.poll(&descriptorEvent, 1, 200)
            if count < 0 && errno != EINTR { throw QuotaClientError.stopped }
            if count == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let readCount = Darwin.read(descriptor, &bytes, bytes.count)
            if readCount == 0 {
                if let quotaData { return try QuotaParser.parse(quotaData, accountData: accountData) }
                throw QuotaClientError.stopped
            }
            if readCount < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw QuotaClientError.stopped
            }
            buffer.append(contentsOf: bytes.prefix(readCount))
            guard buffer.count <= 2_000_000 else { throw QuotaClientError.protocolError }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                guard id == 1 || id == 2 || id == 3 else { continue }
                // Older servers can reject account/read without losing valid quota.
                if id == 3 {
                    if let result = message["result"] as? [String: Any] {
                        accountData = try? JSONSerialization.data(withJSONObject: result)
                    }
                    accountFinished = true
                } else if let error = message["error"] as? [String: Any] {
                    let text = (error["message"] as? String ?? "").lowercased()
                    if text.contains("auth") || text.contains("login") || text.contains("chatgpt") { throw QuotaClientError.loginRequired }
                    throw QuotaClientError.serviceUnavailable
                }
                if id == 1 {
                    guard message["result"] != nil else { throw QuotaClientError.protocolError }
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                    try send(["id": 3, "method": "account/read", "params": ["refreshToken": false]])
                } else if id == 2 {
                    guard let result = message["result"] as? [String: Any] else { throw QuotaClientError.protocolError }
                    do {
                        let data = try JSONSerialization.data(withJSONObject: result)
                        // Validate immediately; account metadata never masks a quota error.
                        _ = try QuotaParser.parse(data)
                        quotaData = data
                    }
                    catch is DecodingError { throw QuotaClientError.protocolError }
                    accountWaitUntil = Date().addingTimeInterval(2)
                }
                if let quotaData, accountFinished {
                    return try QuotaParser.parse(quotaData, accountData: accountData)
                }
            }
        }
        if let quotaData { return try QuotaParser.parse(quotaData, accountData: accountData) }
        throw QuotaClientError.timeout
    }
}
