import Foundation
import Darwin

struct CommandOutput: Sendable {
    let data: Data
    let stderr: String
    var status: Int32 = 0
}

typealias CommandRunner = @Sendable (String, [String], TimeInterval) async throws -> CommandOutput

enum ProcessFailure: LocalizedError {
    case notExecutable
    case timedOut
    case streamLeftOpen
    var errorDescription: String? {
        switch self {
        case .notExecutable: "The executable was not found at the selected path."
        case .timedOut: "The command took too long and was stopped."
        case .streamLeftOpen: "The command left an output stream open."
        }
    }
}

// Runs an executable with an argument array and returns its exit status; each tool decides what
// a nonzero status means. No shell, credential-file parsing, analytics, web server, or output logs.
enum ProcessRunner {
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    // `unsetting` removes inherited variables, e.g. credentials exported by the shell that launched the app.
    // Cancelling the calling task stops the process and throws CancellationError.
    static func run(path: String, arguments: [String], timeout: TimeInterval = 120, environment: [String: String] = [:], unsetting: [String] = []) async throws -> CommandOutput {
        let handle = RunningProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try blockingRun(path: path, arguments: arguments, timeout: timeout, environment: environment, unsetting: unsetting, handle: handle)
            }.value
        } onCancel: {
            handle.cancel()
        }
    }

    static func blockingRun(path: String, arguments: [String], timeout: TimeInterval, environment: [String: String], unsetting: [String] = [],
                            handle: RunningProcess? = nil) throws -> CommandOutput {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw ProcessFailure.notExecutable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:\(searchPath):" + (env["PATH"] ?? "")
        for name in unsetting { env.removeValue(forKey: name) }
        env.merge(environment) { $1 }
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice // Never answer a hidden confirmation prompt.
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        handle?.attach(process)
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
        let data = try out.result(), errorData = try err.result()
        if handle?.isCancelled == true { throw CancellationError() }
        if didTimeout { throw ProcessFailure.timedOut }
        return CommandOutput(data: data, stderr: String(decoding: errorData, as: UTF8.self), status: process.terminationStatus)
    }
}

// Lets a cancelled task stop its process: SIGTERM, then SIGKILL if it is still running 3 seconds later.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func attach(_ process: Process) {
        let cancelledFirst = lock.withLock { () -> Bool in self.process = process; return cancelled }
        if cancelledFirst { Self.stop(process) }
    }

    func cancel() {
        let running = lock.withLock { () -> Process? in cancelled = true; return process }
        if let running { Self.stop(running) }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { kill(pid, SIGKILL) } }
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
        guard completed.wait(timeout: .now() + 3) == .success else { throw ProcessFailure.streamLeftOpen }
        return data
    }
}
