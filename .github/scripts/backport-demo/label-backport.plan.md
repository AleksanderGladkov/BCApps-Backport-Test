---
title: Label-triggered fork backports - execution plan
date_created: 2026-09-16
last_updated: 2026-09-16
status: L-001 DONE - L-002 DONE (reviewed and committed) - L-003 pending
revision_notes: Approved self-contained execution copy. Retains the three local label epics, main-backed live policy and per-write checks. Internal workspace references are omitted; hosted actions remain separately approval-gated.
---

# Label-triggered fork backports

## Executive Summary

Add `backport:29.x` label triggering to the existing **Backport to 29.x** workflow in `AleksanderGladkov/BCApps-Backport-Test`. An authorized user applies the exact label to a PR already merged into `main`; when the live policy enables label requests, the workflow feeds that request into the existing PowerShell backport executor for `releases/29.x`. Manual dispatch remains available with `dry_run=true` by default. A small main-backed policy controls allowed actors, label enablement and repository writes, and is checked again before every mutation.

This is an additional entry point, not a new backport service. Reuse the existing tracking Issue, clean patch preparation, independent publication verification, release PR and feedback behavior. A conflict continues to produce the existing `needs-attention` result without publication; Copilot conflict resolution is not required to complete this feature.

## Scope and authority

This execution copy is the status source for local implementation. It preserves the three scoped epics and supersedes broader historical requirements for this feature. Earlier resolver-integration, label-generation/event-correlation and hosted-demo requirements remain deferred, not completed. The external planning original is not an implementation input or staging target and must be reconciled separately.

The owner approved creating this public-safe copy in a separate local preparation commit and explicitly invoked implementation. L-001 completed in commit `40223ba771c7f50f6ef434226bb198058a96b52c`. The subsequent implementation invocation authorizes **all remaining epics: L-002, then L-003**, in one workflow without an epic filter, followed by holistic review and necessary fixes. This supersedes the earlier L-001-only launch restriction. Normal local implementation, tests, epic commits and status updates to this copy are authorized. Pushes, deployments, hosted workflow dispatches, label applications, merges and other hosted mutations still require separate explicit approval. The owner additionally approved a run-specific workflow copy outside the repository with targeted epic checks and a separate final acceptance script. Do not modify the installed skills, profiles or workflow assets, and do not commit the external orchestration files.

**Owner testing constraint for every remaining epic and review:** "Do not create and run a lot of tests - only necessary." Reuse existing tests and fixtures, add only cases needed for the stated acceptance criteria, and avoid redundant parameterized cases or test-count targets. L-002 coding and review use targeted tests only: the existing `Run-Tests.ps1 -Epic L-002` selection plus affected existing regressions, including `retains authoritative current-user IDs for label reruns`. No agent may run or delegate an unfiltered suite. Do not overlap test processes. Full acceptance belongs exclusively to the independent script step after L-003 implementation stabilizes; it runs outside the coder session with its own two-hour timeout. It retains XML/logs and reuses a successful result only when test-relevant file fingerprints and evidence hashes still match. Documentation-only changes do not require another full run. A failed full run returns to narrow reproduction and fixes, then the script reruns. Do not treat targeted results or L-001's historical pass as final acceptance.

### Implementation workspace and accepted baseline

| Item | Value |
|---|---|
| Implementation and orchestration root | Root of the `AleksanderGladkov/BCApps-Backport-Test` checkout |
| Feature branch | `private/algladkov/bc-backport-github` |
| Accepted starting commit | `e7629fc2348d160ecc857387e47a3f7bd5cf7e41`, containing the completed PowerShell migration |
| Fork | `AleksanderGladkov/BCApps-Backport-Test`, repository ID `1369849596` |
| Source and target | Merged source PR into `main`; backport target `releases/29.x` |
| Execution plan | `.github\scripts\backport-demo\label-backport.plan.md` |

The completed PowerShell migration is accepted as the local baseline. The [executor README](README.md) records its historical behavior and results; [compat.json](compat.json) and [parity.json](parity.json) retain its compatibility oracles. Previously acknowledged gaps in retained publication artifacts, before/after snapshots and approval receipts are not tasks for this feature. Do not repeat the migration, reconstruct missing receipts or present historical tests as tests of the label changes.

Use the fork-local executor and harness. No external harness or planning document is required. Upstream `microsoft/BCApps` is not a backport target. Preserve existing demonstration objects, including source PR #1, tracking Issue #2 and backport PR #3; this plan does not authorize changing them.

## Goals and non-goals

| In scope | Required outcome |
|---|---|
| Exact post-merge label entry | An authorized `backport:29.x` event becomes the same source/target request as manual dispatch. |
| Workflow compatibility | Correct event-specific inputs, dry-run interpretation, title, trusted checkout and shared concurrency. |
| Authorization and live policy | Preserve the existing numeric actor/rerunner checks, intersect them with the policy allowlist, and recheck current policy before every repository mutation. |
| Operator controls | Enable labels independently and stop subsequent writes through reviewed `label_requests_enabled` and `writes_enabled` policy changes. |
| History and recovery compatibility | Recognize label runs without hiding possible writers or letting irrelevant rejected label runs permanently block creation. |
| Existing backport behavior | Reuse the four stages, object identities, artifact bindings, independent patch verification and feedback. |
| Focused local coverage and documentation | Exercise real event parsing, workflow blocks and executor stages with existing test helpers. |

Out of scope: integrating or implementing a Copilot resolver; conflict-model demos; an external revocation service; exact label-application generation binding; webhook/Issue-event timestamp correlation; policy/history-profile registries beyond the single live policy file; a new request sidecar; per-mutation label-removal checks; generic queue management; historical receipt recovery; production rollout/rehearsal and demo acceptance; additional targets, triggers, credentials or ADO integration.

Existing runtime authorization, source/patch verification and conservative creation/recovery guards remain in scope. Hosted actions still need approval; moving them out of local acceptance does not grant it.

## Request behavior

| Situation | Behavior |
|---|---|
| Authorized exact label applied after merge into main | When both policy switches permit it, start a real backport request; no Run workflow click and no hidden dry-run mode. |
| Manual dispatch | Preserve canonical source PR input and the existing boolean input with default `dry_run=true`. |
| `label_requests_enabled=false` | Reject label requests with no repository writes. Manual requests remain subject to the other authorization and policy checks. |
| `writes_enabled=false` | Block every real repository mutation for either entry, including feedback. An authorized manual dry-run remains available when the remaining policy checks pass. |
| Policy revokes an actor, changes during execution, or becomes unreadable | Stop at the next policy check, preserve existing objects and report in Actions only. Do not write a rejection comment or retry a missing create. |
| Wrong label, case variant, unsupported event, wrong repository/base or unmerged PR | Reject or skip before any repository-writing job. Use sanitized Actions output, not a tracking Issue or comment for the rejection. |
| Label applied before merge, then PR merged | No automatic pickup. The user must remove and reapply the exact label after merge. An old event or rerun cannot pass because the PR later merged. |
| Label removed after application | Removal is not cancellation in this scope. An already requested run may continue while its policy permits it; use the live policy or explicit Actions cancellation to stop subsequent work. Neither is an atomic check/write transaction. |
| Label removed and reapplied, or a run rerun | Another execution must pass authorization and the existing reuse/fresh-creation checks. It does not receive permission to duplicate objects or retry ambiguous creates. |
| Existing clean result | Verify and reuse its existing identities through the current executor. |
| Text conflict or other unsupported preparation result | Preserve the current safe stop and authorized `needs-attention` feedback; no new resolver job and no branch/PR publication from an unverified result. |

The lifecycle is deliberately simple: the authorized platform event requests work, subject to live policy. There is no attempt to correlate it with a unique REST Issue-event timestamp or continually rebind authority to the currently present label. Existing source and actor checks remain at their current stage boundaries; policy and actor-allowlist decisions are additionally refreshed at each mutation boundary.

## Requirements

| ID | Requirement | Acceptance boundary |
|---|---|---|
| R1 | Accept `workflow_dispatch` and exact `pull_request_target` action `labeled` with `backport:29.x` in the fixed fork. Require a merged-main snapshot for labels and the existing authoritative merged-main source proof for both entries. | Ineligible input cannot reach a writer. Validate a canonical positive ASCII decimal source PR below `2147483648`. |
| R2 | Retain `BACKPORT_ALLOWED_ACTOR_IDS` and existing original/current actor checks, intersected with R8 policy authorization. Require the label event's numeric sender ID to match the original actor and be allowed. Execute trusted main automation, not PR-head code. | Neither PR authorship, label presence nor repository role substitutes for the numeric allowlist. A rerunner or a permissive current policy cannot authorize an originally unauthorized event. |
| R3 | Normalize both entries into the existing source/dry-run configuration in every stage. Preserve manual title shape and use the same per-source/per-target concurrency group for accepted manual and label runs. | Labels use `dry_run=false`; manual default remains true; `cancel-in-progress=false`. Event and environment projections must agree. |
| R4 | Extend the existing Actions-history parser and fresh-create guard for label runs while retaining manual history and ambiguity protection. | A possible prior writer for the same source or incomplete/unknown history blocks missing creates. A completed rejected label run may be excluded only with positive non-writer evidence. |
| R5 | Reuse existing stages, source/target proofs, artifact schemas/hashes, journals, object identities, create-only branches, verified PR read-back and feedback. | A label-created clean result follows the existing contract; conflicts stay unsupported for publication. Reruns and feedback recovery do not bypass missing-create guards. |
| R6 | Add focused deterministic tests using the actual workflow, raw event files, real controller stages, fake HTTP and owned local Git repositories. Keep existing regression coverage. | Local completion requires executed label coverage and retained regressions, not old migration results, hosted receipts or AL product tests. |
| R7 | Document the exact label, authorized users, after-merge timing, real-run behavior, manual alternative, repeat/recovery behavior, live-policy controls and cancellation limitations. | Distinguish implemented/tested locally from deployed or observed on GitHub. |
| R8 | Add the strictly parsed main-backed `request-policy.json`; require authorized actors and applicable enable switches at admission, before each repository mutation and after its read-back. | Missing, malformed, changed or unavailable policy stops further writes with Actions-only reporting. Preserve partial objects and journals; do not claim atomic cancellation. |

## Design

### Reuse the existing execution path

```text
workflow_dispatch                 pull_request_target:labeled
         \                         /
          normalize and authorize
                    |
              validate (read only)
                    |
                  track
                    |
                 prepare
                    |
                 publish
       (existing independent verification)
```

Keep the workflow's name, path and existing Actions history: `.github\workflows\backport-demo.yml`, **Backport to 29.x**. Do not add a second workflow or a privileged `workflow_run` bridge. Keep the existing manual/read-only executor-test workflow and unrelated integrations unchanged.

The inspected baseline already supplies `plan_ready=true` only after validation and complete source proof. Reuse that success signal and the current dependency graph rather than introducing a second acceptance protocol. Expose the named validate step's output if needed for explicit writer gating. Rejected input must not be admitted through `always()`; existing always-upload steps may still retain local evidence.

### Entry normalization and trusted execution

Add `pull_request_target` with `types: [labeled]` to the existing workflow. A base-branch filter for `main` can avoid wrong-base runs, but never replaces controller validation. Do not add merge/close, synchronize, unlabeled or scheduled triggers.

Read the event name and payload from the platform's event file, not PR-authored content. Add one small private normalization helper at the current `New-BackportContext` boundary:

- Manual: use the existing dispatch inputs and strict source/dry-run parsing.
- Label: require the exact event/action/label, fork repository identity, source number, merged-main snapshot and authorized numeric sender; derive `dry_run=false`.
- Compare the derived source/dry-run values to the workflow's `INPUT_SOURCE_PR` and `INPUT_DRY_RUN` projection. Missing/malformed values fail explicitly rather than defaulting to a real write.
- Retain the existing original actor allowlist and `Get-BackportRemoteContext` check of the current triggering user. Add the sender/original-actor cross-check and the live-policy intersection below, using existing GitHub HTTP/identity helpers rather than a new service.
- Reconstruct the normalized configuration from the same platform event in each stage and retain the existing run/attempt/source/dry-run artifact binding. Do not add `request.json`, event-generation hashes or a second state schema.

Retain the fork name/ID, main execution-ref and current source/target checks. Validate the workflow's main-backed execution reference and use its immutable workflow revision for the sparse executor checkout in all jobs, with the existing pinned action and `persist-credentials: false`. Do not substitute a PR head or synthetic merge revision. Keep source data in the existing isolated Git work directories and retain credential separation.

Retain the existing workflow allowlist and owner fallback; do not add or guess collaborator IDs. That workflow variable is a start-time snapshot, so it is not the live-revocation control. The main-backed policy below supplies that additional restriction.

### Live request policy

Add one owner-reviewed `.github\scripts\backport-demo\request-policy.json`, loaded as data only. Its initial content preserves existing authorized manual writes while leaving new label requests disabled:

```json
{
  "schema": 1,
  "repository_id": 1369849596,
  "allowed_actor_ids": [59250993],
  "label_requests_enabled": false,
  "writes_enabled": true
}
```

Require exactly these keys, schema 1, the fixed repository ID, a nonempty array of distinct positive integer actor IDs and actual JSON booleans. Reject duplicate/unknown keys, invalid types and missing files; never fall back to permissive defaults. The initial actor is the existing verified owner fallback, not a new collaborator approval. Tests use synthetic enabled policies to exercise real label mode; the checked-in label switch stays false until a separately approved enablement.

| Check | Contract |
|---|---|
| Trusted admission policy | Load and validate the file from the immutable workflow-revision checkout already used by every job. Require original/current actor IDs and the label sender ID, when applicable, in both the existing workflow allowlist and this policy. |
| Fresh current policy | Read the fixed fork's `/git/ref/heads/main`, then `/contents/.github/scripts/backport-demo/request-policy.json?ref=SHA` at that exact returned revision through the existing bounded HTTP client. Decode and strictly validate the returned file; never execute it. Repeat at stage admission and at each boundary below. |
| Policy binding | Compare SHA-256 digests of the decoded current policy bytes and the policy bytes from the immutable workflow checkout. A detected difference rejects the old request, even if the new policy is more permissive; a fresh request against the new workflow revision is required. This applies to both entry modes, including a label-switch-only edit during an active manual run. An unrelated main commit with identical policy bytes does not invalidate the request. |
| Actor checks | Require the original requester and independently verified current triggering actor in the fresh allowlist; include the matching label sender for label entry. The live policy can restrict but never widen the original admission. |
| Switches | Label requests require both switches true. Real manual requests require `writes_enabled=true`; a false label switch does not disable newly admitted manual requests, but the policy-binding rule still applies to older requests. Manual dry-runs remain non-writing and may proceed with `writes_enabled=false` if policy/schema/binding/actor checks otherwise pass. |
| Errors or withdrawal | Missing/malformed/unreadable policy, failed GETs, digest mismatch, disallowed actors or disabled applicable switches stop further writes. Emit a fixed sanitized reason in Actions, not a repository comment. |

The trusted workflow revision supplies the same admission-policy bytes in every stage. Recompute their digest and the live authorization decision in memory; do not introduce `request.json`, change existing artifact schemas or persist authority in a new sidecar. Keep selected policy revision/digest evidence in Actions output, not credentials, raw API contexts or customer data. Each job must use its own fresh policy reads; do not cache live policy across mutations.

Apply a final policy check immediately before Issue POST, create-only branch push, PR POST, and **each** comment POST/PATCH, including `needs-attention` and feedback-only recovery. Keep the existing source, patch, history and journal checks as well. Check policy again after each mutation's read-back and before reporting successful reuse/publication. A post-write withdrawal preserves the object and journal but stops subsequent writes, including the remaining feedback destination.

The policy read and GitHub mutation are not atomic: a change after the final read can race one in-flight write. A temporary policy change wholly between checks may not be observed. Do not promise instant or durable cancellation; use Actions cancellation when required and reconcile any partial result. A stopped request cannot bypass existing ambiguous-create guards by starting a new request. Older pre-feature workflow revisions do not gain these checks retroactively.

Keep the single existing workflow and narrow job tokens. Policy GETs use `contents: read` (already available, including through the publisher's contents-write permission); no PAT, App key, variable-read API, new writer job or global permission expansion is needed. Include the policy file in the existing trusted sparse checkout, not a PR-head checkout.

### Title, dry-run and concurrency

For accepted requests retain the existing title format, `Backport PR N to 29.x (dry run = true|false)`, and group `backport-demo-1369849596-N-29`. Labels always render `false`. Manual defaulting still comes from the declared boolean input.

Derive pre-job values from the event-specific source using contexts supported by `run-name` and workflow concurrency; downstream outputs cannot determine them. Use explicit `'true'`/`'false'` strings where GitHub expression truthiness would otherwise turn a manual false value into the wrong fallback. Do not parse arbitrary source text with `fromJSON`.

Unrelated or obviously ineligible label candidates should use a per-run rejected group rather than occupying another source request's group. GitHub expression equality is case-insensitive, so the controller's ordinal comparison remains authoritative. The shared group serializes accepted requests but is not a durable queue; pending-run replacement and conservative recovery behavior remain limitations, not a queue-management epic.

### Small, event-aware history extension

`Get-BackportRunIdentity` currently accepts only `workflow_dispatch`; `Assert-BackportFreshCreation` checks the same workflow's current run and unfiltered paginated history before missing creates. Extend these existing functions and their fake API seams, not a new history framework.

| History case | Required treatment |
|---|---|
| Known manual history | Preserve the existing strict identity/title/source/dry-run contract and current exemptions. |
| Current label run | Validate its event-specific run metadata against the normalized source, non-dry mode, run ID/attempt and fixed workflow identity. Only attempt 1 may create missing objects. |
| Known prior label run for the same source | Treat as a possible writer unless the bounded non-writer proof below succeeds; conclusion, current label state or a later rerun alone is not proof. |
| Known different-source run | Preserve per-source isolation only when source identity is unambiguous under the accepted event/title contract. |
| Completed rejected label run | It may be excluded when authenticated metadata and complete attempt-specific job records prove that no repository-writing job executed in any attempt. |
| Unknown, incomplete, running or ambiguous possible-writer history | Keep the conservative missing-create stop. Do not hide it with event/date filters, title-only rejection markers or a force-create flag. |

For the rejected-label case, add only the necessary bounded attempt/job GETs using the existing HTTP boundary. Validate the fixed workflow/run identity and complete expected job inventory, including skipped `track` and `publish` jobs with no executed steps, for every attempt. An empty/incomplete job list, unknown job layout or a latest skipped rerun after an earlier writer is not sufficient. Preserve pagination, duplicate-ID, attempt and current-run-presence checks.

Handle REST fields according to the event contract; do not assume a label run's PR association or `head_sha` is identical to manual metadata or the workflow revision. Contradictory or insufficient evidence remains an explicit error. Test the supported response shapes; do not invent undocumented event fields. No immutable automation-profile registry, general revision enrollment system, new queue exemption or live observation programme is required.

Keep the existing journal and ambiguous-create handling at each current boundary. Reapplying a label does not clear history or create a new branch/Issue/PR identity. Verified reuse remains distinct from permission to create a missing object.

### Existing executor and compatibility

| Existing surface | Label-related change |
|---|---|
| `New-BackportContext`, `Invoke-BackportCli`, `Invoke-Backport.ps1` | Event-aware normalization and sanitized rejection, retaining the four-stage CLI and runtime checks. |
| `Get-BackportRemoteContext` and a private policy helper | Reuse current authoritative source/target and user-ID checks; add trusted/current policy validation without polling label-event history. |
| `Get-BackportRunIdentity`, `Assert-BackportFreshCreation` | Narrow event-aware identity and rejected-label non-writer handling. |
| `Get-BackportBinding`, artifact readers and stage functions | Reuse current source/dry-run/run/attempt bindings and exact schema-1 contracts; validate the normalized request in each stage. |
| Tracking, preparation, publication and feedback | Retain existing behavior and identities; add live-policy checks before mutations and after read-back, including every feedback destination. |
| `TestHelpers.ps1`, `Backport.Tests.ps1` | Extend current event/run/job fixtures with policy responses and deterministic withdrawal hooks rather than building a parallel harness. |
| `Run-Tests.ps1` | Handle the intentional label-workflow change without deleting historical parity validation or skipping the new coverage. |

Keep `backport/29.x/pr-N`, existing source markers, bot-owned Issue/PR/comment identity, canonical hashes, journal keys, artifact names/retention and cross-attempt replay rejection. The source PR and tracking Issue should receive the existing verified release-PR link on success; the tracking Issue remains open while its PR is open.

The current test runner freezes historical workflow hashes/blocks. Update its explicit feature-contract handling in the same epic that changes the YAML, otherwise an intermediate epic will fail for a known baseline mismatch. Keep `parity.json` and `compat.json` as historical oracles; do not rewrite their history or simply disable the gate. Test the actual changed trigger, input, checkout, permission and dependency blocks.

## Implementation plan

L-001 is DONE as recorded below. L-002 implementation and its targeted gate are complete, with review/commit pending; L-003 remains TO DO. The current implementation task is scoped to L-002 only. L-002 includes history/stage integration and the live policy; L-003 completes local coverage/docs. Update task statuses and acceptance criteria in this file as work is actually completed.

### L-001: Add the label entry and normalized request

**Status:** COMPLETE (local L-001 only)

**Goal:** Feed an authorized exact post-merge label into the existing configuration while preserving manual dispatch.

**Requirements:** R1-R3, R6. **Prerequisites:** Accepted PowerShell baseline and the execution preparation below; no independent integration or hosted evidence.

**Historical restart guidance (resolved):** The first coder session reached its 3600-second limit while waiting for the full test runner. The restarted workflow continued its six in-scope modified files and completed L-001, including review and commit. Do not recreate this completed epic.

**Owner testing constraint:** "Do not create and run a lot of tests - only necessary." Reuse existing tests and fixtures, add only necessary coverage for this epic's acceptance criteria, and avoid redundant parameterized cases or test-count targets. Start with one focused selection covering the changed behavior; do not overlap test processes or repeatedly run the full suite during development. Investigate the previous runner stall before another full run. Broaden coverage only when affected behavior or the existing acceptance gate requires it, and reuse valid results for unchanged code during review. Preserve the historical parity gates; focused results must not be reported as full acceptance.

| Task ID | Type | Description | Files | Status |
|---|---|---|---|---|
| L1-1 | IMPL | Add strict event-file normalization, merged-main snapshot validation, numeric sender/original-actor checks and environment cross-checks at the current context boundary. Retain existing actor/source checks and sanitized errors. | `Backport.psm1`; `Invoke-Backport.ps1` only if its boundary needs adjustment | DONE |
| L1-2 | IMPL | Add the labeled trigger, event-aware input/title/concurrency expressions and trusted workflow-revision checkout. Wire existing validation success to the unchanged writer dependency path. Preserve manual defaults, action pins and least-privilege permissions. | `backport-demo.yml` | DONE |
| L1-3 | TEST | Add raw-event and actual-workflow cases LT-01 through LT-05. Extend existing helpers and update the runner's intentional label-workflow contract in this epic without replacing historical parity data. | `Backport.Tests.ps1`, `TestHelpers.ps1`, `Run-Tests.ps1` | DONE |

**Acceptance Criteria**

- [x] Exact authorized merged-main label input normalizes to the intended source and `dry_run=false`; manual true/default/false behavior is unchanged.
- [x] Invalid event, label, source, actor, repository or trust metadata cannot reach a writer; later merge/rerun cannot authorize an originally pre-merge event.
- [x] Accepted manual/label requests use the same source/target group; the actual title, input, checkout and dependency blocks are covered.
- [x] The existing test entry accepts the intentional feature workflow only through explicit assertions, not by disabling its baseline checks.

This epic establishes event/actor admission, not completed label publication. The manual-only history assumptions and live-policy enforcement are addressed in L-002 before feature completion or deployment.

**Local completion (2026-09-16):** Continued the inherited six-file implementation without adding more cases. The private context helper reuses strict JSON, ordinal literal, repository and numeric identity helpers; the CLI and authoritative remote checks remain unchanged. The runner reverses only explicitly asserted label-workflow edits before enforcing the historical hashes and protected blocks. `compat.json` and `parity.json` remain unchanged.

**Restart investigation:** The previous retained full result completed in 1616.54 seconds with 23 `uncaptured_stage_reference_input` failures; its subsequent run exceeded the coder session limit without a completed result. No orphaned test runner remained. The inherited manual-only reference adapter already addressed those input-shape failures without recapturing historical data; no runner deadlock was established.

**Executed results:** On Windows, PowerShell 7.6.6, .NET 10.0.12 and Pester 5.7.1, the existing `Run-Tests.ps1 -Epic L-001` selection passed 70 selected cases in 177.93 seconds (development only). One subsequent, non-overlapping unfiltered `Run-Tests.ps1` run passed all 480 cases in 1823.48 seconds, with zero failures, skips or unexecuted cases. The acceptance gate retained 67/67 baseline cases, 12/12 migration IDs and LT-01 through LT-05. XML results and the full progress log are retained outside the repository as `l001-focused.xml`, `l001-full.xml` and `l001-full.log`. Workflow expressions were checked by the scoped local fixture, not GitHub's runtime evaluator. No hosted mutation, deployment, L-002 or L-003 completion is claimed.

### L-002: Connect labels to existing stages, history and live policy

**Status:** DONE (reviewed and committed)

**Goal:** Make the existing executor process label requests with live-policy controls, preserving duplicate prevention and the single backport path.

**Requirements:** R2-R6, R8. **Prerequisites:** L-001.

**Restart and execution guidance:** Preserve and finish the existing uncommitted history, policy, test and fixture changes, including the new `request-policy.json`; do not recreate the implementation. The preceding L-002 coder timed out while waiting for an unfiltered run, without reaching review or commit. Run only `Run-Tests.ps1 -Epic L-002` and necessary affected regressions. Include and fix the existing `retains authoritative current-user IDs for label reruns` case in targeted coverage; do not weaken its authorization checks or enable the checked-in label policy. Coding, subagents and reviewers must not run the unfiltered suite or require it to approve this epic. Passing the targeted acceptance scenarios is sufficient for the L-002 gate; final full regression remains required by the independent L-003 step. Continue automatically to L-003 after this epic is approved and committed.

| Task ID | Type | Description | Files | Status |
|---|---|---|---|---|
| L2-1 | IMPL | Extend current run identity/history parsing for label metadata. Preserve manual history, attempt-1 creation limits and incomplete/possible-writer stops. Add bounded attempt-job proof only for completed rejected label runs. | `Backport.psm1` | DONE |
| L2-2 | IMPL | Verify and, where necessary, wire normalized configuration through all four current stages using existing artifact bindings. Preserve object/journal identity, independent verification and existing feedback/conflict behavior. | `Backport.psm1`, `backport-demo.yml` only if stage wiring requires it | DONE |
| L2-3 | TEST | Add LT-06 through LT-09 using existing fake API and owned Git fixtures: rejected-label history, first creation, mixed-entry reuse, ambiguous recovery and conflict stop. Extend explicit feature coverage in the runner as needed. | `Backport.Tests.ps1`, `TestHelpers.ps1`, `Run-Tests.ps1` | DONE |
| L2-4 | IMPL | Add the strict trusted/main-backed policy and initial disabled-label configuration. Intersect actor authorization, enforce switches and policy-byte binding at admission, and place fresh checks before every Issue/push/PR/comment mutation and after read-back, including reuse and feedback recovery. | `request-policy.json`, `Backport.psm1`; `backport-demo.yml` only if needed for trusted policy checkout | DONE |
| L2-5 | TEST | Add LT-11 through LT-13: policy schema/allowlist/switches, old-request policy changes, unreadable policy and withdrawal at every write/feedback boundary, including an in-flight race. Assert preserved partial objects and Actions-only stops using deterministic callbacks. | `Backport.Tests.ps1`, `TestHelpers.ps1`, `Run-Tests.ps1` | DONE |

**Acceptance Criteria**

- [x] A clean authorized label event with a synthetic enabled policy traverses the real local stages, creates exactly the expected Issue/branch/PR/comments in fixtures, and verifies the resulting content.
- [x] Manual/label repeats reuse verified identities; neither relabeling nor a rerun bypasses ambiguous or missing-create guards.
- [x] Positively proven rejected non-writers do not poison later creation; possible writers, incomplete evidence and earlier writing attempts still block missing creates.
- [x] Existing artifact/patch-tampering checks remain effective and a conflict cannot publish a branch or PR.
- [x] Disabled switches, revoked actors, invalid/unreadable policy and detected policy changes prevent further writes at every boundary, including feedback; prior objects and journal entries remain intact.
- [x] An authorized manual dry-run remains available under a valid write-disabled policy; labels are rejected, never silently converted to dry runs. The initial checked-in policy leaves labels disabled.
- [x] Policy checks work without label-generation tracking, a profile registry, sidecar/schema changes or additional credentials.

**Local completion (2026-09-16):** Preserved the inherited executor, history, live-policy, runner and fixture changes. Reused the existing LT-06 through LT-09 and LT-11 through LT-13 cases without adding test functions. Included all five `retains authoritative current-user IDs for label reruns` cases in the L-002 selection. The first targeted run reproduced one failure: numeric rerunner 12 was in the test's workflow allowlist but absent from its synthetic policy. Aligned only that test's trusted/live policy allowlist and asserted that the authoritative current-user ID is retained. The unauthorized and invalid-type rejection assertions remain unchanged. Extended the existing switch case to assert the checked-in owner allowlist, disabled labels and enabled manual writes; production policy and authorization were not relaxed.

**Targeted evidence:** Two sequential, non-overlapping `Run-Tests.ps1 -Epic L-002` runs used PowerShell 7.6.6, .NET 10.0.12 and Pester 5.7.1. The reproduction passed 45/46 cases in 548.03 seconds; the corrected selection passed 46/46 in 541.66 seconds, including all five authoritative rerunner cases, with zero failures or skips. XML and logs are retained outside the repository under `C:\Users\algladkov\.copilot\session-state\c36ee05c-8762-47c7-8026-3451edfa84f2\files` as `l002-before.xml`, `l002-before.log`, `l002-targeted.xml` and `l002-targeted.log`.

**Limitations and handoff:** These results satisfy the owner-approved local L-002 targeted gate only. The selection left 463 other discovered cases unexecuted; no unfiltered suite, hosted mutation, deployment or AL product validation ran in this session. Full acceptance remains pending the independent script after L-003. L3-1/L3-3 and all other L-003 work remain unchanged and pending. This coder session stops at L-002 for review and commit.

### L-003: Complete local regression coverage and operator documentation

**Goal:** Finish the label feature with the existing test entry and concise usage documentation.

**Requirements:** R1-R8. **Prerequisites:** L-001 and L-002.

**Execution guidance:** Finalize documentation, the actual-workflow LT-10 contract and the runner's final required coverage first, using only targeted checks. Then return from the coder session with full-run-dependent criteria still pending. The external workflow's `full_tests` script executes the existing unfiltered `Run-Tests.ps1` after the coder session ends and before epic review/commit. On failure, inspect its retained log/XML and fix only the necessary regressions using focused selections; return so the independent script can rerun. After a successful script result, the reviewer verifies the evidence and the committer records actual results and completes L3-1/L3-3. Never claim completion merely because the test process started. The final review consumes the same content-bound result; code/test changes invalidate it, documentation-only changes do not.

| Task ID | Type | Description | Files | Status |
|---|---|---|---|---|
| L3-1 | TEST | Prepare the full existing Pester entry including new label and live-policy cases for the independent acceptance script. Require them to execute, and resolve feature-caused failures using targeted checks before the script reruns. Record completion only after its full gate passes. Preserve manual/read-only test-workflow behavior; change its invocation only if needed to include the cases. | `Backport.Tests.ps1`, `TestHelpers.ps1`, `Run-Tests.ps1`; `backport-demo-tests.yml` only if necessary | TO DO |
| L3-2 | IMPL | Document authorized post-merge label usage, manual dry-run, policy allowlist/switch controls and initial values, policy-change/fresh-request behavior, existing recovery and conflict stop. Explain removal-not-cancellation, policy check/write races and older-run limitations; state local/deployed status honestly. | `README.md` | TO DO |
| L3-3 | TEST | Cover the final actual-workflow contract and acceptance entry in LT-10; record the new case results and retained regression result without claiming GitHub or AL product validation. | `Backport.Tests.ps1`, `Run-Tests.ps1`, `README.md` | TO DO |

**Acceptance Criteria**

- [ ] New label/policy cases and retained regressions execute through the existing test runner and pass; a filtered development selection is not reported as full acceptance.
- [ ] Operator instructions match the implemented lifecycle and retain manual dispatch as an alternative.
- [ ] The live policy is covered locally; completion needs no resolver, generation tracking, profile registry, sidecar or hosted acceptance run.
- [ ] Documentation distinguishes local completion from deployment and leaves hosted actions to separate approval.

## Focused test matrix

All scenarios remain **TO DO** at preparation. Reuse parameterized cases and existing helpers; the rows describe behaviors, not a quota of new test functions.

| ID | Requirements | Scenario and essential assertions |
|---|---|---|
| LT-01 | R1-R3 | Parse an actual synthetic labeled-event file: exact fork/main/merged/label/sender yields the canonical source and non-dry configuration; missing or conflicting projections reject. |
| LT-02 | R1, R3 | Manual default/true remains write-free; explicit false remains real. Reject malformed PR/dry values; test workflow-declared defaulting separately from a missing raw controller value. |
| LT-03 | R1-R2 | Wrong label, case/whitespace variant, unsupported action/event, wrong repository/base/ref and unmerged/closed-unmerged snapshots perform no writes. Include an old pre-merge event processed after merge. |
| LT-04 | R2 | Allowed sender/original/current actors pass; sender mismatch or an unauthorized original actor/rerunner rejects. Retain the existing authoritative user-ID checks. |
| LT-05 | R3, R6 | Read actual YAML input/title/concurrency/checkout blocks. Accepted label and manual requests share the expected key; false/default truthiness and ordinal-controller rejection remain correct. |
| LT-06 | R4 | Preserve manual history; recognize label identity; prove completed rejected-label non-writers from complete all-attempt jobs. Missing/unknown job evidence, malformed pagination and an earlier writer followed by a skipped rerun block creates. |
| LT-07 | R3-R5 | Run real local stages for a clean label request against owned Git origins/fake HTTP. Verify one Issue, one create-only branch, one release PR and existing two-destination feedback, with exact resulting content. |
| LT-08 | R4-R5 | Mixed manual/label requests and reruns reuse verified IDs/heads/comments. Retain lost-response, prior-writer and missing-comment ambiguity stops; do not add a special queued-writer exemption. |
| LT-09 | R5 | Exercise label-origin source/target/artifact mismatch rejection and the existing conflict safe stop. No conflict resolver is invoked and no unverified result publishes. |
| LT-10 | R1-R8 | Validate the final workflow graph/permissions/artifact contract, trusted policy checkout and runner coverage. Full retained regressions plus new feature cases execute; historical parity data remains intact. |
| LT-11 | R2, R3, R8 | Strict policy schema, numeric allowlist intersection and both switches. Cover label disabled, all writes disabled, authorized manual dry-run, unauthorized original/current actors and missing/malformed policies; no permissive fallback. |
| LT-12 | R2, R5, R8 | Change the live allowlist/switches or lose a policy GET before each Issue/push/PR/comment boundary, between feedback destinations and before comment PATCH/reuse reporting. Assert no later writes and preserve already-created objects/journals; denial reporting is Actions-only. |
| LT-13 | R5, R8 | Compare immutable checkout policy with fresh main-pinned bytes: a detected policy edit requires a fresh request, unchanged bytes on a new main commit are valid, and a more permissive policy cannot widen an old request. Change policy inside the check/write seam; allow only the already in-flight mutation, then stop after read-back. |

Use `New-BackportStageTest`, `Invoke-BackportTestStages`, `New-StageAttempt`, `New-FakeWorkflowRun`, `New-FakeGitHub` and `Set-StageConflict`. Add only the raw event, attempt-job and policy fixtures/withdrawal callbacks required by the cases; keep unknown fake routes and unintended network access failing explicitly. Use matching synthetic trusted/current policy bytes for enabled-label fixtures without modifying the checked-in defaults, then change the current-policy fixture independently for withdrawal cases. Fake the current main ref and exact revision-pinned policy response independently so tests catch stale or unpinned reads. Verify API traces and owned local Git refs, not only mocked normalized objects.

Use the existing workflow-block assertions and focused expression fixtures. Do not build a general YAML/Actions expression engine. A local fixture verifies the supported contract, not GitHub's runtime evaluator; report that distinction.

## Files affected

Paths below are relative to the target repository root; filenames in the task tables refer to these exact files.

| File | Planned change |
|---|---|
| `.github\scripts\backport-demo\label-backport.plan.md` | This approved execution copy, established in a separate preparation commit; normal task/acceptance status and actual-result updates in each scoped epic commit. |
| `.github\scripts\backport-demo\request-policy.json` | New strict owner-reviewed allowlist and label/write switches; labels initially disabled. |
| `.github\workflows\backport-demo.yml` | Label entry, normalized expressions, trusted executor/policy checkout and validation/dependency wiring. |
| `.github\scripts\backport-demo\Backport.psm1` | Event normalization/authorization, live-policy reads and mutation checks, narrow label-aware history handling and existing-stage integration. |
| `.github\scripts\backport-demo\Invoke-Backport.ps1` | Only necessary CLI-boundary changes for event parsing/rejection; keep four stages. |
| `.github\scripts\backport-demo\Backport.Tests.ps1` | Focused label, live-policy/withdrawal and compatibility tests alongside retained regressions. |
| `.github\scripts\backport-demo\TestHelpers.ps1` | Synthetic event, attempt-job and pinned-policy fixtures plus withdrawal callbacks using current fake API/Git helpers. |
| `.github\scripts\backport-demo\Run-Tests.ps1` | Explicit feature-workflow assertions and inclusion of label coverage while preserving historical parity. |
| `.github\scripts\backport-demo\README.md` | Label usage, live-policy controls/limits, existing recovery and actual local results. |
| `.github\workflows\backport-demo-tests.yml` | Only if its current invocation does not already execute the added coverage; preserve manual/read-only scope. |

The single live policy is the only new production configuration file; no new state/profile/sidecar files, AL fixtures or deleted files are planned. Reuse existing test files for label/policy fixtures. `compat.json`, `parity.json`, the separate auth-smoke workflow, historical migration documents, external plans, internal skills and Octane assets are not implementation targets.

## Execution preparation for the approved run-specific workflow

1. Use the selected fork root and feature branch. The accepted baseline was confirmed before preparation. Do not switch branches; the local feature branch does not change the production requirement for trusted main workflow code.
2. Preserve pre-existing work. The Python baseline exporter is saved in an existing stash and is not part of this feature; do not apply or drop that stash. The unrelated `/.github/skills/` ignore addition has already been moved into this repository's local `.git\info\exclude` and the tracked `.gitignore` restored by owner approval. Do not stage local excludes or unrelated files. The five modified tracked files and new `request-policy.json` from the interrupted L-002 run, including this plan's guidance updates, are expected in-scope work. Preserve them; keep abandoned test fixtures outside the repository.
3. This execution copy was established in preparation commit `1372c3742`. Keep its links self-contained and use this file as the status source. Do not copy internal documents, introduce an outside-repository symlink, stage another repository or automatically synchronize the external original. Include normal scope/status updates to this copy in the next epic commit.
4. Run the packaged `conductor-sdd-runtime` prerequisite step once per session. Start a fresh run against this plan without an epic filter, rather than resuming a failed checkpoint. Skip completed L-001, execute L-002 and L-003 in order, then complete holistic review.
5. Use the owner-approved external `implement-targeted.yaml` copy and `Invoke-FinalBackportTests.ps1`, leaving the installed workflow unchanged. The copy preserves epic selection, review, commits and holistic fixes; it replaces per-coder full runs with targeted checks and independent `full_tests`/`final_tests` script gates. Run Conductor in a foreground terminal from this repository root with `--quiet run --workspace-instructions`, the absolute workflow and execution-plan paths and `--web-bg`. Omit the optional `epic` input. Share the returned dashboard URL and stop watching.

The earlier L-001 timeout recovery is complete. The current run continues interrupted L-002 work, not a failed provider session. Preserve committed and in-progress work. Keep test and orchestration artifacts outside the repository and out of epic commits. Apply the owner testing constraint throughout coding, review and fixes for both remaining epics.

The stock `epic_diff` captures `git status --porcelain`, not a before/after baseline. Its reviewer may treat pre-existing dirty files as epic work, and its committer says to stage all modified files including the plan. Its coder has no dedicated blocked-result exit. Prepared scope and clean working-tree state reduce these risks; this plan does not claim that the unchanged runner automatically excludes unrelated changes or guarantees termination of blocked review loops. Stop for owner guidance if unrelated work appears.

Every epic/fix commit in this orchestration session must include these trailers:

```text
Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Copilot-Session: 6159a05f-2cf0-45d4-86b2-05355fe954c6
```

No push is authorized by a local commit. Implement one epic at a time, respecting prerequisites, but do not stop the current workflow after L-002: both remaining epics and final holistic review are authorized.

## Completion and optional hosted follow-up

Local completion means the three epics meet their local acceptance criteria and the label/live-policy cases plus retained regressions pass. Local code/commits do not deploy the trigger or authorize hosted label writes. Policy behavior is proven with synthetic fixtures while the checked-in policy leaves labels disabled; enabling labels on GitHub is not required for local completion. No independent resolver contract, live observation gate or hosted evidence programme is required.

After separate owner approval for deployment, policy enablement and the exact source PR, an operator may run a manual default dry-run and an authorized post-merge label on a cleanly applicable source to confirm GitHub's actual trigger/title/ref/concurrency and the resulting Issue/PR links. Enable labels through a reviewed policy change, then use a fresh request against that revision. This is a later smoke check, not an implementation epic. Record what actually ran; do not call local fixtures hosted proof or claim an AL build, merged PR or shipped fix.

Removing the trigger prevents new label requests, not already running work. A reviewed `label_requests_enabled=false` policy prevents label admission; `writes_enabled=false` prevents real writes from both entry modes. Any detected policy-byte edit also invalidates older feature-aware requests at their next check, even when only the label switch changed. Use approved Actions cancellation when needed, especially for older runs that lack policy checks, and reconcile any in-flight result. If reverting to manual-only entry later, retain live-policy enforcement and label-aware history handling. Preserve journals, history and existing objects; no reset, force push or deletion-based recovery is prescribed.

## References

| Reference | Use |
|---|---|
| [Executor README](README.md), [compatibility oracle](compat.json) and [parity oracle](parity.json) | Accepted baseline behavior and historical results, not new label-test evidence. |
| [Accepted automation tree](https://github.com/AleksanderGladkov/BCApps-Backport-Test/tree/e7629fc2348d160ecc857387e47a3f7bd5cf7e41/.github/scripts/backport-demo) | Existing executor, tests and data to extend. |
| [GitHub workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target) | Label event, base/ref semantics and trusted execution. |
| [Expressions](https://docs.github.com/en/actions/reference/workflows-and-actions/expressions) and [concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency) | Supported contexts, truthiness, comparison and pending-run limits. |
| [Workflow runs](https://docs.github.com/en/rest/actions/workflow-runs) and [workflow jobs](https://docs.github.com/en/rest/actions/workflow-jobs) | Existing run identity and bounded attempt-specific non-writer evidence. |

Preparation of this copy does not establish implementation completion, a new test result or hosted approval.
