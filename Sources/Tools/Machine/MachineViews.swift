import SwiftUI
import AppKit
import Combine

extension LoadVerdict {
    var color: Color {
        switch self {
        case .wait: .red.opacity(0.85)
        case .oneAtATime: .orange
        case .clear: Palette.mint
        }
    }
}

enum Bytes {
    static func gb(_ bytes: Int64) -> String { String(format: bytes >= 10 << 30 ? "%.0f GB" : "%.1f GB", Double(bytes) / Double(1 << 30)) }
    static func gb(_ bytes: UInt64) -> String { gb(Int64(bytes)) }
    static func mem(_ bytes: Int64) -> String { bytes >= 1 << 30 ? gb(bytes) : String(format: "%.0f MB", Double(bytes) / Double(1 << 20)) }
}

enum MachineCopy {
    static let serversTitle = "LOCAL SERVERS"
    static let serversCaption = "Dev servers, databases and tools you started that listen on a port. Stop them when you are done to free memory."
    static let noServers = "Nothing you started is listening on a port."
    static let heaviestTitle = "HEAVIEST APPS & PROCESSES"
}

// Two clicks: the first arms the button, the second sends the signal.
struct ConfirmingButton: View {
    let title: String
    let confirmTitle: String
    let action: () -> Void
    @ViewState private var armed = false
    var body: some View {
        if armed {
            HStack(spacing: 8) {
                Button("Cancel") { armed = false }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button(confirmTitle) { armed = false; action() }.buttonStyle(ActionStyle(primary: true))
            }
        } else {
            Button(title) { armed = true }.buttonStyle(ActionStyle())
        }
    }
}

struct ProcessStopControl: View {
    @EnvironmentObject var machine: MachineStore
    let process: ProcessRow
    let name: String
    var body: some View {
        if !MachineParse.canSignal(process) {
            EmptyView()
        } else if machine.canForceStop(process) {
            Button("Force stop") { Task { await machine.stop(process, name: name, force: true) } }.buttonStyle(ActionStyle(primary: true))
        } else if machine.stopping[process.pid] != nil {
            ProgressView().controlSize(.small)
        } else {
            ConfirmingButton(title: "Stop", confirmTitle: "Stop it") { Task { await machine.stop(process, name: name) } }
                .disabled(machine.demo)
        }
    }
}

struct AppQuitControl: View {
    @EnvironmentObject var machine: MachineStore
    let group: ProcessGroup
    var body: some View {
        if !MachineParse.canQuit(group) {
            EmptyView()
        } else if machine.canForceQuit(group) {
            Button("Force quit") { Task { await machine.quit(group, force: true) } }.buttonStyle(ActionStyle(primary: true))
        } else if let bundle = group.appBundle, machine.quitting[bundle] != nil {
            ProgressView().controlSize(.small)
        } else {
            ConfirmingButton(title: "Quit", confirmTitle: "Quit \(group.name)") { Task { await machine.quit(group) } }
                .disabled(machine.demo)
        }
    }
}

struct ListenerRow: View {
    let listener: Listener
    var compact = false
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(listener.name).font(.system(size: compact ? 14 : 15, weight: .semibold)).lineLimit(1)
                    ForEach(listener.ports, id: \.self) { Tag(text: ":\($0)", color: Palette.accent) }
                }
                Text(verbatim: "PID \(listener.process.pid) · \(listener.process.commandLine)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            ProcessStopControl(process: listener.process, name: listener.name)
        }.padding(12).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9))
            .help("\(listener.process.commandLine)\n\(listener.addresses.joined(separator: ", "))")
    }
}

// An app gets Quit; a command-line tool expands into its processes, each with Stop.
struct GroupRow: View {
    let group: ProcessGroup
    var compact = false
    @ViewState private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if group.appBundle == nil {
                    Button { expanded.toggle() } label: {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 14)
                    }.buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel(expanded ? "Hide processes" : "Show processes")
                } else {
                    Image(systemName: "app").font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                }
                Text(group.name).font(.system(size: compact ? 13 : 14, weight: .medium)).lineLimit(1)
                if !compact && group.processes.allSatisfy(\.isSystem) { Tag(text: "macOS") }
                if !compact {
                    Text(verbatim: group.processes.count == 1 ? "1 process" : "\(group.processes.count) processes").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 6)
                if !compact {
                    Text(String(format: "%.0f%% CPU", group.cpu)).font(.system(size: 13)).foregroundStyle(Palette.muted).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                Text(Bytes.mem(group.residentBytes)).font(.system(size: compact ? 13 : 14, weight: .semibold)).monospacedDigit().frame(width: 66, alignment: .trailing)
                if group.appBundle != nil { AppQuitControl(group: group) }
            }
            .padding(.vertical, compact ? 6 : 12).contentShape(Rectangle())
            .onTapGesture { if group.appBundle == nil { expanded.toggle() } }
            if expanded {
                VStack(spacing: 6) {
                    ForEach(group.processes.prefix(12), id: \.pid) { process in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: "PID \(process.pid) · \(Bytes.mem(Int64(process.residentKB) * 1024))").font(.system(size: 12, weight: .medium))
                                Text(process.commandLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                                    .lineLimit(1).truncationMode(.middle).help(process.commandLine)
                            }
                            Spacer(minLength: 6)
                            ProcessStopControl(process: process, name: group.name)
                        }.padding(10).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.leading, 24).padding(.bottom, 10)
            }
        }
    }
}

struct MachineMenuSection: View {
    @EnvironmentObject var machine: MachineStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Tag(text: machine.demo ? "Sample data" : "Updates every 10 s while open")
                Spacer()
                Button { Task { await machine.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).disabled(machine.busy)
            }
            if let error = machine.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if let free = machine.freePercent, let verdict = machine.verdict {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MEMORY FREE").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(verdict.color)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(free)%").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(verdict.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(verdict.color)
                    }
                    LoadBar(fraction: Double(free) / 100, color: verdict.color)
                    HStack(spacing: 14) {
                        MiniStat(label: "Swap used", value: Bytes.gb(machine.system.swapUsedBytes))
                        MiniStat(label: "Disk free", value: machine.system.diskAvailableBytes.map(Bytes.gb) ?? "—")
                        MiniStat(label: "RAM", value: Bytes.gb(machine.system.physicalBytes))
                    }
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            } else if machine.error == nil {
                Text("Reading memory…").font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(MachineCopy.serversTitle).font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
                Text(MachineCopy.serversCaption).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if machine.listeners.isEmpty {
                Text(MachineCopy.noServers).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            ForEach(machine.listeners) { ListenerRow(listener: $0, compact: true) }
            Text(MachineCopy.heaviestTitle).font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
            VStack(spacing: 0) {
                ForEach(machine.groups.prefix(5)) { GroupRow(group: $0, compact: true) }
            }
        }
        .task { await machine.watch() }
    }
}

struct MiniStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LoadBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.065))
                Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }.frame(height: 5)
    }
}

struct MachineDashboardView: View {
    @EnvironmentObject var machine: MachineStore
    @ViewState private var now = Date()
    let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if machine.demo { Banner(text: "Demo preview · sample readings, nothing is stopped. Relaunch without --demo to see this Mac.", icon: "theatermasks", color: Palette.accent) }
                    if let error = machine.error { Banner(text: error, icon: "exclamationmark.triangle", color: .orange) }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Mac load").font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text(machine.verdict?.detail ?? "Reading memory…").font(.system(size: 15)).foregroundStyle(Palette.muted)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        memoryCard
                        statCard("SWAP USED", value: Bytes.gb(machine.system.swapUsedBytes), caption: "of \(Bytes.gb(machine.system.swapTotalBytes)) swap",
                                 fraction: machine.system.swapTotalBytes == 0 ? 0 : Double(machine.system.swapUsedBytes) / Double(machine.system.swapTotalBytes), color: Palette.accent)
                        statCard("DISK FREE", value: machine.system.diskAvailableBytes.map(Bytes.gb) ?? "—",
                                 caption: machine.system.diskTotalBytes.map { "of \(Bytes.gb($0))" } ?? "",
                                 fraction: diskFraction, color: Palette.mint)
                    }
                    section(MachineCopy.serversTitle, caption: MachineCopy.serversCaption) {
                        if machine.listeners.isEmpty {
                            Text(MachineCopy.noServers).font(.system(size: 14)).foregroundStyle(Palette.muted)
                        }
                        ForEach(machine.listeners) { ListenerRow(listener: $0) }
                    }
                    section(MachineCopy.heaviestTitle, caption: "Resident memory. An app's helpers count with the app; expand a tool to stop one of its processes.") {
                        VStack(spacing: 0) {
                            ForEach(machine.groups) { group in
                                GroupRow(group: group).padding(.horizontal, 18)
                                if group.id != machine.groups.last?.id { Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 18) }
                            }
                        }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.border))
                    }
                    Text("Quit asks an app to close the way ⌘Q does; Stop sends a process a normal quit signal (SIGTERM). Force quit and Force stop appear if it is still running a few seconds later. macOS itself is never offered.")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                }.padding(30)
            }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .onReceive(clock) { now = $0 }
        .task { await machine.watch() }
    }

    var diskFraction: Double {
        guard let available = machine.system.diskAvailableBytes, let total = machine.system.diskTotalBytes, total > 0 else { return 0 }
        return Double(available) / Double(total)
    }

    var header: some View {
        HStack {
            Label("This Mac", systemImage: "desktopcomputer").foregroundStyle(Palette.muted).font(.system(size: 14, weight: .medium))
            Text("/").foregroundStyle(Palette.muted.opacity(0.5)).padding(.horizontal, 7)
            Text("Load").font(.system(size: 14, weight: .medium))
            Spacer()
            if machine.checkedAt != nil {
                Text("Checked \(Dates.age(machine.checkedAt, now: now).lowercased())").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            Button { Task { await machine.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(ActionStyle()).disabled(machine.busy).help("Read memory, processes and ports again. ⌘R")
        }.padding(.horizontal, 30).frame(height: 78)
    }

    var memoryCard: some View {
        let verdict = machine.verdict
        return VStack(alignment: .leading, spacing: 12) {
            Text("MEMORY FREE").font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(verdict?.color ?? Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(machine.freePercent.map(String.init) ?? "—").font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit()
                if machine.freePercent != nil { Text("%").font(.system(size: 23)).foregroundStyle(Palette.muted) }
            }
            Text(verdict?.title ?? "Reading…").font(.system(size: 14, weight: .semibold)).foregroundStyle(verdict?.color ?? Palette.muted)
            LoadBar(fraction: Double(machine.freePercent ?? 0) / 100, color: verdict?.color ?? Palette.muted)
            Text("of \(Bytes.gb(machine.system.physicalBytes)) RAM · from memory_pressure").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).frame(height: 198)
            .background(LinearGradient(colors: [(verdict?.color ?? Palette.muted).opacity(0.095), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder((verdict?.color ?? Palette.border).opacity(0.24)))
    }

    func statCard(_ title: String, value: String, caption: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .medium)).tracking(1).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 13)).foregroundStyle(Palette.muted)
            LoadBar(fraction: fraction, color: color)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).frame(height: 198)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.border))
    }

    func section<Content: View>(_ title: String, caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted)
                Text(caption).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            content()
        }
    }
}
