# Exact leaf It names map to parity.baseline_tests[].pester_name, case-sensitively.
# TEST-013..TEST-024 tags identify migration coverage, including inherited tags.
# LT-01..LT-13 tags identify required label and live-policy coverage.
# EPIC selection is development feedback only, never full acceptance.
# Setup: Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Repository PSGallery
[CmdletBinding()]
param(
    [ValidateSet('EPIC-001', 'EPIC-002', 'EPIC-003', 'L-001', 'L-002', 'L-003')][string]$Epic,
    [string]$ResultPath,
    [string]$ParityPath
)

function Assert-BackportRuntime {
    param(
        [version]$PowerShellVersion = $PSVersionTable.PSVersion,
        [version]$DotNetVersion = [Environment]::Version
    )
    if ($PowerShellVersion -lt [version]'7.4' -or $DotNetVersion -lt [version]'8.0') {
        throw 'PowerShell 7.4+ and .NET 8+ are required.'
    }
}

function Get-BackportDefaultResultPath {
    $directory = [IO.Path]::GetTempPath().TrimEnd('\', '/')
    $ancestor = [IO.DirectoryInfo]::new($PSScriptRoot)
    while ($null -ne $ancestor -and -not (Test-Path -LiteralPath (Join-Path $ancestor.FullName '.git'))) {
        $ancestor = $ancestor.Parent
    }
    if ($null -eq $ancestor) { throw 'Repository root unavailable; specify an external ResultPath.' }
    $repository = $ancestor.FullName
    if ($directory.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
        $directory.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TEMP is inside the repository; specify an external ResultPath.'
    }
    Join-Path $directory ('backport-pester-' + [guid]::NewGuid().ToString('N') + '.xml')
}

function Get-BackportTestTags {
    param($Test)
    $tags = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($tag in $Test.Tag) { $null = $tags.Add([string]$tag) }
    $block = $Test.Block
    $seen = [Collections.Generic.HashSet[object]]::new()
    while ($null -ne $block -and $seen.Add($block)) {
        foreach ($tag in $block.Tag) { $null = $tags.Add([string]$tag) }
        $block = $block.Parent
    }
    return ,$tags
}

function Get-BackportLabelWorkflowEdits {
    $source = '${{ github.event_name == ''pull_request_target'' && github.event.pull_request.number || inputs.source_pr }}'
    $dry = '${{ github.event_name == ''workflow_dispatch'' && inputs.dry_run && ''true'' || ''false'' }}'
    @(
        @{
            Before = 'run-name: Backport PR ${{ inputs.source_pr }} to 29.x (dry run = ${{ inputs.dry_run }})'
            After = "run-name: Backport PR $source to 29.x (dry run = $dry)"; Count = 1
        }
        @{
            Before = "on:`n  workflow_dispatch:"
            After = "on:`n  pull_request_target:`n    types: [labeled]`n    branches: [main]`n  workflow_dispatch:"; Count = 1
        }
        @{
            Before = '  group: backport-demo-${{ github.repository_id }}-${{ inputs.source_pr }}-29'
            After = '  group: backport-demo-${{ github.repository_id }}-${{ (github.event_name == ''workflow_dispatch'' || (github.event_name == ''pull_request_target'' && github.event.action == ''labeled'' && github.event.label.name == ''backport:29.x'' && github.event.pull_request.merged == true && github.event.pull_request.state == ''closed'' && github.event.pull_request.base.ref == ''main'' && github.event.repository.id == 1369849596 && github.event.repository.full_name == ''AleksanderGladkov/BCApps-Backport-Test'' && github.event.pull_request.base.repo.id == 1369849596 && github.event.pull_request.base.repo.full_name == ''AleksanderGladkov/BCApps-Backport-Test'' && github.event.number == github.event.pull_request.number && github.event.number > 0 && github.event.number < 2147483648)) && (github.event_name == ''pull_request_target'' && github.event.pull_request.number || inputs.source_pr) || format(''rejected-{0}'', github.run_id) }}-29'
            Count = 1
        }
        @{ Before = '  INPUT_SOURCE_PR: ${{ inputs.source_pr }}'; After = "  INPUT_SOURCE_PR: $source"; Count = 1 }
        @{ Before = '  INPUT_DRY_RUN: ${{ inputs.dry_run && ''true'' || ''false'' }}'; After = "  INPUT_DRY_RUN: $dry"; Count = 1 }
        @{
            Before = '          ref: ${{ github.sha }}'
            After = '          ref: ${{ github.workflow_sha }}'; Count = 4
        }
        @{
            Before = "  validate:`n"
            After = "  validate:`n    outputs:`n" + '      plan_ready: ${{ steps.validate.outputs.plan_ready }}' + "`n"; Count = 1
        }
        @{
            Before = "      - name: Validate requester, source history and target`n"
            After = "      - name: Validate requester, source history and target`n        id: validate`n"; Count = 1
        }
        @{
            Before = "  track:`n    needs: validate`n"
            After = "  track:`n    needs: validate`n    if: needs.validate.outputs.plan_ready == 'true'`n"; Count = 1
        }
    )
}

function ConvertFrom-BackportLabelWorkflow {
    param([string]$Text)
    # Reverse only the explicitly asserted feature delta, then require the complete historical hash and blocks.
    foreach ($edit in Get-BackportLabelWorkflowEdits) {
        if ([regex]::Matches($Text, [regex]::Escape($edit.After)).Count -ne $edit.Count) { throw 'workflow_baseline_mismatch' }
        $Text = $Text.Replace($edit.After, $edit.Before)
    }
    $Text
}

function Assert-BackportWorkflowBaseline {
    param($Parity, [string]$ProductionText, [string]$TestsText)
    $expected = @{
        production = @{
            Path = '.github/workflows/backport-demo.yml'
            Hash = 'ea06994495c62db9a9fd14802fbbd273b762be938588028ed8d8057d9ec2a9fb'
            CutoverHash = '17cbd7cc727333a9e33781687338e64716efb790b289d934ebcdc0183650ad9f'
            Node24Hash = 'cd79e19cbf8d0ac7e05435d7b74efdb3ccdc863329292ce6540ebff843792d78'
            BlocksHash = 'ddb57d69cf5d4b44624378a3fe7e1e59181a250f931c577d3c090467ee2e23ce'
            Text = $ProductionText
            Blocks = 16
        }
        tests = @{
            Path = '.github/workflows/backport-demo-tests.yml'
            Hash = '2dbcc9f5ab13aa7d621852eed58cf6c83dd1200c5ce5dce5006c0de6dcff7af2'
            CutoverHash = '603902c8b24afaa1a50bcdc23d660c507b80be8edc26f979bade184eb481191c'
            FinalHash = 'a9213eeafd609f37ec0dc1b1b5da6505ded9559fc048ee770a8badd968e3b7cd'
            Node24Hash = 'f4e88dde4740a74bc819c0d910992cfa3a626dec958e1a09ad45efaf5f1b5c89'
            BlocksHash = 'fa08ef48189fc34683cb4fd039af39ea91ed101fef53a32d12bb06164845f528'
            Text = $TestsText
            Blocks = 4
        }
    }
    foreach ($kind in @('production', 'tests')) {
        $entry = $Parity.workflow_baseline[$kind]
        $contract = $expected[$kind]
        if (-not [string]::Equals($entry.path, $contract.Path, [StringComparison]::Ordinal) -or
            -not [string]::Equals($entry.sha256_lf, $contract.Hash, [StringComparison]::Ordinal)) {
            throw 'workflow_baseline_mismatch'
        }
        $text = $contract.Text.Replace("`r`n", "`n")
        if ($kind -ceq 'production' -and $text.Contains('pull_request_target', [StringComparison]::Ordinal)) {
            $text = ConvertFrom-BackportLabelWorkflow $text
        }
        $hash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))
        ).ToLowerInvariant()
        $cutover = $hash.Equals($contract.CutoverHash, [StringComparison]::Ordinal)
        $final = $kind -ceq 'tests' -and $hash.Equals($contract.FinalHash, [StringComparison]::Ordinal)
        $node24 = $hash.Equals($contract.Node24Hash, [StringComparison]::Ordinal)
        if ((-not $hash.Equals($contract.Hash, [StringComparison]::Ordinal) -and -not $cutover -and -not $final -and -not $node24) -or
            @($entry.protected_blocks).Count -ne $contract.Blocks) {
            throw 'workflow_baseline_mismatch'
        }
        $blocksBytes = [Text.Encoding]::UTF8.GetBytes(
            (ConvertTo-Json -InputObject $entry.protected_blocks -Depth 3 -Compress)
        )
        $blocksHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($blocksBytes)
        ).ToLowerInvariant()
        if (-not $blocksHash.Equals($contract.BlocksHash, [StringComparison]::Ordinal)) {
            throw 'workflow_baseline_mismatch'
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($block in $entry.protected_blocks) {
            if ($block -isnot [string] -or -not $block -or -not $seen.Add($block)) {
                throw 'workflow_baseline_mismatch'
            }
            $requiredBlock = $block
            if (($cutover -or $final -or $node24) -and $kind -ceq 'tests') {
                $checkout = @(
                    '          sparse-checkout: |'
                    '            .github/scripts/backport-demo'
                    '            .github/workflows/backport-demo.yml'
                    '            .github/workflows/backport-demo-tests.yml'
                    '          sparse-checkout-cone-mode: false'
                ) -join "`n"
                $requiredBlock = $block.Replace("          sparse-checkout: .github/scripts/backport-demo`n",
                    $checkout + "`n")
            }
            if ($node24) {
                $requiredBlock = $requiredBlock.
                    Replace('actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4', 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1').
                    Replace('actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4', 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1').
                    Replace('actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4', 'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1')
            }
            if (-not $text.Contains($requiredBlock, [StringComparison]::Ordinal)) {
                throw 'workflow_baseline_mismatch'
            }
        }
    }
}

function Test-BackportAcceptance {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result,
        [AllowNull()]$Parity,
        [ValidateSet('EPIC-001', 'EPIC-002', 'EPIC-003', 'L-001', 'L-002', 'L-003')][string]$Epic
    )
    $errors = [Collections.Generic.List[string]]::new()
    $tests = @($Result.Tests | Where-Object { $null -ne $_ })
    $mode = if ($Epic) { 'Development' } else { 'FullAcceptance' }
    $baselinePassed = 0
    $migrationPassed = 0
    $labelPassed = 0
    if ($null -eq $Result -or $tests.Count -eq 0 -or $Result.TotalCount -le 0) {
        $errors.Add('zero discovery or missing result')
    }
    if ($Result.Result -cne 'Passed' -or $Result.FailedCount -gt 0 -or
        $Result.FailedContainersCount -gt 0 -or $Result.FailedBlocksCount -gt 0 -or
        @($Result.ErrorRecord | Where-Object { $null -ne $_ }).Count -gt 0) {
        $errors.Add('run, container, or block failure')
    }
    foreach ($container in $Result.Containers) {
        if (@($container.ErrorRecord | Where-Object { $null -ne $_ }).Count -gt 0) { $errors.Add('container error') }
    }
    if ($tests.Count -ne $Result.TotalCount) { $errors.Add('discovery count disagrees with distinct result entries') }

    $selected = if ($Epic) {
        @($tests | Where-Object { (Get-BackportTestTags $_).Contains($Epic) })
    }
    else { $tests }
    if (@($selected).Count -eq 0) { $errors.Add('no selected tests executed') }
    foreach ($test in $selected) {
        if ($test.Result -cne 'Passed' -or $test.Executed -ne $true) {
            $errors.Add("required case not executed and passed: $($test.Name)")
        }
    }

    if (-not $Epic) {
        $required = @(13..24 | ForEach-Object { 'TEST-{0:d3}' -f $_ })
        $entries = @($Parity.baseline_tests | Where-Object { $null -ne $_ })
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $names = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        if ($Parity.schema -ne 1 -or $Parity.baseline.test_count -ne 67 -or $entries.Count -ne 67) {
            $errors.Add('invalid parity schema or baseline count (67 required)')
        }
        if ($Parity.baseline.commit -cne '514500f55f064aa9ab86607e6d0803f2abd6376c' -or
            $Parity.baseline.controller_lines -ne 866) {
            $errors.Add('pinned baseline source changed')
        }
        foreach ($entry in $entries) {
            if ($entry.id -cnotmatch '^test_[a-zA-Z0-9_]+$' -or
                $entry.pester_name -cne $entry.id) {
                $errors.Add('invalid baseline identity')
                continue
            }
            if (-not $ids.Add($entry.id)) { $errors.Add("duplicate baseline ID: $($entry.id)") }
            if ($names.ContainsKey($entry.pester_name)) { $errors.Add("duplicate baseline name: $($entry.pester_name)") }
            else { $names.Add($entry.pester_name, $entry.id) }
        }
        $orderedIds = [Collections.Generic.List[string]]::new()
        foreach ($id in $ids) { $orderedIds.Add($id) }
        $orderedIds.Sort([StringComparer]::Ordinal)
        $inventory = ConvertTo-Json -InputObject $orderedIds.ToArray() -Compress
        $inventoryHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($inventory))
        ).ToLowerInvariant()
        if ($inventoryHash -cne '3525faf922d39209c6f2df63b71a2c200a416ccb65fc85bd44efb204a3afd8a7') {
            $errors.Add('exact 67-name baseline inventory changed')
        }
        $migrationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($id in $Parity.required_migration_ids) {
            if ($required -cnotcontains $id -or -not $migrationIds.Add($id)) {
                $errors.Add("unknown or duplicate migration ID: $id")
            }
        }
        foreach ($id in $required) {
            if (-not $migrationIds.Contains($id)) { $errors.Add("missing parity migration ID: $id") }
        }

        $observed = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($test in $tests) {
            $name = [string]$test.Name
            if ($name -imatch '^test_' -and -not $names.ContainsKey($name)) {
                $errors.Add("unknown baseline test name: $name")
            }
            if ($names.ContainsKey($name)) {
                if (-not $observed.ContainsKey($name)) {
                    $observed.Add($name, [Collections.Generic.List[object]]::new())
                }
                $observed[$name].Add($test)
            }
        }
        foreach ($name in $names.Keys) {
            if (-not $observed.ContainsKey($name)) { $errors.Add("missing baseline case: $name") }
            elseif ($observed[$name].Count -ne 1) { $errors.Add("duplicate baseline case: $name") }
            elseif ($observed[$name][0].Result -ceq 'Passed' -and $observed[$name][0].Executed -eq $true) {
                $baselinePassed++
            }
        }
        foreach ($id in $required) {
            $matches = @($tests | Where-Object { (Get-BackportTestTags $_).Contains($id) })
            if ($matches.Count -eq 0) { $errors.Add("missing migration case: $id") }
            elseif (@($matches | Where-Object { $_.Result -cne 'Passed' -or $_.Executed -ne $true }).Count -eq 0) {
                $migrationPassed++
            }
        }
        foreach ($id in @(1..13 | ForEach-Object { 'LT-{0:d2}' -f $_ })) {
            $matches = @($tests | Where-Object { (Get-BackportTestTags $_).Contains($id) })
            if ($matches.Count -eq 0) { $errors.Add("missing label case: $id") }
            elseif (@($matches | Where-Object { $_.Result -cne 'Passed' -or $_.Executed -ne $true }).Count -eq 0) {
                $labelPassed++
            }
        }
        if ($Result.SkippedCount -gt 0 -or $Result.NotRunCount -gt 0) {
            $errors.Add('full acceptance cannot contain skipped or unexecuted cases')
        }
    }
    $message = if ($Epic) {
        "Development $Epic - NOT full acceptance."
    }
    else {
        "Full acceptance: $baselinePassed/67 distinct baseline cases; $migrationPassed/12 migration IDs; $labelPassed/13 label IDs."
    }
    [pscustomobject]@{
        Accepted = $errors.Count -eq 0
        ExitCode = [int]($errors.Count -ne 0)
        Mode = $mode
        Message = $message
        BaselinePassed = $baselinePassed
        MigrationPassed = $migrationPassed
        LabelPassed = $labelPassed
        Errors = $errors.ToArray()
    }
}

function Invoke-BackportTests {
    [CmdletBinding()]
    param(
        [ValidateSet('EPIC-001', 'EPIC-002', 'EPIC-003', 'L-001', 'L-002', 'L-003')][string]$Epic,
        [string]$ResultPath,
        [string]$ParityPath = (Join-Path $PSScriptRoot 'parity.json')
    )
    Assert-BackportRuntime
    Import-Module -Name Pester -RequiredVersion 5.7.1 -ErrorAction Stop
    Write-Host ("PowerShell {0}; .NET {1}; Pester {2}" -f
        $PSVersionTable.PSVersion, [Environment]::Version, (Get-Command Invoke-Pester).Module.Version)
    if (-not $ResultPath) { $ResultPath = Get-BackportDefaultResultPath }
    $ResultPath = [IO.Path]::GetFullPath($ResultPath)
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $PSScriptRoot 'Backport.Tests.ps1'
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Run.Throw = $false
    $configuration.TestDrive.Enabled = $false
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = $ResultPath
    if ($Epic) {
        $configuration.Filter.Tag = $Epic
        Write-Host "Development $Epic - NOT full acceptance."
    }
    $result = Invoke-Pester -Configuration $configuration
    $parity = $null
    if (-not $Epic -and $ParityPath -and (Test-Path -LiteralPath $ParityPath)) {
        $parity = Get-Content -LiteralPath $ParityPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    }
    $gateArguments = @{ Result = $result; Parity = $parity }
    if ($Epic) { $gateArguments.Epic = $Epic }
    $gate = Test-BackportAcceptance @gateArguments
    Write-Host $gate.Message
    if (-not $gate.Accepted) {
        Write-Host ("Gate rejected: " + ($gate.Errors -join '; '))
    }
    $gate
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $arguments = @{ ResultPath = $ResultPath }
        if ($Epic) { $arguments.Epic = $Epic }
        if ($ParityPath) { $arguments.ParityPath = $ParityPath }
        $gate = Invoke-BackportTests @arguments
        exit $gate.ExitCode
    }
    catch {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
