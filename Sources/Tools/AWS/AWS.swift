import Foundation

struct AWSProfile: Identifiable, Equatable, Sendable {
    let name: String
    let accountID: String?
    let roleName: String?
    var id: String { name }
}

// One `aws sso login` signs in every profile that shares the session. A legacy profile with its
// own sso_start_url and no sso_session is a session of one, logged in through the profile.
struct SSOSession: Identifiable, Equatable, Sendable {
    let name: String
    let startURL: String?
    let profiles: [AWSProfile]
    let legacyProfile: Bool
    var id: String { (legacyProfile ? "profile:" : "session:") + name }
    var loginArguments: [String] { ["sso", "login", legacyProfile ? "--profile" : "--sso-session", name] }
}

enum ProfileStatus: Equatable, Sendable {
    case unknown
    case checking
    case signedIn(account: String, role: String?)
    case expired
    case failed(String)

    var isSignedIn: Bool { if case .signedIn = self { true } else { false } }
}

enum AWSConfig {
    static var defaultURL: URL {
        if let custom = ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config")
    }

    // Reads only section names and the non-secret SSO keys; ~/.aws/config holds no credentials.
    static func parse(_ text: String) -> [SSOSession] {
        var sections: [(kind: String, name: String, values: [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                let parts = header.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { sections.append((parts[0], parts[1], [:])) }
                else { sections.append(("profile", header, [:])) } // [default]
                continue
            }
            guard let equals = line.firstIndex(of: "="), !sections.isEmpty else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            sections[sections.count - 1].values[key] = value
        }
        let startURLs = Dictionary(sections.filter { $0.kind == "sso-session" }.map { ($0.name, $0.values["sso_start_url"]) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = [], grouped: [String: [AWSProfile]] = [:]
        var sessions: [SSOSession] = []
        for section in sections where section.kind == "profile" {
            let profile = AWSProfile(name: section.name, accountID: section.values["sso_account_id"], roleName: section.values["sso_role_name"])
            if let session = section.values["sso_session"] {
                if grouped[session] == nil { order.append(session) }
                grouped[session, default: []].append(profile)
            } else if let url = section.values["sso_start_url"] {
                sessions.append(SSOSession(name: section.name, startURL: url, profiles: [profile], legacyProfile: true))
            }
        }
        return order.map { SSOSession(name: $0, startURL: startURLs[$0] ?? nil, profiles: grouped[$0] ?? [], legacyProfile: false) } + sessions
    }
}

enum CallerIdentity {
    // `aws sts get-caller-identity --output json`; the role comes from the assumed-role ARN,
    // without the AWSReservedSSO_ prefix and the permission set's hash suffix.
    static func status(_ output: CommandOutput) -> ProfileStatus {
        if output.status == 0,
           let object = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any],
           let account = object["Account"] as? String {
            return .signedIn(account: account, role: (object["Arn"] as? String).flatMap(role(fromARN:)))
        }
        let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let expired = ["expired", "Error loading SSO Token", "UnauthorizedSSOToken", "SSO session", "refresh failed", "aws sso login"]
        if expired.contains(where: { message.localizedCaseInsensitiveContains($0) }) { return .expired }
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .failed(firstLine.isEmpty ? "aws exited with code \(output.status)." : firstLine)
    }

    static func role(fromARN arn: String) -> String? {
        guard let range = arn.range(of: "assumed-role/") else { return nil }
        var role = String(arn[range.upperBound...].prefix { $0 != "/" })
        if role.hasPrefix("AWSReservedSSO_") {
            role.removeFirst("AWSReservedSSO_".count)
            if let underscore = role.lastIndex(of: "_") { role = String(role[..<underscore]) }
        }
        return role.isEmpty ? nil : role
    }
}
