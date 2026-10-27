import SwiftUI
import AppKit

@main
struct DevToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var cswap = DashboardStore(localDataURL: LocalDataFile.defaultURL)
    @StateObject private var vpn = VPNStore()
    @AppStorage("selectedTool") private var selected: Tool = .cswap
    var body: some Scene {
        Window("DevTools", id: "dashboard") {
            ShellView().environmentObject(cswap).environmentObject(vpn)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1090, minHeight: 720)
        }
        .defaultSize(width: 1310, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appTermination) {
                Button("Quit DevTools") { NSApp.terminate(nil) }
                    .keyboardShortcut("q").disabled(cswap.busy || vpn.busy)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh \(selected.title)") {
                    switch selected {
                    case .cswap: Task { await cswap.refresh() }
                    case .vpn: Task { await vpn.refresh() }
                    }
                }
                .keyboardShortcut("r")
                .disabled(selected == .cswap ? cswap.busy || !cswap.connected || cswap.accountReview != nil : vpn.busy)
            }
        }
        MenuBarExtra("DevTools", systemImage: "wrench.and.screwdriver") {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                MenuBarPanel().environmentObject(cswap).environmentObject(vpn).preferredColorScheme(.dark)
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
