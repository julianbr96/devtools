import Foundation

@main struct TestMain {
    @MainActor
    static func main() async throws {
        try await SharedTests.run()
        try await CSWAPTests.run()
        try await VPNTests.run()
        try await MachineTests.run()
        try await AWSTests.run()
        try await CLILoginTests.run()
    }
}
