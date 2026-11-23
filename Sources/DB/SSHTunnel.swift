import Foundation
import Darwin

/// Local port forwarding through the system `ssh` binary, so ~/.ssh/config,
/// keys, agent and ProxyJump all work exactly as in Terminal.
final class SSHTunnel {
    private var process: Process?
    private(set) var localPort: Int = 0

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0 else { return 0 }
        var out = sockaddr_in()
        let ok = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard ok == 0 else { return 0 }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    static func isOpen(port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-z", "-G", "1", "127.0.0.1", String(port)]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func start(ssh: SSHProfile, remoteHost: String, remotePort: Int) throws -> Int {
        let host = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw SidecarError(message: L10n.tr("SSH включён, но хост не указан. Укажите хост или алиас из ~/.ssh/config — либо выключите SSH в профиле."))
        }
        let port = SSHTunnel.freePort()
        guard port > 0 else { throw SidecarError(message: L10n.tr("Не удалось выделить локальный порт для SSH-туннеля")) }

        var args: [String] = []
        if let config = AppSettings.sshConfigPath {
            args += ["-F", config]
        }
        if !ssh.keyPath.isEmpty {
            args += ["-i", (ssh.keyPath as NSString).expandingTildeInPath]
        }
        if ssh.port != 22 {
            args += ["-p", String(ssh.port)]
        }
        args += [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-L", "127.0.0.1:\(port):\(remoteHost):\(remotePort)",
            ssh.user.isEmpty ? host : "\(ssh.user)@\(host)"
        ]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        process = p
        localPort = port

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !p.isRunning {
                let data = errPipe.fileHandleForReading.availableData
                let raw = String(data: data, encoding: .utf8) ?? ""
                let msg = cleanError(raw)
                throw SidecarError(message: L10n.fmt("SSH не запустился: %@", msg.isEmpty ? L10n.tr("проверьте ~/.ssh/config") : msg))
            }
            if SSHTunnel.isOpen(port: port) {
                return port
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        stop()
        throw SidecarError(message: L10n.tr("SSH-туннель не поднялся за 20 секунд"))
    }

    /// ssh prints harmless host-key warnings before the real error.
    private func cleanError(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
            .joined(separator: " ")
    }

    func stop() {        process?.terminate()
        process = nil
        localPort = 0
    }

    deinit {
        process?.terminate()
    }
}
