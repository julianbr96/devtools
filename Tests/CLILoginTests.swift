import Foundation

enum CLILoginTests {
    @MainActor
    static func run() async throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) rethrows {
            guard try condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }

        let ghOK = "github.com\n  ✓ Logged in to github.com account octocat (keyring)\n  - Active account: true\n  - Git operations protocol: ssh\n"
        check(CLIStatus.github(CommandOutput(data: Data(ghOK.utf8), stderr: "")) == .signedIn(account: "octocat", role: nil), "gh status names the signed-in account")
        check(CLIStatus.github(CommandOutput(data: Data(), stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login\n", status: 1)) == .expired,
              "no gh login is signed out")
        check(CLIStatus.github(CommandOutput(data: Data("github.com\n  X Failed to log in to github.com account octocat (keyring)\n  - The token in keyring is invalid.\n".utf8), stderr: "", status: 1)) == .expired,
              "an invalid gh token is signed out")
        check(CLIStatus.github(CommandOutput(data: Data(), stderr: "error connecting to api.github.com\n", status: 1)) == .failed("error connecting to api.github.com"),
              "a network error is not a sign-out")
        check(CLIStatus.gcloudAccount(CommandOutput(data: Data("me@example.com\n".utf8), stderr: "")) == "me@example.com"
              && CLIStatus.gcloudAccount(CommandOutput(data: Data("\n".utf8), stderr: "")) == nil, "the active gcloud account, if any")
        let tokenCommand = try CLIStatus.gcloudTokenCommand(executable: "/opt/homebrew/bin/gcloud")
        check(tokenCommand == ["-c", "'/opt/homebrew/bin/gcloud' auth print-access-token --quiet >/dev/null"],
              "the gcloud token goes to /dev/null inside the shell")
        do { _ = try CLIStatus.gcloudTokenCommand(executable: "/tmp/g'; rm -rf ~; '"); fatalError("accepted unsafe path") }
        catch { check(true, "an unsafe gcloud path never reaches the shell") }
        let script = try CLIStatus.loginScript(tool: .github, executable: "/opt/homebrew/bin/gh")
        check(script.hasPrefix("#!/bin/zsh -l\n") && script.contains("'/opt/homebrew/bin/gh' auth login --web --hostname github.com\n"), "the Terminal script runs the interactive login")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FixtureCLILogin()
        let opened = OpenLog()
        let store = CLILoginStore(demo: false, paths: [.github: "/usr/bin/true", .gcloud: "/usr/bin/true"], scriptDirectory: dir,
                                  command: { path, args, _ in try await fake.run(path, args) }, openInTerminal: { opened.record($0) })
        await store.refresh()
        check(store.status(.github) == .signedIn(account: "octocat", role: nil) && store.status(.gcloud) == .expired && store.signedInCount == 1,
              "an active gcloud account whose token cannot refresh is signed out")
        let calls = await fake.calls
        check(calls.contains(["/usr/bin/true", "auth", "status", "--hostname", "github.com"]) && calls.contains { $0.first == "/bin/sh" }, "each CLI is asked about its own login")

        let beforeCached = await fake.calls.count
        await store.refreshIfStale()
        let afterCached = await fake.calls.count
        check(afterCached == beforeCached, "a fresh check is reused")

        store.login(.gcloud)
        let written = try String(contentsOf: dir.appendingPathComponent("DevTools-login-gcloud.command"), encoding: .utf8)
        let mode = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("DevTools-login-gcloud.command").path)[.posixPermissions] as? Int) ?? 0
        check(opened.urls.map(\.lastPathComponent) == ["DevTools-login-gcloud.command"] && written.contains("'/usr/bin/true' auth login\n") && mode == 0o700,
              "login opens an executable Terminal script for the CLI")
        await fake.setGcloudValid(true)
        await store.refreshIfStale()
        check(store.status(.gcloud) == .signedIn(account: "me@example.com", role: nil), "after a Terminal login the next look re-checks")

        let missing = CLILoginStore(demo: false, paths: [.github: dir.appendingPathComponent("gh").path, .gcloud: dir.appendingPathComponent("gcloud").path],
                                    scriptDirectory: dir, command: { path, args, _ in try await fake.run(path, args) }, openInTerminal: { opened.record($0) })
        let beforeMissing = await fake.calls.count
        await missing.refresh()
        missing.login(.github)
        let afterMissing = await fake.calls.count
        check(missing.status(.github) == .failed("gh is not installed") && afterMissing == beforeMissing && opened.urls.count == 1
              && missing.error?.contains("not installed") == true, "a missing CLI runs and opens nothing")

        let demo = CLILoginStore(demo: true, scriptDirectory: dir, command: { path, args, _ in try await fake.run(path, args) }, openInTerminal: { opened.record($0) })
        await demo.refresh()
        demo.login(.github)
        check(demo.signedInCount == 1 && opened.urls.count == 1, "demo runs and opens nothing")

        print("\(count) CLI login tests passed. No real CLI was asked.")
    }
}

final class OpenLog: @unchecked Sendable {
    private(set) var urls: [URL] = []
    func record(_ url: URL) -> Bool { urls.append(url); return true }
}

actor FixtureCLILogin {
    private var gcloudValid = false
    private(set) var calls: [[String]] = []
    func setGcloudValid(_ value: Bool) { gcloudValid = value }
    func run(_ path: String, _ args: [String]) async throws -> CommandOutput {
        calls.append([path] + args)
        if args.starts(with: ["auth", "status"]) {
            return CommandOutput(data: Data("github.com\n  ✓ Logged in to github.com account octocat (keyring)\n".utf8), stderr: "")
        }
        if args.starts(with: ["auth", "list"]) { return CommandOutput(data: Data("me@example.com\n".utf8), stderr: "") }
        if path == "/bin/sh" {
            return gcloudValid ? CommandOutput(data: Data(), stderr: "")
                : CommandOutput(data: Data(), stderr: "ERROR: Reauthentication failed. cannot prompt during non-interactive execution.\n", status: 1)
        }
        throw DashboardError.message("Unexpected test command")
    }
}
