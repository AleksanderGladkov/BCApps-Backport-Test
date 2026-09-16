# Test-only boundaries. Injected HTTP fixtures never open a network connection.

function Set-BackportTestEventFile {
    param($Environment, $Event, [string]$Path = $Environment.GITHUB_EVENT_PATH)
    $Environment.GITHUB_EVENT_PATH = $Path
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Event -Depth 100 -Compress))
}

function Set-BackportDispatchTestEvent {
    param($Environment, [string]$Path = $Environment.GITHUB_EVENT_PATH)
    Set-BackportTestEventFile $Environment @{
        repository = @{ id = 1369849596; full_name = 'AleksanderGladkov/BCApps-Backport-Test' }
        ref = 'main'
        inputs = @{ source_pr = $Environment.INPUT_SOURCE_PR; dry_run = $Environment.INPUT_DRY_RUN }
    } $Path
}

function New-BackportLabelTestEvent {
    param($Test)
    @{
        action = 'labeled'; number = 7; label = @{ name = 'backport:29.x' }
        repository = (Copy-BackportTestValue $Test.Api.repo)
        sender = @{ id = 59250993; login = 'AleksanderGladkov' }
        pull_request = @{
            number = 7; merged = $true; state = 'closed'
            base = @{ ref = 'main'; repo = (Copy-BackportTestValue $Test.Api.repo) }
        }
    }
}

function Set-BackportLabelStageConfig {
    param($Test)
    $Test.Environment.GITHUB_EVENT_NAME = 'pull_request_target'
    $Test.Environment.INPUT_DRY_RUN = 'false'
    Set-BackportTestEventFile $Test.Environment (New-BackportLabelTestEvent $Test)
    Set-BackportStageConfig $Test
}

function New-BackportTestPolicyBytes {
    param([object[]]$Actors = @(59250993), [bool]$Labels = $true, [bool]$Writes = $true)
    return ,([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 10 -InputObject @{
        schema = 1; repository_id = 1369849596; allowed_actor_ids = $Actors
        label_requests_enabled = $Labels; writes_enabled = $Writes
    })))
}

function Set-BackportTestPolicy {
    param($Test, [byte[]]$Bytes, [switch]$LiveOnly)
    $Test.Api.policy_bytes = $Bytes.Clone()
    if (-not $LiveOnly) { $Test.TrustedPolicyBytes = $Bytes.Clone() }
}

function Test-BackportPolicyGet {
    param($Call)
    $Call.method -ceq 'GET' -and (
        $Call.path -ceq '/repos/AleksanderGladkov/BCApps-Backport-Test/git/ref/heads/main' -or
        $Call.path -cmatch '\A/repos/AleksanderGladkov/BCApps-Backport-Test/contents/\.github/scripts/backport-demo/request-policy\.json\?ref=[0-9a-f]{40}\z'
    )
}

function Assert-BackportRequestRejected {
    param($Test)
    foreach ($stage in @('validate', 'track', 'prepare', 'publish')) {
        {
            $Test.Config = & $Test.Module { param($e) New-BackportContext -Environment $e } $Test.Environment
            Invoke-BackportTestStage $Test $stage
        } | Should -Throw
    }
    $Test.Api.calls.Count | Should -Be 0
    $Test.GitCalls.Count | Should -Be 0
    $Test.Pushes.Count | Should -Be 0
    Test-Path -LiteralPath (Join-Path $Test.Environment.RUNNER_TEMP 'backport-state') | Should -BeFalse
}

function Get-BackportWorkflowTestProjection {
    param([string]$Text, [string]$EventName, $Event, [string]$Source = '7', $Dry = $null, [string]$Run = '123')
    # A fixture for these exact expressions, not a general Actions evaluator.
    $sourceExpression = '${{ github.event_name == ''pull_request_target'' && github.event.pull_request.number || inputs.source_pr }}'
    $dryExpression = '${{ github.event_name == ''workflow_dispatch'' && inputs.dry_run && ''true'' || ''false'' }}'
    $Text | Should -Match '(?m)^        default: true$'
    $Text | Should -Match '(?m)^        type: boolean$'
    [regex]::Match($Text, '(?m)^  INPUT_SOURCE_PR: (.+)$').Groups[1].Value | Should -BeExactly $sourceExpression
    [regex]::Match($Text, '(?m)^  INPUT_DRY_RUN: (.+)$').Groups[1].Value | Should -BeExactly $dryExpression
    $title = [regex]::Match($Text, '(?m)^run-name: (.+)$').Groups[1].Value
    $title | Should -BeExactly "Backport PR $sourceExpression to 29.x (dry run = $dryExpression)"
    if ($null -eq $Dry) { $Dry = $true } # Only the workflow's declared input default supplies this.
    $label = $EventName -eq 'pull_request_target'
    $sourceValue = if ($label -and $Event.pull_request.number) { [string]$Event.pull_request.number } else { $Source }
    $dryValue = if ($EventName -eq 'workflow_dispatch' -and $Dry) { 'true' } else { 'false' }
    $eligible = $EventName -eq 'workflow_dispatch' -or ($label -and $Event.action -eq 'labeled' -and
        $Event.label.name -eq 'backport:29.x' -and $Event.pull_request.merged -eq $true -and
        $Event.pull_request.state -eq 'closed' -and $Event.pull_request.base.ref -eq 'main' -and
        $Event.repository.id -eq 1369849596 -and $Event.repository.full_name -eq 'AleksanderGladkov/BCApps-Backport-Test' -and
        $Event.pull_request.base.repo.id -eq 1369849596 -and
        $Event.pull_request.base.repo.full_name -eq 'AleksanderGladkov/BCApps-Backport-Test' -and
        $Event.number -eq $Event.pull_request.number -and $Event.number -gt 0 -and $Event.number -lt 2147483648)
    $group = [regex]::Match($Text, '(?m)^  group: (.+)$').Groups[1].Value
    $group | Should -BeExactly 'backport-demo-${{ github.repository_id }}-${{ (github.event_name == ''workflow_dispatch'' || (github.event_name == ''pull_request_target'' && github.event.action == ''labeled'' && github.event.label.name == ''backport:29.x'' && github.event.pull_request.merged == true && github.event.pull_request.state == ''closed'' && github.event.pull_request.base.ref == ''main'' && github.event.repository.id == 1369849596 && github.event.repository.full_name == ''AleksanderGladkov/BCApps-Backport-Test'' && github.event.pull_request.base.repo.id == 1369849596 && github.event.pull_request.base.repo.full_name == ''AleksanderGladkov/BCApps-Backport-Test'' && github.event.number == github.event.pull_request.number && github.event.number > 0 && github.event.number < 2147483648)) && (github.event_name == ''pull_request_target'' && github.event.pull_request.number || inputs.source_pr) || format(''rejected-{0}'', github.run_id) }}-29'
    @{
        source = $sourceValue; dry = $dryValue
        title = $title.Replace($sourceExpression, $sourceValue).Replace($dryExpression, $dryValue)
        group = 'backport-demo-1369849596-' + $(if ($eligible) { $sourceValue } else { "rejected-$Run" }) + '-29'
    }
}

function New-BackportStageTest {
    param([string]$ParentPath, $Module, $Template)
    $fixture = New-LocalGitFixture -ParentPath $ParentPath
    $test = [pscustomobject]@{
        Fixture = $fixture; Module = $Module; Config = $null; Base = $fixture.Target
        Api = (New-FakeGitHub -Fixture $fixture -Head $fixture.Head -Source $fixture.Source -Target $fixture.Target -Commits $fixture.Commits)
        Environment = @{
            GITHUB_REPOSITORY = 'AleksanderGladkov/BCApps-Backport-Test'
            GITHUB_REPOSITORY_ID = '1369849596'; GITHUB_REF = 'refs/heads/main'
            GITHUB_EVENT_NAME = 'workflow_dispatch'
            GITHUB_EVENT_PATH = (Join-Path $fixture.Root 'event.json')
            GITHUB_WORKFLOW_REF = 'AleksanderGladkov/BCApps-Backport-Test/.github/workflows/backport-demo.yml@refs/heads/main'
            GITHUB_WORKFLOW_SHA = ('a' * 40)
            GITHUB_ACTOR_ID = '59250993'; GITHUB_TRIGGERING_ACTOR = 'AleksanderGladkov'
            INPUT_SOURCE_PR = '7'; INPUT_DRY_RUN = 'false'
            GITHUB_RUN_ID = '123'; GITHUB_RUN_ATTEMPT = '1'
            RUNNER_TEMP = (Join-Path $fixture.Root 'runner'); GH_TOKEN = 'offline-fixture'
        }
        Http = ${function:Invoke-BackportStageHttp}
        Git = ${function:New-BackportStageGitStartInfo}
        OriginalGit = $(if ($Template) { $Template.OriginalGit } else { & $Module { (Get-Command New-BackportGitStartInfo).ScriptBlock } })
        OriginalHttp = $(if ($Template) { $Template.OriginalHttp } else { & $Module { (Get-Command Invoke-BackportHttp).ScriptBlock } })
        OriginalProcess = $(if ($Template) { $Template.OriginalProcess } else { & $Module { (Get-Command Invoke-BackportProcess).ScriptBlock } })
        Process = ${function:Invoke-BackportStageProcess}
        HttpFilter = $null; BeforePush = $null; AfterPush = $null
        TrustedPolicyBytes = $null
        Boundary = $null; BoundarySeen = $false; HistoryReads = 0
        Pushes = [Collections.Generic.List[object]]::new()
        GitCalls = [Collections.Generic.List[object]]::new()
        GitEffects = [Collections.Generic.List[object]]::new()
    }
    $test.TrustedPolicyBytes = $test.Api.policy_bytes.Clone()
    Set-BackportStageConfig $test
    $test
}

function Invoke-BackportStageProcess {
    param($Test, $StartInfo, $Data, $TimeoutSeconds = 180)
    if ([IO.Path]::GetFileNameWithoutExtension($StartInfo.FileName) -cne 'git') { throw 'non_git_process_forbidden' }
    $result = & $Test.OriginalProcess -StartInfo $StartInfo -Data $Data
    $directoryIndex = $StartInfo.ArgumentList.IndexOf('-C')
    if ($directoryIndex -lt 0) { throw 'git_directory_required' }
    $arguments = @($StartInfo.ArgumentList | Select-Object -Skip ($directoryIndex + 2))
    if ($arguments[0] -cin @('fetch', 'ls-remote', 'push')) {
        $Test.GitEffects.Add(@{
            arguments = @($arguments | ForEach-Object { $_.Replace($Test.Fixture.Origin, '<fixture-origin>') })
            auth = $StartInfo.Environment.ContainsKey('GIT_CONFIG_VALUE_0')
            exit_code = $result.exit_code
            stdout = [Text.Encoding]::UTF8.GetString($result.stdout).Replace($Test.Fixture.Origin, '<fixture-origin>')
        })
    }
    if ($StartInfo.ArgumentList.Contains('push') -and $result.exit_code -eq 0 -and $Test.AfterPush) {
        & $Test.AfterPush $Test
    }
    return $result
}

function Set-BackportStageConfig {
    param($Test)
    if ($Test.Environment.GITHUB_EVENT_NAME -ceq 'workflow_dispatch') {
        Set-BackportDispatchTestEvent $Test.Environment
    }
    $Test.Config = & $Test.Module { param($e) New-BackportContext -Environment $e } $Test.Environment
    $current = New-FakeWorkflowRun -Api $Test.Api -Id ([long]$Test.Config.run_id) -Attempt ([int]$Test.Config.run_attempt) `
        -SourcePr $Test.Config.source_pr -DryRun $Test.Config.dry_run -Event $Test.Environment.GITHUB_EVENT_NAME
    $existing = @($Test.Api.runs | Where-Object id -EQ $current.id)
    if ($existing.Count) {
        foreach ($key in $current.Keys) { $existing[0][$key] = $current[$key] }
    }
    else { $Test.Api.runs.Insert(0, $current) }
}

function Invoke-BackportStageHttp {
    param($Test, $Method, $Path, $Data)
    if ($Method -cne 'GET' -and $Test.Config.dry_run) { throw 'dry_run_write_blocked' }
    if ($Test.HttpFilter) { return ,(& $Test.HttpFilter $Test $Method $Path $Data) }
    return ,(Invoke-FakeGitHub $Test.Api $Method $Path $Data)
}

function New-BackportStageGitStartInfo {
    param($Test, $Config, $Directory, $Arguments, $Auth)
    Assert-LocalGitFixture $Test.Fixture
    $directoryPath = [IO.Path]::GetFullPath($Directory)
    if (-not $directoryPath.StartsWith($Test.Fixture.Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'unowned_stage_git_directory'
    }
    $Test.GitCalls.Add(@{ directory = $Directory; arguments = @($Arguments); auth = [bool]$Auth })
    if ($Arguments[0] -ceq 'push') {
        $Test.Pushes.Add(@($Arguments))
        if ($Test.BeforePush) { & $Test.BeforePush $Test $Directory $Arguments }
    }
    $info = & $Test.OriginalGit -Config $Config -WorkingDirectory $Directory -Arguments $Arguments -Auth:$Auth
    for ($i = 0; $i -lt $info.ArgumentList.Count; $i++) {
        if ($info.ArgumentList[$i] -ceq 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git') {
            $info.ArgumentList[$i] = $Test.Fixture.Origin
        }
        elseif ($info.ArgumentList[$i] -ceq 'protocol.file.allow=never') {
            $info.ArgumentList[$i] = 'protocol.file.allow=always'
        }
    }
    $info.Environment['GIT_ALLOW_PROTOCOL'] = 'file'
    $info.Environment['GIT_AUTHOR_DATE'] = '2000-01-01T00:00:00Z'
    $info.Environment['GIT_COMMITTER_DATE'] = '2000-01-01T00:00:00Z'
    $info.Environment['TEMP'] = $info.Environment['TMP'] = $Test.Fixture.Root
    return $info
}

function Invoke-BackportTestStage {
    param($Test, [ValidateSet('validate', 'track', 'prepare', 'publish')][string]$Stage)
    $script:StageTest = $Test
    & $Test.Module {
        param($config, $stage)
        & ('Invoke-Backport' + $stage) -Config $config
    } $Test.Config $Stage
}

function Invoke-BackportTestStages {
    param($Test, [string]$Last = 'prepare')
    foreach ($stage in @('validate', 'track', 'prepare', 'publish')) {
        $value = Invoke-BackportTestStage $Test $stage
        if ($stage -ceq $Last) { return $value }
    }
}

function Get-StageJson {
    param($Test, [string]$Name = 'plan.json')
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Test.Config.state_dir $Name))) -AsHashtable -Depth 100
}

function Set-StageJson {
    param($Test, [string]$Name, $Value)
    $bytes = & $Test.Module { param($v) ConvertTo-BackportJsonBytes $v } $Value
    [IO.File]::WriteAllBytes((Join-Path $Test.Config.state_dir $Name), $bytes)
}

function Edit-StageJson {
    param($Test, [string]$Name, [scriptblock]$Edit)
    $value = Get-StageJson $Test $Name
    & $Edit $value
    Set-StageJson $Test $Name $value
}

function Get-StageHash {
    param([byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-StagePlanHash {
    param($Test)
    $bytes = & $Test.Module { param($v) ConvertTo-BackportJsonBytes $v } (Get-StageJson $Test)
    Get-StageHash $bytes
}

function New-StageAttempt {
    param($Test, [string]$Run = '123', [string]$Attempt = '2')
    $Test.Environment.GITHUB_RUN_ID = $Run
    $Test.Environment.GITHUB_RUN_ATTEMPT = $Attempt
    $Test.Environment.STATE_DIR = Join-Path $Test.Fixture.Root "state-$Run-$Attempt"
    Set-BackportStageConfig $Test
}

function Invoke-StageFixtureGit {
    param($Test, [string[]]$Arguments)
    Invoke-LocalGit $Test.Fixture $Test.Fixture.Origin $Arguments
}

function Set-StageFixtureText {
    param($Test, [string]$Path, [string]$Text)
    $absolute = Join-Path $Test.Fixture.Origin $Path
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($absolute))
    [IO.File]::WriteAllBytes($absolute, [Text.Encoding]::UTF8.GetBytes($Text))
}

function Update-StageSource {
    param($Test, [int]$ChangedFiles = 1)
    $f = $Test.Fixture
    $f.Head = Invoke-StageFixtureGit $Test @('rev-parse', 'feature')
    $null = Invoke-StageFixtureGit $Test @('update-ref', 'refs/pull/7/head', $f.Head)
    $null = Invoke-StageFixtureGit $Test @('switch', 'main')
    $null = Invoke-StageFixtureGit $Test @('reset', '--hard', $f.Target)
    $null = Invoke-StageFixtureGit $Test @('merge', '--squash', 'feature')
    $null = Invoke-StageFixtureGit $Test @('commit', '-m', 'squash')
    $f.Source = Invoke-StageFixtureGit $Test @('rev-parse', 'HEAD')
    $f.Commits = @((Invoke-StageFixtureGit $Test @('rev-list', '--reverse', "$($f.Target)..$($f.Head)")).Split("`n"))
    $Test.Api.source.merge_commit_sha = $f.Source
    $Test.Api.source.head.sha = $f.Head
    $Test.Api.source.changed_files = $ChangedFiles
    $Test.Api.commits.Clear()
    foreach ($sha in $f.Commits) { $Test.Api.commits.Add(@{ sha = $sha }) }
}

function Set-StageMultiCommitSource {
    param($Test, [string]$Integration = 'squash', [string]$Newline = "`n")
    $f = $Test.Fixture
    $null = Invoke-StageFixtureGit $Test @('reset', '--hard', $Test.Base)
    $lines = @(0..19 | ForEach-Object { "line $_" })
    Set-StageFixtureText $Test 'src\one.al' (($lines -join $Newline) + $Newline)
    $null = Invoke-StageFixtureGit $Test @('commit', '-am', 'spaced base')
    $f.Target = Invoke-StageFixtureGit $Test @('rev-parse', 'HEAD')
    $null = Invoke-StageFixtureGit $Test @('branch', '-f', 'releases/29.x', $f.Target)
    $null = Invoke-StageFixtureGit $Test @('switch', '-C', 'feature', $f.Target)
    $lines[1] = 'FIRST EDIT'
    Set-StageFixtureText $Test 'src\one.al' (($lines -join $Newline) + $Newline)
    $null = Invoke-StageFixtureGit $Test @('commit', '-am', 'first edit')
    $lines[18] = 'SECOND EDIT'
    Set-StageFixtureText $Test 'src\one.al' (($lines -join $Newline) + $Newline)
    $null = Invoke-StageFixtureGit $Test @('commit', '-am', 'second edit')
    $null = Invoke-StageFixtureGit $Test @('switch', 'main')
    if ($Integration -ceq 'rebase') {
        Set-StageFixtureText $Test 'unrelated.txt' "main advanced`n"
        $null = Invoke-StageFixtureGit $Test @('add', '.')
        $null = Invoke-StageFixtureGit $Test @('commit', '-m', 'advance main')
        $null = Invoke-StageFixtureGit $Test @('switch', 'feature')
        $null = Invoke-StageFixtureGit $Test @('rebase', 'main')
        $null = Invoke-StageFixtureGit $Test @('switch', 'main')
    }
    $f.Head = Invoke-StageFixtureGit $Test @('rev-parse', 'feature')
    $base = Invoke-StageFixtureGit $Test @('merge-base', 'main', 'feature')
    $f.Commits = @((Invoke-StageFixtureGit $Test @('rev-list', '--reverse', "$base..$($f.Head)")).Split("`n"))
    if ($f.Commits.Count -ne 2) { throw 'invalid_multicommit_fixture' }
    $null = Invoke-StageFixtureGit $Test @('update-ref', 'refs/pull/7/head', $f.Head)
    if ($Integration -cin @('fast-forward', 'rebase')) {
        $null = Invoke-StageFixtureGit $Test @('merge', '--ff-only', 'feature')
    }
    else {
        if ($Integration -ceq 'partial-parent') {
            $null = Invoke-StageFixtureGit $Test @('merge', '--ff-only', $f.Commits[0])
        }
        $null = Invoke-StageFixtureGit $Test @('merge', '--squash', 'feature')
        $null = Invoke-StageFixtureGit $Test @('commit', '-m', 'complete squash')
    }
    $f.Source = Invoke-StageFixtureGit $Test @('rev-parse', 'HEAD')
    $Test.Api.source.merge_commit_sha = $f.Source
    $Test.Api.source.head.sha = $f.Head
    $Test.Api.target = $f.Target
    $Test.Api.commits.Clear()
    foreach ($sha in $f.Commits) { $Test.Api.commits.Add(@{ sha = $sha }) }
}

function Set-StageConflict {
    param($Test)
    $null = Invoke-StageFixtureGit $Test @('switch', 'releases/29.x')
    Set-StageFixtureText $Test 'src\one.al' "RELEASE`ntwo`nthree`n"
    $null = Invoke-StageFixtureGit $Test @('commit', '-am', 'target edit')
    $Test.Api.target = Invoke-StageFixtureGit $Test @('rev-parse', 'HEAD')
    $null = Invoke-StageFixtureGit $Test @('switch', 'main')
}

function Assert-StageNoPublication {
    param($Test)
    $Test.Api.pulls.Count | Should -Be 0
    (Invoke-StageFixtureGit $Test @('branch', '--list', 'backport/*')) | Should -BeExactly ''
}

function Assert-StagePartialSourceRejected {
    param($Test, [string]$Integration)
    Set-StageMultiCommitSource $Test $Integration
    $parent = Invoke-StageFixtureGit $Test @('rev-parse', "$($Test.Fixture.Source)^")
    $parent | Should -BeExactly $Test.Fixture.Commits[0]
    (Invoke-StageFixtureGit $Test @('merge-base', $parent, $Test.Fixture.Head)) | Should -BeExactly $parent
    $patch = Invoke-StageFixtureGit $Test @('diff', $parent, $Test.Fixture.Source)
    $patch | Should -Match '\+SECOND EDIT'
    $patch | Should -Not -Match '\+FIRST EDIT'
    (Invoke-StageFixtureGit $Test @('diff', '--raw', '--no-abbrev', '--no-renames', $parent, $Test.Fixture.Source)) |
        Should -BeExactly (Invoke-StageFixtureGit $Test @('diff', '--raw', '--no-abbrev', '--no-renames', $parent, $Test.Fixture.Head))
    { Invoke-BackportTestStage $Test validate } | Should -Throw -ExpectedMessage 'source_not_squash'
    Test-Path -LiteralPath (Join-Path $Test.Config.state_dir 'plan.json') | Should -BeFalse
    @($Test.Api.calls | Where-Object method -CNE 'GET').Count | Should -Be 0
}

function Set-StageTwoFileSource {
    param($Test, [switch]$BothPresent)
    $f = $Test.Fixture
    $null = Invoke-StageFixtureGit $Test @('switch', '-c', 'safety-base', $f.Target)
    Set-StageFixtureText $Test 'src\two.al' "alpha`nbeta`n"
    $null = Invoke-StageFixtureGit $Test @('add', '.')
    $null = Invoke-StageFixtureGit $Test @('commit', '-m', 'two-file base')
    $base = Invoke-StageFixtureGit $Test @('rev-parse', 'HEAD')
    $null = Invoke-StageFixtureGit $Test @('switch', '-C', 'feature')
    Set-StageFixtureText $Test 'src\one.al' "ONE`ntwo`nthree`n"
    Set-StageFixtureText $Test 'src\two.al' "ALPHA`nbeta`n"
    $null = Invoke-StageFixtureGit $Test @('commit', '-am', 'complete two-file fix')
    $f.Target = $base
    Update-StageSource $Test -ChangedFiles 2
    $null = Invoke-StageFixtureGit $Test @('branch', '-f', 'releases/29.x', $base)
    $null = Invoke-StageFixtureGit $Test @('switch', 'releases/29.x')
    Set-StageFixtureText $Test 'src\one.al' "ONE`ntwo`nthree`n"
    if ($BothPresent) { Set-StageFixtureText $Test 'src\two.al' "ALPHA`nbeta`n" }
    Set-StageFixtureText $Test 'src\release.al' "release-only`nunchanged`n"
    $null = Invoke-StageFixtureGit $Test @('add', '.')
    $null = Invoke-StageFixtureGit $Test @('commit', '-m', 'preexisting release effects')
    $f.Target = Invoke-StageFixtureGit $Test @('rev-parse', 'HEAD')
    $Test.Api.target = $f.Target
    $null = Invoke-StageFixtureGit $Test @('switch', 'main')
}

function Copy-StageFixtureRefs {
    param($Source, $Target)
    Assert-LocalGitFixture $Source.Fixture
    Assert-LocalGitFixture $Target.Fixture
    $environment = New-LocalGitEnvironment $Target.Fixture
    $result = Invoke-HarnessProcess -FileName (@(Get-Command git -CommandType Application)[0].Source) -Environment $environment -Arguments @(
        '-c', "core.hooksPath=$($Target.Fixture.EmptyHome)", '-c', 'protocol.allow=never',
        '-c', 'protocol.file.allow=always', '-c', 'protocol.ext.allow=never',
        '-c', 'submodule.recurse=false', '-C', $Target.Fixture.Origin,
        'fetch', '--update-head-ok', '--no-tags', '--no-recurse-submodules',
        $Source.Fixture.Origin, '+refs/heads/*:refs/heads/*', '+refs/pull/*:refs/pull/*'
    )
    if ($result.ExitCode -ne 0) { throw 'fixture_ref_clone_failed' }
    $null = Invoke-StageFixtureGit $Target @('reset', '--hard', 'main')
    foreach ($name in @('Head', 'Source', 'Target', 'Commits')) { $Target.Fixture.$name = Copy-BackportTestValue $Source.Fixture.$name }
    foreach ($name in @('source', 'target', 'commits', 'actor', 'repo')) {
        if ($name -ceq 'commits') {
            $Target.Api.commits.Clear()
            foreach ($item in $Source.Api.commits) { $Target.Api.commits.Add((Copy-BackportTestValue $item)) }
        }
        else { $Target.Api.$name = Copy-BackportTestValue $Source.Api.$name }
    }
}

function Get-StageGitBytes {
    param($Test, [string]$Directory, [string[]]$Arguments)
    $script:StageTest = $Test
    $value = & $Test.Module {
        param($c, $d, $a)
        Invoke-BackportGit -Config $c -Directory $d -Arguments $a
    } $Test.Config $Directory $Arguments
    return ,$value.stdout
}

function Set-StageForgedEffect {
    param($Test, [ValidateSet('missing', 'extra')][string]$Kind)
    $directory = New-LocalGitWorkingCopy $Test.Fixture
    $null = Invoke-LocalGit $Test.Fixture $directory @('checkout', '--detach', $Test.Fixture.Target)
    [IO.File]::WriteAllBytes((Join-Path $directory 'src\two.al'),
        [Text.Encoding]::UTF8.GetBytes($(if ($Kind -ceq 'missing') { "WRONG`nbeta`n" } else { "ALPHA`nbeta`n" })))
    if ($Kind -ceq 'extra') {
        [IO.File]::WriteAllBytes((Join-Path $directory 'src\release.al'), [Text.Encoding]::UTF8.GetBytes("unrelated edit`n"))
    }
    $null = Invoke-LocalGit $Test.Fixture $directory @('commit', '-am', "forged`n`n(cherry picked from commit $($Test.Fixture.Source))")
    $patch = Get-StageGitBytes $Test $directory @('diff', '--binary', '--full-index', '--no-renames',
        '--no-ext-diff', '--no-textconv', $Test.Fixture.Target, 'HEAD', '--')
    [IO.File]::WriteAllBytes((Join-Path $Test.Config.state_dir 'patch.bin'), $patch)
    $value = Get-StageJson $Test 'result.json'
    $value.patch_sha256 = Get-StageHash $patch
    $value.tree_sha = Invoke-LocalGit $Test.Fixture $directory @('rev-parse', 'HEAD^{tree}')
    $value.commit_sha = Invoke-LocalGit $Test.Fixture $directory @('rev-parse', 'HEAD')
    Set-StageJson $Test 'result.json' $value
}

function Assert-StageTwoFileTree {
    param($Test, [string]$Ref)
    foreach ($entry in @{
        'src/one.al' = "ONE`ntwo`nthree`n"
        'src/two.al' = "ALPHA`nbeta`n"
        'src/release.al' = "release-only`nunchanged`n"
    }.GetEnumerator()) {
        [Convert]::ToHexString((Get-StageGitBytes $Test $Test.Fixture.Origin @('show', ($Ref + ':' + $entry.Key)))) |
            Should -BeExactly ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($entry.Value)))
    }
}

function Get-StageReceipt {
    param($Test, $Outcome)
    $artifacts = @{}
    foreach ($name in @('plan.json', 'tracking.json', 'result.json', 'patch.bin', 'publication.json')) {
        $path = Join-Path $Test.Config.state_dir $name
        if ([IO.File]::Exists($path)) { $artifacts[$name] = [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) }
    }
    @{
        outcome = $Outcome; artifacts = $artifacts
        output = [IO.File]::ReadAllText($Test.Config.output)
        summary = [IO.File]::ReadAllText($Test.Config.summary)
        calls = @($Test.Api.calls | Where-Object { -not (Test-BackportPolicyGet $_) })
        issues = @($Test.Api.issues.ToArray())
        git_effects = @($Test.GitEffects.ToArray())
        pulls = @($Test.Api.pulls.ToArray()); comments = (ConvertTo-StageComments $Test.Api.comments)
        refs = (Invoke-StageFixtureGit $Test @('show-ref'))
    }
}

function ConvertTo-StageComments {
    param($Comments)
    $value = @{}
    foreach ($key in $Comments.Keys) { $value[[string]$key] = @($Comments[$key].ToArray()) }
    return $value
}

function ConvertTo-BackportReferenceBytes {
    param([AllowNull()]$Value, [switch]$IgnorePrTitles)
    if ($IgnorePrTitles) {
        $Value = Copy-BackportTestValue $Value
        $api = if ($Value.ContainsKey('before')) { $Value.before.api } else { $Value.api }
        if ($api.source -is [Collections.IDictionary]) { $api.source.Remove('title') }
        foreach ($pull in $api.pulls) { $pull.Remove('title') }
        foreach ($call in $api.calls) {
            if ($call.method -ceq 'POST' -and $call.path -ceq '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls') {
                $call.data.Remove('title')
            }
        }
    }
    function ConvertTo-OrderedReference {
        param([AllowNull()]$Item)
        if ($Item -is [Collections.IDictionary]) {
            $ordered = [ordered]@{}
            $keys = [string[]]@($Item.psbase.Keys)
            [Array]::Sort($keys, [StringComparer]::Ordinal)
            foreach ($key in $keys) { $ordered[$key] = ConvertTo-OrderedReference $Item[$key] }
            return ,$ordered
        }
        if ($null -ne $Item -and $Item -isnot [string] -and $Item -is [Collections.IEnumerable]) {
            return ,@($Item | ForEach-Object { ConvertTo-OrderedReference $_ })
        }
        return ,$Item
    }
    return ,[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject (ConvertTo-OrderedReference $Value) -Depth 100 -Compress))
}

function Assert-BackportReferencePath {
    param($Test, [string]$Path)
    $path = [IO.Path]::GetFullPath($Path)
    if (-not $path.StartsWith($Test.Fixture.Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
        throw 'reference_path_outside_fixture'
    }
    while ($path -cne $Test.Fixture.Root) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reference_linked_path' }
        $path = [IO.Path]::GetDirectoryName($path)
    }
    Assert-LocalGitFixture $Test.Fixture
}

function Get-BackportReferenceSnapshot {
    param($Test)
    Assert-LocalGitFixture $Test.Fixture
    $artifacts = @{}
    foreach ($name in @('plan.json', 'tracking.json', 'result.json', 'patch.bin', 'publication.json')) {
        $path = Join-Path $Test.Config.state_dir $name
        Assert-BackportReferencePath $Test $path
        if ([IO.File]::Exists($path)) { $artifacts[$name] = [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) }
    }
    $api = @{}
    foreach ($key in @('repo', 'source', 'commits', 'target', 'actor', 'issues', 'pulls', 'comments', 'calls', 'runs')) {
        $api[$key] = if ($key -ceq 'comments') { ConvertTo-StageComments $Test.Api.comments } else { Copy-BackportTestValue $Test.Api.$key }
    }
    # The frozen manual oracle predates only these two fixed policy GET routes.
    $api.calls = @($api.calls | Where-Object { -not (Test-BackportPolicyGet $_) })
    $snapshot = @{
        artifacts = $artifacts; api = $api; git_effects = @($Test.GitEffects.ToArray())
        refs = (Invoke-StageFixtureGit $Test @('show-ref')); output = $null; summary = $null
    }
    foreach ($key in @('output', 'summary')) {
        $path = $Test.Config[$key]
        if ($path) {
            Assert-BackportReferencePath $Test $path
            if ([IO.File]::Exists($path)) { $snapshot[$key] = [IO.File]::ReadAllText($path) }
        }
    }
    return $snapshot
}

function Get-BackportReferenceInput {
    param($Test, [string[]]$Stages, [switch]$CaptureFailure, [AllowNull()]$UserResponse)
    Assert-LocalGitFixture $Test.Fixture
    $environment = Copy-BackportTestValue $Test.Environment
    if ($environment.GH_TOKEN -cne 'offline-fixture') { throw 'synthetic_credential_required' }
    if (-not [string]::Equals($environment.GITHUB_EVENT_NAME, 'workflow_dispatch', [StringComparison]::Ordinal)) {
        throw 'label_not_historical_reference'
    }
    $null = & $Test.Module { param($e) New-BackportContext -Environment $e } $environment
    # The captured manual baseline predates platform-event admission; never recapture or relax its hash.
    foreach ($key in @('GITHUB_EVENT_NAME', 'GITHUB_EVENT_PATH', 'GITHUB_WORKFLOW_REF', 'GITHUB_WORKFLOW_SHA')) {
        $environment.Remove($key)
    }
    $environment.Remove('GH_TOKEN')
    foreach ($key in @('RUNNER_TEMP', 'STATE_DIR', 'WORK_DIR', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'GITHUB_SUMMARY')) {
        if ($environment.ContainsKey($key)) {
            $path = [IO.Path]::GetFullPath($environment[$key])
            Assert-BackportReferencePath $Test $path
            $environment[$key] = '<fixture-root>/' + [IO.Path]::GetRelativePath($Test.Fixture.Root, $path).Replace('\', '/')
        }
    }
    $input = @{
        environment = $environment; stages = @($Stages); capture_failure = [bool]$CaptureFailure
        before = Get-BackportReferenceSnapshot $Test
        fixture = @{ head = $Test.Fixture.Head; source = $Test.Fixture.Source; target = $Test.Fixture.Target; commits = @($Test.Fixture.Commits) }
    }
    if ($PSBoundParameters.ContainsKey('UserResponse')) {
        $input.user_response_json = [Text.Encoding]::UTF8.GetString((ConvertTo-BackportReferenceBytes $UserResponse))
        if ($null -ne $UserResponse -and $UserResponse.ContainsKey('login') -and
            $UserResponse.login -is [double] -and -not [double]::IsFinite($UserResponse.login)) {
            $input.user_login_float = $UserResponse.login.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    return $input
}

function Get-BackportStageReferences {
    param([AllowNull()]$Reference)
    if (-not $PSBoundParameters.ContainsKey('Reference')) {
        $platform = if ($IsWindows) { 'Windows' } elseif ($IsLinux) { 'Linux' } else { throw 'unsupported_reference_platform' }
        $parity = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'parity.json'))) -AsHashtable -Depth 100
        $Reference = if ($platform -ceq 'Windows') { $parity.stage_reference } else { $parity.stage_reference_linux }
        if ($Reference.runtime.os -cne $platform) { throw 'invalid_stage_reference_platform' }
    }
    if ($reference -isnot [Collections.IDictionary] -or $reference.schema -ne 1 -or
        $reference.baseline_commit -cne '514500f55f064aa9ab86607e6d0803f2abd6376c') { throw 'invalid_stage_reference' }
    if ($reference.runtime.os -cnotin @('Windows', 'Linux')) { throw 'invalid_stage_reference_platform' }
    $expectedEnvelopeHash = '02b30d6e124c49bf167f994d4a2512231e26a0ce01309b30d7dd574fba5ad282'
    $envelope = $reference
    if ($reference.runtime.os -ceq 'Linux') {
        $expectedEnvelopeHash = '463edd62c57358932ccd3e066d2a63fb345c32c7d41178e8093a27b61b112360'
        if ($reference.envelope_sha256 -cne $expectedEnvelopeHash) { throw 'stage_reference_hash_mismatch' }
        $envelope = @{}
        foreach ($key in $reference.psbase.Keys) {
            if ($key -cne 'envelope_sha256') { $envelope[$key] = $reference[$key] }
        }
    }
    $envelopeHash = Get-StageHash (ConvertTo-BackportReferenceBytes $envelope)
    if ($envelopeHash -cne $expectedEnvelopeHash) {
        throw 'stage_reference_hash_mismatch'
    }
    $payloadHash = Get-StageHash (ConvertTo-BackportReferenceBytes @{ records = $reference.records; state = $reference.state })
    if ($payloadHash -cne $reference.payload_sha256) { throw 'stage_reference_hash_mismatch' }
    $bytes = ConvertTo-BackportReferenceBytes $reference.records
    if ((Get-StageHash $bytes) -cne $reference.records_sha256) { throw 'stage_reference_hash_mismatch' }
    return $reference
}

function Invoke-ReferenceStageHandoff {
    param($Test, [string[]]$Stages, [switch]$CaptureFailure, [AllowNull()]$UserResponse)
    $input = Get-BackportReferenceInput @PSBoundParameters
    $key = Get-StageHash (ConvertTo-BackportReferenceBytes $input -IgnorePrTitles)
    $references = Get-BackportStageReferences
    # Display titles have their own tests; historical stage effects remain authoritative.
    $matchingKeys = @($references.records.Keys | Where-Object {
        (Get-StageHash (ConvertTo-BackportReferenceBytes $references.records[$_].input -IgnorePrTitles)) -ceq $key
    })
    if ($matchingKeys.Count -eq 0) { throw 'uncaptured_stage_reference_input' }
    if ($matchingKeys.Count -ne 1) { throw 'ambiguous_stage_reference_input' }
    $reference = $references.records[$matchingKeys[0]]
    if ((Get-StageHash (ConvertTo-BackportReferenceBytes $reference.input)) -cne $matchingKeys[0]) { throw 'stage_reference_input_mismatch' }
    $filter = $Test.HttpFilter
    if ($PSBoundParameters.ContainsKey('UserResponse')) {
        $Test.HttpFilter = {
            param($fixture, $method, $path, $data)
            $value = Invoke-FakeGitHub $fixture.Api $method $path $data
            if ($method -ceq 'GET' -and $path.StartsWith('/users/', [StringComparison]::Ordinal)) { return ,$UserResponse }
            return ,$value
        }
    }
    $outcomes = [Collections.Generic.List[object]]::new()
    $failure = $null
    try {
        foreach ($stage in $Stages) { $outcomes.Add((Invoke-BackportTestStage $Test $stage)) }
    }
    catch {
        if (-not $CaptureFailure) { throw }
        $failure = $_.Exception.Message
    }
    finally { $Test.HttpFilter = $filter }
    $snapshot = Get-BackportReferenceSnapshot $Test
    $response = @{ outcomes = @($outcomes.ToArray()); failure = $failure; api = $snapshot.api; git_effects = $snapshot.git_effects }
    foreach ($pair in @(@{ actual = $response; expected = $reference.response; name = 'response' },
        @{ actual = $snapshot; expected = $reference.after; name = 'receipt' })) {
        if ((Get-StageHash (ConvertTo-BackportReferenceBytes $pair.actual -IgnorePrTitles)) -cne
            (Get-StageHash (ConvertTo-BackportReferenceBytes $pair.expected -IgnorePrTitles))) {
            throw ('stage_reference_' + $pair.name + '_mismatch')
        }
    }
    foreach ($name in $reference.after.artifacts.Keys) {
        $path = Join-Path $Test.Config.state_dir $name
        Assert-BackportReferencePath $Test $path
        [IO.File]::WriteAllBytes($path, [Convert]::FromHexString($reference.after.artifacts[$name]))
    }
    return $response
}

function Copy-BackportTestValue {
    param([AllowNull()]$Value)
    return ,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100 -Compress) -AsHashtable -Depth 100 -NoEnumerate)
}

function New-FakeGitHub {
    param(
        $Fixture,
        [string]$Head = ('1' * 40),
        [string]$Source = ('2' * 40),
        [string]$Target = ('3' * 40),
        [string[]]$Commits = @()
    )
    $repo = @{ id = 1369849596; full_name = 'AleksanderGladkov/BCApps-Backport-Test' }
    $api = [pscustomobject]@{
        fixture = $Fixture; origin = $Fixture.Origin; repo = $repo
        source = @{
            number = 7; title = 'Update AL source'; merged = $true; merge_commit_sha = $Source
            head = @{ sha = $Head }; changed_files = 1
            base = @{ ref = 'main'; repo = (Copy-BackportTestValue $repo) }
        }
        commits = [Collections.Generic.List[object]]::new()
        target = $Target; actor = 59250993
        issues = [Collections.Generic.List[object]]::new()
        pulls = [Collections.Generic.List[object]]::new()
        comments = @{}
        calls = [Collections.Generic.List[object]]::new()
        fail_post = $null; lose_post_response = $null
        fail_patch = $null; lose_patch_response = $null
        runs = [Collections.Generic.List[object]]::new()
        attempts = @{}; jobs = @{}
        policy_bytes = (New-BackportTestPolicyBytes); policy_main_sha = ('c' * 40)
        stale_paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
    foreach ($commit in $Commits) { $api.commits.Add(@{ sha = $commit }) }
    $api
}

function New-FakeWorkflowRun {
    param(
        [Parameter(Mandatory)]$Api,
        [long]$Id = 123,
        [int]$SourcePr = 7,
        [bool]$DryRun = $false,
        [int]$Attempt = 1,
        [ValidateSet('workflow_dispatch', 'pull_request_target')][string]$Event = 'workflow_dispatch'
    )
    $run = @{
        id = $Id; workflow_id = 456; run_attempt = $Attempt
        repository = (Copy-BackportTestValue $Api.repo)
        head_repository = (Copy-BackportTestValue $Api.repo)
        path = '.github/workflows/backport-demo.yml'; event = $Event; head_branch = 'main'
        display_title = "Backport PR $SourcePr to 29.x (dry run = $($DryRun.ToString().ToLowerInvariant()))"
    }
    if ($Event -ceq 'pull_request_target') {
        $run.name = 'Backport to 29.x'
        $run.head_sha = $Api.source.merge_commit_sha
        $run.status = 'in_progress'; $run.conclusion = $null
        $run.pull_requests = @()
    }
    return $run
}

function Add-BackportRejectedLabelRun {
    param($Api, [long]$Id = 122, [int]$Attempts = 1, [string]$Title)
    $run = New-FakeWorkflowRun -Api $Api -Id $Id -Attempt $Attempts -Event pull_request_target
    if ($PSBoundParameters.ContainsKey('Title')) { $run.display_title = $Title }
    $run.status = 'completed'; $run.conclusion = 'failure'
    $Api.runs.Add($run)
    foreach ($attempt in 1..$Attempts) {
        $value = Copy-BackportTestValue $run
        $value.run_attempt = $attempt
        $Api.attempts["$Id/$attempt"] = $value
        $jobs = @(
            foreach ($index in 0..3) {
                @{
                    id = (10000 * $attempt + $index + 1); run_id = $Id; run_attempt = $attempt
                    head_sha = $run.head_sha; head_branch = $run.head_branch; workflow_name = $run.display_title
                    name = @('validate', 'track', 'prepare', 'publish')[$index]
                    status = 'completed'; conclusion = $(if ($index -eq 0) { 'failure' } else { 'skipped' })
                    steps = @()
                }
            }
        )
        $Api.jobs["$Id/$attempt"] = @{ total_count = 4; jobs = $jobs }
    }
    return $run
}

function Invoke-FakeGitHub {
    param(
        [Parameter(Mandatory, Position = 0)]$Api,
        [Parameter(Mandatory, Position = 1)][string]$Method,
        [Parameter(Mandatory, Position = 2)][string]$Path,
        [Parameter(Position = 3)][AllowNull()]$Data
    )
    $Api.calls.Add(@{ method = $Method; path = $Path; data = (Copy-BackportTestValue $Data) })
    $parts = $Path.Split('?', 2)
    $route = $parts[0]
    $root = '/repos/' + $Api.repo.full_name
    $query = @{}
    if ($parts.Count -eq 2) {
        foreach ($part in $parts[1].Split('&')) {
            $pair = $part.Split('=', 2)
            if ($pair.Count -ne 2 -or $query.ContainsKey($pair[0])) { throw 'unexpected_fake_request: query' }
            $query[$pair[0]] = [uri]::UnescapeDataString($pair[1])
        }
    }
    $page = 1
    if ($query.ContainsKey('page')) {
        if ($query.page -notmatch '^[1-9][0-9]{0,6}$') { throw 'unexpected_fake_request: page' }
        $page = [int]$query.page
    }
    if ($query.ContainsKey('per_page') -and $query.per_page -ne '100') { throw 'unexpected_fake_request: page size' }
    foreach ($key in $query.Keys) {
        if ($key -notin @('page', 'per_page', 'state') -and -not (
            $key -ceq 'ref' -and $Method -ceq 'GET' -and
            $route -ceq "$root/contents/.github/scripts/backport-demo/request-policy.json"
        )) { throw 'unexpected_fake_request: query key' }
    }
    if ($Method -ceq 'POST' -and $Api.fail_post -ceq $route) { throw 'api_write_ambiguous' }
    if ($Method -ceq 'PATCH' -and $Api.fail_patch -ceq $route) { throw 'api_write_ambiguous' }
    $value = $null
    $found = $false
    $escapedRoot = [regex]::Escape($root)
    switch -CaseSensitive ($Method) {
        GET {
            $found = $true
            if ($route -cmatch '^/users/[a-zA-Z0-9-]+$') {
                $value = @{ id = $Api.actor; login = 'AleksanderGladkov' }
            }
            elseif ($route -ceq $root) { $value = $Api.repo }
            elseif ($route -ceq "$root/git/ref/heads/main") {
                if ($query.Count -ne 0) { throw 'unexpected_fake_request: main ref query' }
                $value = @{ ref = 'refs/heads/main'; object = @{ type = 'commit'; sha = $Api.policy_main_sha } }
            }
            elseif ($route -ceq "$root/contents/.github/scripts/backport-demo/request-policy.json") {
                if ($query.Count -ne 1 -or $query.ref -cne $Api.policy_main_sha) { throw 'unexpected_fake_request: policy revision' }
                $value = @{
                    type = 'file'; path = '.github/scripts/backport-demo/request-policy.json'; encoding = 'base64'
                    content = [Convert]::ToBase64String($Api.policy_bytes); size = $Api.policy_bytes.Length
                }
            }
            elseif ($route -ceq "$root/pulls/7") { $value = $Api.source }
            elseif ($route -ceq "$root/pulls/7/commits") {
                $value = @($Api.commits | Select-Object -Skip (($page - 1) * 100) -First 100)
            }
            elseif ($route -ceq "$root/branches/releases%2F29.x") {
                $value = @{ commit = @{ sha = $Api.target } }
            }
            elseif ($route -cmatch "^$escapedRoot/actions/runs/([1-9][0-9]*)$") {
                $items = @($Api.runs | Where-Object { $_.id -eq [long]$Matches[1] })
                if ($items.Count -ne 1) { throw 'unexpected_fake_request: run ID' }
                $value = $items[0]
            }
            elseif ($route -cmatch "^$escapedRoot/actions/runs/([1-9][0-9]*)/attempts/([1-9][0-9]*)(/jobs)?$") {
                $key = $Matches[1] + '/' + $Matches[2]
                if ($Matches[3] -ceq '/jobs') {
                    if ($query.Count -ne 2 -or $query.per_page -cne '100' -or $query.page -cne '1' -or
                        -not $Api.jobs.ContainsKey($key)) { throw 'unexpected_fake_request: attempt jobs' }
                    $value = $Api.jobs[$key]
                }
                else {
                    if ($query.Count -ne 0 -or -not $Api.attempts.ContainsKey($key)) { throw 'unexpected_fake_request: attempt' }
                    $value = $Api.attempts[$key]
                }
            }
            elseif ($route -ceq "$root/actions/workflows/backport-demo.yml/runs") {
                if ($query.Count -ne 2 -or -not $query.ContainsKey('per_page') -or -not $query.ContainsKey('page')) {
                    throw 'unexpected_fake_request: run pagination'
                }
                $value = @{
                    total_count = $Api.runs.Count
                    workflow_runs = @($Api.runs | Select-Object -Skip (($page - 1) * 100) -First 100)
                }
            }
            elseif ($route -ceq "$root/issues" -or $route -ceq "$root/pulls") {
                $items = @($Api.pulls.ToArray())
                if ($route -ceq "$root/issues") {
                    $items = @($Api.issues.ToArray()) + @($Api.pulls | ForEach-Object {
                        $item = Copy-BackportTestValue $_
                        $item.pull_request = @{ html_url = $_.html_url }
                        $item
                    })
                }
                $value = @($items | Select-Object -Skip (($page - 1) * 100) -First 100)
            }
            elseif ($route -cmatch "^$escapedRoot/issues/([1-9][0-9]*)/comments$") {
                $value = @($Api.comments[[int]$Matches[1]] | Select-Object -Skip (($page - 1) * 100) -First 100)
            }
            elseif ($route -cmatch "^$escapedRoot/(issues|pulls)/([1-9][0-9]*)$") {
                $collection = if ($Matches[1] -ceq 'issues') { $Api.issues } else { $Api.pulls }
                $number = [int]$Matches[2]
                $items = @($collection | Where-Object { $_.number -eq $number })
                if ($items.Count -ne 1) { throw 'unexpected_fake_request: object ID' }
                $value = $items[0]
            }
            else { $found = $false }
        }
        POST {
            $found = $true
            if ($route -ceq "$root/issues") {
                $number = 101
                while ($number -in @($Api.issues.number) + @($Api.pulls.number)) { $number++ }
                $value = Copy-BackportTestValue $Data
                $value.number = $number; $value.id = 900 + $number; $value.state = 'open'
                $value.html_url = "https://github.com/$($Api.repo.full_name)/issues/$number"
                $value.user = @{ id = 41898282 }
                $Api.issues.Add($value)
            }
            elseif ($route -ceq "$root/pulls") {
                if ($null -eq $Api.fixture) { throw 'local_git_fixture_required' }
                $head = Invoke-LocalGit $Api.fixture $Api.origin @('rev-parse', "refs/heads/$($Data.head)")
                $number = 102
                while ($number -in @($Api.issues.number) + @($Api.pulls.number)) { $number++ }
                $value = @{
                    number = $number; id = 900 + $number; state = 'open'; merged = $false
                    title = $Data.title; body = $Data.body; user = @{ id = 41898282 }
                    head = @{ sha = $head; ref = $Data.head; repo = (Copy-BackportTestValue $Api.repo) }
                    base = @{ ref = $Data.base; repo = (Copy-BackportTestValue $Api.repo) }
                    html_url = "https://github.com/$($Api.repo.full_name)/pull/$number"
                }
                $null = Invoke-LocalGit $Api.fixture $Api.origin @('update-ref', "refs/pull/$number/head", $head)
                $Api.pulls.Add($value)
            }
            elseif ($route -cmatch "^$escapedRoot/issues/([1-9][0-9]*)/comments$") {
                $number = [int]$Matches[1]
                if (-not $Api.comments.ContainsKey($number)) { $Api.comments[$number] = [Collections.Generic.List[object]]::new() }
                $value = Copy-BackportTestValue $Data
                $value.id = 2000 + $number + (100000 * $Api.comments[$number].Count)
                $value.user = @{ id = 41898282 }
                $Api.comments[$number].Add($value)
            }
            else { $found = $false }
            if ($found -and $Api.lose_post_response -ceq $route) { throw 'api_write_ambiguous' }
        }
        PATCH {
            if ($route -cmatch "^$escapedRoot/issues/comments/([1-9][0-9]*)$") {
                $id = [int]$Matches[1]
                $items = @($Api.comments.Values | ForEach-Object { $_ } | Where-Object { $_.id -eq $id })
                if ($items.Count -ne 1) { throw 'unexpected_fake_request: comment ID' }
                $value = $items[0]
                $copy = Copy-BackportTestValue $Data
                foreach ($key in $copy.Keys) { $value[$key] = $copy[$key] }
                $found = $true
                if ($Api.lose_patch_response -ceq $route) { throw 'api_write_ambiguous' }
            }
        }
    }
    if (-not $found) { throw "unexpected_fake_request: $Method $Path" }
    if ($Method -ceq 'GET' -and $Api.stale_paths.Contains($route)) { return ,@() }
    return ,(Copy-BackportTestValue $value)
}

function Assert-LocalFixturePath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\') -or $Path.StartsWith('//')) {
        throw 'local_git_denied: nonlocal path'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'local_git_denied: linked path' }
        $item = $item.Parent
    }
}

function Assert-LocalGitFixture {
    param($Fixture)
    if ($null -eq $Fixture -or -not $Fixture.Root -or -not $Fixture.Token) { throw 'unowned_fixture' }
    $root = [IO.Path]::GetFullPath($Fixture.Root)
    if ([IO.Path]::GetFileName($root) -cne ('fixture-' + $Fixture.Token)) { throw 'unowned_fixture' }
    $owners = Get-LocalGitFixtureOwners
    if (-not $owners.ContainsKey($root) -or $owners[$root] -cne $Fixture.Token) { throw 'unowned_fixture' }
    foreach ($entry in @{ Origin = 'origin'; EmptyHome = 'empty-home'; EmptyConfig = 'empty.config' }.GetEnumerator()) {
        if ($Fixture.($entry.Key) -and $Fixture.($entry.Key) -cne (Join-Path $root $entry.Value)) {
            throw 'local_git_denied: fixture path changed'
        }
    }
    Assert-LocalFixturePath $root
    $marker = Join-Path $root '.fixture-owner'
    if (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker) -cne $Fixture.Token) {
        throw 'unowned_fixture'
    }
}

function Get-LocalGitFixtureOwners {
    if (-not (Get-Variable -Name LocalGitFixtureOwners -Scope Script -ErrorAction SilentlyContinue)) {
        $script:LocalGitFixtureOwners = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    return ,$script:LocalGitFixtureOwners
}

function New-LocalGitEnvironment {
    param([Parameter(Mandatory)]$Fixture)
    Assert-LocalGitFixture $Fixture
    $environment = @{}
    foreach ($name in @('PATH', 'SystemRoot', 'WINDIR', 'SystemDrive', 'ComSpec', 'PATHEXT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $environment[$name] = $value }
    }
    foreach ($name in @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME')) {
        $environment[$name] = $Fixture.EmptyHome
    }
    $environment.TEMP = $environment.TMP = $Fixture.Root
    $environment.GIT_CONFIG_NOSYSTEM = '1'
    $environment.GIT_CONFIG_GLOBAL = $Fixture.EmptyConfig
    $environment.GIT_TERMINAL_PROMPT = '0'
    $environment.GIT_ATTR_NOSYSTEM = '1'
    $environment.GIT_ALLOW_PROTOCOL = 'file'
    $environment.GIT_PROTOCOL_FROM_USER = '0'
    $environment.GIT_AUTHOR_DATE = '2000-01-01T00:00:00Z'
    $environment.GIT_COMMITTER_DATE = '2000-01-01T00:00:00Z'
    $environment.LC_ALL = 'C'
    $environment
}

function Invoke-HarnessProcess {
    param([string]$FileName, [string[]]$Arguments, [hashtable]$Environment, [int]$TimeoutSeconds = 120)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FileName
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment.Clear()
    foreach ($key in $Environment.psbase.Keys) { $info.Environment[$key] = $Environment[$key] }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'test_process_start_failed' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'test_process_timeout'
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult()
            Stderr = $stderr.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

function Invoke-LocalGit {
    param(
        [Parameter(Mandatory, Position = 0)]$Fixture,
        [Parameter(Mandatory, Position = 1)][string]$Directory,
        [Parameter(Mandatory, Position = 2)][string[]]$Arguments
    )
    Assert-LocalGitFixture $Fixture
    $directoryPath = [IO.Path]::GetFullPath($Directory)
    if (-not $directoryPath.StartsWith($Fixture.Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        -not $Fixture.Repositories.Contains($directoryPath)) { throw 'local_git_denied: unregistered repository' }
    Assert-LocalFixturePath $directoryPath
    $gitDirectory = Join-Path $directoryPath '.git'
    if (Test-Path -LiteralPath $gitDirectory) {
        if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) { throw 'local_git_denied: external git directory' }
        Assert-LocalFixturePath $gitDirectory
    }
    $allowed = @('init', 'config', 'add', 'commit', 'branch', 'switch', 'checkout', 'merge', 'rev-parse',
        'rev-list', 'update-ref', 'diff', 'cat-file', 'merge-base', 'cherry-pick', 'apply', 'status',
        'log', 'show', 'reset', 'fetch', 'push', 'ls-remote', 'rebase', 'show-ref', 'ls-tree')
    if ($Arguments.Count -eq 0 -or $Arguments[0] -cnotin $allowed) { throw 'local_git_denied: command' }
    foreach ($argument in $Arguments) {
        if (($argument -cin @('-c', '-C') -and $Arguments[0] -cne 'switch') -or
            $argument -cmatch '^(-F$|--(config-env|git-dir|work-tree|exec-path|upload-pack|receive-pack|exec|output|file|template|recurse-submodules)(=|$))') {
            throw 'local_git_denied: unsafe option'
        }
    }
    if ($Arguments[0] -ceq 'config' -and
        ($Arguments.Count -ne 3 -or $Arguments[1] -cnotin @('user.name', 'user.email', 'core.autocrlf', 'core.longpaths'))) {
        throw 'local_git_denied: configuration'
    }
    # Implicit remotes, URL rewrites, includes, and executable local configuration
    # would bypass destination validation. Fixtures have only core and user keys.
    $configPath = Join-Path $directoryPath '.git\config'
    if (Test-Path -LiteralPath $configPath) {
        Assert-LocalFixturePath $configPath
        $section = ''
        foreach ($line in [IO.File]::ReadAllLines($configPath)) {
            if ($line -match '^\s*(#|;|$)') { continue }
            if ($line -match '^\s*\[([a-z]+)\]\s*$') {
                $section = $Matches[1]
                if ($section -notin @('core', 'user')) { throw 'local_git_denied: local config section' }
            }
            elseif ($line -match '^\s*([a-z]+)\s*=') {
                $key = $section + '.' + $Matches[1]
                if ($key -notin @('core.repositoryformatversion', 'core.filemode', 'core.bare', 'core.logallrefupdates',
                    'core.symlinks', 'core.ignorecase', 'core.autocrlf', 'core.longpaths', 'user.name', 'user.email')) {
                    throw 'local_git_denied: local config key'
                }
            }
            else { throw 'local_git_denied: local config syntax' }
        }
    }
    if ($Arguments[0] -cin @('fetch', 'push', 'ls-remote')) {
        $position = 1
        while ($position -lt $Arguments.Count -and $Arguments[$position].StartsWith('-')) {
            if ($Arguments[$position] -cnotin @('--heads', '--no-tags', '--no-recurse-submodules') -and
                -not ($Arguments[0] -ceq 'push' -and $Arguments[$position] -ceq '--porcelain')) {
                throw 'local_git_denied: transport option'
            }
            $position++
        }
        if ($position -ge $Arguments.Count -or $Arguments[$position] -cne $Fixture.Origin) {
            throw 'local_git_denied: destination'
        }
        Assert-LocalFixturePath $Arguments[$position]
        $leaseRef = $null
        for ($index = $position + 1; $index -lt $Arguments.Count; $index++) {
            if ($Arguments[$index].StartsWith('-')) {
                if ($Arguments[0] -ceq 'push' -and -not $leaseRef -and
                    $Arguments[$index] -cmatch '^--force-with-lease=(refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*):$') {
                    $leaseRef = $Matches[1]
                }
                else { throw 'local_git_denied: trailing transport option' }
            }
        }
        if ($leaseRef -and ($Arguments.Count -ne $position + 3 -or $Arguments[-1] -cne "HEAD:$leaseRef")) {
            throw 'local_git_denied: lease refspec mismatch'
        }
    }
    $safe = @(
        '-c', "core.hooksPath=$($Fixture.EmptyHome)", '-c', 'core.fsmonitor=false',
        '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-c', 'credential.helper=',
        '-c', 'protocol.allow=never', '-c', 'protocol.file.allow=always', '-c', 'protocol.ext.allow=never',
        '-c', 'http.followRedirects=false', '-c', 'submodule.recurse=false',
        '-c', 'core.autocrlf=false', '-c', 'core.longpaths=true', '-c', "core.attributesFile=$($Fixture.EmptyConfig)",
        '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-C', $directoryPath
    )
    if ($Arguments[0] -ceq 'init') { $Arguments += "--template=$($Fixture.EmptyHome)" }
    $result = Invoke-HarnessProcess -FileName (@(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source) `
        -Arguments ($safe + $Arguments) -Environment (New-LocalGitEnvironment $Fixture)
    if ($result.ExitCode -ne 0) { throw "local_git_failed: $($Arguments[0]): $($result.Stderr.Trim())" }
    if ($Arguments[0] -ceq 'push' -and $Fixture.LosePushResponse) { throw 'local_git_response_lost' }
    $result.Stdout.TrimEnd("`r", "`n")
}

function New-LocalGitFixture {
    param([Parameter(Mandatory)][string]$ParentPath)
    $parent = [IO.Path]::GetFullPath($ParentPath)
    Assert-LocalFixturePath $parent
    $token = [guid]::NewGuid().ToString('N')
    $root = Join-Path $parent ('fixture-' + $token)
    $null = [IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText((Join-Path $root '.fixture-owner'), $token)
    $fixture = [pscustomobject]@{
        Root = $root; Token = $token; Origin = (Join-Path $root 'origin')
        EmptyHome = (Join-Path $root 'empty-home'); EmptyConfig = (Join-Path $root 'empty.config')
        Repositories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Target = ''; Head = ''; Source = ''; Commits = @(); LosePushResponse = $false
    }
    (Get-LocalGitFixtureOwners).Add($root, $token)
    try {
        $null = [IO.Directory]::CreateDirectory($fixture.EmptyHome)
        [IO.File]::WriteAllText($fixture.EmptyConfig, '')
        $null = [IO.Directory]::CreateDirectory($fixture.Origin)
        $null = $fixture.Repositories.Add($fixture.Origin)
        $null = Invoke-LocalGit $fixture $fixture.Origin @('init', '-b', 'main')
        $null = [IO.Directory]::CreateDirectory((Join-Path $fixture.Origin 'src'))
        [IO.File]::WriteAllText((Join-Path $fixture.Origin '.gitattributes'), "*.al text eol=lf`n")
        [IO.File]::WriteAllText((Join-Path $fixture.Origin 'src\one.al'), "one`ntwo`nthree`n")
        $null = Invoke-LocalGit $fixture $fixture.Origin @('add', '.')
        $null = Invoke-LocalGit $fixture $fixture.Origin @('commit', '-m', 'base')
        $fixture.Target = Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'HEAD')
        $null = Invoke-LocalGit $fixture $fixture.Origin @('branch', 'releases/29.x')
        $null = Invoke-LocalGit $fixture $fixture.Origin @('switch', '-c', 'feature')
        [IO.File]::WriteAllText((Join-Path $fixture.Origin 'src\one.al'), "ONE`ntwo`nthree`n")
        $null = Invoke-LocalGit $fixture $fixture.Origin @('commit', '-am', 'feature')
        $fixture.Head = Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'HEAD')
        $fixture.Commits = @($fixture.Head)
        $null = Invoke-LocalGit $fixture $fixture.Origin @('update-ref', 'refs/pull/7/head', $fixture.Head)
        $null = Invoke-LocalGit $fixture $fixture.Origin @('switch', 'main')
        $null = Invoke-LocalGit $fixture $fixture.Origin @('merge', '--squash', 'feature')
        $null = Invoke-LocalGit $fixture $fixture.Origin @('commit', '-m', 'squash')
        $fixture.Source = Invoke-LocalGit $fixture $fixture.Origin @('rev-parse', 'HEAD')
        $fixture
    }
    catch {
        Remove-LocalGitFixture $fixture
        throw
    }
}

function New-LocalGitWorkingCopy {
    param([Parameter(Mandatory)]$Fixture)
    Assert-LocalGitFixture $Fixture
    $directory = Join-Path $Fixture.Root ('work-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($directory)
    $null = $Fixture.Repositories.Add($directory)
    $null = Invoke-LocalGit $Fixture $directory @('init', '-b', 'main')
    $null = Invoke-LocalGit $Fixture $directory @('fetch', '--no-tags', '--no-recurse-submodules', $Fixture.Origin,
        '+refs/heads/main:refs/remotes/demo/main', '+refs/heads/releases/29.x:refs/remotes/demo/target',
        '+refs/pull/7/head:refs/remotes/demo/head')
    $directory
}

function Remove-LocalGitFixture {
    param([Parameter(Mandatory)]$Fixture)
    Assert-LocalGitFixture $Fixture
    Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction Stop
    $null = (Get-LocalGitFixtureOwners).Remove($Fixture.Root)
}

function Invoke-HarnessPowerShell {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $environment = @{}
    foreach ($item in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if ($item.Key -notmatch '^(GIT_|GH_TOKEN$|GITHUB_TOKEN$)') { $environment[$item.Key] = $item.Value }
    }
    $environment.GIT_CONFIG_NOSYSTEM = '1'
    $environment.GIT_TERMINAL_PROMPT = '0'
    $environment.GIT_ALLOW_PROTOCOL = 'file'
    $executable = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    Invoke-HarnessProcess -FileName (Join-Path $PSHOME $executable) -Arguments $Arguments -Environment $environment
}

function Initialize-BackportTransportTestTypes {
    if ('Backport.Tests.HttpHandler' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Backport.Tests {
    public sealed class BodyStream : Stream {
        readonly byte[] data;
        readonly string mode;
        int position;
        public int BytesRead;
        public int LargestRead;
        public bool CancellationObserved;
        public bool Disposed;
        public BodyStream(byte[] value, string behavior) { data = value; mode = behavior; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => position; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => throw new InvalidOperationException("sync_body_read");
        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
            LargestRead = Math.Max(LargestRead, count);
            try {
                if (mode == "body-wait") await Task.Delay(Timeout.Infinite, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (mode == "body-throw") throw new IOException("sentinel-transport-secret");
                int size = Math.Min(count, data.Length - position);
                Array.Copy(data, position, buffer, offset, size);
                position += size;
                BytesRead += size;
                return size;
            } catch (OperationCanceledException) { CancellationObserved = true; throw; }
        }
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        protected override void Dispose(bool disposing) {
            Disposed = true;
            base.Dispose(disposing);
            if (mode == "body-dispose-throw") throw new IOException("sentinel-transport-secret");
        }
    }

    public sealed class HttpHandler : HttpMessageHandler {
        public byte[] Body = System.Text.Encoding.UTF8.GetBytes("{\"ok\":true}");
        public string Mode = "ok";
        public int Status = 200;
        public int Calls;
        public string Uri;
        public string Method;
        public string Authorization;
        public byte[] RequestBytes;
        public Dictionary<string, string> Headers = new Dictionary<string, string>();
        public bool CancellationObserved;
        public bool TokenCancelable;
        public bool Disposed;
        public BodyStream Stream;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
            Calls++;
            Uri = request.RequestUri.AbsoluteUri;
            Method = request.Method.Method;
            Authorization = request.Headers.Authorization?.ToString();
            TokenCancelable = token.CanBeCanceled;
            foreach (var header in request.Headers) Headers[header.Key] = string.Join(",", header.Value);
            if (request.Content != null) {
                RequestBytes = await request.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
                foreach (var header in request.Content.Headers) Headers[header.Key] = string.Join(",", header.Value);
            }
            try {
                if (Mode == "headers-wait") await Task.Delay(Timeout.Infinite, token).ConfigureAwait(false);
                if (Mode == "throw") throw new HttpRequestException("sentinel-transport-secret");
                Stream = new BodyStream(Body, Mode);
                var result = new HttpResponseMessage((HttpStatusCode)Status) { Content = new StreamContent(Stream) };
                if (Status >= 300 && Status < 400) result.Headers.Location = new System.Uri("https://example.invalid/denied");
                return result;
            } catch (OperationCanceledException) { CancellationObserved = true; throw; }
        }
        protected override void Dispose(bool disposing) {
            Disposed = true;
            base.Dispose(disposing);
            if (Mode == "dispose-throw") throw new IOException("sentinel-transport-secret");
        }
    }
}
'@
}

function New-BackportProcessFixture {
    param([Parameter(Mandatory)][string]$ParentPath)
    Assert-LocalFixturePath $ParentPath
    $root = Join-Path $ParentPath ('process-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($root)
    $path = Join-Path $root 'child.ps1'
    [IO.File]::WriteAllText($path, @'
$ErrorActionPreference = 'Stop'
$mode = $args[0]
switch ($mode) {
    'args' {
        $values = [string[]]$args[1..($args.Count - 1)]
        $json = ConvertTo-Json -InputObject $values -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
    }
    'pressure' {
        $bytes = [Text.Encoding]::UTF8.GetBytes(('sentinel-transport-secret' * 90000))
        [Console]::OpenStandardError().Write($bytes, 0, $bytes.Length)
        $prefix = [byte[]]::new(2 * 1024 * 1024)
        [Array]::Fill[byte]($prefix, 42)
        [Console]::OpenStandardOutput().Write($prefix, 0, $prefix.Length)
        [Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())
    }
    'exit' {
        [Console]::Error.Write('sentinel-transport-secret')
        exit [int]$args[1]
    }
    'tree' {
        [IO.File]::WriteAllText($args[1], [string]$PID)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = (Get-Process -Id $PID).Path
        $info.UseShellExecute = $false
        foreach ($value in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, 'leaf', $args[2])) {
            $info.ArgumentList.Add($value)
        }
        $child = [Diagnostics.Process]::Start($info)
        try { $child.WaitForExit() } finally { $child.Dispose() }
    }
    'leaf' {
        [IO.File]::WriteAllText($args[1], [string]$PID)
        Start-Sleep -Seconds 60
    }
    default { throw 'unknown_process_fixture' }
}
'@)
    [pscustomobject]@{ Root = $root; Script = $path }
}

function New-BackportProcessFixtureStartInfo {
    param([Parameter(Mandatory)]$Fixture, [string[]]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($key in @($info.Environment.psbase.Keys)) {
        if ($key -imatch '^(GIT_|GH_TOKEN$|GITHUB_TOKEN$)') { $null = $info.Environment.Remove($key) }
    }
    foreach ($value in (@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Fixture.Script) + $Arguments)) {
        $info.ArgumentList.Add($value)
    }
    $info
}

function Invoke-ReferenceStateHandoff {
    param([string]$StateDirectory, [ValidateSet('seed', 'verify')][string]$Mode)
    $reference = Get-BackportStageReferences
    $record = $reference.state[$Mode]
    if ($null -eq $record -or (Get-StageHash (ConvertTo-BackportReferenceBytes $record)) -cne $reference.state_sha256[$Mode]) {
        throw 'state_reference_hash_mismatch'
    }
    $parity = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'parity.json'))) -AsHashtable -Depth 100
    foreach ($id in @('plan', 'tracking-tracked', 'result-applied', 'publication')) {
        $vector = @($parity.vectors | Where-Object id -CEQ $id)[0]
        $name = $id.Split('-')[0] + '.json'
        $bytes = [Convert]::FromHexString($record.artifacts[$name])
        if ((Get-StageHash $bytes) -cne $vector.sha256 -or
            [Convert]::ToHexString($bytes).ToLowerInvariant() -cne $vector.utf8_hex) { throw 'state_reference_vector_mismatch' }
        if ($Mode -ceq 'seed') {
            $null = [IO.Directory]::CreateDirectory($StateDirectory)
            [IO.File]::WriteAllBytes((Join-Path $StateDirectory $name), $bytes)
        }
        if ([Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $StateDirectory $name))) -cne [Convert]::ToHexString($bytes)) {
            throw 'state_reference_bytes_mismatch'
        }
    }
}
