import Foundation
import Darwin

enum MachineTests {
    @MainActor
    static func run() async throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) rethrows {
            guard try condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }

        check(MachineParse.freePercent("Pageouts: 178671 \n\nSystem-wide memory free percentage: 47%\n") == 47, "free percentage read from memory_pressure")
        check(MachineParse.freePercent("no such line") == nil, "a missing free percentage is never guessed")
        check(LoadVerdict(freePercent: 19) == .wait && LoadVerdict(freePercent: 20) == .oneAtATime
              && LoadVerdict(freePercent: 24) == .oneAtATime && LoadVerdict(freePercent: 25) == .clear, "verdict thresholds: wait under 20, push from 25")

        let rows = MachineParse.processes("""
          61590 551360  32.5 /Applications/Roam.app/Contents/Frameworks/Roam Helper.app/Contents/MacOS/Roam Helper
          61586 253584  14.0 /Applications/Roam.app/Contents/Frameworks/Roam Helper (Renderer).app/Contents/MacOS/Roam Helper (Renderer)
          51870 305024   3.7 /Applications/WhatsApp.localized/WhatsApp.app/Contents/MacOS/WhatsApp
          57951 377168   6.2 claude
           1001   9000   0.0 /usr/libexec/rapportd
           1026  80000   0.1 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
          12815  40000   0.0 /Users/me/.local/bin/engram
          22726 120000   1.5 /opt/homebrew/bin/node
        bad line
        """)
        check(rows.count == 8 && rows[0] == ProcessRow(pid: 61590, residentKB: 551360, cpu: 32.5, command: "/Applications/Roam.app/Contents/Frameworks/Roam Helper.app/Contents/MacOS/Roam Helper"),
              "ps rows keep commands with spaces")
        check(MachineParse.appName(rows[0].command) == "Roam" && MachineParse.appName(rows[2].command) == "WhatsApp"
              && MachineParse.appName("claude") == "claude" && MachineParse.appName("/opt/homebrew/bin/node") == "node", "helpers belong to their outermost app")
        let groups = MachineParse.groups(rows, limit: 2)
        check(groups == [ProcessGroup(name: "Roam", residentBytes: Int64(551360 + 253584) * 1024, cpu: 46.5, count: 2),
                         ProcessGroup(name: "claude", residentBytes: 377168 * 1024, cpu: 6.2, count: 1)], "apps sum their helpers and sort by memory")

        let lsof = """
        p1001
        crapportd
        f12
        n*:63525
        f15
        n*:63525
        p1026
        cControlCenter
        f9
        n*:7000
        p12815
        cengram
        f9
        n127.0.0.1:7437
        p22726
        cnode
        f144
        n127.0.0.1:3000
        f145
        n[::1]:3000
        """
        let listeners = MachineParse.listeners(lsof, processes: rows)
        check(listeners.map(\.pid) == [12815, 22726], "macOS services and apps are never offered for stopping")
        check(listeners[1].addresses == ["127.0.0.1:3000", "[::1]:3000"] && listeners[1].ports == ["3000"] && listeners[1].command == "/opt/homebrew/bin/node",
              "one row per process, ports deduplicated across IPv4 and IPv6")

        let fake = FixtureMachine(ps: "  22726 120000 1.5 /opt/homebrew/bin/node\n", lsof: "p22726\ncnode\nn127.0.0.1:3000\n")
        let signals = SignalLog()
        let store = MachineStore(demo: false, command: { path, args, _ in try await fake.run(path, args) },
                                 signal: { pid, sig in signals.record(pid, sig) }, readSystem: { SystemReading(physicalBytes: 16 << 30) }, settle: .zero)
        await store.refresh()
        check(store.freePercent == 31 && store.verdict == .clear && store.listeners.map(\.pid) == [22726] && store.groups.first?.name == "node",
              "refresh reads memory, processes and listeners together")

        await fake.setComm("/opt/homebrew/bin/node\n")
        await fake.setLsof("")
        let node = store.listeners[0]
        await store.stop(node)
        check(signals.calls.map(\.1) == [SIGTERM] && signals.calls.map(\.0) == [22726], "stop sends SIGTERM to the listener")
        check(store.listeners.isEmpty && store.stopping.isEmpty && store.error == nil, "a stopped listener leaves the list")

        await fake.setComm("/usr/bin/some-other-process\n")
        await store.stop(node)
        check(signals.calls.count == 1 && store.error?.contains("no longer running") == true, "a reused PID is never signalled")

        await fake.setComm("/opt/homebrew/bin/node\n")
        await fake.setLsof("p22726\ncnode\nn127.0.0.1:3000\n")
        await store.refresh()
        await store.stop(store.listeners[0])
        let stuck = store.listeners[0]
        check(store.stopping[22726] != nil && !store.canForceStop(stuck, now: Date())
              && store.canForceStop(stuck, now: Date().addingTimeInterval(MachineStore.forceAfter + 1)), "force stop is offered only after the grace period")
        await store.stop(stuck, force: true)
        check(signals.calls.last.map(\.1) == SIGKILL, "force stop sends SIGKILL")

        let demo = MachineStore(demo: true, command: { path, args, _ in try await fake.run(path, args) }, signal: { pid, sig in signals.record(pid, sig) }, settle: .zero)
        let before = await fake.calls.count, signalled = signals.calls.count
        await demo.refresh()
        await demo.stop(demo.listeners[0])
        let after = await fake.calls.count
        check(demo.freePercent != nil && after == before && signals.calls.count == signalled, "demo runs nothing and stops nothing")

        print("\(count) Mac load tests passed. No real process was signalled.")
    }
}

final class SignalLog: @unchecked Sendable {
    private(set) var calls: [(Int32, Int32)] = []
    func record(_ pid: Int32, _ signal: Int32) -> Int32 { calls.append((pid, signal)); return 0 }
}

actor FixtureMachine {
    private var ps: String
    private var lsof: String
    private var comm = ""
    private(set) var calls: [[String]] = []
    init(ps: String, lsof: String) { self.ps = ps; self.lsof = lsof }
    func setComm(_ value: String) { comm = value }
    func setLsof(_ value: String) { lsof = value }
    func run(_ path: String, _ args: [String]) async throws -> CommandOutput {
        calls.append([path] + args)
        switch path {
        case "/usr/bin/memory_pressure": return CommandOutput(data: Data("System-wide memory free percentage: 31%\n".utf8), stderr: "")
        case "/usr/sbin/lsof": return CommandOutput(data: Data(lsof.utf8), stderr: "", status: lsof.isEmpty ? 1 : 0)
        case "/bin/ps" where args.first == "-axo": return CommandOutput(data: Data(ps.utf8), stderr: "")
        case "/bin/ps": return CommandOutput(data: Data(comm.utf8), stderr: "", status: comm.isEmpty ? 1 : 0)
        default: throw DashboardError.message("Unexpected test command")
        }
    }
}
