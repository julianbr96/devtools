import Foundation

@main struct TestMain {
    @MainActor
    static func main() async throws {
        try await CSWAPTests.run()
        try await VPNTests.run()
    }
}
