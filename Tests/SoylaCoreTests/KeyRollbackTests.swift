import Testing
@testable import SoylaCore

/// Regression pass 2026-10-20: a key the service rejects must not stay on file, and Replace… with a bad key must
/// not cost the user their good one.
@Suite("A rejected key is rolled back")
struct KeyRollbackTests {
    @Test func acceptedKeyIsKept() {
        #expect(KeyRollback.action(rejected: false, previous: "AIzaFAKE1111", previousVerified: true) == .keep)
        #expect(KeyRollback.action(rejected: false, previous: nil, previousVerified: false) == .keep)
    }

    @Test func rejectedFirstKeyIsRemoved() {
        #expect(KeyRollback.action(rejected: true, previous: nil, previousVerified: false) == .remove)
    }

    @Test func rejectedReplacementRestoresTheOldKey() {
        #expect(KeyRollback.action(rejected: true, previous: "AIzaFAKE1111", previousVerified: true)
            == .restore("AIzaFAKE1111", verified: true))
        #expect(KeyRollback.action(rejected: true, previous: "AIzaFAKE1111", previousVerified: false)
            == .restore("AIzaFAKE1111", verified: false))
    }
}
