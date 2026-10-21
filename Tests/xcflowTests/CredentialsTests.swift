import Foundation
import Testing
@testable import xcflow

struct CredentialsTests {
    @Test func anIssuerRoundTrips() {
        #expect(CredentialStore.issuerID(fromGeneric: CredentialStore.genericAttribute(issuerID: "2ae5d17c")) == "2ae5d17c")
    }

    @Test func anIndividualKeyHasNoAttribute() {
        #expect(CredentialStore.genericAttribute(issuerID: nil) == nil)
        #expect(CredentialStore.genericAttribute(issuerID: "") == nil)
    }

    @Test func legacyAndGarbageAttributesReadAsNoIssuer() {
        let attributes: [Data?] = [nil, Data([0xFF]), Data("{}".utf8), Data(#"{"issuerID":""}"#.utf8)]
        for attribute in attributes {
            #expect(CredentialStore.issuerID(fromGeneric: attribute) == nil)
        }
    }
}

struct KeyStoreTests {
    private func key(_ id: String, issuer: String? = nil) -> Credentials {
        Credentials(keyID: id, privateKeyPEM: "pem-\(id)", issuerID: issuer)
    }

    @Test func severalKeysLiveSideBySideSortedWithTheirKind() throws {
        let store = FakeKeys()
        try store.save(key("ZED", issuer: "issuer"))
        try store.save(key("ABC"))
        #expect(try store.keys() == [StoredKey(keyID: "ABC", isTeamKey: false, stored: nil), StoredKey(keyID: "ZED", isTeamKey: true, stored: nil)])
    }

    @Test func savingAKeyTwiceReplacesOnlyThatKey() throws {
        let store = FakeKeys(key("ABC"), key("ZED"))
        try store.save(Credentials(keyID: "ABC", privateKeyPEM: "new", issuerID: "issuer"))
        #expect(try store.keys().count == 2)
        #expect(try store.load(keyID: "ABC").privateKeyPEM == "new")
        #expect(try store.load(keyID: "ZED").privateKeyPEM == "pem-ZED")
    }

    @Test func removingAKeyLeavesTheOthers() throws {
        let store = FakeKeys(key("ABC"), key("ZED"))
        try store.remove(keyID: "ABC")
        #expect(try store.keys().map(\.keyID) == ["ZED"])
        #expect(throws: CredentialError.self) { try store.load(keyID: "ABC") }
    }
}
