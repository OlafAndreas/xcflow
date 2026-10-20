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
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-2F5F9E.svg" alt="macOS, Linux">
</p>

Xcode Cloud workflows as JSON files in your repo. Review workflow changes in pull requests, apply them when they merge, and get a pull request when someone changes a workflow by hand in App Store Connect.

xcflow is a command-line tool and an MCP server for the App Store Connect API. It is not made by or affiliated with Apple.

## Install

```bash
brew install olafandreas/tap/xcflow
```

Homebrew installs the macOS build. Each release also has Linux builds for x86_64 and arm64, with the Swift runtime linked in. The GitHub Actions that `setup` adds run on `ubuntu-latest` and download the right one, so CI needs no macOS runners.

## Set up a repo

Xcode Cloud has to be switched on for the app first: create its first workflow in Xcode (**Product → Xcode Cloud → Create Workflow…**) or in App Store Connect. That step also connects the repository, and the App Store Connect API can't do either. Xcode then records the product in `<project>.xcodeproj/xcshareddata/xcodecloud/manifest.json`; commit that file, because it is how `setup` and `export` find the products to manage.

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

   - `XcodeCloud/<bundle id>/*.json`: one file per workflow, exported from the products in the project's Xcode Cloud manifest, or from the ones you pass with `--products`, plus a README on the format.
   - `.github/workflows/xcflow-plan.yml`, `xcflow-apply.yml` and `xcflow-sync.yml`, running on `ubuntu-latest` and installing xcflow from `OlafAndreas/xcflow-action`, pinned to a commit.
   - `.github/dependabot.yml`, so Dependabot opens a pull request when a new xcflow is out. The plan check doesn't run on those pull requests, because they can't read the repo's secrets; the apply on the default branch is the first run of the new version in that repo.
   - `.claude/skills/edit-xcode-cloud-workflow/` and `.claude/rules/xcode-cloud.md`, so Claude Code changes workflows through the files.
   - An `xcflow` entry in `.mcp.json`.
   - Optionally, the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` secrets on the GitHub repo, from a team API key. `setup` checks first and skips this step when all three are already set; `--replace-secrets` sets them again. In a terminal it asks for the key id, issuer id and `.p8` path; pass `--key-id`, `--issuer-id` and `--p8` to set them without being asked, which is what an agent or a script needs. The key's role must be allowed to edit Xcode Cloud workflows: Admin, or App Manager with Xcode Cloud access.

   Run it again at any time; files that already match are left alone, and a newer pin that Dependabot made is kept.

   A repo set up by an earlier xcflow loses its `.github/actions/xcflow/` on the next `setup` if the file is untouched, or gets a to-do if it was edited.

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
| `xcflow export [<bundle id> …]` | Writes the live workflows to `XcodeCloud/`. Without ids: the products already there, or the ones in the project's Xcode Cloud manifest. |
| `xcflow get <path> [key=value …]` | Prints a raw App Store Connect API response. |

`--dry-run <folder>` with `plan`, `apply` or `export` answers from the workflow files in that folder instead of the API, and prints every request it would send. Nothing is sent and no key is needed. Copy `XcodeCloud/` before editing and pass the copy to see exactly what a change would do.

In CI, the key comes from the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` (base64 of the `.p8`) environment variables instead of the Keychain. On Linux, which has no Keychain, the environment variables are the only way. Reads that App Store Connect fails with a 5xx or 429 are retried; writes never are.

## MCP server

Run with no command, xcflow is an MCP server. `setup` registers it in `.mcp.json`, so it starts in Claude Code in that repo.

- **Builds:** `list_workflows`, `list_builds`, `get_build` (action results, compiler errors, failing tests), `get_build_logs`, `start_build`.
- **Workflows:** `get_workflow` shows the live configuration and the file that defines it, and `list_environments` lists the Xcode and macOS versions. The MCP server never changes workflows; that goes through the files.
- **Apps:** the first time a tool runs, you choose which apps it shows. `choose_apps` changes the choice.

## License

MIT
