import Foundation

/// The composite action that older versions of `setup` wrote into each repo. It is frozen here only so that an untouched copy can be recognised and removed.
enum LegacyAction {
    static let path = ".github/actions/xcflow/action.yml"

    static func archives(version: String) -> [String: String] {
        [
            "linux-x86_64": "xcflow-\(version)-linux-x86_64.tar.gz",
            "linux-aarch64": "xcflow-\(version)-linux-aarch64.tar.gz"
        ]
    }

    static func render(version: String, checksums: [String: String]) -> String {
        var install = template.replacingOccurrences(of: "{{version}}", with: version)
        for (platform, archive) in archives(version: version) {
            install = install
                .replacingOccurrences(of: "{{archive-\(platform)}}", with: archive)
                .replacingOccurrences(of: "{{checksum-\(platform)}}", with: checksums[archive] ?? "")
        }
        return install
    }

    /// Whether `content` is byte for byte what `setup` wrote: the frozen template rendered with the version and checksums found in the file itself.
    static func isUntouched(_ content: String) -> Bool {
        guard let version = content.firstMatch(of: /Install xcflow (\d+\.\d+\.\d+)/)?.1 else {
            return false
        }
        var checksums: [String: String] = [:]
        for match in content.matches(of: /NAME="([^"]+)"; SUM="([0-9a-f]*)"/) {
            checksums[String(match.1)] = String(match.2)
        }
        return render(version: String(version), checksums: checksums) == content
    }

    enum Removal: Equatable {
        case removed, kept, absent
    }

    /// Deletes the action when it is untouched, or whenever `force` is set, and then the folders it leaves empty. A dry run decides the same way and deletes nothing.
    static func remove(in root: URL, force: Bool, dryRun: Bool) throws -> Removal {
        let file = root.appending(path: path)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return .absent
        }
        let content = try String(contentsOf: file, encoding: .utf8)
        guard force || isUntouched(content) else {
            return .kept
        }
        if !dryRun {
            try FileManager.default.removeItem(at: file)
            for folder in [".github/actions/xcflow", ".github/actions"] {
                let url = root.appending(path: folder)
                if try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)).isEmpty {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        return .removed
    }

    /// The live source of the action is `Action/action.yml`, which the release workflow renders and
    /// pushes to `OlafAndreas/xcflow-action`. This copy is frozen, for recognising the files written
    /// by xcflow 0.2.1 through 0.2.7.
    private static let template = #"""
    name: Install xcflow
    description: Installs the pinned xcflow release on a Linux runner. xcflow plans and applies the Xcode Cloud workflows in XcodeCloud/.

    runs:
      using: composite
      steps:
        - name: Install xcflow {{version}}
          shell: bash
          run: |
            case "$RUNNER_OS-$RUNNER_ARCH" in
              Linux-X64) NAME="{{archive-linux-x86_64}}"; SUM="{{checksum-linux-x86_64}}" ;;
              Linux-ARM64) NAME="{{archive-linux-aarch64}}"; SUM="{{checksum-linux-aarch64}}" ;;
              *) echo "::error::This action installs xcflow on Linux runners only, not on $RUNNER_OS $RUNNER_ARCH. Use runs-on: ubuntu-latest."; exit 1 ;;
            esac
            ARCHIVE="$RUNNER_TEMP/xcflow.tar.gz"
            curl -fsSL -o "$ARCHIVE" "https://github.com/OlafAndreas/xcflow/releases/download/v{{version}}/$NAME"
            if [ -n "$SUM" ]; then
              echo "$SUM  $ARCHIVE" | shasum -a 256 -c -
            fi
            mkdir -p "$RUNNER_TEMP/xcflow"
            tar -xzf "$ARCHIVE" -C "$RUNNER_TEMP/xcflow"
            echo "$RUNNER_TEMP/xcflow" >> "$GITHUB_PATH"
            "$RUNNER_TEMP/xcflow/xcflow" --version

    """#
}
