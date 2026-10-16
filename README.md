<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/wordmark-dark.svg">
    <img src="Assets/wordmark.svg" alt="xcflow" width="440">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/OlafAndreas/xcflow/actions/workflows/ci.yml"><img src="https://github.com/OlafAndreas/xcflow/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/OlafAndreas/xcflow/releases/latest"><img src="https://img.shields.io/github/v/release/OlafAndreas/xcflow?color=6B4FB3&label=release" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2F5F9E.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/Swift-6.3%2B-1B8A8F.svg" alt="Swift 6.3+">
  <img src="https://img.shields.io/badge/platforms-macOS-2F5F9E.svg" alt="macOS">
</p>

Xcode Cloud workflows as JSON files in your repo. Review workflow changes in pull requests, apply them when they merge, and get a pull request when someone changes a workflow by hand in App Store Connect.

xcflow is a command-line tool and an MCP server for the App Store Connect API. It is not made by or affiliated with Apple.

## Install

```bash
brew install olafandreas/tap/xcflow
```

## Set up a repo

1. Create an App Store Connect API key for yourself: your profile (top right) → **Edit Profile** → **Individual API Key** → **Generate API Key**. Then store it in your Keychain:

   ```bash
   xcflow auth --key-id <KEY_ID> --p8 ~/Downloads/AuthKey_<KEY_ID>.p8
   ```

2. From the repo root, run:

   ```bash
   xcflow setup --dry-run   # see what it would add
   xcflow setup
   ```

   `setup` asks before each step that calls App Store Connect or GitHub, and never overwrites a changed file without asking. It adds:

   - `XcodeCloud/<bundle id>/*.json`: one file per workflow, exported from the products you pick, plus a README on the format.
   - `.github/workflows/xcflow-plan.yml`, `xcflow-apply.yml` and `xcflow-sync.yml`, and `.github/actions/xcflow/`, which installs a pinned xcflow release on the runner.
   - `.claude/skills/edit-xcode-cloud-workflow/` and `.claude/rules/xcode-cloud.md`, so Claude Code changes workflows through the files.
   - An `xcflow` entry in `.mcp.json`.
   - Optionally, the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` secrets on the GitHub repo, from a team API key. The key's role must be allowed to edit Xcode Cloud workflows: Admin, or App Manager with Xcode Cloud access.

   Run it again at any time; files that already match are left alone.

## How it works

- **Pull requests:** `xcflow plan` validates the files and compares them with Xcode Cloud. The PR check posts the result as a comment: what will be created, updated or deleted. It only reads from App Store Connect.
- **Merge:** a push to the default branch that changes `XcodeCloud/` runs `xcflow apply`, which makes those changes.
- **Every night:** `xcflow export` writes the live workflows to the files. If they differ, the sync job opens a pull request. Merge it to accept the change, or run the apply workflow to undo it in Xcode Cloud.

Only products with a folder in `XcodeCloud/` are managed. Deleting a workflow's file deletes the workflow, together with its build history.

## Commands

| Command | What it does |
|---|---|
| `xcflow setup` | Adds the files above to the current repo. |
| `xcflow auth --key-id <id> --p8 <path>` | Checks a key against App Store Connect and stores it in the Keychain. |
| `xcflow plan` | Validates `XcodeCloud/` and prints what would change. Reads only. |
| `xcflow apply` | Makes those changes. Meant for CI on the default branch. |
| `xcflow export [<bundle id> …]` | Writes the live workflows to `XcodeCloud/`. |
| `xcflow get <path> [key=value …]` | Prints a raw App Store Connect API response. |

`--dry-run <folder>` with `plan`, `apply` or `export` answers from the workflow files in that folder instead of the API, and prints every request it would send. Nothing is sent and no key is needed. Copy `XcodeCloud/` before editing and pass the copy to see exactly what a change would do.

In CI, the key comes from the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` (base64 of the `.p8`) environment variables instead of the Keychain. Reads that App Store Connect fails with a 5xx or 429 are retried; writes never are.

## MCP server

Run with no command, xcflow is an MCP server. `setup` registers it in `.mcp.json`, so it starts in Claude Code in that repo.

- **Builds:** `list_workflows`, `list_builds`, `get_build` (action results, compiler errors, failing tests), `get_build_logs`, `start_build`.
- **Workflows:** `get_workflow` shows the live configuration and the file that defines it, and `list_environments` lists the Xcode and macOS versions. The MCP server never changes workflows; that goes through the files.
- **Apps:** the first time a tool runs, you choose which apps it shows. `choose_apps` changes the choice.

## License

MIT
