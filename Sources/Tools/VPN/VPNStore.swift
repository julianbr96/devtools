import SwiftUI

@MainActor
final class VPNStore: ObservableObject {
    @Published private(set) var tunnels: [Tunnel] = []
    @Published private(set) var checkedAt: Date?
    @Published private(set) var busy = false
    // The environment a connect/disconnect is running for ("all" for every tunnel).
    @Published private(set) var working: String?
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var path: String
    let demo: Bool
    private let command: CommandRunner
    private var pollingTask: Task<Void, Never>?

    static let demoStatus = "dev   connected (utun8)\nprod  disconnected\n"

    init(demo: Bool? = nil, path: String? = nil, pollingInterval: Duration? = .seconds(30), command: @escaping CommandRunner = { path, args, timeout in
        try await ProcessRunner.run(path: path, arguments: args, timeout: timeout)
    }) {
        self.demo = demo ?? CommandLine.arguments.contains("--demo")
        self.command = command
        self.path = path ?? UserDefaults.standard.string(forKey: "vpnPath") ?? Self.discover()
        if self.demo {
            tunnels = VPNStatus.parse(Self.demoStatus)
            checkedAt = Date()
        } else if let pollingInterval {
            pollingTask = Task { [weak self] in
                await self?.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: pollingInterval) } catch { return }
                    guard let self else { return }
                    await self.refresh()
                }
            }
        }
    }
    deinit { pollingTask?.cancel() }

    static func discover() -> String {
        Executable.first(["/opt/homebrew/bin/darwin-vpn", "/usr/local/bin/darwin-vpn", "\(Executable.home)/.local/bin/darwin-vpn"])
    }

    var connectedCount: Int { tunnels.filter(\.state.isConnected).count }

    func savePath(_ newPath: String) {
        path = newPath
        UserDefaults.standard.set(newPath, forKey: "vpnPath")
        tunnels = []; checkedAt = nil; error = nil; notice = nil
        Task { await refresh() }
    }

    func refresh() async {
        guard !busy, !demo else { return }
        busy = true
        defer { busy = false }
        error = nil
        await loadStatus()
    }

    func refreshIfStale(after age: TimeInterval = 10) async {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < age { return }
        await refresh()
    }

    // `status` exits 1 whenever a tunnel is down, so the printed lines are the result, not the exit code.
    private func loadStatus() async {
        do {
            let output = try await command(path, ["status"], 20)
            let parsed = VPNStatus.parse(String(decoding: output.data, as: UTF8.self))
            guard !parsed.isEmpty else {
                let reason = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DashboardError.message(reason.isEmpty ? "darwin-vpn status printed no tunnels." : reason)
            }
            tunnels = parsed
            checkedAt = Date()
        } catch { self.error = describe(error) }
    }

    func perform(_ action: VPNAction, on environment: String) async {
        guard !busy, !demo else { return }
        busy = true; working = environment; error = nil; notice = nil
        defer { busy = false; working = nil }
        do {
            guard FileManager.default.isExecutableFile(atPath: path) else { throw ProcessFailure.notExecutable }
            let script = try PrivilegedCommand.appleScript(executable: path, action: action, environment: environment)
            let output = try await command("/usr/bin/osascript", ["-e", script], 300)
            switch PrivilegedCommand.outcome(output) {
            case .done(let text): notice = text.isEmpty ? nil : text
            case .cancelled: break
            case .failed(let text): error = text
            }
        } catch { self.error = describe(error) }
        await loadStatus()
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case ProcessFailure.notExecutable: "darwin-vpn was not found at \(path). Choose it in Settings."
        case ProcessFailure.timedOut: "darwin-vpn took too long. Check the tunnel status before retrying."
        case ProcessFailure.streamLeftOpen: "darwin-vpn left an output stream open. Check the tunnel status before retrying."
        default: error.localizedDescription
        }
    }
}
