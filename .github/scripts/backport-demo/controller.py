"""Fork-only manual backport executor; Python stdlib and Git, no AI calls.

CLI: controller.py {validate|track|prepare|publish}. Each job supplies GH_TOKEN,
the same INPUT_* and GITHUB_* context, and downloads preceding state artifacts
into STATE_DIR (default RUNNER_TEMP/backport-state). WORK_DIR defaults to
RUNNER_TEMP/backport-work. Always run this trusted script outside the work repo.

Artifacts: plan.json, tracking.json, result.json, patch.bin, conflict.json;
publication.json is the local publish-attempt journal and MUST also be kept
with failed-job artifacts. Outputs: plan_ready, issue_number, status,
result_artifact, result_sha256, pr_url. Conflict
handoff: repo, source_pr, source_sha, target_base_sha, worktree, files
[{relative_path, absolute_path}]. Worktree paths are local to the prepare job.
Results are never executable; publish repeats the cherry-pick and content proof.

No POST/PATCH or push retries. Ambiguous writes are recorded before attempting
them; a repeat must reconcile a unique bot-owned object or stop. API listing
cannot prove global absence under eventual consistency across different runs.
Before creating a missing object or branch, authenticated Actions history for
backport-demo.yml must include this exact run, repository, source and attempt.
Any other possibly-writing run for this source, any rerun attempt, or unknown /
incomplete history blocks creation, even when object listings are empty. Exact
visible objects can still be verified and reused; existing comments can be
PATCHed. Known dry runs do not block a fresh attempt. Track/publish need
actions:read. History is re-read before each creation, never a retry permission.
This conservative gate is NOT a durable exactly-once ledger: deleted or omitted
Actions history cannot be detected, and retention/eventual visibility limit it.
Do not delete history to recover or blindly retry an ambiguous creation; stop
for manual reconciliation when the exact remote effects cannot be proven.
The workflow must serialize this source/target and protect ALLOWED_ACTOR_IDS.
Rerun all jobs: artifacts from a different run attempt are intentionally rejected.
Target advancement is conservatively needs-attention, even on a PR rerun.
"""

import argparse
import base64
from dataclasses import dataclass, field
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.parse
import urllib.request


REPOSITORY = "AleksanderGladkov/BCApps-Backport-Test"
REPOSITORY_ID = 1369849596
OWNER_ID = 59250993
BOT_ID = 41898282
TARGET = "releases/29.x"
MAX_FILES = 50
MAX_FILE = 1024 * 1024
MAX_PATCH = 5 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{40}")
HASH = re.compile(r"[0-9a-f]{64}")


class Failure(Exception):
    """A fixed, non-secret reason code, safe for logs and workflow summaries."""


def require(condition, reason):
    if not condition:
        raise Failure(reason)


def positive(value, maximum=None):
    require(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]{0,19}", value), "invalid_number")
    number = int(value)
    require(maximum is None or number < maximum, "invalid_number")
    return number


def sha(value):
    require(isinstance(value, str) and SHA.fullmatch(value), "invalid_sha")
    return value


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def validate_path(value):
    require(isinstance(value, str) and value.startswith("src/") and value.endswith(".al"), "invalid_path")
    require(not any(unicodedata.category(ch).startswith("C") for ch in value), "invalid_path")
    require(not any(ch in value for ch in '\\:<>"|?*'), "invalid_path")
    parts = value.split("/")
    for part in parts:
        require(part not in ("", ".", "..") and not part.endswith((" ", ".")), "invalid_path")
        require(not part.lower().startswith(".git"), "invalid_path")
        require(not re.fullmatch(r"(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])", part.split(".")[0]), "invalid_path")
    return value


def parse_raw_diff(raw):
    fields = raw.split(b"\0")
    require(fields.pop() == b"" and len(fields) % 2 == 0, "invalid_diff")
    entries = []
    for header, filename in zip(fields[::2], fields[1::2]):
        match = re.fullmatch(rb":(\d{6}) (\d{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMD])", header)
        require(match is not None, "invalid_diff")
        old_mode, new_mode, old_id, new_id, status = [x.decode("ascii") for x in match.groups()]
        require(old_mode in ("000000", "100644") and new_mode in ("000000", "100644"), "unsafe_mode")
        require((old_mode == "000000") == (old_id == "0" * 40) == (status == "A"), "invalid_diff")
        require((new_mode == "000000") == (new_id == "0" * 40) == (status == "D"), "invalid_diff")
        try:
            path = validate_path(filename.decode("utf-8", errors="strict"))
        except UnicodeError:
            raise Failure("invalid_path") from None
        entries.append((path, old_mode, new_mode, old_id, new_id, status))
    require(len(entries) <= MAX_FILES, "too_many_files")
    require(len({x[0].casefold() for x in entries}) == len(entries), "ambiguous_paths")
    return entries


@dataclass(frozen=True)
class Config:
    source_pr: int
    dry_run: bool
    actor_id: int
    triggering_actor: str
    allowed_actor_ids: tuple
    run_id: str
    run_attempt: str
    state_dir: Path
    work_dir: Path
    token: str = field(repr=False)
    output: str = ""
    summary: str = ""

    @classmethod
    def from_env(cls, env):
        require(env.get("GITHUB_REPOSITORY") == REPOSITORY, "wrong_repository")
        require(env.get("GITHUB_REPOSITORY_ID") == str(REPOSITORY_ID), "wrong_repository_id")
        require(env.get("GITHUB_REF") == "refs/heads/main", "wrong_execution_ref")
        raw_allowed = env.get("ALLOWED_ACTOR_IDS", str(OWNER_ID))
        allowed = tuple(positive(x) for x in raw_allowed.split(","))
        actor = positive(env.get("GITHUB_ACTOR_ID", ""))
        require(actor in allowed, "actor_not_allowed")
        triggering = env.get("GITHUB_TRIGGERING_ACTOR", "")
        require(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", triggering), "invalid_triggering_actor")
        dry = env.get("INPUT_DRY_RUN")
        require(dry in ("true", "false"), "invalid_dry_run")
        source_pr = positive(env.get("INPUT_SOURCE_PR", ""), 2 ** 31)
        run_id, attempt = env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", "")
        positive(run_id)
        positive(attempt)
        temp = env.get("RUNNER_TEMP", "")
        require(temp or (env.get("STATE_DIR") and env.get("WORK_DIR")), "missing_local_directories")
        state = Path(env.get("STATE_DIR") or str(Path(temp) / "backport-state")).resolve()
        work = Path(env.get("WORK_DIR") or str(Path(temp) / "backport-work")).resolve()
        script = Path(__file__).resolve()
        require(state != work and not state.is_relative_to(work) and not work.is_relative_to(state), "overlapping_directories")
        require(not script.is_relative_to(work) and not script.is_relative_to(state), "script_inside_work_directory")
        token = env.get("GH_TOKEN", "")
        require(token and not any(ch.isspace() for ch in token), "missing_or_invalid_token")
        return cls(source_pr, dry == "true", actor, triggering, allowed, run_id, attempt,
                   state, work, token, env.get("GITHUB_OUTPUT", ""),
                   env.get("GITHUB_STEP_SUMMARY", env.get("GITHUB_SUMMARY", "")))

    def binding(self):
        return {"schema": 1, "repository": REPOSITORY, "repository_id": REPOSITORY_ID,
                "source_pr": self.source_pr, "dry_run": self.dry_run,
                "run_id": self.run_id, "run_attempt": self.run_attempt}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Failure("api_redirect_rejected")


class GitHub:
    def __init__(self, cfg):
        self.cfg = cfg
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method, path, data=None):
        require(path.startswith(("/repos/" + REPOSITORY, "/users/")), "invalid_api_path")
        require(method in ("GET", "POST", "PATCH"), "invalid_api_method")
        require(method == "GET" or not self.cfg.dry_run, "dry_run_write_blocked")
        request = urllib.request.Request(
            "https://api.github.com" + path, method=method,
            data=encoded(data) if data is not None else None,
            headers={"Authorization": "Bearer " + self.cfg.token,
                     "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                     "Content-Type": "application/json", "User-Agent": "bc-backport-demo"})
        try:
            with self.opener.open(request, timeout=60) as response:
                raw = response.read(16 * 1024 * 1024 + 1)
                require(len(raw) <= 16 * 1024 * 1024, "api_response_too_large")
                return json.loads(raw)
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            raise Failure("api_read_failed" if method == "GET" else "api_write_ambiguous") from None


class GitRepo:
    def __init__(self, cfg, *, origin=None, allow_file=False):
        # Local origins are an explicit Python test seam, never an environment/CLI input.
        require(origin is None or allow_file, "local_origin_forbidden")
        self.cfg = cfg
        self.origin = origin or "https://github.com/" + REPOSITORY + ".git"
        self.allow_file = allow_file
        self.keep = False
        cfg.work_dir.mkdir(parents=True, exist_ok=True)
        self.path = Path(tempfile.mkdtemp(prefix="repo-", dir=cfg.work_dir)).resolve()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("GIT_") and k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0", GIT_ATTR_NOSYSTEM="1", LC_ALL="C")
        self.run("init", "--template=")
        for key, value in (("user.name", "github-actions[bot]"),
                           ("user.email", "41898282+github-actions[bot]@users.noreply.github.com"),
                           ("core.autocrlf", "false"), ("core.attributesFile", os.devnull),
                           ("core.longpaths", "true"), ("commit.gpgsign", "false")):
            self.run("config", key, value)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if not self.keep:
            def writable(function, path, error):
                os.chmod(path, 0o700)
                function(path)
            shutil.rmtree(self.path, onexc=writable)

    def command(self, args, data=None, auth=False):
        env = self.env.copy()
        if auth:
            require(not self.cfg.dry_run, "dry_run_write_blocked")
            credential = base64.b64encode(("x-access-token:" + self.cfg.token).encode()).decode("ascii")
            env.update(GIT_CONFIG_COUNT="1",
                       GIT_CONFIG_KEY_0="http.https://github.com/" + REPOSITORY + ".git.extraHeader",
                       GIT_CONFIG_VALUE_0="Authorization: Basic " + credential)
        try:
            return subprocess.run(
                ["git", "-c", "core.hooksPath=", "-c", "protocol.file.allow=" + ("always" if self.allow_file else "never"),
                 "-c", "protocol.ext.allow=never", "-c", "http.followRedirects=false",
                 "-c", "submodule.recurse=false", "-c", "core.fsmonitor=false",
                 "-c", "core.quotePath=true", "-C", str(self.path), *args],
                input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=env, timeout=180, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise Failure("git_operation_failed") from None

    def run(self, *args, data=None):
        result = self.command(args, data)
        require(result.returncode == 0, "git_operation_failed")
        return result.stdout

    def text(self, *args):
        return self.run(*args).decode("utf-8").strip()

    def fetch(self):
        self.run("fetch", "--no-tags", "--no-recurse-submodules", self.origin,
                 "+refs/heads/main:refs/remotes/demo/main",
                 "+refs/heads/releases/29.x:refs/remotes/demo/target",
                 "+refs/pull/" + str(self.cfg.source_pr) + "/head:refs/remotes/demo/head")

    def ancestor(self, old, new):
        result = self.command(("merge-base", "--is-ancestor", old, new))
        require(result.returncode in (0, 1), "git_ancestry_failed")
        return result.returncode == 0

    def raw(self, old, new):
        return self.run("diff", "--raw", "--no-abbrev", "-z", "--no-renames",
                        "--no-ext-diff", "--no-textconv", old, new, "--")

    def patch(self, old, new):
        value = self.run("diff", "--binary", "--full-index", "--no-renames",
                         "--no-ext-diff", "--no-textconv", old, new, "--")
        require(len(value) <= MAX_PATCH, "patch_too_large")
        return value

    def checked_diff(self, old, new):
        raw = self.raw(old, new)
        entries = parse_raw_diff(raw)
        for oid in {x[i] for x in entries for i in (3, 4)} - {"0" * 40}:
            require(int(self.text("cat-file", "-s", oid)) <= MAX_FILE, "file_too_large")
            require(b"\0" not in self.run("cat-file", "blob", oid), "binary_file")
        return raw, entries, self.patch(old, new)

    def prove(self, source, head, target, commits, count=None):
        require(self.text("rev-parse", "refs/remotes/demo/head") == head, "source_head_changed")
        require(self.ancestor(source, "refs/remotes/demo/main"), "source_not_on_main")
        require(self.ancestor(target, "refs/remotes/demo/target"), "target_history_changed")
        parents = self.text("rev-list", "--parents", "-n", "1", source).split()
        require(len(parents) == 2, "source_not_squash")
        parent = sha(parents[1])
        # A single PR commit equal to source/head is complete. For multiple
        # commits, taking only the tip of a fast-forward/rebase loses earlier edits.
        require(source not in commits or commits == [source], "source_not_squash")
        # Otherwise merge-base(parent, head) can hide PR commits already in parent,
        # making the two raw diffs match even though source copies only the tail.
        require(not any(self.ancestor(commit, parent) for commit in commits), "source_not_squash")
        bases = self.text("merge-base", "--all", parent, head).splitlines()
        require(len(bases) == 1, "ambiguous_merge_base")
        raw, entries, patch_bytes = self.checked_diff(parent, source)
        require(entries and raw == self.raw(sha(bases[0]), head), "source_not_squash")
        require(count is None or (type(count) is int and len(entries) == count), "changed_files_mismatch")
        return [x[0] for x in entries], patch_bytes

    def apply(self, plan):
        source, target = plan["source_sha"], plan["target_base_sha"]
        self.run("checkout", "--detach", target)
        if self.ancestor(source, target):
            return {"status": "already_applied", "reason": "source_ancestor"}, b"", []
        original_patch = self.patch(source + "^", source)
        reverse = self.command(("apply", "--reverse", "--check", "--binary", "-"), original_patch)
        if reverse.returncode == 0:
            return {"status": "already_applied", "reason": "reverse_patch_proven"}, b"", []
        picked = self.command(("cherry-pick", "-x", source))
        if picked.returncode:
            conflicts = self.run("diff", "--name-only", "--diff-filter=U", "-z").split(b"\0")
            files = [validate_path(x.decode("utf-8")) for x in conflicts if x]
            require(set(files) <= set(plan["files"]), "unexpected_conflict_paths")
            require(files, "unproven_empty_or_failed_cherry_pick")
            return {"status": "needs-attention", "reason": "cherry_pick_conflict"}, b"", files
        commit = sha(self.text("rev-parse", "HEAD"))
        _, entries, patch_bytes = self.checked_diff(target, commit)
        require(entries and {x[0] for x in entries} <= set(plan["files"]), "unexpected_result_paths")
        require(self.text("rev-parse", commit + "^") == target, "wrong_commit_parent")
        return {"status": "applied", "reason": "clean_cherry_pick", "commit_sha": commit,
                "tree_sha": sha(self.text("rev-parse", "HEAD^{tree}"))}, patch_bytes, []

    def branch_head(self, branch):
        raw = self.run("ls-remote", "--heads", self.origin, "refs/heads/" + branch).splitlines()
        require(len(raw) <= 1, "ambiguous_branch")
        if not raw:
            return None
        fields = raw[0].decode("ascii").split("\t")
        require(len(fields) == 2 and fields[1] == "refs/heads/" + branch, "invalid_branch_response")
        head = sha(fields[0])
        self.run("fetch", "--no-tags", "--no-recurse-submodules", self.origin,
                 "+refs/heads/" + branch + ":refs/remotes/demo/backport")
        require(self.text("rev-parse", "refs/remotes/demo/backport") == head, "branch_changed")
        return head

    def verify_branch(self, head, plan, tree):
        parents = self.text("rev-list", "--parents", "-n", "1", head).split()
        require(parents == [head, plan["target_base_sha"]], "existing_branch_parent_mismatch")
        require(self.text("rev-parse", head + "^{tree}") == tree, "existing_branch_tree_mismatch")
        stamp = "(cherry picked from commit " + plan["source_sha"] + ")"
        require(stamp in self.text("show", "-s", "--format=%B", head).splitlines(), "existing_branch_provenance_mismatch")

    def push(self, branch):
        require(not self.cfg.dry_run, "dry_run_write_blocked")
        result = self.command(("push", "--porcelain", self.origin,
                               "--force-with-lease=refs/heads/" + branch + ":",
                               "HEAD:refs/heads/" + branch), auth=True)
        require(result.returncode == 0, "push_failed_or_ambiguous")


PLAN_FIELDS = {"source_sha", "source_head_sha", "target_ref", "target_base_sha", "files", "commits"}
TRACK_FIELDS = {"plan_hash", "status", "issue_number", "issue_id", "issue_url"}
RESULT_FIELDS = {"plan_hash", "status", "reason", "published", "commit_sha", "tree_sha", "patch_sha256"}


class Controller:
    def __init__(self, cfg, *, api=None, repo_factory=GitRepo):
        self.cfg = cfg
        self.api = api or GitHub(cfg)
        self.repo_factory = repo_factory
        self.root = "/repos/" + REPOSITORY
        self.branch = "backport/29.x/pr-" + str(cfg.source_pr)

    def save(self, name, value):
        self.cfg.state_dir.mkdir(parents=True, exist_ok=True)
        fd, path = tempfile.mkstemp(prefix=".state-", dir=self.cfg.state_dir)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(value if isinstance(value, bytes) else encoded(value))
            os.replace(path, self.cfg.state_dir / name)
        finally:
            if os.path.exists(path):
                os.unlink(path)

    def load(self, name, fields):
        path = self.cfg.state_dir / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_PATCH, "invalid_artifact")
        def unique(pairs):
            result = {}
            for key, value in pairs:
                require(key not in result, "duplicate_json_key")
                result[key] = value
            return result
        try:
            value = json.loads(path.read_bytes(), object_pairs_hook=unique)
        except (ValueError, OSError):
            raise Failure("invalid_artifact") from None
        require(type(value) is dict and set(value) == fields | set(self.cfg.binding()), "invalid_artifact_schema")
        require(encoded({key: value[key] for key in self.cfg.binding()}) == encoded(self.cfg.binding()), "artifact_context_mismatch")
        return value

    def emit(self, **values):
        for key, value in values.items():
            require(re.fullmatch(r"[a-z_][a-z0-9_]*", key) and isinstance(value, str)
                    and not any(unicodedata.category(ch).startswith("C") for ch in value), "unsafe_output")
        if self.cfg.output:
            with open(self.cfg.output, "a", encoding="utf-8") as stream:
                for key, value in values.items():
                    stream.write(key + "=" + value + "\n")

    def summary(self, status, plan=None):
        require(re.fullmatch(r"[a-z_-]+", status), "unsafe_summary")
        details = ""
        if plan is not None:
            source_sha, target_sha = sha(plan["source_sha"]), sha(plan["target_base_sha"])
            require(plan["target_ref"] == TARGET, "wrong_target")
            require(isinstance(plan["files"], list) and 0 < len(plan["files"]) <= MAX_FILES, "invalid_plan_files")
            files = [validate_path(path) for path in plan["files"]]
            # Literal HTML blocks keep valid Markdown metacharacters in filenames
            # inert; escape ampersands as well to prevent entity-based injection.
            details = ("\nSource: https://github.com/" + REPOSITORY + "/pull/" + str(self.cfg.source_pr)
                       + "\n\nSource SHA: " + source_sha + "\n\nTarget: " + TARGET
                       + "\n\nTarget base SHA: " + target_sha + "\n\nBranch: " + self.branch
                       + "\n\nFiles (" + str(len(files)) + "):\n<pre>\n"
                       + html.escape("\n".join(files)) + "\n</pre>\n")
        if self.cfg.summary:
            with open(self.cfg.summary, "a", encoding="utf-8") as stream:
                stream.write("\n### Backport #" + str(self.cfg.source_pr) + " to 29.x\n\n"
                             + "Dry run: " + str(self.cfg.dry_run).lower() + ". "
                             + ("No remote changes. " if self.cfg.dry_run else "")
                             + "Status: " + status + ".\n" + details)

    def pages(self, suffix):
        values = []
        separator = "&" if "?" in suffix else "?"
        for page in range(1, 1001):
            chunk = self.api.request("GET", self.root + suffix + separator + "per_page=100&page=" + str(page))
            require(isinstance(chunk, list) and len(chunk) <= 100, "invalid_api_page")
            values.extend(chunk)
            if len(chunk) < 100:
                return values
        raise Failure("pagination_limit")

    def repo_ok(self, value):
        require(isinstance(value, dict) and type(value.get("id")) is int
                and value["id"] == REPOSITORY_ID and value.get("full_name") == REPOSITORY, "repository_mismatch")

    def require_fresh_creation(self):
        require(not self.cfg.dry_run, "dry_run_write_blocked")
        workflow = ".github/workflows/backport-demo.yml"

        def check_run(run):
            require(isinstance(run, dict) and all(type(run.get(key)) is int and run[key] > 0
                    for key in ("id", "workflow_id", "run_attempt")), "invalid_run_history")
            self.repo_ok(run.get("repository"))
            self.repo_ok(run.get("head_repository"))
            require(run.get("path") == workflow and run.get("event") == "workflow_dispatch"
                    and run.get("head_branch") == "main", "unknown_run_history")
            title = run.get("display_title")
            require(isinstance(title, str), "unknown_run_history")
            match = re.fullmatch(r"Backport PR ([1-9][0-9]{0,9}) to 29\.x \(dry run = (true|false)\)", title)
            require(match is not None, "unknown_run_history")
            return positive(match[1], 2 ** 31), match[2] == "true"

        current = self.api.request("GET", self.root + "/actions/runs/" + self.cfg.run_id)
        require(check_run(current) == (self.cfg.source_pr, self.cfg.dry_run)
                and current["id"] == int(self.cfg.run_id)
                and current["run_attempt"] == int(self.cfg.run_attempt), "current_run_mismatch")
        # Inputs cannot change across attempts; no attempt-history inference or
        # successful/skipped conclusion is allowed to erase a possible write.
        require(current["run_attempt"] == 1, "previous_run_may_have_written")
        seen, total = set(), None
        for page in range(1, 1001):
            value = self.api.request("GET", self.root + "/actions/workflows/backport-demo.yml/runs"
                                     + "?per_page=100&page=" + str(page))
            require(isinstance(value, dict) and type(value.get("total_count")) is int
                    and value["total_count"] >= 0 and isinstance(value.get("workflow_runs"), list),
                    "invalid_run_history_page")
            if total is None:
                total = value["total_count"]
                require(total <= 100000, "pagination_limit")
            require(value["total_count"] == total, "run_history_changed")
            runs = value["workflow_runs"]
            require(len(runs) == min(100, total - len(seen)), "incomplete_run_history")
            for run in runs:
                source_pr, dry_run = check_run(run)
                require(run["workflow_id"] == current["workflow_id"], "wrong_history_workflow")
                require(run["id"] not in seen, "duplicate_run_history")
                seen.add(run["id"])
                if run["id"] == current["id"]:
                    require(run["run_attempt"] == current["run_attempt"]
                            and run["display_title"] == current["display_title"], "current_run_mismatch")
                else:
                    # Titles only add a denial gate; they never authorize actors,
                    # source content, object reuse, or bypass the existing proofs.
                    require(source_pr != self.cfg.source_pr or dry_run, "previous_run_may_have_written")
            if len(seen) == total:
                require(current["id"] in seen, "current_run_missing_from_history")
                return
        raise Failure("pagination_limit")

    def context(self, plan=None):
        self.repo_ok(self.api.request("GET", self.root))
        user = self.api.request("GET", "/users/" + urllib.parse.quote(self.cfg.triggering_actor, safe=""))
        require(type(user.get("id")) is int and user["id"] in self.cfg.allowed_actor_ids
                and self.cfg.actor_id in self.cfg.allowed_actor_ids, "triggering_actor_not_allowed")
        require(str(user.get("login", "")).casefold() == self.cfg.triggering_actor.casefold(), "triggering_actor_mismatch")
        source = self.api.request("GET", self.root + "/pulls/" + str(self.cfg.source_pr))
        require(source.get("number") == self.cfg.source_pr and source.get("merged") is True, "source_not_merged")
        self.repo_ok(source.get("base", {}).get("repo"))
        require(source["base"].get("ref") == "main", "source_wrong_base")
        source_sha = sha(source.get("merge_commit_sha"))
        head = sha(source.get("head", {}).get("sha"))
        target = sha(self.api.request("GET", self.root + "/branches/releases%2F29.x")["commit"]["sha"])
        if plan:
            require(source_sha == plan["source_sha"] and head == plan["source_head_sha"], "source_changed")
        return source, target

    def read_plan(self):
        plan = self.load("plan.json", PLAN_FIELDS)
        for key in ("source_sha", "source_head_sha", "target_base_sha"):
            sha(plan[key])
        require(plan["target_ref"] == TARGET, "wrong_target")
        require(isinstance(plan["files"], list) and 0 < len(plan["files"]) <= MAX_FILES, "invalid_plan_files")
        for path in plan["files"]:
            validate_path(path)
        require(len(set(plan["files"])) == len(plan["files"]), "duplicate_plan_files")
        require(isinstance(plan["commits"], list) and 0 < len(plan["commits"]) <= 250, "invalid_plan_commits")
        for value in plan["commits"]:
            sha(value)
        require(plan["commits"][-1] == plan["source_head_sha"], "incomplete_commit_list")
        return plan

    def prove_plan(self, repo, plan, source):
        commits = [sha(x.get("sha")) for x in self.pages("/pulls/" + str(self.cfg.source_pr) + "/commits")]
        require(commits == plan["commits"], "source_commits_changed")
        repo.fetch()
        files, _ = repo.prove(plan["source_sha"], plan["source_head_sha"], plan["target_base_sha"],
                              commits, source.get("changed_files"))
        require(files == plan["files"], "plan_files_mismatch")

    def marker(self, plan):
        return "<!-- bc-backport:v1:" + str(REPOSITORY_ID) + ":" + str(self.cfg.source_pr) + ":" + plan["source_sha"] + ":29 -->"

    def issue_body(self, plan):
        return "Source: https://github.com/" + REPOSITORY + "/pull/" + str(self.cfg.source_pr) + "\nSource SHA: " + plan["source_sha"] + "\n\n" + self.marker(plan)

    def pr_body(self, plan, issue, tree):
        return ("Backport of #" + str(self.cfg.source_pr) + "\nFixes #" + str(issue) + "\n\n"
                + self.marker(plan) + "\nSource SHA: " + plan["source_sha"]
                + "\nTarget base: " + plan["target_base_sha"] + "\nApplied tree: " + tree)

    def bot(self, obj):
        require(obj.get("user", {}).get("id") == BOT_ID, "object_not_actions_bot_owned")

    def url(self, obj, kind):
        number = obj.get("number")
        require(type(number) is int and 0 < number < 2 ** 31, "invalid_object_number")
        require(type(obj.get("id")) is int and obj["id"] > 0, "invalid_object_id")
        expected = "https://github.com/" + REPOSITORY + "/" + kind + "/" + str(number)
        require(obj.get("html_url") == expected, "invalid_object_url")
        return expected

    def check_issue(self, obj, plan):
        self.bot(obj)
        self.url(obj, "issues")
        require("pull_request" not in obj and obj.get("body") == self.issue_body(plan), "issue_marker_mismatch")
        require(obj.get("state") in ("open", "closed"), "invalid_issue_state")

    def pulls(self):
        result = []
        for obj in self.pages("/pulls?state=all"):
            if obj.get("head", {}).get("ref") == self.branch:
                self.url(obj, "pull")
                self.bot(obj)
                self.repo_ok(obj.get("head", {}).get("repo"))
                self.repo_ok(obj.get("base", {}).get("repo"))
                require(obj.get("base", {}).get("ref") == TARGET, "branch_pr_base_mismatch")
                result.append(obj)
        require(len(result) <= 1, "duplicate_backport_prs")
        return result

    def check_pr(self, obj, plan, issue, head, tree):
        self.bot(obj)
        self.url(obj, "pull")
        for part in ("head", "base"):
            self.repo_ok(obj.get(part, {}).get("repo"))
        require(obj["head"].get("ref") == self.branch and obj["head"].get("sha") == head
                and obj["base"].get("ref") == TARGET, "pr_branch_mismatch")
        require(obj.get("body") == self.pr_body(plan, issue, tree), "pr_provenance_mismatch")
        require(obj.get("state") == "open" or (obj.get("state") == "closed" and obj.get("merged") is True), "closed_unmerged_pr")

    def existing_pr_proof(self, plan, issue, source):
        candidates = self.pulls()
        require(len(candidates) == 1, "issue_without_verified_pr")
        obj = self.api.request("GET", self.root + "/pulls/" + str(candidates[0]["number"]))
        self.url(obj, "pull")
        if issue["state"] == "closed":
            require(obj.get("merged") is True, "closed_issue_without_merged_pr")
        with self.repo_factory(self.cfg) as repo:
            self.prove_plan(repo, plan, source)
            result, _, _ = repo.apply(plan)
            require(result["status"] == "applied", "closed_issue_without_content_proof")
            head = sha(obj.get("head", {}).get("sha"))
            # Merged branches may be deleted. Fetch GitHub's immutable PR head ref.
            repo.run("fetch", "--no-tags", "--no-recurse-submodules", repo.origin,
                     "refs/pull/" + str(obj["number"]) + "/head")
            require(repo.text("rev-parse", "FETCH_HEAD") == head, "pr_head_changed")
            repo.verify_branch(head, plan, result["tree_sha"])
            self.check_pr(obj, plan, issue["number"], head, result["tree_sha"])

    def read_tracking(self, plan, source):
        value = self.load("tracking.json", TRACK_FIELDS)
        require(value["plan_hash"] == digest(encoded(plan)), "tracking_plan_mismatch")
        if self.cfg.dry_run:
            require(value["status"] == "dry-run" and all(value[k] is None for k in ("issue_number", "issue_id", "issue_url")), "invalid_dry_tracking")
            return value
        require(value["status"] == "tracked", "tracking_incomplete")
        require(type(value["issue_number"]) is int and 0 < value["issue_number"] < 2 ** 31, "invalid_issue_number")
        obj = self.api.request("GET", self.root + "/issues/" + str(value["issue_number"]))
        self.check_issue(obj, plan)
        require(obj["id"] == value["issue_id"] and obj["html_url"] == value["issue_url"], "tracking_issue_mismatch")
        if obj["state"] == "closed":
            self.existing_pr_proof(plan, obj, source)
        return value

    def validate(self):
        source, target = self.context()
        commits = [sha(x.get("sha")) for x in self.pages("/pulls/" + str(self.cfg.source_pr) + "/commits")]
        require(0 < len(commits) <= 250 and commits[-1] == source["head"]["sha"], "incomplete_commit_list")
        with self.repo_factory(self.cfg) as repo:
            repo.fetch()
            require(repo.text("rev-parse", "refs/remotes/demo/target") == target, "target_changed")
            files, _ = repo.prove(source["merge_commit_sha"], source["head"]["sha"], target,
                                  commits, source.get("changed_files"))
        plan = {**self.cfg.binding(), "source_sha": source["merge_commit_sha"],
                "source_head_sha": source["head"]["sha"], "target_ref": TARGET,
                "target_base_sha": target, "files": files, "commits": commits}
        if (self.cfg.state_dir / "plan.json").exists():
            require(self.read_plan() == plan, "existing_plan_changed")
        self.save("plan.json", plan)
        self.emit(plan_ready="true")
        self.summary("validated", plan)
        return plan

    def track(self):
        plan = self.read_plan()
        source, _ = self.context(plan)
        state = {**self.cfg.binding(), "plan_hash": digest(encoded(plan)), "status": "dry-run",
                 "issue_number": None, "issue_id": None, "issue_url": None}
        if self.cfg.dry_run:
            self.save("tracking.json", state)
            self.summary("dry-run", plan)
            return state
        candidates = [x for x in self.pages("/issues?state=all")
                      if "pull_request" not in x and self.marker(plan) in (x.get("body") or "")]
        require(len(candidates) <= 1, "duplicate_tracking_issues")
        pulls = self.pulls()
        if candidates:
            self.url(candidates[0], "issues")
            obj = self.api.request("GET", self.root + "/issues/" + str(candidates[0]["number"]))
        else:
            require(not pulls, "existing_pr_without_tracking_issue")
            if (self.cfg.state_dir / "tracking.json").exists():
                previous = self.load("tracking.json", TRACK_FIELDS)
                require(previous["status"] != "ambiguous", "issue_create_ambiguous")
                raise Failure("previous_issue_missing")
            self.require_fresh_creation()
            state["status"] = "ambiguous"
            self.save("tracking.json", state)
            obj = self.api.request("POST", self.root + "/issues", {
                "title": "[29.x] Backport #" + str(self.cfg.source_pr), "body": self.issue_body(plan)})
            self.url(obj, "issues")
            obj = self.api.request("GET", self.root + "/issues/" + str(obj["number"]))
        self.check_issue(obj, plan)
        if obj["state"] == "closed" or pulls:
            self.existing_pr_proof(plan, obj, source)
        state.update(status="tracked", issue_number=obj["number"], issue_id=obj["id"], issue_url=obj["html_url"])
        self.save("tracking.json", state)
        self.emit(issue_number=str(obj["number"]))
        self.summary("tracked", plan)
        return state

    def prepare(self):
        plan = self.read_plan()
        source, _ = self.context(plan)
        self.read_tracking(plan, source)
        with self.repo_factory(self.cfg) as repo:
            self.prove_plan(repo, plan, source)
            outcome, patch_bytes, files = repo.apply(plan)
            result = {**self.cfg.binding(), "plan_hash": digest(encoded(plan)), "published": False,
                      "commit_sha": None, "tree_sha": None, "patch_sha256": digest(patch_bytes), **outcome}
            self.save("patch.bin", patch_bytes)
            if files:
                repo.keep = True
                self.save("conflict.json", {"repo": REPOSITORY, "source_pr": self.cfg.source_pr,
                                           "source_sha": plan["source_sha"], "target_base_sha": plan["target_base_sha"],
                                           "worktree": str(repo.path), "files": [
                                               {"relative_path": p, "absolute_path": str(repo.path / p)} for p in files]})
            else:
                (self.cfg.state_dir / "conflict.json").unlink(missing_ok=True)
            self.save("result.json", result)
        self.emit(status=result["status"], result_artifact="result.json", result_sha256=digest(encoded(result)))
        self.summary(result["status"], plan)
        return result

    def read_result(self, plan):
        result = self.load("result.json", RESULT_FIELDS)
        require(result["plan_hash"] == digest(encoded(plan)) and result["published"] is False, "result_plan_mismatch")
        allowed = {"applied": {"clean_cherry_pick"}, "already_applied": {"source_ancestor", "reverse_patch_proven"},
                   "needs-attention": {"cherry_pick_conflict"}}
        require(result["status"] in allowed and result["reason"] in allowed[result["status"]], "unsupported_result")
        if result["status"] == "applied":
            sha(result["commit_sha"])
            sha(result["tree_sha"])
        else:
            require(result["commit_sha"] is None and result["tree_sha"] is None, "invalid_noop_result")
        patch_path = self.cfg.state_dir / "patch.bin"
        require(patch_path.is_file() and not patch_path.is_symlink() and patch_path.stat().st_size <= MAX_PATCH, "invalid_patch")
        require(isinstance(result["patch_sha256"], str) and HASH.fullmatch(result["patch_sha256"])
                and digest(patch_path.read_bytes()) == result["patch_sha256"], "patch_digest_mismatch")
        return result

    def journal(self, plan):
        path = self.cfg.state_dir / "publication.json"
        if path.exists():
            value = self.load("publication.json", {"plan_hash", "attempted"})
            require(value["plan_hash"] == digest(encoded(plan)) and isinstance(value["attempted"], list)
                    and all(isinstance(x, str) for x in value["attempted"]), "invalid_publication_journal")
            return value
        return {**self.cfg.binding(), "plan_hash": digest(encoded(plan)), "attempted": []}

    def write_once(self, plan, key, method, path, data):
        require(not self.cfg.dry_run, "dry_run_write_blocked")
        journal = self.journal(plan)
        require(key not in journal["attempted"], "publication_write_ambiguous")
        if method == "POST":
            self.require_fresh_creation()
        journal["attempted"].append(key)
        self.save("publication.json", journal)
        return self.api.request(method, path, data)

    def feedback(self, plan, tracking, status, pr_url="", reason=""):
        require(status in ("needs-attention", "already_applied", "pr-created", "pr-reused"), "invalid_feedback_status")
        require(reason in ("", "target_advanced", "source_ancestor", "reverse_patch_proven", "cherry_pick_conflict"), "invalid_feedback_reason")
        marker = self.marker(plan) + "\n<!-- bc-backport-status -->"
        body = marker + "\nBackport #" + str(self.cfg.source_pr) + " to 29.x: " + status + "."
        if reason:
            body += "\nReason: " + reason + "."
        if pr_url:
            body += "\n" + pr_url
        for number in (tracking["issue_number"], self.cfg.source_pr):
            comments = self.pages("/issues/" + str(number) + "/comments")
            matches = [x for x in comments if x.get("user", {}).get("id") == BOT_ID
                       and marker in (x.get("body") or "")]
            require(len(matches) <= 1, "duplicate_status_comments")
            if matches:
                comment = matches[0]
                require(type(comment.get("id")) is int and comment["id"] > 0, "invalid_comment_id")
                if comment.get("body") == body:
                    continue
                path = self.root + "/issues/comments/" + str(comment["id"])
                method = "PATCH"
            else:
                path = self.root + "/issues/" + str(number) + "/comments"
                method = "POST"
            # A changed status must not bypass an ambiguous earlier POST.
            key = "comment:" + str(number) + (":create" if method == "POST" else ":" + digest(body.encode()))
            value = self.write_once(plan, key, method, path, {"body": body})
            self.bot(value)
            require(value.get("body") == body, "comment_readback_mismatch")

    def finish(self, plan, tracking, status, pr_url="", reason=""):
        if not self.cfg.dry_run:
            self.feedback(plan, tracking, status, pr_url, reason)
        values = {"status": status}
        if pr_url:
            values["pr_url"] = pr_url
        self.emit(**values)
        self.summary(status, plan)
        return {**values, "reason": reason}

    def publish(self):
        plan = self.read_plan()
        source, target = self.context(plan)
        tracking = self.read_tracking(plan, source)
        result = self.read_result(plan)
        if self.cfg.dry_run:
            return self.finish(plan, tracking, "dry-run")
        if target != plan["target_base_sha"]:
            return self.finish(plan, tracking, "needs-attention", reason="target_advanced")
        with self.repo_factory(self.cfg) as repo:
            self.prove_plan(repo, plan, source)
            computed, patch_bytes, _ = repo.apply(plan)
            require(computed["status"] == result["status"] and computed["reason"] == result["reason"]
                    and computed.get("tree_sha") == result["tree_sha"]
                    and digest(patch_bytes) == result["patch_sha256"], "recomputed_result_mismatch")
            if result["status"] != "applied":
                return self.finish(plan, tracking, result["status"], reason=result["reason"])
            candidates = self.pulls()
            head = repo.branch_head(self.branch)
            if head:
                repo.verify_branch(head, plan, result["tree_sha"])
            if candidates:
                require(head is not None, "existing_pr_branch_missing")
                obj = self.api.request("GET", self.root + "/pulls/" + str(candidates[0]["number"]))
                self.check_pr(obj, plan, tracking["issue_number"], head, result["tree_sha"])
                return self.finish(plan, tracking, "pr-reused", obj["html_url"])
            # Recheck actor/source/target immediately before any push or PR creation.
            _, current_target = self.context(plan)
            if current_target != plan["target_base_sha"]:
                return self.finish(plan, tracking, "needs-attention", reason="target_advanced")
            journal = self.journal(plan)
            require("pr" not in journal["attempted"], "pr_create_ambiguous")
            if not head:
                require("push" not in journal["attempted"], "push_ambiguous")
                self.require_fresh_creation()
                journal["attempted"].append("push")
                self.save("publication.json", journal)
                repo.push(self.branch)
                head = repo.branch_head(self.branch)
                require(head == computed["commit_sha"], "push_readback_mismatch")
                repo.verify_branch(head, plan, result["tree_sha"])
            _, current_target = self.context(plan)
            if current_target != plan["target_base_sha"]:
                return self.finish(plan, tracking, "needs-attention", reason="target_advanced")
            obj = self.write_once(plan, "pr", "POST", self.root + "/pulls", {
                "title": "Backport #" + str(self.cfg.source_pr) + " to 29.x", "head": self.branch,
                "base": TARGET, "body": self.pr_body(plan, tracking["issue_number"], result["tree_sha"]), "draft": False})
            self.url(obj, "pull")
            obj = self.api.request("GET", self.root + "/pulls/" + str(obj["number"]))
            self.check_pr(obj, plan, tracking["issue_number"], head, result["tree_sha"])
            return self.finish(plan, tracking, "pr-created", obj["html_url"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("validate", "track", "prepare", "publish"))
    args = parser.parse_args(argv)
    controller = None
    try:
        controller = Controller(Config.from_env(os.environ))
        getattr(controller, args.stage)()
        return 0
    except Failure as exc:
        reason = str(exc)
        # Never log response bodies, Git stderr, source titles, paths, or tokens.
        print("Backport stopped: " + (reason if re.fullmatch(r"[a-z_]+", reason) else "invalid_data"), file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, UnicodeError):
        print("Backport stopped: invalid_data_or_local_io", file=sys.stderr)
    if controller:
        try:
            controller.emit(status="needs-attention")
            controller.summary("needs-attention")
        except (OSError, Failure):
            pass
    return 1


if __name__ == "__main__":
    sys.exit(main())