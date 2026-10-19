enum Templates {
    struct File {
        let path: String
        let content: String
    }

    static func archives(version: String) -> [String: String] {
        [
            "linux-x86_64": "xcflow-\(version)-linux-x86_64.tar.gz",
            "linux-aarch64": "xcflow-\(version)-linux-aarch64.tar.gz"
        ]
    }

    static func files(version: String, checksums: [String: String]) -> [File] {
        var install = installAction.replacingOccurrences(of: "{{version}}", with: version)
        for (platform, archive) in archives(version: version) {
            install = install
                .replacingOccurrences(of: "{{archive-\(platform)}}", with: archive)
                .replacingOccurrences(of: "{{checksum-\(platform)}}", with: checksums[archive] ?? "")
        }
        return [
            File(path: ".github/actions/xcflow/action.yml", content: install),
            File(path: ".github/workflows/xcflow-plan.yml", content: planWorkflow),
            File(path: ".github/workflows/xcflow-apply.yml", content: applyWorkflow),
            File(path: ".github/workflows/xcflow-sync.yml", content: syncWorkflow),
            File(path: "XcodeCloud/README.md", content: workflowsReadme),
            File(path: ".claude/skills/edit-xcode-cloud-workflow/SKILL.md", content: skill),
            File(path: ".claude/rules/xcode-cloud.md", content: rule)
        ]
    }

    static var mcpServer: [String: Any] {
        ["type": "stdio", "command": "xcflow", "args": [String](), "env": [String: String]()]
    }

    private static let installAction = #"""
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

    private static let planWorkflow = #"""
    name: Xcode Cloud plan

    on:
      pull_request:
        types: [opened, synchronize, reopened, ready_for_review]
        paths:
          - 'XcodeCloud/**'
          - '.github/actions/xcflow/**'
          - '.github/workflows/xcflow-*.yml'

    permissions:
      contents: read
      pull-requests: write

    concurrency:
      group: xcflow-plan-${{ github.event.pull_request.number }}
      cancel-in-progress: true

    jobs:
      plan:
        name: Plan Xcode Cloud workflow changes
        if: github.event.pull_request.draft == false
        runs-on: ubuntu-latest

        steps:
          - name: Checkout repository
            uses: actions/checkout@v7

          - name: Install xcflow
            uses: ./.github/actions/xcflow

          - name: Plan
            id: plan
            env:
              ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
              ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
              ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
            run: |
              set +e
              xcflow plan > plan.md 2> plan-error.txt
              STATUS=$?
              set -e
              if [ "$STATUS" -ne 0 ] && [ -s plan-error.txt ]; then
                { echo; echo '**The plan failed:**'; echo '```'; cat plan-error.txt; echo '```'; } >> plan.md
              fi
              cat plan.md >> "$GITHUB_STEP_SUMMARY"
              echo "status=$STATUS" >> "$GITHUB_OUTPUT"

          - name: Comment on the PR
            env:
              GH_TOKEN: ${{ github.token }}
              PR: ${{ github.event.pull_request.number }}
            run: |
              MARKER='<!-- xcflow-plan -->'
              {
                echo "$MARKER"
                head -c 60000 plan.md
                echo
                echo
                echo "_Applied to Xcode Cloud when this PR is merged. Commit ${GITHUB_SHA::8}._"
              } > comment.md
              EXISTING=$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR/comments" --paginate --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" | head -1)
              if [ -n "$EXISTING" ]; then
                gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$EXISTING" -F body=@comment.md > /dev/null
              else
                gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$PR/comments" -F body=@comment.md > /dev/null
              fi

          - name: Fail on invalid workflow files
            if: steps.plan.outputs.status != '0'
            run: |
              echo "::error::The Xcode Cloud plan failed. See the PR comment or the job summary."
              exit 1

    """#

    private static let applyWorkflow = #"""
    name: Xcode Cloud apply

    on:
      push:
        paths:
          - 'XcodeCloud/**'
      workflow_dispatch:

    permissions:
      contents: read

    concurrency:
      group: xcflow-apply
      cancel-in-progress: false

    jobs:
      apply:
        name: Apply Xcode Cloud workflow changes
        if: github.ref_name == github.event.repository.default_branch
        runs-on: ubuntu-latest

        steps:
          - name: Checkout repository
            uses: actions/checkout@v7

          - name: Install xcflow
            uses: ./.github/actions/xcflow

          - name: Apply
            env:
              ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
              ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
              ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
            run: |
              set +e
              xcflow apply > apply.md 2> apply-error.txt
              STATUS=$?
              set -e
              if [ "$STATUS" -ne 0 ] && [ -s apply-error.txt ]; then
                { echo; echo '**Apply failed. Changes listed above went through; the rest did not:**'; echo '```'; cat apply-error.txt; echo '```'; } >> apply.md
              fi
              cat apply.md
              cat apply.md >> "$GITHUB_STEP_SUMMARY"
              exit $STATUS

    """#

    private static let syncWorkflow = #"""
    name: Xcode Cloud sync

    on:
      workflow_dispatch: {}
      schedule:
        - cron: "30 4 * * *"

    permissions:
      contents: write
      pull-requests: write

    concurrency:
      group: xcflow-sync
      cancel-in-progress: false

    jobs:
      sync:
        name: Sync Xcode Cloud workflows to the repo
        runs-on: ubuntu-latest

        steps:
          - name: Checkout repository
            uses: actions/checkout@v7

          - name: Install xcflow
            uses: ./.github/actions/xcflow

          - name: Export the live workflows
            env:
              ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
              ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
              ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
            run: xcflow export

          - name: Describe the changes
            run: |
              BODY="$RUNNER_TEMP/xcflow-sync.md"
              {
                echo "Workflows in App Store Connect no longer match the files in \`XcodeCloud/\`. Someone changed them there by hand, or Xcode Cloud did."
                echo
                git status --porcelain --untracked-files=all XcodeCloud | while read -r STATUS FILE; do
                  PRODUCT=$(basename "$(dirname "$FILE")")
                  case "$STATUS" in
                    D) echo "- Deleted in App Store Connect: **$(git show "HEAD:$FILE" | jq -r .attributes.name)** ($PRODUCT)" ;;
                    '??') echo "- New in App Store Connect: **$(jq -r .attributes.name "$FILE")** ($PRODUCT)" ;;
                    *) echo "- Changed in App Store Connect: **$(jq -r .attributes.name "$FILE")** ($PRODUCT)" ;;
                  esac
                done
                echo
                echo "**Merging** accepts these changes into the repo. The apply that follows the merge changes nothing in Xcode Cloud."
                echo
                echo "**To undo them in Xcode Cloud instead**, run the \"Xcode Cloud apply\" workflow by hand. It puts back what the files say, and the next sync closes this PR."
                echo
                echo "Automated change by the xcflow sync action."
              } > "$BODY"
              cat "$BODY" >> "$GITHUB_STEP_SUMMARY"

          - name: Create or update the pull request
            uses: peter-evans/create-pull-request@v8
            with:
              add-paths: XcodeCloud/**
              commit-message: "Xcode Cloud: Sync workflows from App Store Connect"
              title: "Xcode Cloud sync"
              body-path: ${{ runner.temp }}/xcflow-sync.md
              branch: xcflow/sync
              delete-branch: true

    """#

    private static let workflowsReadme = #"""
    # Xcode Cloud workflows

    The files here define this repo's Xcode Cloud workflows, and they are the source of truth: a change merged to the default branch is applied to Xcode Cloud. A change made by hand in App Store Connect shows up the next night as an "Xcode Cloud sync" PR, see below. The tooling is [xcflow](https://github.com/OlafAndreas/xcflow).

    ## Layout

    One folder per Xcode Cloud product, named by its bundle id, and one JSON file per workflow, e.g. `XcodeCloud/com.example.app/nightly-tests.json`. Only products with a folder are managed; xcflow never touches the others.

    ## A workflow file

    ```json
    {
      "id": "…",
      "repository": "my-repo",
      "xcodeVersion": "Latest Release",
      "macOsVersion": "Latest Release",
      "attributes": { "name": "Nightly tests", "actions": [ … ], "scheduledStartCondition": { … }, … }
    }
    ```

    - `id` ties the file to an existing workflow. A new workflow has no `id`; it is created on merge and matched by name after that.
    - `xcodeVersion` and `macOsVersion` are version names as Xcode Cloud shows them, e.g. "Xcode 26.6" or "Latest Release". `plan` lists the available names when one is unknown. `null` keeps whatever the workflow has, which is only allowed for existing workflows.
    - `attributes` uses App Store Connect's own keys and shapes. Copying from an existing file is the easiest way to get them right.
    - Test destinations name their device and runtime by `deviceTypeIdentifier` and `runtimeIdentifier` only. Xcode Cloud's display labels for them go stale, so xcflow leaves them out and ignores them.
    - In a start condition's `filesAndFoldersRule`, App Store Connect stores an unset matcher `directory` as `""`, while an unset `fileExtension` or `fileName` stays `null`. xcflow treats a `null` directory as `""`, so either works, but `""` matches what `export` writes.
    - Renaming a workflow is a change to `attributes.name`. Keep the `id` so its build history stays.
    - Deleting a file deletes the workflow, together with its build history.
    - A workflow with **Restrict Editing** turned on in App Store Connect (`"isLockedForEditing" : true`) can't be changed or deleted through the API. `plan` warns when a change touches one; turn Restrict Editing off in App Store Connect before merging.

    ## Changing a workflow

    1. Edit, add or delete a file. In Claude Code, the `edit-xcode-cloud-workflow` skill does this and opens the PR.
    2. The PR check (`.github/workflows/xcflow-plan.yml`) posts what will be created, updated or deleted, and fails if a file is invalid. It doesn't run on draft PRs.
    3. When the PR is merged, `.github/workflows/xcflow-apply.yml` applies the change.

    ## Changes made in App Store Connect

    Every night, `.github/workflows/xcflow-sync.yml` exports the live workflows. If they differ from the default branch, it opens or updates the "Xcode Cloud sync" PR on the `xcflow/sync` branch, listing each workflow changed, added or deleted in App Store Connect.

    - **Merge it** to accept the changes into the repo. The apply after the merge changes nothing in Xcode Cloud.
    - **To undo the changes instead**, run the "Xcode Cloud apply" workflow by hand. It puts back what the files say, and the next sync closes the PR.

    The plan check doesn't run on the sync PR, because GitHub doesn't start workflows for PRs that a workflow opened.

    ## Seeing the plan locally

    With [xcflow](https://github.com/OlafAndreas/xcflow) installed and your own key stored (`xcflow auth`), run `xcflow plan` from the repo root. To see the exact requests without calling the API, copy the folder before editing and run `xcflow plan --dry-run <copy>`.

    """#

    private static let skill = #"""
    ---
    name: edit-xcode-cloud-workflow
    description: Use when an Xcode Cloud workflow should change — adding, editing, enabling, renaming or removing one, its start conditions, actions, schemes, Xcode or macOS version.
    ---

    # Edit an Xcode Cloud workflow

    Workflows are defined by the JSON files in `XcodeCloud/<bundle id>/`. Read `XcodeCloud/README.md` for the file format. A change reaches Xcode Cloud only through a PR: the PR check posts the plan, and merging applies it. Never change a workflow by hand in App Store Connect; the nightly sync turns that into a PR that someone has to accept or undo.

    ## Steps

    1. **Take a snapshot** of the folder before editing, so the dry run has a "before" to compare with:
       ```bash
       SNAPSHOT=<scratchpad>/xcode-cloud-snapshot && rm -rf "$SNAPSHOT" && mkdir -p "$SNAPSHOT"
       git archive HEAD XcodeCloud | tar -x -C "$SNAPSHOT"
       ```
    2. **Edit the files.**
       - **Change:** edit the file in place and keep its `id`. A rename is a change to `attributes.name`.
       - **Add:** copy the closest existing file into the product's folder. Remove `id`, set a new `attributes.name`, and change everything product-specific: the `scheme` in each action, and the start conditions. Use version names that other files use; an unknown name makes `plan` fail and list the names Xcode Cloud has.
       - **Remove:** delete the file. It deletes the workflow **and its build history**. Confirm that with the developer before deleting, and name the workflow.
       - Check the scheme can do what the action asks. A `TEST` action on a scheme without test targets fails every build.
    3. **Dry run** the plan offline and show the developer the result:
       ```bash
       xcflow plan --dry-run "$SNAPSHOT/XcodeCloud"
       ```
       It must list exactly the creates, updates and deletes you meant, with no validation errors. Use `apply` instead of `plan` to see the request bodies. The dry run compares against the repo's files, not live Xcode Cloud. `xcflow plan` without `--dry-run` reads the live state; only run it when the developer agrees to calling App Store Connect.
    4. **Commit and open the PR** the way this repo does it. Put the dry-run plan in the description. Say that the live plan arrives as a PR comment once the PR is ready for review, because the check skips drafts. Don't predict what that comment will say.

    ## Common mistakes

    | Mistake | Result |
    |---|---|
    | Copying a file and keeping its `id` | Two files claim the same workflow; plan fails |
    | New file in the wrong bundle-id folder | Workflow created in the wrong app |
    | `xcodeVersion: null` on a new workflow | Plan fails; only existing workflows may keep theirs |
    | Deleting to "start fresh" when editing would do | Build history lost |
    | Running `xcflow apply` locally | Changes Xcode Cloud without review; apply only runs from the default branch |

    """#

    private static let rule = #"""
    ---
    paths:
      - "XcodeCloud/**"
      - ".github/workflows/xcflow-*.yml"
      - ".github/actions/xcflow/**"
      - "ci_scripts/**"
    ---

    # Xcode Cloud

    The files in `XcodeCloud/` are the source of truth for the Xcode Cloud workflows. Change a workflow only by editing its file and opening a PR, using the `edit-xcode-cloud-workflow` skill. Never change one by hand in App Store Connect.

    Calls to App Store Connect need the developer's OK, including reads. Use `xcflow plan --dry-run <snapshot>` by default. `xcflow plan` and `xcflow export` without it, and the xcflow MCP tools, read live data. `xcflow apply` is only run by the GitHub Action on the default branch; never run it locally.

    `ci_scripts/` holds Xcode Cloud's custom build scripts. They run in every Xcode Cloud build, of every workflow, and neither `plan` nor a dry run covers them. A change there can only be checked by a real Xcode Cloud build, so say that in the PR, and ask the developer before starting one.

    """#
}
