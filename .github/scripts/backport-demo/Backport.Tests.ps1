# Offline harness, compatibility contracts, and baseline stage equivalents.
# Reserved identities: exact leaf It names "test_*" map to parity.json;
# migration cases carry TEST-013..TEST-024 tags. Harness cases never impersonate them.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'Run-Tests.ps1')
    $script:HarnessRoot = Join-Path (Split-Path -Parent $PSScriptRoot) ('.backport-run-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:HarnessRoot
    $script:Reference = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'parity.json') -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100

    function New-SyntheticParity {
        @{
            schema = 1
            baseline = Copy-BackportTestValue $script:Reference.baseline
            baseline_tests = Copy-BackportTestValue $script:Reference.baseline_tests
            required_migration_ids = @(13..24 | ForEach-Object { 'TEST-{0:d3}' -f $_ })
            vectors = @()
        }
    }
    function New-SyntheticResult {
        $parity = New-SyntheticParity
        $tests = @($parity.baseline_tests | ForEach-Object {
            [pscustomobject]@{ Name = $_.pester_name; Tag = @(); Result = 'Passed'; Executed = $true }
        }) + @($parity.required_migration_ids | ForEach-Object {
            [pscustomobject]@{ Name = "synthetic migration $_"; Tag = @($_); Result = 'Passed'; Executed = $true }
        })
        [pscustomobject]@{
            Result = 'Passed'; Tests = $tests; TotalCount = $tests.Count
            PassedCount = $tests.Count; FailedCount = 0; SkippedCount = 0; NotRunCount = 0
            FailedContainersCount = 0; FailedBlocksCount = 0; ErrorRecord = @()
            Containers = @([pscustomobject]@{ ErrorRecord = @() })
        }
    }
    function New-SyntheticDevelopmentResult {
        $result = New-SyntheticResult
        $result.Tests = @([pscustomobject]@{
            Name = 'synthetic harness case'; Tag = @('EPIC-001'); Result = 'Passed'; Executed = $true
        })
        $result.TotalCount = $result.PassedCount = 1
        $result
    }
}

Describe 'Baseline stages with real owned Git and fake HTTP' -Tag 'EPIC-003' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force
        $script:StageCore = Get-Module Backport
    }
    BeforeEach {
        $script:T = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $script:StageCore
        $script:StageTest = $script:T
        & $script:StageCore { param($t) $script:StageTest = $t } $script:T
        Mock -ModuleName Backport New-BackportHttpClient { throw 'network_forbidden' }
        Mock -ModuleName Backport Get-BackportToken { 'offline-fixture' }
        Mock -ModuleName Backport Invoke-BackportHttp {
            param($Config, $Method, $Path, $Data)
            & $script:StageTest.Http $script:StageTest $Method $Path $Data
        }
        Mock -ModuleName Backport New-BackportGitStartInfo {
            param($Config, $WorkingDirectory, $Arguments, $Auth)
            & $script:StageTest.Git $script:StageTest $Config $WorkingDirectory $Arguments $Auth
        }
        Mock -ModuleName Backport Invoke-BackportProcess {
            param($StartInfo, $Data, $TimeoutSeconds = 180)
            & $script:StageTest.Process $script:StageTest $StartInfo $Data $TimeoutSeconds
        }
    }
    AfterEach {
        Remove-LocalGitFixture $script:T.Fixture
    }
    It 'test_two_commit_fast_forward_cannot_drop_first_same_file_edit' {
        Assert-StagePartialSourceRejected $T 'fast-forward'
    }
    It 'test_two_commit_rebase_cannot_drop_first_same_file_edit' {
        Assert-StagePartialSourceRejected $T 'rebase'
    }
    It 'test_squash_parent_cannot_already_contain_a_pr_commit' {
        Assert-StagePartialSourceRejected $T 'partial-parent'
        $T.Fixture.Source | Should -Not -BeIn $T.Fixture.Commits
    }
    It 'test_prove_plan_rejects_partial_source_using_exact_api_commits' {
        Set-StageMultiCommitSource $T 'fast-forward'
        $plan = & $T.Module { param($c) Get-BackportBinding $c } $T.Config
        foreach ($entry in @{
            source_sha = $T.Fixture.Source; source_head_sha = $T.Fixture.Head
            target_base_sha = $T.Fixture.Target; target_ref = 'releases/29.x'
            files = @('src/one.al'); commits = $T.Fixture.Commits
        }.GetEnumerator()) { $plan[$entry.Key] = $entry.Value }
        $null = [IO.Directory]::CreateDirectory($T.Config.state_dir)
        Set-StageJson $T 'plan.json' $plan
        $T.Environment.INPUT_DRY_RUN = 'true'
        Set-BackportStageConfig $T
        $plan.dry_run = $true
        Set-StageJson $T 'plan.json' $plan
        $null = Invoke-BackportTestStage $T track
        { Invoke-BackportTestStage $T prepare } | Should -Throw -ExpectedMessage 'source_not_squash'
        Assert-StageNoPublication $T
    }
    It 'test_prove_plan_rejects_truncated_commit_list_before_git_proof' {
        Set-StageMultiCommitSource $T 'squash'
        $null = Invoke-BackportTestStages $T -Last track
        Edit-StageJson $T 'plan.json' { param($p) $p.commits = @($T.Fixture.Head) }
        $hash = Get-StagePlanHash $T
        Edit-StageJson $T 'tracking.json' { param($p) $p.plan_hash = $hash }
        $T.GitCalls.Clear()
        { Invoke-BackportTestStage $T prepare } | Should -Throw -ExpectedMessage 'source_commits_changed'
        @($T.GitCalls | Where-Object { $_.arguments[0] -in @('fetch', 'diff', 'merge-base') }).Count | Should -Be 0
    }
    It 'test_multi_commit_squash_copies_both_edits_with_lf_and_crlf' {
        foreach ($newline in @("`n", "`r`n")) {
            Set-StageMultiCommitSource $T 'squash' $newline
            $T.Environment.INPUT_DRY_RUN = 'true'
            $T.Environment.STATE_DIR = Join-Path $T.Fixture.Root ("state-eol-" + $newline.Length)
            Set-BackportStageConfig $T
            $parentAncestors = (Invoke-StageFixtureGit $T @('rev-list', "$($T.Fixture.Source)^")).Split("`n")
            foreach ($sha in $T.Fixture.Commits) { $sha | Should -Not -BeIn $parentAncestors }
            (Invoke-StageFixtureGit $T @('show', "$($T.Fixture.Source):src/one.al")) | Should -Not -Match "`r"
            (Invoke-BackportTestStages $T).status | Should -BeExactly 'applied'
            (Get-StageJson $T).commits | Should -Be $T.Fixture.Commits
            $patch = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'patch.bin')))
            $patch | Should -Match '\+FIRST EDIT'
            $patch | Should -Match '\+SECOND EDIT'
            (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'dry-run'
            @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
        }
    }
    It 'test_single_commit_source_equal_to_head_is_complete' {
        $null = Invoke-StageFixtureGit $T @('reset', '--hard', $T.Fixture.Head)
        $T.Api.source.merge_commit_sha = $T.Fixture.Head
        (Invoke-BackportTestStages $T).status | Should -BeExactly 'applied'
        (Get-StageJson $T).commits | Should -Be @($T.Fixture.Head)
        [IO.File]::ReadAllText((Join-Path $T.Config.state_dir 'patch.bin')) | Should -Match '\+ONE'
    }
    It 'test_environment_is_strict_and_fork_owner_is_mandatory' {
        $mutations = @{
            GITHUB_REPOSITORY = @('microsoft/BCApps', 'evil/BCApps-Backport-Test')
            GITHUB_REPOSITORY_ID = @('1', ''); GITHUB_REF = @('refs/heads/feature', '')
            GITHUB_ACTOR_ID = @('1234', '', "59250993`n")
            INPUT_SOURCE_PR = @('0', '-1', '2147483648', '7;echo', ' 7', "7`n", '01')
            INPUT_DRY_RUN = @('True', '1', '', "false`n")
            GITHUB_RUN_ID = @('', "1`n"); GITHUB_RUN_ATTEMPT = @('0')
            GITHUB_TRIGGERING_ACTOR = @('', "owner`n", '../owner')
            ALLOWED_ACTOR_IDS = @('', 'owner', '59250993,', '1;evil')
        }
        foreach ($entry in $mutations.GetEnumerator()) {
            foreach ($value in $entry.Value) {
                $environment = Copy-BackportTestValue $T.Environment
                $environment[$entry.Key] = $value
                { & $T.Module { param($e) New-BackportContext -Environment $e } $environment } | Should -Throw
            }
        }
        $T.Api.calls.Count | Should -Be 0
    }
    It 'test_rerun_triggering_actor_must_also_be_allowlisted' {
        $T.Api.actor = 12
        { Invoke-BackportTestStage $T validate } | Should -Throw -ExpectedMessage 'triggering_actor_not_allowed'
        @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
    }
    It 'test_allowlist_comes_only_from_protected_variable' {
        $environment = Copy-BackportTestValue $T.Environment
        $environment.GITHUB_ACTOR_ID = '12'
        $environment.ALLOWED_ACTOR_IDS = '59250993,12'
        $config = & $T.Module { param($e) New-BackportContext -Environment $e } $environment
        12 | Should -BeIn $config.allowed_actor_ids
        $environment.Remove('ALLOWED_ACTOR_IDS')
        $environment.INPUT_ALLOWED_ACTOR_IDS = '12'
        { & $T.Module { param($e) New-BackportContext -Environment $e } $environment } | Should -Throw
    }
    It 'matches Python user-login coercion for <Case>' -Tag 'TEST-018', 'TEST-020' -ForEach @(
        @{ Case = 'string casefold'; Actor = 'author'; UserResponse = @{ id = 59250993; login = 'AUTHOR' }; Accepted = $true }
        @{ Case = 'different string'; Actor = 'author'; UserResponse = @{ id = 59250993; login = 'other' }; Accepted = $false }
        @{ Case = 'singleton string list'; Actor = 'author'; UserResponse = @{ id = 59250993; login = @('author') }; Accepted = $false }
        @{ Case = 'singleton integer list'; Actor = '123'; UserResponse = @{ id = 59250993; login = @(123) }; Accepted = $false }
        @{ Case = 'singleton boolean list'; Actor = 'True'; UserResponse = @{ id = 59250993; login = @($true) }; Accepted = $false }
        @{ Case = 'empty list'; Actor = 'author'; UserResponse = @{ id = 59250993; login = @() }; Accepted = $false }
        @{ Case = 'dictionary'; Actor = 'author'; UserResponse = @{ id = 59250993; login = @{ name = 'author' } }; Accepted = $false }
        @{ Case = 'null matching None'; Actor = 'None'; UserResponse = @{ id = 59250993; login = $null }; Accepted = $true }
        @{ Case = 'null different actor'; Actor = 'author'; UserResponse = @{ id = 59250993; login = $null }; Accepted = $false }
        @{ Case = 'integer scalar'; Actor = '1'; UserResponse = @{ id = 59250993; login = 1 }; Accepted = $true }
        @{ Case = 'integral float'; Actor = '1'; UserResponse = @{ id = 59250993; login = 1.0 }; Accepted = $false }
        @{ Case = 'negative-exponent float'; Actor = '1e-05'; UserResponse = @{ id = 59250993; login = 1e-05 }; Accepted = $true }
        @{ Case = 'infinity float'; Actor = 'inf'; UserResponse = @{ id = 59250993; login = [double]::PositiveInfinity }; Accepted = $true }
        @{ Case = 'NaN float'; Actor = 'nan'; UserResponse = @{ id = 59250993; login = [double]::NaN }; Accepted = $true }
        @{ Case = 'boolean scalar'; Actor = 'True'; UserResponse = @{ id = 59250993; login = $true }; Accepted = $true }
        @{ Case = 'missing login'; Actor = 'author'; UserResponse = @{ id = 59250993 }; Accepted = $false }
    ) {
        $oracle = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $T.Module -Template $T
        try {
            Copy-StageFixtureRefs $T $oracle
            foreach ($test in @($T, $oracle)) {
                $test.Environment.GITHUB_TRIGGERING_ACTOR = $Actor
                Set-BackportStageConfig $test
            }
            $T.HttpFilter = {
                param($t, $method, $path, $data)
                $value = Invoke-FakeGitHub $t.Api $method $path $data
                if ($method -ceq 'GET' -and $path -ceq "/users/$Actor") {
                    return ,$UserResponse.Clone()
                }
                return ,$value
            }
            $python = Invoke-PythonStageHandoff $oracle @('validate') -CaptureFailure -UserResponse $UserResponse
            if ($Accepted) {
                $python.failure | Should -BeNullOrEmpty
                $plan = Invoke-BackportTestStage $T validate
                $plan.source_sha | Should -BeExactly $T.Fixture.Source
                [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'plan.json'))) |
                    Should -BeExactly ([Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $oracle.Config.state_dir 'plan.json'))))
            }
            else {
                $python.failure | Should -BeExactly 'triggering_actor_mismatch'
                { Invoke-BackportTestStage $T validate } | Should -Throw -ExpectedMessage 'triggering_actor_mismatch'
                foreach ($test in @($T, $oracle)) {
                    Test-Path -LiteralPath (Join-Path $test.Config.state_dir 'plan.json') | Should -BeFalse
                    $test.GitEffects.Count | Should -Be 0
                    $test.Api.calls.Count | Should -Be 2
                }
            }
            foreach ($key in @('calls', 'GitEffects')) {
                $actual = if ($key -ceq 'calls') { @($T.Api.calls.ToArray()) } else { @($T.GitEffects.ToArray()) }
                $expected = if ($key -ceq 'calls') { @($oracle.Api.calls.ToArray()) } else { @($oracle.GitEffects.ToArray()) }
                $actualBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $actual)
                $expectedBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $expected)
                [Convert]::ToHexString($actualBytes) | Should -BeExactly ([Convert]::ToHexString($expectedBytes))
            }
            @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
        }
        finally { Remove-LocalGitFixture $oracle.Fixture }
    }
    It 'test_source_repository_merge_base_and_metadata_are_checked' {
        $original = Copy-BackportTestValue $T.Api.source
        foreach ($edit in @(
            { param($x) $x.merged = $false }, { param($x) $x.number = 8 }
            { param($x) $x.base.ref = 'other' }, { param($x) $x.base.repo.id = 1 }
            { param($x) $x.merge_commit_sha = 'bad' }, { param($x) $x.changed_files = 2 }
        )) {
            $T.Api.source = Copy-BackportTestValue $original
            & $edit $T.Api.source
            { Invoke-BackportTestStage $T validate } | Should -Throw
        }
    }
    It 'test_non_squash_net_diff_is_rejected' {
        Set-StageFixtureText $T 'src\one.al' "unrelated`n"
        $null = Invoke-StageFixtureGit $T @('commit', '-am', 'not the PR patch')
        $T.Api.source.merge_commit_sha = Invoke-StageFixtureGit $T @('rev-parse', 'HEAD')
        { Invoke-BackportTestStage $T validate } | Should -Throw
    }
    It 'test_paths_reject_traversal_controls_backslashes_and_non_al' {
        foreach ($path in @('src/../x.al', '/src/a.al', 'src//a.al', 'src/./a.al',
            'src\a.al', "src/a`nb.al", "src/a`0.al", "src/a`u{7f}.al",
            '.github/x.al', 'src/a.py', 'src/C:/a.al', 'src/CON.al', 'src/a. /b.al', 'src/.git/a.al')) {
            { & $T.Module { param($p) Assert-BackportPath $p } $path } | Should -Throw
        }
        (& $T.Module { Assert-BackportPath 'src/Module/My Code.al' }) | Should -BeExactly 'src/Module/My Code.al'
    }
    It 'test_raw_entries_reject_executable_symlink_gitlink_and_control_paths' {
        foreach ($mode in @('100755', '120000', '160000')) {
            $raw = [Text.Encoding]::UTF8.GetBytes(":100644 $mode $('a' * 40) $('a' * 40) M`0src/a.al`0")
            { & $T.Module { param($b) ConvertFrom-BackportRawDiff $b } $raw } | Should -Throw
        }
        $raw = [Text.Encoding]::UTF8.GetBytes(":100644 100644 $('a' * 40) $('a' * 40) M`0src/a`nb.al`0")
        { & $T.Module { param($b) ConvertFrom-BackportRawDiff $b } $raw } | Should -Throw
    }
    It 'test_size_limits_and_binary_blobs_are_rejected' {
        foreach ($contents in @([byte[]]@(97, 0, 98), ([Text.Encoding]::UTF8.GetBytes(('x' * (1024 * 1024 + 1)))))) {
            $null = Invoke-StageFixtureGit $T @('switch', 'feature')
            [IO.File]::WriteAllBytes((Join-Path $T.Fixture.Origin 'src\one.al'), $contents)
            $null = Invoke-StageFixtureGit $T @('commit', '-am', 'large or binary')
            Update-StageSource $T
            { Invoke-BackportTestStage $T validate } | Should -Throw
        }
    }
    It 'test_file_count_and_total_patch_limits' {
        $null = Invoke-StageFixtureGit $T @('switch', 'feature')
        foreach ($i in 1..50) { Set-StageFixtureText $T "src\extra$i.al" "new AL`n" }
        $null = Invoke-StageFixtureGit $T @('add', '.')
        $null = Invoke-StageFixtureGit $T @('commit', '-m', '51 changed files')
        Update-StageSource $T -ChangedFiles 51
        { Invoke-BackportTestStage $T validate } | Should -Throw
        $null = Invoke-StageFixtureGit $T @('switch', 'feature')
        $null = Invoke-StageFixtureGit $T @('reset', '--hard', $T.Fixture.Target)
        foreach ($i in 1..6) { Set-StageFixtureText $T "src\large$i.al" (('x' * (1024 * 1024 - 2)) + "`n") }
        $null = Invoke-StageFixtureGit $T @('add', '.')
        $null = Invoke-StageFixtureGit $T @('commit', '-m', 'patch over five MiB')
        Update-StageSource $T -ChangedFiles 6
        { Invoke-BackportTestStage $T validate } | Should -Throw -ExpectedMessage 'patch_too_large'
        Assert-StageNoPublication $T
    }
    It 'test_all_stages_dry_run_never_write_remotely' {
        $T.Environment.INPUT_DRY_RUN = 'true'
        Set-BackportStageConfig $T
        (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'dry-run'
        @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
        (Invoke-LocalGit $T.Fixture $T.Fixture.Origin @('branch', '--list', 'backport/*')) | Should -BeExactly ''
        $T.Pushes.Count | Should -Be 0
    }
    It 'test_clean_cherry_pick_publish_and_duplicate_reconcile' {
        $result = Invoke-BackportTestStages $T
        $result.status | Should -BeExactly 'applied'
        $result.published | Should -BeFalse
        $result.patch_sha256 | Should -BeExactly (Get-StageHash ([IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'patch.bin'))))
        $published = Invoke-BackportTestStage $T publish
        $published.status | Should -BeExactly 'pr-created'
        $published.pr_url | Should -BeExactly $T.Api.pulls[0].html_url
        (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'pr-reused'
        (Invoke-BackportTestStage $T track).issue_number | Should -Be 101
        $T.Api.issues.Count | Should -Be 1
        $T.Api.pulls.Count | Should -Be 1
        @($T.Api.comments.Values | ForEach-Object Count) | Should -Be @(1, 1)
        (Invoke-StageFixtureGit $T @('show', 'backport/29.x/pr-7:src/one.al')) | Should -BeExactly "ONE`ntwo`nthree"
        (Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7^')) | Should -BeExactly $T.Fixture.Target
    }
    It 'test_full_rerun_after_publication_reuses_issue_and_pr' {
        (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'pr-created'
        $listed = Invoke-FakeGitHub $T.Api GET '/repos/AleksanderGladkov/BCApps-Backport-Test/issues?state=all&per_page=100&page=1'
        $listed.Count | Should -Be 2
        @($listed | Where-Object { $_.ContainsKey('pull_request') }).Count | Should -Be 1
        foreach ($obj in $listed) { $obj.body | Should -Match ('bc-backport:v1:1369849596:7:' + $T.Fixture.Source + ':29') }
        $head = Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7')
        $creates = @($T.Api.calls | Where-Object method -CEQ 'POST').Count
        foreach ($attempt in @('1', '2')) {
            if ($attempt -ceq '2') { New-StageAttempt $T } else { Set-BackportStageConfig $T }
            (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'pr-reused'
            (Get-StageJson $T).run_attempt | Should -BeExactly $attempt
            $T.Api.issues.Count | Should -Be 1
            $T.Api.pulls.Count | Should -Be 1
            @($T.Api.calls | Where-Object method -CEQ 'POST').Count | Should -Be $creates
            (Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7')) | Should -BeExactly $head
            @($T.Api.comments.Values | ForEach-Object Count) | Should -Be @(1, 1)
        }
    }
    It 'test_conflict_emits_resolver_input_without_publication' {
        Set-StageConflict $T
        $result = Invoke-BackportTestStages $T
        $result.status | Should -BeExactly 'needs-attention'
        $conflict = Get-StageJson $T 'conflict.json'
        @($conflict.Keys | Sort-Object) | Should -Be @('files', 'repo', 'source_pr', 'source_sha', 'target_base_sha', 'worktree')
        $conflict.repo | Should -BeExactly $T.Environment.GITHUB_REPOSITORY
        $conflict.files[0].relative_path | Should -BeExactly 'src/one.al'
        [IO.Path]::IsPathFullyQualified($conflict.files[0].absolute_path) | Should -BeTrue
        Test-Path -LiteralPath $conflict.worktree -PathType Container | Should -BeTrue
        (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'needs-attention'
        Assert-StageNoPublication $T
    }
    It 'test_already_applied_requires_content_proof_and_creates_no_pr' {
        $null = Invoke-StageFixtureGit $T @('switch', 'releases/29.x')
        $null = Invoke-StageFixtureGit $T @('cherry-pick', $T.Fixture.Source)
        $T.Api.target = Invoke-StageFixtureGit $T @('rev-parse', 'HEAD')
        $null = Invoke-StageFixtureGit $T @('switch', 'main')
        (Invoke-BackportTestStages $T).status | Should -BeExactly 'already_applied'
        (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'already_applied'
        Assert-StageNoPublication $T
    }
    It 'test_artifacts_cannot_cross_runs_attempts_or_source_context' {
        $null = Invoke-BackportTestStages $T
        foreach ($entry in @{ GITHUB_RUN_ID = '124'; GITHUB_RUN_ATTEMPT = '2'; INPUT_SOURCE_PR = '8' }.GetEnumerator()) {
            $old = $T.Environment[$entry.Key]
            $T.Environment[$entry.Key] = $entry.Value
            Set-BackportStageConfig $T
            { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'artifact_context_mismatch'
            $T.Environment[$entry.Key] = $old
        }
        $T.Api.pulls.Count | Should -Be 0
    }
    It 'test_result_and_patch_tampering_fail_closed' {
        $null = Invoke-BackportTestStages $T
        $original = Get-StageJson $T 'result.json'
        foreach ($edit in @(
            { param($x) $x.tree_sha = 'a' * 40 }, { param($x) $x.status = 'resolved' }
            { param($x) $x.published = $true }, { param($x) $x.plan_hash = 'a' * 64 }
            { param($x) $x.extra = 'untrusted' }
        )) {
            Set-StageJson $T 'result.json' $original
            Edit-StageJson $T 'result.json' $edit
            { Invoke-BackportTestStage $T publish } | Should -Throw
        }
        Set-StageJson $T 'result.json' $original
        [IO.File]::WriteAllBytes((Join-Path $T.Config.state_dir 'patch.bin'), [Text.Encoding]::UTF8.GetBytes('evil'))
        { Invoke-BackportTestStage $T publish } | Should -Throw
        Assert-StageNoPublication $T
    }
    It 'test_target_advance_has_no_branch_or_pr_write' {
        $null = Invoke-BackportTestStages $T
        $T.Api.target = 'a' * 40
        $result = Invoke-BackportTestStage $T publish
        $result.status | Should -BeExactly 'needs-attention'
        $result.reason | Should -BeExactly 'target_advanced'
        Assert-StageNoPublication $T
    }
    It 'test_source_or_triggering_actor_changes_are_rechecked_before_writes' {
        $null = Invoke-BackportTestStages $T
        $T.Api.source.merge_commit_sha = $T.Fixture.Target
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'source_changed'
        $T.Api.source.merge_commit_sha = $T.Fixture.Source
        $T.Api.actor = 12
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'triggering_actor_not_allowed'
        Assert-StageNoPublication $T
    }
    It 'test_duplicate_and_spoofed_tracking_issues_block' {
        $null = Invoke-BackportTestStages $T -Last track
        $T.Api.issues.Add((Copy-BackportTestValue $T.Api.issues[0]))
        { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'duplicate_tracking_issues'
        $T.Api.issues.RemoveAt(1)
        $T.Api.issues[0].user.id = 123
        { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'object_not_actions_bot_owned'
    }
    It 'test_issue_pagination_ignores_same_title_without_marker' {
        $null = Invoke-BackportTestStages $T -Last track
        $real = $T.Api.issues[0]
        $T.Api.issues.Clear()
        foreach ($i in 200..299) { $T.Api.issues.Add(@{ number = $i; title = $real.title; body = ''; user = @{ id = 12 } }) }
        $T.Api.issues.Add($real)
        (Invoke-BackportTestStage $T track).issue_number | Should -Be 101
        @($T.Api.calls | Where-Object path -Match 'page=2').Count | Should -BeGreaterThan 0
    }
    It 'test_closed_issue_requires_verified_merged_pr' {
        $null = Invoke-BackportTestStages $T
        $T.Api.issues[0].state = 'closed'
        { Invoke-BackportTestStage $T track } | Should -Throw
        $T.Api.issues[0].state = 'open'
        $null = Invoke-BackportTestStage $T publish
        $T.Api.issues[0].state = 'closed'
        $T.Api.pulls[0].state = 'closed'
        $T.Api.pulls[0].merged = $true
        $T.Api.pulls[0].merged_at = '2026-09-14T00:00:00Z'
        (Invoke-BackportTestStage $T track).issue_number | Should -Be 101
    }
    It 'test_ambiguous_issue_create_is_not_retried_in_same_run' {
        $null = Invoke-BackportTestStage $T validate
        $T.Api.fail_post = '/repos/AleksanderGladkov/BCApps-Backport-Test/issues'
        foreach ($i in 1..2) { { Invoke-BackportTestStage $T track } | Should -Throw }
        @($T.Api.calls | Where-Object method -CEQ 'POST').Count | Should -Be 1
        (Get-StageJson $T 'tracking.json').status | Should -BeExactly 'ambiguous'
    }
    It 'test_lost_create_response_can_reconcile_without_reposting' {
        $null = Invoke-BackportTestStage $T validate
        $T.Api.lose_post_response = '/repos/AleksanderGladkov/BCApps-Backport-Test/issues'
        { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'api_write_ambiguous'
        (Invoke-BackportTestStage $T track).issue_number | Should -Be 101
        $T.Api.issues.Count | Should -Be 1
    }
    It 'test_lost_issue_response_with_stale_listing_blocks_new_attempt_and_run' -Tag 'TEST-019' {
        $route = '/repos/AleksanderGladkov/BCApps-Backport-Test/issues'
        $null = Invoke-BackportTestStage $T validate
        $T.Api.lose_post_response = $route
        { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'api_write_ambiguous'
        $T.Api.lose_post_response = $null
        foreach ($pair in @(@('123', '2'), @('124', '1'))) {
            New-StageAttempt $T $pair[0] $pair[1]
            Test-Path -LiteralPath (Join-Path $T.Config.state_dir 'tracking.json') | Should -BeFalse
            $null = Invoke-BackportTestStage $T validate
            $null = $T.Api.stale_paths.Add($route)
            { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
            $T.Api.stale_paths.Clear()
            (Invoke-BackportTestStage $T track).issue_number | Should -Be 101
        }
        @($T.Api.calls | Where-Object method -CEQ 'POST').Count | Should -Be 1
        $T.Api.issues.Count | Should -Be 1
    }
    It 'test_lost_source_comment_response_stale_on_rerun_never_reposts' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStages $T
        $route = '/repos/AleksanderGladkov/BCApps-Backport-Test/issues/7/comments'
        $T.Api.lose_post_response = $route
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'api_write_ambiguous'
        $T.Api.lose_post_response = $null
        $creates = @($T.Api.calls | Where-Object method -CEQ 'POST').Count
        $head = Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7')
        foreach ($pair in @(@('123', '2'), @('124', '1'))) {
            New-StageAttempt $T $pair[0] $pair[1]
            Test-Path -LiteralPath (Join-Path $T.Config.state_dir 'publication.json') | Should -BeFalse
            $null = Invoke-BackportTestStages $T
            $null = $T.Api.stale_paths.Add($route)
            $T.Pushes.Clear()
            { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
            $T.Api.stale_paths.Clear()
            (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'pr-reused'
            $T.Pushes.Count | Should -Be 0
            @($T.Api.calls | Where-Object method -CEQ 'POST').Count | Should -Be $creates
            (Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7')) | Should -BeExactly $head
        }
        @($T.Api.calls | Where-Object method -CEQ 'PATCH').Count | Should -BeGreaterThan 0
        @($T.Api.comments.Values | ForEach-Object Count) | Should -Be @(1, 1)
    }
    It 'test_incomplete_feedback_does_not_guess_recovery_on_new_attempt' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStages $T
        $route = '/repos/AleksanderGladkov/BCApps-Backport-Test/issues/101/comments'
        $T.Api.lose_post_response = $route
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'api_write_ambiguous'
        $T.Api.lose_post_response = $null
        $creates = @($T.Api.calls | Where-Object method -CEQ 'POST').Count
        New-StageAttempt $T
        $null = Invoke-BackportTestStages $T
        foreach ($stale in @($true, $false)) {
            $T.Api.stale_paths.Clear()
            if ($stale) { $null = $T.Api.stale_paths.Add($route) }
            { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
        }
        @($T.Api.calls | Where-Object method -CEQ 'POST').Count | Should -Be $creates
        $T.Api.comments[101].Count | Should -Be 1
        $T.Api.comments.ContainsKey(7) | Should -BeFalse
    }
    It 'test_ambiguous_push_cannot_be_retried_without_branch_on_new_run' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStages $T
        $T.BeforePush = { throw 'push_failed_or_ambiguous' }
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'push_failed_or_ambiguous'
        $T.Pushes.Count | Should -Be 1
        $T.BeforePush = $null
        New-StageAttempt $T '124' '1'
        $null = Invoke-BackportTestStages $T
        $T.Pushes.Clear()
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
        $T.Pushes.Count | Should -Be 0
        Assert-StageNoPublication $T
    }
    It 'test_lost_pr_response_with_stale_listing_cannot_create_on_new_run' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStages $T
        $route = '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls'
        $T.Api.lose_post_response = $route
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'api_write_ambiguous'
        $T.Api.lose_post_response = $null
        $null = $T.Api.stale_paths.Add($route)
        $head = Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7')
        New-StageAttempt $T '124' '1'
        $null = Invoke-BackportTestStages $T
        $T.Pushes.Clear()
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
        $T.Pushes.Count | Should -Be 0
        @($T.Api.calls | Where-Object { $_.method -ceq 'POST' -and $_.path -ceq $route }).Count | Should -Be 1
        $T.Api.pulls.Count | Should -Be 1
        (Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7')) | Should -BeExactly $head
    }
    It 'test_known_dry_runs_and_other_sources_allow_fresh_creation' -Tag 'TEST-019' {
        $T.Api.runs.Add((New-FakeWorkflowRun -Api $T.Api -Id 120 -DryRun $true -Attempt 2))
        $T.Api.runs.Add((New-FakeWorkflowRun -Api $T.Api -Id 121 -SourcePr 8))
        (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'pr-created'
        @($T.Api.calls | Where-Object path -CEQ '/repos/AleksanderGladkov/BCApps-Backport-Test/actions/runs/123').Count | Should -Be 5
    }
    It 'test_history_gate_blocks_any_previous_nondry_conclusion' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStage $T validate
        $previous = New-FakeWorkflowRun -Api $T.Api -Id 122
        $T.Api.runs.Add($previous)
        foreach ($conclusion in @($null, 'success', 'failure', 'cancelled', 'skipped', 'timed_out')) {
            $previous.conclusion = $conclusion
            { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
        }
        @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
    }
    It 'test_history_read_failure_blocks_creation_without_local_ambiguity' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStage $T validate
        foreach ($suffix in @('/actions/runs/123', '/actions/workflows/backport-demo.yml/runs')) {
            $T.HttpFilter = {
                param($t, $method, $path, $data)
                if ($path.Split('?')[0] -ceq ('/repos/AleksanderGladkov/BCApps-Backport-Test' + $suffix)) { throw 'api_read_failed' }
                Invoke-FakeGitHub $t.Api $method $path $data
            }
            { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'api_read_failed'
            Test-Path -LiteralPath (Join-Path $T.Config.state_dir 'tracking.json') | Should -BeFalse
        }
        @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
    }
    It 'test_current_run_must_match_repository_workflow_source_and_attempt' -Tag 'TEST-019' {
        $mutations = @(
            @{ Key = 'id'; Value = 999 }
            @{ Key = 'workflow_id'; Value = $true }
            @{ Key = 'run_attempt'; Value = 2 }
            @{ Key = 'repository'; Value = @{ id = 1; full_name = $T.Environment.GITHUB_REPOSITORY } }
            @{ Key = 'head_repository'; Value = @{ id = 1369849596; full_name = 'evil/repo' } }
            @{ Key = 'path'; Value = '.github/workflows/other.yml' }
            @{ Key = 'event'; Value = 'pull_request' }
            @{ Key = 'head_branch'; Value = 'feature' }
            @{ Key = 'display_title'; Value = $null }
            @{ Key = 'display_title'; Value = 'Backport PR 8 to 29.x (dry run = false)' }
            @{ Key = 'display_title'; Value = 'Backport PR 7 to 29.x (dry run = true)' }
        )
        $mutations.Count | Should -Be 11
        foreach ($mutation in $mutations) {
            $T.HttpFilter = {
                param($t, $method, $path, $data)
                $result = Invoke-FakeGitHub $t.Api $method $path $data
                if ($path.EndsWith('/actions/runs/123')) { $result[$mutation.Key] = $mutation.Value }
                return ,$result
            }
            { & $T.Module { param($c) Assert-BackportFreshCreation -Config $c } $T.Config } | Should -Throw
        }
        @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
    }
    It 'test_unknown_or_wrong_scope_history_never_grants_creation' -Tag 'TEST-019' {
        $current = $T.Api.runs[0]
        $mutations = @(
            @{ Key = 'id'; Value = '122' }
            @{ Key = 'workflow_id'; Value = 999 }
            @{ Key = 'run_attempt'; Value = 0 }
            @{ Key = 'repository'; Value = @{ id = 1; full_name = $T.Environment.GITHUB_REPOSITORY } }
            @{ Key = 'head_repository'; Value = $null }
            @{ Key = 'event'; Value = 'push' }
            @{ Key = 'head_branch'; Value = 'feature' }
            @{ Key = 'path'; Value = '.github/workflows/other.yml' }
            @{ Key = 'display_title'; Value = $null }
            @{ Key = 'display_title'; Value = 'old workflow title' }
            @{ Key = 'display_title'; Value = 'Backport PR 07 to 29.x (dry run = true)' }
            @{ Key = 'display_title'; Value = "Backport PR 7 to 29.x (dry run = true)`n" }
            @{ Key = 'display_title'; Value = 'Backport PR 2147483648 to 29.x (dry run = true)' }
        )
        $mutations.Count | Should -Be 13
        foreach ($mutation in $mutations) {
            $previous = New-FakeWorkflowRun -Api $T.Api -Id 122 -DryRun $true
            $previous[$mutation.Key] = $mutation.Value
            $T.Api.runs.Clear()
            $T.Api.runs.Add($current)
            $T.Api.runs.Add($previous)
            { & $T.Module { param($c) Assert-BackportFreshCreation -Config $c } $T.Config } | Should -Throw
        }
    }
    It 'test_history_paginates_all_runs_including_current_and_possible_writer' -Tag 'TEST-019' {
        $current = $T.Api.runs[0]
        $T.Api.runs.Clear()
        foreach ($i in 1000..1099) { $T.Api.runs.Add((New-FakeWorkflowRun -Api $T.Api -Id $i -DryRun $true)) }
        $T.Api.runs.Add($current)
        & $T.Module { param($c) Assert-BackportFreshCreation -Config $c } $T.Config
        @($T.Api.calls | Where-Object path -Match 'per_page=100&page=2$').Count | Should -Be 1
        $T.Api.runs.Add((New-FakeWorkflowRun -Api $T.Api -Id 122))
        { & $T.Module { param($c) Assert-BackportFreshCreation -Config $c } $T.Config } |
            Should -Throw -ExpectedMessage 'previous_run_may_have_written'
    }
    It 'test_history_rejects_incomplete_duplicate_missing_current_and_oversize_pages' -Tag 'TEST-019' {
        $current = $T.Api.runs[0]
        $dry = New-FakeWorkflowRun -Api $T.Api -Id 122 -DryRun $true
        $wrongAttempt = Copy-BackportTestValue $current
        $wrongAttempt.run_attempt = 2
        $wrongTitle = Copy-BackportTestValue $current
        $wrongTitle.display_title = $dry.display_title
        $pages = @(
            ,@()
            @{}
            @{ total_count = $true; workflow_runs = @($current) }
            @{ total_count = 1; workflow_runs = @{} }
            @{ total_count = 0; workflow_runs = @() }
            @{ total_count = 1; workflow_runs = @($dry) }
            @{ total_count = 2; workflow_runs = @($current) }
            @{ total_count = 2; workflow_runs = @($current, $current) }
            @{ total_count = 1; workflow_runs = @($wrongAttempt) }
            @{ total_count = 1; workflow_runs = @($wrongTitle) }
            @{ total_count = 101; workflow_runs = @($dry) * 101 }
            @{ total_count = 100001; workflow_runs = @($current) }
        )
        $pages.Count | Should -Be 12
        foreach ($page in $pages) {
            $T.HttpFilter = {
                param($t, $method, $path, $data)
                $result = Invoke-FakeGitHub $t.Api $method $path $data
                if ($path.Contains('/actions/workflows/')) { return ,$page }
                return ,$result
            }
            { & $T.Module { param($c) Assert-BackportFreshCreation -Config $c } $T.Config } | Should -Throw
        }
    }
    It 'test_history_detects_count_change_and_repeated_page' -Tag 'TEST-019' {
        foreach ($i in 1000..1099) { $T.Api.runs.Add((New-FakeWorkflowRun -Api $T.Api -Id $i -DryRun $true)) }
        foreach ($changedCount in @($true, $false)) {
            $T.HttpFilter = {
                param($t, $method, $path, $data)
                $result = Invoke-FakeGitHub $t.Api $method $path $data
                if ($path.Contains('/actions/workflows/') -and $path.EndsWith('page=2')) {
                    if ($changedCount) { $result.total_count++ } else { $result.workflow_runs = @($t.Api.runs[0]) }
                }
                return ,$result
            }
            $reason = if ($changedCount) { 'run_history_changed' } else { 'duplicate_run_history' }
            { & $T.Module { param($c) Assert-BackportFreshCreation -Config $c } $T.Config } | Should -Throw -ExpectedMessage $reason
        }
    }
    It 'test_rerun_attempt_blocks_creation_even_without_older_run_entries' -Tag 'TEST-019' {
        New-StageAttempt $T
        $null = Invoke-BackportTestStage $T validate
        { Invoke-BackportTestStage $T track } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
        $T.Api.runs.Count | Should -Be 1
        $T.Api.issues.Count | Should -Be 0
    }
    It 'test_dry_rerun_does_not_need_history_or_mutate' -Tag 'TEST-019' {
        $T.Environment.INPUT_DRY_RUN = 'true'
        New-StageAttempt $T
        $T.HttpFilter = {
            param($t, $method, $path, $data)
            if ($path.Contains('/actions/')) { throw 'unneeded_history' }
            Invoke-FakeGitHub $t.Api $method $path $data
        }
        $T.BeforePush = { throw 'dry_push_forbidden' }
        (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'dry-run'
        @($T.Api.calls | Where-Object { $_.method -cne 'GET' -or $_.path.Contains('/actions/') }).Count | Should -Be 0
        $T.Pushes.Count | Should -Be 0
    }
    It 'test_history_is_rechecked_before_branch_push' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStages $T
        $T.Api.runs.Add((New-FakeWorkflowRun -Api $T.Api -Id 122))
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
        $T.Pushes.Count | Should -Be 0
        Assert-StageNoPublication $T
    }
    It 'test_history_is_rechecked_after_push_before_pr_creation' -Tag 'TEST-019' {
        $null = Invoke-BackportTestStages $T
        $T.AfterPush = { param($t) $t.Api.runs.Add((New-FakeWorkflowRun -Api $t.Api -Id 122)) }
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'previous_run_may_have_written'
        (Invoke-StageFixtureGit $T @('branch', '--list', 'backport/*')) | Should -Not -BeNullOrEmpty
        $T.Api.pulls.Count | Should -Be 0
        @($T.Api.calls | Where-Object method -CEQ 'POST').Count | Should -Be 1
    }
    It 'test_push_lease_rejects_racing_fast_forward_target_without_changes' {
        $null = Invoke-BackportTestStages $T
        $before = (Invoke-StageFixtureGit $T @('show-ref')).Split("`n")
        $T.BeforePush = {
            param($t, $directory, $arguments)
            $arguments | Should -Contain '--force-with-lease=refs/heads/backport/29.x/pr-7:'
            (Invoke-StageFixtureGit $t @('branch', '--list', 'backport/29.x/pr-7')) | Should -BeExactly ''
            $null = Invoke-StageFixtureGit $t @('branch', 'backport/29.x/pr-7', $t.Fixture.Target)
        }
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'push_failed_or_ambiguous'
        (Invoke-StageFixtureGit $T @('rev-parse', 'backport/29.x/pr-7')) | Should -BeExactly $T.Fixture.Target
        @((Invoke-StageFixtureGit $T @('show-ref')).Split("`n") | Sort-Object) |
            Should -Be @(($before + "$($T.Fixture.Target) refs/heads/backport/29.x/pr-7") | Sort-Object)
        @($T.GitCalls | Where-Object { $_.arguments[0] -ceq 'push' -and $_.auth }).Count | Should -Be 1
        $T.Api.pulls.Count | Should -Be 0
        $T.Api.comments.Count | Should -Be 0
    }
    It 'test_mismatched_existing_branch_and_closed_pr_block' {
        $null = Invoke-BackportTestStages $T
        $null = Invoke-StageFixtureGit $T @('branch', 'backport/29.x/pr-7', $T.Fixture.Target)
        { Invoke-BackportTestStage $T publish } | Should -Throw
        $null = Invoke-StageFixtureGit $T @('branch', '-D', 'backport/29.x/pr-7')
        $null = Invoke-BackportTestStage $T publish
        $T.Api.pulls[0].state = 'closed'
        $T.Api.pulls[0].merged = $false
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'closed_unmerged_pr'
    }
    It 'test_github_output_and_summary_are_fixed_and_single_line' {
        $T.Environment.GITHUB_OUTPUT = Join-Path $T.Fixture.Root 'outputs'
        $T.Environment.GITHUB_STEP_SUMMARY = Join-Path $T.Fixture.Root 'summary'
        $T.Environment.INPUT_DRY_RUN = 'true'
        Set-BackportStageConfig $T
        $T.Api.source.title = "AB#999`n<script>untrusted title</script>"
        $T.Api.source.body = 'untrusted body'
        foreach ($stage in @('validate', 'track', 'prepare', 'publish')) {
            [IO.File]::WriteAllText($T.Config.summary, '')
            $null = Invoke-BackportTestStage $T $stage
            $summary = [IO.File]::ReadAllText($T.Config.summary)
            foreach ($value in @("Source SHA: $($T.Fixture.Source)", "Target base SHA: $($T.Fixture.Target)",
                'Target: releases/29.x', 'Branch: backport/29.x/pr-7', 'Files (1):', 'src/one.al',
                'https://github.com/AleksanderGladkov/BCApps-Backport-Test/pull/7', 'Dry run: true', 'No remote changes.')) {
                $summary.Contains($value) | Should -BeTrue -Because $value
            }
            $summary | Should -Not -Match 'offline-fixture|AB#|untrusted|<script>'
        }
        $output = [IO.File]::ReadAllText($T.Config.output)
        $output | Should -Match ([regex]::Escape('plan_ready=true' + [Environment]::NewLine))
        $output | Should -Match ([regex]::Escape('status=dry-run' + [Environment]::NewLine))
        $output | Should -Not -Match 'offline-fixture'
    }
    It 'test_summary_keeps_markdown_filenames_in_escaped_literal_block' {
        $plan = Invoke-BackportTestStage $T validate
        $plan.files = @('src/[link](https&colon;evil)`&lt;script&gt;.al')
        $T.Environment.GITHUB_STEP_SUMMARY = Join-Path $T.Fixture.Root 'summary'
        Set-BackportStageConfig $T
        & $T.Module { param($c, $p) Write-BackportSummary -Config $c -Status validated -Plan $p } $T.Config $plan
        $summary = [IO.File]::ReadAllText($T.Config.summary)
        $newline = [Environment]::NewLine
        $summary.Contains("<pre>${newline}src/[link](https&amp;colon;evil)``&amp;lt;script&amp;gt;.al${newline}</pre>") | Should -BeTrue
        $summary | Should -Not -Match '&lt;script&gt;'
    }
    It 'test_summary_rejects_invalid_plan_fields_without_writing' {
        $plan = Invoke-BackportTestStage $T validate
        $T.Environment.GITHUB_STEP_SUMMARY = Join-Path $T.Fixture.Root 'summary'
        Set-BackportStageConfig $T
        $mutations = @(
            @{ Key = 'source_sha'; Value = (('a' * 40) + "`nSECRET") }
            @{ Key = 'target_base_sha'; Value = '<script>' }
            @{ Key = 'target_ref'; Value = "other`nSECRET" }
            @{ Key = 'files'; Value = @("src/a.al`nSECRET") }
            @{ Key = 'files'; Value = @() }
        )
        $mutations.Count | Should -Be 5
        foreach ($mutation in $mutations) {
            $copy = Copy-BackportTestValue $plan
            $copy[$mutation.Key] = $mutation.Value
            { & $T.Module { param($c, $p) Write-BackportSummary -Config $c -Status validated -Plan $p } $T.Config $copy } | Should -Throw
        }
        Test-Path -LiteralPath $T.Config.summary | Should -BeFalse
        & $T.Module { param($c) Write-BackportSummary -Config $c -Status needs-attention } $T.Config
        [IO.File]::ReadAllText($T.Config.summary) | Should -Not -Match 'SECRET'
    }
    It 'test_added_and_deleted_files_are_supported' {
        $null = Invoke-StageFixtureGit $T @('switch', 'feature')
        Remove-Item -LiteralPath (Join-Path $T.Fixture.Origin 'src\one.al')
        Set-StageFixtureText $T 'src\new.al' "new AL source`n"
        $null = Invoke-StageFixtureGit $T @('add', '-A')
        $null = Invoke-StageFixtureGit $T @('commit', '-m', 'replace file')
        Update-StageSource $T -ChangedFiles 2
        (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'pr-created'
        (Invoke-StageFixtureGit $T @('ls-tree', '--name-only', 'backport/29.x/pr-7', 'src/one.al')) | Should -BeExactly ''
        (Invoke-StageFixtureGit $T @('show', 'backport/29.x/pr-7:src/new.al')) | Should -BeExactly 'new AL source'
    }
    It 'test_merge_commit_with_two_parents_is_rejected' {
        $null = Invoke-StageFixtureGit $T @('reset', '--hard', $T.Fixture.Target)
        $null = Invoke-StageFixtureGit $T @('merge', '--no-ff', 'feature', '-m', 'merge commit')
        $T.Api.source.merge_commit_sha = Invoke-StageFixtureGit $T @('rev-parse', 'HEAD')
        { Invoke-BackportTestStage $T validate } | Should -Throw -ExpectedMessage 'source_not_squash'
    }
    It 'test_ambiguous_pr_create_is_not_retried' {
        $null = Invoke-BackportTestStages $T
        $route = '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls'
        $T.Api.fail_post = $route
        foreach ($i in 1..2) { { Invoke-BackportTestStage $T publish } | Should -Throw }
        @($T.Api.calls | Where-Object { $_.method -ceq 'POST' -and $_.path -ceq $route }).Count | Should -Be 1
        (Get-StageJson $T 'publication.json').attempted | Should -Contain 'pr'
    }
    It 'test_lost_pr_create_response_reuses_verified_pr' {
        $null = Invoke-BackportTestStages $T
        $T.Api.lose_post_response = '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls'
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'api_write_ambiguous'
        (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'pr-reused'
        $T.Api.pulls.Count | Should -Be 1
    }
    It 'test_ambiguous_comment_create_cannot_retry_when_pr_status_changes' {
        $null = Invoke-BackportTestStages $T
        $route = '/repos/AleksanderGladkov/BCApps-Backport-Test/issues/101/comments'
        $T.Api.fail_post = $route
        foreach ($i in 1..2) { { Invoke-BackportTestStage $T publish } | Should -Throw }
        @($T.Api.calls | Where-Object { $_.method -ceq 'POST' -and $_.path -ceq $route }).Count | Should -Be 1
    }
    It 'test_successful_write_with_wrong_readback_is_rejected' {
        $null = Invoke-BackportTestStages $T -Last publish
        $T.Api.pulls[0].head.sha = $T.Fixture.Target
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'pr_branch_mismatch'
    }
    It 'test_api_transport_blocks_dry_writes_before_opening_connection' {
        $T.Environment.INPUT_DRY_RUN = 'true'
        Set-BackportStageConfig $T
        { & $T.OriginalHttp -Config $T.Config -Method POST -Path '/repos/AleksanderGladkov/BCApps-Backport-Test/issues' -Data @{} } |
            Should -Throw -ExpectedMessage 'dry_run_write_blocked'
        Should -Invoke -ModuleName Backport New-BackportHttpClient -Times 0 -Exactly
    }
    It 'test_git_credentials_are_scoped_in_environment_only' {
        $old = @{}
        $inherited = @{
            GH_TOKEN = 'ambient-gh-token'; GITHUB_TOKEN = 'ambient-github-token'
            GIT_CONFIG_COUNT = '1'; GIT_CONFIG_KEY_0 = 'remote.origin.url'
            GIT_CONFIG_VALUE_0 = 'https://example.invalid/unwanted.git'
        }
        try {
            foreach ($key in $inherited.Keys) { $old[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, $inherited[$key]) }
            $directory = & $T.Module { param($c) New-BackportGitWorkDirectory -Config $c } $T.Config
            $plain = & $T.OriginalGit -Config $T.Config -Directory $directory -Arguments @('status')
            foreach ($key in $inherited.Keys) { $plain.Environment.ContainsKey($key) | Should -BeFalse }
            $args = @('push', '--porcelain', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
                '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7')
            $info = & $T.OriginalGit -Config $T.Config -Directory $directory -Arguments $args -Auth
            ($info.ArgumentList -join ' ') | Should -Not -Match 'offline-fixture|ambient-'
            $info.Environment.ContainsKey('GH_TOKEN') | Should -BeFalse
            $info.Environment.ContainsKey('GITHUB_TOKEN') | Should -BeFalse
            $info.Environment['GIT_CONFIG_KEY_0'] | Should -BeExactly 'http.https://github.com/AleksanderGladkov/BCApps-Backport-Test.git.extraHeader'
            $info.Environment['GIT_CONFIG_VALUE_0'] | Should -Match '^Authorization: Basic '
            [IO.File]::ReadAllText((Join-Path $directory '.git\config')) | Should -Not -Match 'offline-fixture|ambient-|Authorization'
            & $T.Module { param($d) Remove-BackportGitWorkDirectory -Directory $d } $directory
        }
        finally { foreach ($key in $old.Keys) { [Environment]::SetEnvironmentVariable($key, $old[$key]) } }
    }
    It 'test_feedback_contains_reason_and_never_copies_source_text' {
        Set-StageConflict $T
        $T.Api.source.title = "AB#999`nmalicious title"
        $T.Api.source.body = 'arbitrary body'
        $null = Invoke-BackportTestStages $T -Last publish
        $T.Api.comments.Count | Should -Be 2
        foreach ($items in $T.Api.comments.Values) {
            $items[0].body | Should -Match 'cherry_pick_conflict'
            $items[0].body | Should -Not -Match 'AB#|malicious|arbitrary body'
        }
    }
    It 'test_new_attempt_reconciles_existing_issue_from_old_artifact' {
        $null = Invoke-BackportTestStages $T -Last track
        $T.Environment.GITHUB_RUN_ATTEMPT = '2'
        Set-BackportStageConfig $T
        Remove-Item -LiteralPath (Join-Path $T.Config.state_dir 'plan.json')
        $null = Invoke-BackportTestStage $T validate
        (Invoke-BackportTestStage $T track).issue_number | Should -Be 101
        (Get-StageJson $T 'tracking.json').run_attempt | Should -BeExactly '2'
    }
    It 'test_run_scoped_ambiguity_cannot_be_erased_by_prepare' {
        $null = Invoke-BackportTestStages $T
        $route = '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls'
        $T.Api.fail_post = $route
        { Invoke-BackportTestStage $T publish } | Should -Throw
        $journal = [IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'publication.json'))
        $null = Invoke-BackportTestStage $T prepare
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'publication.json'))) |
            Should -BeExactly ([Convert]::ToHexString($journal))
        { Invoke-BackportTestStage $T publish } | Should -Throw
        @($T.Api.calls | Where-Object { $_.method -ceq 'POST' -and $_.path -ceq $route }).Count | Should -Be 1
    }
    It 'test_forged_patch_with_matching_artifact_digest_is_still_rejected' {
        $null = Invoke-BackportTestStages $T
        $forged = [Text.Encoding]::UTF8.GetBytes('untrusted replacement content')
        [IO.File]::WriteAllBytes((Join-Path $T.Config.state_dir 'patch.bin'), $forged)
        Edit-StageJson $T 'result.json' { param($x) $x.patch_sha256 = Get-StageHash $forged }
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'recomputed_result_mismatch'
        Assert-StageNoPublication $T
    }
    It 'test_plan_file_list_cannot_be_expanded_even_with_matching_hashes' {
        $null = Invoke-BackportTestStages $T
        Edit-StageJson $T 'plan.json' { param($x) $x.files += 'src/evil.al' }
        $hash = Get-StagePlanHash $T
        foreach ($name in @('tracking.json', 'result.json')) {
            Edit-StageJson $T $name { param($x) $x.plan_hash = $hash }
        }
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'plan_files_mismatch'
        Assert-StageNoPublication $T
    }
    It 'test_missing_target_branch_and_wrong_api_repository_fail_readonly' {
        $T.HttpFilter = {
            param($t, $method, $path, $data)
            if ($path.Contains('/branches/')) { throw 'api_read_failed' }
            Invoke-FakeGitHub $t.Api $method $path $data
        }
        { Invoke-BackportTestStage $T validate } | Should -Throw -ExpectedMessage 'api_read_failed'
        $T.HttpFilter = $null
        $T.Api.repo.id = 1
        { Invoke-BackportTestStage $T validate } | Should -Throw -ExpectedMessage 'repository_mismatch'
        @($T.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
    }
    It 'test_cli_rejects_inputs_without_echoing_untrusted_values' {
        $environment = Copy-BackportTestValue $T.Environment
        $environment.INPUT_SOURCE_PR = "7`nSECRET"
        $result = Invoke-HarnessProcess -FileName (Get-Process -Id $PID).Path -Environment $environment `
            -Arguments @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Invoke-Backport.ps1'), '-Stage', 'validate')
        $result.ExitCode | Should -Be 1
        ($result.Stdout + $result.Stderr) | Should -Not -Match 'SECRET'
        ($result.Stdout + $result.Stderr) | Should -Match 'invalid_number'
    }
    It 'preserves exact two-file effects with a smaller legitimate release delta' -Tag 'TEST-021' {
        Set-StageTwoFileSource $T
        $oracle = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $T.Module -Template $T
        try {
            Copy-StageFixtureRefs $T $oracle
            $python = Invoke-PythonStageHandoff $oracle @('validate', 'track', 'prepare', 'publish')
            $python.outcomes[-1].status | Should -BeExactly 'pr-created'
            Assert-StageTwoFileTree $oracle 'backport/29.x/pr-7'
            (Invoke-StageFixtureGit $oracle @('diff', '--name-only', $oracle.Fixture.Target, 'backport/29.x/pr-7')) | Should -BeExactly 'src/two.al'
            (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'pr-created'
            Assert-StageTwoFileTree $T 'backport/29.x/pr-7'
            (Invoke-StageFixtureGit $T @('diff', '--name-only', $T.Fixture.Target, 'backport/29.x/pr-7')) | Should -BeExactly 'src/two.al'
            (Get-StageJson $T 'result.json').tree_sha | Should -BeExactly (Get-StageJson $oracle 'result.json').tree_sha
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'patch.bin'))) |
                Should -BeExactly ([Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $oracle.Config.state_dir 'patch.bin'))))
        }
        finally { Remove-LocalGitFixture $oracle.Fixture }
    }
    It 'proves both preexisting effects without creating a branch or PR' -Tag 'TEST-021' {
        Set-StageTwoFileSource $T -BothPresent
        $oracle = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $T.Module -Template $T
        try {
            Copy-StageFixtureRefs $T $oracle
            $python = Invoke-PythonStageHandoff $oracle @('validate', 'track', 'prepare', 'publish')
            $python.outcomes[-1].status | Should -BeExactly 'already_applied'
            Assert-StageTwoFileTree $oracle $oracle.Fixture.Target
            Assert-StageNoPublication $oracle
            $result = Invoke-BackportTestStages $T -Last publish
            $result.status | Should -BeExactly 'already_applied'
            $result.reason | Should -BeExactly $python.outcomes[-1].reason
            Assert-StageTwoFileTree $T $T.Fixture.Target
            Assert-StageNoPublication $T
            (Get-StageJson $T 'result.json').published | Should -BeFalse
        }
        finally { Remove-LocalGitFixture $oracle.Fixture }
    }
    It 'rejects a rehashed <Kind> source effect by independent reconstruction' -Tag 'TEST-021' -ForEach @(
        @{ Kind = 'missing' }, @{ Kind = 'extra' }
    ) {
        Set-StageTwoFileSource $T
        $oracle = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $T.Module -Template $T
        try {
            Copy-StageFixtureRefs $T $oracle
            $null = Invoke-PythonStageHandoff $oracle @('validate', 'track', 'prepare')
            Set-StageForgedEffect $oracle $Kind
            $python = Invoke-PythonStageHandoff $oracle @('publish') -CaptureFailure
            $python.failure | Should -BeExactly 'recomputed_result_mismatch'
            Assert-StageNoPublication $oracle
            $null = Invoke-BackportTestStages $T
            Set-StageForgedEffect $T $Kind
            $result = Get-StageJson $T 'result.json'
            $result.patch_sha256 | Should -BeExactly (Get-StageHash ([IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'patch.bin'))))
            { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'recomputed_result_mismatch'
            Assert-StageNoPublication $T
        }
        finally { Remove-LocalGitFixture $oracle.Fixture }
    }
    It 'isolates every stage from a dirty unrelated caller and cleans only owned checkouts' -Tag 'TEST-022' {
        $caller = New-LocalGitWorkingCopy $T.Fixture
        $null = Invoke-LocalGit $T.Fixture $caller @('checkout', '-b', 'unrelated-caller', $T.Fixture.Target)
        $tracked = Join-Path $caller 'src\one.al'
        $untracked = Join-Path $caller 'keep.txt'
        [IO.File]::WriteAllBytes($tracked, [byte[]]@(0, 255, 13, 10, 42))
        [IO.File]::WriteAllBytes($untracked, [byte[]]@(1, 2, 3, 128, 13, 10))
        $sentinel = Join-Path $T.Config.work_dir 'not-owned'
        $null = [IO.Directory]::CreateDirectory($sentinel)
        [IO.File]::WriteAllText((Join-Path $sentinel 'keep'), 'must survive')
        $head = Invoke-LocalGit $T.Fixture $caller @('rev-parse', 'HEAD')
        $status = Invoke-LocalGit $T.Fixture $caller @('status', '--porcelain=v1')
        $trackedBytes = [Convert]::ToHexString([IO.File]::ReadAllBytes($tracked))
        $untrackedBytes = [Convert]::ToHexString([IO.File]::ReadAllBytes($untracked))
        Push-Location $caller
        try {
            foreach ($stage in @('validate', 'track', 'prepare', 'publish')) {
                $null = Invoke-BackportTestStage $T $stage
                (Invoke-LocalGit $T.Fixture $caller @('branch', '--show-current')) | Should -BeExactly 'unrelated-caller'
                (Invoke-LocalGit $T.Fixture $caller @('rev-parse', 'HEAD')) | Should -BeExactly $head
                (Invoke-LocalGit $T.Fixture $caller @('status', '--porcelain=v1')) | Should -BeExactly $status
                [Convert]::ToHexString([IO.File]::ReadAllBytes($tracked)) | Should -BeExactly $trackedBytes
                [Convert]::ToHexString([IO.File]::ReadAllBytes($untracked)) | Should -BeExactly $untrackedBytes
                [IO.File]::ReadAllText((Join-Path $sentinel 'keep')) | Should -BeExactly 'must survive'
                @(Get-ChildItem -LiteralPath $T.Config.work_dir -Directory | Where-Object Name -NE 'not-owned').Count | Should -Be 0
            }
        }
        finally { Pop-Location }
    }
    It 'represents a regular AL rename as add and delete without disturbing release files' -Tag 'TEST-022' {
        $null = Invoke-StageFixtureGit $T @('switch', 'feature')
        Move-Item -LiteralPath (Join-Path $T.Fixture.Origin 'src\one.al') -Destination (Join-Path $T.Fixture.Origin 'src\renamed.al')
        $null = Invoke-StageFixtureGit $T @('add', '-A')
        $null = Invoke-StageFixtureGit $T @('commit', '-m', 'regular AL rename')
        Update-StageSource $T -ChangedFiles 2
        $null = Invoke-StageFixtureGit $T @('switch', 'releases/29.x')
        Set-StageFixtureText $T 'src\release.al' "release-only`r`n"
        $null = Invoke-StageFixtureGit $T @('add', '.')
        $null = Invoke-StageFixtureGit $T @('commit', '-m', 'release-only file')
        $T.Api.target = Invoke-StageFixtureGit $T @('rev-parse', 'HEAD')
        $release = Get-StageGitBytes $T $T.Fixture.Origin @('show', "$($T.Api.target):src/release.al")
        $null = Invoke-StageFixtureGit $T @('switch', 'main')
        (Invoke-BackportTestStages $T -Last publish).status | Should -BeExactly 'pr-created'
        $plan = Get-StageJson $T
        $plan.files | Should -Be @('src/one.al', 'src/renamed.al')
        (Invoke-StageFixtureGit $T @('ls-tree', '--name-only', 'backport/29.x/pr-7', 'src/one.al')) | Should -BeExactly ''
        [Convert]::ToHexString((Get-StageGitBytes $T $T.Fixture.Origin @('show', 'backport/29.x/pr-7:src/renamed.al'))) |
            Should -BeExactly ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes("ONE`ntwo`nthree`n")))
        [Convert]::ToHexString((Get-StageGitBytes $T $T.Fixture.Origin @('show', 'backport/29.x/pr-7:src/release.al'))) |
            Should -BeExactly ([Convert]::ToHexString($release))
        $patch = [IO.File]::ReadAllText((Join-Path $T.Config.state_dir 'patch.bin'))
        $patch | Should -Match 'deleted file mode 100644'
        $patch | Should -Match 'new file mode 100644'
        $patch | Should -Not -Match 'rename from|rename to|similarity index'
    }
    It 'retains exact job-local conflict handoff without invoking a model or resolver' -Tag 'TEST-023' {
        Mock -ModuleName Backport Start-Process { throw 'model_or_resolver_forbidden' }
        Mock -ModuleName Backport Invoke-Expression { throw 'model_or_resolver_forbidden' }
        Set-StageConflict $T
        $result = Invoke-BackportTestStages $T
        $result.status | Should -BeExactly 'needs-attention'
        $result.reason | Should -BeExactly 'cherry_pick_conflict'
        $result.published | Should -BeFalse
        $conflict = Get-StageJson $T 'conflict.json'
        @($conflict.Keys | Sort-Object) | Should -Be @('files', 'repo', 'source_pr', 'source_sha', 'target_base_sha', 'worktree')
        $conflict.repo | Should -BeExactly $T.Environment.GITHUB_REPOSITORY
        $conflict.source_pr | Should -Be 7
        $conflict.source_sha | Should -BeExactly $T.Fixture.Source
        $conflict.target_base_sha | Should -BeExactly $T.Api.target
        $conflict.files.Count | Should -Be 1
        @($conflict.files[0].Keys | Sort-Object) | Should -Be @('absolute_path', 'relative_path')
        $conflict.files[0].relative_path | Should -BeExactly 'src/one.al'
        $conflict.files[0].absolute_path | Should -BeExactly (Join-Path $conflict.worktree 'src\one.al')
        $conflict.worktree.StartsWith($T.Config.work_dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $conflict.worktree '.git\CHERRY_PICK_HEAD') | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($conflict.files[0].absolute_path)
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Match '<<<<<<<|=======|>>>>>>>'
        (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'needs-attention'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($conflict.files[0].absolute_path)) | Should -BeExactly ([Convert]::ToHexString($bytes))
        Assert-StageNoPublication $T
        $T.Pushes.Count | Should -Be 0
        Should -Invoke -ModuleName Backport Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName Backport Invoke-Expression -Times 0 -Exactly
    }
    It 'rejects foreign skill-shaped and forged resolved action results' -Tag 'TEST-023' {
        Set-StageConflict $T
        $null = Invoke-BackportTestStages $T
        $original = Get-StageJson $T 'result.json'
        Set-StageJson $T 'result.json' @{
            schema = 'hotfix-conflict/v1'; repoRoot = $T.Config.work_dir
            status = 'resolved'; files = @('src/one.al'); published = $false
        }
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'invalid_artifact_schema'
        $original.status = 'resolved'
        Set-StageJson $T 'result.json' $original
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'unsupported_result'
        Assert-StageNoPublication $T
    }
    It 'requires fresh and reused PR readback for <Field>' -Tag 'TEST-024' -ForEach @(
        @{ Field = 'repository' }, @{ Field = 'head_repository_name' }
        @{ Field = 'base_repository_id' }, @{ Field = 'base_repository_name' }
        @{ Field = 'source_branch' }, @{ Field = 'target' }
        @{ Field = 'head' }, @{ Field = 'body' }, @{ Field = 'unavailable' }
    ) {
        $T.Environment.GITHUB_OUTPUT = Join-Path $T.Fixture.Root 'outputs'
        Set-BackportStageConfig $T
        $null = Invoke-BackportTestStages $T
        $originalResult = [IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'result.json'))
        $T.HttpFilter = {
            param($t, $method, $path, $data)
            $value = Invoke-FakeGitHub $t.Api $method $path $data
            if ($method -ceq 'GET' -and $path.EndsWith('/pulls/102')) {
                switch ($Field) {
                    repository { $value.head.repo.id = 1 }
                    head_repository_name { $value.head.repo.full_name = 'other/repository' }
                    base_repository_id { $value.base.repo.id = 1 }
                    base_repository_name { $value.base.repo.full_name = 'other/repository' }
                    source_branch { $value.head.ref = 'other' }
                    target { $value.base.ref = 'main' }
                    head { $value.head.sha = $t.Fixture.Target }
                    body { $value.body += "`nforged" }
                    unavailable { throw 'api_read_failed' }
                }
            }
            return ,$value
        }
        { Invoke-BackportTestStage $T publish } | Should -Throw
        $T.Api.pulls.Count | Should -Be 1
        @($T.Api.calls | Where-Object { $_.method -ceq 'GET' -and $_.path.EndsWith('/pulls/102') }).Count | Should -Be 1
        [IO.File]::ReadAllText($T.Config.output) | Should -Not -Match 'status=pr-created|status=pr-reused|pr_url='
        $journal = Get-StageJson $T 'publication.json'
        $journal.attempted | Should -Contain 'push'
        $journal.attempted | Should -Contain 'pr'
        { Invoke-BackportTestStage $T publish } | Should -Throw
        @($T.Api.calls | Where-Object { $_.method -ceq 'POST' -and $_.path.EndsWith('/pulls') }).Count | Should -Be 1
        $T.HttpFilter = $null
        $null = $T.Api.stale_paths.Add('/repos/AleksanderGladkov/BCApps-Backport-Test/pulls')
        { Invoke-BackportTestStage $T publish } | Should -Throw -ExpectedMessage 'pr_create_ambiguous'
        $T.Api.stale_paths.Clear()
        (Invoke-BackportTestStage $T publish).status | Should -BeExactly 'pr-reused'
        $T.Api.pulls[0].number | Should -Be 102
        $T.Api.pulls[0].id | Should -Be 1002
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $T.Config.state_dir 'result.json'))) |
            Should -BeExactly ([Convert]::ToHexString($originalResult))
        (Get-StageJson $T 'result.json').published | Should -BeFalse
        (Get-StageJson $T 'publication.json').attempted | Should -Contain 'pr'
    }
    It 'hands complete stages across Python and PowerShell in both directions with identical bindings' -Tag 'TEST-018' {
        $pythonFirst = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $T.Module -Template $T
        $powershellFirst = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $T.Module -Template $T
        try {
            foreach ($other in @($pythonFirst, $powershellFirst)) { Copy-StageFixtureRefs $T $other }
            foreach ($test in @($T, $pythonFirst, $powershellFirst)) {
                $test.Environment.GITHUB_OUTPUT = Join-Path $test.Fixture.Root 'outputs'
                $test.Environment.GITHUB_STEP_SUMMARY = Join-Path $test.Fixture.Root 'summary'
                Set-BackportStageConfig $test
            }
            $expected = Get-StageReceipt $T (Invoke-BackportTestStages $T -Last publish)
            $python = Invoke-PythonStageHandoff $pythonFirst @('validate', 'track', 'prepare')
            $python.outcomes[-1].status | Should -BeExactly 'applied'
            $fromPython = Get-StageReceipt $pythonFirst (Invoke-BackportTestStage $pythonFirst publish)
            $null = Invoke-BackportTestStages $powershellFirst
            $python = Invoke-PythonStageHandoff $powershellFirst @('publish')
            $fromPowerShell = Get-StageReceipt $powershellFirst $python.outcomes[-1]
            foreach ($receipt in @($fromPython, $fromPowerShell)) {
                @($receipt.git_effects | Where-Object { $_.arguments[0] -ceq 'push' }).Count | Should -Be 1
                foreach ($key in @('outcome', 'artifacts', 'calls', 'issues', 'pulls', 'comments', 'git_effects')) {
                    $actualBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $receipt[$key])
                    $expectedBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $expected[$key])
                    [Convert]::ToHexString($actualBytes) | Should -BeExactly ([Convert]::ToHexString($expectedBytes)) -Because "handoff $key"
                }
                $receipt.output | Should -BeExactly $expected.output
                $receipt.summary | Should -BeExactly $expected.summary
                $receipt.refs | Should -BeExactly $expected.refs
            }
            $head = Invoke-StageFixtureGit $pythonFirst @('rev-parse', 'backport/29.x/pr-7')
            $expectedReuse = Get-StageReceipt $T (Invoke-BackportTestStage $T publish)
            $fromPythonReuse = Get-StageReceipt $pythonFirst (Invoke-PythonStageHandoff $pythonFirst @('publish')).outcomes[-1]
            $fromPowerShellReuse = Get-StageReceipt $powershellFirst (Invoke-BackportTestStage $powershellFirst publish)
            foreach ($receipt in @($fromPythonReuse, $fromPowerShellReuse)) {
                $receipt.outcome.status | Should -BeExactly 'pr-reused'
                @($receipt.git_effects | Where-Object { $_.arguments[0] -ceq 'push' }).Count | Should -Be 1
                foreach ($key in @('outcome', 'artifacts', 'calls', 'issues', 'pulls', 'comments', 'git_effects')) {
                    $actualBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $receipt[$key])
                    $expectedBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $expectedReuse[$key])
                    [Convert]::ToHexString($actualBytes) | Should -BeExactly ([Convert]::ToHexString($expectedBytes)) -Because "reuse $key"
                }
                $receipt.output | Should -BeExactly $expectedReuse.output
                $receipt.summary | Should -BeExactly $expectedReuse.summary
                $receipt.refs | Should -BeExactly $expectedReuse.refs
            }
            foreach ($test in @($pythonFirst, $powershellFirst)) {
                $test.Api.pulls.Count | Should -Be 1
                $test.Api.issues.Count | Should -Be 1
                (Invoke-StageFixtureGit $test @('rev-parse', 'backport/29.x/pr-7')) | Should -BeExactly $head
            }
            foreach ($binding in @(
                @{ Run = '123'; Attempt = '2' }, @{ Run = '124'; Attempt = '1' }
            )) {
                foreach ($test in @($pythonFirst, $powershellFirst)) {
                    $test.Environment.GITHUB_RUN_ID = $binding.Run
                    $test.Environment.GITHUB_RUN_ATTEMPT = $binding.Attempt
                    Set-BackportStageConfig $test
                    $test.Api.calls.Clear()
                    $test.GitEffects.Clear()
                }
                { Invoke-BackportTestStage $pythonFirst publish } | Should -Throw -ExpectedMessage 'artifact_context_mismatch'
                (Invoke-PythonStageHandoff $powershellFirst @('publish') -CaptureFailure).failure | Should -BeExactly 'artifact_context_mismatch'
                foreach ($test in @($pythonFirst, $powershellFirst)) {
                    $test.Api.calls.Count | Should -Be 0
                    $test.GitEffects.Count | Should -Be 0
                    (Invoke-StageFixtureGit $test @('rev-parse', 'backport/29.x/pr-7')) | Should -BeExactly $head
                }
            }
        }
        finally {
            Remove-LocalGitFixture $pythonFirst.Fixture
            Remove-LocalGitFixture $powershellFirst.Fixture
        }
    }
    It 'matches cross-language reason and effect traces for <Reason>' -Tag 'TEST-018' -ForEach @(
        @{ Reason = 'target_advanced' }, @{ Reason = 'recomputed_result_mismatch' }
    ) {
        $powershellFirst = New-BackportStageTest -ParentPath $script:HarnessRoot -Module $T.Module -Template $T
        try {
            Copy-StageFixtureRefs $T $powershellFirst
            foreach ($test in @($T, $powershellFirst)) {
                $test.Environment.GITHUB_OUTPUT = Join-Path $test.Fixture.Root 'outputs'
                $test.Environment.GITHUB_STEP_SUMMARY = Join-Path $test.Fixture.Root 'summary'
                Set-BackportStageConfig $test
            }
            $null = Invoke-PythonStageHandoff $T @('validate', 'track', 'prepare')
            $null = Invoke-BackportTestStages $powershellFirst
            foreach ($test in @($T, $powershellFirst)) {
                if ($Reason -ceq 'target_advanced') { $test.Api.target = 'a' * 40 }
                else {
                    $forged = [Text.Encoding]::UTF8.GetBytes('rehashed but unapproved patch')
                    [IO.File]::WriteAllBytes((Join-Path $test.Config.state_dir 'patch.bin'), $forged)
                    $result = Get-StageJson $test 'result.json'
                    $result.patch_sha256 = Get-StageHash $forged
                    Set-StageJson $test 'result.json' $result
                }
            }
            $python = Invoke-PythonStageHandoff $powershellFirst @('publish') -CaptureFailure
            if ($Reason -ceq 'target_advanced') {
                $python.failure | Should -BeNullOrEmpty
                $python.outcomes[-1].status | Should -BeExactly 'needs-attention'
                $python.outcomes[-1].reason | Should -BeExactly $Reason
                $expectedOutcome = $python.outcomes[-1]
                $actualOutcome = Invoke-BackportTestStage $T publish
            }
            else {
                $python.failure | Should -BeExactly $Reason
                $expectedOutcome = @{ failure = $python.failure }
                try {
                    $null = Invoke-BackportTestStage $T publish
                    throw 'expected_failure_not_raised'
                }
                catch {
                    $_.Exception.Message | Should -BeExactly $Reason
                    $actualOutcome = @{ failure = $_.Exception.Message }
                }
            }
            $expected = Get-StageReceipt $powershellFirst $expectedOutcome
            $actual = Get-StageReceipt $T $actualOutcome
            foreach ($key in @('outcome', 'artifacts', 'calls', 'issues', 'pulls', 'comments', 'git_effects')) {
                $actualBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $actual[$key])
                $expectedBytes = & $T.Module { param($v) ConvertTo-BackportJsonBytes $v } (Copy-BackportTestValue $expected[$key])
                [Convert]::ToHexString($actualBytes) | Should -BeExactly ([Convert]::ToHexString($expectedBytes)) -Because "$Reason $key"
            }
            $actual.output | Should -BeExactly $expected.output
            $actual.summary | Should -BeExactly $expected.summary
            $actual.refs | Should -BeExactly $expected.refs
            foreach ($test in @($T, $powershellFirst)) {
                Assert-StageNoPublication $test
                @($test.GitEffects | Where-Object { $_.arguments[0] -ceq 'push' }).Count | Should -Be 0
                (Get-StageJson $test 'result.json').published | Should -BeFalse
            }
        }
        finally { Remove-LocalGitFixture $powershellFirst.Fixture }
    }
}

Describe 'Offline workflow baseline and EPIC-003 runner selection' -Tag 'EPIC-003' {
    BeforeAll {
        if (-not $env:BACKPORT_TEST_BASELINE_DIR) { throw 'BACKPORT_TEST_BASELINE_DIR must select the pinned read-only Python oracle.' }
        $github = [IO.Directory]::GetParent([IO.Directory]::GetParent($env:BACKPORT_TEST_BASELINE_DIR).FullName).FullName
        $script:WorkflowTexts = @{
            production = [IO.File]::ReadAllText((Join-Path $github 'workflows\backport-demo.yml')).Replace("`r`n", "`n")
            tests = [IO.File]::ReadAllText((Join-Path $github 'workflows\backport-demo-tests.yml')).Replace("`r`n", "`n")
        }
    }
    It 'selects only EPIC-003 through the real runner without promoting development to acceptance' {
        $script:CapturedStageConfiguration = $null
        Mock Invoke-Pester {
            $script:CapturedStageConfiguration = $Configuration
            $result = New-SyntheticDevelopmentResult
            $result.Tests[0].Tag = @('EPIC-003')
            $result
        }
        Mock Import-Module {} -ParameterFilter { $Name -ceq 'Pester' -and $RequiredVersion -eq '5.7.1' }
        Mock Write-Host {}
        $path = Join-Path $script:HarnessRoot 'epic003-selection.xml'
        $gate = Invoke-BackportTests -Epic EPIC-003 -ResultPath $path
        $gate.ExitCode | Should -Be 0
        $gate.Mode | Should -BeExactly 'Development'
        $gate.Message | Should -BeExactly 'Development EPIC-003 - NOT full acceptance.'
        @($script:CapturedStageConfiguration.Filter.Tag.Value) | Should -Be @('EPIC-003')
        @($script:CapturedStageConfiguration.Filter.FullName.Value).Count | Should -Be 0
        $script:CapturedStageConfiguration.TestResult.OutputPath.Value | Should -BeExactly $path
        $script:CapturedStageConfiguration.TestDrive.Enabled.Value | Should -BeFalse
        Should -Invoke Invoke-Pester -Times 1 -Exactly
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter {
            $Name -ceq 'Pester' -and $RequiredVersion -eq '5.7.1'
        }
    }
    It 'verifies the pinned checked-out workflow bytes with LF and CRLF checkouts' -Tag 'TEST-017' {
        foreach ($newline in @("`n", "`r`n")) {
            Assert-BackportWorkflowBaseline -Parity $script:Reference `
                -ProductionText $script:WorkflowTexts.production.Replace("`n", $newline) `
                -TestsText $script:WorkflowTexts.tests.Replace("`n", $newline)
        }
    }
    It 'accepts the exact planned PowerShell cutover and rejects weakened matrix or runtime contracts' -Tag 'TEST-017' {
        $pythonSetup = @(
            '      - uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5'
            '        with:'
            '          python-version: ''3.13'''
        ) -join "`n"
        $runtimeSetup = @(
            '      - name: Check PowerShell runtime'
            '        run: |'
            '          if ($PSVersionTable.PSVersion -lt [version]''7.4'' -or [Environment]::Version -lt [version]''8.0'') {'
            '            throw ''PowerShell 7.4+ and .NET 8+ are required.'''
            '          }'
        ) -join "`n"
        $production = $script:WorkflowTexts.production.Replace($pythonSetup, $runtimeSetup).
            Replace("  PYTHONDONTWRITEBYTECODE: '1'`n", '').Replace('shell: bash', 'shell: pwsh')
        foreach ($stage in @('validate', 'track', 'prepare', 'publish')) {
            $production = $production.Replace("python .github/scripts/backport-demo/controller.py $stage",
                "./.github/scripts/backport-demo/Invoke-Backport.ps1 -Stage $stage")
        }
        $tests = @(
            'name: Backport executor tests'
            ''
            'on:'
            '  workflow_dispatch:'
            ''
            'permissions:'
            '  contents: read'
            ''
            'jobs:'
            '  test:'
            '    if: github.repository == ''AleksanderGladkov/BCApps-Backport-Test'''
            '    strategy:'
            '      fail-fast: false'
            '      matrix:'
            '        os: [ubuntu-latest, windows-latest]'
            '    runs-on: ${{ matrix.os }}'
            '    timeout-minutes: 30'
            '    defaults:'
            '      run:'
            '        shell: pwsh'
            '    env:'
            '      PYTHONDONTWRITEBYTECODE: ''1'''
            '    steps:'
            '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4'
            '        with:'
            '          ref: ${{ github.sha }}'
            '          persist-credentials: false'
            '          sparse-checkout: |'
            '            .github/scripts/backport-demo'
            '            .github/workflows/backport-demo.yml'
            '            .github/workflows/backport-demo-tests.yml'
            '          sparse-checkout-cone-mode: false'
            '      - uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5'
            '        with:'
            '          python-version: ''3.13'''
            '      - name: Check runtimes and provision pinned test dependency'
            '        id: setup'
            '        run: |'
            '          if ($PSVersionTable.PSVersion -lt [version]''7.4'' -or [Environment]::Version -lt [version]''8.0'') {'
            '            throw ''PowerShell 7.4+ and .NET 8+ are required.'''
            '          }'
            '          if (-not (Get-Module -ListAvailable Pester | Where-Object Version -EQ ([version]''5.7.1''))) {'
            '            Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop'
            '          }'
            '          Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop'
            '          Write-Host ("PowerShell {0}; .NET {1}; Pester {2}" -f $PSVersionTable.PSVersion, [Environment]::Version, (Get-Module Pester).Version)'
            '          git --version'
            '          if ($LASTEXITCODE -ne 0) { throw ''Git version check failed.'' }'
            '          python -B -c "import sys, unicodedata; assert sys.version_info[:2] == (3, 13); assert unicodedata.unidata_version == ''15.1.0''; print(sys.version); print(''Unicode'', unicodedata.unidata_version)"'
            '          if ($LASTEXITCODE -ne 0) { throw ''Python reference runtime check failed.'' }'
            '      - name: Test unchanged Python reference offline'
            '        run: |'
            '          python -B -m unittest discover -s .github/scripts/backport-demo -p ''test_*.py'' -v'
            '          if ($LASTEXITCODE -ne 0) { throw ''Python reference suite failed.'' }'
            '      - name: Run full PowerShell parity gate offline'
            '        if: ${{ !cancelled() && steps.setup.outcome == ''success'' }}'
            '        run: |'
            '          $env:BACKPORT_TEST_BASELINE_DIR = Join-Path $env:GITHUB_WORKSPACE ''.github/scripts/backport-demo'''
            '          & ./.github/scripts/backport-demo/Run-Tests.ps1 -ResultPath (Join-Path $env:RUNNER_TEMP ''backport-pester.xml'')'
            '      - name: Preserve test results'
            '        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4'
            '        if: always()'
            '        with:'
            '          name: backport-tests-${{ matrix.os }}-${{ github.run_attempt }}'
            '          path: ${{ runner.temp }}/backport-pester.xml'
            '          if-no-files-found: error'
            '          retention-days: 7'
            ''
        ) -join "`n"
        ([regex]::Matches($production, [regex]::Escape($runtimeSetup))).Count | Should -Be 4
        $production | Should -Not -Match 'setup-python|controller\.py|PYTHONDONTWRITEBYTECODE'
        $baselineProduction = $production.Replace($runtimeSetup, $pythonSetup).Replace('shell: pwsh', 'shell: bash').
            Replace("`ndefaults:", "  PYTHONDONTWRITEBYTECODE: '1'`n`ndefaults:")
        foreach ($stage in @('validate', 'track', 'prepare', 'publish')) {
            $baselineProduction = $baselineProduction.Replace("./.github/scripts/backport-demo/Invoke-Backport.ps1 -Stage $stage",
                "python .github/scripts/backport-demo/controller.py $stage")
        }
        $baselineTests = @(
            'name: Backport executor tests'
            ''
            'on:'
            '  workflow_dispatch:'
            ''
            'permissions:'
            '  contents: read'
            ''
            'jobs:'
            '  test:'
            '    if: github.repository == ''AleksanderGladkov/BCApps-Backport-Test'''
            '    runs-on: ubuntu-latest'
            '    timeout-minutes: 15'
            '    steps:'
            $script:Reference.workflow_baseline.tests.protected_blocks[-1].TrimEnd("`n")
            $pythonSetup
            '      - name: Test offline with fake GitHub responses and temporary Git repos'
            '        env:'
            '          PYTHONDONTWRITEBYTECODE: ''1'''
            '        run: python -m unittest discover -s .github/scripts/backport-demo -p ''test_*.py'' -v'
            ''
        ) -join "`n"
        foreach ($newline in @("`n", "`r`n")) {
            Assert-BackportWorkflowBaseline -Parity $script:Reference `
                -ProductionText $production.Replace("`n", $newline) -TestsText $tests.Replace("`n", $newline)
            Assert-BackportWorkflowBaseline -Parity $script:Reference `
                -ProductionText $baselineProduction.Replace("`n", $newline) -TestsText $baselineTests.Replace("`n", $newline)
        }
        foreach ($mutation in @(
            @{ production = $production.Replace('shell: pwsh', 'shell: bash'); tests = $tests },
            @{ production = $production.Replace("[version]'7.4'", "[version]'7.0'"); tests = $tests },
            @{ production = $production; tests = $tests.Replace('contents: read', 'contents: write') },
            @{ production = $production; tests = $tests.Replace('os: [ubuntu-latest, windows-latest]', 'os: [ubuntu-latest]') },
            @{ production = $production; tests = $tests.Replace('fail-fast: false', 'fail-fast: true') },
            @{ production = $production; tests = $tests.Replace('python -B -m unittest discover', 'echo skipped') }
        )) {
            { Assert-BackportWorkflowBaseline -Parity $script:Reference `
                -ProductionText $mutation.production -TestsText $mutation.tests } |
                Should -Throw -ExpectedMessage 'workflow_baseline_mismatch'
        }
    }
    It 'rejects changes to every protected production and manual read-only test block' -Tag 'TEST-017' {
        foreach ($kind in @('production', 'tests')) {
            foreach ($block in $script:Reference.workflow_baseline[$kind].protected_blocks) {
                $texts = Copy-BackportTestValue $script:WorkflowTexts
                $protected = $block
                if ($kind -ceq 'tests' -and -not $texts[$kind].Contains($block, [StringComparison]::Ordinal)) {
                    $checkout = @(
                        '          sparse-checkout: |'
                        '            .github/scripts/backport-demo'
                        '            .github/workflows/backport-demo.yml'
                        '            .github/workflows/backport-demo-tests.yml'
                        '          sparse-checkout-cone-mode: false'
                        ''
                    ) -join "`n"
                    $protected = $block.Replace("          sparse-checkout: .github/scripts/backport-demo`n", $checkout)
                }
                $texts[$kind].Contains($protected, [StringComparison]::Ordinal) | Should -BeTrue
                $texts[$kind] = $texts[$kind].Replace($protected, '')
                { Assert-BackportWorkflowBaseline -Parity $script:Reference `
                    -ProductionText $texts.production -TestsText $texts.tests } |
                    Should -Throw -ExpectedMessage 'workflow_baseline_mismatch'
            }
        }
    }
    It 'rejects changed identity and incomplete or diluted protected-block reference data' -Tag 'TEST-017' {
        foreach ($kind in @('production', 'tests')) {
            foreach ($mutation in @('path', 'hash', 'missing', 'duplicate', 'diluted')) {
                $reference = Copy-BackportTestValue $script:Reference
                $entry = $reference.workflow_baseline[$kind]
                switch ($mutation) {
                    path { $entry.path = '.github/workflows/renamed.yml' }
                    hash { $entry.sha256_lf = '0' * 64 }
                    missing { $entry.protected_blocks = @($entry.protected_blocks | Select-Object -Skip 1) }
                    duplicate { $entry.protected_blocks[0] = $entry.protected_blocks[1] }
                    diluted { $entry.protected_blocks[0] = 'name:' }
                }
                { Assert-BackportWorkflowBaseline -Parity $reference `
                    -ProductionText $script:WorkflowTexts.production -TestsText $script:WorkflowTexts.tests } |
                    Should -Throw -ExpectedMessage 'workflow_baseline_mismatch' -Because "$kind/$mutation must retain the exact baseline contract"
            }
        }
    }
}

Describe 'Configuration and safe CLI compatibility' -Tag 'EPIC-002', 'TEST-020' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force
        $script:Core = Get-Module Backport
        function New-CoreEnvironment {
            @{
                GITHUB_REPOSITORY = 'AleksanderGladkov/BCApps-Backport-Test'
                GITHUB_REPOSITORY_ID = '1369849596'; GITHUB_REF = 'refs/heads/main'
                GITHUB_ACTOR_ID = '59250993'; GITHUB_TRIGGERING_ACTOR = 'AleksanderGladkov'
                GITHUB_RUN_ID = '123'; GITHUB_RUN_ATTEMPT = '1'
                INPUT_SOURCE_PR = '7'; INPUT_DRY_RUN = 'false'
                GH_TOKEN = 'synthetic-secret'; RUNNER_TEMP = $script:HarnessRoot
            }
        }
    }
    It 'imports without reading credentials or running a command' {
        @($script:Core.ExportedFunctions.Keys) | Should -Be @('Invoke-BackportCli')
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($arg in @('-NoProfile', '-Command', "Import-Module '$PSScriptRoot\Backport.psm1'")) {
            $info.ArgumentList.Add($arg)
        }
        $info.Environment['GH_TOKEN'] = "secret invalid`n"
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $out = $process.StandardOutput.ReadToEndAsync()
            $err = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0
            $out.Result | Should -BeExactly ''
            $err.Result | Should -BeExactly ''
        }
        finally { $process.Dispose() }
    }
    It 'retains strict context types and never serializes the token' {
        $envMap = New-CoreEnvironment
        $envMap.GITHUB_RUN_ID = '99999999999999999999'
        $envMap.ALLOWED_ACTOR_IDS = '59250993,99999999999999999999'
        $config = & $script:Core { param($e) New-BackportContext -Environment $e } $envMap
        $config.dry_run | Should -BeOfType bool
        $config.dry_run | Should -BeFalse
        $config.source_pr | Should -Be 7
        $config.run_id | Should -BeOfType string
        $config.allowed_actor_ids[1].ToString() | Should -BeExactly '99999999999999999999'
        $config.ContainsKey('token') | Should -BeFalse
        [Text.Encoding]::UTF8.GetString((& $script:Core { param($c) ConvertTo-BackportJsonBytes $c } $config)) |
            Should -Not -Match 'synthetic-secret|GH_TOKEN'
    }
    It 'reads credentials only through the private credential boundary' {
        InModuleScope Backport -Parameters @{ Environment = (New-CoreEnvironment) } {
            param($Environment)
            Mock Get-BackportToken { throw 'missing_or_invalid_token' }
            { New-BackportContext -Environment $Environment } |
                Should -Throw -ExpectedMessage 'missing_or_invalid_token'
            Should -Invoke Get-BackportToken -Times 1 -Exactly
        }
    }
    It 'rejects <Key> with fixed <Reason>' -ForEach @(
        @{ Key = 'GITHUB_REPOSITORY'; Value = 'aleksandergladkov/BCApps-Backport-Test'; Reason = 'wrong_repository' }
        @{ Key = 'GITHUB_REPOSITORY'; Value = "AleksanderGladkov/BCApps-Backport-Test`u{ad}"; Reason = 'wrong_repository' }
        @{ Key = 'GITHUB_REPOSITORY_ID'; Value = '01369849596'; Reason = 'wrong_repository_id' }
        @{ Key = 'GITHUB_REPOSITORY_ID'; Value = "1369849596`u{ad}"; Reason = 'wrong_repository_id' }
        @{ Key = 'GITHUB_REF'; Value = "refs/heads/main`n"; Reason = 'wrong_execution_ref' }
        @{ Key = 'GITHUB_REF'; Value = "refs/heads/main`0"; Reason = 'wrong_execution_ref' }
        @{ Key = 'INPUT_SOURCE_PR'; Value = '2147483648'; Reason = 'invalid_number' }
        @{ Key = 'INPUT_SOURCE_PR'; Value = "7`n"; Reason = 'invalid_number' }
        @{ Key = 'INPUT_SOURCE_PR'; Value = '07'; Reason = 'invalid_number' }
        @{ Key = 'GITHUB_RUN_ID'; Value = '100000000000000000000'; Reason = 'invalid_number' }
        @{ Key = 'GITHUB_RUN_ATTEMPT'; Value = '0'; Reason = 'invalid_number' }
        @{ Key = 'GITHUB_ACTOR_ID'; Value = '123'; Reason = 'actor_not_allowed' }
        @{ Key = 'ALLOWED_ACTOR_IDS'; Value = '59250993,'; Reason = 'invalid_number' }
        @{ Key = 'INPUT_DRY_RUN'; Value = 'False'; Reason = 'invalid_dry_run' }
        @{ Key = 'INPUT_DRY_RUN'; Value = "false`u{ad}"; Reason = 'invalid_dry_run' }
        @{ Key = 'INPUT_DRY_RUN'; Value = ''; Reason = 'invalid_dry_run' }
        @{ Key = 'GITHUB_TRIGGERING_ACTOR'; Value = 'bad-'; Reason = 'invalid_triggering_actor' }
        @{ Key = 'GITHUB_TRIGGERING_ACTOR'; Value = "valid`n"; Reason = 'invalid_triggering_actor' }
        @{ Key = 'GH_TOKEN'; Value = "secret`u{1c}"; Reason = 'missing_or_invalid_token' }
        @{ Key = 'GH_TOKEN'; Value = ''; Reason = 'missing_or_invalid_token' }
    ) {
        $envMap = New-CoreEnvironment
        $envMap[$Key] = $Value
        { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } | Should -Throw "*$Reason*"
    }
    It 'uses only the protected allowlist and the existing summary fallback' {
        $envMap = New-CoreEnvironment
        $envMap.INPUT_ALLOWED_ACTOR_IDS = '123'
        $envMap.GITHUB_SUMMARY = Join-Path $script:HarnessRoot 'fallback.txt'
        $config = & $script:Core { param($e) New-BackportContext -Environment $e } $envMap
        @($config.allowed_actor_ids) | Should -Be @(59250993)
        $config.summary | Should -BeExactly $envMap.GITHUB_SUMMARY
        $envMap.GITHUB_STEP_SUMMARY = ''
        (& $script:Core { param($e) New-BackportContext -Environment $e } $envMap).summary | Should -BeExactly ''
    }
    It 'distinguishes sibling prefixes from equal and nested directories' {
        $envMap = New-CoreEnvironment
        $envMap.STATE_DIR = Join-Path $script:HarnessRoot 'state'
        $envMap.WORK_DIR = Join-Path $script:HarnessRoot 'state-sibling'
        { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } | Should -Not -Throw
        foreach ($work in @($envMap.STATE_DIR, (Join-Path $envMap.STATE_DIR 'child'), $script:HarnessRoot)) {
            $envMap.WORK_DIR = $work
            { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
                Should -Throw '*overlapping_directories*'
        }
    }
    It 'rejects work containing trusted code and unsafe output locations' {
        $envMap = New-CoreEnvironment
        $envMap.WORK_DIR = $PSScriptRoot
        { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
            Should -Throw '*script_inside_work_directory*'
        $envMap = New-CoreEnvironment
        foreach ($path in @((Join-Path $PSScriptRoot 'Backport.psm1'),
            (Join-Path $PSScriptRoot 'compat.json'), (Join-Path $script:HarnessRoot 'backport-state\plan.json'),
            (Join-Path $script:HarnessRoot 'backport-work\out'), $script:HarnessRoot)) {
            $envMap.GITHUB_OUTPUT = $path
            { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
                Should -Throw '*invalid_output_path*'
        }
        $envMap.GITHUB_OUTPUT = $envMap.GITHUB_STEP_SUMMARY = Join-Path $script:HarnessRoot 'same.txt'
        { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
            Should -Throw '*invalid_output_path*'
    }
    It 'rejects missing local directories and files used as directory roots' {
        $envMap = New-CoreEnvironment
        $envMap.RUNNER_TEMP = ''
        { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
            Should -Throw '*missing_local_directories*'
        $path = Join-Path $script:HarnessRoot 'not-a-directory'
        [IO.File]::WriteAllText($path, 'unchanged')
        foreach ($name in @('STATE_DIR','WORK_DIR')) {
            $envMap = New-CoreEnvironment
            $envMap[$name] = $path
            { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
                Should -Throw '*invalid_local_path*'
        }
        [IO.File]::ReadAllText($path) | Should -BeExactly 'unchanged'
    }
    It 'rejects files used as ancestors of state work or output paths' {
        $path = Join-Path $script:HarnessRoot 'file-ancestor'
        [IO.File]::WriteAllText($path, 'unchanged')
        foreach ($key in @('STATE_DIR', 'WORK_DIR', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY')) {
            $envMap = New-CoreEnvironment
            $envMap[$key] = Join-Path $path 'child'
            $reason = if ($key -in @('STATE_DIR', 'WORK_DIR')) { 'invalid_local_path' } else { 'invalid_output_path' }
            { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
                Should -Throw -ExpectedMessage $reason
        }
        [IO.File]::ReadAllText($path) | Should -BeExactly 'unchanged'
    }
    It 'does not interpret invisible Unicode characters as dot path segments' {
        foreach ($part in @(".`u{ad}", "..`u{ad}", "folder.`u{ad}")) {
            $path = Join-Path (Join-Path $script:HarnessRoot $part) 'state'
            (& $script:Core { param($p) Resolve-BackportLocalPath $p } $path) |
                Should -BeExactly ([IO.Path]::GetFullPath($path))
        }
    }
    It 'resolves existing link ancestors before checking containment including dot-dot' {
        $root = Join-Path $script:HarnessRoot ('links-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'real\child') -Force
        $link = Join-Path $root 'alias'
        $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $kind -Path $link -Target (Join-Path $root 'real\child')
        try {
            $envMap = New-CoreEnvironment
            $envMap.STATE_DIR = Join-Path $root 'real\state'
            $envMap.WORK_DIR = Join-Path $link '..\state\nested'
            { & $script:Core { param($e) New-BackportContext -Environment $e } $envMap } |
                Should -Throw '*overlapping_directories*'
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }
    It 'fails closed for every valid stage with invalid context before any transport' {
        foreach ($stage in @('validate','track','prepare','publish')) {
            $envMap = New-CoreEnvironment
            $root = Join-Path $script:HarnessRoot ('cli-' + [guid]::NewGuid().ToString('N'))
            $envMap.RUNNER_TEMP = $root
            $envMap.GITHUB_REPOSITORY_ID = '1'
            $envMap.GITHUB_OUTPUT = Join-Path $root 'outputs'
            $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Invoke-Backport.ps1'),'-Stage',$stage)) {
                $info.ArgumentList.Add($arg)
            }
            foreach ($key in $envMap.Keys) { $info.Environment[$key] = $envMap[$key] }
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $info.RedirectStandardError = $true
            $p = [Diagnostics.Process]::Start($info)
            try {
                $out = $p.StandardOutput.ReadToEndAsync()
                $err = $p.StandardError.ReadToEndAsync()
                $p.WaitForExit()
                $p.ExitCode | Should -Be 1
                ($out.Result + $err.Result).Trim() | Should -Match '^backport_failed: wrong_repository_id$'
                Test-Path -LiteralPath $root | Should -BeFalse
            }
            finally { $p.Dispose() }
        }
    }
    It 'classifies invalid environment values at the CLI boundary without echoing them' {
        $envMap = New-CoreEnvironment
        $envMap.INPUT_SOURCE_PR = 'secret-value'
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Invoke-Backport.ps1'),'-Stage','validate')) {
            $info.ArgumentList.Add($arg)
        }
        foreach ($key in $envMap.Keys) { $info.Environment[$key] = $envMap[$key] }
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $info.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($info)
        try {
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            $p.WaitForExit()
            $p.ExitCode | Should -Be 1
            ($out.Result + $err.Result).Trim() | Should -BeExactly 'backport_failed: invalid_number'
        }
        finally { $p.Dispose() }
    }
    It 'rejects invalid CLI arguments without echoing raw input or credentials' -ForEach @(
        @{ CliArgs = @('-Stage', 'secret-value') }
        @{ CliArgs = @('-Stage', "validate`u{ad}") }
        @{ CliArgs = @("-Sta`u{ad}ge", 'validate') }
        @{ CliArgs = @('-Stage', 'validate', '-Origin', 'secret-value') }
        @{ CliArgs = @('-Stage', 'validate', '-Stage', 'publish') }
        @{ CliArgs = @() }
    ) {
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($arg in @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Invoke-Backport.ps1')) + $CliArgs) {
            $info.ArgumentList.Add($arg)
        }
        $info.Environment['GH_TOKEN'] = 'secret-value'
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $info.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($info)
        try {
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            $p.WaitForExit()
            $p.ExitCode | Should -Be 1
            ($out.Result + $err.Result).Trim() | Should -BeExactly 'backport_failed: invalid_stage'
        }
        finally { $p.Dispose() }
    }
}

Describe 'Canonical JSON and bound atomic artifacts' -Tag 'EPIC-002', 'TEST-013', 'TEST-018' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force
        $script:Core = Get-Module Backport
        $script:CoreReference = & $script:Core {
            param($path) ConvertFrom-BackportJsonBytes ([IO.File]::ReadAllBytes($path))
        } (Join-Path $PSScriptRoot 'parity.json')
        function New-StateConfig {
            $directory = Join-Path $script:HarnessRoot ('state-' + [guid]::NewGuid().ToString('N'))
            @{ state_dir = $directory; source_pr = 7; dry_run = $false; run_id = '123'; run_attempt = '1' }
        }
    }
    It 'matches every Python canonical byte and hash vector with no type coercion' {
        foreach ($vector in $script:CoreReference.vectors) {
            $bytes = & $script:Core { param($v) ConvertTo-BackportJsonBytes $v } $vector.value
            $bytes | Should -BeOfType byte
            [Convert]::ToHexString($bytes).ToLowerInvariant() | Should -BeExactly $vector.utf8_hex
            (& $script:Core { param($b) Get-BackportHash $b } $bytes) | Should -BeExactly $vector.sha256
        }
        foreach ($vector in $script:CoreReference.surrogate_vectors) {
            $value = -join @($vector.utf16_code_units | ForEach-Object { [char]$_ })
            $bytes = & $script:Core { param($v) ConvertTo-BackportJsonBytes $v } $value
            [Convert]::ToHexString($bytes).ToLowerInvariant() | Should -BeExactly $vector.utf8_hex
        }
    }
    It 'preserves null arrays large integers case-distinct keys and escaped surrogates' {
        $value = & $script:Core {
            ConvertFrom-BackportJsonBytes ([Text.Encoding]::UTF8.GetBytes(
                '{"a":[],"A":[null],"n":99999999999999999999,"b":false,"s":"\ud800"}'))
        }
        $value.Count | Should -Be 5
        $value['a'] | Should -HaveCount 0
        $value['A'] | Should -HaveCount 1
        $value['A'][0] | Should -BeNullOrEmpty
        $value.n | Should -BeOfType ([Numerics.BigInteger])
        $value.b | Should -BeOfType bool
        [int]$value.s[0] | Should -Be 0xd800
        $roundtrip = & $script:Core { param($v) ConvertFrom-BackportJsonBytes (ConvertTo-BackportJsonBytes $v) } $value
        $roundtrip['A'] | Should -HaveCount 1
    }
    It 'rejects non-schema canonical types without coercion' {
        foreach ($value in @(1.0, [decimal]1, [double]::NaN, [double]::PositiveInfinity,
            [datetime]::MinValue, [pscustomobject]@{ value = 1 }, @{ 1 = 'integer-key' })) {
            { & $script:Core { param($v) ConvertTo-BackportJsonBytes $v } $value } |
                Should -Throw -ExpectedMessage 'invalid_json_type'
        }
    }
    It 'rejects nested and escaped duplicate keys' -ForEach @(
        @{ Json = '{"a":1,"a":2}' }, @{ Json = '{"a":{"z":1,"\u007a":2}}' },
        @{ Json = '[{"a":1,"a":2}]' }
    ) {
        { & $script:Core { param($j) ConvertFrom-BackportJsonBytes ([Text.Encoding]::UTF8.GetBytes($j)) } $Json } |
            Should -Throw '*duplicate_json_key*'
    }
    It 'serializes property names that shadow dictionary members without loss' {
        $json = '{"Count":999,"Keys":["payload"],"Values":null,"psbase":"shadow"}'
        $actual = & $script:Core {
            param($j) ConvertTo-BackportJsonBytes (ConvertFrom-BackportJsonBytes ([Text.Encoding]::UTF8.GetBytes($j)))
        } $json
        [Text.Encoding]::UTF8.GetString($actual) | Should -BeExactly $json
    }
    It 'rejects an extra Keys property even when it claims the exact expected schema' {
        $config = New-StateConfig
        $vector = @($script:CoreReference.vectors | Where-Object id -CEQ 'plan')[0]
        $keys = ConvertTo-Json -InputObject ([string[]]@($vector.value.Keys)) -Compress
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromHexString($vector.utf8_hex))
        $forged = '{"Keys":' + $keys + ',' + $json.Substring(1)
        $null = [IO.Directory]::CreateDirectory($config.state_dir)
        [IO.File]::WriteAllText((Join-Path $config.state_dir 'plan.json'), $forged)
        { & $script:Core { param($c) Read-BackportArtifact $c 'plan.json' } $config } |
            Should -Throw '*invalid_artifact_schema*'
    }
    It 'rejects malformed JSON and strict UTF8 without leaking the payload' -ForEach @(
        @{ Hex = '7B' }, @{ Hex = 'FF' }, @{ Hex = '22EDA08022' }, @{ Hex = '7B2261223A312C7D' },
        @{ Hex = '7B2261223A4E614E7D' }
    ) {
        { & $script:Core { param($h) ConvertFrom-BackportJsonBytes ([Convert]::FromHexString($h)) } $Hex } |
            Should -Throw '*invalid_artifact*'
    }
    It 'reads Python-produced artifacts and writes identical bytes for every bound shape' {
        $config = New-StateConfig
        foreach ($vector in $script:CoreReference.vectors) {
            if ($vector.id -notmatch '\A(plan|tracking-.+|result-.+|publication)\z') { continue }
            $name = ($vector.id.Split('-')[0]) + '.json'
            $null = [IO.Directory]::CreateDirectory($config.state_dir)
            [IO.File]::WriteAllBytes((Join-Path $config.state_dir $name), [Convert]::FromHexString($vector.utf8_hex))
            $read = & $script:Core { param($c,$n) Read-BackportArtifact $c $n } $config $name
            & $script:Core { param($c,$n,$v) Write-BackportState $c $n $v } $config $name $read
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $config.state_dir $name))).ToLowerInvariant() |
                Should -BeExactly $vector.utf8_hex
        }
        @(Get-ChildItem -LiteralPath $config.state_dir -Filter '.state-*' -Force) | Should -HaveCount 0
    }
    It 'rejects every binding mutation in every bound artifact' {
        $config = New-StateConfig
        foreach ($id in @('plan', 'tracking-tracked', 'result-applied', 'publication')) {
            $vector = @($script:CoreReference.vectors | Where-Object id -CEQ $id)[0]
            $name = $id.Split('-')[0] + '.json'
            foreach ($key in @('schema','repository','repository_id','source_pr','dry_run','run_id','run_attempt')) {
                foreach ($mutation in @('wrong','null','type','missing','case','extra')) {
                    $value = & $script:Core { param($b) ConvertFrom-BackportJsonBytes $b } ([Convert]::FromHexString($vector.utf8_hex))
                    switch ($mutation) {
                        wrong { $value[$key] = if ($value[$key] -is [string]) { 'wrong' } else { 99 } }
                        null { $value[$key] = $null }
                        type { $value[$key] = if ($value[$key] -is [string]) { 123 } else { [string]$value[$key] } }
                        missing { $null = $value.Remove($key) }
                        case { $value[$key.ToUpperInvariant()] = $value[$key]; $null = $value.Remove($key) }
                        extra { $value['unknown'] = $true }
                    }
                    & $script:Core { param($c,$n,$v) Write-BackportState $c $n $v } $config $name $value
                    $reason = if ($mutation -in @('missing','case','extra')) { 'invalid_artifact_schema' } else { 'artifact_context_mismatch' }
                    { & $script:Core { param($c,$n) Read-BackportArtifact $c $n } $config $name } |
                        Should -Throw "*$reason*"
                }
            }
        }
    }
    It 'distinguishes boolean and fractional numbers from integer binding fields' {
        $config = New-StateConfig
        $null = [IO.Directory]::CreateDirectory($config.state_dir)
        foreach ($id in @('plan', 'tracking-tracked', 'result-applied', 'publication')) {
            $vector = @($script:CoreReference.vectors | Where-Object id -CEQ $id)[0]
            $name = $id.Split('-')[0] + '.json'
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromHexString($vector.utf8_hex))
            foreach ($field in @('schema', 'repository_id', 'source_pr')) {
                $integer = [string]$vector.value[$field]
                foreach ($replacement in @('true', ($integer + '.0'), ($integer + 'e0'), ('"' + $integer + '"'))) {
                    [IO.File]::WriteAllText((Join-Path $config.state_dir $name),
                        $json.Replace(('"' + $field + '":' + $integer), ('"' + $field + '":' + $replacement)))
                    { & $script:Core { param($c,$n) Read-BackportArtifact $c $n } $config $name } |
                        Should -Throw '*artifact_context_mismatch*'
                }
            }
            foreach ($field in @('repository', 'run_id', 'run_attempt')) {
                foreach ($suffix in @('\u00ad', '\u0000')) {
                    [IO.File]::WriteAllText((Join-Path $config.state_dir $name),
                        $json.Replace(('"' + $field + '":"' + $vector.value[$field] + '"'),
                            ('"' + $field + '":"' + $vector.value[$field] + $suffix + '"')))
                    { & $script:Core { param($c,$n) Read-BackportArtifact $c $n } $config $name } |
                        Should -Throw '*artifact_context_mismatch*'
                }
            }
        }
    }
    It 'rejects artifact names with linguistically ignorable characters' {
        $config = New-StateConfig
        foreach ($name in @("plan.json`u{ad}", "res`0ult.json")) {
            { & $script:Core { param($c,$n) Write-BackportState $c $n @{} } $config $name } |
                Should -Throw '*invalid_artifact*'
        }
    }
    It 'writes empty and binary patch bytes without text conversion or pipeline output' {
        $config = New-StateConfig
        foreach ($bytes in @([byte[]]@(), [byte[]]@(0, 13, 10, 255))) {
            $output = @(& $script:Core { param($c,$b) Write-BackportState $c 'patch.bin' $b } $config $bytes)
            $output | Should -HaveCount 0
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $config.state_dir 'patch.bin'))) |
                Should -BeExactly ([Convert]::ToHexString($bytes))
        }
    }
    It 'rejects escaped filenames nonregular inputs and oversized state' {
        $config = New-StateConfig
        { & $script:Core { param($c) Write-BackportState $c '../escape.json' @{} } $config } |
            Should -Throw '*invalid_artifact*'
        $null = [IO.Directory]::CreateDirectory((Join-Path $config.state_dir 'plan.json'))
        { & $script:Core { param($c) Read-BackportArtifact $c 'plan.json' } $config } |
            Should -Throw '*invalid_artifact*'
        { & $script:Core { param($c) Write-BackportState $c 'plan.json' @{} } $config } |
            Should -Throw '*invalid_artifact*'
        $config = New-StateConfig
        $null = [IO.Directory]::CreateDirectory($config.state_dir)
        [IO.File]::WriteAllBytes((Join-Path $config.state_dir 'plan.json'), [byte[]]::new(5MB + 1))
        { & $script:Core { param($c) Read-BackportArtifact $c 'plan.json' } $config } |
            Should -Throw '*invalid_artifact*'
    }
    It 'isolates <Boundary> fixture credentials even with shadowing environment names' -ForEach @(
        @{ Boundary = 'process' }, @{ Boundary = 'python' }, @{ Boundary = 'harness' }
    ) {
        $saved = @{}
        try {
            foreach ($name in @('Keys','Count','GH_TOKEN','GITHUB_TOKEN','GIT_TRACE')) {
                $saved[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, 'synthetic-shadow-value')
            }
            if ($Boundary -ceq 'process') {
                $info = New-BackportProcessFixtureStartInfo -Fixture ([pscustomobject]@{ Script = 'unused.ps1' }) -Arguments @()
                foreach ($name in @('GH_TOKEN','GITHUB_TOKEN','GIT_TRACE')) {
                    $info.Environment.ContainsKey($name) | Should -BeFalse
                }
            }
            elseif ($Boundary -ceq 'harness') {
                $command = @'
if ($env:Keys -cne 'synthetic-shadow-value' -or $env:GH_TOKEN -or $env:GITHUB_TOKEN -or $env:GIT_TRACE) { exit 2 }
[Console]::Write('isolated')
'@
                $child = Invoke-HarnessPowerShell -Arguments @('-NoProfile', '-NonInteractive', '-Command', $command)
                $child.ExitCode | Should -Be 0
                $child.Stdout | Should -BeExactly 'isolated'
                $child.Stderr | Should -BeExactly ''
            }
            else {
                $config = New-StateConfig
                Invoke-PythonStateHandoff -BaselineDirectory $env:BACKPORT_TEST_BASELINE_DIR -StateDirectory $config.state_dir -Mode seed
            }
        }
        finally {
            foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value) }
        }
    }
    It 'performs actual Python-to-PowerShell-to-Python same-binding state handoff' {
        $config = New-StateConfig
        Invoke-PythonStateHandoff -BaselineDirectory $env:BACKPORT_TEST_BASELINE_DIR -StateDirectory $config.state_dir -Mode seed
        foreach ($name in @('plan.json','tracking.json','result.json','publication.json')) {
            $value = & $script:Core { param($c,$n) Read-BackportArtifact $c $n } $config $name
            & $script:Core { param($c,$n,$v) Write-BackportState $c $n $v } $config $name $value
        }
        Invoke-PythonStateHandoff -BaselineDirectory $env:BACKPORT_TEST_BASELINE_DIR -StateDirectory $config.state_dir -Mode verify
    }
    It 'rejects state links and ancestor substitution without touching their targets' {
        $config = New-StateConfig
        $null = [IO.Directory]::CreateDirectory($config.state_dir)
        $target = Join-Path $script:HarnessRoot ('target-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($target)
        $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $path = Join-Path $config.state_dir 'plan.json'
        $null = New-Item -ItemType $kind -Path $path -Target $target
        try {
            { & $script:Core { param($c) Read-BackportArtifact $c 'plan.json' } $config } |
                Should -Throw '*invalid_artifact*'
            { & $script:Core { param($c) Write-BackportState $c 'plan.json' @{} } $config } |
                Should -Throw '*invalid_artifact*'
        }
        finally { Remove-Item -LiteralPath $path -Force }
        Remove-Item -LiteralPath $config.state_dir
        $null = New-Item -ItemType $kind -Path $config.state_dir -Target $target
        try {
            { & $script:Core { param($c) Write-BackportState $c 'plan.json' @{} } $config } |
                Should -Throw '*invalid_artifact*'
            @(Get-ChildItem -LiteralPath $target -Force) | Should -HaveCount 0
        }
        finally { Remove-Item -LiteralPath $config.state_dir -Force }
    }
    It 'rejects nonregular Unix file modes before opening a stream' {
        $config = New-StateConfig
        & $script:Core { param($c) Write-BackportState $c 'plan.json' @{} } $config
        InModuleScope Backport -Parameters @{ Path = (Join-Path $config.state_dir 'plan.json') } {
            param($Path)
            foreach ($mode in @('prw-------','srw-------','crw-------','brw-------')) {
                Mock Get-Item { [pscustomobject]@{ UnixMode = $mode } }
                { Assert-BackportRegularFile $Path } | Should -Throw '*invalid_artifact*'
            }
        }
    }
    It 'keeps previous complete bytes when atomic replacement fails' {
        $config = New-StateConfig
        & $script:Core { param($c) Write-BackportState $c 'result.json' @{ previous = $true } } $config
        $path = Join-Path $config.state_dir 'result.json'
        $before = [IO.File]::ReadAllBytes($path)
        InModuleScope Backport -Parameters @{ Config = $config } {
            param($Config)
            Mock Move-BackportStateFile { throw [IO.IOException]::new('synthetic write failure') }
            { Write-BackportState $Config 'result.json' @{ next = $true } } |
                Should -Throw '*state_write_failed*'
        }
        [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToHexString($before))
        @(Get-ChildItem -LiteralPath $config.state_dir -Filter '.state-*' -Force) | Should -HaveCount 0
    }
}

AfterAll {
    if ($script:HarnessRoot -and (Test-Path -LiteralPath $script:HarnessRoot)) {
        Remove-Item -LiteralPath $script:HarnessRoot -Recurse -Force
    }
}

Describe 'Acceptance gate using simulated execution results only' -Tag 'EPIC-001' {
    BeforeEach {
        Mock Invoke-WebRequest { throw 'network_forbidden' }
        Mock Invoke-RestMethod { throw 'network_forbidden' }
        $parity = New-SyntheticParity
        $result = New-SyntheticResult
    }

    It 'accepts a complete synthetic set without claiming the suite has ported it' {
        $gate = Test-BackportAcceptance -Result $result -Parity $parity
        $gate.Accepted | Should -BeTrue
        $gate.Mode | Should -Be 'FullAcceptance'
        $gate.BaselinePassed | Should -Be 67
        $gate.MigrationPassed | Should -Be 12
    }

    It 'accepts null optional error records as returned by Pester 5.7.1' {
        $result.ErrorRecord = $null
        $result.Containers[0].ErrorRecord = $null
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeTrue
    }

    It 'rejects <Mutation> baseline identity even with the same total count' -ForEach @(
        @{ Mutation = 'duplicate' }, @{ Mutation = 'unknown' }, @{ Mutation = 'case-changed' }
    ) {
        switch ($Mutation) {
            duplicate { $result.Tests[0].Name = $result.Tests[1].Name }
            unknown { $result.Tests[0].Name = 'test_not_in_baseline' }
            case-changed { $result.Tests[0].Name = $result.Tests[0].Name.ToUpperInvariant() }
        }
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }

    It 'rejects a missing baseline case instead of trusting PassedCount' {
        $result.Tests = @($result.Tests | Select-Object -Skip 1)
        (Test-BackportAcceptance -Result $result -Parity $parity).Errors -join ';' | Should -Match 'baseline'
    }

    It 'rejects a required case whose state is <State>' -ForEach @(
        @{ State = 'Skipped' }, @{ State = 'Pending' }, @{ State = 'NotRun' }, @{ State = 'Failed' }
    ) {
        $result.Tests[0].Result = $State
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }

    It 'rejects a required case marked passed but never executed' {
        $result.Tests[0].Executed = $false
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }

    It 'rejects a missing migration ID even when 67 baseline names pass' {
        $result.Tests[-1].Tag = @()
        (Test-BackportAcceptance -Result $result -Parity $parity).Errors -join ';' | Should -Match 'TEST-024'
    }

    It 'rejects an unexecuted tagged migration case' {
        $result.Tests[-1].Executed = $false
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }

    It 'rejects <Mutation> parity metadata' -ForEach @(
        @{ Mutation = 'count' }, @{ Mutation = 'duplicate-id' }, @{ Mutation = 'duplicate-name' },
        @{ Mutation = 'unknown-name' }, @{ Mutation = 'missing-migration' }, @{ Mutation = 'duplicate-migration' },
        @{ Mutation = 'unknown-migration' }, @{ Mutation = 'schema' }
    ) {
        switch ($Mutation) {
            count { $parity.baseline.test_count = 66 }
            duplicate-id { $parity.baseline_tests[0].id = $parity.baseline_tests[1].id }
            duplicate-name { $parity.baseline_tests[0].pester_name = $parity.baseline_tests[1].pester_name }
            unknown-name { $parity.baseline_tests[0].pester_name = 'not-a-baseline-name' }
            missing-migration { $parity.required_migration_ids = $parity.required_migration_ids[0..10] }
            duplicate-migration { $parity.required_migration_ids[0] = 'TEST-014' }
            unknown-migration { $parity.required_migration_ids[0] = 'TEST-099' }
            schema { $parity.schema = 2 }
        }
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }

    It 'rejects <Failure> even when individual test results appear passed' -ForEach @(
        @{ Failure = 'container-count' }, @{ Failure = 'container-error' }, @{ Failure = 'block-count' },
        @{ Failure = 'run-error' }, @{ Failure = 'zero-discovery' }, @{ Failure = 'failed-run' }
    ) {
        switch ($Failure) {
            container-count { $result.FailedContainersCount = 1 }
            container-error { $result.Containers[0].ErrorRecord = @('discovery failed') }
            block-count { $result.FailedBlocksCount = 1 }
            run-error { $result.ErrorRecord = @('before-all failed') }
            zero-discovery { $result.Tests = @(); $result.TotalCount = 0 }
            failed-run { $result.Result = 'Failed' }
        }
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }

    It 'allows only the selected development epic and labels it NOT full acceptance' {
        $result = New-SyntheticDevelopmentResult
        $result.Tests += [pscustomobject]@{
            Name = 'future case'; Tag = @('EPIC-002'); Result = 'NotRun'; Executed = $false
        }
        $result.TotalCount = 2
        $result.NotRunCount = 1
        $gate = Test-BackportAcceptance -Result $result -Epic EPIC-001
        $gate.Accepted | Should -BeTrue
        $gate.Mode | Should -Be 'Development'
        $gate.Message | Should -Match 'NOT full acceptance'
        $gate.BaselinePassed | Should -Be 0
    }

    It 'does not accept a development run with no selected cases' {
        (Test-BackportAcceptance -Result $result -Epic EPIC-001).Accepted | Should -BeFalse
    }

    It 'does not accept a skipped selected development case' {
        $result = New-SyntheticDevelopmentResult
        $result.Tests[0].Result = 'Skipped'
        (Test-BackportAcceptance -Result $result -Epic EPIC-001).Accepted | Should -BeFalse
    }

    It 'rejects coordinated replacement of all 67 names in metadata and simulated results' {
        foreach ($index in 0..66) {
            $name = 'test_replacement_{0:d2}' -f $index
            $parity.baseline_tests[$index].id = $name
            $parity.baseline_tests[$index].pester_name = $name
            $result.Tests[$index].Name = $name
        }
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }

    It 'rejects a changed pinned baseline <Field>' -ForEach @(
        @{ Field = 'commit'; Value = ('b' * 40) }, @{ Field = 'controller_lines'; Value = 867 }
    ) {
        $parity.baseline[$Field] = $Value
        (Test-BackportAcceptance -Result $result -Parity $parity).Accepted | Should -BeFalse
    }
}

Describe 'Repository-local reference resources' -Tag 'EPIC-001' {
    It 'retains canonical byte and SHA-256 pairs without claiming PowerShell serialization parity' {
        $script:Reference.vectors.Count | Should -Be 16
        foreach ($vector in @($script:Reference.vectors) + @($script:Reference.surrogate_vectors)) {
            $bytes = [Convert]::FromHexString($vector.utf8_hex)
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() |
                Should -BeExactly $vector.sha256
        }
    }

    It 'retains all correspondence and independently named helper dispositions' -Tag 'EPIC-003', 'TEST-021', 'TEST-022', 'TEST-023', 'TEST-024' {
        @($script:Reference.correspondence.id) | Should -Be @(1..8 | ForEach-Object { 'MAP-{0:d3}' -f $_ })
        @($script:Reference.correspondence.disposition) | Should -Be @(
            'retained', 'adapted', 'adapted', 'retained', 'deferred', 'adapted', 'adapted', 'retained'
        )
        $script:Reference.helper_dispositions.Count | Should -Be 5
        @($script:Reference.helper_dispositions.id) | Should -Be @(
            'byte-safe-blob', 'canonical-atomic-json', 'result-before-pr', 'github-readback', 'publication-receipt'
        )
        @($script:Reference.helper_dispositions.disposition) | Should -Be @(
            'adapted', 'adapted', 'adapted', 'adapted', 'deferred'
        )
        foreach ($entry in @($script:Reference.correspondence) + @($script:Reference.helper_dispositions)) {
            $entry.decision | Should -Not -BeNullOrEmpty
        }
        @($script:Reference.shared_safety.Keys | Sort-Object) | Should -Be @('TEST-021', 'TEST-022', 'TEST-023', 'TEST-024')
        $script:Reference.shared_safety.'TEST-021'.baseline_cases.Count | Should -Be 4
    }

    It 'retains the pinned complete Unicode profile and redistribution notice' {
        $compat = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'compat.json') -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $compat.provenance.python_version | Should -BeExactly '3.13'
        $compat.provenance.unicode_version | Should -BeExactly '15.1.0'
        $compat.case_folds.Count | Should -Be 1530
        $compat.category_c_ranges.Count | Should -Be 712
        $compat.whitespace.Count | Should -Be 29
        $compat.license.notice | Should -Match 'Permission is hereby granted'
    }
}

Describe 'Pinned runner boundary' -Tag 'EPIC-001' {
    BeforeEach {
        Mock Invoke-WebRequest { throw 'network_forbidden' }
        Mock Invoke-RestMethod { throw 'network_forbidden' }
        Mock Write-Host {}
    }

    It 'dot-sources without running tests or importing Pester' {
        Mock Invoke-Pester { throw 'unexpected execution' }
        Mock Import-Module { throw 'unexpected import' }
        . (Join-Path $PSScriptRoot 'Run-Tests.ps1')
        Should -Invoke Invoke-Pester -Times 0 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly
    }

    It 'requires PowerShell 7.4 and .NET 8 or newer' {
        { Assert-BackportRuntime -PowerShellVersion ([version]'7.3') -DotNetVersion ([version]'8.0') } | Should -Throw
        { Assert-BackportRuntime -PowerShellVersion ([version]'7.4') -DotNetVersion ([version]'7.0') } | Should -Throw
        { Assert-BackportRuntime -PowerShellVersion ([version]'7.4') -DotNetVersion ([version]'8.0') } | Should -Not -Throw
    }

    It 'pins Pester, the adjacent test file, and caller-specified XML using mocked execution' {
        $script:CapturedConfiguration = $null
        Mock Invoke-Pester {
            $script:CapturedConfiguration = $Configuration
            New-SyntheticDevelopmentResult
        }
        Mock Import-Module {} -ParameterFilter { $Name -eq 'Pester' -and $RequiredVersion -eq '5.7.1' }
        $path = Join-Path $script:HarnessRoot 'mock-results.xml'
        $gate = Invoke-BackportTests -Epic EPIC-001 -ResultPath $path
        $gate.ExitCode | Should -Be 0
        @($script:CapturedConfiguration.Run.Path.Value) | Should -Be @((Join-Path $PSScriptRoot 'Backport.Tests.ps1'))
        $script:CapturedConfiguration.Filter.Tag.Value | Should -Contain 'EPIC-001'
        $script:CapturedConfiguration.TestResult.Enabled.Value | Should -BeTrue
        $script:CapturedConfiguration.TestResult.OutputPath.Value | Should -Be $path
        $script:CapturedConfiguration.Run.Exit.Value | Should -BeFalse
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $RequiredVersion -eq '5.7.1'
        }
    }

    It 'returns nonzero for a mocked failing runner' {
        Mock Invoke-Pester {
            $fake = New-SyntheticDevelopmentResult
            $fake.Tests[0].Result = 'Failed'
            $fake.FailedCount = 1
            $fake.Result = 'Failed'
            $fake
        }
        (Invoke-BackportTests -Epic EPIC-001 -ResultPath (Join-Path $script:HarnessRoot 'failed.xml')).ExitCode |
            Should -Be 1
    }

    It 'never promotes a green mocked harness run to default full acceptance' {
        Mock Invoke-Pester { New-SyntheticDevelopmentResult }
        $metadata = Join-Path $script:HarnessRoot 'synthetic-parity.json'
        New-SyntheticParity | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadata
        $gate = Invoke-BackportTests -ParityPath $metadata -ResultPath (Join-Path $script:HarnessRoot 'full-mock.xml')
        $gate.Mode | Should -Be 'FullAcceptance'
        $gate.ExitCode | Should -Be 1
        $gate.BaselinePassed | Should -Be 0
        $gate.Errors -join ';' | Should -Match 'missing baseline'
    }

    It 'reads case-distinct parity keys and escaped Unicode without rewriting metadata' {
        Mock Invoke-Pester { New-SyntheticDevelopmentResult }
        Mock Test-BackportAcceptance {
            $script:CapturedParity = $Parity
            [pscustomobject]@{ Accepted = $false; ExitCode = 1; Message = 'synthetic parsing check'; Errors = @() }
        }
        $metadata = Join-Path $script:HarnessRoot 'case-distinct-parity.json'
        $json = '{"schema":1,"vectors":[{"A":true,"a":0,"astral":"\ud83d\ude00","lone_escape":"\\ud800"}]}'
        [IO.File]::WriteAllText($metadata, $json)
        $before = (Get-FileHash -LiteralPath $metadata).Hash
        $null = Invoke-BackportTests -ParityPath $metadata -ResultPath (Join-Path $script:HarnessRoot 'unicode-mock.xml')
        $vector = $script:CapturedParity.vectors[0]
        $vector.Count | Should -Be 4
        $vector['A'] | Should -BeTrue
        $vector['a'] | Should -Be 0
        $vector['astral'] | Should -Be ([char]::ConvertFromUtf32(0x1F600))
        $vector['lone_escape'] | Should -Be '\ud800'
        (Get-FileHash -LiteralPath $metadata).Hash | Should -Be $before
    }

    It 'fails closed when the pinned Pester import is unavailable' {
        Mock Import-Module { throw 'pinned_pester_unavailable' } -ParameterFilter { $Name -eq 'Pester' }
        Mock Invoke-Pester { throw 'must_not_run' }
        { Invoke-BackportTests -Epic EPIC-001 } | Should -Throw '*pinned_pester_unavailable*'
        Should -Invoke Invoke-Pester -Times 0 -Exactly
    }

    It 'defaults XML outside the repository without creating it at import' {
        $path = Get-BackportDefaultResultPath
        $path | Should -Match '\.xml$'
        [IO.Path]::GetDirectoryName($path) | Should -Be ([IO.Path]::GetTempPath().TrimEnd('\', '/'))
        Test-Path -LiteralPath $path | Should -BeFalse
        foreach ($layout in @('one/two/three/four/five', '.github/scripts/backport-demo')) {
            $root = Join-Path $script:HarnessRoot ([guid]::NewGuid().ToString('N'))
            $repository = Join-Path $root 'repository'
            $scripts = Join-Path $repository $layout
            $externalTemp = Join-Path $root '_temp'
            $internalTemp = Join-Path $repository '_temp'
            $null = New-Item -ItemType Directory -Path $scripts, $externalTemp, $internalTemp, (Join-Path $repository '.git')
            $runner = Join-Path $scripts 'Run-Tests.ps1'
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Run-Tests.ps1') -Destination $runner
            foreach ($temp in @($externalTemp, $internalTemp)) {
                $command = ". '$($runner.Replace("'", "''"))'; " +
                    "`$env:TMP = `$env:TEMP = `$env:TMPDIR = '$($temp.Replace("'", "''"))'; Get-BackportDefaultResultPath"
                $child = Invoke-HarnessPowerShell -Arguments @('-NoProfile', '-NonInteractive', '-Command', $command)
                if ($temp -eq $externalTemp) {
                    $child.ExitCode | Should -Be 0 -Because $layout
                    [IO.Path]::GetDirectoryName($child.Stdout.Trim()) | Should -Be $externalTemp
                    Test-Path -LiteralPath $child.Stdout.Trim() | Should -BeFalse
                }
                else {
                    $child.ExitCode | Should -Be 1
                    $child.Stderr | Should -Match 'TEMP is inside the repository'
                }
            }
        }
    }

    It 'returns nonzero from the real script when pinned Pester cannot be loaded' {
        $xml = Join-Path $script:HarnessRoot 'missing-pester.xml'
        $runner = (Join-Path $PSScriptRoot 'Run-Tests.ps1').Replace("'", "''")
        $emptyModules = Join-Path $script:HarnessRoot 'empty-modules'
        $null = New-Item -ItemType Directory -Path $emptyModules
        $command = "`$env:PSModulePath = '$($emptyModules.Replace("'", "''"))'; & '$runner' -Epic EPIC-001 -ResultPath '$($xml.Replace("'", "''"))'"
        $child = Invoke-HarnessPowerShell -Arguments @(
            '-NoProfile', '-NonInteractive', '-Command', $command
        )
        $child.ExitCode | Should -Be 1
        $child.Stderr | Should -Match 'Pester'
        Test-Path -LiteralPath $xml | Should -BeFalse
    }
}

Describe 'Offline stateful GitHub fixture' -Tag 'EPIC-001' {
    BeforeEach {
        Mock Invoke-WebRequest { throw 'network_forbidden' }
        Mock Invoke-RestMethod { throw 'network_forbidden' }
        $api = New-FakeGitHub -Head ('1' * 40) -Source ('2' * 40) -Target ('3' * 40)
        $root = '/repos/' + $api.repo.full_name
    }

    It 'deep copies metadata, response values, and recorded request payloads' {
        $repo = Invoke-FakeGitHub $api GET $root
        $repo.full_name = 'changed/response'
        $api.repo.full_name | Should -Be 'AleksanderGladkov/BCApps-Backport-Test'
        $payload = @{ title = 'one'; labels = @('original') }
        $issue = Invoke-FakeGitHub $api POST "$root/issues" $payload
        $payload.labels[0] = 'mutated'
        $issue.title = 'mutated response'
        $api.calls[-1].data.labels[0] | Should -Be 'original'
        $api.issues[0].title | Should -Be 'one'
        (Invoke-FakeGitHub $api GET "$root/pulls/7").merge_commit_sha | Should -Be ('2' * 40)
    }

    It 'uses baseline repository and object identities without opening a connection' {
        $api.repo.id | Should -Be 1369849596
        $api.repo.full_name | Should -Be 'AleksanderGladkov/BCApps-Backport-Test'
        $issue = Invoke-FakeGitHub $api POST "$root/issues" @{ title = 'synthetic'; body = 'fixture' }
        $issue.html_url | Should -Be 'https://github.com/AleksanderGladkov/BCApps-Backport-Test/issues/101'
        $issue.id | Should -Be 1001
        $issue.user.id | Should -Be 41898282
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'paginates lists and source commits without sharing mutable returned data' {
        foreach ($number in 1..205) {
            $api.issues.Add(@{ number = $number; title = "issue $number" })
            $api.commits.Add(@{ sha = '{0:x40}' -f $number })
        }
        (Invoke-FakeGitHub $api GET "$root/issues?state=all&per_page=100&page=1").Count | Should -Be 100
        $page = Invoke-FakeGitHub $api GET "$root/issues?state=all&per_page=100&page=3"
        $page.Count | Should -Be 5
        $page[0].title = 'changed'
        $api.issues[200].title | Should -Be 'issue 201'
        (Invoke-FakeGitHub $api GET "$root/pulls/7/commits?per_page=100&page=3").Count | Should -Be 5
        (Invoke-FakeGitHub $api GET "$root/issues?per_page=100&page=4").Count | Should -Be 0
    }

    It 'reads current run and paginated history again after mutable history changes' {
        foreach ($id in 1..101) { $api.runs.Add((New-FakeWorkflowRun -Api $api -Id $id)) }
        (Invoke-FakeGitHub $api GET "$root/actions/runs/1").run_attempt | Should -Be 1
        $page = Invoke-FakeGitHub $api GET "$root/actions/workflows/backport-demo.yml/runs?per_page=100&page=2"
        $page.total_count | Should -Be 101
        $page.workflow_runs.Count | Should -Be 1
        $page.workflow_runs[0].run_attempt = 99
        $api.runs[100].run_attempt | Should -Be 1
        $api.runs[0].run_attempt = 2
        $api.runs.Add((New-FakeWorkflowRun -Api $api -Id 102 -DryRun $true))
        (Invoke-FakeGitHub $api GET "$root/actions/runs/1").run_attempt | Should -Be 2
        (Invoke-FakeGitHub $api GET "$root/actions/workflows/backport-demo.yml/runs?per_page=100&page=2").total_count |
            Should -Be 102
    }

    It 'distinguishes failure before POST from lost response after an issue exists' {
        $api.fail_post = "$root/issues"
        { Invoke-FakeGitHub $api POST "$root/issues" @{ title = 'no effect' } } | Should -Throw '*api_write_ambiguous*'
        $api.issues.Count | Should -Be 0
        $api.fail_post = $null
        $api.lose_post_response = "$root/issues"
        { Invoke-FakeGitHub $api POST "$root/issues" @{ title = 'effect exists' } } | Should -Throw '*api_write_ambiguous*'
        $api.issues.Count | Should -Be 1
        $api.calls.Count | Should -Be 2
        (Invoke-FakeGitHub $api GET "$root/issues/101").title | Should -Be 'effect exists'
    }

    It 'allows stale lists without deleting objects that remain readable by ID' {
        $null = Invoke-FakeGitHub $api POST "$root/issues" @{ title = 'visible by id' }
        $null = $api.stale_paths.Add("$root/issues")
        (Invoke-FakeGitHub $api GET "$root/issues?per_page=100&page=1").Count | Should -Be 0
        (Invoke-FakeGitHub $api GET "$root/issues/101").title | Should -Be 'visible by id'
        $null = $api.stale_paths.Remove("$root/issues")
        (Invoke-FakeGitHub $api GET "$root/issues").Count | Should -Be 1
    }

    It 'returns PR-shaped Issue entries as well as ordinary issues' {
        $api.issues.Add(@{ number = 101; title = 'issue' })
        $api.pulls.Add(@{ number = 102; html_url = 'https://example.invalid/pull/102'; head = @{ sha = 'abc' } })
        $issues = Invoke-FakeGitHub $api GET "$root/issues?state=all"
        $issues.Count | Should -Be 2
        $issues[1].pull_request.html_url | Should -Be 'https://example.invalid/pull/102'
        $issues[1].head.sha = 'changed'
        (Invoke-FakeGitHub $api GET "$root/pulls/102").head.sha | Should -Be 'abc'
    }

    It 'supports comment create, readback, PATCH, and lost PATCH responses' {
        $comment = Invoke-FakeGitHub $api POST "$root/issues/101/comments" @{ body = 'first' }
        $patched = Invoke-FakeGitHub $api PATCH "$root/issues/comments/$($comment.id)" @{ body = 'second' }
        $patched.body | Should -Be 'second'
        $api.lose_patch_response = "$root/issues/comments/$($comment.id)"
        { Invoke-FakeGitHub $api PATCH "$root/issues/comments/$($comment.id)" @{ body = 'third' } } |
            Should -Throw '*api_write_ambiguous*'
        (Invoke-FakeGitHub $api GET "$root/issues/101/comments")[0].body | Should -Be 'third'
    }

    It 'keeps a created comment after a lost response and can hide its list' {
        $api.lose_post_response = "$root/issues/101/comments"
        { Invoke-FakeGitHub $api POST "$root/issues/101/comments" @{ body = 'created once' } } |
            Should -Throw '*api_write_ambiguous*'
        $api.comments[101].Count | Should -Be 1
        $null = $api.stale_paths.Add("$root/issues/101/comments")
        (Invoke-FakeGitHub $api GET "$root/issues/101/comments").Count | Should -Be 0
        $api.comments[101][0].body | Should -Be 'created once'
    }

    It 'rejects malformed workflow pagination instead of inventing complete history' {
        { Invoke-FakeGitHub $api GET "$root/actions/workflows/backport-demo.yml/runs?per_page=100" } |
            Should -Throw '*unexpected_fake_request*'
        { Invoke-FakeGitHub $api GET "$root/issues?per_page=100&page=0" } |
            Should -Throw '*unexpected_fake_request*'
    }

    It 'fails closed for unexpected method or route <Method> <Path>' -ForEach @(
        @{ Method = 'DELETE'; Path = '/anything' }, @{ Method = 'GET'; Path = 'https://example.invalid/' },
        @{ Method = 'GET'; Path = '/repos/AleksanderGladkov/BCApps-Backport-Test/unexpected/comments' },
        @{ Method = 'POST'; Path = '/repos/AleksanderGladkov/BCApps-Backport-Test/unknown' },
        @{ Method = 'GET'; Path = '/repos/AleksanderGladkov/BCApps-Backport-Test/actions/runs/999' }
    ) {
        { Invoke-FakeGitHub $api $Method $Path } | Should -Throw '*unexpected_fake_request*'
    }

    It 'blocks network cmdlets at the test boundary' {
        { Invoke-WebRequest -Uri 'https://example.invalid' } | Should -Throw '*network_forbidden*'
        { Invoke-RestMethod -Uri 'https://example.invalid' } | Should -Throw '*network_forbidden*'
    }
}

Describe 'Owned local Git fixtures' -Tag 'EPIC-001' {
    BeforeEach {
        Mock Invoke-WebRequest { throw 'network_forbidden' }
        Mock Invoke-RestMethod { throw 'network_forbidden' }
        $fixture = New-LocalGitFixture -ParentPath $script:HarnessRoot
    }
    AfterEach { if ($fixture) { Remove-LocalGitFixture -Fixture $fixture } }

    It 'pins author and committer times for reproducible fixture identities' {
        $environment = New-LocalGitEnvironment -Fixture $fixture
        $environment.GIT_AUTHOR_DATE | Should -Be '2000-01-01T00:00:00Z'
        $environment.GIT_COMMITTER_DATE | Should -Be '2000-01-01T00:00:00Z'
        $other = New-LocalGitFixture -ParentPath $script:HarnessRoot
        try {
            $other.Target | Should -Be $fixture.Target
            $other.Head | Should -Be $fixture.Head
            $other.Source | Should -Be $fixture.Source
        }
        finally { Remove-LocalGitFixture $other }
    }

    It 'leaves a real branch after losing the push response without retrying' {
        $work = New-LocalGitWorkingCopy -Fixture $fixture
        $null = Invoke-LocalGit $fixture $work @('checkout', '--detach', $fixture.Target)
        $fixture | Add-Member -NotePropertyName LosePushResponse -NotePropertyValue $true -Force
        { Invoke-LocalGit $fixture $work @('push', $fixture.Origin, 'HEAD:refs/heads/lost-response') } |
            Should -Throw '*local_git_response_lost*'
        Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'refs/heads/lost-response') |
            Should -Be $fixture.Target
    }

    It 'creates main, release, feature, and a provable synthetic PR 7 squash' {
        Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'refs/heads/releases/29.x') | Should -Be $fixture.Target
        Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'refs/pull/7/head') | Should -Be $fixture.Head
        Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', "$($fixture.Source)^") | Should -Be $fixture.Target
        $sourceDiff = Invoke-LocalGit $fixture $fixture.Origin @('diff', '--raw', '--no-abbrev', $fixture.Target, $fixture.Source)
        $headDiff = Invoke-LocalGit $fixture $fixture.Origin @('diff', '--raw', '--no-abbrev', $fixture.Target, $fixture.Head)
        $sourceDiff | Should -Be $headDiff
        $sourceDiff | Should -Match 'src/one.al'
    }

    It 'pushes and reads a real local branch and records a pull ref even after a lost response' {
        $work = New-LocalGitWorkingCopy -Fixture $fixture
        $null = Invoke-LocalGit $fixture $work @('checkout', '--detach', $fixture.Target)
        $null = Invoke-LocalGit $fixture $work @('cherry-pick', '-x', $fixture.Source)
        $head = Invoke-LocalGit $fixture $work @('rev-parse', 'HEAD')
        $null = Invoke-LocalGit $fixture $work @('push', $fixture.Origin, 'HEAD:refs/heads/backport-fixture')
        Invoke-LocalGit $fixture $work @('ls-remote', '--heads', $fixture.Origin, 'refs/heads/backport-fixture') |
            Should -Match "^$head"
        $api = New-FakeGitHub -Fixture $fixture -Head $fixture.Head -Source $fixture.Source -Target $fixture.Target
        $root = '/repos/' + $api.repo.full_name
        $api.lose_post_response = "$root/pulls"
        { Invoke-FakeGitHub $api POST "$root/pulls" @{ head = 'backport-fixture'; base = 'releases/29.x'; body = 'proof' } } |
            Should -Throw '*api_write_ambiguous*'
        $api.pulls.Count | Should -Be 1
        $api.pulls[0].html_url | Should -Be 'https://github.com/AleksanderGladkov/BCApps-Backport-Test/pull/102'
        (Invoke-FakeGitHub $api GET "$root/pulls/102").head.sha | Should -Be $head
        Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'refs/pull/102/head') | Should -Be $head
    }

    It 'permits the baseline create-only lease and rejects a repeated branch creation' {
        $work = New-LocalGitWorkingCopy -Fixture $fixture
        $null = Invoke-LocalGit $fixture $work @('checkout', '--detach', $fixture.Target)
        $arguments = @('push', '--porcelain', $fixture.Origin,
            '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7')
        $null = Invoke-LocalGit $fixture $work $arguments
        $null = Invoke-LocalGit $fixture $work @('commit', '--allow-empty', '-m', 'racing advance')
        { Invoke-LocalGit $fixture $work $arguments } | Should -Throw '*local_git_failed*'
        Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'refs/heads/backport/29.x/pr-7') |
            Should -Be $fixture.Target
    }

    It 'preserves a dirty caller worktree, index, HEAD, and current directory' {
        $caller = New-LocalGitWorkingCopy -Fixture $fixture
        $null = Invoke-LocalGit $fixture $caller @('checkout', '--detach', $fixture.Target)
        [IO.File]::WriteAllText((Join-Path $caller 'staged.txt'), "staged`n")
        $null = Invoke-LocalGit $fixture $caller @('add', 'staged.txt')
        [IO.File]::WriteAllText((Join-Path $caller 'src\one.al'), "dirty`n")
        [IO.File]::WriteAllText((Join-Path $caller 'untracked.txt'), "untracked`n")
        $before = Invoke-LocalGit $fixture $caller @('status', '--porcelain=v1')
        $index = (Get-FileHash -LiteralPath (Join-Path $caller '.git\index')).Hash
        $location = Get-Location
        try {
            Set-Location -LiteralPath $caller
            $other = New-LocalGitWorkingCopy -Fixture $fixture
            $null = Invoke-LocalGit $fixture $other @('checkout', '--detach', $fixture.Source)
            (Get-Location).Path | Should -Be $caller
        }
        finally { Set-Location -LiteralPath $location.Path }
        Invoke-LocalGit $fixture $caller @('rev-parse', 'HEAD') | Should -Be $fixture.Target
        (Get-FileHash -LiteralPath (Join-Path $caller '.git\index')).Hash | Should -Be $index
        Invoke-LocalGit $fixture $caller @('status', '--porcelain=v1') | Should -Be $before
        [IO.File]::ReadAllText((Join-Path $caller 'src\one.al')) | Should -Be "dirty`n"
    }

    It 'removes only its owned fixture and refuses cleanup of an unowned path' {
        $sentinel = Join-Path $script:HarnessRoot 'preserved.txt'
        [IO.File]::WriteAllText($sentinel, 'preserve')
        $forged = [pscustomobject]@{ Root = $script:HarnessRoot; Token = $fixture.Token }
        { Remove-LocalGitFixture -Fixture $forged } | Should -Throw '*unowned_fixture*'
        $owned = $fixture.Root
        Remove-LocalGitFixture -Fixture $fixture
        $fixture = $null
        Test-Path -LiteralPath $owned | Should -BeFalse
        [IO.File]::ReadAllText($sentinel) | Should -Be 'preserve'
    }

    It 'denies nonlocal or unregistered Git destination <Destination>' -ForEach @(
        @{ Destination = 'https://example.invalid/repo.git' }, @{ Destination = 'ssh://example.invalid/repo' },
        @{ Destination = 'git@example.invalid:repo.git' }, @{ Destination = '\\server\share\repo' },
        @{ Destination = 'file:///C:/not-owned/repo' }, @{ Destination = 'origin' },
        @{ Destination = 'ext::arbitrary-command' }
    ) {
        { Invoke-LocalGit $fixture $fixture.Origin @('push', $Destination, 'HEAD:refs/heads/nope') } |
            Should -Throw '*local_git_denied*'
    }

    It 'denies overriding safe Git flags and accessing caller repositories' {
        { Invoke-LocalGit $fixture $fixture.Origin @('-c', 'protocol.https.allow=always', 'fetch', 'https://example.invalid') } |
            Should -Throw '*local_git_denied*'
        { Invoke-LocalGit $fixture $PSScriptRoot @('status') } | Should -Throw '*local_git_denied*'
        { Invoke-LocalGit $fixture $fixture.Origin @('fetch', '--upload-pack=arbitrary', $fixture.Origin) } |
            Should -Throw '*local_git_denied*'
        { Invoke-LocalGit $fixture $fixture.Origin @('config', 'url.https://example.invalid/.insteadOf', $fixture.Origin) } |
            Should -Throw '*local_git_denied*'
    }

    It 'does not trust a mutated repository allowlist or local config includes' {
        $null = $fixture.Repositories.Add($PSScriptRoot)
        { Invoke-LocalGit $fixture $PSScriptRoot @('status') } | Should -Throw '*local_git_denied*'
        $config = Join-Path $fixture.Origin '.git\config'
        [IO.File]::AppendAllText($config, "[include]`n    path = caller.gitconfig`n")
        { Invoke-LocalGit $fixture $fixture.Origin @('status') } | Should -Throw '*local_git_denied*'
    }

    It 'sanitizes child environment without mutating parent tokens or Git overrides' {
        $names = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GH_TOKEN', 'GITHUB_TOKEN', 'GIT_SSH_COMMAND')
        $saved = @{}
        try {
            foreach ($name in $names) {
                $saved[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, 'untrusted-fixture-value')
            }
            $environment = New-LocalGitEnvironment -Fixture $fixture
            foreach ($name in $names) { $environment.ContainsKey($name) | Should -BeFalse }
            $environment.GIT_ALLOW_PROTOCOL | Should -Be 'file'
            $environment.GIT_CONFIG_NOSYSTEM | Should -Be '1'
            $environment.GIT_TERMINAL_PROMPT | Should -Be '0'
            Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'HEAD') | Should -Be $fixture.Source
            $env:GH_TOKEN | Should -Be 'untrusted-fixture-value'
        }
        finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }

    It 'ignores caller credential configuration and hooks' {
        $null = [IO.Directory]::CreateDirectory((Join-Path $fixture.Origin '.git\hooks'))
        [IO.File]::WriteAllText((Join-Path $fixture.Origin '.git\hooks\pre-commit'), "#!/bin/sh`nexit 91`n")
        $oldConfig = $env:GIT_CONFIG_GLOBAL
        try {
            $badConfig = Join-Path $fixture.Root 'caller.gitconfig'
            [IO.File]::WriteAllText($badConfig, "[alias]`n    status = !exit 92`n[credential]`n    helper = !exit 93`n")
            $env:GIT_CONFIG_GLOBAL = $badConfig
            $null = Invoke-LocalGit $fixture $fixture.Origin @('commit', '--allow-empty', '-m', 'safe commit')
            Invoke-LocalGit $fixture $fixture.Origin @('log', '-1', '--format=%s') | Should -Be 'safe commit'
        }
        finally { $env:GIT_CONFIG_GLOBAL = $oldConfig }
    }
}

Describe 'Production I/O seam regression contracts' -Tag 'EPIC-002' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Initialize-BackportTransportTestTypes
        Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force
    }

    It 'preserves Git stdout bytes and rejects a nonzero native result through a private seam' -Tag 'TEST-015' {
        InModuleScope Backport -Parameters @{ TestWorkingDirectory = $PSScriptRoot } {
            (Get-Command Invoke-BackportGit).Parameters.ContainsKey('WorkingDirectory') | Should -BeTrue
            Mock New-BackportGitStartInfo { [Diagnostics.ProcessStartInfo]::new() }
            Mock Invoke-BackportProcess {
                [pscustomobject]@{ exit_code = 0; stdout = [byte[]]@(0, 13, 10, 255) }
            }
            $result = Invoke-BackportGit -Config @{ dry_run = $true } -WorkingDirectory $TestWorkingDirectory -Arguments @('status')
            $result.exit_code | Should -Be 0
            $result.stdout.GetType() | Should -Be ([byte[]])
            [Convert]::ToHexString($result.stdout) | Should -BeExactly '000D0AFF'
            Should -Invoke Invoke-BackportProcess -Times 1 -Exactly
            Should -Invoke New-BackportGitStartInfo -Times 1 -Exactly -ParameterFilter {
                $WorkingDirectory -ceq $TestWorkingDirectory
            }
            Mock Invoke-BackportProcess {
                [pscustomobject]@{
                    exit_code = 1; stdout = [byte[]]@()
                    stderr = [Text.Encoding]::UTF8.GetBytes('sentinel-transport-secret')
                }
            }
            $caught = $null
            try {
                $null = Invoke-BackportGit -Config @{ dry_run = $true } -WorkingDirectory $TestWorkingDirectory -Arguments @('status')
            }
            catch { $caught = $_ }
            $caught.Exception.Message | Should -BeExactly 'git_operation_failed'
            ($caught | Out-String) | Should -Not -Match 'sentinel-transport-secret'
        }
    }

    It 'classifies a lost POST response without retrying through a private HTTP seam' -Tag 'TEST-016' {
        $oldToken = [Environment]::GetEnvironmentVariable('GH_TOKEN')
        try {
            [Environment]::SetEnvironmentVariable('GH_TOKEN', 'sentinel-transport-secret')
            InModuleScope Backport {
                $handler = [Backport.Tests.HttpHandler]::new()
                $handler.Mode = 'throw'
                Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
                Mock Invoke-WebRequest { throw 'network_forbidden' }
                Mock Invoke-RestMethod { throw 'network_forbidden' }
                { Invoke-BackportHttp -Config @{ dry_run = $false } -Method POST -Path '/repos/AleksanderGladkov/BCApps-Backport-Test/issues' -Data @{ title = 'once' } } |
                    Should -Throw -ExpectedMessage 'api_write_ambiguous'
                $handler.Calls | Should -Be 1
                $handler.Disposed | Should -BeTrue
                Should -Invoke New-BackportHttpClient -Times 1 -Exactly
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            }
        }
        finally { [Environment]::SetEnvironmentVariable('GH_TOKEN', $oldToken) }
    }
}

Describe 'Pinned Unicode and Git-path compatibility' -Tag 'EPIC-002', 'TEST-014' {
    BeforeAll {
        $script:PathModule = Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force -PassThru
        $script:PathProfile = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'compat.json') -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
        $script:PathFixtureRoot = Join-Path $PSScriptRoot ('.path-fixtures-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:PathFixtureRoot

        function Invoke-PathSubject {
            param([string]$Name, [hashtable]$Arguments = @{})
            & $script:PathModule {
                param($FunctionName, $FunctionArguments)
                & $FunctionName @FunctionArguments
            } $Name $Arguments
        }

        function New-PathRawFixture {
            param(
                [string]$Path = 'src/one.al',
                [string]$Header = (':100644 100644 ' + ('1' * 40) + ' ' + ('2' * 40) + ' M'),
                [AllowNull()][byte[]]$Filename
            )
            if ($null -eq $Filename) { $Filename = [Text.Encoding]::UTF8.GetBytes($Path) }
            [byte[]]$prefix = [Text.Encoding]::UTF8.GetBytes($Header)
            [byte[]]$result = [byte[]]::new($prefix.Length + $Filename.Length + 2)
            [Array]::Copy($prefix, $result, $prefix.Length)
            [Array]::Copy($Filename, 0, $result, $prefix.Length + 1, $Filename.Length)
            return ,$result
        }

        function New-PathResourceFixture {
            $directory = Join-Path $script:PathFixtureRoot ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $directory
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Backport.psm1') -Destination (Join-Path $directory 'PathFixture.psm1')
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'compat.json') -Destination (Join-Path $directory 'compat.json')
            return $directory
        }
    }

    AfterAll {
        if ($script:PathFixtureRoot -and (Test-Path -LiteralPath $script:PathFixtureRoot)) {
            Remove-Item -LiteralPath $script:PathFixtureRoot -Recurse -Force
        }
    }

    It 'loads the exact pinned profile and reuses its verified lookup' -Tag 'TEST-020' {
        $compat = Invoke-PathSubject 'Get-BackportCompatibility'
        $again = Invoke-PathSubject 'Get-BackportCompatibility'
        [object]::ReferenceEquals($compat, $again) | Should -BeTrue
        $compat.Profile.schema | Should -Be 1
        $compat.Profile.provenance.python_version | Should -BeExactly '3.13'
        $compat.Profile.provenance.unicode_version | Should -BeExactly '15.1.0'
        $compat.Profile.provenance.generator | Should -BeExactly 'Export-PythonBaseline.py'
        $compat.Profile.provenance.normalization | Should -BeExactly 'none'
        $compat.Profile.license.id | Should -BeExactly 'Unicode-3.0'
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'compat.json')).Replace("`r`n", "`n")
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))) |
            Should -BeExactly 'E3A963A3B19822B287A62A89A0F28AB2EEE28CD334439B98E50218BF1B7AD2E3'
    }

    It 'accepts only the pinned LF and Git CRLF checkout variants' -Tag 'TEST-020' {
        $canonical = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'compat.json')).Replace("`r`n", "`n")
        foreach ($ending in @("`n", "`r`n")) {
            $directory = New-PathResourceFixture
            $resource = Join-Path $directory 'compat.json'
            [IO.File]::WriteAllText($resource, $canonical.Replace("`n", $ending), [Text.UTF8Encoding]::new($false))
            $module = Import-Module (Join-Path $directory 'PathFixture.psm1') -Force -PassThru -Prefix PathFixture
            try {
                (& $module { Get-BackportCompatibility }).Profile.provenance.unicode_version | Should -BeExactly '15.1.0'
            }
            finally { Remove-Module -ModuleInfo $module }
        }
        $directory = New-PathResourceFixture
        $resource = Join-Path $directory 'compat.json'
        $firstLine = $canonical.IndexOf("`n")
        [IO.File]::WriteAllText($resource, $canonical.Insert($firstLine, "`r"), [Text.UTF8Encoding]::new($false))
        $module = Import-Module (Join-Path $directory 'PathFixture.psm1') -Force -PassThru -Prefix PathFixture
        try {
            { & $module { Get-BackportCompatibility } } | Should -Throw -ExpectedMessage 'invalid_compatibility_data'
        }
        finally { Remove-Module -ModuleInfo $module }
    }

    It 'does not read the resource during import and loads only its adjacent resource lazily' -Tag 'TEST-020' {
        $directory = New-PathResourceFixture
        Remove-Item -LiteralPath (Join-Path $directory 'compat.json')
        $module = $null
        try {
            $module = Import-Module (Join-Path $directory 'PathFixture.psm1') -Force -PassThru -Prefix PathFixture
            $module | Should -Not -BeNullOrEmpty
            { & $module { Get-BackportCompatibility } } | Should -Throw -ExpectedMessage '*invalid_compatibility_data*'
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'compat.json') -Destination (Join-Path $directory 'compat.json')
            (& $module { Get-BackportCompatibility }).Profile.provenance.unicode_version | Should -BeExactly '15.1.0'
        }
        finally {
            if ($module) { Remove-Module -ModuleInfo $module }
        }
    }

    It 'rejects resource byte or provenance changes without echoing their contents' -Tag 'TEST-020' {
        foreach ($mutation in @('bytes', 'provenance', 'malformed')) {
            $directory = New-PathResourceFixture
            $resource = Join-Path $directory 'compat.json'
            $text = [IO.File]::ReadAllText($resource)
            switch ($mutation) {
                bytes { $text += ' ' }
                provenance { $text = $text.Replace('15.1.0', '99.9.9') }
                malformed { $text = '{"sentinel-secret-do-not-log":' }
            }
            [IO.File]::WriteAllText($resource, $text, [Text.UTF8Encoding]::new($false))
            $module = Import-Module (Join-Path $directory 'PathFixture.psm1') -Force -PassThru -Prefix PathFixture
            try {
                { & $module { Get-BackportCompatibility } } | Should -Throw -ExpectedMessage '*invalid_compatibility_data*'
                try { & $module { Get-BackportCompatibility }; throw 'expected_rejection' }
                catch { $_.Exception.Message | Should -BeExactly 'invalid_compatibility_data' }
            }
            finally { Remove-Module -ModuleInfo $module }
        }
    }

    It 'consumes every full-fold mapping as a scalar-aware batch without normalization' {
        $inputText = [Text.StringBuilder]::new()
        $expected = [Text.StringBuilder]::new()
        foreach ($entry in $script:PathProfile.case_folds) {
            $null = $inputText.Append([char]::ConvertFromUtf32([int]$entry[0])).Append('|')
            $null = $expected.Append([string]$entry[1]).Append('|')
        }
        $actual = Invoke-PathSubject 'ConvertTo-BackportCaseFold' @{ Value = $inputText.ToString() }
        $actual | Should -BeExactly $expected.ToString()
        (Invoke-PathSubject 'ConvertTo-BackportCaseFold' @{ Value = '' }) | Should -BeExactly ''
        (Invoke-PathSubject 'ConvertTo-BackportCaseFold' @{ Value = "I`u{130}`u{131}" }) | Should -BeExactly "ii`u{307}`u{131}"
        (Invoke-PathSubject 'ConvertTo-BackportCaseFold' @{ Value = "é|e`u{301}|`u{1F600}" }) |
            Should -BeExactly "é|e`u{301}|`u{1F600}"
    }

    It 'matches all category-C ranges and all whitespace points across the entire pinned domain' {
        $compat = Invoke-PathSubject 'Get-BackportCompatibility'
        $compat.CategoryC.Length | Should -Be 0x110000
        [byte[]]$expectedBits = [byte[]]::new(0x110000 / 8)
        foreach ($range in $script:PathProfile.category_c_ranges) {
            $first = [int]$range[0] -shr 3
            $last = [int]$range[1] -shr 3
            $startBit = [int]$range[0] -band 7
            $endBit = [int]$range[1] -band 7
            if ($first -eq $last) {
                $expectedBits[$first] = $expectedBits[$first] -bor (((1 -shl ($endBit - $startBit + 1)) - 1) -shl $startBit)
            }
            else {
                $expectedBits[$first] = $expectedBits[$first] -bor ((255 -shl $startBit) -band 255)
                $expectedBits[$last] = $expectedBits[$last] -bor ((1 -shl ($endBit + 1)) - 1)
                if ($last - $first -gt 1) { [Array]::Fill[byte]($expectedBits, [byte]255, $first + 1, $last - $first - 1) }
            }
        }
        [byte[]]$actualBits = [byte[]]::new($expectedBits.Length)
        $compat.CategoryC.CopyTo($actualBits, 0)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actualBits)) |
            Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expectedBits)))
        $compat.CaseFolds.Count | Should -Be $script:PathProfile.case_folds.Count
        foreach ($entry in $script:PathProfile.case_folds) {
            $compat.CaseFolds[[int]$entry[0]] | Should -BeExactly ([string]$entry[1])
        }
        $compat.Whitespace.Count | Should -Be $script:PathProfile.whitespace.Count
        $compat.WhitespaceCharacters.Length | Should -Be $script:PathProfile.whitespace.Count
        foreach ($point in $script:PathProfile.whitespace) {
            $compat.Whitespace.Contains([int]$point) | Should -BeTrue
            $compat.WhitespaceCharacters.Contains([char]$point) | Should -BeTrue
            (Invoke-PathSubject 'Test-BackportWhitespace' @{ Value = ('a' + [char]::ConvertFromUtf32([int]$point) + 'b') }) |
                Should -BeTrue
        }
        (Invoke-PathSubject 'Test-BackportWhitespace' @{ Value = '' }) | Should -BeFalse
        (Invoke-PathSubject 'Test-BackportWhitespace' @{ Value = "x`u{180E}`u{200B}`u{FEFF}`u{1F600}" }) | Should -BeFalse
    }

    It 'rejects each category-C range boundary and allows each adjacent non-C scalar when path syntax permits' {
        $compat = Invoke-PathSubject 'Get-BackportCompatibility'
        foreach ($range in $script:PathProfile.category_c_ranges) {
            foreach ($point in @([int]$range[0], [int]$range[1])) {
                $character = if ($point -ge 0xd800 -and $point -le 0xdfff) { [string][char]$point }
                else { [char]::ConvertFromUtf32($point) }
                { Invoke-PathSubject 'Assert-BackportPath' @{ Value = ('src/a' + $character + 'b.al') } } |
                    Should -Throw -ExpectedMessage '*invalid_path*'
            }
            foreach ($point in @(([int]$range[0] - 1), ([int]$range[1] + 1))) {
                if ($point -lt 0 -or $point -gt 0x10ffff -or $compat.CategoryC[$point]) { continue }
                $character = [char]::ConvertFromUtf32($point)
                if ('/\:<>"|?*'.Contains($character, [StringComparison]::Ordinal)) { continue }
                $path = 'src/a' + $character + 'b.al'
                (Invoke-PathSubject 'Assert-BackportPath' @{ Value = $path }) | Should -BeExactly $path
            }
        }
    }

    It 'preserves allowed Unicode paths including supplementary scalars and Python lower and regex edge cases' {
        foreach ($path in @(
            'src/one.al', 'src/é.al', "src/e`u{301}.al", "src/`u{1F600}.al", "src/`u{2EBF0}.al",
            "src/`u{10400}.al", "src/`u{212A}`u{17F}`u{131}.al", "src/.g`u{130}t/config.al",
            "src/.g`u{131}t/config.al", 'src/.gi/config.al', 'src/COM0.al', 'src/com10.al',
            'src/lpt0.al', 'src/conx.al', 'src/ＣＯＮ.al', 'src/com¹.al', "src/a`u{A0}.al",
            'src/ spaced name/one.al', 'src/one..al', 'src/.al'
        )) {
            (Invoke-PathSubject 'Assert-BackportPath' @{ Value = $path }) | Should -BeExactly $path
        }
    }

    It 'rejects path escapes, reserved device stems, forbidden punctuation and exact-case violations' {
        foreach ($path in @(
            $null, 123, @('src/one.al'), '', '/src/one.al', 'Src/one.al', 'src/one.AL',
            'src/../one.al', 'src/./one.al', 'src//one.al', 'src/a /one.al', 'src/a./one.al',
            'src/.git/one.al', 'src/.GITignore.al', 'src/.gItmodules/one.al',
            'src/CON.al', 'src/prn.al', 'src/AuX.al', 'src/nul.al', 'src/com1.al', 'src/LPT9.al',
            'src/CoM1.more.al', 'src/con/one.al', 'src/one.al/', "src/one.al`n", "src/a`nb.al",
            'src\a.al', 'src/a:b.al', 'src/a<b.al', 'src/a>b.al', 'src/a"b.al',
            'src/a|b.al', 'src/a?b.al', 'src/a*b.al', "src/`u{E000}.al", "src/`u{10FFFF}.al",
            ('src/' + [char]0xd800 + '.al'), ('src/' + [char]0xdc00 + '.al')
        )) {
            { Invoke-PathSubject 'Assert-BackportPath' @{ Value = $path } } |
                Should -Throw -ExpectedMessage '*invalid_path*'
        }
    }

    It 'is ordinal and culture-independent for Turkish, English and Greek current cultures' {
        $original = [Globalization.CultureInfo]::CurrentCulture
        $originalUi = [Globalization.CultureInfo]::CurrentUICulture
        try {
            foreach ($name in @('tr-TR', 'en-US', 'el-GR')) {
                [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($name)
                [Globalization.CultureInfo]::CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo($name)
                (Invoke-PathSubject 'ConvertTo-BackportCaseFold' @{ Value = "IİıΣςß`u{10400}" }) |
                    Should -BeExactly "ii`u{307}ıσσss`u{10428}"
                (Invoke-PathSubject 'Assert-BackportPath' @{ Value = 'src/İ.al' }) | Should -BeExactly 'src/İ.al'
                { Invoke-PathSubject 'Assert-BackportPath' @{ Value = 'SRC/one.al' } } | Should -Throw
                { Invoke-PathSubject 'Assert-BackportPath' @{ Value = 'src/.GIT/one.al' } } | Should -Throw
                [byte[]]$raw = (New-PathRawFixture -Path 'src/I.al') + (New-PathRawFixture -Path 'src/i.al')
                { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                    Should -Throw -ExpectedMessage '*ambiguous_paths*'
            }
        }
        finally {
            [Globalization.CultureInfo]::CurrentCulture = $original
            [Globalization.CultureInfo]::CurrentUICulture = $originalUi
        }
    }

    It 'returns exact byte-stream records without unrolling empty or singleton arrays' {
        $empty = Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = [byte[]]::new(0) }
        ($empty -is [object[]]) | Should -BeTrue
        $empty.Count | Should -Be 0
        $one = Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = (New-PathRawFixture -Path 'src/é.al') }
        ($one -is [object[]]) | Should -BeTrue
        $one.Count | Should -Be 1
        $one[0].path | Should -BeExactly 'src/é.al'
        $one[0].old_mode | Should -BeExactly '100644'
        $one[0].new_mode | Should -BeExactly '100644'
        $one[0].old_id | Should -BeExactly ('1' * 40)
        $one[0].new_id | Should -BeExactly ('2' * 40)
        $one[0].status | Should -BeExactly 'M'
        ($one[0].PSObject.Properties.Name -join ',') | Should -BeExactly 'path,old_mode,new_mode,old_id,new_id,status'
        [byte[]]$raw = (New-PathRawFixture -Path 'src/old.al' -Header (':100644 000000 ' + ('1' * 40) + ' ' + ('0' * 40) + ' D')) +
            (New-PathRawFixture -Path 'src/new.al' -Header (':000000 100644 ' + ('0' * 40) + ' ' + ('2' * 40) + ' A'))
        $records = Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw }
        $records.Count | Should -Be 2
        $records[0].status | Should -BeExactly 'D'
        $records[1].status | Should -BeExactly 'A'
    }

    It 'rejects malformed raw framing and absolute-end or non-ASCII header violations' {
        $header = ':100644 100644 ' + ('1' * 40) + ' ' + ('2' * 40) + ' M'
        foreach ($badHeader in @(
            '', ($header + "`n"), ("`n" + $header), ($header + ' '),
            $header.Replace('100644', '１００６４４'), $header.Replace('100644', '10064'),
            $header.Replace(('1' * 40), ('A' * 40)), $header.Replace(('1' * 40), ('1' * 39)),
            $header.Replace(' M', ' R'), $header.Replace(' M', ' M100'), $header.Replace(' M', ' m'),
            $header.Replace(' M', ' C'), $header.Replace(' M', ' T'), $header.Replace(' M', ' U')
        )) {
            [byte[]]$raw = New-PathRawFixture -Header $badHeader
            { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                Should -Throw -ExpectedMessage '*invalid_diff*'
        }
        [byte[]]$valid = New-PathRawFixture
        foreach ($raw in @(
            [byte[]]@(0), [byte[]]$valid[0..($valid.Length - 2)],
            [Text.Encoding]::UTF8.GetBytes($header + [char]0),
            [byte[]]($valid + [byte]0), [byte[]]($valid + [byte]120)
        )) {
            { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                Should -Throw -ExpectedMessage '*invalid_diff*'
        }
    }

    It 'rejects unsafe modes and every inconsistent zero-mode, zero-id and status combination' {
        foreach ($mode in @('100755', '120000', '160000', '040000')) {
            foreach ($side in @('old', 'new')) {
                $oldMode = if ($side -ceq 'old') { $mode } else { '100644' }
                $newMode = if ($side -ceq 'new') { $mode } else { '100644' }
                [byte[]]$raw = New-PathRawFixture -Header (":$oldMode $newMode " + ('1' * 40) + ' ' + ('2' * 40) + ' M')
                { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                    Should -Throw -ExpectedMessage '*unsafe_mode*'
            }
        }
        foreach ($oldZero in @($false, $true)) {
            foreach ($newZero in @($false, $true)) {
                foreach ($oldIdZero in @($false, $true)) {
                    foreach ($newIdZero in @($false, $true)) {
                        foreach ($status in @('A', 'M', 'D')) {
                            $oldMode = if ($oldZero) { '000000' } else { '100644' }
                            $newMode = if ($newZero) { '000000' } else { '100644' }
                            $oldId = if ($oldIdZero) { '0' * 40 } else { '1' * 40 }
                            $newId = if ($newIdZero) { '0' * 40 } else { '2' * 40 }
                            [byte[]]$raw = New-PathRawFixture -Header ":$oldMode $newMode $oldId $newId $status"
                            $valid = ($oldZero -eq $oldIdZero) -and ($oldZero -eq ($status -ceq 'A')) -and
                                ($newZero -eq $newIdZero) -and ($newZero -eq ($status -ceq 'D'))
                            if ($valid) { (Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw }).Count | Should -Be 1 }
                            else {
                                { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                                    Should -Throw -ExpectedMessage '*invalid_diff*'
                            }
                        }
                    }
                }
            }
        }
    }

    It 'strictly decodes filenames and rejects overlong, surrogate, truncated and out-of-range UTF-8' {
        foreach ($invalid in @(
            [byte[]]@(0xc0, 0xaf), [byte[]]@(0xe0, 0x80, 0xaf), [byte[]]@(0xf0, 0x80, 0x80, 0xaf),
            [byte[]]@(0xed, 0xa0, 0x80), [byte[]]@(0xed, 0xbf, 0xbf), [byte[]]@(0xc2),
            [byte[]]@(0xe2, 0x82), [byte[]]@(0xf0, 0x9f, 0x98), [byte[]]@(0x80),
            [byte[]]@(0xff), [byte[]]@(0xf4, 0x90, 0x80, 0x80), [byte[]]@(0xe2, 0x28, 0xa1)
        )) {
            [byte[]]$filename = [Text.Encoding]::UTF8.GetBytes('src/a') + $invalid + [Text.Encoding]::UTF8.GetBytes('.al')
            [byte[]]$raw = New-PathRawFixture -Filename $filename
            { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                Should -Throw -ExpectedMessage '*invalid_path*'
        }
        foreach ($path in @('src/../one.al', 'src/a\one.al', 'src/.git/config.al', "src/a`u{FEFF}.al")) {
            [byte[]]$raw = New-PathRawFixture -Path $path
            { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                Should -Throw -ExpectedMessage '*invalid_path*'
        }
    }

    It 'rejects full-fold collisions but does not normalize or apply culture-dependent equivalences' {
        foreach ($pair in @(
            @('src/ß.al', 'src/ss.al'), @('src/Σ.al', 'src/ς.al'), @('src/ς.al', 'src/σ.al'),
            @("src/`u{10400}.al", "src/`u{10428}.al"), @('src/K.al', 'src/k.al'),
            @('src/ſ.al', 'src/s.al'), @('src/ﬃ.al', 'src/ffi.al'),
            @('src/İ.al', "src/i`u{307}.al"), @('src/one.al', 'src/one.al')
        )) {
            [byte[]]$raw = (New-PathRawFixture -Path $pair[0]) + (New-PathRawFixture -Path $pair[1])
            { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw } } |
                Should -Throw -ExpectedMessage '*ambiguous_paths*'
        }
        foreach ($pair in @(@('src/é.al', "src/e`u{301}.al"), @('src/I.al', 'src/ı.al'), @('src/i.al', 'src/İ.al'))) {
            [byte[]]$raw = (New-PathRawFixture -Path $pair[0]) + (New-PathRawFixture -Path $pair[1])
            (Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $raw }).Count | Should -Be 2
        }
    }

    It 'accepts 50 changes and rejects 51 before collision checking' {
        $stream = [IO.MemoryStream]::new()
        try {
            for ($i = 0; $i -lt 50; $i++) {
                [byte[]]$entry = New-PathRawFixture -Path "src/file$i.al"
                $stream.Write($entry, 0, $entry.Length)
            }
            (Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $stream.ToArray() }).Count | Should -Be 50
            [byte[]]$entry = New-PathRawFixture -Path 'src/file0.al'
            $stream.Write($entry, 0, $entry.Length)
            { Invoke-PathSubject 'ConvertFrom-BackportRawDiff' @{ Bytes = $stream.ToArray() } } |
                Should -Throw -ExpectedMessage '*too_many_files*'
        }
        finally { $stream.Dispose() }
    }

    It 'preserves empty and boundary-sized blob bytes and rejects overflow or any NUL' {
        foreach ($length in @(0, 1, 1MB)) {
            [byte[]]$bytes = [byte[]]::new($length)
            [Array]::Fill[byte]($bytes, [byte]0xff)
            $actual = Invoke-PathSubject 'Assert-BackportBlob' @{ Bytes = $bytes }
            ($actual -is [byte[]]) | Should -BeTrue
            [object]::ReferenceEquals($actual, $bytes) | Should -BeTrue
        }
        { Invoke-PathSubject 'Assert-BackportBlob' @{ Bytes = [byte[]]::new(1MB + 1) } } |
            Should -Throw -ExpectedMessage '*file_too_large*'
        foreach ($offset in @(0, 511, 1023)) {
            [byte[]]$bytes = [byte[]]::new(1024)
            [Array]::Fill[byte]($bytes, [byte]65)
            $bytes[$offset] = 0
            { Invoke-PathSubject 'Assert-BackportBlob' @{ Bytes = $bytes } } |
                Should -Throw -ExpectedMessage '*binary_file*'
        }
    }

    It 'preserves patch bytes including NUL and enforces the exact five MiB bound' {
        foreach ($length in @(0, 1, 5MB)) {
            [byte[]]$bytes = [byte[]]::new($length)
            $actual = Invoke-PathSubject 'Assert-BackportPatch' @{ Bytes = $bytes }
            ($actual -is [byte[]]) | Should -BeTrue
            [object]::ReferenceEquals($actual, $bytes) | Should -BeTrue
        }
        { Invoke-PathSubject 'Assert-BackportPatch' @{ Bytes = [byte[]]::new(5MB + 1) } } |
            Should -Throw -ExpectedMessage '*patch_too_large*'
    }
}

Describe 'Private Git process adapter' -Tag 'EPIC-002', 'TEST-015', 'TEST-020' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force
        $script:IoRoot = Join-Path $PSScriptRoot ('io-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = [IO.Directory]::CreateDirectory($script:IoRoot)
        $script:IoGit = New-LocalGitFixture -ParentPath $script:IoRoot
        $script:IoProcess = New-BackportProcessFixture -ParentPath $script:IoRoot
    }
    AfterAll {
        if ($script:IoGit) { Remove-LocalGitFixture $script:IoGit }
        if ($script:IoRoot -and (Test-Path -LiteralPath $script:IoRoot)) {
            Remove-Item -LiteralPath $script:IoRoot -Recurse -Force
        }
    }
    BeforeEach {
        $script:IoSavedEnvironment = @{}
        foreach ($key in @('GH_TOKEN', 'GITHUB_TOKEN', 'GIT_DIR', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')) {
            $script:IoSavedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, 'sentinel-transport-secret')
        }
    }
    AfterEach {
        foreach ($entry in $script:IoSavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }

    It 'retains every baseline isolation override only in the child environment' {
        $gitCandidates = @(
            [pscustomobject]@{ Source = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source }
            [pscustomobject]@{ Source = (Join-Path $script:IoRoot 'missing/git.exe') }
        )
        Mock Get-Command { $gitCandidates } -ParameterFilter {
            $Name -ceq 'git' -and $CommandType -eq [Management.Automation.CommandTypes]::Application
        }
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; GitCandidates = $gitCandidates } {
            Mock Get-Command { $GitCandidates } -ParameterFilter {
                $Name -ceq 'git' -and $CommandType -eq [Management.Automation.CommandTypes]::Application
            }
            $info = New-BackportGitStartInfo -Config @{ dry_run = $false } -Directory $Directory -Arguments @('status', '--porcelain')
            $info.FileName | Should -BeExactly $GitCandidates[0].Source
            $info.UseShellExecute | Should -BeFalse
            $info.RedirectStandardInput | Should -BeTrue
            $info.RedirectStandardOutput | Should -BeTrue
            $info.RedirectStandardError | Should -BeTrue
            $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
            foreach ($pair in @{
                GIT_CONFIG_NOSYSTEM = '1'; GIT_CONFIG_GLOBAL = $nullDevice
                GIT_TERMINAL_PROMPT = '0'; GIT_ATTR_NOSYSTEM = '1'; LC_ALL = 'C'
            }.GetEnumerator()) { $info.Environment[$pair.Key] | Should -BeExactly $pair.Value }
            foreach ($key in @('GH_TOKEN', 'GITHUB_TOKEN', 'GIT_DIR', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')) {
                $info.Environment.ContainsKey($key) | Should -BeFalse
                [Environment]::GetEnvironmentVariable($key) | Should -BeExactly 'sentinel-transport-secret'
            }
            foreach ($override in @(
                'core.hooksPath=', 'protocol.file.allow=never', 'protocol.ext.allow=never',
                'http.followRedirects=false', 'submodule.recurse=false', 'core.fsmonitor=false',
                'core.quotePath=true', 'core.autocrlf=false', "core.attributesFile=$nullDevice",
                'core.longpaths=true', 'commit.gpgsign=false'
            )) { @($info.ArgumentList) | Should -Contain $override }
            @($info.ArgumentList) -join '|' | Should -Not -Match 'sentinel-transport-secret'
            (Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments @('status', '--porcelain')).exit_code |
                Should -Be 0
            Should -Invoke Get-Command -Times 2 -Exactly -ParameterFilter {
                $Name -ceq 'git' -and $CommandType -eq [Management.Automation.CommandTypes]::Application
            }
        }
        (Invoke-LocalGit $script:IoGit $script:IoGit.Origin @('status', '--porcelain')) | Should -BeExactly ''
        $copyExecutables = [Collections.Generic.List[string]]::new()
        Mock Invoke-HarnessProcess {
            $copyExecutables.Add($FileName)
            @{ ExitCode = 1 }
        } -ParameterFilter { $Arguments -contains 'fetch' }
        $stage = @{ Fixture = $script:IoGit }
        { Copy-StageFixtureRefs -Source $stage -Target $stage } | Should -Throw -ExpectedMessage 'fixture_ref_clone_failed'
        $copyExecutables.Count | Should -Be 1
        $copyExecutables[0] | Should -BeExactly $gitCandidates[0].Source
        Should -Invoke Get-Command -Times 2 -Exactly -ParameterFilter {
            $Name -ceq 'git' -and $CommandType -eq [Management.Automation.CommandTypes]::Application
        }
    }

    It 'sanitizes the child environment when an inherited <Shadow> key shadows dictionary properties' -ForEach @(
        @{ Shadow = 'Keys' }, @{ Shadow = 'Count' }
    ) {
        $old = [Environment]::GetEnvironmentVariable($Shadow)
        try {
            [Environment]::SetEnvironmentVariable($Shadow, 'ordinary-environment-value')
            InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Shadow = $Shadow } {
                $info = New-BackportGitStartInfo -Config @{ dry_run = $true } -WorkingDirectory $Directory -Arguments @('status')
                foreach ($key in @('GH_TOKEN', 'GITHUB_TOKEN', 'GIT_DIR', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')) {
                    $info.Environment.ContainsKey($key) | Should -BeFalse
                }
                $info.Environment[$Shadow] | Should -BeExactly 'ordinary-environment-value'
                [Environment]::GetEnvironmentVariable($Shadow) | Should -BeExactly 'ordinary-environment-value'
            }
        }
        finally { [Environment]::SetEnvironmentVariable($Shadow, $old) }
    }

    It 'round trips NUL LF CRLF and non-ASCII bytes through actual git object plumbing' {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin } {
            $bytes = [Text.Encoding]::UTF8.GetBytes("nul`0lf`ncrlf`r`ncafé 日本語")
            $written = Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments @('hash-object', '-w', '--stdin') -Data $bytes
            $written.exit_code | Should -Be 0
            $written.stdout.GetType() | Should -Be ([byte[]])
            $oid = [Text.Encoding]::ASCII.GetString($written.stdout).Trim()
            $oid | Should -Match '^[0-9a-f]{40}$'
            $read = Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments @('cat-file', 'blob', $oid)
            [Convert]::ToBase64String($read.stdout) | Should -BeExactly ([Convert]::ToBase64String($bytes))
            @($read.PSObject.Properties.Name) | Should -Be @('exit_code', 'stdout')
        }
    }

    It 'preserves empty space and shell-metacharacter ArgumentList values' {
        $values = @('', 'a b', '"; & | $() < > % !', '日本語')
        $info = New-BackportProcessFixtureStartInfo $script:IoProcess (@('args') + $values)
        InModuleScope Backport -Parameters @{ Info = $info; Values = $values } {
            $result = Invoke-BackportProcess -StartInfo $Info
            $result.exit_code | Should -Be 0
            $decoded = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($result.stdout)) -NoEnumerate
            $decoded | Should -Be $Values
        }
    }

    It 'drains pressured stdout and stderr while writing byte stdin without logging secrets' {
        $info = New-BackportProcessFixtureStartInfo $script:IoProcess @('pressure')
        InModuleScope Backport -Parameters @{ Info = $info } {
            $bytes = [byte[]]::new(3 * 1024 * 1024)
            for ($index = 0; $index -lt $bytes.Length; $index++) { $bytes[$index] = $index % 251 }
            $result = Invoke-BackportProcess -StartInfo $Info -Data $bytes
            $result.exit_code | Should -Be 0
            $result.stdout.Length | Should -Be (5 * 1024 * 1024)
            $result.stdout[0] | Should -Be 42
            $tail = [byte[]]::new($bytes.Length)
            [Array]::Copy($result.stdout, 2 * 1024 * 1024, $tail, 0, $tail.Length)
            [Convert]::ToBase64String($tail) | Should -BeExactly ([Convert]::ToBase64String($bytes))
            ($result | Out-String) | Should -Not -Match 'sentinel-transport-secret'
        }
    }

    It 'distinguishes expected ancestry exit one from unexpected failure' {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Old = $script:IoGit.Head; New = $script:IoGit.Target } {
            $args = @('merge-base', '--is-ancestor', $Old, $New)
            (Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments $args -ExpectedExitCodes @(0, 1)).exit_code | Should -Be 1
            { Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments $args } | Should -Throw -ExpectedMessage 'git_operation_failed'
            { Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments @('cat-file', 'blob', 'invalid') -ExpectedExitCodes @(0, 1) } | Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'returns a failing process code without returning its stderr' {
        $info = New-BackportProcessFixtureStartInfo $script:IoProcess @('exit', '23')
        InModuleScope Backport -Parameters @{ Info = $info } {
            $result = Invoke-BackportProcess -StartInfo $Info
            $result.exit_code | Should -Be 23
            $result.stdout.Length | Should -Be 0
            @($result.PSObject.Properties.Name) | Should -Be @('exit_code', 'stdout')
            ($result | Out-String) | Should -Not -Match 'sentinel-transport-secret'
        }
    }

    It 'preserves exit <Code> when the child closes stdin before reading all bytes' -ForEach @(
        @{ Code = 0 }, @{ Code = 1 }, @{ Code = 23 }
    ) {
        $info = New-BackportProcessFixtureStartInfo $script:IoProcess @('exit', [string]$Code)
        InModuleScope Backport -Parameters @{ Info = $info; Code = $Code } {
            $result = Invoke-BackportProcess -StartInfo $Info -Data ([byte[]]::new(2 * 1024 * 1024))
            $result.exit_code | Should -Be $Code
            $result.stdout.Length | Should -Be 0
            @($result.PSObject.Properties.Name) | Should -Be @('exit_code', 'stdout')

            if (-not ('BackportStdinCloseFaultStream' -as [type])) {
                Add-Type -TypeDefinition @'
public sealed class BackportStdinCloseFaultStream : System.IO.MemoryStream
{
    public override void Flush()
    {
        throw new System.IO.IOException("sentinel-transport-secret");
    }
}
'@
            }
            $stdin = [IO.StreamWriter]::new([BackportStdinCloseFaultStream]::new())
            $fake = [pscustomobject]@{
                StartInfo = $null; StandardInput = $stdin
                StandardOutput = [pscustomobject]@{ BaseStream = [IO.MemoryStream]::new() }
                StandardError = [pscustomobject]@{ BaseStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('sentinel-transport-secret')) }
                HasExited = $true; ExitCode = $Code; Disposed = $false; Starts = 0
            }
            $fake | Add-Member ScriptMethod Start { $this.Starts++; return $true }
            $fake | Add-Member ScriptMethod WaitForExitAsync {
                param($token)
                $token.ThrowIfCancellationRequested()
                return [Threading.Tasks.Task]::CompletedTask
            }
            $fake | Add-Member ScriptMethod Dispose {
                $this.StandardInput.BaseStream.Dispose()
                $this.StandardOutput.BaseStream.Dispose()
                $this.StandardError.BaseStream.Dispose()
                $this.Disposed = $true
            }
            Mock New-BackportProcess { $fake }
            $result = Invoke-BackportProcess -StartInfo $Info -Data ([byte[]]::new(1))
            $result.exit_code | Should -Be $Code
            $result.stdout.Length | Should -Be 0
            @($result.PSObject.Properties.Name) | Should -Be @('exit_code', 'stdout')
            ($result | Out-String) | Should -Not -Match 'sentinel-transport-secret'
            $fake.Starts | Should -Be 1
            $fake.Disposed | Should -BeTrue
            Should -Invoke New-BackportProcess -Times 1 -Exactly
        }
    }

    It 'uses a private 180 second deadline and kills only its owned process tree on expiry' {
        $pidFile = Join-Path $script:IoProcess.Root 'parent.pid'
        $childFile = Join-Path $script:IoProcess.Root 'child.pid'
        $info = New-BackportProcessFixtureStartInfo $script:IoProcess @('tree', $pidFile, $childFile)
        try {
            InModuleScope Backport -Parameters @{ Info = $info } {
                (Get-Command New-BackportGitDeadline).ScriptBlock.ToString() | Should -Match 'FromSeconds\(180\)'
                Mock New-BackportGitDeadline { [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(3)) }
                $watch = [Diagnostics.Stopwatch]::StartNew()
                { Invoke-BackportProcess -StartInfo $Info -Data ([byte[]]::new(2 * 1024 * 1024)) } | Should -Throw -ExpectedMessage 'git_operation_failed'
                $watch.Elapsed.TotalSeconds | Should -BeLessThan 12
            }
            foreach ($path in @($pidFile, $childFile)) {
                Test-Path -LiteralPath $path | Should -BeTrue
                $ownedPid = [int][IO.File]::ReadAllText($path)
                $ownedProcess = Get-Process -Id $ownedPid -ErrorAction SilentlyContinue
                if ($IsLinux -and $ownedProcess) {
                    $role = if ($path -eq $pidFile) { 'parent' } else { 'child' }
                    $state = 'unavailable'
                    try {
                        $status = [IO.File]::ReadAllText("/proc/$ownedPid/status")
                        $match = [regex]::Match($status, '(?m)^State:\s+([RSDZTtXxKWPIN])\s')
                        if ($match.Success) { $state = $match.Groups[1].Value }
                    }
                    catch [IO.IOException] { $state = 'unavailable' }
                    catch [UnauthorizedAccessException] { $state = 'unavailable' }
                    Write-Host "owned-process-state role=$role state=$state"
                }
                $ownedProcess | Should -BeNullOrEmpty
            }
            Get-Process -Id $PID | Should -Not -BeNullOrEmpty
        }
        finally {
            foreach ($path in @($pidFile, $childFile)) {
                if (Test-Path -LiteralPath $path) {
                    Stop-Process -Id ([int][IO.File]::ReadAllText($path)) -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It 'puts authentication only in the exact repository scoped child header for push' {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin } {
            $origin = 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git'
            $arguments = @('push', '--porcelain', $origin, '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7')
            $info = New-BackportGitStartInfo -Config @{ dry_run = $false; source_pr = 7 } -Directory $Directory -Arguments $arguments -Auth
            $info.Environment['GIT_CONFIG_COUNT'] | Should -BeExactly '1'
            $info.Environment['GIT_CONFIG_KEY_0'] | Should -BeExactly "http.$origin.extraHeader"
            $credential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:sentinel-transport-secret'))
            $info.Environment['GIT_CONFIG_VALUE_0'] | Should -BeExactly "Authorization: Basic $credential"
            @($info.ArgumentList) -join '|' | Should -Not -Match ([regex]::Escape($credential))
            $info.Environment.ContainsKey('GH_TOKEN') | Should -BeFalse
            { New-BackportGitStartInfo -Config @{ dry_run = $true } -Directory $Directory -Arguments $arguments -Auth } | Should -Throw -ExpectedMessage 'dry_run_write_blocked'
        }
    }

    It 'runs an authenticated push only through a test-only rewrite to its registered local fixture' {
        $directory = New-LocalGitWorkingCopy $script:IoGit
        InModuleScope Backport -Parameters @{ Directory = $directory; LocalOrigin = $script:IoGit.Origin } {
            $config = @{ dry_run = $false; source_pr = 7 }
            $null = Invoke-BackportGit -Config $config -Directory $Directory -Arguments @('checkout', '--detach', 'refs/remotes/demo/main')
            $original = (Get-Command New-BackportGitStartInfo).ScriptBlock
            Mock New-BackportGitStartInfo {
                $info = & $original -Config $Config -Directory $Directory -Arguments $Arguments -Auth:$Auth
                $fileIndex = $info.ArgumentList.IndexOf('protocol.file.allow=never')
                $originIndex = $info.ArgumentList.IndexOf('https://github.com/AleksanderGladkov/BCApps-Backport-Test.git')
                if ($fileIndex -lt 0 -or $originIndex -lt 0) { throw 'invalid_local_rewrite' }
                $info.ArgumentList[$fileIndex] = 'protocol.file.allow=always'
                $info.ArgumentList[$originIndex] = $LocalOrigin
                $info
            }
            $result = Invoke-BackportGit -Config $config -Directory $Directory -Auth -Arguments @(
                'push', '--porcelain', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
                '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7'
            )
            $result.exit_code | Should -Be 0
            ($result | Out-String) | Should -Not -Match 'sentinel-transport-secret'
            Should -Invoke New-BackportGitStartInfo -Times 1 -Exactly
        }
        (Invoke-LocalGit $script:IoGit $script:IoGit.Origin @('rev-parse', 'refs/heads/backport/29.x/pr-7')) | Should -BeExactly $script:IoGit.Source
    }

    It 'classifies lost push responses as ambiguous without retry and scrubs owned start information' {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin } {
            $captured = [Collections.Generic.List[object]]::new()
            Mock Invoke-BackportProcess {
                $captured.Add($StartInfo)
                throw 'sentinel-transport-secret'
            }
            $arguments = @(
                'push', '--porcelain', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
                '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7'
            )
            { Invoke-BackportGit -Config @{ dry_run = $false; source_pr = 7 } -Directory $Directory -Arguments $arguments -Auth } | Should -Throw -ExpectedMessage 'push_failed_or_ambiguous'
            Should -Invoke Invoke-BackportProcess -Times 1 -Exactly
            $captured[0].Environment.ContainsKey('GIT_CONFIG_VALUE_0') | Should -BeFalse
            { Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments $arguments -Auth } | Should -Throw -ExpectedMessage 'dry_run_write_blocked'
            Should -Invoke Invoke-BackportProcess -Times 1 -Exactly
        }
    }

    It 'never accepts a nonzero push exit through the expected-exit read seam' {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin } {
            Mock Invoke-BackportProcess { [pscustomobject]@{ exit_code = 1; stdout = [byte[]]::new(0) } }
            $arguments = @(
                'push', '--porcelain', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
                '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7'
            )
            { Invoke-BackportGit -Config @{ dry_run = $false; source_pr = 7 } -Directory $Directory -Arguments $arguments -Auth -ExpectedExitCodes @(0, 1) } |
                Should -Throw -ExpectedMessage 'push_failed_or_ambiguous'
            Should -Invoke Invoke-BackportProcess -Times 1 -Exactly
        }
    }

    It 'rejects <Case> transport/config bypass before starting git' -ForEach @(
        @{ Case = 'origin name'; GitArguments = @('push', '--porcelain', 'origin', 'HEAD:refs/heads/x'); Auth = $true }
        @{ Case = 'sibling repository'; GitArguments = @('push', '--porcelain', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test-evil.git', 'HEAD:refs/heads/x'); Auth = $true }
        @{ Case = 'local transport'; GitArguments = @('fetch', 'file:///fixture', 'main'); Auth = $false }
        @{ Case = 'config override'; GitArguments = @('-c', 'protocol.file.allow=always', 'status'); Auth = $false }
        @{ Case = 'remote override'; GitArguments = @('push', '--repo=https://example.invalid/a', 'HEAD'); Auth = $true }
        @{ Case = 'auth on read'; GitArguments = @('status'); Auth = $true }
        @{ Case = 'external textconv'; GitArguments = @('cat-file', '--textconv', 'HEAD:a'); Auth = $false }
        @{ Case = 'attached command config'; GitArguments = @('status', '-ccore.hooksPath=elsewhere'); Auth = $false }
        @{ Case = 'template override'; GitArguments = @('init', '--template=elsewhere'); Auth = $false }
    ) {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Values = $GitArguments; Authenticate = $Auth } {
            { New-BackportGitStartInfo -Config @{ dry_run = $false } -Directory $Directory -Arguments $Values -Auth:$Authenticate } | Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'rejects init <Case> that changes the owned repository boundary' -ForEach @(
        @{ Case = 'separate git directory'; Values = @('--separate-git-dir=elsewhere') }
        @{ Case = 'bare repository'; Values = @('--bare') }
        @{ Case = 'positional destination'; Values = @('elsewhere') }
        @{ Case = 'parent destination'; Values = @('..') }
        @{ Case = 'abbreviated template'; Values = @('--temp=elsewhere') }
    ) {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Values = $Values } {
            Mock Invoke-BackportProcess { throw 'process_must_not_start' }
            { Invoke-BackportGit -Config @{ dry_run = $true } -Directory $Directory -Arguments (@('init') + $Values) } |
                Should -Throw -ExpectedMessage 'git_operation_failed'
            Should -Invoke Invoke-BackportProcess -Times 0 -Exactly
        }
    }

    It 'reads a branch head with ls-remote only through a registered local-fixture rewrite' {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Expected = $script:IoGit.Source } {
            $original = (Get-Command New-BackportGitStartInfo).ScriptBlock
            $origin = 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git'
            $arguments = @('ls-remote', '--heads', $origin, 'refs/heads/main')
            $info = New-BackportGitStartInfo -Config @{ dry_run = $true } -WorkingDirectory $Directory -Arguments $arguments
            $info.Environment.ContainsKey('GIT_CONFIG_COUNT') | Should -BeFalse
            Mock New-BackportGitStartInfo {
                $info = & $original -Config $Config -WorkingDirectory $WorkingDirectory -Arguments $Arguments -Auth:$Auth
                $fileIndex = $info.ArgumentList.IndexOf('protocol.file.allow=never')
                $originIndex = $info.ArgumentList.IndexOf($origin)
                if ($fileIndex -lt 0 -or $originIndex -lt 0) { throw 'invalid_local_rewrite' }
                $info.ArgumentList[$fileIndex] = 'protocol.file.allow=always'
                $info.ArgumentList[$originIndex] = $Directory
                $info
            }
            $result = Invoke-BackportGit -Config @{ dry_run = $true } -WorkingDirectory $Directory -Arguments $arguments
            [Text.Encoding]::UTF8.GetString($result.stdout).TrimEnd("`r", "`n") | Should -BeExactly "$Expected`trefs/heads/main"
            Should -Invoke New-BackportGitStartInfo -Times 1 -Exactly
        }
    }

    It 'rejects invalid ls-remote <Case> before starting transport' -ForEach @(
        @{ Case = 'origin'; GitArguments = @('ls-remote', '--heads', 'origin', 'refs/heads/main') }
        @{ Case = 'sibling'; GitArguments = @('ls-remote', '--heads', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test-evil.git', 'refs/heads/main') }
        @{ Case = 'all refs'; GitArguments = @('ls-remote', '--refs', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git', 'refs/heads/main') }
        @{ Case = 'wildcard'; GitArguments = @('ls-remote', '--heads', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git', 'refs/heads/*') }
        @{ Case = 'trailing newline'; GitArguments = @('ls-remote', '--heads', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git', "refs/heads/main`n") }
    ) {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Values = $GitArguments } {
            { New-BackportGitStartInfo -Config @{ dry_run = $true } -WorkingDirectory $Directory -Arguments $Values } |
                Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'rejects newline-suffixed <Command> references instead of matching before LF' -ForEach @(
        @{ Command = 'push' }, @{ Command = 'fetch' }
    ) {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Command = $Command } {
            $origin = 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git'
            $arguments = if ($Command -eq 'push') {
                @('push', '--porcelain', $origin, "--force-with-lease=refs/heads/backport/29.x/pr-7:`n", 'HEAD:refs/heads/backport/29.x/pr-7')
            }
            else { @('fetch', '--no-tags', '--no-recurse-submodules', $origin, "+refs/heads/main:refs/remotes/demo/main`n") }
            { New-BackportGitStartInfo -Config @{ dry_run = $false; source_pr = 7 } -WorkingDirectory $Directory -Arguments $arguments -Auth:($Command -eq 'push') } |
                Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'denies a push to <Branch> outside the config-bound backport branch' -ForEach @(
        @{ Branch = 'main' }, @{ Branch = 'releases/29.x' }, @{ Branch = 'backport/29.x/pr-8' }, @{ Branch = 'backport/30.x/pr-7' }
    ) {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Branch = $Branch } {
            $arguments = @('push', '--porcelain', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
                "--force-with-lease=refs/heads/${Branch}:", "HEAD:refs/heads/$Branch")
            { New-BackportGitStartInfo -Config @{ dry_run = $false; source_pr = 7 } -WorkingDirectory $Directory -Arguments $arguments -Auth } |
                Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'denies authenticated push when source_pr is absent rather than choosing an arbitrary branch' {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin } {
            $arguments = @('push', '--porcelain', 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
                '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7')
            { New-BackportGitStartInfo -Config @{ dry_run = $false } -WorkingDirectory $Directory -Arguments $arguments -Auth } |
                Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'surfaces owned-process <Failure> cleanup failure as a fixed code' -ForEach @(
        @{ Failure = 'kill' }, @{ Failure = 'wait-timeout' }, @{ Failure = 'wait-throw' }
    ) {
        InModuleScope Backport -Parameters @{ Failure = $Failure } {
            $fake = [pscustomobject]@{ HasExited = $false; Failure = $Failure; KilledTree = $false; WaitMilliseconds = 0 }
            $fake | Add-Member ScriptMethod Kill {
                param($entireTree)
                $this.KilledTree = $entireTree
                if ($this.Failure -eq 'kill') { throw 'sentinel-transport-secret' }
            }
            $fake | Add-Member ScriptMethod WaitForExit {
                param($milliseconds)
                $this.WaitMilliseconds = $milliseconds
                if ($this.Failure -eq 'wait-throw') { throw 'sentinel-transport-secret' }
                return $false
            }
            { Stop-BackportOwnedProcess -Process $fake } | Should -Throw -ExpectedMessage 'git_operation_failed'
            $fake.KilledTree | Should -BeTrue
            if ($Failure -ne 'kill') { $fake.WaitMilliseconds | Should -Be 5000 }
        }
    }

    It 'disposes process and deadline after cleanup failure without publishing a partial result' {
        $info = New-BackportProcessFixtureStartInfo $script:IoProcess @('exit', '0')
        InModuleScope Backport -Parameters @{ Info = $info } {
            $owned = [Diagnostics.Process]::new()
            $ownedDeadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(20))
            $handles = [Collections.Generic.List[object]]::new()
            $published = [Collections.Generic.List[object]]::new()
            Mock New-BackportProcess { $owned }
            Mock New-BackportGitDeadline { $ownedDeadline }
            Mock Stop-BackportOwnedProcess {
                $handles.Add($Process.SafeHandle)
                throw 'sentinel-transport-secret'
            }
            { Invoke-BackportProcess -StartInfo $Info | ForEach-Object { $published.Add($_) } } |
                Should -Throw -ExpectedMessage 'git_operation_failed'
            $handles.Count | Should -Be 1
            $handles[0].IsClosed | Should -BeTrue
            $published.Count | Should -Be 0
            { $ownedDeadline.Cancel() } | Should -Throw
        }
    }

    It 'contains no silent cleanup catch blocks in the process or directory lifecycle' {
        InModuleScope Backport {
            foreach ($name in @('Invoke-BackportProcess', 'New-BackportGitWorkDirectory')) {
                $empty = (Get-Command $name).ScriptBlock.Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Body.Statements.Count -eq 0
                }, $true)
                @($empty).Count | Should -Be 0
            }
        }
    }

    It 'uses ordinal Git literal checks for <Case> with <SuffixName>' -ForEach @(
        foreach ($case in @(
            @{ Case = 'push command'; Kind = 'push'; Index = 0 }
            @{ Case = 'push origin'; Kind = 'push'; Index = 2 }
            @{ Case = 'push flag'; Kind = 'push'; Index = 1 }
            @{ Case = 'push HEAD ref'; Kind = 'push'; Index = 4 }
            @{ Case = 'config command'; Kind = 'config'; Index = 0 }
            @{ Case = 'config key'; Kind = 'config'; Index = 1 }
            @{ Case = 'config value'; Kind = 'config'; Index = 2 }
            @{ Case = 'fetch origin'; Kind = 'fetch'; Index = 3 }
            @{ Case = 'fetch no-tags'; Kind = 'fetch'; Index = 1 }
            @{ Case = 'fetch no-submodules'; Kind = 'fetch'; Index = 2 }
            @{ Case = 'ls-remote origin'; Kind = 'ls-remote'; Index = 2 }
            @{ Case = 'ls-remote flag'; Kind = 'ls-remote'; Index = 1 }
        )) {
            foreach ($suffix in @(@{ Name = 'soft hyphen'; Code = 0xAD }, @{ Name = 'NUL'; Code = 0 })) {
                @{ Case = $case.Case; Kind = $case.Kind; Index = $case.Index; SuffixName = $suffix.Name; Codepoint = $suffix.Code }
            }
        }
    ) {
        InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin; Kind = $Kind; Index = $Index; Codepoint = $Codepoint } {
            $origin = 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git'
            $arguments = switch ($Kind) {
                push { @('push', '--porcelain', $origin, '--force-with-lease=refs/heads/backport/29.x/pr-7:', 'HEAD:refs/heads/backport/29.x/pr-7') }
                config { @('config', 'core.autocrlf', 'false') }
                fetch { @('fetch', '--no-tags', '--no-recurse-submodules', $origin, '+refs/heads/main:refs/remotes/demo/main') }
                ls-remote { @('ls-remote', '--heads', $origin, 'refs/heads/main') }
            }
            $arguments[$Index] += [char]$Codepoint
            { New-BackportGitStartInfo -Config @{ dry_run = $false; source_pr = 7 } -WorkingDirectory $Directory -Arguments $arguments -Auth:($Kind -eq 'push') } |
                Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'rejects unsafe repository-local URL rewrites rather than trusting the origin spelling' {
        $path = Join-Path $script:IoGit.Origin '.git\config'
        $original = [IO.File]::ReadAllBytes($path)
        try {
            [IO.File]::AppendAllText($path, "`n[url `"https://example.invalid/`"]`n`t insteadOf = https://github.com/`n")
            InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin } {
                { New-BackportGitStartInfo -Config @{ dry_run = $false } -Directory $Directory -Arguments @('status') } | Should -Throw -ExpectedMessage 'git_operation_failed'
            }
        }
        finally { [IO.File]::WriteAllBytes($path, $original) }
    }

    It 'does not discover a parent repository when the requested directory has no owned git directory' {
        $directory = Join-Path $script:IoGit.Origin 'src'
        InModuleScope Backport -Parameters @{ Directory = $directory } {
            { New-BackportGitStartInfo -Config @{ dry_run = $false } -Directory $Directory -Arguments @('status') } | Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'rejects an alternate common git directory that could bypass local config inspection' {
        $path = Join-Path $script:IoGit.Origin '.git\commondir'
        try {
            [IO.File]::WriteAllText($path, 'elsewhere')
            InModuleScope Backport -Parameters @{ Directory = $script:IoGit.Origin } {
                { New-BackportGitStartInfo -Config @{ dry_run = $false } -Directory $Directory -Arguments @('status') } | Should -Throw -ExpectedMessage 'git_operation_failed'
            }
        }
        finally { Remove-Item -LiteralPath $path -Force }
    }

    It 'initializes and removes only an owned Git working directory with baseline identity' {
        InModuleScope Backport -Parameters @{ Parent = $script:IoRoot } {
            $config = @{ dry_run = $true; work_dir = (Join-Path $Parent 'owned-work') }
            $directory = New-BackportGitWorkDirectory -Config $config
            try {
                $directory.StartsWith($config.work_dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $directory '.git') | Should -BeTrue
                $raw = [IO.File]::ReadAllText((Join-Path $directory '.git\config'))
                $raw | Should -Match 'github-actions\[bot\]'
                $raw | Should -Match '41898282\+github-actions\[bot\]@users\.noreply\.github\.com'
                $raw | Should -Match 'autocrlf = false'
                $raw | Should -Match 'longpaths = true'
                $raw | Should -Match 'gpgsign = false'
                $status = Invoke-BackportGit -Config $config -Directory $directory -Arguments @('status', '--porcelain')
                $status.stdout.Length | Should -Be 0
                { Remove-BackportGitWorkDirectory -Directory $config.work_dir } | Should -Throw -ExpectedMessage 'git_operation_failed'
            }
            finally { Remove-BackportGitWorkDirectory -Directory $directory }
            Test-Path -LiteralPath $directory | Should -BeFalse
            Test-Path -LiteralPath $config.work_dir | Should -BeTrue
            { Remove-BackportGitWorkDirectory -Directory $directory } | Should -Throw -ExpectedMessage 'git_operation_failed'
        }
    }

    It 'denies cleanup after an owned-directory marker has been replaced' {
        InModuleScope Backport -Parameters @{ Parent = $script:IoRoot } {
            $config = @{ dry_run = $true; work_dir = (Join-Path $Parent 'owned-work') }
            $directory = New-BackportGitWorkDirectory -Config $config
            $marker = Join-Path $directory '.git\backport-owner'
            $original = [IO.File]::ReadAllBytes($marker)
            try {
                [IO.File]::WriteAllText($marker, 'not-the-owner')
                { Remove-BackportGitWorkDirectory -Directory $directory } | Should -Throw -ExpectedMessage 'git_operation_failed'
                Test-Path -LiteralPath $directory | Should -BeTrue
            }
            finally {
                [IO.File]::WriteAllBytes($marker, $original)
                Remove-BackportGitWorkDirectory -Directory $directory
            }
        }
    }

    It 'cleans an owned directory when git initialization fails without removing its parent' {
        InModuleScope Backport -Parameters @{ Parent = $script:IoRoot } {
            $config = @{ dry_run = $true; work_dir = (Join-Path $Parent 'failed-work') }
            Mock Invoke-BackportGit { throw 'sentinel-transport-secret' }
            { New-BackportGitWorkDirectory -Config $config } | Should -Throw -ExpectedMessage 'git_operation_failed'
            Test-Path -LiteralPath $config.work_dir | Should -BeTrue
            @(Get-ChildItem -LiteralPath $config.work_dir -Force).Count | Should -Be 0
        }
    }

    It 'removes a checkout link without following it into an unowned directory' {
        InModuleScope Backport -Parameters @{ Parent = $script:IoRoot } {
            $config = @{ dry_run = $true; work_dir = (Join-Path $Parent 'owned-work') }
            $unowned = Join-Path $Parent 'unowned'
            $null = [IO.Directory]::CreateDirectory($unowned)
            $sentinel = Join-Path $unowned 'keep'
            [IO.File]::WriteAllText($sentinel, 'must-survive')
            $directory = New-BackportGitWorkDirectory -Config $config
            $link = Join-Path $directory 'checkout-link'
            $type = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            $null = New-Item -ItemType $type -Path $link -Target $unowned -ErrorAction Stop
            Remove-BackportGitWorkDirectory -Directory $directory
            [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'must-survive'
        }
    }

    It 'refuses cleanup if the owned root is replaced by a link to an unowned directory' {
        InModuleScope Backport -Parameters @{ Parent = $script:IoRoot } {
            $config = @{ dry_run = $true; work_dir = (Join-Path $Parent 'owned-work') }
            $unowned = Join-Path $Parent 'unowned'
            $null = [IO.Directory]::CreateDirectory($unowned)
            $directory = New-BackportGitWorkDirectory -Config $config
            $moved = $directory + '-moved'
            [IO.Directory]::Move($directory, $moved)
            $type = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            $null = New-Item -ItemType $type -Path $directory -Target $unowned -ErrorAction Stop
            try {
                { Remove-BackportGitWorkDirectory -Directory $directory } | Should -Throw -ExpectedMessage 'git_operation_failed'
                Test-Path -LiteralPath $unowned | Should -BeTrue
            }
            finally {
                Remove-Item -LiteralPath $directory -Force
                [IO.Directory]::Move($moved, $directory)
                Remove-BackportGitWorkDirectory -Directory $directory
            }
        }
    }
}

Describe 'Private fixed-host HTTP adapter' -Tag 'EPIC-002', 'TEST-016', 'TEST-020' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Initialize-BackportTransportTestTypes
        Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force
    }
    BeforeEach {
        $script:IoSavedToken = [Environment]::GetEnvironmentVariable('GH_TOKEN')
        [Environment]::SetEnvironmentVariable('GH_TOKEN', 'sentinel-transport-secret')
    }
    AfterEach { [Environment]::SetEnvironmentVariable('GH_TOKEN', $script:IoSavedToken) }

    It 'sends fixed headers and exact JSON bytes through injected transport and disposes it' {
        InModuleScope Backport {
            $handler = [Backport.Tests.HttpHandler]::new()
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            $data = @{ title = 'café'; enabled = $false }
            $expected = ConvertTo-BackportJsonBytes -Value $data
            $result = Invoke-BackportHttp -Config @{ dry_run = $false } -Method POST -Path '/repos/AleksanderGladkov/BCApps-Backport-Test/issues' -Data $data
            $result.ok | Should -BeTrue
            $handler.Calls | Should -Be 1
            $handler.Uri | Should -BeExactly 'https://api.github.com/repos/AleksanderGladkov/BCApps-Backport-Test/issues'
            $handler.Method | Should -BeExactly 'POST'
            $handler.Authorization | Should -BeExactly 'Bearer sentinel-transport-secret'
            $handler.Headers['Accept'] | Should -BeExactly 'application/vnd.github+json'
            $handler.Headers['X-GitHub-Api-Version'] | Should -BeExactly '2022-11-28'
            $handler.Headers['Content-Type'] | Should -BeExactly 'application/json'
            $handler.Headers['User-Agent'] | Should -BeExactly 'bc-backport-demo'
            [Convert]::ToBase64String($handler.RequestBytes) | Should -BeExactly ([Convert]::ToBase64String($expected))
            $handler.Disposed | Should -BeTrue
            $handler.Stream.Disposed | Should -BeTrue
            $handler.TokenCancelable | Should -BeTrue
            ($result | Out-String) | Should -Not -Match 'sentinel-transport-secret'
        }
    }

    It 'accepts GET <Route> without changing the fixed host' -ForEach @(
        @{ Route = '/repos/AleksanderGladkov/BCApps-Backport-Test' }
        @{ Route = '/repos/AleksanderGladkov/BCApps-Backport-Test?per_page=100&page=1' }
        @{ Route = '/repos/AleksanderGladkov/BCApps-Backport-Test/branches/releases%2F29.x' }
        @{ Route = '/users/AleksanderGladkov' }
    ) {
        InModuleScope Backport -Parameters @{ Route = $Route } {
            $handler = [Backport.Tests.HttpHandler]::new()
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            (Invoke-BackportHttp -Config @{ dry_run = $true } -Method GET -Path $Route).ok | Should -BeTrue
            $handler.Calls | Should -Be 1
            $handler.Uri | Should -BeExactly ('https://api.github.com' + $Route)
            $handler.Headers['Content-Type'] | Should -BeExactly 'application/json'
        }
    }

    It 'rejects <Case> route without opening transport' -ForEach @(
        @{ Case = 'sibling prefix'; Method = 'GET'; Route = '/repos/AleksanderGladkov/BCApps-Backport-Test-other' }
        @{ Case = 'alternate owner'; Method = 'GET'; Route = '/repos/other/BCApps-Backport-Test' }
        @{ Case = 'absolute URL'; Method = 'GET'; Route = 'https://example.invalid/a' }
        @{ Case = 'scheme relative'; Method = 'GET'; Route = '//example.invalid/a' }
        @{ Case = 'backslash'; Method = 'GET'; Route = '/repos/AleksanderGladkov/BCApps-Backport-Test\..\else' }
        @{ Case = 'dot traversal'; Method = 'GET'; Route = '/repos/AleksanderGladkov/BCApps-Backport-Test/../else' }
        @{ Case = 'encoded traversal'; Method = 'GET'; Route = '/repos/AleksanderGladkov/BCApps-Backport-Test/%2e%2e/else' }
        @{ Case = 'fragment'; Method = 'GET'; Route = '/repos/AleksanderGladkov/BCApps-Backport-Test#fragment' }
        @{ Case = 'user nested path'; Method = 'GET'; Route = '/users/AleksanderGladkov/repos' }
        @{ Case = 'user write'; Method = 'POST'; Route = '/users/AleksanderGladkov' }
        @{ Case = 'user trailing newline'; Method = 'GET'; Route = "/users/AleksanderGladkov`n" }
    ) {
        InModuleScope Backport -Parameters @{ Route = $Route; Verb = $Method } {
            Mock New-BackportHttpClient { throw 'connection_must_not_open' }
            { Invoke-BackportHttp -Config @{ dry_run = $false } -Method $Verb -Path $Route } | Should -Throw -ExpectedMessage 'invalid_api_path'
            Should -Invoke New-BackportHttpClient -Times 0 -Exactly
        }
    }

    It 'rejects unsupported methods before opening transport' {
        InModuleScope Backport {
            Mock New-BackportHttpClient { throw 'connection_must_not_open' }
            { Invoke-BackportHttp -Config @{ dry_run = $false } -Method DELETE -Path '/repos/AleksanderGladkov/BCApps-Backport-Test' } | Should -Throw -ExpectedMessage 'invalid_api_method'
            Should -Invoke New-BackportHttpClient -Times 0 -Exactly
        }
    }

    It 'uses ordinal HTTP method checks for <Verb> with <SuffixName>' -ForEach @(
        foreach ($verb in @('GET', 'POST', 'PATCH')) {
            foreach ($suffix in @(@{ Name = 'soft hyphen'; Code = 0xAD }, @{ Name = 'NUL'; Code = 0 })) {
                @{ Verb = $verb; SuffixName = $suffix.Name; Codepoint = $suffix.Code }
            }
        }
    ) {
        InModuleScope Backport -Parameters @{ Verb = $Verb; Codepoint = $Codepoint } {
            Mock New-BackportHttpClient { throw 'connection_must_not_open' }
            Mock Get-BackportToken { throw 'token_must_not_be_read' }
            { Invoke-BackportHttp -Config @{ dry_run = $false } -Method ($Verb + [char]$Codepoint) -Path '/repos/AleksanderGladkov/BCApps-Backport-Test' } |
                Should -Throw -ExpectedMessage 'invalid_api_method'
            Should -Invoke New-BackportHttpClient -Times 0 -Exactly
            Should -Invoke Get-BackportToken -Times 0 -Exactly
        }
    }

    It 'uses ordinal repository-root checks with <SuffixName>' -ForEach @(
        @{ SuffixName = 'soft hyphen'; Codepoint = 0xAD }, @{ SuffixName = 'NUL'; Codepoint = 0 }
    ) {
        InModuleScope Backport -Parameters @{ Codepoint = $Codepoint } {
            Mock New-BackportHttpClient { throw 'connection_must_not_open' }
            { Invoke-BackportHttp -Config @{ dry_run = $false } -Method GET -Path ('/repos/AleksanderGladkov/BCApps-Backport-Test' + [char]$Codepoint) } |
                Should -Throw -ExpectedMessage 'invalid_api_path'
            Should -Invoke New-BackportHttpClient -Times 0 -Exactly
        }
    }

    It 'maps safe JSON types without enumerating empty or one-element array responses' -ForEach @(
        @{ Json = '[]'; Count = 0 }
        @{ Json = '[{"ok":true}]'; Count = 1 }
    ) {
        InModuleScope Backport -Parameters @{ Json = $Json; Count = $Count } {
            $handler = [Backport.Tests.HttpHandler]::new()
            $handler.Body = [Text.Encoding]::UTF8.GetBytes($Json)
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            $value = Invoke-BackportHttp -Config @{ dry_run = $true } -Method GET -Path '/repos/AleksanderGladkov/BCApps-Backport-Test'
            $value.Count | Should -Be $Count
            $value -is [array] | Should -BeTrue
        }
    }

    It 'denies dry-run <Verb> before transport or token access' -ForEach @(@{ Verb = 'POST' }, @{ Verb = 'PATCH' }) {
        InModuleScope Backport -Parameters @{ Verb = $Verb } {
            Mock New-BackportHttpClient { throw 'connection_must_not_open' }
            Mock Get-BackportToken { throw 'token_must_not_be_read' }
            { Invoke-BackportHttp -Config @{ dry_run = $true } -Method $Verb -Path '/repos/AleksanderGladkov/BCApps-Backport-Test/issues' } | Should -Throw -ExpectedMessage 'dry_run_write_blocked'
            Should -Invoke New-BackportHttpClient -Times 0 -Exactly
            Should -Invoke Get-BackportToken -Times 0 -Exactly
        }
    }

    It 'rejects redirect <Status> explicitly without retry or reading its body' -ForEach @(
        @{ Status = 301 }, @{ Status = 302 }, @{ Status = 303 }, @{ Status = 307 }, @{ Status = 308 }
    ) {
        InModuleScope Backport -Parameters @{ Status = $Status } {
            $handler = [Backport.Tests.HttpHandler]::new()
            $handler.Status = $Status
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            { Invoke-BackportHttp -Config @{ dry_run = $false } -Method GET -Path '/repos/AleksanderGladkov/BCApps-Backport-Test' } | Should -Throw -ExpectedMessage 'api_redirect_rejected'
            $handler.Calls | Should -Be 1
            $handler.Stream.BytesRead | Should -Be 0
            $handler.Disposed | Should -BeTrue
            $handler.Stream.Disposed | Should -BeTrue
        }
    }

    It 'classifies <Verb> <Failure> without retry or leaking exception content' -ForEach @(
        @{ Verb = 'GET'; Failure = 'status400'; Code = 'api_read_failed' }
        @{ Verb = 'GET'; Failure = 'status500'; Code = 'api_read_failed' }
        @{ Verb = 'GET'; Failure = 'throw'; Code = 'api_read_failed' }
        @{ Verb = 'GET'; Failure = 'body-throw'; Code = 'api_read_failed' }
        @{ Verb = 'GET'; Failure = 'malformed'; Code = 'api_read_failed' }
        @{ Verb = 'POST'; Failure = 'status400'; Code = 'api_write_ambiguous' }
        @{ Verb = 'POST'; Failure = 'throw'; Code = 'api_write_ambiguous' }
        @{ Verb = 'POST'; Failure = 'malformed'; Code = 'api_write_ambiguous' }
        @{ Verb = 'PATCH'; Failure = 'status500'; Code = 'api_write_ambiguous' }
        @{ Verb = 'PATCH'; Failure = 'body-throw'; Code = 'api_write_ambiguous' }
        @{ Verb = 'PATCH'; Failure = 'malformed'; Code = 'api_write_ambiguous' }
    ) {
        InModuleScope Backport -Parameters @{ Verb = $Verb; Failure = $Failure; Code = $Code } {
            $handler = [Backport.Tests.HttpHandler]::new()
            if ($Failure -like 'status*') { $handler.Status = [int]$Failure.Substring(6) }
            elseif ($Failure -eq 'malformed') { $handler.Body = [Text.Encoding]::UTF8.GetBytes('sentinel-transport-secret') }
            else { $handler.Mode = $Failure }
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            $caught = $null
            try { $null = Invoke-BackportHttp -Config @{ dry_run = $false } -Method $Verb -Path '/repos/AleksanderGladkov/BCApps-Backport-Test' }
            catch { $caught = $_ }
            $caught.Exception.Message | Should -BeExactly $Code
            ($caught | Out-String) | Should -Not -Match 'sentinel-transport-secret'
            $handler.Calls | Should -Be 1
            $handler.Disposed | Should -BeTrue
            if ($handler.Stream) { $handler.Stream.Disposed | Should -BeTrue }
        }
    }

    It 'accepts exactly 16 MiB and rejects one extra byte with bounded reads' -ForEach @(
        @{ Extra = 0 }, @{ Extra = 1 }, @{ Extra = 1024 }
    ) {
        InModuleScope Backport -Parameters @{ Extra = $Extra } {
            $handler = [Backport.Tests.HttpHandler]::new()
            $handler.Body = [byte[]]::new(16 * 1024 * 1024 + $Extra)
            [Array]::Fill[byte]($handler.Body, 32)
            $handler.Body[0] = 123
            $handler.Body[1] = 125
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            if ($Extra -eq 0) {
                $value = Invoke-BackportHttp -Config @{ dry_run = $true } -Method GET -Path '/repos/AleksanderGladkov/BCApps-Backport-Test'
                $value.Count | Should -Be 0
            }
            else {
                { Invoke-BackportHttp -Config @{ dry_run = $true } -Method GET -Path '/repos/AleksanderGladkov/BCApps-Backport-Test' } | Should -Throw -ExpectedMessage 'api_response_too_large'
            }
            $handler.Stream.BytesRead | Should -Be ([Math]::Min($handler.Body.Length, 16 * 1024 * 1024 + 1))
            $handler.Stream.LargestRead | Should -BeLessOrEqual 65536
            $handler.Stream.Disposed | Should -BeTrue
            $handler.Calls | Should -Be 1
        }
    }

    It 'contains <Failure> cleanup errors for <Verb> without returning a partial response' -ForEach @(
        foreach ($verb in @('GET', 'POST', 'PATCH')) {
            foreach ($failure in @('body-dispose-throw', 'dispose-throw')) {
                @{ Verb = $verb; Failure = $failure; Code = $(if ($verb -eq 'GET') { 'api_read_failed' } else { 'api_write_ambiguous' }) }
            }
        }
    ) {
        InModuleScope Backport -Parameters @{ Verb = $Verb; Failure = $Failure; Code = $Code } {
            $handler = [Backport.Tests.HttpHandler]::new()
            $handler.Mode = $Failure
            $ownedDeadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))
            $published = [Collections.Generic.List[object]]::new()
            Mock Get-BackportToken { 'sentinel-transport-secret' }
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            Mock New-BackportHttpDeadline { $ownedDeadline }
            $caught = $null
            try {
                Invoke-BackportHttp -Config @{ dry_run = $false } -Method $Verb -Path '/repos/AleksanderGladkov/BCApps-Backport-Test' |
                    ForEach-Object { $published.Add($_) }
            }
            catch { $caught = $_ }
            $caught.Exception.Message | Should -BeExactly $Code
            ($caught | Out-String) | Should -Not -Match 'sentinel-transport-secret'
            $published.Count | Should -Be 0
            $handler.Calls | Should -Be 1
            $handler.Stream.Disposed | Should -BeTrue
            $handler.Disposed | Should -BeTrue
            { $ownedDeadline.Cancel() } | Should -Throw
        }
    }

    It 'cancels <Phase> for <Verb> using the same private deadline through body reads' -ForEach @(
        @{ Phase = 'headers-wait'; Verb = 'GET'; Code = 'api_read_failed' }
        @{ Phase = 'body-wait'; Verb = 'GET'; Code = 'api_read_failed' }
        @{ Phase = 'body-wait'; Verb = 'POST'; Code = 'api_write_ambiguous' }
        @{ Phase = 'body-wait'; Verb = 'PATCH'; Code = 'api_write_ambiguous' }
    ) {
        InModuleScope Backport -Parameters @{ Phase = $Phase; Verb = $Verb; Code = $Code } {
            (Get-Command New-BackportHttpDeadline).ScriptBlock.ToString() | Should -Match 'FromSeconds\(60\)'
            $handler = [Backport.Tests.HttpHandler]::new()
            $handler.Mode = $Phase
            Mock New-BackportHttpClient { [Net.Http.HttpClient]::new($handler, $true) }
            Mock New-BackportHttpDeadline { [Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds(150)) }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            { Invoke-BackportHttp -Config @{ dry_run = $false } -Method $Verb -Path '/repos/AleksanderGladkov/BCApps-Backport-Test' } | Should -Throw -ExpectedMessage $Code
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
            $handler.Calls | Should -Be 1
            $handler.Disposed | Should -BeTrue
            if ($Phase -eq 'headers-wait') { $handler.CancellationObserved | Should -BeTrue }
            else {
                $handler.Stream.CancellationObserved | Should -BeTrue
                $handler.Stream.Disposed | Should -BeTrue
            }
        }
    }

    It 'constructs production clients with automatic redirects disabled and no shorter timeout' {
        InModuleScope Backport {
            $client = New-BackportHttpClient
            try {
                $client.Timeout | Should -Be ([Threading.Timeout]::InfiniteTimeSpan)
                (Get-Command New-BackportHttpClient).ScriptBlock.ToString() | Should -Match 'AllowAutoRedirect\s*=\s*\$false'
            }
            finally { $client.Dispose() }
        }
    }
}
