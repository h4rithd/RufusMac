import Foundation
import CryptoKit

/// Executes a privileged shell script (partitioning, formatting, `dd`, …) with a
/// single administrator-password prompt via macOS Authorization Services
/// (`osascript … with administrator privileges`).
///
/// The whole burn pipeline is assembled as one script and run once, so the user
/// is prompted a single time per operation. Set `dryRun` to capture the exact
/// script **without executing** — used by tests and the in-app "Preview
/// commands" feature so destructive actions are always auditable first.
public actor PrivilegedRunner {
    public var dryRun: Bool
    public private(set) var lastScript: String = ""

    public init(dryRun: Bool = false) {
        self.dryRun = dryRun
    }

    public func setDryRun(_ value: Bool) {
        dryRun = value
    }

    /// Run `script` as administrator. The user sees one native password dialog
    /// labelled with `prompt`. In dry-run mode the script is returned verbatim.
    @discardableResult
    public func run(script: String, prompt: String, feedImage: URL? = nil, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        var script = script
        lastScript = script

        if dryRun {
            return "[dry-run] would execute as administrator:\n\(script)"
        }

        // Stream the image through a FIFO from this (unprivileged) process.
        signal(SIGPIPE, SIG_IGN) // a closed reader must be an error, not a crash
        var feedTask: Task<Void, Error>?
        var feedDir: URL?
        if let feedImage {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rufusmac-feed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            feedDir = dir
            let fifo = dir.appendingPathComponent("image").path
            let hashFile = dir.appendingPathComponent("sha256").path
            guard mkfifo(fifo, 0o600) == 0 else { throw ShellError.nonZeroExit(command: "mkfifo", status: 1, stderr: "mkfifo failed") }
            script = script
                .replacingOccurrences(of: BurnPlanner.feedToken, with: "'\(fifo)'")
                .replacingOccurrences(of: BurnPlanner.hashToken, with: "'\(hashFile)'")
            feedTask = Task.detached {
                var hasher = SHA256()
                let total = Double((try? FileManager.default.attributesOfItem(atPath: feedImage.path)[.size] as? NSNumber)??.doubleValue ?? 0)
                var done = 0.0
                var lastReported = -1.0
                let input = try FileHandle(forReadingFrom: feedImage)
                defer { try? input.close() }
                // Blocks until the privileged dd opens the FIFO for reading.
                guard let out = FileHandle(forWritingAtPath: fifo) else { return }
                while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    try out.write(contentsOf: chunk)
                    done += Double(chunk.count)
                    if total > 0, done / total - lastReported >= 0.005 {
                        lastReported = done / total
                        onProgress?(min(done / total, 1))
                    }
                }
                let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                try hex.write(toFile: hashFile, atomically: true, encoding: .utf8)
                try out.close()
            }
        }
        defer {
            feedTask?.cancel()
            if let feedDir { try? FileManager.default.removeItem(at: feedDir) }
        }

        // Write the script to a temp file and execute it as admin in one prompt.
        // This avoids fragile AppleScript escaping of multi-line shell scripts.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rufusmac-\(UUID().uuidString).sh")
        let fullScript = "#!/bin/sh\nset -euo pipefail\n\(script)\n"
        try fullScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        // Run via sudo as a direct child of this app (not osascript) so macOS
        // attributes disk access to RufusMac and honours its Full Disk Access.
        let safePrompt = prompt.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\\", with: "")
        let askpassURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rufusmac-askpass-\(UUID().uuidString).sh")
        let askpass = "#!/bin/sh\n/usr/bin/osascript -e 'text returned of (display dialog \"\(safePrompt)\" default answer \"\" with hidden answer with title \"RufusMac\" with icon caution buttons {\"Cancel\", \"OK\"} default button \"OK\")'\n"
        try askpass.write(to: askpassURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpassURL.path)
        defer { try? FileManager.default.removeItem(at: askpassURL) }

        let result = try await Task.detached { () -> (ok: Bool, status: Int32, stdout: String, stderr: String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-k", "-A", "/bin/sh", scriptURL.path]
            var env = ProcessInfo.processInfo.environment
            env["SUDO_ASKPASS"] = askpassURL.path
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus == 0, p.terminationStatus,
                    String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }.value
        if let feedTask {
            if !result.ok, let feedDir {
                // Release a feeder still blocked opening the FIFO.
                let fd = open(feedDir.appendingPathComponent("image").path, O_RDONLY | O_NONBLOCK)
                if fd >= 0 { close(fd) }
            }
            _ = try? await feedTask.value
        }
        guard result.ok else {
            throw ShellError.nonZeroExit(command: "sudo", status: result.status, stderr: result.stderr)
        }
        return result.stdout
    }
}
