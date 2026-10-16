enum Usage {
    static let text = """
    xcflow \(Version.current): Xcode Cloud workflows as JSON files in your repo.

    Usage: xcflow <command>
      setup [--dry-run] [--yes] [--force] [--products <bundle id,…>] [--skip-export] [--skip-secrets] [--checksums <file>]
                                        Add the workflow files, GitHub Actions, Claude skill and rule, and MCP entry to this repo.
      auth --key-id <KEY_ID> --p8 <path> Store your App Store Connect API key in the Keychain.
      plan [--dry-run <folder>]         Validate XcodeCloud/ and show what would change in Xcode Cloud.
      apply [--dry-run <folder>]        Make those changes. The GitHub Action runs this on the default branch.
      export [<bundle id> …]            Write the live workflows to XcodeCloud/.
      get <path> [key=value …]          Print a raw App Store Connect API response.
      --version                         Print the version.

    Run with no command, xcflow is an MCP server for Claude Code and other MCP clients.

    """
}
