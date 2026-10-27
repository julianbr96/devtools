import SwiftUI
import Darwin

@MainActor
final class MachineStore: ObservableObject {
    @Published private(set) var freePercent: Int?
    @Published private(set) var system = SystemReading()
    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var listeners: [Listener] = []
    @Published private(set) var checkedAt: Date?
    @Published private(set) var busy = false
    // Listeners sent SIGTERM, with when; one still listening after `forceAfter` offers a force stop.
    @Published private(set) var stopping: [Int32: Date] = [:]
    @Published var error: String?
    let demo: Bool
    private let command: CommandRunner
    private let signal: @Sendable (Int32, Int32) -> Int32
    private let readSystem: @Sendable () -> SystemReading
    private let settle: Duration
    static let forceAfter: TimeInterval = 3

    init(demo: Bool? = nil,
         command: @escaping CommandRunner = { path, args, timeout in try await ProcessRunner.run(path: path, arguments: args, timeout: timeout) },
         signal: @escaping @Sendable (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
         readSystem: @escaping @Sendable () -> SystemReading = { SystemReading.current() },
         settle: Duration = .milliseconds(800)) {
        self.demo = demo ?? CommandLine.arguments.contains("--demo")
        self.command = command
        self.signal = signal
        self.readSystem = readSystem
        self.settle = settle
        if self.demo { loadDemo() }
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
            async let ps = command("/bin/ps", ["-axo", "pid=,rss=,%cpu=,comm="], 15)
            async let lsof = command("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "+c", "0", "-Fpcn"], 15)
            let rows = MachineParse.processes(text(try await ps))
            guard let free = MachineParse.freePercent(text(try await pressure)) else {
                throw DashboardError.message("memory_pressure did not report a free percentage.")
            }
            // lsof exits 1 when nothing is listening; its output is still the answer.
            let found = MachineParse.listeners(text(try await lsof), processes: rows)
            freePercent = free
            groups = MachineParse.groups(rows)
            listeners = found
            system = readSystem()
            stopping = stopping.filter { pid, _ in found.contains { $0.pid == pid } }
            checkedAt = Date()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func canForceStop(_ listener: Listener, now: Date = Date()) -> Bool {
        stopping[listener.pid].map { now.timeIntervalSince($0) >= Self.forceAfter } ?? false
    }

    // Re-reads the PID's command first, so a PID reused since the last refresh is never signalled.
    func stop(_ listener: Listener, force: Bool = false) async {
        guard !demo else { return }
        var failure: String?
        do {
            let current = try await command("/bin/ps", ["-o", "comm=", "-p", String(listener.pid)], 10)
            guard text(current).trimmingCharacters(in: .whitespacesAndNewlines) == listener.command else {
                throw DashboardError.message("\(listener.name) (PID \(listener.pid)) is no longer running. Refreshed the list.")
            }
            guard signal(listener.pid, force ? SIGKILL : SIGTERM) == 0 else {
                throw DashboardError.message("Could not stop \(listener.name) (PID \(listener.pid)): \(String(cString: strerror(errno))).")
            }
            stopping[listener.pid] = Date()
            // Give the process a moment to close its sockets before the list is read again.
            try? await Task.sleep(for: settle)
        } catch { failure = error.localizedDescription }
        await refresh()
        if let failure { error = failure }
    }

    private func text(_ output: CommandOutput) -> String { String(decoding: output.data, as: UTF8.self) }

    private func loadDemo() {
        freePercent = 23
        system = SystemReading(physicalBytes: 16 << 30, swapUsedBytes: 2_300 << 20, swapTotalBytes: 3 << 30,
                               diskAvailableBytes: 182 << 30, diskTotalBytes: 994 << 30)
        groups = [
            ProcessGroup(name: "Google Chrome", residentBytes: 3_100 << 20, cpu: 18.4, count: 31),
            ProcessGroup(name: "node", residentBytes: 1_900 << 20, cpu: 42.0, count: 6),
            ProcessGroup(name: "Slack", residentBytes: 900 << 20, cpu: 2.1, count: 5),
            ProcessGroup(name: "postgres", residentBytes: 310 << 20, cpu: 0.4, count: 9),
        ]
        listeners = [
            Listener(pid: 4242, name: "node", command: "/opt/homebrew/bin/node", addresses: ["127.0.0.1:3000"]),
            Listener(pid: 5151, name: "postgres", command: "/opt/homebrew/opt/postgresql@16/bin/postgres", addresses: ["127.0.0.1:55432", "[::1]:55432"]),
        ]
        checkedAt = Date()
    }
}
