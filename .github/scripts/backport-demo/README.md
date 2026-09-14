---
title: Manual backport test workflow
description: Alexander's fork-only clean backport executor and Milica's conflict handoff.
---

## Run it

1. Enable only Backport executor tests and Backport to 29.x in this fork.
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

The workflow calls the trusted [controller](controller.py) in four stages:
validate, track, prepare, publish. [Tests](test_controller.py) use only Python's
standard library and Git. No product AL build is performed by these tests.

Each job keeps state under RUNNER_TEMP/backport-state and uploads the whole
directory even on failure. It contains the validated plan, Issue tracking,
result, patch, and any publication-attempt journal. Never drop the journal
when diagnosing an uncertain write. Logs avoid secrets and untrusted PR text.

Token-created PR workflows may require manual owner approval. A successful
backport run is evidence of PR preparation only, not a passed BCApps build.

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
