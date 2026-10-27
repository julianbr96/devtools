import Foundation

enum AttentionLevel: Int, Comparable, Sendable {
    case ok, warning, critical
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// What the menu-bar icon reports. Only states worth a glance count: memory too low for heavy work,
// a tunnel that is up but broken or left DNS rules behind, and a GitHub sign-out. A disconnected
// tunnel or a signed-out AWS profile is normal and changes nothing.
struct Attention: Equatable, Sendable {
    var level: AttentionLevel = .ok
    var reasons: [Reason] = []

    struct Reason: Equatable, Sendable {
        let level: AttentionLevel
        let text: String
    }

    static func evaluate(freePercent: Int?, tunnels: [Tunnel], github: ProfileStatus) -> Attention {
        var reasons: [Reason] = []
        if let free = freePercent {
            switch LoadVerdict(freePercent: free) {
            case .wait: reasons.append(Reason(level: .critical, text: "Memory \(free)% free: wait before heavy runs"))
            case .oneAtATime: reasons.append(Reason(level: .warning, text: "Memory \(free)% free: one heavy run at a time"))
            case .clear: break
            }
        }
        for tunnel in tunnels {
            switch tunnel.state {
            case .broken: reasons.append(Reason(level: .critical, text: "\(tunnel.name) VPN is up but not answering"))
            case .staleDNS: reasons.append(Reason(level: .warning, text: "\(tunnel.name) VPN left old DNS rules behind"))
            default: break
            }
        }
        if github == .expired { reasons.append(Reason(level: .warning, text: "GitHub is signed out")) }
        return Attention(level: reasons.map(\.level).max() ?? .ok, reasons: reasons.filter { $0.level == .critical } + reasons.filter { $0.level == .warning })
    }
}
