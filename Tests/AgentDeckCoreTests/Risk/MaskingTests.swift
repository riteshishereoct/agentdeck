import XCTest
@testable import AgentDeckCore

final class MaskingTests: XCTestCase {
    func testBearerSkAndAkiaKeepFirstFourPlusDots() {
        XCTAssertEqual(Masking.mask("curl -H 'Authorization: Bearer abcdefghijklmnop1234' x"), "curl -H 'Authorization: Bearer abcd••••' x")
        XCTAssertEqual(Masking.mask("key=sk-abcdefghijklmnopqrstuvwx rest"), "key=sk-a•••• rest")
        XCTAssertEqual(Masking.mask("id AKIAIOSFODNN7EXAMPLE end"), "id AKIA•••• end")
    }
    func testShortOrEmbeddedLookalikesAreUntouchedAndMaskIsIdempotent() {
        for s in ["sk-short", "task-abcdefghijklmnopqrstuvwx", "Bearer abc", "plain text"] { XCTAssertEqual(Masking.mask(s), s) }
        let m = Masking.mask("Bearer abcdefghijklmnop1234 sk-abcdefghijklmnopqrstuvwx")
        XCTAssertEqual(Masking.mask(m), m)
        XCTAssertFalse(m.contains("efgh"))
    }
}

final class MaskingMoreTests: XCTestCase {
    func testMoreCredentialShapesAreMaskedAndIdempotent() {
        let cases: [(String, String)] = [
            ("git push https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@x", "git push https://ghp_••••@x"),
            ("t=github_pat_11ABCDEFG0123456789_abcdefghij", "t=github_pat_••••"),
            ("slack xoxb-1234567890-abcdefghij end", "slack xoxb-•••• end"),
            ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abcDEF123_- ok", "jwt eyJ•••• ok"),
            ("psql postgres://admin:hunter2pass@db:5432/x", "psql postgres://admin:••••@db:5432/x"),
            ("API_KEY=abc123 DB_PASSWORD='p@ss w' AWS_SECRET_ACCESS_KEY=xyz", "API_KEY=•••• DB_PASSWORD=•••• AWS_SECRET_ACCESS_KEY=••••"),
            ("-----BEGIN RSA PRIVATE KEY-----\nMIIabc\ndef\n-----END RSA PRIVATE KEY-----\nafter",
             "-----BEGIN RSA PRIVATE KEY-----••••-----END RSA PRIVATE KEY-----\nafter"),
            ("-----BEGIN PRIVATE KEY-----\nMIIcut", "-----BEGIN PRIVATE KEY-----••••-----END PRIVATE KEY-----"),
        ]
        for (raw, want) in cases {
            XCTAssertEqual(Masking.mask(raw), want, raw)
            XCTAssertEqual(Masking.mask(want), want, "idempotent: \(raw)")
        }
    }
    func testOrdinaryCodeAndVariableReferencesStayReadable() {
        for s in ["let token = request.token", "export API_KEY=$API_KEY", "https://example.com/a:b@c", "monkey=banana", "ghp_short"] {
            XCTAssertEqual(Masking.mask(s), s)
        }
    }
}
