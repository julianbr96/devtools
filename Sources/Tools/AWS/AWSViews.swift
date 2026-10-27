import SwiftUI
import AppKit
import Combine

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

struct AWSMessages: View {
    @EnvironmentObject var aws: AWSStore
    var compact = false
    var body: some View {
        if let error = aws.error {
            if compact { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            else { Banner(text: error, icon: "exclamationmark.triangle", color: .orange) }
        }
        if let notice = aws.notice {
            HStack(alignment: .top) {
                if compact { Text(notice).font(.system(size: 12)).foregroundStyle(Palette.mint) }
                else { Banner(text: notice, icon: "checkmark.circle", color: Palette.mint) }
                Spacer(minLength: 0)
                Button { aws.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .foregroundStyle(Palette.muted).padding(.top, compact ? 0 : 15).accessibilityLabel("Dismiss")
            }
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
            }
        } else {
            Button(aws.needsLogin(session) ? "Log in" : "Log in again") { Task { await aws.login(session) } }
                .buttonStyle(ActionStyle(primary: aws.needsLogin(session))).disabled(aws.busy || aws.demo)
        }
    }
}

struct ProfileRow: View {
    @EnvironmentObject var aws: AWSStore
    let profile: AWSProfile
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
            if status == .checking { ProgressView().controlSize(.small) }
            Text(status.label).font(.system(size: 12)).foregroundStyle(status.color).lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.trailing).help(status.label)
        }.padding(.horizontal, compact ? 0 : 18).padding(.vertical, compact ? 4 : 12)
    }
}

struct AWSMenuSection: View {
    @EnvironmentObject var aws: AWSStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Tag(text: aws.demo ? "Sample data" : "\(aws.signedInCount) of \(aws.profileCount) signed in")
                Spacer()
                Button { Task { await aws.refresh() } } label: { Label("Check", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).disabled(aws.busy)
            }
            AWSMessages(compact: true)
            if aws.sessions.isEmpty && aws.error == nil {
                Text("Reading ~/.aws/config…").font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            ForEach(aws.sessions) { session in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(session.name.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
                        Spacer()
                        SessionLoginButton(session: session)
                    }
                    ForEach(session.profiles) { ProfileRow(profile: $0, compact: true) }
                }.padding(12).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            Text("Log in opens your browser to approve the SSO session.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        .task { await aws.refreshIfStale() }
    }
}

struct AWSDashboardView: View {
    @EnvironmentObject var aws: AWSStore
    @ViewState private var now = Date()
    let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if aws.demo { Banner(text: "Demo preview · sample profiles, no aws calls. Relaunch without --demo to check your sessions.", icon: "theatermasks", color: Palette.accent) }
                    AWSMessages()
                    VStack(alignment: .leading, spacing: 7) {
                        Text("AWS sessions").font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text("Your SSO profiles from ~/.aws/config, grouped by the login they share.").font(.system(size: 15)).foregroundStyle(Palette.muted)
                    }
                    ForEach(aws.sessions) { sessionCard($0) }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Commands that use --profile or AWS_PROFILE pick up a new login right away.", systemImage: "info.circle")
                        Text("A shell that exported credentials into its environment keeps the old ones until you export again. Checking only asks STS who each profile is.")
                        Text(aws.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }.font(.system(size: 13)).foregroundStyle(Palette.muted)
                }.padding(30)
            }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .onReceive(clock) { now = $0 }
        .task { await aws.refreshIfStale() }
    }

    var header: some View {
        HStack {
            Label("Cloud", systemImage: "cloud").foregroundStyle(Palette.muted).font(.system(size: 14, weight: .medium))
            Text("/").foregroundStyle(Palette.muted.opacity(0.5)).padding(.horizontal, 7)
            Text("AWS").font(.system(size: 14, weight: .medium))
            Spacer()
            if aws.checking { ProgressView().controlSize(.small); Text("Checking…").font(.system(size: 13)).foregroundStyle(Palette.muted) }
            else if aws.checkedAt != nil {
                Text("Checked \(Dates.age(aws.checkedAt, now: now).lowercased())").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            Button { Task { await aws.refresh() } } label: { Label("Check all", systemImage: "arrow.clockwise") }
                .buttonStyle(ActionStyle()).disabled(aws.busy).help("Ask STS about every profile again. ⌘R")
        }.padding(.horizontal, 30).frame(height: 78)
    }

    func sessionCard(_ session: SSOSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.legacyProfile ? "PROFILE LOGIN" : "SSO SESSION").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
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
                ProfileRow(profile: profile)
                if profile.id != session.profiles.last?.id { Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 18) }
            }
        }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(aws.needsLogin(session) ? Color.orange.opacity(0.25) : Palette.border))
    }
}
