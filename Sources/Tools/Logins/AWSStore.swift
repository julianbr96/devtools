import SwiftUI

@MainActor
final class AWSStore: ObservableObject {
    @Published private(set) var sessions: [SSOSession] = []
    @Published private(set) var statuses: [String: ProfileStatus] = [:]
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checking = false
    // The session whose browser login is running.
    @Published private(set) var loggingIn: String?
    @Published var error: String?
    @Published var notice: String?
    let path: String
    let demo: Bool
    private let configURL: URL
    private let command: CommandRunner

    // Exported credentials (e.g. from `aws configure export-credentials --format env`) would
    // override --profile, so every aws call drops them.
    static let inheritedCredentials = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_CREDENTIAL_EXPIRATION",
                                       "AWS_PROFILE", "AWS_DEFAULT_PROFILE"]

    init(demo: Bool? = nil, path: String? = nil, configURL: URL = AWSConfig.defaultURL, command: @escaping CommandRunner = { path, args, timeout in
        try await ProcessRunner.run(path: path, arguments: args, timeout: timeout,
                                    environment: ["AWS_PAGER": "", "NO_COLOR": "1"], unsetting: AWSStore.inheritedCredentials)
    }) {
        self.demo = demo ?? CommandLine.arguments.contains("--demo")
        self.path = path ?? Self.discover()
        self.configURL = configURL
        self.command = command
        if self.demo { loadDemo() }
    }

    static func discover() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "\(home)/.local/bin/aws"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    var busy: Bool { checking || loggingIn != nil }
    var signedInCount: Int { statuses.values.filter(\.isSignedIn).count }
    var profileCount: Int { sessions.reduce(0) { $0 + $1.profiles.count } }
    func status(_ profile: AWSProfile) -> ProfileStatus { statuses[profile.name] ?? .unknown }
    func needsLogin(_ session: SSOSession) -> Bool { session.profiles.contains { !status($0).isSignedIn } }

    func refreshIfStale(after age: TimeInterval = 300) async {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < age { return }
        await refresh()
    }

    // Re-reads ~/.aws/config, then asks STS who each profile is. Read-only: nothing is assumed or written.
    func refresh() async {
        guard !busy, !demo else { return }
        checking = true
        defer { checking = false }
        error = nil
        do {
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                sessions = []; statuses = [:]
                throw DashboardError.message("No AWS config at \(configURL.path). Run aws configure sso first.")
            }
            sessions = AWSConfig.parse(try String(contentsOf: configURL, encoding: .utf8))
            guard !sessions.isEmpty else { throw DashboardError.message("\(configURL.path) has no SSO profiles.") }
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw DashboardError.message("The AWS CLI was not found at \(path). Install AWS CLI v2 (brew install awscli).")
            }
            await check(sessions.flatMap(\.profiles))
            checkedAt = Date()
        } catch { self.error = error.localizedDescription }
    }

    private func check(_ profiles: [AWSProfile]) async {
        for profile in profiles { statuses[profile.name] = .checking }
        let path = path, command = command
        await withTaskGroup(of: (String, ProfileStatus).self) { group in
            for profile in profiles {
                group.addTask {
                    do {
                        let output = try await command(path, ["sts", "get-caller-identity", "--profile", profile.name, "--output", "json"], 30)
                        return (profile.name, CallerIdentity.status(output))
                    } catch ProcessFailure.timedOut {
                        return (profile.name, .failed("aws took too long. Check your network, then refresh."))
                    } catch {
                        return (profile.name, .failed(error.localizedDescription))
                    }
                }
            }
            for await (name, status) in group { statuses[name] = status }
        }
    }

    // Opens the browser for approval and waits for it; the CLI caches the SSO token itself.
    func login(_ session: SSOSession) async {
        guard !busy, !demo else { return }
        loggingIn = session.id; error = nil; notice = nil
        do {
            let output = try await command(path, session.loginArguments, 300)
            if output.status != 0 {
                let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DashboardError.message(message.isEmpty ? "aws sso login exited with code \(output.status)." : message)
            }
            notice = "Logged in to \(session.name)."
        } catch ProcessFailure.timedOut {
            error = "The \(session.name) login was not approved within 5 minutes. Try again."
        } catch { self.error = error.localizedDescription }
        loggingIn = nil
        checking = true
        await check(session.profiles)
        checking = false
    }

    private func loadDemo() {
        sessions = [
            SSOSession(name: "acme", startURL: "https://acme.awsapps.com/start", profiles: [
                AWSProfile(name: "acme-dev", accountID: "111111111111", roleName: "Developer"),
                AWSProfile(name: "acme-prod", accountID: "222222222222", roleName: "ReadOnly"),
            ], legacyProfile: false),
            SSOSession(name: "sandbox", startURL: "https://sandbox.awsapps.com/start", profiles: [
                AWSProfile(name: "sandbox-admin", accountID: "333333333333", roleName: "AdministratorAccess"),
            ], legacyProfile: false),
        ]
        statuses = ["acme-dev": .signedIn(account: "111111111111", role: "Developer"),
                    "acme-prod": .signedIn(account: "222222222222", role: "ReadOnly"),
                    "sandbox-admin": .expired]
        checkedAt = Date()
    }
}
