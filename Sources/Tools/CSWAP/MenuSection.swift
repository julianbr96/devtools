import SwiftUI

struct CSWAPMenuSection: View {
    @EnvironmentObject var store: DashboardStore
    let showDashboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Tag(text: store.demo ? "Sample data" : store.autoRefresh ? "Auto-refresh on" : "Manual refresh")
                Spacer()
                Button("History") { showDashboard(); store.showHistory = true }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
                    .disabled(store.accountReview != nil)
            }
            if let review = store.accountReview, store.reviewLocation == .menuBar {
                AccountReviewView(review: review, compact: true)
            } else {
                LocalDataWarning()
                if let error = store.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
                if let notice = store.notice {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(notice).font(.system(size: 12)).foregroundStyle(Palette.mint)
                        Button("Dismiss") { store.notice = nil }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
                if store.connected { connectedContent }
                else {
                    Text("Your accounts, one click away.").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Open the dashboard to connect your existing CSWAP installation. Nothing is checked until you connect.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Button("Open dashboard to connect", action: showDashboard).buttonStyle(ActionStyle(primary: true))
                }
            }
        }
    }

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let active = store.active {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.failedRefresh ? "LAST SEEN ACTIVE" : "ACTIVE ACCOUNT")
                        .font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.mint)
                    HStack(spacing: 8) {
                        Circle().fill(store.tint(for: active)).frame(width: 9, height: 9)
                        Text(store.name(for: active)).font(.system(size: 23, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    Text(active.email).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).help(active.email)
                    HStack(spacing: 12) {
                        miniQuota("5-hour", window: active.displayUsage?.fiveHour, account: active)
                        miniQuota("Weekly", window: active.displayUsage?.sevenDay, account: active)
                    }
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text(store.accounts.isEmpty ? "No saved accounts yet." : "Current login is not a saved account.")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text("Checked \(Dates.age(store.checkedAt).lowercased()). Opening this panel never checks quota.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise").fixedSize() }
                    .buttonStyle(ActionStyle())
                Button { Task { await store.prepareBestAccount(location: .menuBar) } } label: { Label("Use best account", systemImage: "sparkles").fixedSize() }
                    .buttonStyle(ActionStyle(primary: true))
            }.disabled(store.busy || store.accountReview != nil)
            if store.accountReview != nil {
                Text("Finish the account review in the dashboard first.").font(.system(size: 12)).foregroundStyle(Palette.accent)
            }
            Text("QUICK SWITCH").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
            ForEach(store.accounts) { account in
                Button { store.requestSwitch(account, location: .menuBar) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: account.active ? "checkmark.circle.fill" : "person.crop.circle")
                            .foregroundStyle(store.tint(for: account))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.name(for: account)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text("#\(account.number) · \(account.organization)").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer()
                        Text(account.active ? "In use" : "Review…").font(.system(size: 12)).foregroundStyle(account.active ? Palette.mint : Palette.accent)
                    }.padding(12).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(account.active || store.busy || store.demo || store.failedRefresh || store.accountReview != nil)
                    .help(account.email)
            }
            Text("Switches always ask for confirmation. Close the dashboard to keep menu-bar access; Quit stops DevTools.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private func miniQuota(_ label: String, window: QuotaWindow?, account: Account) -> some View {
        let old = store.failedRefresh || account.outdated() || (window?.expired() ?? false)
        return VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(window?.remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
            Text(old ? "last known remaining" : "remaining").font(.system(size: 10)).foregroundStyle(old ? .orange : Palette.muted)
            Text(window?.resetLabel() ?? "Not reported").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
