import Foundation
import Darwin

// How much free memory heavy local work needs: under `wait` nothing heavy starts, from `push`
// up a push (with its pre-push hooks) is fine. In between, run one heavy command at a time.
enum LoadVerdict: Equatable, Sendable {
    case wait, oneAtATime, clear
    static let waitBelow = 20
    static let pushFrom = 25

    init(freePercent: Int) {
        self = freePercent < Self.waitBelow ? .wait : freePercent < Self.pushFrom ? .oneAtATime : .clear
    }

    var title: String {
        switch self {
        case .wait: "Wait before heavy runs"
        case .oneAtATime: "One heavy run at a time"
        case .clear: "Fine to push"
        }
    }

    var detail: String {
        switch self {
        case .wait: "Under \(Self.waitBelow)% free. Let tests, builds and pushes wait, or stop something below."
        case .oneAtATime: "Under \(Self.pushFrom)% free. Run one test, build or typecheck at a time; wait for \(Self.pushFrom)% to push."
        case .clear: "\(Self.pushFrom)% or more free. Still run heavy commands one at a time."
        }
    }
}

struct ProcessRow: Equatable, Sendable {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let residentKB: Int
    let cpu: Double
    let commandLine: String
    // The real executable (proc_pidpath); a process can rename itself in its command line.
    let path: String?

    // The command it was started as ("claude", "node", "-zsh" → "zsh"); when that is a path, the
    // real executable's name, since a path in the command line can contain spaces.
    var executableName: String {
        let launched = String(commandLine.split(separator: " ").first ?? "")
        let bare = launched.hasPrefix("-") ? String(launched.dropFirst()) : launched
        if !bare.isEmpty && !bare.contains("/") { return bare }
        return ((path ?? bare) as NSString).lastPathComponent
    }

    var isSystem: Bool { MachineParse.isSystem(path) }
}

struct ProcessGroup: Identifiable, Equatable, Sendable {
    let name: String
    // The app's bundle when the processes belong to an app; nil for a command-line tool.
    let appBundle: String?
    let processes: [ProcessRow]
    var id: String { appBundle ?? "tool:\(name)" }
    var residentBytes: Int64 { Int64(processes.reduce(0) { $0 + $1.residentKB }) * 1024 }
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
}

struct Listener: Identifiable, Equatable, Sendable {
    let process: ProcessRow
    let name: String
    let addresses: [String]
    var id: Int32 { process.pid }
    var ports: [String] { Array(Set(addresses.compactMap { $0.split(separator: ":").last.map(String.init) })).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) } }
}

struct SystemReading: Equatable, Sendable {
    var physicalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var diskAvailableBytes: Int64?
    var diskTotalBytes: Int64?

    static func current() -> SystemReading {
        var reading = SystemReading(physicalBytes: ProcessInfo.processInfo.physicalMemory)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            reading.swapUsedBytes = swap.xsu_used
            reading.swapTotalBytes = swap.xsu_total
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            reading.diskAvailableBytes = values.volumeAvailableCapacityForImportantUsage
            reading.diskTotalBytes = values.volumeTotalCapacity.map(Int64.init)
        }
        return reading
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
}

enum MachineParse {
    // `memory_pressure` ends with "System-wide memory free percentage: 39%".
    static func freePercent(_ output: String) -> Int? {
        guard let range = output.range(of: #"free percentage: [0-9]+%"#, options: .regularExpression) else { return nil }
        return Int(output[range].dropFirst("free percentage: ".count).dropLast())
    }

    // `ps -axo pid=,ppid=,uid=,rss=,%cpu=,args=`: the command line is the rest of the line.
    static func processes(_ output: String, path: (Int32) -> String?) -> [ProcessRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let uid = UInt32(fields[2]),
                  let rss = Int(fields[3]), let cpu = Double(fields[4]) else { return nil }
            return ProcessRow(pid: pid, ppid: ppid, uid: uid, residentKB: rss, cpu: cpu, commandLine: String(fields[5]), path: path(pid))
        }
    }

    // The outermost bundle: ".../Slack.app/.../Slack Helper.app/..." is "/Applications/Slack.app".
    static func bundlePath(_ path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func appName(_ bundle: String) -> String { ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension }

    // A process belongs to the app it runs from, or to the app that launched it before any shell did:
    // Raycast's node backend belongs to Raycast, a dev server started in a terminal belongs to nobody.
    static func ownerApp(_ row: ProcessRow, byPID: [Int32: ProcessRow]) -> String? {
        var current: ProcessRow? = row
        for _ in 0..<32 {
            guard let process = current else { return nil }
            if let bundle = bundlePath(process.path) { return bundle }
            if isShell(process.path) || process.ppid <= 1 { return nil }
            current = byPID[process.ppid]
        }
        return nil
    }

    static func groups(_ rows: [ProcessRow], limit: Int = 8) -> [ProcessGroup] {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: rows) { row in ownerApp(row, byPID: byPID).map { "app:\($0)" } ?? "tool:\(row.executableName)" }
            .map { key, rows in
                let bundle = key.hasPrefix("app:") ? String(key.dropFirst(4)) : nil
                return ProcessGroup(name: bundle.map(appName) ?? rows[0].executableName, appBundle: bundle,
                                    processes: rows.sorted { $0.residentKB > $1.residentKB })
            }
            .sorted { $0.residentBytes == $1.residentBytes ? $0.name < $1.name : $0.residentBytes > $1.residentBytes }
            .prefix(limit).map { $0 }
    }

    // `lsof -nP -iTCP -sTCP:LISTEN +c 0 -Fpcn` prints p<pid>, c<name>, then one n<address> per socket.
    // Without sudo it only lists this user's processes. Only standalone tools are kept: an app's own
    // servers (Raycast, AirPlay in ControlCenter) go with the app.
    static func listeners(_ output: String, processes: [ProcessRow]) -> [Listener] {
        var order: [Int32] = [], names: [Int32: String] = [:], addresses: [Int32: [String]] = [:]
        var current: Int32?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                current = Int32(value)
                if let pid = current, names[pid] == nil { order.append(pid); names[pid] = ""; addresses[pid] = [] }
            case "c": if let pid = current { names[pid] = value }
            case "n": if let pid = current, !(addresses[pid]?.contains(value) ?? true) { addresses[pid]?.append(value) }
            default: continue
            }
        }
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { pid in
            guard let process = byPID[pid], !isSystem(process.path), ownerApp(process, byPID: byPID) == nil else { return nil }
            let name = names[pid].flatMap { $0.isEmpty ? nil : $0 } ?? process.executableName
            return Listener(process: process, name: name, addresses: addresses[pid] ?? [])
        }
    }

    // An unknown path (another user's process, or one that already exited) counts as system.
    static func isSystem(_ path: String?) -> Bool {
        guard let path else { return true }
        let system = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/"]
        return system.contains { path.hasPrefix($0) }
    }

    static func isShell(_ path: String?) -> Bool {
        guard let path else { return false }
        return ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "login", "tmux", "screen"].contains((path as NSString).lastPathComponent)
    }

    // What the app may signal: your own processes outside the system, never the app itself.
    static func canSignal(_ row: ProcessRow, uid: UInt32 = getuid(), pid: Int32 = getpid()) -> Bool {
        row.uid == uid && row.pid != pid && !isSystem(row.path)
    }

    static func canQuit(_ group: ProcessGroup) -> Bool {
        guard let bundle = group.appBundle else { return false }
        return !bundle.hasPrefix("/System/") && !group.processes.contains { $0.pid == getpid() }
    }
}
