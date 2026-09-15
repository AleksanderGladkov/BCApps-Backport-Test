"""Offline, temporary reference tooling for the pinned Python controller."""

import argparse
import ast
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import types
import unicodedata
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent
BASELINE_ROOT = None
c = baseline = None
COMMIT = "514500f55f064aa9ab86607e6d0803f2abd6376c"
SOURCE_HASHES = {
    "controller.py": "6818a52f0f8f993f34509fd4902fcfbd08568bcb03f96f9fc9422802501c9a4c",
    "test_controller.py": "5ea6d6c6072688e1427d0b1dc9ba150b6104feb681d4c9dcf0d014eb634a1992",
}
GROUP_ENDS = [325, 375, 418, 495, 544, 591, 692, 847, 885, 958, 1027, 1090]


def verify_runtime(version=None, unicode_version=None):
    version = sys.version_info[:2] if version is None else version
    unicode_version = unicodedata.unidata_version if unicode_version is None else unicode_version
    if tuple(version) != (3, 13) or unicode_version != "15.1.0":
        raise ValueError("unsupported_reference_runtime")


def verified_sources(directory=None):
    verify_runtime()
    directory = BASELINE_ROOT if directory is None else directory
    if directory is None:
        raise ValueError("explicit_baseline_directory_required")
    result = {}
    for name, expected in SOURCE_HASHES.items():
        # Git may check the same immutable source out with CRLF on Windows.
        content = (directory / name).read_bytes().replace(b"\r\n", b"\n")
        if hashlib.sha256(content).hexdigest() != expected:
            raise ValueError("baseline_source_drift")
        result[name] = content
    if len(result["controller.py"].splitlines()) != 866:
        raise ValueError("baseline_line_count_drift")
    return result


def inventory_rows():
    tree = ast.parse(verified_sources()["test_controller.py"])
    classes = [node for node in tree.body if isinstance(node, ast.ClassDef)
               and node.name == "ExecutorTests"]
    if len(classes) != 1:
        raise ValueError("baseline_inventory_drift")
    rows = []
    for node in classes[0].body:
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_"):
            group = next(i for i, end in enumerate(GROUP_ENDS, 1) if node.lineno <= end)
            rows.append({"id": node.name, "pester_name": node.name, "group": f"TEST-{group:03}"})
    if len(rows) != 67 or len({row["id"] for row in rows}) != 67:
        raise ValueError("baseline_inventory_drift")
    return sorted(rows, key=lambda row: row["id"])


def verify_source():
    return [row["id"] for row in inventory_rows()]


@contextmanager
def load_baseline(directory):
    sources = verified_sources(directory)
    modules = {name: types.ModuleType(name) for name in ("controller", "test_controller")}
    # Execute only the bytes already pinned above, never a same-named ambient module.
    with patch.dict(sys.modules, modules):
        for name, module in modules.items():
            module.__file__ = str(directory / (name + ".py"))
            exec(compile(sources[name + ".py"], module.__file__, "exec"), module.__dict__)
        yield modules["controller"], modules["test_controller"]


class ReferenceTests(unittest.TestCase):
    def test_import_does_not_require_an_adjacent_oracle_or_create_files(self):
        with patch.object(Path, "read_bytes", side_effect=AssertionError("unexpected source read")), patch(
                "subprocess.Popen", side_effect=AssertionError("unexpected child process")):
            imported = runpy.run_path(str(ROOT / "Export-PythonBaseline.py"))
        self.assertIsNone(imported["c"])
        self.assertIsNone(imported["baseline"])

    def test_explicit_oracle_ignores_ambient_modules_and_restores_them(self):
        import types
        ambient = types.ModuleType("controller")
        with patch.dict(sys.modules, {"controller": ambient}):
            with load_baseline(BASELINE_ROOT) as (controller, tests):
                self.assertIsNot(controller, ambient)
                self.assertIs(tests.c, controller)
                self.assertEqual(controller.encoded({"a": True}), b'{"a":true}')
            self.assertIs(sys.modules["controller"], ambient)

    def test_resource_output_cannot_overwrite_oracle_or_harness_source(self):
        for destination in (BASELINE_ROOT, BASELINE_ROOT / "nested", ROOT.parent):
            with self.subTest(destination=destination):
                with self.assertRaisesRegex(ValueError, "^unsafe_resource_destination$"):
                    validate_destination(destination)

    def test_runtime_rejects_other_python_and_unicode_versions(self):
        for version, unicode_version in [((3, 12), "15.1.0"), ((3, 14), "15.1.0"),
                                         ((3, 13), "16.0.0")]:
            with self.subTest(version=version, unicode=unicode_version):
                with self.assertRaisesRegex(ValueError, "unsupported_reference_runtime"):
                    verify_runtime(version, unicode_version)
        verify_runtime((3, 13), "15.1.0")

    def test_exact_pinned_inventory_and_source_are_verified(self):
        inventory = verify_source()
        self.assertEqual(len(inventory), 67)
        self.assertEqual(len(set(inventory)), 67)
        self.assertEqual(inventory, sorted(inventory))
        self.assertEqual(inventory, unittest.TestLoader().getTestCaseNames(baseline.ExecutorTests))
        rows = inventory_rows()
        self.assertEqual([sum(row["group"] == f"TEST-{i:03}" for row in rows)
                          for i in range(1, 13)], [7, 5, 4, 5, 4, 5, 5, 12, 2, 5, 7, 6])

    def test_source_drift_is_rejected(self):
        with patch.object(Path, "read_bytes", return_value=b"changed\n"):
            with self.assertRaisesRegex(ValueError, "^baseline_source_drift$"):
                verify_source()

    def test_import_never_executes_cli(self):
        with patch.object(c, "main", side_effect=AssertionError("CLI must not run")), patch.object(
                c, "Controller", side_effect=AssertionError("stage construction must not run")):
            imported = runpy.run_path(str(ROOT / "Export-PythonBaseline.py"))
        self.assertIn("generate_resources", imported)

    def test_verify_rejects_changed_resource_bytes(self):
        with patch.object(Path, "read_bytes", return_value=b"changed\n"):
            with patch("builtins.print"):
                # Isolate the resource read from source verification in this negative case.
                with patch.dict(globals(), build_reference=lambda: {"schema": 1}):
                    with self.assertRaisesRegex(ValueError, "^reference_resource_drift$"):
                        generate_resources(Path("synthetic-output"), verify=True)

    def test_generation_is_deterministic_and_matches_canonical_bytes(self):
        first = build_reference()
        self.assertEqual(first, build_reference())
        for vector in first["vectors"]:
            raw = c.encoded(vector["value"])
            self.assertEqual(vector["utf8_hex"], raw.hex())
            self.assertEqual(vector["sha256"], c.digest(raw))

    def test_reference_shapes_and_public_dispositions_are_complete(self):
        reference = build_reference()
        self.assertEqual({row["id"] for row in reference["correspondence"]},
                         {f"MAP-{i:03}" for i in range(1, 9)})
        self.assertEqual(len(reference["helper_dispositions"]), 5)
        names = {row["id"] for row in reference["vectors"]}
        self.assertTrue({"plan", "tracking-dry", "tracking-ambiguous", "tracking-tracked",
                         "result-applied", "result-noop", "result-conflict", "publication",
                         "conflict", "issue-body", "pr-body", "feedback-body"} <= names)
        self.assertEqual(build_compatibility()["provenance"]["unicode_version"], "15.1.0")
        self.assertIn("Permission is hereby granted", build_compatibility()["license"]["notice"])
        self.assertIn("Copyright (c) Microsoft Corporation.", reference["baseline"]["license_notice"])
        data = resource_bytes(reference)
        for private in (str(ROOT), str(BASELINE_ROOT), "microsoft.ghe.com", "offline-fixture"):
            self.assertNotIn(private.encode("utf-8"), data)

    def test_surrogate_vectors_do_not_require_lossy_json_decoding(self):
        reference = build_reference()
        for vector in reference["surrogate_vectors"]:
            value = "".join(chr(unit) for unit in vector["utf16_code_units"])
            self.assertEqual(vector["utf8_hex"], c.encoded(value).hex())
            self.assertEqual(vector["sha256"], c.digest(c.encoded(value)))
        decoded = json.loads(resource_bytes(reference))
        for vector in decoded["vectors"]:
            json.dumps(vector["value"], ensure_ascii=False).encode("utf-8", errors="strict")

    def test_unicode_profile_covers_all_code_points(self):
        import unicodedata
        profile = build_compatibility()
        folds = {item[0]: item[1] for item in profile["case_folds"]}
        spaces = set(profile["whitespace"])
        ranges = iter(profile["category_c_ranges"])
        current = next(ranges, None)
        for point in range(0x110000):
            char = chr(point)
            self.assertEqual(folds.get(point, char), char.casefold(), hex(point))
            self.assertEqual(point in spaces, char.isspace(), hex(point))
            while current and point > current[1]:
                current = next(ranges, None)
            forbidden = current is not None and current[0] <= point <= current[1]
            self.assertEqual(forbidden, unicodedata.category(char).startswith("C"), hex(point))


class SharedSafetyCases:
    """TEST-021 uses only synthetic content and the unchanged public baseline."""

    def two_file_source(self, both_present=False):
        git = baseline.git
        git(self.origin, "switch", "-c", "safety-base", self.base)
        (self.origin / "src/two.al").write_bytes(b"alpha\nbeta\n")
        git(self.origin, "add", ".")
        git(self.origin, "commit", "-m", "two-file base")
        base = git(self.origin, "rev-parse", "HEAD")
        git(self.origin, "switch", "-c", "safety-feature")
        (self.origin / "src/one.al").write_bytes(b"ONE\ntwo\nthree\n")
        (self.origin / "src/two.al").write_bytes(b"ALPHA\nbeta\n")
        git(self.origin, "commit", "-am", "complete two-file fix")
        self.head = git(self.origin, "rev-parse", "HEAD")
        git(self.origin, "update-ref", "refs/pull/7/head", self.head)
        git(self.origin, "update-ref", "refs/heads/main", base)
        git(self.origin, "switch", "main")
        git(self.origin, "merge", "--squash", "safety-feature")
        git(self.origin, "commit", "-m", "complete squash")
        self.source = git(self.origin, "rev-parse", "HEAD")
        git(self.origin, "update-ref", "refs/heads/releases/29.x", base)
        git(self.origin, "switch", "releases/29.x")
        (self.origin / "src/one.al").write_bytes(b"ONE\ntwo\nthree\n")
        if both_present:
            (self.origin / "src/two.al").write_bytes(b"ALPHA\nbeta\n")
        (self.origin / "release-only.txt").write_bytes(b"release-only\r\nunchanged\n")
        git(self.origin, "add", ".")
        git(self.origin, "commit", "-m", "preexisting release effects")
        self.target = git(self.origin, "rev-parse", "HEAD")
        git(self.origin, "switch", "main")
        self.api = baseline.FakeGitHub(self.origin, self.head, self.source, self.target, [self.head])
        self.api.source["changed_files"] = 2
        self.configure()

    def blob(self, ref, name):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("GIT_") and key not in ("GH_TOKEN", "GITHUB_TOKEN")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_TERMINAL_PROMPT="0")
        return subprocess.check_output(
            ["git", "-c", "protocol.allow=never", "-c", "core.hooksPath=",
             "-C", str(self.origin), "cat-file", "blob", ref + ":" + name],
            env=env, stderr=subprocess.PIPE)

    def test_021_partial_fix_preserves_exact_final_content(self):
        self.two_file_source()
        result = self.stages()
        self.assertEqual(result["status"], "applied")
        self.assertEqual(self.executor.publish()["status"], "pr-created")
        ref = "refs/heads/backport/29.x/pr-7"
        self.assertEqual(self.blob(ref, "src/one.al"), b"ONE\ntwo\nthree\n")
        self.assertEqual(self.blob(ref, "src/two.al"), b"ALPHA\nbeta\n")
        self.assertEqual(self.blob(ref, "release-only.txt"), b"release-only\r\nunchanged\n")
        self.assertEqual(baseline.git(self.origin, "diff", "--name-only", self.target, ref),
                         "src/two.al")

    def test_021_both_fixes_present_is_verified_noop(self):
        self.two_file_source(both_present=True)
        self.assertEqual(self.stages()["status"], "already_applied")
        self.assertEqual(self.executor.publish()["status"], "already_applied")
        self.assertFalse(self.api.pulls)
        self.assertEqual(baseline.git(self.origin, "branch", "--list", "backport/*"), "")
        self.assertEqual(self.blob(self.target, "src/one.al"), b"ONE\ntwo\nthree\n")
        self.assertEqual(self.blob(self.target, "src/two.al"), b"ALPHA\nbeta\n")
        self.assertEqual(self.blob(self.target, "release-only.txt"), b"release-only\r\nunchanged\n")

    def assert_forged_effect_rejected(self, name, content):
        self.two_file_source()
        result = self.stages()
        plan = self.executor.read_plan()
        with self.executor.repo_factory(self.config) as repo:
            repo.fetch()
            computed, _, _ = repo.apply(plan)
            self.assertEqual(computed["status"], "applied")
            (repo.path / name).write_bytes(content)
            repo.run("add", "--", name)
            repo.run("commit", "-m", "synthetic forged effect")
            forged = repo.patch(self.target, "HEAD")
            result.update(commit_sha=repo.text("rev-parse", "HEAD"),
                          tree_sha=repo.text("rev-parse", "HEAD^{tree}"),
                          patch_sha256=hashlib.sha256(forged).hexdigest())
        self.executor.save("patch.bin", forged)
        self.executor.save("result.json", result)
        with self.assertRaisesRegex(c.Failure, "^recomputed_result_mismatch$"):
            self.executor.publish()
        self.assertFalse(self.api.pulls)
        self.assertEqual(baseline.git(self.origin, "branch", "--list", "backport/*"), "")

    def test_021_missing_effect_with_rehashed_artifacts_is_rejected(self):
        self.assert_forged_effect_rejected("src/two.al", b"alpha\nbeta\n")

    def test_021_unrelated_effect_with_rehashed_artifacts_is_rejected(self):
        self.assert_forged_effect_rejected("release-only.txt", b"unapproved\n")


BASELINE_NOTICE = """MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE"""


UNICODE_NOTICE = """UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright \u00a9 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder."""


def build_compatibility():
    verify_runtime()
    folds, ranges, spaces = [], [], []
    start = None
    for point in range(0x110000):
        char = chr(point)
        folded = char.casefold()
        if folded != char:
            folds.append([point, folded])
        if char.isspace():
            spaces.append(point)
        if unicodedata.category(char).startswith("C"):
            if start is None:
                start = point
        elif start is not None:
            ranges.append([start, point - 1])
            start = None
    if start is not None:
        ranges.append([start, 0x10ffff])
    return {
        "schema": 1,
        "provenance": {
            "generator": "Export-PythonBaseline.py",
            "python_version": "3.13", "unicode_version": "15.1.0",
            "source": "Python str.casefold, str.isspace and unicodedata.category",
            "domain": "All code points U+0000..U+10FFFF, including surrogates",
            "normalization": "none",
            "python_license": "PSF-2.0; https://docs.python.org/3.13/license.html",
            "python_copyright": "Copyright (c) 2001-2026 Python Software Foundation",
            "ucd": "https://www.unicode.org/Public/15.1.0/ucd/ReadMe.txt",
            "derivation": "Computed data only; no Python or internal-package source copied.",
        },
        "license": {"id": "Unicode-3.0", "url": "https://www.unicode.org/license.txt",
                    "notice": UNICODE_NOTICE},
        "case_folds": folds, "category_c_ranges": ranges, "whitespace": spaces,
    }


def canonical_vectors():
    cfg = c.Config(7, False, c.OWNER_ID, "fixture", (c.OWNER_ID,), "123", "1",
                   Path("synthetic-state"), Path("synthetic-work"), "offline-fixture")
    api = baseline.FakeGitHub(None, "2" * 40, "1" * 40, "3" * 40, ["2" * 40])
    executor = c.Controller(cfg, api=api)
    binding = cfg.binding()
    plan = {**binding, "source_sha": "1" * 40, "source_head_sha": "2" * 40,
            "target_ref": c.TARGET, "target_base_sha": "3" * 40,
            "files": ["src/one.al", "src/\u03a3.al"], "commits": ["2" * 40]}
    plan_hash = c.digest(c.encoded(plan))
    tracking = {**binding, "plan_hash": plan_hash, "status": "tracked",
                "issue_number": 101, "issue_id": 1001,
                "issue_url": "https://github.com/" + c.REPOSITORY + "/issues/101"}
    result = {**binding, "plan_hash": plan_hash, "status": "applied",
              "reason": "clean_cherry_pick", "published": False, "commit_sha": "4" * 40,
              "tree_sha": "5" * 40, "patch_sha256": c.digest(b"synthetic patch\n")}
    shapes = {
        "plan": plan, "tracking-tracked": tracking, "result-applied": result,
        "publication": {**binding, "plan_hash": plan_hash, "attempted": ["push", "pr"]},
        "conflict": {"repo": c.REPOSITORY, "source_pr": 7, "source_sha": "1" * 40,
                     "target_base_sha": "3" * 40, "worktree": "/synthetic/work/repo",
                     "files": [{"relative_path": "src/one.al",
                                "absolute_path": "/synthetic/work/repo/src/one.al"}]},
        "issue-body": executor.issue_body(plan),
        "pr-body": executor.pr_body(plan, 101, "5" * 40),
        "marker": executor.marker(plan),
        "empty-and-singleton": {"empty": [], "one": [None], "many": [False, 0, "", {}]},
        "types-and-order": {"a": 0, "A": True, "\U00010000": 1, "\ue000": 2,
                            "null": None, "integer": 99999999999999999999,
                            "string": "99999999999999999999", "negative": -1},
        "escaping": {"text": "\"\\\b\f\n\r\t\u0000/<>&'\u00df\u03a3\U0001f600"},
    }
    for status in ("dry-run", "ambiguous"):
        shapes["tracking-" + ("dry" if status == "dry-run" else status)] = {
            **tracking, "status": status, "issue_number": None, "issue_id": None, "issue_url": None}
    for key, status, reason in (("noop", "already_applied", "reverse_patch_proven"),
                                ("conflict", "needs-attention", "cherry_pick_conflict")):
        shapes["result-" + key] = {**result, "status": status, "reason": reason,
                                  "commit_sha": None, "tree_sha": None, "patch_sha256": c.digest(b"")}
    with patch.object(executor, "pages", return_value=[]), patch.object(
            executor, "write_once", side_effect=lambda plan, key, method, path, data:
            {**data, "user": {"id": c.BOT_ID}}) as writes:
        executor.feedback(plan, tracking, "pr-created",
                          "https://github.com/" + c.REPOSITORY + "/pull/102")
        shapes["feedback-body"] = writes.call_args.args[-1]["body"]
    return [{"id": name, "value": value, "utf8_hex": c.encoded(value).hex(),
             "sha256": c.digest(c.encoded(value))} for name, value in sorted(shapes.items())]


def build_reference():
    rows = inventory_rows()
    maps = [
        ("MAP-001", "retained", "Exact source, target and actor revalidation; dispatch authorization is not interactive aggregate approval."),
        ("MAP-002", "adapted", "Independent temporary repositories protect callers; persistent worktree recovery is not supported."),
        ("MAP-003", "adapted", "Verified squash cherry-pick and independent reconstruction; legitimate smaller deltas require exact final content."),
        ("MAP-004", "retained", "Reconcile exact bot-owned objects; journals, fresh history and create-only branch leases prohibit blind recreation."),
        ("MAP-005", "deferred", "Keep the executor conflict handoff and stop publication; no resolver invocation or schema adapter."),
        ("MAP-006", "adapted", "Read back branches and PRs; preparation published=false is not a final receipt. A separate receipt is deferred."),
        ("MAP-007", "adapted", "Independent public-safe synthetic fixtures supplement, not replace, the 67 baseline cases."),
        ("MAP-008", "retained", "One source and one target; no reviewer policy, branch-only mode, bulk coordination or translation."),
    ]
    helpers = [
        ("byte-safe-blob", "adapted", "Raw byte streams and argument lists inform independent fork-local bounded transport."),
        ("canonical-atomic-json", "adapted", "Sorted keys and atomic writes retained; Python escaping, types and exact bytes remain authoritative."),
        ("result-before-pr", "adapted", "Recompute content before publication; legitimate subset deltas differ from exact changed-path manifests."),
        ("github-readback", "adapted", "Verify branch/base/head with fixed-scope HTTP and create-only publication; no work-item or CLI transport."),
        ("publication-receipt", "deferred", "Keep existing remote verification and journal evidence; introduce no new result schema."),
    ]
    return {
        "schema": 1,
        "baseline": {"commit": COMMIT, "controller_lines": 866, "test_count": 67,
                     "source_sha256_lf": SOURCE_HASHES,
                     "source": "https://github.com/" + c.REPOSITORY + "/tree/" + COMMIT,
                     "license": "MIT; see repository LICENSE",
                     "license_notice": BASELINE_NOTICE,
                     "inventory_sha256": c.digest(c.encoded([row["id"] for row in rows]))},
        "capture": {
            "date": "2026-09-14", "platform": "Windows",
            "python_version": "3.13.15", "unicode_version": "15.1.0",
            "inspected_main": "9d44122e00089c6c5d4fb83d760ca574263ee6d1",
            "automation_matches_baseline": True,
            "baseline_suite": {"passed": 67, "failed": 0, "skipped": 0, "seconds": 478.558},
            "TEST-021": {"passed": 4, "failed": 0, "skipped": 0},
            "protected_paths": {
                "count": 141, "unchanged": True,
                "receipt_sha256": "4fff56b541eed64b6ed763177f1d7c1c0ed5bb5f6dacbf9f77df9cf3515f7067",
                "scope": "Source, installed, legacy and previously recorded reference copies; private path manifest is not distributed.",
            },
            "scope": "Historical baseline receipt, not the result of the current exporter invocation or PowerShell acceptance.",
        },
        "baseline_tests": rows,
        "required_migration_ids": [f"TEST-{i:03}" for i in range(13, 25)],
        "vectors": canonical_vectors(),
        # JSON decoders may replace lone surrogates. Reconstruct these from code units.
        "surrogate_vectors": [
            {"id": name, "utf16_code_units": [unit], "utf8_hex": c.encoded(chr(unit)).hex(),
             "sha256": c.digest(c.encoded(chr(unit)))}
            for name, unit in (("unpaired-high", 0xd800), ("unpaired-low", 0xdfff))
        ],
        "correspondence": [{"id": key, "disposition": disposition, "decision": text}
                           for key, disposition, text in maps],
        "helper_dispositions": [{"id": key, "disposition": disposition, "decision": text}
                                for key, disposition, text in helpers],
        "shared_safety": {
            "TEST-021": {"baseline_cases": sorted(name for name in SharedSafetyCases.__dict__
                                                if name.startswith("test_021_")),
                         "observed": "Partial fix publishes only the missing effect; complete fix is a no-op; rehashed missing/extra effects are rejected."},
            "TEST-022": {"scope": "Dirty caller and unrelated working-directory isolation"},
            "TEST-023": {"scope": "Exact fork conflict handoff; no skill import or resolver"},
            "TEST-024": {"scope": "Fresh remote read-back and retained publication journals"},
        },
        "verification": {
            "python": "3.13", "unicode": "15.1.0",
            "unchanged_suite": "python -B Export-PythonBaseline.py --baseline-dir <pinned-oracle-directory> --baseline-tests",
            "reference_tests": "python -B Export-PythonBaseline.py --baseline-dir <pinned-oracle-directory> --self-test",
            "shared_safety": "python -B Export-PythonBaseline.py --baseline-dir <pinned-oracle-directory> --safety",
            "generate": "python -B Export-PythonBaseline.py --baseline-dir <pinned-oracle-directory> --generate",
            "verify": "python -B Export-PythonBaseline.py --baseline-dir <pinned-oracle-directory> --verify",
            "scope": "Reference data and baseline observations only, not PowerShell acceptance.",
        },
    }


def resource_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode("ascii")


def validate_destination(destination):
    destination = destination.resolve()
    oracle = BASELINE_ROOT.resolve()
    if (destination == oracle or destination.is_relative_to(oracle) or oracle.is_relative_to(destination)
            or (destination != ROOT and ROOT.is_relative_to(destination))):
        raise ValueError("unsafe_resource_destination")


def generate_resources(destination, verify=False):
    if not verify:
        validate_destination(destination)
    resources = {"compat.json": build_compatibility(), "parity.json": build_reference()}
    second = {"compat.json": build_compatibility(), "parity.json": build_reference()}
    for name, value in resources.items():
        content = resource_bytes(value)
        if content != resource_bytes(second[name]):
            raise ValueError("non_deterministic_reference")
        path = destination / name
        if verify:
            if path.read_bytes() != content:
                raise ValueError("reference_resource_drift")
        else:
            destination.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        print(name + " sha256=" + c.digest(content))


def run_tests(test_class, prefix="test_"):
    names = [name for name in unittest.TestLoader().getTestCaseNames(test_class) if name.startswith(prefix)]
    suite = unittest.TestSuite(test_class(name) for name in names)
    with patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("network forbidden")):
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() and not result.skipped else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--safety", action="store_true")
    mode.add_argument("--generate", action="store_true")
    mode.add_argument("--verify", action="store_true")
    mode.add_argument("--baseline-tests", action="store_true")
    parser.add_argument("--baseline-dir", type=Path, required=True,
                        help="Read-only directory containing the pinned controller.py and test_controller.py")
    parser.add_argument("--output-dir", type=Path, default=ROOT)
    args = parser.parse_args()
    BASELINE_ROOT = args.baseline_dir.resolve()
    with load_baseline(BASELINE_ROOT) as (c, baseline):
        verify_source()
        if args.baseline_tests:
            sys.exit(run_tests(baseline.ExecutorTests))
        if args.safety:
            safety = type("SharedSafetyTests", (SharedSafetyCases, baseline.ExecutorTests), {})
            sys.exit(run_tests(safety, "test_021_"))
        if args.self_test:
            sys.exit(run_tests(ReferenceTests))
        generate_resources(args.output_dir, verify=args.verify)
