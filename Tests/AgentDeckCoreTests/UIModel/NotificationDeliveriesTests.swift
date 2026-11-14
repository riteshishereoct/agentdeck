import XCTest
@testable import AgentDeckCore

final class NotificationDeliveriesTests: XCTestCase {
    func testOldPrivacyCompletionCannotRemoveReplacement() throws {
        for failed in [false, true] {
            var deliveries = NotificationDeliveries()
            _ = deliveries.synchronize(activeIds: ["request"])
            let old = try XCTUnwrap(deliveries.begin(requestId: "request", expectedGeneration: deliveries.generation))
            XCTAssertEqual(deliveries.synchronize(activeIds: ["request"], reset: true), [old.identifier])
            let replacement = try XCTUnwrap(deliveries.begin(requestId: "request", expectedGeneration: deliveries.generation))
            XCTAssertNotEqual(old.identifier, replacement.identifier)
            XCTAssertEqual(deliveries.finish(old, failed: failed), old.identifier)
            XCTAssertNil(deliveries.finish(replacement, failed: false))
            XCTAssertEqual(deliveries.synchronize(activeIds: []), [replacement.identifier])
        }
    }
    func testStaleAuthorizationAndResolvedRequestNeverPost() throws {
        var deliveries = NotificationDeliveries()
        _ = deliveries.synchronize(activeIds: ["request"])
        let beforePrivacy = deliveries.generation
        _ = deliveries.synchronize(activeIds: ["request"], reset: true)
        XCTAssertNil(deliveries.begin(requestId: "request", expectedGeneration: beforePrivacy))
        let current = try XCTUnwrap(deliveries.begin(requestId: "request", expectedGeneration: deliveries.generation))
        _ = deliveries.synchronize(activeIds: [])
        XCTAssertEqual(deliveries.finish(current, failed: false), current.identifier)
        XCTAssertNil(deliveries.begin(requestId: "request", expectedGeneration: deliveries.generation))
    }
}
