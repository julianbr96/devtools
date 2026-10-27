import SwiftUI
import AppKit

@main
struct DevToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var cswap = DashboardStore(localDataURL: LocalDataFile.defaultURL)
    @StateObject private var vpn = VPNStore()
    @StateObject private var machine = MachineStore()
    @StateObject private var aws = AWSStore()
    @AppStorage("selectedTool") private var selected: Tool = .cswap
    var body: some Scene {
        Window("DevTools", id: "dashboard") {
            ShellView().environmentObject(cswap).environmentObject(vpn).environmentObject(machine).environmentObject(aws)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1090, minHeight: 720)
        }
        .defaultSize(width: 1310, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appTermination) {
                Button("Quit DevTools") { NSApp.terminate(nil) }
                    .keyboardShortcut("q").disabled(cswap.busy || vpn.busy || aws.loggingIn != nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh \(selected.title)") {
                    switch selected {
                    case .cswap: Task { await cswap.refresh() }
                    case .vpn: Task { await vpn.refresh() }
                    case .machine: Task { await machine.refresh() }
                    case .aws: Task { await aws.refresh() }
                    }
                }
                .keyboardShortcut("r")
                .disabled(refreshDisabled)
            }
        }
        MenuBarExtra("DevTools", systemImage: "wrench.and.screwdriver") {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                MenuBarPanel().environmentObject(cswap).environmentObject(vpn).environmentObject(machine).environmentObject(aws)
                    .preferredColorScheme(.dark)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var refreshDisabled: Bool {
        switch selected {
        case .cswap: cswap.busy || !cswap.connected || cswap.accountReview != nil
        case .vpn: vpn.busy
        case .machine: machine.busy
        case .aws: aws.busy
        }
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
