---
title: Manual backport test workflow
description: Alexander's fork-only clean backport executor and Milica's conflict handoff.
---

## Migration status and local tests

PowerShell cutover preparation is local to the migration branch. The focused
workflow contract checks pass; full hosted Windows/Ubuntu parity, deployment,
dry-run, existing-object reuse, and fresh-publication acceptance remain pending.
Do not dispatch the production workflow from the migration branch or remove
the Python reference files before those separately approved gates pass.

Production requires PowerShell 7.4+, bundled .NET 8+, and Git. Tests additionally
require Python 3.13 (Unicode 15.1.0) and exactly Pester 5.7.1. Provision Pester
only during test setup, in user scope, when that version is absent:

```powershell
if (-not (Get-Module -ListAvailable Pester | Where-Object Version -EQ ([version]'5.7.1'))) {
  Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
}
Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
```

From the repository root, run the unchanged reference suite and full parity
gate offline. Tests use fake HTTP and temporary local Git origins, not GitHub:

```powershell
$env:BACKPORT_TEST_BASELINE_DIR = Join-Path (Get-Location) '.github/scripts/backport-demo'
$env:PYTHONDONTWRITEBYTECODE = '1'
python -B -m unittest discover -s .github/scripts/backport-demo -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Python reference suite failed.' }
& ./.github/scripts/backport-demo/Run-Tests.ps1 -ResultPath (Join-Path ([IO.Path]::GetTempPath()) 'backport-pester.xml')
```

The manual test workflow runs both suites on Ubuntu and Windows with independent
30-minute jobs, Contents read only, and no publishing credential. It logs runtime,
Git and Pester versions and always attempts to retain XML results for seven days
under distinct OS/attempt artifact names. A missing result or failed dependency
setup is not acceptance. The full gate requires all 67 mapped baseline scenarios
and TEST-013 through TEST-024, with no skipped or unexecuted required cases.

## Run it

1. Do not enable inherited BCApps workflows or change unrelated workflows.
2. Run Backport executor tests from Actions. It makes no remote writes.
3. Create and squash-merge a source PR into this fork's main, changing only
   regular text AL files under src. No automation, binary files or submodules.
4. Run Backport to 29.x from main, with that PR number and dry_run enabled.
5. Inspect the Actions summary and result artifacts. A dry run creates no Issue,
   branch, PR or feedback comment. It still performs local Git checks.
6. Run again with dry_run disabled to create/reuse the tracking Issue and PR.
   Check the target, diff, source links and actual check results before merging.

No upstream writes, App key, PAT, ADO, auto-merge or self-approval is used.
GitHub Actions must be permitted to create PRs in repository settings. Default
job-token permissions can remain read-only; only named jobs request writes.

## Requesters and repository scope

Only AleksanderGladkov's numeric ID 59250993 is allowed initially. Once Milica
accepts collaborator access, the repository owner can add her verified numeric
GitHub ID to BACKPORT_ALLOWED_ACTOR_IDS, a comma-separated Actions variable.
Both the original requester and the person rerunning a workflow must be allowed.
Do not put this setting in dispatch inputs. Never infer identity from PR text.

Code checks the exact fork name, repository ID 1369849596, main execution ref,
and fixed target releases/29.x. Renaming or moving the repository requires a
reviewed code change. It will not silently switch to microsoft/BCApps.

## Supported changes and results

- Verify the squash commit's complete change against the source PR branch.
  Current merge settings alone do not prove historical source PRs were squashed.
- Maximum 50 regular AL files, 1 MiB per blob and 5 MiB patch. Symlinks,
  executable files, traversal/control-character paths and binary blobs are rejected.
- Source/main and target refs are fetched in a new isolated Git repository.
  No source hooks, external diff drivers, or configured credential helpers run.
- Clean changes are independently recomputed by the publisher. Uploaded patches
  are compared, not trusted as instructions or blindly applied with credentials.
- Conflicts return needs-attention with no branch/PR publication. The tracking
  Issue and source PR receive a status comment on a non-dry run.
- Already-applied content is a verified no-op, not an empty new PR.
- A stable branch and bot-owned marker identify existing objects. Duplicates,
  edited object metadata, conflicting branches, abandoned PRs and uncertain writes
  stop rather than overwrite, force-push or blindly repeat creation.
- New branches use a create-only expected-ref check; a concurrently created
  branch is rejected rather than fast-forwarded or overwritten.
- A target that advances during the run stops publication. A later rerun may
  also stop if an existing branch was built on a different target base.

API lookup/pagination failures are errors, not empty result sets. Cross-run
history checks prevent new creates after an earlier possibly-writing request
for the same source, even if an Issue/PR list is temporarily stale. Verified
existing objects can still be reused and existing comments updated. A later
run cannot create missing feedback or finish a partial publication automatically;
operator reconciliation is required. Keep workflow history and failure artifacts:
deleted history is not a durable exactly-once guarantee. Do not delete it to
get past the recovery guard. Rerun all jobs, not just failed
jobs: state from another run attempt is rejected. Artifacts expire after seven
days and are diagnostics, not a complete durable external ledger.

## Files and state

The prepared workflow calls [Invoke-Backport.ps1](Invoke-Backport.ps1) with
`-Stage validate`, `track`, `prepare`, or `publish`, loading only the trusted
[module](Backport.psm1) and adjacent [compatibility data](compat.json).
The unchanged [Python controller](controller.py) and [reference tests](test_controller.py)
remain beside the [Pester suite](Backport.Tests.ps1) during migration. No product
AL build is performed by these tests. Compatibility data records Python 3.13 /
Unicode 15.1.0 provenance and the applicable license notices; it is not generated
or downloaded by production jobs.

Each job keeps state under RUNNER_TEMP/backport-state and uploads the whole
directory even on failure. It contains the validated plan, Issue tracking,
result, patch, and any publication-attempt journal. Never drop the journal
when diagnosing an uncertain write. Logs avoid secrets and untrusted PR text.

Token-created PR workflows may require manual owner approval. A successful
backport run is evidence of PR preparation only, not a passed BCApps build.

## Safety correspondence and rollback

The eight correspondence decisions in [parity.json](parity.json) retain exact
source/target/actor checks, isolated temporary repositories, verified squash
cherry-pick with independent reconstruction, exact bot-object reconciliation,
journals, history checks, create-only leases and remote read-back. Synthetic
safety tests supplement the 67 baseline cases. This remains a one-source,
one-target executor, not a wire-compatible implementation of another coordinator.
Neither protected backport nor conflict-resolver package is imported or executed.

The same metadata records these five helper dispositions:

- `byte-safe-blob`: adapted to independent bounded byte-stream transport and argument lists.
- `canonical-atomic-json`: adapted; sorted keys and atomic writes preserve Python's exact bytes and types.
- `result-before-pr`: adapted to recomputed content and verified legitimate subset deltas.
- `github-readback`: adapted to fixed-scope HTTP, branch/base/head verification and create-only publication.
- `publication-receipt`: deferred; retain existing journals and read-back without adding a result schema.

Resolver adaptation remains deferred. Preparation `published=false` is not a
final publication verdict. These tests do not establish AI resolution, label
automation, AL correctness or delivery of a shipped fix.

Before deploying, record the tested pre-cutover main SHA, workflow ID/history,
source/target refs and existing object identities. Restore the recorded Python
version only through a reviewed revert in place, never a reset, force-push or
renamed fallback workflow. Keep Python source/tests/exporter until hosted
acceptance and cleanup are approved. If any write may have occurred, stop
dispatches, retain journals/artifacts/history and reconcile exact objects before
retrying. Rollback does not authorize closing Issues, merging PRs, deleting
branches/comments/history, or retrying an uncertain create.

## Milica's next integration step

The controller does not run Copilot yet. On conflict, prepare writes a JSON
handoff containing repo, source_pr, source_sha, target_base_sha, worktree, and
files (each with relative_path and absolute_path).

The worktree belongs to the prepare job and disappears with its runner. A
separate resolver job must recreate the conflict from the recorded SHAs and
set its own worktree path. It must not use a previous runner's absolute path.
Add repository read and copilot-requests write only to that new job, with no
publishing token. Keep its result schema and publisher verification as a
reviewed follow-up: the current publisher accepts only its own recomputed
clean cherry-pick, not an AI patch marked resolved.

Return resolved/needs-attention, the reason, changed file list, source/base
SHAs, and patch/checksum. Alexander must add independent path/region/fix checks
before accepting that new result; changing the status string is insufficient.
