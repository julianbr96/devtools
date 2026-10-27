import Foundation
import Darwin

enum CSWAPTests {
    @MainActor
    static func run() async throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) rethrows {
            guard try condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        func decodeWindow(_ text: String) throws -> QuotaWindow { try JSONDecoder().decode(QuotaWindow.self, from: Data(text.utf8)) }
        let settings = DashboardStore()
        check(!settings.autoRefresh, "automatic refresh defaults to off")
        settings.autoRefresh = true
        check(settings.autoRefresh, "automatic refresh remains opt-in")
        settings.autoRefresh = false
        check(!DashboardStore().autoRefresh, "a new launch resets automatic refresh to off")
        let zero = try decodeWindow(#"{"pct":100}"#)
        let full = try decodeWindow(#"{"pct":0}"#)
        let missing = try decodeWindow(#"{}"#)
        check(zero.remaining == 0, "100 used means zero remaining")
        check(full.remaining == 100, "zero used means 100 remaining")
        check(missing.remaining == nil, "missing quota is not full quota")
        let overflow = try decodeWindow(#"{"pct":110}"#)
        let negative = try decodeWindow(#"{"pct":-10}"#)
        check(overflow.remaining == 0 && negative.remaining == 100, "remaining percentages are clamped")
        let reset = try decodeWindow(#"{"pct":60,"resetsAt":"2020-01-01T00:00:00Z"}"#)
        check(reset.expired() && reset.resetLabel().contains("refresh needed"), "past reset never implies a replenished quota")
        let empty = try AccountsResponse.decode(Data(#"{"schemaVersion":1,"accounts":[],"activeAccountNumber":null}"#.utf8))
        check(empty.accounts.isEmpty, "empty account list")
        let api = try AccountsResponse.decode(Data(#"{"schemaVersion":1,"accounts":[{"number":1,"email":"api@example.test","active":true,"usageStatus":"api_key","usage":null}]}"#.utf8))
        check(api.accounts[0].displayUsage == nil && api.accounts[0].statusLabel.contains("no subscription"), "API keys have no subscription quota")
        let stale = try AccountsResponse.decode(Data(#"{"schemaVersion":1,"accounts":[{"number":1,"email":"old@example.test","active":false,"usageStatus":"unavailable","usage":null,"lastGoodUsage":{"fiveHour":{"pct":40}},"lastGoodFetchedAt":"2020-01-01T00:00:00Z"}]}"#.utf8))
        check(stale.accounts[0].isLastKnown && stale.accounts[0].outdated(), "last-good quota is explicitly stale")
        check(stale.accounts[0].displayUsage?.fiveHour?.remaining == 60, "last-good quota remains displayable")
        do {
            _ = try AccountsResponse.decode(Data(#"{"schemaVersion":2,"accounts":[]}"#.utf8)); fatalError("accepted unknown schema")
        } catch { check(true, "unknown schema rejected") }
        do {
            _ = try AccountsResponse.decode(Data(#"{"schemaVersion":1,"error":{"type":"ConfigError","message":"test failure"}}"#.utf8)); fatalError("accepted error envelope")
        } catch { check(error.localizedDescription.contains("test failure"), "structured CLI errors preserved") }
        let secret = "sk-ant-oat01-TEST_SECRET"
        check(!redact("token \(secret)").contains(secret), "tokens redacted from diagnostics")
        check(!redact(#"{"refreshToken":"private-refresh"}"#).contains("private-refresh"), "JSON refresh tokens redacted")
        check(!api.accounts[0].sameIdentity(as: stale.accounts[0]), "slot identity changes rejected")
        // Pure ranking and injected CLI workflow tests: never use a real login.
        let now = Date()
        let iso = ISO8601DateFormatter()
        func account(_ slot: Int, _ fiveUsed: Double, _ weekUsed: Double, active: Bool = false,
                     disabled: Bool = false, age: Double = 0) -> [String: Any] {
            ["number": slot, "email": "account\(slot)@example.test", "active": active,
             "disabled": disabled, "usageStatus": "ok",
             "usageFetchedAt": iso.string(from: now.addingTimeInterval(-age)),
             "usage": ["fiveHour": ["pct": fiveUsed, "resetsAt": iso.string(from: now.addingTimeInterval(3600))],
                       "sevenDay": ["pct": weekUsed, "resetsAt": iso.string(from: now.addingTimeInterval(86400))]]]
        }
        func payload(_ accounts: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "accounts": accounts,
                "activeAccountNumber": accounts.first(where: { $0["active"] as? Bool == true })?["number"] ?? NSNull()])
        }
        func review(_ accounts: [[String: Any]]) throws -> AccountReview {
            BestAccountSelector.review(try AccountsResponse.decode(payload(accounts)), now: now)
        }
        let a = account(1, 50, 60, active: true) // limiting headroom 40
        let b = account(2, 10, 20)              // limiting headroom 80
        let c = account(3, 0, 90)               // average misleading; headroom 10
        let standard = try payload([a, b, c])
        try check(try review([a, b, c]).target?.number == 2, "best account uses tighter quota, never an average")
        try check(try review([a, account(2, 60, 0)]).target == nil, "tie retains the current account")
        try check(try review([a, account(3, 0, 20), b]).target?.number == 2, "equal alternatives choose the earliest slot")
        try check(try review([a, account(2, 0, 0, disabled: true), c]).target == nil, "disabled alternatives are excluded")
        try check(try review([a, account(2, 0, 0, age: 301)]).target == nil, "stale quota never wins")
        try check(try review([a, account(2, 0, 0, age: -120)]).target == nil, "future measurements are not trusted")
        var partial = b
        partial["usage"] = ["fiveHour": ["pct": 0]]
        try check(try review([a, partial]).target == nil, "both account-wide windows are required")
        var expiredAccount = b
        expiredAccount["usage"] = ["fiveHour": ["pct": 0, "resetsAt": "2020-01-01T00:00:00Z"], "sevenDay": ["pct": 0]]
        try check(try review([a, expiredAccount]).target == nil, "a passed reset requires fresh quota")
        var apiAccount = b
        apiAccount["usageStatus"] = "api_key"
        try check(try review([a, apiAccount]).target == nil, "API-key accounts are not ranked")
        try check(try review([account(1, 0, 0, active: true, age: 301), b]).target == nil, "unknown current quota cannot justify a switch")
        try check(try review([account(1, 100, 0, active: true), account(2, 100, 0)]).title.contains("at a limit"), "exhausted accounts produce a no-switch result")
        try check(try review([a, c, apiAccount]).title == "No proven improvement", "incomplete comparison never claims global best")
        try check(try review([a]).title == "No other account to compare", "single account has no alternate")
        try check(try review([]).target == nil, "empty list has no recommendation")
        var secondActive = b
        secondActive["active"] = true
        try check(try review([a, secondActive]).target == nil, "ambiguous active state blocks recommendations")
        var invalid = b
        invalid["usage"] = ["fiveHour": ["pct": -1], "sevenDay": ["pct": 0]]
        try check(try review([a, invalid]).target == nil, "negative used percentages cannot win")
        var scopedLimit = b
        var scopedUsage = b["usage"] as! [String: Any]
        scopedUsage["scoped"] = [["name": "Model", "pct": 100]]
        scopedLimit["usage"] = scopedUsage
        try check(try review([a, scopedLimit]).target?.number == 2, "ranking is explicitly account-wide, not per-model")

        let future = now.addingTimeInterval(30 * 86400)
        let shiftedDemo = try AccountsResponse.decodeDemo(standard, now: future)
        check(BestAccountSelector.review(shiftedDemo, now: future).target?.number == 2, "demo-only dates remain useful after the fixture creation date")
        let unshiftedLive = try AccountsResponse.decode(standard)
        check(BestAccountSelector.review(unshiftedLive, now: future).target == nil, "live quota timestamps are never rewritten")
        let oldDemo = try AccountsResponse.decodeDemo(payload([a, account(2, 0, 0, age: 600)]), now: future)
        check(oldDemo.accounts[1].outdated(now: future), "demo shifting preserves intentionally stale measurement ages")

        let fake = FixtureCLI([standard])
        let store = DashboardStore(demo: false, command: { _, args, _ in try await fake.run(args) })
        let initialCalls = await fake.calls
        check(initialCalls.isEmpty && !store.connected, "creating the shared store never invokes CSWAP")
        await store.prepareBestAccount(location: .menuBar)
        let preparedCalls = await fake.calls
        check(preparedCalls == [["list", "--json"]] && store.accountReview?.target?.number == 2,
              "best-account preparation only reads a list and presents the candidate")
        check(store.reviewLocation == .menuBar, "menu confirmation uses the shared review state")
        store.accountReview = nil
        let cancelledCalls = await fake.calls
        check(cancelledCalls.count == 1, "cancelling a review never switches")
        await store.prepareBestAccount(location: .dashboard)
        await store.confirmReview()
        let confirmedCalls = await fake.calls
        check(confirmedCalls == [["list", "--json"], ["list", "--json"], ["list", "--json"], ["switch", "2", "--json"], ["list", "--json"]],
              "confirmation rechecks and switches only the approved numeric slot")
        check(store.notice != nil && store.accountReview == nil && !store.busy, "confirmed workflow refreshes and releases shared busy state")

        func blockedConfirmation(_ changed: Data, name: String) async throws {
            let fake = FixtureCLI([standard, changed])
            let store = DashboardStore(demo: false, command: { _, args, _ in try await fake.run(args) })
            await store.prepareBestAccount(location: .dashboard)
            await store.confirmReview()
            let calls = await fake.calls
            check(calls == [["list", "--json"], ["list", "--json"]] && store.error != nil && store.localArchive.history.isEmpty, name)
        }
        var replaced = b
        replaced["email"] = "replacement@example.test"
        try await blockedConfirmation(payload([a, replaced, c]), name: "slot identity change aborts before any write")
        try await blockedConfirmation(payload([a, b, account(3, 0, 0)]), name: "a different best target requires a new confirmation")
        try await blockedConfirmation(payload([a, account(2, 100, 100), c]), name: "a depleted recommendation never switches")
        try await blockedConfirmation(payload([a, account(2, 0, 0, disabled: true), c]), name: "a newly disabled target never switches")
        try await blockedConfirmation(payload([a, account(2, 0, 0, age: 301), c]), name: "stale confirmation data never switches")
        try await blockedConfirmation(payload([account(1, 50, 60), b, account(3, 0, 90, active: true)]),
                                      name: "an externally changed active account requires new review")
        try await blockedConfirmation(Data(#"{"schemaVersion":2,"accounts":[]}"#.utf8), name: "unsupported confirmation schema fails closed")

        let manualFake = FixtureCLI([standard])
        let manualStore = DashboardStore(demo: false, command: { _, args, _ in try await manualFake.run(args) })
        manualStore.snapshot = try AccountsResponse.decode(standard)
        manualStore.requestSwitch(manualStore.accounts[1], location: .menuBar)
        let manualCalls = await manualFake.calls
        check(manualCalls.isEmpty && manualStore.accountReview?.target?.number == 2, "quick switch only opens a review")

        let serializedFake = FixtureCLI([standard], delay: .milliseconds(80))
        let serialized = DashboardStore(demo: false, command: { _, args, _ in try await serializedFake.run(args) })
        let first = Task { await serialized.prepareBestAccount(location: .menuBar) }
        try await Task.sleep(for: .milliseconds(20))
        await serialized.prepareBestAccount(location: .dashboard)
        await first.value
        let serializedCalls = await serializedFake.calls
        check(serializedCalls.count == 1, "simultaneous dashboard and menu requests share a single busy lock")

        let pollFake = FixtureCLI([standard])
        let polling = DashboardStore(demo: false, pollingInterval: .milliseconds(40), command: { _, args, _ in try await pollFake.run(args) })
        polling.connected = true
        try await Task.sleep(for: .milliseconds(110))
        let offCalls = await pollFake.calls
        check(offCalls.isEmpty, "no background quota calls with default-off polling")
        polling.autoRefresh = true
        try await Task.sleep(for: .milliseconds(110))
        polling.autoRefresh = false
        let onCount = await pollFake.calls.count
        check(onCount > 0, "explicit opt-in enables the store-owned poller")
        try await Task.sleep(for: .milliseconds(110))
        let stoppedCount = await pollFake.calls.count
        check(stoppedCount == onCount, "turning polling off cancels future refreshes")
        polling.accountReview = try review([a, b])
        polling.autoRefresh = true
        try await Task.sleep(for: .milliseconds(110))
        polling.autoRefresh = false
        let reviewCount = await pollFake.calls.count
        check(reviewCount == stoppedCount, "polling pauses while a confirmation is pending")

        // App-local metadata must never touch live CLI aliases or credential storage.
        let personal = try AccountsResponse.decode(standard).accounts[0]
        let alternate = try AccountsResponse.decode(standard).accounts[1]
        let custom = try AccountStyle.make(nickname: "  Work  ", color: .blue)
        check(custom.nickname == "Work" && custom.color == .blue, "local nicknames are trimmed")
        try check(try AccountStyle.make(nickname: "  ", color: .peach) == AccountStyle(), "blank/default appearance restores CLI naming")
        do { _ = try AccountStyle.make(nickname: String(repeating: "x", count: 41), color: .blue); fatalError("accepted long name") }
        catch { check(true, "overlong local names are rejected") }
        do { _ = try AccountStyle.make(nickname: "first\nsecond", color: .blue); fatalError("accepted multiline name") }
        catch { check(true, "control characters in local names are rejected") }
        var moved = a; moved["number"] = 9; moved["alias"] = "Different CLI alias"
        let movedAccount = try AccountsResponse.decode(payload([moved])).accounts[0]
        check(personal.appearanceKey == movedAccount.appearanceKey, "appearance follows identity across slot and alias changes")
        var otherOrg = a; otherOrg["organizationUuid"] = "different-org"
        let otherOrgAccount = try AccountsResponse.decode(payload([otherOrg])).accounts[0]
        check(personal.appearanceKey != otherOrgAccount.appearanceKey, "different organizations keep separate appearances")
        check(manualStore.saveStyle(for: alternate, nickname: "Team", color: .purple), "save an app-local name and color")
        check(manualStore.name(for: alternate) == "Team" && manualStore.style(for: alternate).color == .purple, "personalization is applied through the shared store")
        let afterStyleCalls = await manualFake.calls
        check(afterStyleCalls.isEmpty, "appearance edits never invoke CSWAP")
        await manualStore.prepareBestAccount(location: .menuBar)
        check(manualStore.accountReview?.detail.contains("Team has") == true, "best-account explanation uses the local display name")
        await manualStore.confirmReview()
        check(manualStore.localArchive.history.count == 1 && manualStore.localArchive.history[0].method == .bestAccount,
              "confirmed best-account switch adds one history record")
        check(manualStore.localArchive.history[0].to.name == "Team" && manualStore.localArchive.history[0].to.slot == 2 &&
              manualStore.localArchive.history[0].from?.slot == 1, "history captures approved identity and display name at switch time")
        _ = manualStore.saveStyle(for: alternate, nickname: "New name", color: .pink)
        check(manualStore.localArchive.history[0].to.name == "Team", "later renaming does not rewrite historical labels")
        check(manualStore.clearHistory() && manualStore.localArchive.history.isEmpty && manualStore.name(for: alternate) == "New name",
              "clearing history preserves appearance and does not switch accounts")

        let metadataDir = FileManager.default.temporaryDirectory.appendingPathComponent("cswap-metadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: metadataDir) }
        let metadataURL = metadataDir.appendingPathComponent("settings/local-data.json")
        let persistentFake = FixtureCLI([standard])
        let persistent = DashboardStore(demo: false, localDataURL: metadataURL, command: { _, args, _ in try await persistentFake.run(args) })
        check(!FileManager.default.fileExists(atPath: metadataURL.path), "loading missing metadata creates no file")
        check(persistent.saveStyle(for: personal, nickname: "Personal", color: .mint), "local appearance persists to the injected file")
        let reloaded = DashboardStore(demo: false, localDataURL: metadataURL)
        check(reloaded.name(for: movedAccount) == "Personal" && reloaded.style(for: movedAccount).color == .mint, "appearance survives restart and slot movement")
        let fileMode = try FileManager.default.attributesOfItem(atPath: metadataURL.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: metadataURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        check(fileMode?.intValue == 0o600 && directoryMode?.intValue == 0o700, "local metadata file and new folder are private")
        _ = reloaded.saveStyle(for: alternate, nickname: "Office", color: .blue)
        _ = persistent.saveStyle(for: personal, nickname: "Home", color: .gold)
        let merged = try LocalDataFile(url: metadataURL).load()
        check(merged.styles[alternate.appearanceKey]?.nickname == "Office" && merged.styles[personal.appearanceKey]?.nickname == "Home",
              "separate instances merge changes under a file lock")
        await persistent.switchAccount(alternate)
        let historyReload = DashboardStore(demo: false, localDataURL: metadataURL)
        check(historyReload.localArchive.history.count == 1 && historyReload.localArchive.history[0].method == .manual,
              "successful manual switches persist across restarts")
        let savedText = try String(contentsOf: metadataURL, encoding: .utf8)
        check(!savedText.contains("usage") && !savedText.contains("accessToken") && !savedText.contains("refreshToken") && !savedText.contains("message"),
              "archive contains no quota payloads, tokens, or raw CLI messages")
        let demoBefore = try Data(contentsOf: metadataURL)
        let isolatedDemo = DashboardStore(demo: true, localDataURL: metadataURL)
        _ = isolatedDemo.saveStyle(for: personal, nickname: "Demo only", color: .pink)
        try check(try Data(contentsOf: metadataURL) == demoBefore && isolatedDemo.localArchive.history.isEmpty,
                  "demo ignores real metadata and never writes it")

        let noOpCLI = FixtureCLI([standard], switched: false)
        let noOpStore = DashboardStore(demo: false, command: { _, args, _ in try await noOpCLI.run(args) })
        await noOpStore.switchAccount(alternate)
        check(noOpStore.localArchive.history.isEmpty, "switched=false does not create a history event")
        let failureCLI = FixtureCLI([standard], failSwitch: true)
        let failureStore = DashboardStore(demo: false, command: { _, args, _ in try await failureCLI.run(args) })
        await failureStore.switchAccount(alternate)
        check(failureStore.localArchive.history.isEmpty && failureStore.error != nil, "failed switches do not create history")
        let refreshFailureCLI = FixtureCLI([standard, Data("invalid json".utf8)])
        let refreshFailureStore = DashboardStore(demo: false, command: { _, args, _ in try await refreshFailureCLI.run(args) })
        await refreshFailureStore.switchAccount(alternate)
        check(refreshFailureStore.localArchive.history.count == 1 && refreshFailureStore.failedRefresh,
              "confirmed switch remains logged when the subsequent quota refresh fails")

        let corruptURL = metadataDir.appendingPathComponent("corrupt/local-data.json")
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not-json-DO-NOT-OVERWRITE".utf8)
        try corrupt.write(to: corruptURL)
        let corruptCLI = FixtureCLI([standard])
        let corruptStore = DashboardStore(demo: false, localDataURL: corruptURL, command: { _, args, _ in try await corruptCLI.run(args) })
        check(corruptStore.localDataError != nil, "corrupt metadata is surfaced without crashing")
        check(!corruptStore.saveStyle(for: personal, nickname: "Attempt", color: .blue), "corrupt metadata cannot be silently overwritten")
        await corruptStore.switchAccount(alternate)
        try check(try Data(contentsOf: corruptURL) == corrupt, "failed persistence preserves the existing file")
        check(corruptStore.localArchive.history.count == 1 && corruptStore.localDataError?.contains("switch succeeded") == true &&
              corruptStore.error == nil, "history-save failure never misreports a successful CLI switch")
        try JSONEncoder().encode(LocalArchive()).write(to: corruptURL)
        corruptStore.retryLocalSave()
        try check(corruptStore.localDataError == nil && (try LocalDataFile(url: corruptURL).load()).history.count == 1,
              "retry persists pending history after storage is repaired")
        corruptStore.retryLocalSave()
        try check(try LocalDataFile(url: corruptURL).load().history.count == 1, "retries do not duplicate history")

        var newer = LocalArchive(); newer.schemaVersion = 9
        try JSONEncoder().encode(newer).write(to: corruptURL)
        check(!corruptStore.saveStyle(for: personal, nickname: "Do not overwrite", color: .blue), "unknown metadata schemas fail closed")
        let futureArchive = try JSONDecoder().decode(LocalArchive.self, from: Data(contentsOf: corruptURL))
        check(futureArchive.schemaVersion == 9, "newer metadata stays intact")

        let record = historyReload.localArchive.history[0]
        var bounded = LocalArchive()
        for number in 0..<120 {
            bounded.append(SwitchRecord(id: UUID(), date: now.addingTimeInterval(Double(number)), from: record.from, to: record.to, method: .manual))
        }
        check(bounded.history.count == 100 && bounded.history.first?.date == now.addingTimeInterval(119),
              "history keeps the latest 100 records, newest first")
        let lockPath = metadataURL.deletingLastPathComponent().appendingPathComponent("local-data.lock").path
        let lockedFD = Darwin.open(lockPath, O_RDWR)
        guard lockedFD >= 0 && flock(lockedFD, LOCK_EX | LOCK_NB) == 0 else { fatalError("test lock unavailable") }
        let lockStart = Date()
        check(!persistent.saveStyle(for: personal, nickname: "Locked", color: .blue) && Date().timeIntervalSince(lockStart) < 1,
              "a busy metadata lock fails promptly without freezing the UI")
        flock(lockedFD, LOCK_UN); Darwin.close(lockedFD)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("fake-cswap")
        func writeStub(_ contents: String) throws {
            try ("#!/bin/sh\n" + contents).write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        }
        try writeStub("printf '%s\\n' \"$1\" \"$2\"\n")
        let arguments = try await CLI.run(path: stub.path, arguments: ["switch", "a; touch /DO_NOT_CREATE"])
        check(String(decoding: arguments.data, as: UTF8.self).contains("a; touch /DO_NOT_CREATE"), "arguments passed literally, never shell-evaluated")
        try writeStub("printf 'failure' >&2\nexit 7\n")
        do {
            _ = try await CLI.run(path: stub.path, arguments: []); fatalError("accepted CLI failure")
        } catch { check(error.localizedDescription == "failure", "nonzero process exit surfaced") }
        try writeStub("exec /bin/sleep 20\n")
        let start = Date()
        do {
            _ = try await CLI.run(path: stub.path, arguments: [], timeout: 0.15); fatalError("no timeout")
        } catch { check(Date().timeIntervalSince(start) < 6 && error.localizedDescription.contains("too long"), "hung subprocess terminated") }
        try writeStub("/bin/sleep 6 &\nexit 0\n")
        let pipeStart = Date()
        do {
            _ = try await CLI.run(path: stub.path, arguments: []); fatalError("accepted inherited open pipe")
        } catch { check(Date().timeIntervalSince(pipeStart) < 5 && error.localizedDescription.contains("output stream"), "inherited output pipes cannot hang the UI") }
        print("\(count) tests passed. No real CSWAP calls or credentials used.")
    }
}

actor FixtureCLI {
    private var snapshots: [Data]
    private let delay: Duration
    private let switched: Bool
    private let failSwitch: Bool
    private(set) var calls: [[String]] = []
    init(_ snapshots: [Data], delay: Duration = .zero, switched: Bool = true, failSwitch: Bool = false) {
        self.snapshots = snapshots
        self.delay = delay
        self.switched = switched
        self.failSwitch = failSwitch
    }
    func run(_ args: [String]) async throws -> CommandOutput {
        calls.append(args)
        if delay > .zero { try await Task.sleep(for: delay) }
        let data: Data
        if args == ["list", "--json"] {
            data = snapshots[0]
            if snapshots.count > 1 { snapshots.removeFirst() }
        } else if args.first == "switch" {
            if failSwitch { throw DashboardError.message("Fixture switch failed") }
            data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "switched": switched, "message": "Fixture switch confirmed"])
        } else if args == ["--version"] {
            data = Data("Fixture CLI".utf8)
        } else {
            throw DashboardError.message("Unexpected test command")
        }
        return CommandOutput(data: data, stderr: "")
    }
}
