import Foundation

enum AWSTests {
    @MainActor
    static func run() async throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) rethrows {
            guard try condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }

        let config = """
        [default]
        region = us-east-1

        # team accounts
        [sso-session acme]
        sso_region = us-east-1
        sso_start_url = https://acme.awsapps.com/start
        sso_registration_scopes = sso:account:access
        [profile acme-dev]
        sso_session = acme
        sso_account_id = 111111111111
        sso_role_name = Developer
        region = us-east-1
        [profile plain]
        region = eu-west-1
        [profile old-style]
        sso_start_url = https://old.awsapps.com/start
        sso_account_id = 999999999999
        sso_role_name = ReadOnly
        [profile acme-prod]
        sso_session=acme
        sso_account_id=222222222222
        sso_role_name=AdministratorAccess
        """
        let sessions = AWSConfig.parse(config)
        check(sessions.map(\.name) == ["acme", "old-style"] && sessions[0].profiles.map(\.name) == ["acme-dev", "acme-prod"],
              "SSO profiles group by session; plain profiles are skipped")
        check(sessions[0].startURL == "https://acme.awsapps.com/start" && sessions[0].profiles[1] == AWSProfile(name: "acme-prod", accountID: "222222222222", roleName: "AdministratorAccess"),
              "session URL and profile account/role come from the config, spaces around = optional")
        check(sessions[0].loginArguments == ["sso", "login", "--sso-session", "acme"] && sessions[1].loginArguments == ["sso", "login", "--profile", "old-style"],
              "a session logs in once for all its profiles; a legacy profile logs in by itself")

        let identity = #"{"UserId":"AROAEXAMPLE:me@example.com","Account":"111111111111","Arn":"arn:aws:sts::111111111111:assumed-role/AWSReservedSSO_AdministratorAccess_0123abcd4567ef89/me@example.com"}"#
        check(CallerIdentity.status(CommandOutput(data: Data(identity.utf8), stderr: "")) == .signedIn(account: "111111111111", role: "AdministratorAccess"),
              "a caller identity is signed in, with the permission set name")
        check(CallerIdentity.role(fromARN: "arn:aws:sts::1:assumed-role/Deployer/ci") == "Deployer" && CallerIdentity.role(fromARN: "arn:aws:iam::1:user/me") == nil,
              "non-SSO roles keep their name; IAM users have no role")
        for message in ["Error when retrieving token from sso: Token has expired and refresh failed",
                        "Error loading SSO Token: Token for acme does not exist",
                        "The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile."] {
            check(CallerIdentity.status(CommandOutput(data: Data(), stderr: message + "\n", status: 255)) == .expired, "signed out: \(message.prefix(40))")
        }
        check(CallerIdentity.status(CommandOutput(data: Data(), stderr: "\nCould not connect to the endpoint URL: \"https://sts.amazonaws.com/\"\nmore\n", status: 255))
              == .failed("Could not connect to the endpoint URL: \"https://sts.amazonaws.com/\""), "other failures show their first line, not a false sign-out")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let fake = FixtureAWS(signedIn: ["acme-dev"])
        let store = AWSStore(demo: false, path: "/usr/bin/true", configURL: configURL, command: { _, args, _ in try await fake.run(args) })
        await store.refresh()
        check(store.status(sessions[0].profiles[0]) == .signedIn(account: "111111111111", role: "Developer")
              && store.status(sessions[0].profiles[1]) == .expired && store.signedInCount == 1 && store.profileCount == 3,
              "refresh checks every profile")
        let checks = await fake.calls.filter { $0.first == "sts" }
        check(checks.count == 3 && checks.allSatisfy { $0.count == 6 && $0[2] == "--profile" && $0[4...] == ["--output", "json"] }, "checks only ask STS who each profile is")
        check(store.needsLogin(store.sessions[0]), "a session with a signed-out profile needs a login")

        await fake.signIn(["acme-dev", "acme-prod"])
        let beforeLogin = await fake.calls.count
        await store.login(store.sessions[0])
        let loginCalls = await fake.calls.dropFirst(beforeLogin)
        check(loginCalls.first == ["sso", "login", "--sso-session", "acme"] && loginCalls.count == 3, "login runs once, then re-checks only that session's profiles")
        check(store.notice == "Logged in to acme." && store.loggingIn == nil && !store.needsLogin(store.sessions[0]), "a successful login signs in the whole session")

        await fake.failLogin("Error: browser authorization was denied\n")
        await store.login(store.sessions[1])
        check(store.error == "Error: browser authorization was denied" && store.loggingIn == nil, "a failed login shows the CLI's message")

        let missingCLI = AWSStore(demo: false, path: dir.appendingPathComponent("aws").path, configURL: configURL, command: { _, args, _ in try await fake.run(args) })
        let beforeMissing = await fake.calls.count
        await missingCLI.refresh()
        let afterMissing = await fake.calls.count
        check(missingCLI.error?.contains("AWS CLI was not found") == true && afterMissing == beforeMissing && missingCLI.sessions.count == 2,
              "a missing CLI still lists the profiles and runs nothing")
        let noConfig = AWSStore(demo: false, path: "/usr/bin/true", configURL: dir.appendingPathComponent("none"), command: { _, args, _ in try await fake.run(args) })
        await noConfig.refresh()
        check(noConfig.error?.contains("No AWS config") == true, "a missing config is explained")

        let stub = dir.appendingPathComponent("env-stub")
        try "#!/bin/sh\nprintf '%s|%s|%s' \"${AWS_PROFILE-unset}\" \"${AWS_SECRET_ACCESS_KEY-unset}\" \"${AWS_PAGER-unset}\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        setenv("AWS_PROFILE", "leaked", 1); setenv("AWS_SECRET_ACCESS_KEY", "leaked", 1)
        defer { unsetenv("AWS_PROFILE"); unsetenv("AWS_SECRET_ACCESS_KEY") }
        let env = try await ProcessRunner.run(path: stub.path, arguments: [], timeout: 10, environment: ["AWS_PAGER": ""], unsetting: AWSStore.inheritedCredentials)
        check(String(decoding: env.data, as: UTF8.self) == "unset|unset|", "exported credentials never reach the aws CLI")

        let demo = AWSStore(demo: true, command: { _, args, _ in try await fake.run(args) })
        let beforeDemo = await fake.calls.count
        await demo.refresh()
        await demo.login(demo.sessions[1])
        let afterDemo = await fake.calls.count
        check(demo.sessions.count == 2 && afterDemo == beforeDemo, "demo shows sample sessions and runs nothing")

        print("\(count) AWS tests passed. No real aws calls made.")
    }
}

actor FixtureAWS {
    private var signedIn: Set<String>
    private var loginError: String?
    private(set) var calls: [[String]] = []
    init(signedIn: Set<String>) { self.signedIn = signedIn }
    func signIn(_ profiles: Set<String>) { signedIn = profiles; loginError = nil }
    func failLogin(_ message: String) { loginError = message }
    func run(_ args: [String]) async throws -> CommandOutput {
        calls.append(args)
        if args.starts(with: ["sso", "login"]) {
            if let loginError { return CommandOutput(data: Data(), stderr: loginError, status: 1) }
            return CommandOutput(data: Data("Successfully logged into Start URL: https://acme.awsapps.com/start\n".utf8), stderr: "")
        }
        guard args.first == "sts", let profile = args.firstIndex(of: "--profile").map({ args[$0 + 1] }) else {
            throw DashboardError.message("Unexpected test command")
        }
        if signedIn.contains(profile) {
            let account = profile == "acme-dev" ? "111111111111" : "222222222222"
            let role = profile == "acme-dev" ? "Developer" : "AdministratorAccess"
            let json = #"{"Account":"\#(account)","Arn":"arn:aws:sts::\#(account):assumed-role/AWSReservedSSO_\#(role)_abc123/me@example.com"}"#
            return CommandOutput(data: Data(json.utf8), stderr: "")
        }
        return CommandOutput(data: Data(), stderr: "Error loading SSO Token: Token for acme does not exist\n", status: 255)
    }
}
