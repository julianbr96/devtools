import Foundation

enum VPNTests {
    @MainActor
    static func run() async throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) rethrows {
            guard try condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }

        let mixed = VPNStatus.parse("""
        dev   connected (utun8)
        prod  connected through another VPN (utun4), probably the WireGuard app
        """)
        check(mixed == [
            Tunnel(name: "dev", state: .connected(interface: "utun8"), detail: "connected (utun8)"),
            Tunnel(name: "prod", state: .otherVPN(interface: "utun4"), detail: "connected through another VPN (utun4), probably the WireGuard app"),
        ], "status lines parse into named tunnels with their interface")
        check(VPNStatus.state(for: "NOT WORKING: the tunnel is up but the dev VPN does not answer; run: darwin-vpn up dev") == .broken, "a tunnel that does not answer is broken")
        check(VPNStatus.state(for: "disconnected; a previous connection left DNS rules behind; run: darwin-vpn down dev") == .staleDNS, "leftover DNS rules are reported apart from a clean disconnect")
        check(VPNStatus.state(for: "disconnected") == .disconnected, "plain disconnect")
        check(VPNStatus.state(for: "not set up; run: darwin-vpn setup prod [file]") == .unconfigured, "missing config")
        check(VPNStatus.state(for: "warming up") == .unknown, "unrecognized wording is never guessed")
        check(VPNStatus.parse("darwin-vpn: only macOS is supported\n\n").isEmpty, "error lines are not tunnels")

        check(TunnelState.connected(interface: "utun8").action?.verb == .down, "a connected tunnel offers disconnect")
        check(TunnelState.broken.action?.title == "Reconnect" && TunnelState.broken.action?.verb == .up, "a broken tunnel offers reconnect")
        check(TunnelState.staleDNS.action?.verb == .up && TunnelState.disconnected.action?.verb == .up, "down tunnels offer connect")
        check(TunnelState.otherVPN(interface: "utun4").action == nil && TunnelState.unconfigured.action == nil, "no action when the fix is outside the app")

        let script = try PrivilegedCommand.appleScript(executable: "/opt/homebrew/bin/darwin-vpn", action: .up, environment: "dev")
        check(script.contains("'/opt/homebrew/bin/darwin-vpn' up dev 2>&1") && script.hasSuffix("with administrator privileges without altering line endings"),
              "connect runs darwin-vpn through the administrator prompt")
        check(script.contains("with prompt \"DevTools needs your password to connect the dev VPN.\""), "the password prompt names the action and environment")
        for unsafe in ["/tmp/x\"; rm -rf /", "/tmp/dar win-vpn", "relative/darwin-vpn", "/tmp/../bin/sh", "/tmp/$(id)"] {
            do { _ = try PrivilegedCommand.appleScript(executable: unsafe, action: .up, environment: "dev"); fatalError("accepted \(unsafe)") }
            catch { check(true, "unsafe path rejected: \(unsafe)") }
        }
        do { _ = try PrivilegedCommand.appleScript(executable: "/opt/homebrew/bin/darwin-vpn", action: .down, environment: "dev; id"); fatalError("accepted environment") }
        catch { check(true, "unsafe environment rejected") }

        check(PrivilegedCommand.outcome(CommandOutput(data: Data("dev: connected\n".utf8), stderr: "")) == .done("dev: connected"), "success returns darwin-vpn's output")
        check(PrivilegedCommand.outcome(CommandOutput(data: Data(), stderr: "0:180: execution error: User canceled. (-128)\n", status: 1)) == .cancelled, "closing the password prompt is a cancel, not an error")
        check(PrivilegedCommand.outcome(CommandOutput(data: Data(), stderr: "0:180: execution error: dev: failed to connect (wg-quick output above) (1)\n", status: 1))
              == .failed("dev: failed to connect (wg-quick output above)"), "failures keep darwin-vpn's message without osascript's framing")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("fake-darwin-vpn")
        try "#!/bin/sh\nprintf 'dev   disconnected\\n'\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let real = VPNStore(demo: false, path: stub.path, pollingInterval: nil)
        await real.refresh()
        check(real.tunnels.map(\.state) == [.disconnected] && real.error == nil, "a nonzero status exit still yields the printed tunnels")

        let fake = FixtureVPN(status: "dev   disconnected\nprod  connected (utun11)\n")
        let store = VPNStore(demo: false, path: stub.path, pollingInterval: nil, command: { path, args, _ in try await fake.run(path, args) })
        let idleCalls = await fake.calls
        check(store.tunnels.isEmpty && idleCalls.isEmpty, "nothing runs without a refresh when polling is off")
        await store.refresh()
        check(store.tunnels.count == 2 && store.connectedCount == 1, "refresh loads every tunnel")

        await fake.setOsascript(CommandOutput(data: Data("dev: connected\n".utf8), stderr: ""))
        await store.perform(.up, on: "dev")
        let upCalls = await fake.calls
        check(upCalls.count == 3 && upCalls[1].path == "/usr/bin/osascript" && upCalls[1].args[1].contains("up dev") && upCalls[2].args == ["status"],
              "connect goes through osascript, then re-reads status")
        check(store.notice == "dev: connected" && store.error == nil && !store.busy && store.working == nil, "connect output is shown as a notice")

        await fake.setOsascript(CommandOutput(data: Data(), stderr: "0:1: execution error: User canceled. (-128)", status: 1))
        await store.perform(.down, on: "prod")
        check(store.error == nil && store.notice == nil, "a cancelled prompt shows no error")

        await fake.setOsascript(CommandOutput(data: Data(), stderr: "0:1: execution error: prod: failed to disconnect (wg-quick output above) (1)", status: 1))
        await store.perform(.down, on: "prod")
        check(store.error == "prod: failed to disconnect (wg-quick output above)", "a failed command keeps its error after the status re-read")

        let silent = FixtureVPN(status: "", stderr: "darwin-vpn: only macOS is supported\n")
        let silentStore = VPNStore(demo: false, path: stub.path, pollingInterval: nil, command: { path, args, _ in try await silent.run(path, args) })
        await silentStore.refresh()
        check(silentStore.error == "darwin-vpn: only macOS is supported" && silentStore.tunnels.isEmpty, "status with no tunnels surfaces darwin-vpn's error")

        let missing = VPNStore(demo: false, path: dir.appendingPathComponent("missing").path, pollingInterval: nil, command: { path, args, _ in try await fake.run(path, args) })
        let before = await fake.calls.count
        await missing.perform(.up, on: "dev")
        let missingCalls = await fake.calls.dropFirst(before)
        check(missingCalls.map(\.args) == [["status"]] && missing.error?.contains("was not found") == true, "a missing darwin-vpn never reaches the password prompt")

        let demo = VPNStore(demo: true, pollingInterval: nil, command: { path, args, _ in try await fake.run(path, args) })
        let demoBefore = await fake.calls.count
        await demo.perform(.up, on: "prod")
        await demo.refresh()
        let demoAfter = await fake.calls.count
        check(demo.tunnels.count == 2 && demoAfter == demoBefore, "demo shows sample tunnels and runs nothing")

        print("\(count) VPN tests passed. No real tunnels changed.")
    }
}

actor FixtureVPN {
    private let status: String
    private let stderr: String
    private var osascript = CommandOutput(data: Data(), stderr: "")
    private(set) var calls: [(path: String, args: [String])] = []
    init(status: String, stderr: String = "") {
        self.status = status
        self.stderr = stderr
    }
    func setOsascript(_ output: CommandOutput) { osascript = output }
    func run(_ path: String, _ args: [String]) async throws -> CommandOutput {
        calls.append((path, args))
        if path == "/usr/bin/osascript" { return osascript }
        guard args == ["status"] else { throw DashboardError.message("Unexpected test command") }
        return CommandOutput(data: Data(status.utf8), stderr: stderr, status: 1)
    }
}
