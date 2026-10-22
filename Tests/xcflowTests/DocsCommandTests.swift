import Foundation
import Testing
@testable import xcflow

struct DocsCommandTests {
    private func content(_ path: String) -> String {
        Templates.docs.first { $0.path == path }?.content ?? ""
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func rewritesTheStaleDocsAndLeavesClaudeOutOfARepoWithoutIt() throws {
        let root = try Fixtures.makeRepo()
        try write("old", to: "XcodeCloud/README.md", in: root)
        #expect(try DocsCommand.refresh(in: root, write: true) == ["XcodeCloud/README.md"])
        #expect(try String(contentsOf: root.appending(path: "XcodeCloud/README.md"), encoding: .utf8) == content("XcodeCloud/README.md"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".claude").path(percentEncoded: false)))
        #expect(try DocsCommand.refresh(in: root, write: true).isEmpty)
    }

    @Test func keepsBothClaudeFilesWhenTheRepoHasOne() throws {
        let root = try Fixtures.makeRepo()
        try write(content("XcodeCloud/README.md"), to: "XcodeCloud/README.md", in: root)
        try write("old skill", to: ".claude/skills/edit-xcode-cloud-workflow/SKILL.md", in: root)
        #expect(try DocsCommand.refresh(in: root, write: true) == [".claude/skills/edit-xcode-cloud-workflow/SKILL.md", ".claude/rules/xcode-cloud.md"])
        #expect(try String(contentsOf: root.appending(path: ".claude/rules/xcode-cloud.md"), encoding: .utf8) == content(".claude/rules/xcode-cloud.md"))
    }

    @Test func checkListsWithoutWriting() throws {
        let root = try Fixtures.makeRepo()
        try write("old", to: "XcodeCloud/README.md", in: root)
        var out: [String] = []
        #expect(DocsCommand.run(arguments: ["--check"], root: root, out: { out.append($0) }) == 1)
        #expect(out == ["Out of date XcodeCloud/README.md"])
        #expect(try String(contentsOf: root.appending(path: "XcodeCloud/README.md"), encoding: .utf8) == "old")
    }

    @Test func theSkillLoadsItsBodyFromTheInstalledXcflow() {
        let stub = content(".claude/skills/edit-xcode-cloud-workflow/SKILL.md")
        #expect(stub.contains("allowed-tools: Bash(xcflow guide skill)"))
        #expect(stub.contains("\n!`xcflow guide skill`\n"))
        #expect(Templates.skillGuide.hasPrefix("# Edit an Xcode Cloud workflow"))
        #expect(Templates.skillGuide.contains("xcflow add pr-checks"))
    }
}
