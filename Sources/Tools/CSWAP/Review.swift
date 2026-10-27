import SwiftUI

struct AccountReviewView: View {
    @EnvironmentObject var store: DashboardStore
    let review: AccountReview
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(review.isRecommendation ? "QUOTA CHECK" : "ACCOUNT SWITCH", systemImage: review.isRecommendation ? "sparkles" : "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.accent)
            Text(review.title).font(.system(size: compact ? 23 : 27, weight: .semibold, design: .rounded))
            Text(review.detail).font(.system(size: 14)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)

            if let target = review.target {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SWITCH TO · SLOT \(target.number)").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.mint)
                    HStack(spacing: 8) {
                        Circle().fill(store.tint(for: target)).frame(width: 9, height: 9)
                        Text(store.name(for: target)).font(.system(size: 19, weight: .semibold))
                    }
                    Text(target.email).font(.system(size: 13)).textSelection(.enabled)
                    Text(target.organization).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    HStack(spacing: 20) {
                        quota("5-hour", target.displayUsage?.fiveHour, account: target)
                        quota("Weekly", target.displayUsage?.sevenDay, account: target)
                    }
                    if target.disabled == true {
                        Text("Excluded from automatic rotation. This manual switch is still allowed.").foregroundStyle(.orange).font(.system(size: 12))
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.mint.opacity(0.065)).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.mint.opacity(0.22)))
                Text("Changes the global Claude login. Existing sessions may cache the old login; restart Claude Code for immediate use. Isolated cswap run sessions are unaffected.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if review.isRecommendation {
                Text("Uses the smaller remaining percentage across 5-hour and weekly limits, not an average. Only recent, comparable measurements count. Model-specific limits are not ranked; check them in the dashboard. CSWAP’s cache and backoff still apply.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if !review.excluded.isEmpty {
                    DisclosureGroup("Not compared (\(review.excluded.count))") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(review.excluded, id: \.self) { Text($0).font(.system(size: 12)) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            if store.demo { Text("Sample data only — switching is disabled.").font(.system(size: 12)).foregroundStyle(Palette.accent) }
            HStack(spacing: 10) {
                Button(review.target == nil ? "Close" : "Cancel") { store.accountReview = nil }
                    .buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                if review.target != nil {
                    Button("Confirm switch") { Task { await store.confirmReview() } }
                        .buttonStyle(ActionStyle(primary: true)).disabled(store.busy || store.demo)
                }
            }
        }.foregroundStyle(.white).tint(Palette.accent)
    }

    private func quota(_ title: String, _ window: QuotaWindow?, account: Account) -> some View {
        let stale = store.failedRefresh || account.outdated() || (window?.expired() ?? false)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(window?.remaining.map { String(format: "%.0f%% left", $0) } ?? "Not reported")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(stale ? Palette.muted : Palette.mint)
            if stale { Text("Last known").font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
}
