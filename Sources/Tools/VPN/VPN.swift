import Foundation

enum TunnelState: Equatable, Sendable {
    case connected(interface: String)
    case otherVPN(interface: String)
    case broken
    case staleDNS
    case unconfigured
    case disconnected
    case unknown

    var isConnected: Bool { if case .connected = self { true } else { false } }

    var summary: String {
        switch self {
        case .connected(let interface): "Connected · \(interface)"
        case .otherVPN(let interface): "Connected through another VPN · \(interface)"
        case .broken: "Up, but the VPN does not answer"
        case .staleDNS: "Disconnected · old DNS rules left behind"
        case .unconfigured: "Not set up"
        case .disconnected: "Disconnected"
        case .unknown: "Unrecognized status"
        }
    }

    // The darwin-vpn command that moves the tunnel forward; nil when the fix is outside this app
    // (another VPN owns the route, or the config still has to be saved with `darwin-vpn setup`).
    var action: (title: String, verb: VPNAction)? {
        switch self {
        case .connected: ("Disconnect", .down)
        case .broken: ("Reconnect", .up)
        case .staleDNS, .disconnected: ("Connect", .up)
        case .otherVPN, .unconfigured, .unknown: nil
        }
    }
}

enum VPNAction: String, Sendable {
    case up, down
}

struct Tunnel: Identifiable, Equatable, Sendable {
    let name: String
    let state: TunnelState
    let detail: String
    var id: String { name }
}

enum VPNStatus {
    // `darwin-vpn status` prints one "<env> <message>" line per environment.
    static func parse(_ output: String) -> [Tunnel] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let space = text.firstIndex(of: " ") else { return nil }
            let name = String(text[..<space])
            guard isEnvironmentName(name) else { return nil }
            let detail = text[space...].trimmingCharacters(in: .whitespaces)
            return Tunnel(name: name, state: state(for: detail), detail: detail)
        }
    }

    static func state(for detail: String) -> TunnelState {
        if detail.hasPrefix("connected through another VPN") { return .otherVPN(interface: interface(in: detail) ?? "unknown interface") }
        if detail.hasPrefix("connected") { return .connected(interface: interface(in: detail) ?? "unknown interface") }
        if detail.hasPrefix("NOT WORKING") { return .broken }
        if detail.hasPrefix("disconnected;") { return .staleDNS }
        if detail.hasPrefix("disconnected") { return .disconnected }
        if detail.hasPrefix("not set up") { return .unconfigured }
        return .unknown
    }

    static func interface(in detail: String) -> String? {
        guard let range = detail.range(of: #"\(utun[0-9]+\)"#, options: .regularExpression) else { return nil }
        return String(detail[range].dropFirst().dropLast())
    }

    static func isEnvironmentName(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
    }
}

enum PrivilegedOutcome: Equatable {
    case done(String)
    case cancelled
    case failed(String)
}

// darwin-vpn calls sudo, which needs a terminal. `do shell script … with administrator privileges`
// shows the standard macOS password prompt instead and runs the command as root.
enum PrivilegedCommand {
    static func appleScript(executable: String, action: VPNAction, environment: String) throws -> String {
        guard isSafePath(executable) else {
            throw DashboardError.message("The darwin-vpn path may only contain letters, digits, '.', '_', '-' and '/'. Choose it again in Settings.")
        }
        guard VPNStatus.isEnvironmentName(environment) else {
            throw DashboardError.message("Unexpected VPN environment name.")
        }
        let target = environment == "all" ? "all VPN tunnels" : "the \(environment) VPN"
        let prompt = "DevTools needs your password to \(action == .up ? "connect" : "disconnect") \(target)."
        let shell = "PATH=\(ProcessRunner.searchPath) '\(executable)' \(action.rawValue) \(environment) 2>&1"
        return "do shell script \"\(shell)\" with prompt \"\(prompt)\" with administrator privileges without altering line endings"
    }

    // The path is interpolated into a root shell command, so only plain path characters pass.
    static func isSafePath(_ path: String) -> Bool {
        path.range(of: #"^/[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil && !path.contains("..")
    }

    static func outcome(_ output: CommandOutput) -> PrivilegedOutcome {
        let printed = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.status == 0 { return .done(printed) }
        let error = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if error.hasSuffix("(-128)") { return .cancelled }
        // osascript reports "<range>: execution error: <command output> (<exit code>)".
        let message = error
            .replacingOccurrences(of: #"^[0-9]+:[0-9]+: execution error: "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(-?[0-9]+\)$"#, with: "", options: .regularExpression)
        return .failed(message.isEmpty ? "darwin-vpn failed (osascript exited with code \(output.status))." : message)
    }
}
