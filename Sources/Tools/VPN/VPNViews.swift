import SwiftUI
import AppKit
import Combine

extension TunnelState {
    var color: Color {
        switch self {
        case .connected: Palette.mint
        case .otherVPN: Palette.accent
        case .broken, .staleDNS: .orange
        case .unconfigured, .disconnected, .unknown: Palette.muted
        }
    }
}

struct VPNMenuSection: View {
    @EnvironmentObject var vpn: VPNStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Tag(text: vpn.demo ? "Sample data" : "Checks every 30 s")
                Spacer()
                Button { Task { await vpn.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).disabled(vpn.busy)
            }
            MessageList(errors: [vpn.error].compactMap { $0 }, notice: vpn.notice, compact: true) { vpn.notice = nil }
            if vpn.tunnels.isEmpty && vpn.error == nil {
                Text("Checking tunnels…").font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            ForEach(vpn.tunnels) { TunnelRow(tunnel: $0) }
            if vpn.tunnels.count > 1 { AllTunnelsButtons() }
            Text("Connecting and disconnecting ask for your Mac password.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        .task { await vpn.refreshIfStale() }
    }
}

struct TunnelRow: View {
    @EnvironmentObject var vpn: VPNStore
    let tunnel: Tunnel
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(tunnel.state.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(tunnel.name.uppercased()).font(.system(size: 14, weight: .semibold, design: .rounded)).tracking(1)
                Text(tunnel.state.summary).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer()
            TunnelActionButton(tunnel: tunnel)
        }.padding(12).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9))
            .help(tunnel.detail)
    }
}

struct TunnelActionButton: View {
    @EnvironmentObject var vpn: VPNStore
    let tunnel: Tunnel
    var body: some View {
        if vpn.working == tunnel.name || vpn.working == "all" {
            ProgressView().controlSize(.small)
        } else if let action = tunnel.state.action {
            Button(action.title) { Task { await vpn.perform(action.verb, on: tunnel.name) } }
                .buttonStyle(ActionStyle(primary: action.verb == .up)).disabled(vpn.busy || vpn.demo)
        }
    }
}

struct AllTunnelsButtons: View {
    @EnvironmentObject var vpn: VPNStore
    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await vpn.perform(.up, on: "all") } } label: { Label("Connect all", systemImage: "bolt.horizontal").fixedSize() }
                .buttonStyle(ActionStyle(primary: true))
                .disabled(vpn.connectedCount == vpn.tunnels.count)
            Button { Task { await vpn.perform(.down, on: "all") } } label: { Label("Disconnect all", systemImage: "bolt.horizontal.slash").fixedSize() }
                .buttonStyle(ActionStyle())
                .disabled(vpn.connectedCount == 0)
        }.disabled(vpn.busy || vpn.demo)
    }
}

struct VPNDashboardView: View {
    @EnvironmentObject var vpn: VPNStore
    @ViewState private var showSettings = false
    @ViewState private var now = Date()
    let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if vpn.demo { Banner(text: "Demo preview · sample tunnels, no real darwin-vpn calls. Relaunch without --demo to connect.", icon: "theatermasks", color: Palette.accent) }
                    MessageList(errors: [vpn.error].compactMap { $0 }, notice: vpn.notice) { vpn.notice = nil }
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("VPN tunnels").font(.system(size: 32, weight: .semibold, design: .rounded))
                            Text("Every environment at once, each on its own tunnel.").font(.system(size: 15)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if vpn.tunnels.count > 1 { AllTunnelsButtons() }
                    }
                    if vpn.tunnels.isEmpty && vpn.error == nil {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking tunnels…").foregroundStyle(Palette.muted) }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(vpn.tunnels) { tunnelCard($0) }
                    }
                    footer
                }.padding(30)
            }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .sheet(isPresented: $showSettings) { VPNSettingsSheet().environmentObject(vpn) }
        .onReceive(clock) { now = $0 }
        .task { await vpn.refreshIfStale() }
    }

    var header: some View {
        ToolHeader(area: "Network", icon: "network", page: "VPN", working: vpn.busy ? "Working…" : nil,
                   checked: vpn.checkedAt.map { "Checked \(Dates.age($0, now: now).lowercased())" }) {
            Button { Task { await vpn.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(ActionStyle()).disabled(vpn.busy)
                .help("Run darwin-vpn status again. ⌘R")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(ActionStyle()).disabled(vpn.busy).help("Settings")
        }
    }

    func tunnelCard(_ tunnel: Tunnel) -> some View {
        let connected = tunnel.state.isConnected
        return VStack(alignment: .leading, spacing: 14) {
            Label(tunnel.state.summary.uppercased(), systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(tunnel.state.color).lineLimit(1)
            Text(tunnel.name.uppercased()).font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(2)
            if !connected && tunnel.state != .disconnected {
                Text(tunnel.detail).font(.system(size: 13)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tunnel.state == .unconfigured {
                Text("In Terminal, copy the client config and run: darwin-vpn setup \(tunnel.name)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.accent).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                TunnelActionButton(tunnel: tunnel)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 210)
            .background(LinearGradient(colors: [tunnel.state.color.opacity(connected ? 0.095 : 0.04), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(connected ? Palette.mint.opacity(0.24) : Palette.border))
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect and Disconnect show the macOS password prompt, then run darwin-vpn as an administrator.", systemImage: "lock")
            Text("Status needs no password. Saving a config (darwin-vpn setup) stays in Terminal, because it reads your private key from the clipboard.")
            Text(vpn.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }.font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 2)
    }
}

struct VPNSettingsSheet: View {
    @EnvironmentObject var vpn: VPNStore
    @Environment(\.dismiss) var dismiss
    @ViewState private var path = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("VPN settings").font(.system(size: 25, weight: .semibold))
            VStack(alignment: .leading, spacing: 9) {
                Text("darwin-vpn executable").font(.system(size: 14, weight: .medium))
                TextField("Absolute path to darwin-vpn", text: $path).textFieldStyle(.roundedBorder)
                Button("Choose file…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }.buttonStyle(ActionStyle())
                Text("Only choose a trusted darwin-vpn. After your password, it runs as an administrator to connect or disconnect.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            HStack {
                Button("Close") { dismiss() }.buttonStyle(ActionStyle())
                Spacer()
                Button("Save path") {
                    let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean != vpn.path { vpn.savePath(clean) }
                    dismiss()
                }.buttonStyle(ActionStyle(primary: true)).disabled(!Executable.isPlainPath(path.trimmingCharacters(in: .whitespacesAndNewlines)) || vpn.busy)
            }
        }.padding(30).frame(width: 560).background(Palette.background)
            .onAppear { path = vpn.path }
    }
}
