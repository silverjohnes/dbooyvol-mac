import Foundation

struct SidecarError: LocalizedError {
    var message: String
    var sqlState: String?
    var code: Int?
    /// Set when the JVM or the server connection is gone; avoids matching on
    /// translated message text.
    var lost: Bool = false

    var errorDescription: String? { message }

    var dbError: DBError { DBError(message: message, sqlState: sqlState, code: code) }

    /// The server (or the sidecar JVM) went away while the app still had a session.
    var isConnectionLost: Bool {
        if lost { return true }
        if let sqlState, sqlState.hasPrefix("08") { return true }
        let text = message.lowercased()
        let needles = [
            "connection is closed", "not connected", "connection has been closed",
            "terminating connection", "connection reset", "broken pipe",
            "java-процесс завершился", "sidecar не запущен"
        ]
        return needles.contains { text.contains($0) }
    }
}

/// One long-lived JVM process speaking NDJSON JSON-RPC over stdio.
final class SidecarClient {
    static let shared = SidecarClient()

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var seq = 0
    private(set) var lastStderr = ""

    private init() {}

    private static func jarURL() -> URL? {
        if let u = Bundle.main.url(forResource: "sidecar", withExtension: "jar") { return u }
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sidecar.jar"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/sidecar.jar")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if let p = process, p.isRunning { return }
        guard let jar = Self.jarURL() else {
            throw SidecarError(message: L10n.tr("sidecar.jar не найден. Соберите его: ./Sidecar/build.sh"))
        }
        guard FileManager.default.isExecutableFile(atPath: AppSettings.javaPath) else {
            throw SidecarError(message: L10n.fmt("Java не найдена: %@. Укажите путь в настройках.", AppSettings.javaPath))
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: AppSettings.javaPath)
        p.arguments = ["-Dfile.encoding=UTF-8", "-Xss4m", "-jar", jar.path]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.lock.lock()
            let merged = (self?.lastStderr ?? "") + text
            self?.lastStderr = String(merged.suffix(4000))
            self?.lock.unlock()
        }

        p.terminationHandler = { [weak self] _ in
            self?.failAll(SidecarError(message: L10n.tr("Java-процесс завершился"), lost: true))
        }

        try p.run()
        process = p
        input = stdinPipe.fileHandleForWriting
        buffer.removeAll()
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<idx]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        lock.unlock()

        for line in lines { handleLine(line) }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let id = (obj["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let callback = pending.removeValue(forKey: id)
        lock.unlock()
        guard let callback else { return }

        if let ok = obj["ok"] as? Bool, ok, let result = obj["result"] as? [String: Any] {
            callback(.success(result))
        } else {
            let err = obj["error"] as? [String: Any] ?? [:]
            callback(.failure(SidecarError(
                message: err["message"] as? String ?? L10n.tr("Неизвестная ошибка"),
                sqlState: err["sqlState"] as? String,
                code: (err["code"] as? NSNumber)?.intValue
            )))
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let callbacks = pending
        pending.removeAll()
        process = nil
        input = nil
        lock.unlock()
        callbacks.values.forEach { $0(.failure(error)) }
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try start()
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            seq += 1
            return seq
        }()
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = { result in
                switch result {
                case .success(let v): continuation.resume(returning: v)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }
            let handle = input
            lock.unlock()

            guard let handle else {
                continuation.resume(throwing: SidecarError(message: L10n.tr("Sidecar не запущен"), lost: true))
                return
            }
            do {
                try handle.write(contentsOf: line)
            } catch {
                lock.lock()
                pending.removeValue(forKey: id)
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func shutdown() {
        lock.lock()
        let p = process
        process = nil
        input = nil
        lock.unlock()
        p?.terminate()
    }
}
