import SwiftUI
import AppKit
import Darwin

@MainActor
final class MachineStore: ObservableObject {
    @Published private(set) var freePercent: Int?
    @Published private(set) var system = SystemReading()
    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var listeners: [Listener] = []
    @Published private(set) var checkedAt: Date?
    @Published private(set) var busy = false
    // Processes sent SIGTERM and apps asked to quit, with when; still running after `forceAfter` offers a force.
    @Published private(set) var stopping: [Int32: Date] = [:]
    @Published private(set) var quitting: [String: Date] = [:]
    @Published var error: String?
    let demo: Bool
    private let command: CommandRunner
    private let signal: @Sendable (Int32, Int32) -> Int32
    private let quitApp: @MainActor (String, Bool) -> Bool
    private let readSystem: @Sendable () -> SystemReading
    private let executablePath: @Sendable (Int32) -> String?
    private let settle: Duration
    private var memoryTask: Task<Void, Never>?
    static let forceAfter: TimeInterval = 4

    init(demo: Bool? = nil,
         command: @escaping CommandRunner = { path, args, timeout in try await ProcessRunner.run(path: path, arguments: args, timeout: timeout) },
         signal: @escaping @Sendable (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
         quitApp: @escaping @MainActor (String, Bool) -> Bool = MachineStore.quitRunningApp,
         readSystem: @escaping @Sendable () -> SystemReading = { SystemReading.current() },
         executablePath: @escaping @Sendable (Int32) -> String? = { SystemReading.executablePath($0) },
         settle: Duration = .milliseconds(800),
         memoryPollInterval: Duration? = .seconds(30)) {
        self.demo = demo ?? CommandLine.arguments.contains("--demo")
        self.command = command
        self.signal = signal
        self.quitApp = quitApp
        self.readSystem = readSystem
        self.executablePath = executablePath
        self.settle = settle
        if self.demo { loadDemo() }
        else if let memoryPollInterval {
            // The menu-bar icon follows memory even with every view closed; only memory_pressure runs.
            memoryTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshMemory()
                    do { try await Task.sleep(for: memoryPollInterval) } catch { return }
                }
            }
        }
    }
    deinit { memoryTask?.cancel() }

    func refreshMemory() async {
        guard !demo, let output = try? await command("/usr/bin/memory_pressure", [], 15),
              let free = MachineParse.freePercent(text(output)) else { return }
        freePercent = free
    }

    var verdict: LoadVerdict? { freePercent.map(LoadVerdict.init(freePercent:)) }

    // Polls while a view showing the load is on screen; SwiftUI cancels the task when it goes away.
    func watch(every interval: Duration = .seconds(10)) async {
        while !Task.isCancelled {
            await refreshIfStale(after: 8)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    func refreshIfStale(after age: TimeInterval) async {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < age { return }
        await refresh()
    }

    func refresh() async {
        guard !busy, !demo else { return }
        busy = true
        defer { busy = false }
        do {
            async let pressure = command("/usr/bin/memory_pressure", [], 15)
            async let ps = command("/bin/ps", ["-axo", "pid=,ppid=,uid=,rss=,%cpu=,args="], 15)
            async let lsof = command("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "+c", "0", "-Fpcn"], 15)
            let rows = MachineParse.processes(text(try await ps), path: executablePath)
            guard let free = MachineParse.freePercent(text(try await pressure)) else {
                throw DashboardError.message("memory_pressure did not report a free percentage.")
            }
            // lsof exits 1 when nothing is listening; its output is still the answer.
            let found = MachineParse.listeners(text(try await lsof), processes: rows)
            let running = Set(rows.map(\.pid))
            freePercent = free
            groups = MachineParse.groups(rows)
            listeners = found
            system = readSystem()
            stopping = stopping.filter { running.contains($0.key) }
            quitting = quitting.filter { bundle, _ in rows.contains { MachineParse.bundlePath($0.path) == bundle } }
            checkedAt = Date()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func canForceStop(_ process: ProcessRow, now: Date = Date()) -> Bool {
        stopping[process.pid].map { now.timeIntervalSince($0) >= Self.forceAfter } ?? false
    }

    func canForceQuit(_ group: ProcessGroup, now: Date = Date()) -> Bool {
        group.appBundle.flatMap { quitting[$0] }.map { now.timeIntervalSince($0) >= Self.forceAfter } ?? false
    }

    // Re-reads the PID's command line first, so a PID reused since the last refresh is never signalled.
    func stop(_ process: ProcessRow, name: String, force: Bool = false) async {
        guard !demo else { return }
        var failure: String?
        do {
            guard MachineParse.canSignal(process) else { throw DashboardError.message("\(name) is not one of your processes; DevTools leaves it alone.") }
            let current = try await command("/bin/ps", ["-o", "args=", "-p", String(process.pid)], 10)
            guard text(current).trimmingCharacters(in: .whitespacesAndNewlines) == process.commandLine else {
                throw DashboardError.message("\(name) (PID \(process.pid)) is no longer running. Refreshed the list.")
            }
            guard signal(process.pid, force ? SIGKILL : SIGTERM) == 0 else {
                throw DashboardError.message("Could not stop \(name) (PID \(process.pid)): \(String(cString: strerror(errno))).")
            }
            stopping[process.pid] = Date()
            // Give the process a moment to exit before the list is read again.
            try? await Task.sleep(for: settle)
        } catch { failure = error.localizedDescription }
        await refresh()
        if let failure { error = failure }
    }

    // Quit asks the app the way ⌘Q does, so it can save or ask; Force quit ends it without asking.
    func quit(_ group: ProcessGroup, force: Bool = false) async {
        guard !demo, let bundle = group.appBundle else { return }
        var failure: String?
        if !MachineParse.canQuit(group) {
            failure = "\(group.name) is part of macOS; DevTools leaves it alone."
        } else if quitApp(bundle, force) {
            quitting[bundle] = Date()
            try? await Task.sleep(for: settle)
        } else {
            failure = "\(group.name) is not running as an app DevTools can quit. Stop its processes instead."
        }
        await refresh()
        if let failure { error = failure }
    }

    static func quitRunningApp(_ bundle: String, _ force: Bool) -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundle }
        guard !apps.isEmpty else { return false }
        return apps.map { force ? $0.forceTerminate() : $0.terminate() }.contains(true)
    }

    private func text(_ output: CommandOutput) -> String { String(decoding: output.data, as: UTF8.self) }

    private func loadDemo() {
        let uid = getuid()
        func row(_ pid: Int32, _ mb: Int, _ cpu: Double, _ line: String, _ path: String) -> ProcessRow {
            ProcessRow(pid: pid, ppid: 1, uid: uid, residentKB: mb * 1024, cpu: cpu, commandLine: line, path: path)
        }
        freePercent = 23
        system = SystemReading(physicalBytes: 16 << 30, swapUsedBytes: 2_300 << 20, swapTotalBytes: 3 << 30,
                               diskAvailableBytes: 182 << 30, diskTotalBytes: 994 << 30)
        let node = row(4242, 820, 38.0, "node /Users/me/app/node_modules/.bin/next dev", "/opt/homebrew/bin/node")
        let postgres = row(5151, 310, 0.4, "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16", "/opt/homebrew/opt/postgresql@16/bin/postgres")
        groups = [
            ProcessGroup(name: "Google Chrome", appBundle: "/Applications/Google Chrome.app",
                         processes: [row(900, 3_100, 18.4, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")]),
            ProcessGroup(name: "node", appBundle: nil, processes: [node, row(4300, 640, 4.0, "node /Users/me/app/node_modules/.bin/jest --maxWorkers=2", "/opt/homebrew/bin/node")]),
            ProcessGroup(name: "Slack", appBundle: "/Applications/Slack.app",
                         processes: [row(910, 900, 2.1, "/Applications/Slack.app/Contents/MacOS/Slack", "/Applications/Slack.app/Contents/MacOS/Slack")]),
            ProcessGroup(name: "postgres", appBundle: nil, processes: [postgres]),
        ]
        listeners = [
            Listener(process: node, name: "node", addresses: ["127.0.0.1:3000"]),
            Listener(process: postgres, name: "postgres", addresses: ["127.0.0.1:55432", "[::1]:55432"]),
        ]
        checkedAt = Date()
    }
}
