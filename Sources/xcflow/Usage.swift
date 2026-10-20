enum Usage {
    static let text = """
    xcflow \(Version.current): Xcode Cloud workflows as JSON files in your repo.

    Usage: xcflow <command>
      setup [--dry-run] [--yes] [--force] [--products <bundle id,…>] [--skip-export] [--skip-secrets] [--replace-secrets] [--claude]
            [--key-id <id> --issuer-id <id> --p8 <path>] [--action-sha <sha>]
                                        Add the workflow files and GitHub Actions to this repo. --claude also adds the Claude Code skill, rule and MCP entry.
                                        One team key does it all: kept for xcflow, used for the export, set as the GitHub secrets.
                                        Asked for in a terminal when none is stored, or given with the three flags.
      auth --key-id <KEY_ID> --p8 <path> Store your App Store Connect API key in the Keychain.
      plan [--dry-run <folder>]         Validate XcodeCloud/ and show what would change in Xcode Cloud.
      apply [--dry-run <folder>]        Make those changes. The GitHub Action runs this on the default branch.
      export [<bundle id> …]            Write the live workflows to XcodeCloud/. Without ids: the products already there,
                                        or the ones in the project's Xcode Cloud manifest.
      get <path> [key=value …]          Print a raw App Store Connect API response.
      --version                         Print the version.

    Run with no command, xcflow is an MCP server for Claude Code and other MCP clients.

    """
}
