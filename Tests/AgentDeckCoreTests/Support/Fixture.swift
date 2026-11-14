import Foundation
@testable import AgentDeckCore

enum Fixture {
    static func data(_ relativePath: String) -> Data {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
        return try! Data(contentsOf: url)
    }
    static func hookInput(_ name: String) -> HookInput { try! HookInput.decode(data("hooks/\(name).json")) }
}
