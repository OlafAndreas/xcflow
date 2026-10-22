enum Usage {
    static let text = """
    xcflow \(Version.current): Xcode Cloud workflows as JSON files in your repo.

    Usage: xcflow <command>
      setup [--dry-run] [--yes] [--force] [--products <bundle id,…>] [--skip-export] [--skip-secrets] [--replace-secrets] [--claude]
            [--key-id <id> --issuer-id <id> --p8 <path>] [--action-sha <sha>]
                                        Add the workflow files and GitHub Actions to this repo. --claude also adds the Claude Code skill, rule and MCP entry.
                                        One team key does it all: kept for xcflow, used for the export, set as the GitHub secrets.
                                        Asked for in a terminal when none is stored, or given with the three flags.
      auth --key-id <KEY_ID> --p8 <path> [--issuer-id <id>] Store your App Store Connect API key in the Keychain.
      keys [use <key id> | remove <key id>]
                                        List the stored keys, pin this repo to one on this machine, or remove one.
      add <pr-checks | nightly-tests | testflight-on-tag> [--product <bundle id>] [--scheme <name>] [--name <name>] [--root <folder>]
                                        Write a new workflow file from a preset, copying the project and versions from an existing one.
      plan [--dry-run <folder>]         Validate XcodeCloud/ and show what would change in Xcode Cloud.
      apply [--dry-run <folder>]        Make those changes. The GitHub Action runs this on the default branch.
      export [<bundle id> …]            Write the live workflows to XcodeCloud/. Without ids: the products already there,
                                        or the ones in the project's Xcode Cloud manifest.
      builds [<workflow>] [--branch <name>] [--limit <n>] [--product <bundle id> | --all] [--root <folder>]
                                        List recent builds, newest first.
      build <number or id> [--wait] [--timeout <minutes>] [--product <bundle id> | --all] [--root <folder>]
                                        Show a build: its actions, compiler errors and failing tests.
      logs <number or id> [--action <name>] [--product <bundle id> | --all] [--root <folder>]
                                        Download a build's logs and print where they went.
      run <workflow> (--branch <name> | --tag <name>) [--clean] [--wait] [--timeout <minutes>] [--product <bundle id> | --all] [--root <folder>]
                                        Start a build. With --wait, also wait for it to finish.
                                        --wait exits 0 when the build succeeded, 1 when it failed, 2 when it couldn't finish, 124 on timeout.
      get <path> [key=value …]          Print a raw App Store Connect API response.
      --version                         Print the version.

    Run with no command, xcflow is an MCP server for Claude Code and other MCP clients.

    """
}
