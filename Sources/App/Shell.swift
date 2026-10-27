import SwiftUI
import AppKit

// Every tool gets a case here, a full page in ShellView and a section in MenuBarPanel.
enum Tool: String, CaseIterable, Identifiable {
    case cswap, vpn, machine, aws
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cswap: "CSWAP"
        case .vpn: "VPN"
        case .machine: "Mac"
        case .aws: "AWS"
        }
    }
    var icon: String {
        switch self {
        case .cswap: "arrow.left.arrow.right"
        case .vpn: "lock.shield"
        case .machine: "memorychip"
        case .aws: "cloud"
        }
    }
}

struct ShellView: View {
    @AppStorage("selectedTool") private var selected: Tool = .cswap
    var body: some View {
        HStack(spacing: 0) {
            ToolRail(selected: $selected)
            switch selected {
            case .cswap: DashboardView()
            case .vpn: VPNDashboardView()
            case .machine: MachineDashboardView()
            case .aws: AWSDashboardView()
            }
        }.background(Palette.background)
    }
}

struct ToolRail: View {
    @Binding var selected: Tool
    var body: some View {
        VStack(spacing: 14) {
            ForEach(Tool.allCases) { tool in
                let isSelected = tool == selected
                Button { selected = tool } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tool.icon).font(.system(size: 16, weight: .bold))
                            .foregroundStyle(isSelected ? Palette.background : Palette.muted)
                            .frame(width: 40, height: 40)
                            .background(isSelected ? Palette.accent : Color.white.opacity(0.055))
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                        Text(tool.title).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : Palette.muted)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
            }
            Spacer()
        }
        .padding(.top, 58).frame(width: 72)
        .background(Palette.background)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1) }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var cswap: DashboardStore
    @EnvironmentObject var vpn: VPNStore
    @EnvironmentObject var aws: AWSStore
    @AppStorage("selectedTool") private var selected: Tool = .cswap
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack {
                    Label("DevTools", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
                    Spacer()
                    if cswap.busy || vpn.busy || aws.busy { ProgressView().controlSize(.small) }
                }
                Picker("Tool", selection: $selected) {
                    ForEach(Tool.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(18)
            Divider().overlay(Palette.border)
            ScrollView {
                Group {
                    switch selected {
                    case .cswap: CSWAPMenuSection(showDashboard: showDashboard)
                    case .vpn: VPNMenuSection()
                    case .machine: MachineMenuSection()
                    case .aws: AWSMenuSection()
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 540)
            Divider().overlay(Palette.border)
            HStack {
                Button("Open dashboard", action: showDashboard).buttonStyle(.plain)
                Spacer()
                Button("Quit DevTools") { NSApp.terminate(nil) }.buttonStyle(.plain).disabled(cswap.busy || vpn.busy || aws.loggingIn != nil)
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).padding(18)
        }.frame(width: 420).fixedSize(horizontal: false, vertical: true)
            .background(Palette.background).foregroundStyle(.white).tint(Palette.accent)
    }

    private func showDashboard() {
        openWindow(id: "dashboard")
        if selected == .cswap, cswap.accountReview != nil { cswap.reviewLocation = .dashboard }
        NSApp.activate(ignoringOtherApps: true)
    }
}
