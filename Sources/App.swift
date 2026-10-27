import SwiftUI
import AppKit

enum Palette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.083)
    static let sidebar = Color(red: 0.074, green: 0.087, blue: 0.106)
    static let surface = Color(red: 0.091, green: 0.106, blue: 0.125)
    static let border = Color.white.opacity(0.09)
    static let accent = Color(red: 0.94, green: 0.62, blue: 0.47)
    static let mint = Color(red: 0.48, green: 0.84, blue: 0.70)
    static let muted = Color(red: 0.62, green: 0.66, blue: 0.72)
    static func quota(_ remaining: Double?) -> Color {
        guard let remaining else { return muted }
        return remaining <= 10 ? .red.opacity(0.85) : remaining <= 30 ? .orange : mint
    }
}

struct ActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(primary ? Palette.background : Color.white.opacity(0.9))
            .background(primary ? Palette.accent : Color.white.opacity(configuration.isPressed ? 0.13 : 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? Color.clear : Palette.border))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
    }
}

struct Tag: View {
    let text: String
    var color: Color = Palette.muted
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

@main
struct CSWAPDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = DashboardStore(localDataURL: LocalDataFile.defaultURL)
    var body: some Scene {
        Window("CSWAP", id: "dashboard") {
            DashboardView().environmentObject(store)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1020, minHeight: 720)
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appTermination) {
                Button("Quit CSWAP") { NSApp.terminate(nil) }
                    .keyboardShortcut("q").disabled(store.busy)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh accounts") { Task { await store.refresh() } }
                    .keyboardShortcut("r").disabled(store.busy || !store.connected || store.accountReview != nil)
            }
        }
        MenuBarExtra("CSWAP", systemImage: "arrow.left.arrow.right") {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                MenuBarPanel().environmentObject(store).preferredColorScheme(.dark)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Keep dashboard windows without adding a Dock / Command-Tab entry.
        // LSUIElement also applies this policy before startup to avoid a Dock flash.
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct DashboardView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var showSettings = false
    @State private var showAdd = false
    @State private var styleTarget: Account?
    @State private var now = Date()
    let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if store.demo { banner("Demo preview · sample accounts, no real CLI calls. Relaunch without --demo to connect.", icon: "theatermasks", color: Palette.accent) }
                        LocalDataWarning()
                        if let error = store.error {
                            banner(error, icon: "exclamationmark.triangle", color: .orange)
                        }
                        if let notice = store.notice {
                            HStack(alignment: .top) {
                                banner(notice, icon: "checkmark.circle", color: Palette.mint)
                                Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).padding(.top, 15).accessibilityLabel("Dismiss confirmation")
                            }
                        }
                        if store.connected {
                            overview
                            accountList
                            ForEach(store.snapshot?.warnings ?? [], id: \.self) { banner($0, icon: "exclamationmark.triangle", color: .orange) }
                            footer
                        } else { connectionCard }
                    }
                    .padding(30)
                }
            }
            .background(Palette.background)
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(store) }
        .sheet(isPresented: $store.showHistory) { SwitchHistorySheet().environmentObject(store) }
        .sheet(item: $styleTarget) { AccountStyleSheet(account: $0).environmentObject(store) }
        .sheet(isPresented: $showAdd) { AddAccountSheet().environmentObject(store) }
        .sheet(item: Binding(get: {
            store.reviewLocation == .dashboard ? store.accountReview : nil
        }, set: { if $0 == nil && store.reviewLocation == .dashboard { store.accountReview = nil } })) { review in
            ScrollView { AccountReviewView(review: review).padding(28) }
                .frame(width: 580, height: review.target == nil ? 430 : 640)
                .background(Palette.background)
                .environmentObject(store)
        }
        .onReceive(clock) { now = $0 }
        .task {
            if store.demo && !store.connected { await store.refresh() }
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.background).frame(width: 39, height: 39)
                    .background(Palette.accent).clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("CSWAP").font(.system(size: 19, weight: .bold, design: .rounded)).tracking(1.5)
                    Text("ACCOUNT MANAGER").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(Palette.muted)
                }
            }.padding(.bottom, 42)
            Text("WORKSPACE").font(.system(size: 12, weight: .medium)).tracking(1.5).foregroundStyle(Palette.muted).padding(.leading, 11).padding(.bottom, 12)
            HStack {
                Image(systemName: "square.stack.3d.up").frame(width: 20)
                Text("Accounts").font(.system(size: 14, weight: .semibold))
                Spacer()
                if store.connected { Text("\(store.accounts.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted) }
            }.padding(12).background(Color.white.opacity(0.065)).clipShape(RoundedRectangle(cornerRadius: 9))
            Button { store.showHistory = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").frame(width: 20)
                    Text("Switch history")
                    Spacer()
                    Text("\(store.localArchive.history.count)").font(.system(size: 12))
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted)
                .disabled(store.accountReview != nil).padding(.top, 6)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("Local to this Mac", systemImage: "desktopcomputer").font(.system(size: 14, weight: .medium))
                Text("Credentials stay with CSWAP.\nNo cloud dashboard.").font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(3)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
            Button { showSettings = true } label: {
                HStack(spacing: 10) { Image(systemName: "gearshape"); Text("Settings"); Spacer() }.padding(12)
            }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Palette.muted).disabled(store.busy).padding(.top, 17)
        }
        .padding(.horizontal, 19).padding(.top, 58).padding(.bottom, 20).frame(width: 224)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1) }
    }
    var header: some View {
        HStack {
            Label("Claude Code", systemImage: "terminal").foregroundStyle(Palette.muted).font(.system(size: 14, weight: .medium))
            Text("/").foregroundStyle(Palette.muted.opacity(0.5)).padding(.horizontal, 7)
            Text("Accounts").font(.system(size: 14, weight: .medium))
            Spacer()
            if store.busy { ProgressView().controlSize(.small); Text("Working…").font(.system(size: 13)).foregroundStyle(Palette.muted) }
            else if store.connected {
                Text("Checked \(Dates.age(store.checkedAt, now: now).lowercased())").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(ActionStyle()).disabled(store.busy || !store.connected)
                .help("Read CSWAP again. Its own cache and backoff still apply. ⌘R")
        }.padding(.horizontal, 30).frame(height: 78)
    }
    var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your accounts").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("See your limits. Choose your next login.").font(.system(size: 15)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }.buttonStyle(ActionStyle(primary: true)).disabled(store.busy || store.demo)
            }
            HStack(spacing: 10) {
                Button { Task { await store.prepareBestAccount(location: .dashboard) } } label: {
                    Label("Use best account", systemImage: "sparkles")
                }.buttonStyle(ActionStyle()).disabled(store.busy || store.accountReview != nil)
                Text("Check quota, then review before switching.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            if let account = store.active {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(store.failedRefresh ? "LAST SEEN ACTIVE" : "ACTIVE ACCOUNT", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(Palette.mint)
                        HStack(spacing: 9) {
                            Circle().fill(store.tint(for: account)).frame(width: 10, height: 10)
                            Text(store.name(for: account)).font(.system(size: 25, weight: .semibold, design: .rounded)).lineLimit(1)
                        }
                        Text(account.email).font(.system(size: 13)).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(1).help(account.email)
                        HStack { Tag(text: "Slot \(account.number)"); Tag(text: account.organization) }.lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading).frame(height: 198)
                        .background(LinearGradient(colors: [Palette.mint.opacity(0.095), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.mint.opacity(0.24)))
                    summaryQuota("5-hour window", window: account.displayUsage?.fiveHour, account: account)
                    summaryQuota("Weekly window", window: account.displayUsage?.sevenDay, account: account)
                }
            } else if !store.accounts.isEmpty {
                banner("No saved account matches the current Claude login. Switch to a saved account, or add the current login.", icon: "person.crop.circle.badge.questionmark", color: Palette.accent)
            }
        }
    }
    func summaryQuota(_ title: String, window: QuotaWindow?, account: Account) -> some View {
        let remaining = window?.remaining
        let old = store.failedRefresh || account.outdated(now: now) || (window?.expired(now: now) ?? false)
        return VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.system(size: 12, weight: .medium)).tracking(1).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(remaining.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit()
                if remaining != nil { Text("%").font(.system(size: 23)).foregroundStyle(Palette.muted) }
                Spacer(minLength: 0)
            }
            Text(remaining == nil ? "not reported" : old ? "last known remaining" : "remaining")
                .font(.system(size: 13)).foregroundStyle(old ? .orange : Palette.muted)
            quotaBar(remaining, muted: old)
            Text(window?.resetLabel(now: now) ?? "Reset time unavailable").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).frame(height: 198)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.border))
    }
    var accountList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SAVED ACCOUNTS").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted)
                Tag(text: "\(store.accounts.count)")
                Spacer()
                Text("Quota bars show remaining capacity").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if store.accounts.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 32)).foregroundStyle(Palette.accent)
                    Text("Your first account starts here").font(.system(size: 19, weight: .semibold))
                    Text("Log in to Claude Code, then save that login to CSWAP.").font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Button("Add current login") { showAdd = true }.buttonStyle(ActionStyle(primary: true)).disabled(store.demo || store.busy)
                }.frame(maxWidth: .infinity).padding(38).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
            } else {
                VStack(spacing: 0) {
                    ForEach(store.accounts) { account in
                        accountRow(account)
                        if account.id != store.accounts.last?.id { Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 20) }
                    }
                }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.border))
            }
        }
    }
    func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 18) {
                HStack(spacing: 12) {
                    Text(String(store.name(for: account).prefix(2)).uppercased()).font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(store.tint(for: account))
                        .frame(width: 42, height: 44).background(store.tint(for: account).opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Text(store.name(for: account)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            if account.active { Tag(text: store.failedRefresh ? "Last active" : "Active", color: Palette.mint) }
                            Button { styleTarget = account } label: { Image(systemName: "pencil").font(.system(size: 12)) }
                                .buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(store.busy || store.accountReview != nil)
                                .help("Customize name and color").accessibilityLabel("Customize \(store.name(for: account))")
                        }
                        Text(account.email).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1).help(account.email).textSelection(.enabled)
                        Text("#\(account.number) · \(account.organization)").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                compactQuota("5-hour", window: account.displayUsage?.fiveHour, account: account)
                compactQuota("7-day", window: account.displayUsage?.sevenDay, account: account)
                Button { store.requestSwitch(account, location: .dashboard) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: account.active ? "checkmark" : "arrow.left.arrow.right").font(.system(size: 12)).frame(width: 15)
                        Text(account.active ? "In use" : "Switch").fixedSize()
                    }.frame(width: 75)
                }.buttonStyle(ActionStyle()).disabled(account.active || store.busy || store.demo || store.failedRefresh)
            }
            HStack(spacing: 10) {
                if account.usageStatus != "ok" { Tag(text: account.statusLabel, color: account.usageStatus == "api_key" ? Palette.muted : .orange) }
                if account.disabled == true { Tag(text: "Out of auto-rotation") }
                if account.displayUsage != nil {
                    Text("\(account.isLastKnown || store.failedRefresh ? "Last known" : "Measured") · \(Dates.age(account.measuredAt, now: now).lowercased())")
                        .font(.system(size: 12)).foregroundStyle(account.outdated(now: now) || store.failedRefresh ? .orange : Palette.muted)
                }
                Spacer(minLength: 0)
            }
            if let scoped = account.displayUsage?.scoped, !scoped.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(scoped.enumerated()), id: \.offset) { _, window in
                        Text("\(window.name ?? "Model") weekly · \(window.remaining.map { String(format: "%.0f%% remaining", $0) } ?? "unavailable") · \(window.resetLabel(now: now))")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
            }
        }.padding(20)
    }
    func compactQuota(_ title: String, window: QuotaWindow?, account: Account) -> some View {
        let remaining = window?.remaining
        let old = store.failedRefresh || account.outdated(now: now) || (window?.expired(now: now) ?? false)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).foregroundStyle(Palette.muted)
                Spacer(minLength: 4)
                Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit().fontWeight(.semibold)
            }.font(.system(size: 13))
            quotaBar(remaining, muted: old)
            Text(window?.resetLabel(now: now) ?? "Not reported").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
        }.frame(width: 140)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(remaining.map { String(format: "%.0f percent remaining", $0) } ?? "unavailable")\(old && remaining != nil ? ", last known data" : ""). \(window?.resetLabel(now: now) ?? "")")
    }
    func quotaBar(_ remaining: Double?, muted: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.065))
                if let remaining {
                    Capsule().fill(muted ? Palette.muted.opacity(0.55) : Palette.quota(remaining))
                        .frame(width: geo.size.width * remaining / 100)
                }
            }
        }.frame(height: 5)
    }
    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Switches affect the global Claude login, not cswap run sessions.", systemImage: "info.circle")
            Text("Quota is reported by CSWAP and may be cached. A refresh never bypasses Anthropic’s rate limits.")
        }.font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 2)
    }
    var connectionCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Your Claude accounts,\nin one place.").font(.system(size: 39, weight: .semibold, design: .rounded))
            Text("Connect your existing CSWAP installation to see saved logins, remaining quota, and reset times.")
                .font(.system(size: 17)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                Label("Native Mac app", systemImage: "macwindow")
                Label("No hosted backend", systemImage: "externaldrive")
                Label("Your existing accounts", systemImage: "person.2")
            }.font(.system(size: 14)).foregroundStyle(Palette.muted)
            Rectangle().fill(Palette.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("What happens when you connect").font(.system(size: 16, weight: .semibold))
                Text("The app runs cswap list --json. CSWAP may access Keychain, refresh its own login tokens, and contact Anthropic for quota. This app never reads, copies, or stores your tokens.")
                    .font(.system(size: 15)).foregroundStyle(Palette.muted).lineSpacing(4)
                Text("No account is switched automatically.").font(.system(size: 15)).foregroundStyle(Palette.mint)
            }
            HStack(spacing: 12) {
                Button { Task { await store.refresh() } } label: { Label("Connect to CSWAP", systemImage: "link") }.buttonStyle(ActionStyle(primary: true)).disabled(store.busy)
                Button("Choose executable…") { showSettings = true }.buttonStyle(ActionStyle()).disabled(store.busy)
            }
            Text(store.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
        }.padding(34).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Palette.border)).padding(.top, 15)
    }
    func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).foregroundStyle(color).padding(.top, 2)
            Text(text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(15).background(color.opacity(0.065)).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.17)))
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) var dismiss
    @State private var path = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Local settings").font(.system(size: 25, weight: .semibold))
            Text(store.version).font(.system(size: 13)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 9) {
                Text("CSWAP executable").font(.system(size: 14, weight: .medium))
                TextField("Absolute path to cswap", text: $path).textFieldStyle(.roundedBorder)
                Button("Choose file…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }.buttonStyle(ActionStyle())
                Text("Only choose a trusted CSWAP executable; it will run with your Mac user’s permissions.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            Toggle("Refresh accounts every minute while CSWAP is running", isOn: $store.autoRefresh).font(.system(size: 14))
            Text("Off by default on each launch. Use Refresh or ⌘R whenever you need an update. Closing the dashboard leaves CSWAP in the menu bar; choose Quit CSWAP to stop it.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
            Text("CSWAP controls quota caching and network backoff. Local-only means no app backend or telemetry—not offline quota checks. Switching still uses CSWAP’s credential and Keychain handling.")
                .font(.system(size: 14)).foregroundStyle(Palette.muted).lineSpacing(4)
            HStack {
                Button("Close") { dismiss() }.buttonStyle(ActionStyle())
                Spacer()
                Button("Save path") {
                    let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean != store.path { store.savePath(clean) }
                    dismiss()
                }.buttonStyle(ActionStyle(primary: true)).disabled(!path.hasPrefix("/") || store.busy)
            }
        }.padding(30).frame(width: 560).background(Palette.background)
            .onAppear { path = store.path }
    }
}

struct AddAccountSheet: View {
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) var dismiss
    @State private var alias = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Add an account", systemImage: "person.crop.circle.badge.plus").font(.system(size: 25, weight: .semibold))
            Text("1. In Claude Code, run /login and sign in to the account you want to save. Do not run /logout first—it can revoke the previous account’s saved token.")
                .font(.system(size: 15)).lineSpacing(4)
            Text("2. Return here and save the current login. CSWAP will add a new slot or update that account if it already exists.")
                .font(.system(size: 15)).lineSpacing(4)
            Text("If you haven’t saved the current login yet, save it before signing in to another account.")
                .font(.system(size: 14)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 8) {
                Text("Alias (optional)").font(.system(size: 14, weight: .medium))
                TextField("e.g. personal or work", text: $alias).textFieldStyle(.roundedBorder).disabled(store.busy)
            }
            Text("Saving invokes cswap add and lets CSWAP store the current credentials. No tokens are entered into this app.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(3)
            if let error = store.error { Text(error).foregroundStyle(.orange).font(.system(size: 13)).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(ActionStyle()).disabled(store.busy)
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button("Save current login") { Task { if await store.addCurrent(alias: alias) { dismiss() } } }
                    .buttonStyle(ActionStyle(primary: true)).disabled(store.busy || store.demo)
            }
        }.padding(30).frame(width: 580).background(Palette.background).interactiveDismissDisabled(store.busy)
    }
}
