import Foundation

enum DashboardError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Dates {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Time unknown" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

struct QuotaWindow: Decodable, Sendable {
    let pct: Double?
    let resetsAt: String?
    let countdown: String?
    let clock: String?
    let name: String?
    var remaining: Double? {
        guard let pct, pct.isFinite else { return nil }
        return min(100, max(0, 100 - pct))
    }
    var resetDate: Date? { Dates.parse(resetsAt) }
    func expired(now: Date = Date()) -> Bool { resetDate.map { $0 <= now } ?? false }
    func resetLabel(now: Date = Date()) -> String {
        guard let reset = resetDate else { return "Reset time unavailable" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset passed · refresh needed" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if minutes < 1440 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h"
    }
}

struct Usage: Decodable, Sendable {
    let fiveHour: QuotaWindow?
    let sevenDay: QuotaWindow?
    let scoped: [QuotaWindow]?
}

struct Account: Decodable, Identifiable, Sendable {
    let number: Int
    let email: String
    let organizationName: String?
    let organizationUuid: String?
    let active: Bool
    let alias: String?
    let disabled: Bool?
    let usageStatus: String
    let usage: Usage?
    let usageFetchedAt: String?
    let usageAgeSeconds: Double?
    let lastGoodUsage: Usage?
    let lastGoodFetchedAt: String?
    let lastGoodAgeSeconds: Double?
    var id: Int { number }
    var title: String { alias.flatMap { $0.isEmpty ? nil : $0 } ?? email.components(separatedBy: "@").first ?? email }
    var organization: String { organizationName.flatMap { $0.isEmpty ? nil : $0 } ?? "Personal account" }
    var initials: String { String(title.prefix(2)).uppercased() }
    var displayUsage: Usage? { usage ?? lastGoodUsage }
    var measuredAt: Date? { Dates.parse(usage != nil ? usageFetchedAt : lastGoodFetchedAt) }
    var isLastKnown: Bool { usage == nil && lastGoodUsage != nil }
    func outdated(now: Date = Date()) -> Bool {
        if isLastKnown || usageStatus != "ok" { return true }
        guard let measuredAt else { return true }
        return now.timeIntervalSince(measuredAt) > 300
    }
    var statusLabel: String {
        switch usageStatus {
        case "ok": return "Quota available"
        case "api_key": return "API key · no subscription quota"
        case "token_expired": return "Token refresh pending"
        case "relogin_required": return "Sign-in required"
        case "keychain_unavailable": return "Unlock your Keychain"
        case "foreign_credential": return "Login identity mismatch"
        case "no_credentials": return "Credentials missing"
        default: return "Quota unavailable"
        }
    }
    func sameIdentity(as other: Account) -> Bool {
        number == other.number && email == other.email && (organizationUuid ?? "") == (other.organizationUuid ?? "")
    }
}

struct AccountsResponse: Decodable, Sendable {
    let schemaVersion: Int
    let activeAccountNumber: Int?
    let accounts: [Account]
    let duplicateAccountWarnings: [String]?
    let lockstepUsageWarnings: [String]?
    var warnings: [String] { (duplicateAccountWarnings ?? []) + (lockstepUsageWarnings ?? []) }
    static func decode(_ data: Data) throws -> Self {
        try checkEnvelope(data)
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1 else { throw DashboardError.message("This CSWAP JSON version is not supported. Update the dashboard before switching.") }
        guard Set(result.accounts.map(\.number)).count == result.accounts.count else {
            throw DashboardError.message("CSWAP returned duplicate account slots. Check cswap list in Terminal.")
        }
        return result
    }

    // Shift only bundled sample dates, preserving the sample's age/reset offsets.
    // Live CLI payloads must always go through decode without this adjustment.
    static func decodeDemo(_ data: Data, now: Date = Date()) throws -> Self {
        let original = try decode(data)
        guard let anchor = original.accounts.compactMap({ Dates.parse($0.usageFetchedAt) }).max() else { return original }
        let offset = now.timeIntervalSince(anchor)
        let formatter = ISO8601DateFormatter()
        let dateKeys: Set<String> = ["usageFetchedAt", "lastGoodFetchedAt", "resetsAt"]
        func transform(_ object: Any) -> Any {
            if let values = object as? [Any] { return values.map(transform) }
            if let values = object as? [String: Any] {
                return Dictionary(uniqueKeysWithValues: values.map { key, value in
                    if dateKeys.contains(key), let raw = value as? String, let date = Dates.parse(raw) {
                        return (key, formatter.string(from: date.addingTimeInterval(offset)) as Any)
                    }
                    return (key, transform(value))
                })
            }
            return object
        }
        return try decode(JSONSerialization.data(withJSONObject: transform(JSONSerialization.jsonObject(with: data))))
    }
}

struct SwitchResponse: Decodable, Sendable {
    let schemaVersion: Int
    let switched: Bool
    let message: String
    let warnings: [String]?
}

enum ReviewLocation { case dashboard, menuBar }

struct AccountReview: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
    let target: Account?
    let current: Account?
    let isRecommendation: Bool
    let excluded: [String]
}

enum BestAccountSelector {
    static func headroom(_ account: Account, now: Date = Date()) -> Double? {
        guard account.usageStatus == "ok", !account.outdated(now: now),
              let measured = account.measuredAt, measured <= now.addingTimeInterval(60),
              let five = account.usage?.fiveHour, let week = account.usage?.sevenDay,
              !five.expired(now: now), !week.expired(now: now),
              let fiveUsed = five.pct, let weekUsed = week.pct,
              fiveUsed.isFinite, weekUsed.isFinite, fiveUsed >= 0, weekUsed >= 0,
              let fiveLeft = five.remaining, let weekLeft = week.remaining else { return nil }
        return min(fiveLeft, weekLeft)
    }

    static func review(_ snapshot: AccountsResponse, now: Date = Date(), name: (Account) -> String = { $0.title }) -> AccountReview {
        let current = snapshot.accounts.first { $0.active }
        let otherAccounts = snapshot.accounts.filter { !$0.active }
        var excluded: [String] = []
        var eligible: [(Account, Double)] = []
        for account in otherAccounts.sorted(by: { $0.number < $1.number }) {
            if account.disabled == true {
                excluded.append("#\(account.number) \(name(account)): excluded from rotation")
            } else if let score = headroom(account, now: now) {
                eligible.append((account, score))
            } else {
                excluded.append("#\(account.number) \(name(account)): quota missing, stale, or unavailable")
            }
        }
        func result(_ title: String, _ detail: String, target: Account? = nil) -> AccountReview {
            AccountReview(title: title, detail: detail, target: target, current: current, isRecommendation: true, excluded: excluded)
        }
        guard snapshot.accounts.count > 1 else {
            return result("No other account to compare", "Add another Claude login before looking for a better account.")
        }
        guard snapshot.accounts.filter({ $0.active }).count == 1, let current,
              snapshot.activeAccountNumber == nil || snapshot.activeAccountNumber == current.number,
              let currentScore = headroom(current, now: now) else {
            return result("Current quota is not comparable", "The current login needs recent 5-hour and weekly quota before we can prove another account is better. Refresh later or choose an account manually.")
        }
        guard let best = eligible.max(by: { $0.1 == $1.1 ? $0.0.number > $1.0.number : $0.1 < $1.1 }) else {
            return result("No eligible account to compare", "The other accounts are excluded or lack recent quota. Nothing has been switched.")
        }
        if best.1 > currentScore {
            let difference = String(format: "%.0f", best.1 - currentScore)
            return result("A better account is available", "\(name(best.0)) has \(String(format: "%.0f", best.1))% remaining in its tighter account-wide limit, versus \(String(format: "%.0f", currentScore))% for \(name(current)) — \(difference) percentage points more. This is the best eligible account among the recent measurements.", target: best.0)
        }
        if !excluded.isEmpty {
            return result("No proven improvement", "None of the comparable accounts has more headroom. Some accounts could not be compared, so we’ll stay on the current login.")
        }
        if currentScore <= 0 {
            return result("All compared accounts are at a limit", "Switching would not help right now. Nothing has been switched.")
        }
        return result("You’re already on a best account", "No other account has more headroom across the 5-hour and weekly limits. Ties keep your current login; nothing has been switched.")
    }
}

func checkEnvelope(_ data: Data) throws {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = object["error"] as? [String: Any] {
        throw DashboardError.message(redact(error["message"] as? String ?? "CSWAP could not complete the command."))
    }
}

func redact(_ value: String) -> String {
    let patterns = [#"sk-ant-[A-Za-z0-9_\-]+"#, #"(?i)(Bearer\s+)[A-Za-z0-9._\-]+"#, #"(?i)([\"']?(?:access_token|refresh_token|accessToken|refreshToken)[\"']?\s*[:=]\s*[\"']?)[^\s\"',}]+"#]
    var result = value
    for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
    result = result.replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    return String(result.prefix(3000))
}
