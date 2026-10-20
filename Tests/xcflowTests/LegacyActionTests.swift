import Foundation
import Testing
@testable import xcflow

struct LegacyActionTests {
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: ".github/actions/xcflow"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ content: String, in root: URL) throws {
        try content.write(to: root.appending(path: LegacyAction.path), atomically: true, encoding: .utf8)
    }

    private func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }

    @Test func renderPicksTheArchiveForTheRunner() {
        let pinned = LegacyAction.render(version: "1.2.3", checksums: [
            "xcflow-1.2.3-linux-x86_64.tar.gz": "2" + String(repeating: "0", count: 63),
            "xcflow-1.2.3-linux-aarch64.tar.gz": "3" + String(repeating: "0", count: 63)
        ])
        #expect(pinned.contains("releases/download/v1.2.3/$NAME"))
        #expect(pinned.contains(#"Linux-X64) NAME="xcflow-1.2.3-linux-x86_64.tar.gz"; SUM="2"#))
        #expect(pinned.contains(#"Linux-ARM64) NAME="xcflow-1.2.3-linux-aarch64.tar.gz"; SUM="3"#))
        #expect(!pinned.contains("macOS-"))
        #expect(!pinned.contains("xcflow-1.2.3.tar.gz"))
        #expect(pinned.contains("Linux runners only"))
        #expect(!pinned.contains("{{"))

        let unpinned = LegacyAction.render(version: "1.2.3", checksums: [:])
        #expect(unpinned.contains(#"SUM="" ;;"#))
        #expect(!unpinned.contains("{{"))
    }

    @Test func anUntouchedActionIsRecognised() {
        let sums = ["xcflow-0.2.6-linux-x86_64.tar.gz": String(repeating: "1", count: 64), "xcflow-0.2.6-linux-aarch64.tar.gz": String(repeating: "2", count: 64)]
        #expect(LegacyAction.isUntouched(LegacyAction.render(version: "0.2.6", checksums: sums)))
        #expect(LegacyAction.isUntouched(LegacyAction.render(version: "0.2.6", checksums: [:])))
    }

    @Test func anEditedActionIsNot() {
        let pristine = LegacyAction.render(version: "0.2.6", checksums: [:])
        #expect(!LegacyAction.isUntouched(pristine + "# edited\n"))
        #expect(!LegacyAction.isUntouched(pristine.replacing("OlafAndreas", with: "someone")))
        #expect(!LegacyAction.isUntouched("name: Install xcflow\n"))
    }

    @Test func removeDeletesAnUntouchedActionAndItsEmptyFolders() throws {
        let root = try makeRepo()
        try write(LegacyAction.render(version: "0.2.6", checksums: [:]), in: root)
        #expect(try LegacyAction.remove(in: root, force: false, dryRun: false) == .removed)
        #expect(!exists(".github/actions", in: root))
        #expect(exists(".github", in: root))
    }

    @Test func removeKeepsAnEditedActionUnlessForced() throws {
        let root = try makeRepo()
        try write(LegacyAction.render(version: "0.2.6", checksums: [:]) + "# edited\n", in: root)
        #expect(try LegacyAction.remove(in: root, force: false, dryRun: false) == .kept)
        #expect(exists(LegacyAction.path, in: root))
        #expect(try LegacyAction.remove(in: root, force: true, dryRun: false) == .removed)
        #expect(!exists(LegacyAction.path, in: root))
    }

    @Test func removeInADryRunTouchesNothing() throws {
        let root = try makeRepo()
        try write(LegacyAction.render(version: "0.2.6", checksums: [:]), in: root)
        #expect(try LegacyAction.remove(in: root, force: false, dryRun: true) == .removed)
        #expect(exists(LegacyAction.path, in: root))
    }

    @Test func removeReportsAnAbsentAction() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(try LegacyAction.remove(in: root, force: false, dryRun: false) == .absent)
    }
}
