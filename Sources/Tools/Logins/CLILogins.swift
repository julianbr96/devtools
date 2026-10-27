import SwiftUI
import AppKit

// Command-line tools whose login lives in their own credential store. Status is checked in the
// background; logging in is interactive, so it runs in a Terminal window.
enum CLITool: String, CaseIterable, Identifiable, Sendable {
    case github, gcloud
    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .gcloud: "Google Cloud"
        }
    }

    var executable: String {
        switch self {
        case .github: "gh"
        case .gcloud: "gcloud"
        }
    }

    var loginArguments: [String] {
        switch self {
        case .github: ["auth", "login", "--web", "--hostname", "github.com"]
        case .gcloud: ["auth", "login"]
        }
    }

    // A token in the environment would answer for the stored login, so status checks drop it.
    var inheritedCredentials: [String] {
        switch self {
        case .github: ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"]
        case .gcloud: ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE", "CLOUDSDK_CORE_ACCOUNT"]
        }
    }

    func discover() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/\(executable)", "/usr/local/bin/\(executable)", "\(home)/.local/bin/\(executable)", "\(home)/google-cloud-sdk/bin/\(executable)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
}

enum CLIStatus {
    // `gh auth status --hostname github.com` exits 0 when the active account's token works.
    static func github(_ output: CommandOutput) -> ProfileStatus {
        let text = String(decoding: output.data, as: UTF8.self) + "\n" + output.stderr
        let account = text.range(of: #"Logged in to github\.com account [^ \n]+"#, options: .regularExpression)
            .map { String(text[$0].split(separator: " ").last ?? "") }
        if output.status == 0 { return .signedIn(account: account ?? "github.com", role: nil) }
        let signedOut = ["not logged into", "Failed to log in", "token in keyring is invalid", "gh auth login"]
        if signedOut.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return .expired }
        return .failed(firstLine(text) ?? "gh exited with code \(output.status).")
    }

    // `gcloud auth list --filter=status:ACTIVE --format=value(account)` prints the active account, if any.
    static func gcloudAccount(_ output: CommandOutput) -> String? {
        let account = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.status == 0 && !account.isEmpty ? account : nil
    }

    // Minting an access token proves the stored refresh token still works. The token goes to
    // /dev/null inside the shell, so it never reaches this app.
    static func gcloudTokenCommand(executable: String) throws -> [String] {
        guard PrivilegedCommand.isSafePath(executable) else { throw DashboardError.message("Unexpected gcloud path: \(executable)") }
        return ["-c", "'\(executable)' auth print-access-token --quiet >/dev/null"]
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    // The Terminal script for an interactive login. Only plain paths and fixed arguments go in.
    static func loginScript(tool: CLITool, executable: String) throws -> String {
        guard PrivilegedCommand.isSafePath(executable) else { throw DashboardError.message("Unexpected \(tool.executable) path: \(executable)") }
        return """
        #!/bin/zsh -l
        clear
        echo "DevTools: signing in to \(tool.title)"
        echo
        '\(executable)' \(tool.loginArguments.joined(separator: " "))
        echo
        echo "Done. Open DevTools again and it re-checks \(tool.title)."

        """
    }
}

@MainActor
final class CLILoginStore: ObservableObject {
    @Published private(set) var statuses: [CLITool: ProfileStatus] = [:]
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checking = false
    @Published var error: String?
    @Published var notice: String?
    let demo: Bool
    let paths: [CLITool: String]
    private let command: CommandRunner
    private let openInTerminal: @MainActor (URL) -> Bool
    private let scriptDirectory: URL
    // A Terminal login finishes outside the app; the next look re-checks instead of trusting the cache.
    private var recheckPending = false

    init(demo: Bool? = nil, paths: [CLITool: String]? = nil, scriptDirectory: URL = FileManager.default.temporaryDirectory,
         command: @escaping CommandRunner = { path, args, timeout in
             try await ProcessRunner.run(path: path, arguments: args, timeout: timeout,
                                         environment: ["CLOUDSDK_CORE_DISABLE_PROMPTS": "1", "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"],
                                         unsetting: CLITool.allCases.flatMap(\.inheritedCredentials))
         },
         openInTerminal: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.demo = demo ?? CommandLine.arguments.contains("--demo")
        self.paths = paths ?? Dictionary(uniqueKeysWithValues: CLITool.allCases.map { ($0, $0.discover()) })
        self.scriptDirectory = scriptDirectory
        self.command = command
        self.openInTerminal = openInTerminal
        if self.demo {
            statuses = [.github: .signedIn(account: "octocat", role: nil), .gcloud: .expired]
            checkedAt = Date()
        }
    }

    var signedInCount: Int { statuses.values.filter(\.isSignedIn).count }
    func status(_ tool: CLITool) -> ProfileStatus { statuses[tool] ?? .unknown }
    func installed(_ tool: CLITool) -> Bool { paths[tool].map { FileManager.default.isExecutableFile(atPath: $0) } ?? false }

    func refreshIfStale(after age: TimeInterval = 300) async {
        if !recheckPending, let checkedAt, Date().timeIntervalSince(checkedAt) < age { return }
        await refresh()
    }

    func refresh() async {
        guard !checking, !demo else { return }
        checking = true
        defer { checking = false }
        recheckPending = false
        for tool in CLITool.allCases { statuses[tool] = installed(tool) ? .checking : .failed("\(tool.executable) is not installed") }
        let tools = CLITool.allCases.filter(installed)
        let paths = paths, command = command
        await withTaskGroup(of: (CLITool, ProfileStatus).self) { group in
            for tool in tools {
                group.addTask { (tool, await Self.check(tool, path: paths[tool] ?? "", command: command)) }
            }
            for await (tool, status) in group { statuses[tool] = status }
        }
        checkedAt = Date()
    }

    nonisolated static func check(_ tool: CLITool, path: String, command: CommandRunner) async -> ProfileStatus {
        do {
            switch tool {
            case .github:
                return CLIStatus.github(try await command(path, ["auth", "status", "--hostname", "github.com"], 30))
            case .gcloud:
                let list = try await command(path, ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"], 45)
                guard let account = CLIStatus.gcloudAccount(list) else {
                    return list.status == 0 ? .expired : .failed(CLIStatus.firstLine(list.stderr) ?? "gcloud auth list failed.")
                }
                let token = try await command("/bin/sh", try CLIStatus.gcloudTokenCommand(executable: path), 45)
                return token.status == 0 ? .signedIn(account: account, role: nil) : .expired
            }
        } catch ProcessFailure.timedOut {
            return .failed("\(tool.executable) took too long. Check your network, then refresh.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func login(_ tool: CLITool) {
        guard !demo else { return }
        error = nil; notice = nil
        do {
            guard installed(tool), let path = paths[tool] else { throw DashboardError.message("\(tool.executable) is not installed.") }
            let script = scriptDirectory.appendingPathComponent("DevTools-login-\(tool.rawValue).command")
            try CLIStatus.loginScript(tool: tool, executable: path).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard openInTerminal(script) else { throw DashboardError.message("Could not open Terminal for the \(tool.title) login.") }
            recheckPending = true
            notice = "Finish signing in to \(tool.title) in the Terminal window. DevTools re-checks when you open it again."
        } catch { self.error = error.localizedDescription }
    }
}
