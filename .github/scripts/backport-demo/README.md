---
title: Fork-only backport workflow
description: Manual and policy-controlled label requests with clean backports and a conflict safe stop.
---

## Label feature status and local tests

The label entry and live policy are implemented locally; L-003 finalized the
workflow/runner contract and operator documentation. **Full label-feature acceptance
passed independently on 2026-09-16** via the `full_tests` script (exit code 0,
gate: "Full acceptance: 67/67 distinct baseline cases; 12/12 migration IDs;
13/13 label IDs."). The checked-in policy leaves labels
disabled. This work does not deploy or enable the feature on GitHub. Pushes,
deployment, hosted dispatches, label applications and other hosted changes require
separate owner approval; hosted acceptance is not required for local completion.
Historical migration receipts below do not validate these feature changes.

Production requires PowerShell 7.4+, bundled .NET 8+, and Git. Tests additionally
require exactly Pester 5.7.1, not Python or Node.js. Provision Pester
only during test setup, in user scope, when that version is absent:

```powershell
if (-not (Get-Module -ListAvailable Pester | Where-Object Version -EQ ([version]'5.7.1'))) {
  Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
}
Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
```

During implementation, use only the relevant targeted selection, with no overlapping
test processes. Tests use fake HTTP and owned temporary local Git origins, not GitHub.
From the repository root, the final workflow/runner contract and retained authoritative
rerunner-ID cases are selected with:

```powershell
$env:BACKPORT_TEST_WORKFLOW_DIR = Join-Path (Get-Location) '.github\workflows'
& .\.github\scripts\backport-demo\Run-Tests.ps1 -Epic L-003 -ResultPath (Join-Path ([IO.Path]::GetTempPath()) 'backport-pester-l003.xml')
```

`-Epic L-001` selects admission coverage; `-Epic L-002` selects history, stages and
live-policy coverage, including the existing authoritative current-user-ID regression.
Every filtered run is **development only**, never full acceptance. The independent
`full_tests` script runs the existing runner **without an Epic filter only after the
coder session ends**, with its own two-hour timeout and retained XML/logs. It ran
successfully for L-003 (exit code 0, 2176.38 seconds), and L3-1/L3-3 are now marked
DONE. A saved pass is reusable only
while test-relevant file fingerprints and evidence hashes match; code/test changes
invalidate it, documentation-only changes do not. Reproduce failures with focused
selections, then return for the independent script to rerun.

The unchanged manual test workflow, when separately approved, runs Pester on Ubuntu
and Windows with independent 30-minute jobs, Contents read only, and no publishing credential. It logs runtime,
Git and Pester versions and always attempts to retain XML results for seven days
under distinct OS/attempt artifact names. A missing result or failed dependency
setup is not acceptance. The full gate requires all 67 mapped baseline scenarios
and TEST-013 through TEST-024 plus **LT-01 through LT-13**, including LT-10's actual
workflow graph, permissions, trusted policy checkout, artifact chain and runner
contract. No skipped or unexecuted cases are accepted. Workflow checks cover
event inputs, concurrency, trusted checkout, permissions, action pinning and
artifact flow. They do not pin display wording, comments or historical workflow
versions. Local expression fixtures check the supported contract, not GitHub's
runtime evaluator. These tests do
not validate AL product behavior. Default XML output is external to the repository;
temporary Git fixtures use owned `.github/scripts/.backport-run-*` directories and are cleaned
up by the suite. The scoped `.gitignore` excludes only `backport-pester*.xml`;
the root `.gitignore` is unchanged.

**Targeted evidence (2026-09-16):** On Windows, PowerShell 7.6.6, .NET 10.0.12 and
Pester 5.7.1, `Run-Tests.ps1 -Epic L-003` passed 45/45 selected cases in 42.95 seconds,
including the updated LT-10 contract and all five retained authoritative rerunner-ID
cases; zero failures or skips, with 465 other discovered cases not run. The preceding
L-002 selection passed 46/46 history/stage/policy cases, not a full suite. XML/log
locations and the initial failing contract results are recorded in the
[execution plan](label-backport.plan.md). No unfiltered suite, GitHub evaluator,
deployment, hosted mutation or AL product validation ran in this L-003 session.

## Historical migration and accepted hosted evidence

The Python-free PowerShell migration was deployed on main at
[d3a5864485f2372e03286d93f71a5cfb34194978](https://github.com/AleksanderGladkov/BCApps-Backport-Test/commit/d3a5864485f2372e03286d93f71a5cfb34194978)
after the owner's conditional approval and the final 410-case matrix passed on both
OSes. That is historical manual-only evidence, not deployment or acceptance of labels
or live policy. Retain the existing workflow path, ID and history.

- [Final Python-free matrix 35010271229](https://github.com/AleksanderGladkov/BCApps-Backport-Test/actions/runs/35010271229)
  at d3a5864485f2372e03286d93f71a5cfb34194978 passed all 410 Pester cases on
  both OSes, retaining all 67 baseline mappings and 12 migration tags without
  Python setup or execution. Both saved XML results have zero skipped/not-run cases.
- [Transitional matrix 34990942466](https://github.com/AleksanderGladkov/BCApps-Backport-Test/actions/runs/34990942466)
  at 09339bed6 passed 410/410 Pester cases with zero skips and all 67 Python
  reference tests on both Windows and Ubuntu before deployment.
- [Source PR 1 dry run 34992819393](https://github.com/AleksanderGladkov/BCApps-Backport-Test/actions/runs/34992819393)
  made no object changes.
  [Reuse run 34993165554](https://github.com/AleksanderGladkov/BCApps-Backport-Test/actions/runs/34993165554),
  attempts 1 and 2, preserved open
  [Issue 2](https://github.com/AleksanderGladkov/BCApps-Backport-Test/issues/2),
  [PR 3](https://github.com/AleksanderGladkov/BCApps-Backport-Test/pull/3),
  comments and head `c1de55e330150d23b374aa23e6f774878207dd63`.
- [Source PR 6](https://github.com/AleksanderGladkov/BCApps-Backport-Test/pull/6)
  was squash-merged at 386360dc2.
  [Dry run 34995091907](https://github.com/AleksanderGladkov/BCApps-Backport-Test/actions/runs/34995091907)
  made no object changes.
  [Publication run 34995308640](https://github.com/AleksanderGladkov/BCApps-Backport-Test/actions/runs/34995308640)
  created exactly open
  [Issue 7](https://github.com/AleksanderGladkov/BCApps-Backport-Test/issues/7) and
  [PR 8](https://github.com/AleksanderGladkov/BCApps-Backport-Test/pull/8).
  Attempt 2 reused the same objects and head
  `0652ff833b6b80332db05191aeae6269bd292da0`. Source comment `5684058038`
  and Issue comment `5684057475` retained their IDs; their status changed only
  from `pr-created` to `pr-reused` as expected.

These receipts establish accepted cutover, publication and Python-free cleanup,
not an AL build or a shipped fix. Issues 2/7 and PRs 3/8 were verified open, with
both PRs unmerged, before the approved cleanup deployment. Do not merge, close,
reset or delete the demo objects as part of cleanup.

## Manual request (including dry-run)

1. Do not enable inherited BCApps workflows or change unrelated workflows.
2. Use the local test evidence; run Backport executor tests from Actions only with
   separate approval. Its jobs make no repository-object writes.
3. Create and squash-merge a source PR into this fork's main, changing only
   regular text AL files under src. No automation, binary files or submodules.
4. Run Backport to 29.x from main, with that PR number and dry_run enabled.
5. Inspect the Actions summary and result artifacts. A dry run creates no Issue,
   branch, PR or feedback comment. It still performs local Git checks.
6. Run again with dry_run disabled to create/reuse the tracking Issue and PR.
   Check the target, diff, source links and actual check results before merging.

Manual `dry_run` defaults to true. Explicit false is a real request; malformed or
missing raw controller values are rejected, not silently defaulted. All manual
requests must pass actor and policy checks, including dry-runs.

No upstream writes, App key, PAT, ADO, auto-merge or self-approval is used.
GitHub Actions must be permitted to create PRs in repository settings. Default
job-token permissions can remain read-only; only named jobs request writes.

## Post-merge label request

After separately approved deployment and policy enablement, an authorized user can
apply **`backport:29.x`** to a PR **already merged into this fork's `main`**. This
starts a real backport to `releases/29.x` (`dry_run=false`); no Run workflow click is
needed. Use manual dispatch first when a preview is wanted.

The label must match exactly: no case or whitespace variants. Wrong labels, events,
repositories or bases, and unmerged snapshots cannot reach a writer. A label applied
before merge is not picked up automatically at merge time. Remove and reapply it
after merge; rerunning that old pre-merge event cannot authorize it.

Manual and label requests share the source/target concurrency group with
`cancel-in-progress=false`. Relabeling or rerunning reuses only verified existing
objects and does not bypass recovery guards. This is not a durable queue: pending
runs can be replaced. **Removing the label is not cancellation**; the original
request may continue. Use reviewed live-policy withdrawal or explicit Actions
cancellation to stop subsequent work, subject to the race limitations below.

New backport PR titles use `[29.x] <source PR title>`, removing `[main]` and
`[master]` tags and their following space without changing other title text.
Existing backport PRs keep their titles when reused. PR descriptions remain
`Backport of #<source>` and `Fixes #<tracking issue>` with the existing provenance;
the source PR description is not copied. Branch names remain
`backport/29.x/pr-<source PR>`. The source number is also stored in the plan and
provenance marker, while the deterministic branch name supports existing-PR lookup.

## Requesters, repository scope and live policy

The initial requester allowlist contains numeric GitHub user ID `59250993`.
Adding a requester requires approval to add their verified numeric GitHub ID to
**both** `BACKPORT_ALLOWED_ACTOR_IDS` (a comma-separated Actions variable) and
`allowed_actor_ids` in the reviewed
[request-policy.json](request-policy.json) on main. The variable defaults to
`59250993`; it is a start-time snapshot, not a live revocation control.
The original requester and independently verified current rerunner must be in both
allowlists. A label's numeric sender must also match the original actor. An allowed
rerunner cannot authorize an originally unauthorized event. Repository roles,
PR authorship, label presence and PR text do not grant authority; dispatch inputs
cannot supply the allowlist.

Code checks the exact fork name, repository ID 1369849596, main execution ref,
and fixed target releases/29.x. Renaming or moving the repository requires a
reviewed code change. It will not silently switch to microsoft/BCApps.

The policy's checked-in initial values are:

```json
{
  "schema": 1,
  "repository_id": 1369849596,
  "allowed_actor_ids": [59250993],
  "label_requests_enabled": false,
  "writes_enabled": true
}
```

Keep exactly these keys, distinct positive integer actor IDs and actual JSON
booleans. Missing/malformed files, unknown or duplicate keys, invalid identities and
failed policy reads reject the request; there is no permissive fallback.
`label_requests_enabled=false` blocks labels but permits authorized manual requests.
`writes_enabled=false` blocks repository writes for **both** entries, including
feedback; an authorized manual dry-run remains available with otherwise valid policy.
Label requests require both switches true and never fall back to dry-run.

Every job checks out trusted automation and policy at the immutable
`github.workflow_sha`, from the main-backed workflow, never the PR head. Each stage
and mutation boundary rereads the fork's current main ref and fetches policy bytes
pinned to that exact commit. Their SHA-256 must match the immutable checkout policy.
**Any detected byte change requires a fresh request against the new main workflow
revision**, even whitespace or a more permissive edit, and even for a manual dry-run
or a label-switch-only edit during a manual run. Start a new dispatch or authorized
post-merge relabel, not a rerun of the old request. An unrelated main commit with
identical policy bytes remains valid.

Policy is checked before Issue creation, create-only branch push, PR creation and
each comment POST/PATCH, including conflict feedback and feedback-only recovery.
It is checked again after read-back and before reporting reuse, including unchanged
comments. Withdrawal, changed bytes or unavailable policy stops later writes,
including the second feedback destination. Denial is reported only in Actions:
no rejection Issue/comment is created. Preserve already-created objects and journals;
a fresh request still cannot retry an ambiguous create.

**Checks and writes are not atomic.** A policy change after the final read can race
one in-flight mutation; a temporary change entirely between checks may be missed.
Neither label removal, policy withdrawal nor Actions cancellation promises instant
or durable rollback. Inspect partial results and reconcile before retrying.
Older pre-feature workflow revisions do not gain live-policy checks retroactively.

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
  Issue and source PR receive a status comment on a non-dry run only while policy permits.
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

The production workflow calls [Invoke-Backport.ps1](Invoke-Backport.ps1) with
`-Stage validate`, `track`, `prepare`, or `publish`, loading only the trusted
[module](Backport.psm1), adjacent [compatibility data](compat.json) and
[request policy](request-policy.json). Live policy is read as data, never executed.
The final package also uses the [Pester suite](Backport.Tests.ps1),
[test helpers](TestHelpers.ps1), [runner](Run-Tests.ps1), and
[parity reference](parity.json): eight runtime/test/data files. Current tests
execute PowerShell and compare against pinned reference bytes; they do not run
a Python oracle. Historical source and capture metadata are retained, not
rewritten to imply live cross-language execution. No product AL build is performed.

Compatibility data preserves Python 3.13 / Unicode 15.1.0 provenance, fixed
canonical vectors and applicable license notices. Production does not generate
or download it. The parity resource retains the exact 67 baseline names pinned
to source commit `514500f55f064aa9ab86607e6d0803f2abd6376c`.
Separate Windows and Linux envelopes each contain 28 stage records and two
state records, with pinned source, exporter, helper and capture provenance.

- Windows historical capture on 2026-09-15 used PowerShell 7.6.6, .NET 10.0.12,
  Git 2.55.0.windows.5, Python 3.13.15 and Unicode 15.1.0; 27 focused cases passed.
- [Linux historical capture 34985587470](https://github.com/AleksanderGladkov/BCApps-Backport-Test/actions/runs/34985587470),
  attempt 1 at `c544d98d02561a7396912870e8da4fc3da99e2d6`, used Ubuntu 24.04.5,
  PowerShell 7.6.5, .NET 10.0.11, Git 2.55.0, Pester 5.7.1, Python 3.13.15
  and Unicode 15.1.0; 27 focused cases passed.

Those captures are historical live Python handoffs, not full-suite acceptance.
Current checks verify each envelope and its byte/hash pairs, reject modified
provenance even after payload rehashing, and replay only the matching OS data.

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
final publication verdict. Conflicts retain `needs-attention` and policy-authorized
feedback without branch/PR publication; no resolver or unverified result publishes.
Local feature coverage needs no resolver, generation tracking, profile registry or
new request sidecar. These tests do not establish AI resolution, hosted label
automation, AL correctness or delivery of a shipped fix.

The recoverable tested Python rollback is
[6972ef0a0](https://github.com/AleksanderGladkov/BCApps-Backport-Test/commit/6972ef0a0e0c00b35d4e00fb866363b4742c7266).
Before any rollback, stop dispatches and reconcile the current source/target
refs and exact object identities. Prepare a reviewed restoration of that tested
Python runtime and its required files at their original paths, including
`.github/workflows/backport-demo.yml`. Validate the restoration before deployment.
Keep workflow ID `357933757` and its history intact; never reset, force-push,
rename the workflow or delete history to bypass an uncertain-write guard.

If any write may have occurred, retain journals/artifacts/history and reconcile
exact objects before retrying. Rollback does not authorize closing Issues,
merging PRs, deleting branches/comments/history, or retrying an uncertain create.

## Conflict handling

The preparation result retains conflict details, including repository, source and
target SHAs, and affected files. Its worktree paths belong to that job's runner
and must not be reused after the runner is removed.

The workflow reports `needs-attention` without publishing a branch or PR. It has
no automatic conflict-resolution step; the publisher accepts only its independently
recomputed clean cherry-pick result.
