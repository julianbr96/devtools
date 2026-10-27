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

        let me = getuid()
        let raycastNode = "/Users/me/Library/Application Support/com.raycast.macos/node/runtime/bin/node"
        let paths: [Int32: String] = [
            700: "/Applications/Raycast.app/Contents/MacOS/Raycast",
            22726: raycastNode,
            61590: "/Applications/Roam.app/Contents/Frameworks/Roam Helper.app/Contents/MacOS/Roam Helper",
            61577: "/Applications/Roam.app/Contents/MacOS/Roam",
            1001: "/usr/libexec/rapportd",
            1026: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            12815: "/Users/me/.local/bin/engram",
            3900: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            4000: "/bin/zsh",
            4242: "/opt/homebrew/bin/node",
        ]
        let ps = """
            700     1 \(me)  90000  0.5 /Applications/Raycast.app/Contents/MacOS/Raycast
          22726   700 \(me) 120000  1.5 Raycast Backend
          61577     1 \(me) 200000  2.0 /Applications/Roam.app/Contents/MacOS/Roam
          61590 61577 \(me) 551360 32.5 /Applications/Roam.app/Contents/Frameworks/Roam Helper.app/Contents/MacOS/Roam Helper --type=gpu
           1001     1 \(me)   9000  0.0 /usr/libexec/rapportd
           1026     1 \(me)  80000  0.1 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
          12815     1 \(me)  40000  0.0 engram serve
           3900     1 \(me)  60000  1.0 /Applications/Ghostty.app/Contents/MacOS/ghostty
           4000  3900 \(me)   5000  0.0 -zsh
           4242  4000 \(me) 300000 12.0 node /Users/me/app/node_modules/.bin/next dev
        bad line
        """
        let rows = MachineParse.processes(ps, path: { paths[$0] })
        check(rows.count == 10 && rows[3] == ProcessRow(pid: 61590, ppid: 61577, uid: me, residentKB: 551360, cpu: 32.5,
              commandLine: "/Applications/Roam.app/Contents/Frameworks/Roam Helper.app/Contents/MacOS/Roam Helper --type=gpu", path: paths[61590]),
              "ps rows keep the full command line and the real executable")
        let versioned = ProcessRow(pid: 1, ppid: 1, uid: me, residentKB: 1, cpu: 0, commandLine: "claude --effort xhigh", path: "/Users/me/.local/share/claude/versions/2.1.310")
        let byPath = ProcessRow(pid: 1, ppid: 1, uid: me, residentKB: 1, cpu: 0, commandLine: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /data", path: "/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres")
        check(versioned.executableName == "claude" && byPath.executableName == "postgres" && rows[8].executableName == "zsh",
              "a tool is named by the command it was started as, not its versioned binary")
        check(MachineParse.bundlePath(paths[61590]) == "/Applications/Roam.app" && MachineParse.appName("/Applications/Roam.app") == "Roam", "helpers resolve to their outermost app")

        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        check(MachineParse.ownerApp(rows[1], byPID: byPID) == "/Applications/Raycast.app", "an app's background node belongs to the app that launched it")
        check(MachineParse.ownerApp(rows[9], byPID: byPID) == nil && MachineParse.ownerApp(rows[6], byPID: byPID) == nil,
              "a dev server started from a terminal shell, or by launchd, belongs to no app")

        let groups = MachineParse.groups(rows, limit: 3)
        check(groups.map(\.name) == ["Roam", "node", "Raycast"] && groups[0].appBundle == "/Applications/Roam.app" && groups[0].processes.count == 2
              && groups[1].appBundle == nil && groups[2].processes.map(\.pid) == [22726, 700],
              "apps gather their helpers; tools group by executable; sorted by memory")
        check(groups[0].residentBytes == Int64(551360 + 200000) * 1024 && groups[0].cpu == 34.5, "group totals add their processes")

        let lsof = """
        p1001
        crapportd
        n*:63525
        n*:63525
        p1026
        cControlCenter
        n*:7000
        p22726
        cnode
        n127.0.0.1:7265
        p12815
        cengram
        n127.0.0.1:7437
        p4242
        cnode
        n127.0.0.1:3000
        n[::1]:3000
        """
        let listeners = MachineParse.listeners(lsof, processes: rows)
        check(listeners.map(\.process.pid) == [12815, 4242], "only servers you started are listed: no macOS services, no app backends")
        check(listeners[1].addresses == ["127.0.0.1:3000", "[::1]:3000"] && listeners[1].ports == ["3000"], "ports deduplicated across IPv4 and IPv6")

        check(MachineParse.canSignal(rows[9]) && !MachineParse.canSignal(rows[4]), "your own tools can be stopped, macOS services cannot")
        let other = ProcessRow(pid: 9, ppid: 1, uid: me &+ 1, residentKB: 1, cpu: 0, commandLine: "x", path: "/opt/homebrew/bin/x")
        let unknown = ProcessRow(pid: 10, ppid: 1, uid: me, residentKB: 1, cpu: 0, commandLine: "x", path: nil)
        let itself = ProcessRow(pid: getpid(), ppid: 1, uid: me, residentKB: 1, cpu: 0, commandLine: "x", path: "/Applications/DevTools.app/Contents/MacOS/DevTools")
        check(!MachineParse.canSignal(other) && !MachineParse.canSignal(unknown) && !MachineParse.canSignal(itself), "never another user's process, an unknown one, or DevTools itself")
        check(MachineParse.canQuit(groups[0]) && !MachineParse.canQuit(ProcessGroup(name: "ControlCenter", appBundle: "/System/Library/CoreServices/ControlCenter.app", processes: [rows[5]]))
              && !MachineParse.canQuit(groups[1]), "apps can be quit, macOS apps and tools cannot")

        let fake = FixtureMachine(ps: "  4242 4000 \(me) 300000 12.0 node server.js\n   4000 1 \(me) 5000 0 -zsh\n",
                                  lsof: "p4242\ncnode\nn127.0.0.1:3000\n")
        let signals = SignalLog()
        let quits = QuitLog()
        let machinePaths: [Int32: String] = [4242: "/opt/homebrew/bin/node", 4000: "/bin/zsh"]
        let store = MachineStore(demo: false, command: { path, args, _ in try await fake.run(path, args) },
                                 signal: { pid, sig in signals.record(pid, sig) }, quitApp: { bundle, force in quits.record(bundle, force) },
                                 readSystem: { SystemReading(physicalBytes: 16 << 30) }, executablePath: { machinePaths[$0] }, settle: .zero)
        await store.refresh()
        check(store.freePercent == 31 && store.verdict == .clear && store.listeners.map(\.process.pid) == [4242] && store.groups.first?.name == "node",
              "refresh reads memory, processes and listeners together")

        let node = store.listeners[0].process
        await fake.setArgs("node server.js\n")
        await fake.setLsof("")
        await fake.setPS("   4000 1 \(me) 5000 0 -zsh\n")
        await store.stop(node, name: "node")
        check(signals.calls.map(\.0) == [4242] && signals.calls.map(\.1) == [SIGTERM], "stop sends SIGTERM")
        check(store.listeners.isEmpty && store.stopping.isEmpty && store.error == nil, "a stopped process leaves the lists")

        await fake.setArgs("/usr/bin/some-other-process\n")
        await store.stop(node, name: "node")
        check(signals.calls.count == 1 && store.error?.contains("no longer running") == true, "a reused PID is never signalled")
        await store.stop(other, name: "x")
        check(signals.calls.count == 1 && store.error?.contains("not one of your processes") == true, "another user's process is refused before any signal")

        await fake.setArgs("node server.js\n")
        await fake.setPS("  4242 4000 \(me) 300000 12.0 node server.js\n")
        await fake.setLsof("p4242\ncnode\nn127.0.0.1:3000\n")
        await store.refresh()
        await store.stop(node, name: "node")
        check(store.stopping[4242] != nil && !store.canForceStop(node, now: Date())
              && store.canForceStop(node, now: Date().addingTimeInterval(MachineStore.forceAfter + 1)), "force stop is offered only after the grace period")
        await store.stop(node, name: "node", force: true)
        check(signals.calls.last.map(\.1) == SIGKILL, "force stop sends SIGKILL")

        let roam = groups[0]
        await fake.setPS("  61577 1 \(me) 200000 2.0 /Applications/Roam.app/Contents/MacOS/Roam\n")
        let roamStore = MachineStore(demo: false, command: { path, args, _ in try await fake.run(path, args) },
                                     signal: { pid, sig in signals.record(pid, sig) }, quitApp: { bundle, force in quits.record(bundle, force) },
                                     readSystem: { SystemReading() }, executablePath: { paths[$0] }, settle: .zero)
        await roamStore.quit(roam)
        check(quits.calls.count == 1 && quits.calls[0].0 == "/Applications/Roam.app" && quits.calls[0].1 == false && roamStore.quitting["/Applications/Roam.app"] != nil,
              "quit asks the app to close, like ⌘Q")
        check(!roamStore.canForceQuit(roam, now: Date()) && roamStore.canForceQuit(roam, now: Date().addingTimeInterval(MachineStore.forceAfter + 1)),
              "force quit is offered only after the grace period")
        await roamStore.quit(roam, force: true)
        check(quits.calls.last.map(\.1) == true, "force quit forces")
        quits.refuse = true
        await roamStore.quit(roam)
        check(roamStore.error?.contains("not running as an app") == true, "an app that cannot be found says so")

        let demo = MachineStore(demo: true, command: { path, args, _ in try await fake.run(path, args) },
                                signal: { pid, sig in signals.record(pid, sig) }, quitApp: { bundle, force in quits.record(bundle, force) }, settle: .zero)
        let before = await fake.calls.count, signalled = signals.calls.count, quitCount = quits.calls.count
        await demo.refresh()
        await demo.stop(demo.listeners[0].process, name: "node")
        await demo.quit(demo.groups[0])
        let after = await fake.calls.count
        check(demo.freePercent != nil && after == before && signals.calls.count == signalled && quits.calls.count == quitCount, "demo runs, stops and quits nothing")

        print("\(count) Mac load tests passed. No real process was signalled or app quit.")
    }
}

final class SignalLog: @unchecked Sendable {
    private(set) var calls: [(Int32, Int32)] = []
    func record(_ pid: Int32, _ signal: Int32) -> Int32 { calls.append((pid, signal)); return 0 }
}

final class QuitLog: @unchecked Sendable {
    private(set) var calls: [(String, Bool)] = []
    var refuse = false
    func record(_ bundle: String, _ force: Bool) -> Bool {
        if refuse { return false }
        calls.append((bundle, force)); return true
    }
}

actor FixtureMachine {
    private var ps: String
    private var lsof: String
    private var args = ""
    private(set) var calls: [[String]] = []
    init(ps: String, lsof: String) { self.ps = ps; self.lsof = lsof }
    func setArgs(_ value: String) { args = value }
    func setLsof(_ value: String) { lsof = value }
    func setPS(_ value: String) { ps = value }
    func run(_ path: String, _ arguments: [String]) async throws -> CommandOutput {
        calls.append([path] + arguments)
        switch path {
        case "/usr/bin/memory_pressure": return CommandOutput(data: Data("System-wide memory free percentage: 31%\n".utf8), stderr: "")
        case "/usr/sbin/lsof": return CommandOutput(data: Data(lsof.utf8), stderr: "", status: lsof.isEmpty ? 1 : 0)
        case "/bin/ps" where arguments.first == "-axo": return CommandOutput(data: Data(ps.utf8), stderr: "")
        case "/bin/ps": return CommandOutput(data: Data(args.utf8), stderr: "", status: args.isEmpty ? 1 : 0)
        default: throw DashboardError.message("Unexpected test command")
        }
    }
}
