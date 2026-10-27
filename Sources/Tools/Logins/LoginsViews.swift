import SwiftUI
import AppKit
import Combine

@MainActor
func refreshLogins(aws: AWSStore, cli: CLILoginStore) async {
    async let checkAWS: Void = aws.refresh()
    async let checkCLI: Void = cli.refresh()
    _ = await (checkAWS, checkCLI)
}

extension ProfileStatus {
    var color: Color {
        switch self {
        case .signedIn: Palette.mint
        case .expired: .orange
        case .failed: .red.opacity(0.85)
        case .unknown, .checking: Palette.muted
        }
    }

    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .signedIn: "Signed in"
        case .expired: "Signed out"
        case .failed(let message): message
        }
    }
}

struct SessionLoginButton: View {
    @EnvironmentObject var aws: AWSStore
    let session: SSOSession
    var body: some View {
        if aws.loggingIn == session.id {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Approve in your browser…").font(.system(size: 12)).foregroundStyle(Palette.accent)
                Button("Cancel") { aws.cancelLogin() }.buttonStyle(ActionStyle()).help("Stop waiting for the browser approval")
            }
        } else {
            Button(aws.needsLogin(session) ? "Log in" : "Log in again") { aws.beginLogin(session) }
                .buttonStyle(ActionStyle(primary: aws.needsLogin(session))).disabled(aws.busy || aws.demo)
        }
    }
}

struct StatusLabel: View {
    let status: ProfileStatus
    var compact = false
    var body: some View {
        HStack(spacing: 6) {
            if status == .checking { ProgressView().controlSize(.mini) }
            Text(status.label).font(.system(size: 12)).foregroundStyle(status.color).lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.trailing).help(status.label)
        }
    }
}

// One row per login: a profile on its own session, or a profile inside a shared session's card.
struct ProfileRow: View {
    @EnvironmentObject var aws: AWSStore
    let profile: AWSProfile
    var session: SSOSession?
    var compact = false
    var body: some View {
        let status = aws.status(profile)
        HStack(spacing: 12) {
            Circle().fill(status.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: compact ? 13 : 15, weight: .semibold)).lineLimit(1)
                if !compact, let account = profile.accountID {
                    Text([account, profile.roleName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            StatusLabel(status: status, compact: compact)
            if let session { SessionLoginButton(session: session) }
        }
    }
}

struct CLIRow: View {
    @EnvironmentObject var cli: CLILoginStore
    let tool: CLITool
    var compact = false
    var body: some View {
        let status = cli.status(tool)
        HStack(spacing: 12) {
            Circle().fill(status.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.title).font(.system(size: compact ? 13 : 15, weight: .semibold)).lineLimit(1)
                if case .signedIn(let account, _) = status {
                    Text(account).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).textSelection(.enabled)
                } else if !compact, let path = cli.paths[tool] {
                    Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            StatusLabel(status: status, compact: compact)
            if cli.installed(tool) {
                Button(status.isSignedIn ? "Log in again" : "Log in") { cli.login(tool) }
                    .buttonStyle(ActionStyle(primary: !status.isSignedIn && status != .checking)).disabled(cli.demo || status == .checking)
                    .help("Opens Terminal to run \(tool.executable) \(tool.loginArguments.joined(separator: " "))")
            }
        }
    }
}

struct LoginsMenuSection: View {
    @EnvironmentObject var aws: AWSStore
    @EnvironmentObject var cli: CLILoginStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Tag(text: aws.demo ? "Sample data" : "\(aws.signedInCount + cli.signedInCount) of \(aws.profileCount + CLITool.allCases.count) signed in")
                Spacer()
                Button { Task { await refreshLogins(aws: aws, cli: cli) } } label: { Label("Check", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).disabled(aws.busy || cli.checking)
            }
            MessageList(errors: [aws.error, cli.error].compactMap { $0 }, notice: aws.notice ?? cli.notice, compact: true) { aws.notice = nil; cli.notice = nil }
            SectionLabel(text: "AWS")
            if aws.sessions.isEmpty && aws.error == nil {
                Text("Reading ~/.aws/config…").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            ForEach(aws.sessions) { session in
                if session.profiles.count == 1 {
                    ProfileRow(profile: session.profiles[0], session: session, compact: true)
                        .padding(10).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel(text: session.name.uppercased())
                            Spacer()
                            SessionLoginButton(session: session)
                        }
                        ForEach(session.profiles) { ProfileRow(profile: $0, compact: true) }
                    }.padding(10).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            SectionLabel(text: "COMMAND-LINE TOOLS")
            ForEach(CLITool.allCases) { tool in
                CLIRow(tool: tool, compact: true).padding(10).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            Text("AWS logs in through your browser. GitHub and Google Cloud open a Terminal window to sign in.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            await aws.refreshIfStale()
            await cli.refreshIfStale()
        }
    }

}

struct LoginsDashboardView: View {
    @EnvironmentObject var aws: AWSStore
    @EnvironmentObject var cli: CLILoginStore
    @ViewState private var now = Date()
    let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if aws.demo { Banner(text: "Demo preview · sample logins, nothing is run. Relaunch without --demo to check yours.", icon: "theatermasks", color: Palette.accent) }
                    MessageList(errors: [aws.error, cli.error].compactMap { $0 }, notice: aws.notice ?? cli.notice) { aws.notice = nil; cli.notice = nil }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Logins").font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text("Who your command-line tools are signed in as, and a login for each.").font(.system(size: 15)).foregroundStyle(Palette.muted)
                    }
                    SectionHeading(title: "AWS", caption: "SSO profiles from ~/.aws/config. Each one on its own sso-session logs in separately.")
                    ForEach(aws.sessions) { session in
                        if session.profiles.count == 1 {
                            card { ProfileRow(profile: session.profiles[0], session: session).padding(18) }
                        } else {
                            sessionCard(session)
                        }
                    }
                    SectionHeading(title: "COMMAND-LINE TOOLS", caption: "Log in opens Terminal for the CLI's own sign-in, which may ask questions.")
                    card {
                        VStack(spacing: 0) {
                            ForEach(CLITool.allCases) { tool in
                                CLIRow(tool: tool).padding(18)
                                if tool != CLITool.allCases.last { Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 18) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Commands that use --profile or AWS_PROFILE pick up a new AWS login right away.", systemImage: "info.circle")
                        Text("A shell that exported credentials into its environment keeps the old ones until you export again. Checks only ask who you are; they never write credentials.")
                    }.font(.system(size: 13)).foregroundStyle(Palette.muted)
                }.padding(30)
            }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .onReceive(clock) { now = $0 }
        .task {
            await aws.refreshIfStale()
            await cli.refreshIfStale()
        }
    }

    var header: some View {
        ToolHeader(area: "Cloud", icon: "cloud", page: "Logins", working: aws.checking || cli.checking ? "Checking…" : nil,
                   checked: [aws.checkedAt, cli.checkedAt].compactMap { $0 }.min().map { "Checked \(Dates.age($0, now: now).lowercased())" }) {
            Button { Task { await refreshLogins(aws: aws, cli: cli) } } label: { Label("Check all", systemImage: "arrow.clockwise") }
                .buttonStyle(ActionStyle()).disabled(aws.busy || cli.checking).help("Check every login again. ⌘R")
        }
    }

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.border))
    }

    func sessionCard(_ session: SSOSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SHARED SSO SESSION · ONE LOGIN FOR ALL").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
                    Text(session.name).font(.system(size: 22, weight: .semibold, design: .rounded))
                    if let url = session.startURL {
                        Text(url).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    }
                }
                Spacer()
                SessionLoginButton(session: session)
            }.padding(20)
            Rectangle().fill(Palette.border).frame(height: 1)
            ForEach(session.profiles) { profile in
                ProfileRow(profile: profile).padding(.horizontal, 18).padding(.vertical, 12)
                if profile.id != session.profiles.last?.id { Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 18) }
            }
        }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(aws.needsLogin(session) ? Color.orange.opacity(0.25) : Palette.border))
    }
}
