import Testing
@testable import xcflow

struct ActionPinTests {
    let sha = String(repeating: "a", count: 40)

    @Test func usesPinsTheCommitWithTheVersionComment() {
        #expect(ActionPin(version: "0.2.8", commit: sha).uses == "OlafAndreas/xcflow-action@\(sha) # v0.2.8")
    }

    @Test func usesFallsBackToTheTag() {
        #expect(ActionPin(version: "0.2.8", commit: nil).uses == "OlafAndreas/xcflow-action@v0.2.8")
    }

    @Test func parseReadsACommitPin() {
        #expect(ActionPin.parse("steps:\n  - uses: OlafAndreas/xcflow-action@\(sha) # v0.2.9\n") == ActionPin(version: "0.2.9", commit: sha))
    }

    @Test func parseReadsATagPin() {
        #expect(ActionPin.parse("  uses: OlafAndreas/xcflow-action@v0.2.9\n") == ActionPin(version: "0.2.9", commit: nil))
    }

    @Test func parseIgnoresOtherInstallSteps() {
        #expect(ActionPin.parse("  uses: ./.github/actions/xcflow\n") == nil)
        #expect(ActionPin.parse("  uses: someone/xcflow-action@v0.2.9\n") == nil)
    }

    @Test func versionsCompareNumerically() {
        #expect(ActionPin.isNewer("0.10.0", than: "0.9.1"))
        #expect(ActionPin.isNewer("0.2.8.1", than: "0.2.8"))
        #expect(ActionPin.isNewer("1.0", than: "0.9.9"))
        #expect(!ActionPin.isNewer("0.2.8", than: "0.2.8"))
        #expect(!ActionPin.isNewer("0.2.7", than: "0.2.8"))
    }

    @Test func lsRemotePrefersThePeeledTag() {
        let tag = String(repeating: "b", count: 40), commit = String(repeating: "c", count: 40)
        #expect(ActionPin.commit(fromLsRemote: "\(tag)\trefs/tags/v0.2.8\n\(commit)\trefs/tags/v0.2.8^{}\n") == commit)
        #expect(ActionPin.commit(fromLsRemote: "\(commit)\trefs/tags/v0.2.8\n") == commit)
        #expect(ActionPin.commit(fromLsRemote: "") == nil)
    }
}
