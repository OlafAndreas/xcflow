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

1. Have a team App Store Connect API key: **Users and Access → Integrations → Team Keys → Generate API Key**, with the Admin role or App Manager with access to Xcode Cloud. Download the `.p8` and note the key id and the issuer id. One key serves everything: `setup` keeps it in your Keychain for xcflow's own use, exports the workflows with it, and sets it as the repo's GitHub secrets for CI.

   Rather use a personal key on your own machine? Store it first with `xcflow auth --key-id <KEY_ID> --p8 <path>`; `setup` then still asks for a team key for the secrets.

2. From the repo root, run:

   ```bash
   xcflow setup --dry-run   # see what it would add
   xcflow setup             # asks for the team key when none is stored
   xcflow setup --key-id <KEY_ID> --issuer-id <ISSUER_ID> --p8 ~/Downloads/AuthKey_<KEY_ID>.p8   # no questions: scripts and agents
   ```

   `setup` asks before each step that calls App Store Connect or GitHub, and never overwrites a changed file without asking. It adds:

   - `XcodeCloud/<bundle id>/*.json`: one file per workflow, exported from the products in the project's Xcode Cloud manifest, or from the ones you pass with `--products`, plus a README on the format.
   - `.github/workflows/xcflow-plan.yml`, `xcflow-apply.yml` and `xcflow-sync.yml`, running on `ubuntu-latest` and installing xcflow from `OlafAndreas/xcflow-action`, pinned to a commit.
   - `.github/dependabot.yml`, so Dependabot opens a pull request when a new xcflow is out. The plan check doesn't run on those pull requests, because they can't read the repo's secrets; the bump merges on the strength of xcflow's own release checks, and the nightly sync is the first run of the new version in that repo.
   - With `--claude`: `.claude/skills/edit-xcode-cloud-workflow/` and `.claude/rules/xcode-cloud.md`, so Claude Code changes workflows through the files, and an `xcflow` entry in `.mcp.json`, so it can read Xcode Cloud through xcflow. The skill loads its instructions from the installed xcflow (`xcflow guide skill`), so it always matches the version you run. The nightly sync runs `xcflow docs`, so `XcodeCloud/README.md` and the rule follow the xcflow version the workflows pin.
   - The `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` secrets on the GitHub repo, from the team key. `setup` checks first and skips this step when all three are already set; `--replace-secrets` sets them again.

   When it's done, review the new files with `git status`, commit them and open a pull request. The plan check posts what would change in Xcode Cloud, and the repo is ready.

   Run it again at any time; files that already match are left alone, and a newer pin that Dependabot made is kept.

   A repo set up by an earlier xcflow loses its `.github/actions/xcflow/` on the next `setup` once the file is untouched and no workflow uses it any more. While a workflow still references it, or if it was edited, `setup` keeps it and says what to do in the to-do list.

### Keys for several teams

xcflow keeps any number of keys in the Keychain, one per key id, and picks one for each command in this order:

1. The `ASC_KEY_ID` and `ASC_KEY_CONTENT` environment variables, when set. CI always works this way.
2. The key this repo is pinned to on this machine.
3. The only stored key, when there is just one.

With several keys stored and no pin, xcflow stops and asks you to pick one with `xcflow keys use <key id>`. `setup` pins the key it used, asking in a terminal when there are several, and `auth` pins the key it stores in a repo that has an `XcodeCloud/` folder and no pin yet.

The pins live outside the repo, in `~/Library/Application Support/xcflow/repos.json`, keyed by the repo's `origin` remote, so every clone and worktree of a repo shares one. Nothing is committed: each developer has their own keys. A repo set up by xcflow 0.2.12 has its pin in `XcodeCloud/xcflow.json`; it still works, and the next `setup`, `auth` or `keys use` moves it to `repos.json` and deletes the file.

```bash
xcflow keys                  # the stored keys; * marks this repo's
xcflow keys use <key id>     # pin this repo to a stored key
xcflow keys remove <key id>  # delete a key from the Keychain
```

## How it works

- **Pull requests:** `xcflow plan` validates the files against the live catalog (Xcode and macOS versions that exist and run together, schemes the project shares) and compares them with Xcode Cloud. The PR check posts the result as a comment: what will be created, updated or deleted. It only reads from App Store Connect.
- **Merge:** a push to the default branch that changes `XcodeCloud/` runs `xcflow apply`, which makes those changes.
- **Every night:** `xcflow export` writes the live workflows to the files. If they differ, the sync job opens a pull request. Merge it to accept the change, or run the apply workflow to undo it in Xcode Cloud.

Only products with a folder in `XcodeCloud/` are managed. Deleting a workflow's file deletes the workflow, together with its build history.

## Commands

| Command | What it does |
|---|---|
| `xcflow setup` | Adds the files above to the current repo. |
| `xcflow auth --key-id <id> --p8 <path> [--issuer-id <id>]` | Checks a key against App Store Connect and stores it in the Keychain. |
| `xcflow keys [use <id> \| remove <id>]` | Lists the stored keys, pins this repo to one, or removes one. |
| `xcflow add <pr-checks \| nightly-tests \| testflight-on-tag>` | Writes a new workflow file from a preset: tests on every pull request, tests every night at 03:00, or an App Store archive for each `v` tag. It copies the repository, project, versions and platform from a workflow file already in the folder, and picks the scheme the project shares. `--product`, `--scheme` and `--name` choose when there's more than one option. The API can't add a TestFlight post-action, so add that in Xcode once the workflow exists. |
| `xcflow plan` | Validates `XcodeCloud/` and prints what would change. Reads only. |
| `xcflow apply` | Makes those changes. Meant for CI on the default branch. |
| `xcflow export [<bundle id> …]` | Writes the live workflows to `XcodeCloud/`. Without ids: the products already there, or the ones in the project's Xcode Cloud manifest. |
| `xcflow builds [<workflow>] [--branch <name>] [--limit <n>]` | Lists recent builds, newest first. |
| `xcflow build <number or id> [--wait] [--timeout <minutes>]` | Shows a build: its actions, compiler errors and failing tests. With `--wait`, waits for it to finish first. |
| `xcflow logs <number or id> [--action <name>]` | Downloads a build's logs and prints where they went. |
| `xcflow run <workflow> (--branch <name> \| --tag <name>) [--clean] [--wait] [--timeout <minutes>]` | Starts a build. With `--wait`, waits for it to finish. |
| `xcflow docs [--check]` | Rewrites `XcodeCloud/README.md`, and the Claude Code skill and rule when the repo has them, to match this version. The nightly sync runs it. |
| `xcflow get <path> [key=value …]` | Prints a raw App Store Connect API response. |

`--dry-run <folder>` with `plan`, `apply` or `export` answers from the workflow files in that folder instead of the API, and prints every request it would send. Nothing is sent and no key is needed. Copy `XcodeCloud/` before editing and pass the copy to see exactly what a change would do.

In CI, the key comes from the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` (base64 of the `.p8`) environment variables instead of the Keychain. On Linux, which has no Keychain, the environment variables are the only way. Reads that App Store Connect fails with a 5xx or 429 are retried; writes never are.

### Builds from CI

The build commands read and start builds in the products that have a folder in `XcodeCloud/`; `--product <bundle id>` or `--all` widens or narrows that. A GitHub workflow can start a build and gate on how it ends:

```yaml
runs-on: ubuntu-latest
steps:
  - uses: actions/checkout@v7
  - uses: OlafAndreas/xcflow-action@v0.2.11
  - run: xcflow run "Nightly tests" --branch "$REF" --wait
    env:
      REF: ${{ github.ref_name }}
      ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
      ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
      ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
```

The branch goes through `env` rather than straight into the script, so a branch name can't inject shell commands. On `pull_request` events, use `github.head_ref` instead of `github.ref_name`.

Interrupting the command or letting `--timeout` pass (120 minutes by default) leaves the build running in Xcode Cloud. With `--wait` the exit code is 0 when the build succeeded, 1 when it failed, 2 when xcflow couldn't finish (App Store Connect or the network failed, or the workflow wasn't found), 64 for a usage error (a missing or unknown flag) and 124 when the wait timed out.

## MCP server

Run with no command, xcflow is an MCP server. `setup` registers it in `.mcp.json`, so it starts in Claude Code in that repo.

- **Builds:** `list_workflows`, `list_builds`, `get_build` (action results, compiler errors, failing tests), `get_build_logs`, `start_build`.
- **Workflows:** `get_workflow` shows the live configuration and the file that defines it, and `list_environments` lists the Xcode and macOS versions. The MCP server never changes workflows; that goes through the files.
- **Apps:** the tools show the apps in the repo's `XcodeCloud/` folders. In a repo without them, the first tool call asks which apps to show. `choose_apps` changes the choice for the current repo. Choices are kept per repo on this machine, in `~/Library/Application Support/xcflow/apps.json`, so a repo for one team never hides another team's apps.

## Roadmap

Where xcflow is heading, roughly in order. Contributions are welcome: open an issue to talk an item through before building it, or send a pull request.

- **Seeding from CI.** A reusable workflow next to the install action, so a repo gets xcflow from a five-line workflow and a dispatch, and an organization workflow template so it shows on every repo's "New workflow" page.
- **Smaller onboarding gaps.** `setup` warning on a private repo that Dependabot needs the dependency graph switched on, and a homebrew-core formula once the project qualifies, so `brew install xcflow` works without naming the tap.

Not planned: managing TestFlight testers or groups, which are people and drift that don't belong in git, and creating an app's first Xcode Cloud workflow, which the App Store Connect API doesn't allow.

## License

MIT
