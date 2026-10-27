import Foundation

// CSWAP's process adapter: where cswap lives, its JSON error envelope, and its error messages.
enum CLI {
    static func discover() -> String {
        Executable.first(["\(Executable.home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"])
    }

    static func run(path: String, arguments: [String], timeout: TimeInterval = 120) async throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try await ProcessRunner.run(path: path, arguments: arguments, timeout: timeout,
                                                 environment: ["NO_COLOR": "1", "PYTHONUNBUFFERED": "1"])
        } catch ProcessFailure.notExecutable {
            throw DashboardError.message("CSWAP was not found at the selected path. Choose the cswap executable in Settings.")
        } catch ProcessFailure.timedOut {
            throw DashboardError.message("CSWAP took too long. Unlock Keychain if prompted, then refresh. A write may have completed; check the active account before retrying.")
        } catch ProcessFailure.streamLeftOpen {
            throw DashboardError.message("CSWAP left an output stream open. Check the active account before retrying; a write may have completed.")
        }
        let errorText = redact(output.stderr)
        if output.status != 0 {
            try checkEnvelope(output.data)
            let safeOutput = redact(String(decoding: output.data, as: UTF8.self))
            throw DashboardError.message(errorText.isEmpty ? (safeOutput.isEmpty ? "CSWAP exited with code \(output.status)." : safeOutput) : errorText)
        }
        return CommandOutput(data: output.data, stderr: errorText)
    }
}
