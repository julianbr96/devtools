import SwiftUI

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var localArchive = LocalArchive()
    @Published private(set) var localDataError: String?
    private let localFile: LocalDataFile?
    private var pendingHistory: [SwitchRecord] = []
    @Published var snapshot: AccountsResponse?
    @Published var busy = false
    @Published var connected = false
    @Published var error: String?
    @Published var notice: String?
    @Published var checkedAt: Date?
    @Published var failedRefresh = false
    @Published var version = "CSWAP CLI"
    @Published var path: String
    // Polling is opt-in for each launch; explicit refresh actions still work.
    @Published var autoRefresh = false {
        didSet { configurePolling() }
    }
    @Published var showHistory = false
    @Published var accountReview: AccountReview?
    @Published var reviewLocation: ReviewLocation = .dashboard
    private var pollingTask: Task<Void, Never>?
    private let command: CommandRunner
    private let pollingInterval: Duration
    let demo: Bool
    init(demo: Bool? = nil, localDataURL: URL? = nil, pollingInterval: Duration = .seconds(60), command: @escaping CommandRunner = { path, args, timeout in
        try await CLI.run(path: path, arguments: args, timeout: timeout)
    }) {
        self.demo = demo ?? CommandLine.arguments.contains("--demo")
        self.localFile = self.demo ? nil : localDataURL.map { LocalDataFile(url: $0) }
        self.command = command
        self.pollingInterval = pollingInterval
        path = UserDefaults.standard.string(forKey: "cliPath") ?? CLI.discover()
        do { localArchive = try localFile?.load() ?? LocalArchive() }
        catch { localDataError = "Could not load local names/history. Existing data was left untouched. " + redact(error.localizedDescription) }
    }
    deinit { pollingTask?.cancel() }
    private func configurePolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard autoRefresh, !demo else { return }
        let interval = pollingInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if self.connected && self.autoRefresh && self.accountReview == nil {
                    await self.refresh()
                }
            }
        }
    }
    var accounts: [Account] { snapshot?.accounts.sorted { $0.number < $1.number } ?? [] }
    var active: Account? { accounts.first { $0.active } }
    func style(for account: Account) -> AccountStyle { localArchive.styles[account.appearanceKey] ?? AccountStyle() }
    func name(for account: Account) -> String { style(for: account).nickname ?? account.title }
    func saveStyle(for account: Account, nickname: String, color: AccountColor) -> Bool {
        do {
            let style = try AccountStyle.make(nickname: nickname, color: color)
            return updateLocal { archive in
                if style == AccountStyle() { archive.styles.removeValue(forKey: account.appearanceKey) }
                else { archive.styles[account.appearanceKey] = style }
            }
        } catch { localDataError = error.localizedDescription; return false }
    }
    func clearHistory() -> Bool { updateLocal { $0.history = [] } }
    func retryLocalSave() { updateLocal { _ in } }
    @discardableResult
    private func updateLocal(_ mutation: (inout LocalArchive) -> Void) -> Bool {
        do {
            if let localFile {
                localArchive = try localFile.update { archive in
                    let existing = Set(archive.history.map(\.id))
                    archive.history += pendingHistory.filter { !existing.contains($0.id) }
                    archive.history.sort { $0.date > $1.date }
                    mutation(&archive)
                }
                pendingHistory = []
            }
            else { mutation(&localArchive) }
            localDataError = nil
            return true
        } catch {
            localDataError = "Local names/history could not be saved. " + redact(error.localizedDescription)
            return false
        }
    }
    private func historyAccount(_ account: Account) -> HistoryAccount {
        HistoryAccount(name: name(for: account), email: account.email, organization: account.organization,
                       slot: account.number, color: style(for: account).color)
    }
    private func recordSwitch(from: Account?, to: Account, method: SwitchMethod) {
        let record = SwitchRecord(id: UUID(), date: Date(), from: from.map(historyAccount), to: historyAccount(to), method: method)
        if !updateLocal({ $0.append(record) }) {
            // The CLI switch succeeded even if its local audit entry could not be persisted.
            localArchive.append(record)
            pendingHistory.insert(record, at: 0)
            pendingHistory = Array(pendingHistory.prefix(LocalArchive.historyLimit))
            localDataError = "The account switch succeeded, but its history entry was not saved to disk. It is visible only until you quit. " + (localDataError ?? "")
        }
    }
    private func recommendation(_ snapshot: AccountsResponse) -> AccountReview {
        BestAccountSelector.review(snapshot, name: { self.name(for: $0) })
    }
    func savePath(_ newPath: String) {
        path = newPath
        UserDefaults.standard.set(newPath, forKey: "cliPath")
        snapshot = nil; connected = false; checkedAt = nil; error = nil; notice = nil; accountReview = nil
    }
    private func loadSnapshot() async throws -> AccountsResponse {
        let result: AccountsResponse
        if demo {
            guard let url = Bundle.main.url(forResource: "cswap-demo", withExtension: "json") else {
                throw DashboardError.message("Demo fixture missing.")
            }
            result = try AccountsResponse.decodeDemo(Data(contentsOf: url))
            version = "CSWAP 0.26.0 · demo"
            if !connected, let target = result.accounts.first(where: { $0.active }),
               let source = result.accounts.first(where: { !$0.active && $0.disabled != true }) {
                localArchive.append(SwitchRecord(id: UUID(), date: Date().addingTimeInterval(-1800),
                    from: historyAccount(source), to: historyAccount(target), method: .manual))
            }
        } else {
            result = try AccountsResponse.decode(try await command(path, ["list", "--json"], 120).data)
        }
        snapshot = result
        checkedAt = Date(); connected = true; failedRefresh = false
        return result
    }
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil; accountReview = nil
        do {
            let firstConnection = !connected
            _ = try await loadSnapshot()
            if !demo {
                if firstConnection, let v = try? await command(path, ["--version"], 10) {
                    version = redact(String(decoding: v.data, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch { self.error = redact(error.localizedDescription); failedRefresh = true }
    }
    func requestSwitch(_ account: Account, location: ReviewLocation) {
        guard !busy else { return }
        reviewLocation = location
        accountReview = AccountReview(title: "Switch Claude account?", detail: "Review this account before changing the global Claude login.", target: account, current: active, isRecommendation: false, excluded: [])
    }
    func prepareBestAccount(location: ReviewLocation) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil; accountReview = nil
        defer { busy = false }
        do {
            let latest = try await loadSnapshot()
            reviewLocation = location
            accountReview = recommendation(latest)
        } catch { self.error = redact(error.localizedDescription); failedRefresh = true }
    }
    func confirmReview() async {
        guard !busy, !demo, let review = accountReview, let account = review.target else { return }
        accountReview = nil
        await switchAccount(account, recommendation: review.isRecommendation ? review : nil)
    }
    func switchAccount(_ account: Account, recommendation: AccountReview? = nil) async {
        guard !busy, !demo else { return }
        busy = true; error = nil; notice = nil
        var completedMessage: String?
        do {
            // Reject a stale UI selection if the user moved/replaced its slot in another terminal.
            let latest = try await loadSnapshot()
            guard let current = latest.accounts.first(where: { $0.number == account.number }), current.sameIdentity(as: account) else {
                throw DashboardError.message("That account slot changed in CSWAP. Review the refreshed list before switching.")
            }
            if let recommendation {
                let updated = self.recommendation(latest)
                guard let target = updated.target, target.sameIdentity(as: account),
                      let previousActive = recommendation.current, let updatedActive = updated.current,
                      previousActive.sameIdentity(as: updatedActive) else {
                    throw DashboardError.message("Accounts or quota changed since the recommendation. Nothing was switched. Use ‘Use best account’ again to review the latest choice.")
                }
            }
            let data = try await command(path, ["switch", String(account.number), "--json"], 180).data
            try checkEnvelope(data)
            let result = try JSONDecoder().decode(SwitchResponse.self, from: data)
            guard result.schemaVersion == 1 else { throw DashboardError.message("Unexpected CSWAP response. Refresh to check the active account.") }
            if result.switched {
                let activeAccounts = latest.accounts.filter { $0.active }
                recordSwitch(from: activeAccounts.count == 1 ? activeAccounts[0] : nil, to: current,
                             method: recommendation == nil ? .manual : .bestAccount)
            }
            completedMessage = ([result.message] + (result.warnings ?? []) + ["Restart Claude Code to apply the change immediately; existing sessions may cache the previous login."]).joined(separator: "\n")
        } catch { self.error = redact(error.localizedDescription); failedRefresh = true }
        busy = false
        if let completedMessage {
            notice = redact(completedMessage)
            await refresh()
        }
    }
    func addCurrent(alias: String) async -> Bool {
        guard !busy, !demo else { return false }
        busy = true; error = nil; notice = nil
        do {
            var args = ["add"]
            let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { args += ["--alias", name] }
            _ = try await command(path, args, 180)
            busy = false
            notice = "Current Claude login saved to CSWAP. Existing logins are updated in place."
            await refresh()
            return true
        } catch {
            self.error = redact(error.localizedDescription)
            busy = false
            return false
        }
    }
}
