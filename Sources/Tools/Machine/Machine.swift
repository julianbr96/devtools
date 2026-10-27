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
    let residentKB: Int
    let cpu: Double
    let command: String
}

struct ProcessGroup: Identifiable, Equatable, Sendable {
    let name: String
    let residentBytes: Int64
    let cpu: Double
    let count: Int
    var id: String { name }
}

struct Listener: Identifiable, Equatable, Sendable {
    let pid: Int32
    let name: String
    let command: String
    let addresses: [String]
    var id: Int32 { pid }
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
}

enum MachineParse {
    // `memory_pressure` ends with "System-wide memory free percentage: 39%".
    static func freePercent(_ output: String) -> Int? {
        guard let range = output.range(of: #"free percentage: [0-9]+%"#, options: .regularExpression) else { return nil }
        return Int(output[range].dropFirst("free percentage: ".count).dropLast())
    }

    // `ps -axo pid=,rss=,%cpu=,comm=`: the command is the rest of the line and may contain spaces.
    static func processes(_ output: String) -> [ProcessRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let rss = Int(fields[1]), let cpu = Double(fields[2]) else { return nil }
            return ProcessRow(pid: pid, residentKB: rss, cpu: cpu, command: String(fields[3]))
        }
    }

    // An app's helpers count as the app: ".../Slack.app/.../Slack Helper.app/..." is "Slack".
    static func appName(_ command: String) -> String {
        if let range = command.range(of: #"[^/]+\.app/"#, options: .regularExpression) {
            return String(command[range].dropLast(5))
        }
        return (command as NSString).lastPathComponent
    }

    static func groups(_ rows: [ProcessRow], limit: Int = 8) -> [ProcessGroup] {
        Dictionary(grouping: rows, by: { appName($0.command) })
            .map { name, rows in
                ProcessGroup(name: name, residentBytes: Int64(rows.reduce(0) { $0 + $1.residentKB }) * 1024,
                             cpu: rows.reduce(0) { $0 + $1.cpu }, count: rows.count)
            }
            .sorted { $0.residentBytes == $1.residentBytes ? $0.name < $1.name : $0.residentBytes > $1.residentBytes }
            .prefix(limit).map { $0 }
    }

    // `lsof -nP -iTCP -sTCP:LISTEN +c 0 -Fpcn` prints p<pid>, c<name>, then one n<address> per socket.
    // Without sudo it only lists this user's processes.
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
        let commands = Dictionary(processes.map { ($0.pid, $0.command) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { pid in
            let command = commands[pid] ?? names[pid] ?? ""
            guard isOwnTool(command) else { return nil }
            return Listener(pid: pid, name: names[pid].flatMap { $0.isEmpty ? nil : $0 } ?? appName(command), command: command, addresses: addresses[pid] ?? [])
        }
    }

    // Dev servers and databases you started, never macOS services or GUI apps listening on a port.
    static func isOwnTool(_ command: String) -> Bool {
        let system = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/"]
        return !command.isEmpty && !system.contains { command.hasPrefix($0) } && !command.contains(".app/")
    }
}
