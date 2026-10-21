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
