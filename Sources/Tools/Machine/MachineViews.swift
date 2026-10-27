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
            Text("LOCAL SERVERS").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
            if machine.listeners.isEmpty {
                Text("Nothing of yours is listening on a port.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            ForEach(machine.listeners) { ListenerRow(listener: $0, compact: true) }
            Text("HEAVIEST APPS").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
            VStack(spacing: 6) {
                ForEach(machine.groups.prefix(5)) { group in
                    HStack {
                        Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(Bytes.mem(group.residentBytes)).font(.system(size: 13)).monospacedDigit()
                    }
                }
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

struct ListenerRow: View {
    @EnvironmentObject var machine: MachineStore
    let listener: Listener
    var compact = false
    @ViewState private var confirming = false
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(listener.name).font(.system(size: compact ? 14 : 15, weight: .semibold)).lineLimit(1)
                    ForEach(listener.ports, id: \.self) { Tag(text: ":\($0)", color: Palette.accent) }
                }
                Text(verbatim: compact ? "PID \(listener.pid)" : "PID \(listener.pid) · \(listener.command)")
                    .font(.system(size: 11, design: compact ? .default : .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if machine.canForceStop(listener) {
                Button("Force stop") { Task { await machine.stop(listener, force: true) } }.buttonStyle(ActionStyle(primary: true))
            } else if machine.stopping[listener.pid] != nil {
                ProgressView().controlSize(.small)
            } else if confirming {
                Button("Cancel") { confirming = false }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button("Stop it") { confirming = false; Task { await machine.stop(listener) } }.buttonStyle(ActionStyle(primary: true))
            } else {
                Button("Stop") { confirming = true }.buttonStyle(ActionStyle()).disabled(machine.demo)
            }
        }.padding(12).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 9))
            .help(listener.addresses.joined(separator: ", "))
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
                    section("LOCAL SERVERS", trailing: "Your own processes listening on a TCP port") {
                        if machine.listeners.isEmpty {
                            Text("Nothing of yours is listening on a port.").font(.system(size: 14)).foregroundStyle(Palette.muted)
                        }
                        ForEach(machine.listeners) { ListenerRow(listener: $0) }
                    }
                    section("HEAVIEST APPS", trailing: "Resident memory, helpers counted with their app") {
                        VStack(spacing: 0) {
                            ForEach(machine.groups) { group in
                                HStack {
                                    Text(group.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text(group.count == 1 ? "1 process" : "\(group.count) processes").font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    Spacer()
                                    Text(String(format: "%.0f%% CPU", group.cpu)).font(.system(size: 13)).foregroundStyle(Palette.muted).monospacedDigit().frame(width: 90, alignment: .trailing)
                                    Text(Bytes.mem(group.residentBytes)).font(.system(size: 14, weight: .semibold)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                }.padding(.horizontal, 18).padding(.vertical, 12)
                                if group.id != machine.groups.last?.id { Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 18) }
                            }
                        }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.border))
                    }
                    Text("Stop sends the process a normal quit signal (SIGTERM); Force stop appears if it is still listening a few seconds later. macOS services and apps are never listed.")
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

    func section<Content: View>(_ title: String, trailing: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted)
                Spacer()
                Text(trailing).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            content()
        }
    }
}
