import Foundation

enum SharedTests {
    @MainActor
    static func run() async throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) rethrows {
            guard try condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("slow")
        try "#!/bin/sh\nexec /bin/sleep 20\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

        let running = Task { try await ProcessRunner.run(path: stub.path, arguments: [], timeout: 60) }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        running.cancel()
        do { _ = try await running.value; fatalError("a cancelled command completed") }
        catch is CancellationError { check(Date().timeIntervalSince(start) < 6, "cancelling a task stops its running process") }
        let early = Task { try await ProcessRunner.run(path: stub.path, arguments: [], timeout: 60) }
        early.cancel()
        do { _ = try await early.value; fatalError("a command cancelled before it started completed") }
        catch is CancellationError { check(true, "a task cancelled before its process starts never leaves it running") }

        check(Executable.first(["/nonexistent/tool", "/bin/sh"]) == "/bin/sh" && Executable.first(["/nonexistent/a", "/nonexistent/b"]) == "/nonexistent/a",
              "discovery takes the first executable candidate, else names the first")
        check(Executable.isPlainPath("/opt/homebrew/bin/darwin-vpn") && !Executable.isPlainPath("/tmp/a b") && !Executable.isPlainPath("/tmp/x\"y")
              && !Executable.isPlainPath("bin/x") && !Executable.isPlainPath("/tmp/../bin/sh"), "only plain absolute paths may go into a command")

        let quiet = Attention.evaluate(freePercent: 40, tunnels: [Tunnel(name: "dev", state: .disconnected, detail: "disconnected")], github: .signedIn(account: "me", role: nil))
        check(quiet == Attention(level: .ok, reasons: []), "a disconnected tunnel and enough memory need no attention")
        let tight = Attention.evaluate(freePercent: 22, tunnels: [], github: .expired)
        check(tight.level == .warning && tight.reasons.map(\.text) == ["Memory 22% free: one heavy run at a time", "GitHub is signed out"],
              "tight memory and a GitHub sign-out are warnings")
        let broken = Attention.evaluate(freePercent: 22, tunnels: [Tunnel(name: "prod", state: .broken, detail: "NOT WORKING"),
                                                                   Tunnel(name: "dev", state: .staleDNS, detail: "disconnected;")], github: .unknown)
        check(broken.level == .critical && broken.reasons.map(\.text) == ["prod VPN is up but not answering", "Memory 22% free: one heavy run at a time", "dev VPN left old DNS rules behind"],
              "a broken tunnel is critical, listed first")
        check(Attention.evaluate(freePercent: 19, tunnels: [], github: .expired).level == .critical
              && Attention.evaluate(freePercent: nil, tunnels: [], github: .unknown).level == .ok, "memory under 20% is critical; nothing known is fine")

        print("\(count) shared tests passed.")
    }
}
