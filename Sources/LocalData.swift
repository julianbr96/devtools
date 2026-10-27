import Foundation
import CryptoKit
import Darwin

enum AccountColor: String, Codable, CaseIterable, Sendable {
    case peach, mint, blue, purple, pink, gold, gray
    var label: String { rawValue.capitalized }
}

struct AccountStyle: Codable, Equatable, Sendable {
    var nickname: String? = nil
    var color: AccountColor = .peach
    static func make(nickname: String, color: AccountColor) throws -> Self {
        let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 40, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DashboardError.message("Use a single-line name of up to 40 characters.")
        }
        return Self(nickname: clean.isEmpty ? nil : clean, color: color)
    }
}

extension Account {
    // Slot and CLI alias can change; actual login identity owns its appearance.
    var appearanceKey: String {
        let identity = try! JSONEncoder().encode([email, organizationUuid ?? ""])
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}

struct HistoryAccount: Codable, Equatable, Sendable {
    let name: String
    let email: String
    let organization: String
    let slot: Int
    let color: AccountColor
}

enum SwitchMethod: String, Codable, Sendable {
    case manual, bestAccount
    var label: String { self == .manual ? "Manual switch" : "Best-account switch" }
}

struct SwitchRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let from: HistoryAccount?
    let to: HistoryAccount
    let method: SwitchMethod
}

struct LocalArchive: Codable, Sendable {
    var schemaVersion = 1
    var styles: [String: AccountStyle] = [:]
    var history: [SwitchRecord] = []
    static let historyLimit = 100
    mutating func append(_ record: SwitchRecord) {
        history.insert(record, at: 0)
        history = Array(history.prefix(Self.historyLimit))
    }
}

struct LocalDataFile {
    let url: URL
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CSWAP", isDirectory: true)
            .appendingPathComponent("local-data.json")
    }
    func load() throws -> LocalArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return LocalArchive() }
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? 0) <= 2_000_000 else {
            throw DashboardError.message("Local CSWAP data is not a supported regular-sized file. It was left untouched.")
        }
        let archive = try JSONDecoder().decode(LocalArchive.self, from: Data(contentsOf: url))
        guard archive.schemaVersion == 1 else {
            throw DashboardError.message("Local data uses a newer format. Update CSWAP before editing it.")
        }
        return archive
    }
    func update(_ mutation: (inout LocalArchive) -> Void) throws -> LocalArchive {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("local-data.lock")
        let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw DashboardError.message("Could not open the local-data lock. Check folder permissions.") }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw DashboardError.message("Another CSWAP instance is updating local data. Try again.")
        }
        defer { flock(lockFD, LOCK_UN) }
        var archive = try load() // Never overwrite corrupt/newer data or another instance's changes.
        mutation(&archive)
        archive.history = Array(archive.history.prefix(LocalArchive.historyLimit))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        let temporary = directory.appendingPathComponent(".local-data-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DashboardError.message("Could not create a private local-data file. Check folder permissions.") }
        defer { Darwin.close(fd); try? fm.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw DashboardError.message("Could not write local data. Check disk space and permissions.") }
                offset += amount
            }
        }
        guard fsync(fd) == 0, Darwin.rename(temporary.path, url.path) == 0 else {
            throw DashboardError.message("Could not finish saving local data. The previous file was kept.")
        }
        return archive
    }
}
