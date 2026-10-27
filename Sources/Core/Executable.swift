import Foundation

enum Executable {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // The first candidate that exists and is executable, else the first one, so "not found" names it.
    static func first(_ candidates: [String]) -> String {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    // A path that may go into a shell or AppleScript command: letters, digits, '.', '_', '-' and '/' only.
    static func isPlainPath(_ path: String) -> Bool {
        path.range(of: #"^/[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil && !path.contains("..")
    }
}
