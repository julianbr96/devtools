import Foundation
import Darwin

struct CommandOutput: Sendable {
    let data: Data
    let stderr: String
}

enum CLI {
    static func discover() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    // No shell, credential-file parsing, analytics, web server, or output logs.
    static func run(path: String, arguments: [String], timeout: TimeInterval = 120) async throws -> CommandOutput {
        try await Task.detached(priority: .userInitiated) {
            try blockingRun(path: path, arguments: arguments, timeout: timeout)
        }.value
    }

    static func blockingRun(path: String, arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw DashboardError.message("CSWAP was not found at the selected path. Choose the cswap executable in Settings.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["NO_COLOR"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice // Never answer a hidden confirmation prompt.
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let out = DataCollector(stdout.fileHandleForReading)
        let err = DataCollector(stderr.fileHandleForReading)
        let didTimeout = finished.wait(timeout: .now() + timeout) == .timedOut
        if didTimeout {
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 3)
            }
        }
        let data = try out.result(), errorText = redact(String(decoding: try err.result(), as: UTF8.self))
        if didTimeout {
            throw DashboardError.message("CSWAP took too long. Unlock Keychain if prompted, then refresh. A write may have completed; check the active account before retrying.")
        }
        if process.terminationStatus != 0 {
            try checkEnvelope(data)
            let safeOutput = redact(String(decoding: data, as: UTF8.self))
            throw DashboardError.message(errorText.isEmpty ? (safeOutput.isEmpty ? "CSWAP exited with code \(process.terminationStatus)." : safeOutput) : errorText)
        }
        return CommandOutput(data: data, stderr: errorText)
    }
}

// Drain both pipes concurrently so a verbose subprocess cannot deadlock.
private final class DataCollector: @unchecked Sendable {
    private var data = Data()
    private let completed = DispatchSemaphore(value: 0)
    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = handle.readDataToEndOfFile()
            try? handle.close()
            completed.signal()
        }
    }
    func result() throws -> Data {
        // A descendant can inherit a pipe even after the CLI exits. Never let
        // that keep the UI busy forever; the reader owns its data until EOF.
        guard completed.wait(timeout: .now() + 3) == .success else {
            throw DashboardError.message("CSWAP left an output stream open. Check the active account before retrying; a write may have completed.")
        }
        return data
    }
}
