import SwiftUI

extension AccountColor {
    var tint: Color {
        switch self {
        case .peach: return Palette.accent
        case .mint: return Palette.mint
        case .blue: return Color(red: 0.47, green: 0.69, blue: 0.98)
        case .purple: return Color(red: 0.73, green: 0.59, blue: 0.97)
        case .pink: return Color(red: 0.96, green: 0.56, blue: 0.71)
        case .gold: return Color(red: 0.94, green: 0.79, blue: 0.40)
        case .gray: return Palette.muted
        }
    }
}

extension DashboardStore {
    func tint(for account: Account) -> Color { style(for: account).color.tint }
}

struct LocalDataWarning: View {
    @EnvironmentObject var store: DashboardStore
    var body: some View {
        if let warning = store.localDataError {
            VStack(alignment: .leading, spacing: 8) {
                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                Button("Retry local save") { store.retryLocalSave() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

struct AccountStyleSheet: View {
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @ViewState private var nickname = ""
    @ViewState private var color: AccountColor = .peach
    private var previewName: String {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? account.title : value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Make it yours").font(.system(size: 27, weight: .semibold, design: .rounded))
            Text("A name and color just for this app. Your CSWAP alias, Claude login, and credentials stay unchanged.")
                .font(.system(size: 14)).foregroundStyle(Palette.muted)
            HStack(spacing: 15) {
                Text(String(previewName.prefix(2)).uppercased()).font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(color.tint).frame(width: 56, height: 56).background(color.tint.opacity(0.13)).clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(previewName).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(account.email).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(account.organization).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }.padding(17).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Display name").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("\(nickname.count)/40").font(.system(size: 12)).foregroundStyle(nickname.count > 40 ? .orange : Palette.muted)
                }
                TextField(account.title, text: $nickname).textFieldStyle(.roundedBorder).accessibilityLabel("Local account name")
                Text("Leave blank to use the CSWAP alias or account name.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Account color · \(color.label)").font(.system(size: 14, weight: .medium))
                HStack(spacing: 12) {
                    ForEach(AccountColor.allCases, id: \.self) { choice in
                        Button { color = choice } label: {
                            Circle().fill(choice.tint).frame(width: 34, height: 34)
                                .overlay { if color == choice { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.background) } }
                                .padding(3).overlay(Circle().strokeBorder(color == choice ? choice.tint : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel("\(choice.label) account color")
                            .accessibilityValue(color == choice ? "Selected" : "Not selected").help(choice.label)
                    }
                }
            }
            LocalDataWarning()
            if store.demo { Text("Demo changes stay in memory and disappear when you quit.").font(.system(size: 12)).foregroundStyle(Palette.accent) }
            HStack {
                Button("Reset appearance") { nickname = ""; color = .peach }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button("Save appearance") {
                    if store.saveStyle(for: account, nickname: nickname, color: color) { dismiss() }
                }.buttonStyle(ActionStyle(primary: true)).disabled(store.busy || (try? AccountStyle.make(nickname: nickname, color: color)) == nil)
            }
        }.padding(28).frame(width: 550).background(Palette.background).foregroundStyle(.white).tint(Palette.accent)
            .onAppear { let style = store.style(for: account); nickname = style.nickname ?? ""; color = style.color }
    }
}

struct SwitchHistorySheet: View {
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Switch history").font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("Only on this Mac · last \(LocalArchive.historyLimit) switches").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Tag(text: "\(store.localArchive.history.count) recorded")
            }
            Text("Records successful switches made through this app. Terminal switches, failed attempts, and unchanged logins aren’t recorded. Names and slots reflect the time of the switch. No tokens or quota snapshots are stored.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
            LocalDataWarning()
            if store.localArchive.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 35)).foregroundStyle(Palette.accent)
                    Text("Your next switch starts the story").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Nothing is reconstructed from older sessions.").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if store.demo { Text("Sample history only — no real switches were made.").font(.system(size: 12)).foregroundStyle(Palette.accent) }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.localArchive.history) { record in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Tag(text: record.method.label)
                                    Spacer()
                                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                        .help(record.date.formatted(date: .complete, time: .complete))
                                }
                                HStack(alignment: .top, spacing: 16) {
                                    if let from = record.from { identity(from, label: "FROM") }
                                    else { Text("Unmanaged / unknown login").font(.system(size: 13)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
                                    Image(systemName: "arrow.right").foregroundStyle(Palette.muted).padding(.top, 20)
                                    identity(record.to, label: "TO")
                                }
                            }.padding(17).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            HStack {
                Button("Clear history…") { confirmClear = true }.buttonStyle(ActionStyle()).disabled(store.localArchive.history.isEmpty || store.busy)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 760, height: 630).background(Palette.background).foregroundStyle(.white).tint(Palette.accent)
            .alert("Clear local switch history?", isPresented: $confirmClear) {
                Button("Cancel", role: .cancel) { }
                Button("Clear history", role: .destructive) { _ = store.clearHistory() }
            } message: { Text("This removes the history stored by this app. Account names, colors, and the active Claude login are unchanged. This cannot be undone.") }
    }
    private func identity(_ account: HistoryAccount, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
            HStack(spacing: 7) {
                Circle().fill(account.color.tint).frame(width: 8, height: 8)
                Text(account.name).font(.system(size: 16, weight: .semibold)).lineLimit(1).help(account.name)
            }
            Text(account.email).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).help(account.email)
            Text("#\(account.slot) · \(account.organization)").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
