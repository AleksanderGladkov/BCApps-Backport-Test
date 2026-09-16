Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-BackportDictionary {
    return ,([Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal))
}

function Test-BackportLiteral {
    param([AllowNull()]$Value, [string[]]$Allowed)
    # PowerShell -ceq ignores some Unicode characters; string equality here must be ordinal.
    $Value -is [string] -and [Array]::IndexOf[string]($Allowed, $Value) -ge 0
}

function Get-BackportHash {
    param([byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertFrom-BackportJsonString {
    param([string]$Raw)
    # JsonDocument validates syntax; decoding escapes ourselves retains lone surrogate code units.
    $text = [Text.StringBuilder]::new()
    for ($i = 1; $i -lt $Raw.Length - 1; $i++) {
        $ch = $Raw[$i]
        if ($ch -ceq '\') {
            $i++
            switch -CaseSensitive ($Raw[$i]) {
                'u' {
                    $ch = [char][Convert]::ToInt32($Raw.Substring($i + 1, 4), 16)
                    $i += 4
                }
                'b' { $ch = [char]8 }
                'f' { $ch = [char]12 }
                'n' { $ch = [char]10 }
                'r' { $ch = [char]13 }
                't' { $ch = [char]9 }
                default { $ch = $Raw[$i] }
            }
        }
        $null = $text.Append($ch)
    }
    $text.ToString()
}

function ConvertFrom-BackportJsonElement {
    param([Text.Json.JsonElement]$Element)
    switch ($Element.ValueKind) {
        Object {
            $value = New-BackportDictionary
            foreach ($property in $Element.EnumerateObject()) {
                $raw = $property.ToString()
                for ($end = 1; $end -lt $raw.Length; $end++) {
                    if ($raw[$end] -ceq '\') { $end++; continue }
                    if ($raw[$end] -ceq '"') { break }
                }
                $key = ConvertFrom-BackportJsonString $raw.Substring(0, $end + 1)
                if ($value.ContainsKey($key)) { throw 'duplicate_json_key' }
                $value.Add($key, (ConvertFrom-BackportJsonElement $property.Value))
            }
            return ,$value
        }
        Array {
            $value = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $value.Add((ConvertFrom-BackportJsonElement $item))
            }
            return ,$value.ToArray()
        }
        String { return (ConvertFrom-BackportJsonString $Element.GetRawText()) }
        Number {
            $raw = $Element.GetRawText()
            if ([regex]::IsMatch($raw, '\A-?(0|[1-9][0-9]*)\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                $number = [Numerics.BigInteger]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture)
                if ($number -ge [long]::MinValue -and $number -le [long]::MaxValue) { return [long]$number }
                return $number
            }
            # Noninteger tokens stay nonintegers, so 1.0/1e0 cannot impersonate a schema integer.
            return $Element.GetDouble()
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { throw 'invalid_artifact' }
    }
}

function ConvertFrom-BackportJsonBytes {
    param([byte[]]$Bytes)
    $document = $null
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 100
        $document = [Text.Json.JsonDocument]::Parse($text, $options)
        return ,(ConvertFrom-BackportJsonElement $document.RootElement)
    }
    catch [Text.DecoderFallbackException] { throw 'invalid_artifact' }
    catch [Text.Json.JsonException] { throw 'invalid_artifact' }
    catch [FormatException] { throw 'invalid_artifact' }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Add-BackportJsonString {
    param([Text.StringBuilder]$Builder, [string]$Value)
    $null = $Builder.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        $escape = switch ($code) {
            8 { '\b' }
            9 { '\t' }
            10 { '\n' }
            12 { '\f' }
            13 { '\r' }
            34 { '\"' }
            92 { '\\' }
            default { $null }
        }
        if ($null -ne $escape) { $null = $Builder.Append($escape) }
        elseif ($code -lt 32 -or $code -ge 127) {
            $null = $Builder.Append('\u').Append($code.ToString('x4', [Globalization.CultureInfo]::InvariantCulture))
        }
        else { $null = $Builder.Append($ch) }
    }
    $null = $Builder.Append('"')
}

function Test-BackportInteger {
    param($Value)
    $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [short] -or $Value -is [ushort] -or
    $Value -is [int] -or $Value -is [uint] -or $Value -is [long] -or $Value -is [ulong] -or
    $Value -is [Numerics.BigInteger]
}

function Add-BackportJsonValue {
    param([Text.StringBuilder]$Builder, [AllowNull()]$Value, [int]$Depth = 0)
    if ($Depth -gt 100) { throw 'invalid_json_type' }
    if ($null -eq $Value) { $null = $Builder.Append('null'); return }
    if ($Value -is [string]) { Add-BackportJsonString $Builder $Value; return }
    if ($Value -is [bool]) {
        $null = $Builder.Append($(if ($Value) { 'true' } else { 'false' }))
        return
    }
    if (Test-BackportInteger $Value) {
        $null = $Builder.Append($Value.ToString([Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        # Python orders keys by scalar, not UTF-16 code unit or current culture.
        $keys = [Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($key in $Value.psbase.Keys) {
            if ($key -isnot [string]) { throw 'invalid_json_type' }
            $sortKey = [Text.StringBuilder]::new()
            for ($i = 0; $i -lt $key.Length; $i++) {
                $code = [int]$key[$i]
                if ([char]::IsHighSurrogate($key[$i]) -and $i + 1 -lt $key.Length -and [char]::IsLowSurrogate($key[$i + 1])) {
                    $code = [char]::ConvertToUtf32($key, $i)
                    $i++
                }
                $null = $sortKey.Append($code.ToString('x6', [Globalization.CultureInfo]::InvariantCulture))
            }
            $keys.Add($sortKey.ToString(), $key)
        }
        $null = $Builder.Append('{')
        $separator = ''
        foreach ($key in $keys.Values) {
            $null = $Builder.Append($separator)
            Add-BackportJsonString $Builder $key
            $null = $Builder.Append(':')
            Add-BackportJsonValue $Builder $Value[$key] ($Depth + 1)
            $separator = ','
        }
        $null = $Builder.Append('}')
        return
    }
    if ($Value -is [array] -or $Value -is [Collections.IList]) {
        $null = $Builder.Append('[')
        $separator = ''
        foreach ($item in $Value) {
            $null = $Builder.Append($separator)
            Add-BackportJsonValue $Builder $item ($Depth + 1)
            $separator = ','
        }
        $null = $Builder.Append(']')
        return
    }
    throw 'invalid_json_type'
}

function ConvertTo-BackportJsonBytes {
    param([AllowNull()]$Value)
    $builder = [Text.StringBuilder]::new()
    Add-BackportJsonValue $builder $Value
    return ,([Text.UTF8Encoding]::new($false, $true).GetBytes($builder.ToString()))
}

function ConvertTo-BackportPositive {
    param($Value, [AllowNull()]$Maximum = $null)
    if ($Value -isnot [string] -or -not [regex]::IsMatch($Value, '\A[1-9][0-9]{0,19}\z')) { throw 'invalid_number' }
    $number = [Numerics.BigInteger]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($null -ne $Maximum -and $number -ge $Maximum) { throw 'invalid_number' }
    $number
}

function Resolve-BackportLocalPath {
    param([string]$Path, [int]$LinkDepth = 0)
    if (-not $Path -or $LinkDepth -gt 40 -or $Path.IndexOf([char]0) -ge 0) { throw 'invalid_local_path' }
    try {
        if (-not [IO.Path]::IsPathFullyQualified($Path)) {
            $Path = [IO.Path]::Combine((Get-Location).ProviderPath, $Path)
        }
        $root = [IO.Path]::GetPathRoot($Path)
        $current = $root
        $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        foreach ($part in $Path.Substring($root.Length).Split($separators, [StringSplitOptions]::RemoveEmptyEntries)) {
            if ([IO.File]::Exists($current)) { throw 'invalid_local_path' }
            if (Test-BackportLiteral $part @('.')) { continue }
            if (Test-BackportLiteral $part @('..')) {
                $parent = [IO.Directory]::GetParent($current)
                if ($null -ne $parent) { $current = $parent.FullName }
                continue
            }
            if ($IsWindows -and ($part.EndsWith(' ', [StringComparison]::Ordinal) -or
                $part.EndsWith('.', [StringComparison]::Ordinal) -or $part.Contains(':'))) {
                throw 'invalid_local_path'
            }
            $current = [IO.Path]::Combine($current, $part)
            $item = [IO.FileInfo]::new($current)
            if ($null -ne $item.LinkTarget) {
                $target = $item.ResolveLinkTarget($true)
                if ($null -eq $target) { throw 'invalid_local_path' }
                $current = Resolve-BackportLocalPath $target.FullName ($LinkDepth + 1)
            }
        }
        [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($current))
    }
    catch [ArgumentException] { throw 'invalid_local_path' }
    catch [IO.IOException] { throw 'invalid_local_path' }
    catch [UnauthorizedAccessException] { throw 'invalid_local_path' }
}

function Test-BackportContainedPath {
    param([string]$Path, [string]$Directory)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $Directory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $Path.Equals($Directory, $comparison) -or $Path.StartsWith($prefix, $comparison)
}

function Assert-BackportRegularFile {
    param([string]$Path, [switch]$AllowMissing)
    $item = [IO.FileInfo]::new($Path)
    if ($null -ne $item.LinkTarget) { throw 'invalid_artifact' }
    if (-not $item.Exists) {
        if (-not $AllowMissing -or [IO.Directory]::Exists($Path)) { throw 'invalid_artifact' }
        return
    }
    if (($item.Attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Device)) -ne 0) {
        throw 'invalid_artifact'
    }
    $mode = (Get-Item -LiteralPath $Path -Force).PSObject.Properties['UnixMode']
    if (($null -ne $mode -and -not ([string]$mode.Value).StartsWith('-', [StringComparison]::Ordinal)) -or
        (-not $IsWindows -and $null -eq $mode)) { throw 'invalid_artifact' }
}

function Assert-BackportToken {
    param([string]$Token)
    if (-not $Token -or (Test-BackportWhitespace -Value $Token)) { throw 'missing_or_invalid_token' }
}

function Get-BackportToken {
    param([AllowNull()][Collections.IDictionary]$Environment = $null)
    $token = if ($null -eq $Environment) { [Environment]::GetEnvironmentVariable('GH_TOKEN') }
        else { [string]$Environment['GH_TOKEN'] }
    Assert-BackportToken $token
    $token
}

function Get-BackportRequest {
    param($Environment, $Actor, $Allowed)
    $dry = $Environment['INPUT_DRY_RUN']
    if (-not (Test-BackportLiteral $dry @('true', 'false'))) { throw 'invalid_dry_run' }
    $source = ConvertTo-BackportPositive $Environment['INPUT_SOURCE_PR'] 2147483648
    $eventName = $Environment['GITHUB_EVENT_NAME']
    if (-not (Test-BackportLiteral $eventName @('workflow_dispatch', 'pull_request_target'))) { throw 'unsupported_event' }
    $path = $Environment['GITHUB_EVENT_PATH']
    if (-not $path) { throw 'invalid_event_file' }
    try {
        Assert-BackportRegularFile $path
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 5MB) { throw 'invalid_event_file' }
            $bytes = [byte[]]::new([int]$stream.Length)
            $stream.ReadExactly($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
        $event = ConvertFrom-BackportJsonBytes $bytes
    }
    catch [IO.IOException] { throw 'invalid_event_file' }
    catch [UnauthorizedAccessException] { throw 'invalid_event_file' }
    Assert-BackportRepository (Get-BackportField $event 'repository')
    if (Test-BackportLiteral $eventName @('workflow_dispatch')) {
        if (-not (Test-BackportLiteral (Get-BackportField $event 'ref') @('main', 'refs/heads/main'))) {
            throw 'wrong_execution_ref'
        }
        $inputs = Get-BackportObjectField $event 'inputs'
        $requestSource = ConvertTo-BackportPositive (Get-BackportField $inputs 'source_pr') 2147483648
        $requestDry = Get-BackportField $inputs 'dry_run'
        if (-not (Test-BackportLiteral $requestDry @('true', 'false'))) { throw 'invalid_dry_run' }
    }
    else {
        if (-not (Test-BackportLiteral (Get-BackportField $event 'action') @('labeled')) -or
            -not (Test-BackportLiteral (Get-BackportField (Get-BackportObjectField $event 'label') 'name') @('backport:29.x'))) {
            throw 'invalid_label_event'
        }
        $pr = Get-BackportObjectField $event 'pull_request'
        $requestSource = Get-BackportField $pr 'number'
        $number = Get-BackportField $event 'number'
        if (-not (Test-BackportInteger $requestSource) -or $requestSource -le 0 -or $requestSource -ge 2147483648 -or
            -not (Test-BackportInteger $number) -or $number -ne $requestSource) { throw 'invalid_number' }
        # Admission uses the original snapshot, never a later merge observed through the API.
        $merged = Get-BackportField $pr 'merged'
        if ($merged -isnot [bool] -or -not $merged -or
            -not (Test-BackportLiteral (Get-BackportField $pr 'state') @('closed'))) { throw 'source_not_merged' }
        $base = Get-BackportObjectField $pr 'base'
        Assert-BackportRepository (Get-BackportField $base 'repo')
        if (-not (Test-BackportLiteral (Get-BackportField $base 'ref') @('main'))) { throw 'source_wrong_base' }
        $sender = Get-BackportField (Get-BackportObjectField $event 'sender') 'id'
        if (-not (Test-BackportInteger $sender) -or $sender -le 0 -or $sender -ne $Actor -or
            $Allowed -notcontains $sender) { throw 'sender_not_allowed' }
        $requestDry = 'false'
    }
    if ($requestSource -ne $source -or -not (Test-BackportLiteral $dry @($requestDry))) { throw 'request_projection_mismatch' }
    return @{ source_pr = [int]$requestSource; dry_run = (Test-BackportLiteral $requestDry @('true')) }
}

function New-BackportContext {
    param([AllowNull()][Collections.IDictionary]$Environment = $null)
    $envMap = New-BackportDictionary
    foreach ($key in @('GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_REF', 'GITHUB_ACTOR_ID',
        'GITHUB_TRIGGERING_ACTOR', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'INPUT_SOURCE_PR', 'INPUT_DRY_RUN',
        'GITHUB_EVENT_NAME', 'GITHUB_EVENT_PATH', 'GITHUB_WORKFLOW_REF', 'GITHUB_WORKFLOW_SHA',
        'ALLOWED_ACTOR_IDS', 'RUNNER_TEMP', 'STATE_DIR', 'WORK_DIR', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'GITHUB_SUMMARY')) {
        $value = if ($null -eq $Environment) { [Environment]::GetEnvironmentVariable($key) } else { $Environment[$key] }
        if ($null -ne $value) { $envMap.Add($key, [string]$value) }
    }
    if (-not (Test-BackportLiteral $envMap['GITHUB_REPOSITORY'] @('AleksanderGladkov/BCApps-Backport-Test'))) { throw 'wrong_repository' }
    if (-not (Test-BackportLiteral $envMap['GITHUB_REPOSITORY_ID'] @('1369849596'))) { throw 'wrong_repository_id' }
    if (-not (Test-BackportLiteral $envMap['GITHUB_REF'] @('refs/heads/main'))) { throw 'wrong_execution_ref' }
    if (-not (Test-BackportLiteral $envMap['GITHUB_WORKFLOW_REF'] @(
        'AleksanderGladkov/BCApps-Backport-Test/.github/workflows/backport-demo.yml@refs/heads/main'
    ))) { throw 'wrong_workflow_ref' }
    $null = Assert-BackportSha $envMap['GITHUB_WORKFLOW_SHA']
    $rawAllowed = if ($envMap.ContainsKey('ALLOWED_ACTOR_IDS')) { $envMap['ALLOWED_ACTOR_IDS'] } else { '59250993' }
    $allowed = @($rawAllowed.Split(',') | ForEach-Object { ConvertTo-BackportPositive $_ })
    $actor = ConvertTo-BackportPositive $envMap['GITHUB_ACTOR_ID']
    if ($allowed -notcontains $actor) { throw 'actor_not_allowed' }
    $triggering = $envMap['GITHUB_TRIGGERING_ACTOR']
    if (-not $triggering -or -not [regex]::IsMatch($triggering, '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z')) {
        throw 'invalid_triggering_actor'
    }
    $request = Get-BackportRequest $envMap $actor $allowed
    $run = $envMap['GITHUB_RUN_ID']; $attempt = $envMap['GITHUB_RUN_ATTEMPT']
    $null = ConvertTo-BackportPositive $run
    $null = ConvertTo-BackportPositive $attempt
    $temp = $envMap['RUNNER_TEMP']
    if (-not $temp -and (-not $envMap['STATE_DIR'] -or -not $envMap['WORK_DIR'])) { throw 'missing_local_directories' }
    $state = Resolve-BackportLocalPath $(if ($envMap['STATE_DIR']) { $envMap['STATE_DIR'] } else { [IO.Path]::Combine($temp, 'backport-state') })
    $work = Resolve-BackportLocalPath $(if ($envMap['WORK_DIR']) { $envMap['WORK_DIR'] } else { [IO.Path]::Combine($temp, 'backport-work') })
    if ((Test-BackportContainedPath $state $work) -or (Test-BackportContainedPath $work $state)) { throw 'overlapping_directories' }
    $trusted = @('Backport.psm1','Invoke-Backport.ps1','compat.json') | ForEach-Object {
        Resolve-BackportLocalPath ([IO.Path]::Combine($PSScriptRoot, $_))
    }
    foreach ($path in $trusted) {
        if ((Test-BackportContainedPath $path $state) -or (Test-BackportContainedPath $path $work)) { throw 'script_inside_work_directory' }
    }
    if ([IO.File]::Exists($state) -or [IO.File]::Exists($work)) { throw 'invalid_local_path' }
    $output = [string]$envMap['GITHUB_OUTPUT']
    $summary = if ($envMap.ContainsKey('GITHUB_STEP_SUMMARY')) { $envMap['GITHUB_STEP_SUMMARY'] } else { [string]$envMap['GITHUB_SUMMARY'] }
    $outputs = [Collections.Generic.List[string]]::new()
    foreach ($path in @($output, $summary)) {
        if (-not $path) { $outputs.Add(''); continue }
        try {
            Assert-BackportRegularFile $path -AllowMissing
            $resolved = Resolve-BackportLocalPath $path
            Assert-BackportRegularFile $resolved -AllowMissing
        }
        catch { throw 'invalid_output_path' }
        if ((Test-BackportContainedPath $resolved $state) -or (Test-BackportContainedPath $resolved $work)) { throw 'invalid_output_path' }
        foreach ($file in $trusted) {
            if (Test-BackportContainedPath $resolved $file) { throw 'invalid_output_path' }
        }
        if ($outputs.Count -gt 0 -and $outputs[0] -and (Test-BackportContainedPath $resolved $outputs[0])) { throw 'invalid_output_path' }
        $outputs.Add($resolved)
    }
    $null = Get-BackportToken -Environment $Environment
    $config = New-BackportDictionary
    foreach ($entry in @{
        source_pr = $request.source_pr; dry_run = $request.dry_run; actor_id = $actor
        triggering_actor = $triggering; allowed_actor_ids = $allowed; run_id = $run
        run_attempt = $attempt; state_dir = $state; work_dir = $work
        output = $outputs[0]; summary = $outputs[1]
    }.GetEnumerator()) { $config.Add($entry.Key, $entry.Value) }
    return ,$config
}

function Get-BackportBinding {
    param($Config)
    $binding = New-BackportDictionary
    foreach ($entry in @{
        schema = 1; repository = 'AleksanderGladkov/BCApps-Backport-Test'; repository_id = 1369849596
        source_pr = $Config.source_pr; dry_run = $Config.dry_run
        run_id = $Config.run_id; run_attempt = $Config.run_attempt
    }.GetEnumerator()) { $binding.Add($entry.Key, $entry.Value) }
    return ,$binding
}

function Get-BackportStatePath {
    param($Config, [string]$Name)
    if (-not (Test-BackportLiteral $Name @('plan.json','tracking.json','result.json','publication.json','conflict.json','patch.bin'))) {
        throw 'invalid_artifact'
    }
    $directory = Resolve-BackportLocalPath $Config.state_dir
    if (-not $directory.Equals($Config.state_dir, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        throw 'invalid_artifact'
    }
    [IO.Path]::Combine($directory, $Name)
}

function Move-BackportStateFile {
    param([string]$Source, [string]$Destination)
    [IO.File]::Move($Source, $Destination, $true)
}

function Write-BackportState {
    param($Config, [string]$Name, [AllowNull()]$Value)
    $path = Get-BackportStatePath $Config $Name
    Assert-BackportRegularFile $path -AllowMissing
    $bytes = if ($Value -is [byte[]]) { ,$Value } else { ConvertTo-BackportJsonBytes $Value }
    $temporary = $null
    try {
        $null = [IO.Directory]::CreateDirectory($Config.state_dir)
        $temporary = [IO.Path]::Combine($Config.state_dir, '.state-' + [guid]::NewGuid().ToString('N'))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        $null = Get-BackportStatePath $Config $Name
        Assert-BackportRegularFile $path -AllowMissing
        Move-BackportStateFile $temporary $path
    }
    catch [IO.IOException] { throw 'state_write_failed' }
    catch [UnauthorizedAccessException] { throw 'state_write_failed' }
    finally { if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Read-BackportArtifact {
    param($Config, [string]$Name)
    $fields = switch -CaseSensitive ($Name) {
        'plan.json' { @('source_sha','source_head_sha','target_ref','target_base_sha','files','commits') }
        'tracking.json' { @('plan_hash','status','issue_number','issue_id','issue_url') }
        'result.json' { @('plan_hash','status','reason','published','commit_sha','tree_sha','patch_sha256') }
        'publication.json' { @('plan_hash','attempted') }
        default { throw 'invalid_artifact' }
    }
    try {
        $path = Get-BackportStatePath $Config $Name
        Assert-BackportRegularFile $path
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 5MB) { throw 'invalid_artifact' }
            $bytes = [byte[]]::new([int]$stream.Length)
            $stream.ReadExactly($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
        $value = ConvertFrom-BackportJsonBytes $bytes
    }
    catch [IO.IOException] { throw 'invalid_artifact' }
    catch [UnauthorizedAccessException] { throw 'invalid_artifact' }
    $binding = Get-BackportBinding $Config
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in @($fields) + @($binding.psbase.Keys)) { $null = $required.Add($key) }
    if ($value -isnot [Collections.IDictionary] -or -not $required.SetEquals([string[]]@($value.psbase.Keys))) {
        throw 'invalid_artifact_schema'
    }
    foreach ($key in $binding.psbase.Keys) {
        $expected = $binding[$key]; $actual = $value[$key]
        $same = if (Test-BackportInteger $expected) {
            (Test-BackportInteger $actual) -and $actual -eq $expected
        }
        elseif ($expected -is [bool]) { $actual -is [bool] -and $actual -eq $expected }
        else { $actual -is [string] -and [string]::Equals($actual, $expected, [StringComparison]::Ordinal) }
        if (-not $same) { throw 'artifact_context_mismatch' }
    }
    return ,$value
}

function Invoke-BackportCli {
    param([object[]]$Arguments)
    $config = $null
    try {
        if ($Arguments.Count -ne 2 -or -not (Test-BackportLiteral $Arguments[0] @('-Stage')) -or
            -not (Test-BackportLiteral $Arguments[1] @('validate','track','prepare','publish'))) { throw 'invalid_stage' }
        $config = New-BackportContext
        switch -CaseSensitive ($Arguments[1]) {
            'validate' { $null = Invoke-BackportValidate -Config $config }
            'track' { $null = Invoke-BackportTrack -Config $config }
            'prepare' { $null = Invoke-BackportPrepare -Config $config }
            'publish' { $null = Invoke-BackportPublish -Config $config }
        }
        return 0
    }
    catch {
        $reason = Get-BackportSafeReason $_.Exception.Message
        [Console]::Error.WriteLine('backport_failed: ' + $reason)
        if ($null -ne $config) {
            try {
                Write-BackportOutput -Config $config -Values @{ status = 'needs-attention' }
                Write-BackportSummary -Config $config -Status 'needs-attention'
            }
            catch {
                [Console]::Error.WriteLine('backport_reporting_failed: ' + (Get-BackportSafeReason $_.Exception.Message))
            }
        }
        return 1
    }
}

function Get-BackportCompatibility {
    $cached = Get-Variable -Name BackportUnicodeCompatibility -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $cached) { return $cached.Value }

    try {
        [byte[]]$bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'compat.json'))
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        # Pin both exact Git checkout encodings, without normalizing arbitrary resource edits.
        if (-not (Test-BackportLiteral $hash @(
            'E3A963A3B19822B287A62A89A0F28AB2EEE28CD334439B98E50218BF1B7AD2E3',
            '05BEE658C220A98302BB6DB36BC5C20511113DB2220A8BA5BC5C3E564AA54D05'))) {
            throw 'invalid_compatibility_data'
        }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $profile = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 20 -ErrorAction Stop
        if ($profile.schema -ne 1 -or $profile.provenance.python_version -cne '3.13' -or
            $profile.provenance.unicode_version -cne '15.1.0' -or
            $profile.provenance.generator -cne 'Export-PythonBaseline.py' -or
            $profile.provenance.normalization -cne 'none' -or $profile.license.id -cne 'Unicode-3.0') {
            throw 'invalid_compatibility_data'
        }
        $folds = [Collections.Generic.Dictionary[int, string]]::new()
        foreach ($entry in $profile.case_folds) { $folds.Add([int]$entry[0], [string]$entry[1]) }
        $categoryC = [Collections.BitArray]::new(0x110000)
        foreach ($range in $profile.category_c_ranges) {
            for ($point = [int]$range[0]; $point -le [int]$range[1]; $point++) {
                $categoryC.Set($point, $true)
            }
        }
        $whitespace = [Collections.Generic.HashSet[int]]::new()
        $whitespaceCharacters = [Collections.Generic.List[char]]::new()
        foreach ($point in $profile.whitespace) {
            $null = $whitespace.Add([int]$point)
            $whitespaceCharacters.Add([char]$point)
        }
        $script:BackportUnicodeCompatibility = [pscustomobject]@{
            Profile = $profile
            CaseFolds = $folds
            CategoryC = $categoryC
            Whitespace = $whitespace
            WhitespaceCharacters = $whitespaceCharacters.ToArray()
        }
        return $script:BackportUnicodeCompatibility
    }
    catch { throw 'invalid_compatibility_data' }
}

function ConvertTo-BackportCaseFold {
    param([AllowNull()]$Value)
    if ($Value -isnot [string]) { throw 'invalid_path' }
    $compat = Get-BackportCompatibility
    $builder = [Text.StringBuilder]::new()
    $unchangedStart = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $scalarStart = $index
        $point = [int]$Value[$index]
        if ($point -ge 0xd800 -and $point -le 0xdbff -and $index + 1 -lt $Value.Length -and
            [char]::IsLowSurrogate($Value[$index + 1])) {
            $point = [char]::ConvertToUtf32($Value, $index)
            $index++
        }
        if ($compat.CaseFolds.ContainsKey($point)) {
            $null = $builder.Append($Value, $unchangedStart, $scalarStart - $unchangedStart)
            $null = $builder.Append($compat.CaseFolds[$point])
            $unchangedStart = $index + 1
        }
    }
    if ($unchangedStart -eq 0) { return $Value }
    $null = $builder.Append($Value, $unchangedStart, $Value.Length - $unchangedStart)
    return $builder.ToString()
}

function Test-BackportWhitespace {
    param([AllowNull()]$Value)
    if ($Value -isnot [string]) { throw 'invalid_token' }
    $compat = Get-BackportCompatibility
    # Every whitespace point in this hash-pinned Python profile is in the BMP.
    return $Value.IndexOfAny($compat.WhitespaceCharacters) -ge 0
}

function Assert-BackportPath {
    param([AllowNull()]$Value)
    if ($Value -isnot [string] -or -not $Value.StartsWith('src/', [StringComparison]::Ordinal) -or
        -not $Value.EndsWith('.al', [StringComparison]::Ordinal)) {
        throw 'invalid_path'
    }
    if ($Value.IndexOfAny([char[]]'\:<>"|?*') -ge 0) { throw 'invalid_path' }
    $compat = Get-BackportCompatibility
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $point = [int]$Value[$index]
        if ($point -ge 0xd800 -and $point -le 0xdbff -and $index + 1 -lt $Value.Length -and
            [char]::IsLowSurrogate($Value[$index + 1])) {
            $point = [char]::ConvertToUtf32($Value, $index)
            $index++
        }
        if ($compat.CategoryC[$point]) { throw 'invalid_path' }
    }
    foreach ($part in $Value.Split([char]'/')) {
        if ($part.Length -eq 0 -or $part.Equals('.', [StringComparison]::Ordinal) -or
            $part.Equals('..', [StringComparison]::Ordinal) -or
            $part.EndsWith(' ', [StringComparison]::Ordinal) -or $part.EndsWith('.', [StringComparison]::Ordinal)) {
            throw 'invalid_path'
        }
        # Python lower() can produce this prefix only from ASCII G/I/T; dotted I expands to i + dot.
        if ([regex]::IsMatch($part, '\A\.[gG][iI][tT]', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw 'invalid_path'
        }
        $stem = $part.Split([char]'.')[0]
        # These device tokens contain none of Python IGNORECASE's extra I/K/S equivalence classes.
        if ([regex]::IsMatch($stem,
            '\A(?:[cC][oO][nN]|[pP][rR][nN]|[aA][uU][xX]|[nN][uU][lL]|[cC][oO][mM][1-9]|[lL][pP][tT][1-9])\z',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw 'invalid_path'
        }
    }
    return $Value
}

function ConvertFrom-BackportRawDiff {
    param([AllowNull()]$Bytes)
    if ($Bytes -isnot [byte[]]) { throw 'invalid_diff' }
    if ($Bytes.Length -gt 0 -and $Bytes[$Bytes.Length - 1] -ne 0) { throw 'invalid_diff' }
    $entries = [Collections.Generic.List[object]]::new()
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $headerPattern = '\A:([0-9]{6}) ([0-9]{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMD])\z'
    $zeroId = '0' * 40
    $offset = 0
    while ($offset -lt $Bytes.Length) {
        $headerEnd = [Array]::IndexOf($Bytes, [byte]0, $offset)
        if ($headerEnd -lt 0 -or $headerEnd + 1 -ge $Bytes.Length) { throw 'invalid_diff' }
        $filenameStart = $headerEnd + 1
        $filenameEnd = [Array]::IndexOf($Bytes, [byte]0, $filenameStart)
        if ($filenameEnd -lt 0) { throw 'invalid_diff' }
        $header = [Text.Encoding]::ASCII.GetString($Bytes, $offset, $headerEnd - $offset)
        $match = [regex]::Match($header, $headerPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success) { throw 'invalid_diff' }
        $oldMode = $match.Groups[1].Value
        $newMode = $match.Groups[2].Value
        $oldId = $match.Groups[3].Value
        $newId = $match.Groups[4].Value
        $status = $match.Groups[5].Value
        if ($oldMode -cnotin @('000000', '100644') -or $newMode -cnotin @('000000', '100644')) {
            throw 'unsafe_mode'
        }
        if (($oldMode -ceq '000000') -ne ($oldId -ceq $zeroId) -or
            ($oldMode -ceq '000000') -ne ($status -ceq 'A') -or
            ($newMode -ceq '000000') -ne ($newId -ceq $zeroId) -or
            ($newMode -ceq '000000') -ne ($status -ceq 'D')) {
            throw 'invalid_diff'
        }
        try { $path = $utf8.GetString($Bytes, $filenameStart, $filenameEnd - $filenameStart) }
        catch { throw 'invalid_path' }
        $path = Assert-BackportPath -Value $path
        $entries.Add([pscustomobject]@{
            path = $path
            old_mode = $oldMode
            new_mode = $newMode
            old_id = $oldId
            new_id = $newId
            status = $status
        })
        $offset = $filenameEnd + 1
    }
    if ($entries.Count -gt 50) { throw 'too_many_files' }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        if (-not $paths.Add((ConvertTo-BackportCaseFold -Value $entry.path))) { throw 'ambiguous_paths' }
    }
    return ,$entries.ToArray()
}

function Assert-BackportBlob {
    param([AllowNull()]$Bytes)
    if ($Bytes -isnot [byte[]]) { throw 'invalid_blob' }
    if ($Bytes.Length -gt 1MB) { throw 'file_too_large' }
    if ([Array]::IndexOf($Bytes, [byte]0) -ge 0) { throw 'binary_file' }
    return ,$Bytes
}

function Assert-BackportPatch {
    param([AllowNull()]$Bytes)
    if ($Bytes -isnot [byte[]]) { throw 'invalid_patch' }
    if ($Bytes.Length -gt 5MB) { throw 'patch_too_large' }
    return ,$Bytes
}

function New-BackportGitDeadline {
    [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(180))
}

function New-BackportProcess {
    [Diagnostics.Process]::new()
}

function Stop-BackportOwnedProcess {
    param($Process)
    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            if (-not $Process.WaitForExit(5000)) { throw 'git_operation_failed' }
        }
    }
    catch { throw 'git_operation_failed' }
}

function Invoke-BackportProcess {
    param(
        [Diagnostics.ProcessStartInfo]$StartInfo,
        [AllowNull()][AllowEmptyCollection()][byte[]]$Data
    )
    $process = $null
    $deadline = $null
    $output = $null
    $started = $false
    $result = $null
    try {
        if ($null -eq $StartInfo -or $StartInfo.UseShellExecute -or
            -not $StartInfo.RedirectStandardInput -or -not $StartInfo.RedirectStandardOutput -or
            -not $StartInfo.RedirectStandardError) { throw 'git_operation_failed' }
        $deadline = New-BackportGitDeadline
        $output = [IO.MemoryStream]::new()
        $process = New-BackportProcess
        $process.StartInfo = $StartInfo
        $started = $process.Start()
        if (-not $started) { throw 'git_operation_failed' }
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync($output, 65536, $deadline.Token)
        $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null, 65536, $deadline.Token)
        try {
            if ($null -ne $Data -and $Data.Length -gt 0) {
                $null = $process.StandardInput.BaseStream.WriteAsync($Data, 0, $Data.Length, $deadline.Token).GetAwaiter().GetResult()
            }
        }
        catch [IO.IOException] {
            # An early stdin close must not hide the child's exit code or bypass the deadline.
            $null = $process.WaitForExitAsync($deadline.Token).GetAwaiter().GetResult()
        }
        finally {
            try { $process.StandardInput.Close() }
            catch [IO.IOException] {
                $null = $process.WaitForExitAsync($deadline.Token).GetAwaiter().GetResult()
            }
        }
        $null = $process.WaitForExitAsync($deadline.Token).GetAwaiter().GetResult()
        $null = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync($deadline.Token).GetAwaiter().GetResult()
        $result = [pscustomobject]@{ exit_code = $process.ExitCode; stdout = $output.ToArray() }
    }
    catch { throw 'git_operation_failed' }
    finally {
        $cleanupFailed = $false
        try {
            if ($process -and $started) { Stop-BackportOwnedProcess -Process $process }
        }
        catch { $cleanupFailed = $true }
        finally {
            foreach ($resource in @($process, $deadline, $output)) {
                if ($resource) {
                    try { $resource.Dispose() }
                    catch { $cleanupFailed = $true }
                }
            }
        }
        if ($cleanupFailed) { throw 'git_operation_failed' }
    }
    return $result
}

function Assert-BackportGitLocalConfig {
    param([string]$Directory, [switch]$AllowUninitialized)
    $directoryInfo = [IO.DirectoryInfo]::new($Directory)
    while ($null -ne $directoryInfo) {
        if ($directoryInfo.Exists -and ($directoryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'git_operation_failed'
        }
        $directoryInfo = $directoryInfo.Parent
    }
    $gitDirectory = Join-Path $Directory '.git'
    if (Test-Path -LiteralPath $gitDirectory) {
        $gitInfo = Get-Item -LiteralPath $gitDirectory -Force -ErrorAction Stop
        if (-not $gitInfo.PSIsContainer -or ($gitInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'git_operation_failed'
        }
        if (Test-Path -LiteralPath (Join-Path $gitDirectory 'commondir')) { throw 'git_operation_failed' }
    }
    elseif (-not $AllowUninitialized) { throw 'git_operation_failed' }
    $configPath = Join-Path $gitDirectory 'config'
    if (-not (Test-Path -LiteralPath $configPath)) {
        if (-not $AllowUninitialized) { throw 'git_operation_failed' }
        return
    }
    $configInfo = Get-Item -LiteralPath $configPath -Force -ErrorAction Stop
    if ($configInfo.PSIsContainer -or ($configInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $configInfo.Length -gt 65536) {
        throw 'git_operation_failed'
    }
    $section = ''
    foreach ($line in [IO.File]::ReadAllLines($configPath)) {
        if ($line -match '\A\s*(#|;|\z)') { continue }
        if ($line -match '\A\s*\[([a-z]+)\]\s*\z') {
            $section = $Matches[1].ToLowerInvariant()
            if (-not (Test-BackportLiteral -Value $section -Allowed @('core', 'user', 'commit'))) { throw 'git_operation_failed' }
        }
        elseif ($line -match '\A\s*([a-z]+)\s*=\s*[^\\]*\z') {
            $key = $section + '.' + $Matches[1].ToLowerInvariant()
            if (-not (Test-BackportLiteral -Value $key -Allowed @(
                'core.repositoryformatversion', 'core.filemode', 'core.bare', 'core.logallrefupdates',
                'core.symlinks', 'core.ignorecase', 'core.autocrlf', 'core.longpaths', 'core.attributesfile',
                'user.name', 'user.email', 'commit.gpgsign'
            ))) { throw 'git_operation_failed' }
        }
        else { throw 'git_operation_failed' }
    }
}

function New-BackportGitStartInfo {
    param(
        $Config,
        [Alias('Directory')][string]$WorkingDirectory,
        [AllowEmptyCollection()][string[]]$Arguments,
        [switch]$Auth
    )
    $Directory = $WorkingDirectory
    if ($null -ne $Arguments -and $Arguments.Count -gt 0 -and
        (Test-BackportLiteral -Value $Arguments[0] -Allowed @('push')) -and $Config.dry_run) {
        throw 'dry_run_write_blocked'
    }
    try {
        if (-not [IO.Path]::IsPathFullyQualified($Directory) -or -not [IO.Directory]::Exists($Directory) -or
            $Arguments.Count -eq 0 -or -not (Test-BackportLiteral -Value $Arguments[0] -Allowed @(
                'init', 'config', 'hash-object', 'cat-file', 'status', 'rev-parse', 'rev-list', 'merge-base',
                'diff', 'show', 'log', 'fetch', 'push', 'checkout', 'switch', 'read-tree', 'write-tree',
                'commit-tree', 'update-ref', 'apply', 'cherry-pick', 'reset', 'add', 'commit', 'ls-tree', 'ls-remote'
            ))) { throw 'git_operation_failed' }
        $command = $Arguments[0]
        if ((Test-BackportLiteral -Value $command -Allowed @('init')) -and $Arguments.Count -ne 1) {
            throw 'git_operation_failed'
        }
        Assert-BackportGitLocalConfig -Directory $Directory -AllowUninitialized:(Test-BackportLiteral -Value $command -Allowed @('init'))
        foreach ($argument in $Arguments) {
            if ($null -eq $argument -or $argument.Contains([char]0) -or
                ($argument.StartsWith('-c', [StringComparison]::Ordinal) -and
                    -not ((Test-BackportLiteral -Value $argument -Allowed @('-c')) -and
                        (Test-BackportLiteral -Value $command -Allowed @('switch')))) -or
                $argument -cmatch '\A(-C\z|--(config-env|git-dir|work-tree|exec-path|upload-pack|receive-pack|exec|output|file|textconv|filters|ext-diff)(=|\z))') {
                throw 'git_operation_failed'
            }
        }
        if (Test-BackportLiteral -Value $command -Allowed @('config')) {
            $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
            $values = @{
                'user.name' = 'github-actions[bot]'
                'user.email' = '41898282+github-actions[bot]@users.noreply.github.com'
                'core.autocrlf' = 'false'; 'core.attributesFile' = $nullDevice
                'core.longpaths' = 'true'; 'commit.gpgsign' = 'false'
            }
            if ($Arguments.Count -ne 3 -or -not (Test-BackportLiteral -Value $Arguments[1] -Allowed @($values.psbase.Keys)) -or
                -not (Test-BackportLiteral -Value $Arguments[2] -Allowed @($values[$Arguments[1]]))) { throw 'git_operation_failed' }
        }
        $origin = 'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git'
        if ($Auth -and -not (Test-BackportLiteral -Value $command -Allowed @('push'))) { throw 'git_operation_failed' }
        if (Test-BackportLiteral -Value $command -Allowed @('push')) {
            if (-not $Auth -or $Arguments.Count -ne 5 -or -not (Test-BackportLiteral -Value $Arguments[1] -Allowed @('--porcelain')) -or
                -not (Test-BackportLiteral -Value $Arguments[2] -Allowed @($origin)) -or
                $Arguments[3] -cnotmatch '\A--force-with-lease=(refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*):\z') {
                throw 'git_operation_failed'
            }
            $reference = $Matches[1]
            if (($Config.source_pr -isnot [int] -and $Config.source_pr -isnot [long]) -or
                $Config.source_pr -lt 1 -or $Config.source_pr -gt [int]::MaxValue -or
                -not (Test-BackportLiteral -Value $reference -Allowed @("refs/heads/backport/29.x/pr-$($Config.source_pr)")) -or
                -not (Test-BackportLiteral -Value $Arguments[4] -Allowed @("HEAD:$reference"))) {
                throw 'git_operation_failed'
            }
        }
        if (Test-BackportLiteral -Value $command -Allowed @('fetch')) {
            if ($Arguments.Count -lt 5 -or -not (Test-BackportLiteral -Value $Arguments[1] -Allowed @('--no-tags')) -or
                -not (Test-BackportLiteral -Value $Arguments[2] -Allowed @('--no-recurse-submodules')) -or
                -not (Test-BackportLiteral -Value $Arguments[3] -Allowed @($origin))) {
                throw 'git_operation_failed'
            }
            foreach ($reference in $Arguments[4..($Arguments.Count - 1)]) {
                # Closed merged PRs may have no branch; prove their immutable GitHub head ref.
                if ($Arguments.Count -eq 5 -and
                    [regex]::IsMatch($reference, '\Arefs/pull/[1-9][0-9]{0,9}/head\z')) {
                    $null = ConvertTo-BackportPositive $reference.Split('/')[2] 2147483648
                    continue
                }
                if ($reference -cnotmatch '\A\+refs/[A-Za-z0-9][A-Za-z0-9._/-]*:refs/[A-Za-z0-9][A-Za-z0-9._/-]*\z' -or
                    $reference.Contains('..') -or $reference.Contains('//')) { throw 'git_operation_failed' }
            }
        }
        if (Test-BackportLiteral -Value $command -Allowed @('ls-remote')) {
            if ($Arguments.Count -ne 4 -or -not (Test-BackportLiteral -Value $Arguments[1] -Allowed @('--heads')) -or
                -not (Test-BackportLiteral -Value $Arguments[2] -Allowed @($origin)) -or
                $Arguments[3] -cnotmatch '\Arefs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*\z' -or
                $Arguments[3].Contains('..') -or $Arguments[3].Contains('//') -or
                $Arguments[3].EndsWith('/') -or $Arguments[3].EndsWith('.') -or $Arguments[3].EndsWith('.lock')) {
                throw 'git_operation_failed'
            }
        }
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($key in @($info.Environment.psbase.Keys)) {
            if ($key -imatch '\A(GIT_|GH_TOKEN\z|GITHUB_TOKEN\z)') { $null = $info.Environment.Remove($key) }
        }
        $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
        $info.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
        $info.Environment['GIT_CONFIG_GLOBAL'] = $nullDevice
        $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
        $info.Environment['GIT_ATTR_NOSYSTEM'] = '1'
        $info.Environment['LC_ALL'] = 'C'
        foreach ($argument in @(
            '-c', 'core.hooksPath=', '-c', 'protocol.allow=never', '-c', 'protocol.https.allow=always',
            '-c', 'protocol.file.allow=never', '-c', 'protocol.ext.allow=never',
            '-c', 'http.followRedirects=false', '-c', 'submodule.recurse=false',
            '-c', 'core.fsmonitor=false', '-c', 'core.quotePath=true',
            '-c', 'core.autocrlf=false', '-c', "core.attributesFile=$nullDevice",
            '-c', 'core.longpaths=true', '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false',
            '-c', 'credential.helper=', '-C', $Directory
        )) { $info.ArgumentList.Add($argument) }
        $info.ArgumentList.Add($command)
        if (Test-BackportLiteral -Value $command -Allowed @('init')) { $info.ArgumentList.Add('--template=') }
        if (Test-BackportLiteral -Value $command -Allowed @('diff', 'show', 'log')) {
            $info.ArgumentList.Add('--no-ext-diff')
            $info.ArgumentList.Add('--no-textconv')
        }
        if ($Arguments.Count -gt 1) {
            foreach ($argument in $Arguments[1..($Arguments.Count - 1)]) {
                if ((Test-BackportLiteral -Value $command -Allowed @('init')) -and
                    $argument.StartsWith('--template', [StringComparison]::Ordinal)) { throw 'git_operation_failed' }
                $info.ArgumentList.Add($argument)
            }
        }
        if ($Auth) {
            $credential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:' + (Get-BackportToken)))
            $info.Environment['GIT_CONFIG_COUNT'] = '1'
            $info.Environment['GIT_CONFIG_KEY_0'] = "http.$origin.extraHeader"
            $info.Environment['GIT_CONFIG_VALUE_0'] = 'Authorization: Basic ' + $credential
        }
        return $info
    }
    catch { throw 'git_operation_failed' }
}

function Invoke-BackportGit {
    param(
        $Config,
        [Alias('Directory')][string]$WorkingDirectory,
        [AllowEmptyCollection()][string[]]$Arguments,
        [AllowNull()][AllowEmptyCollection()][byte[]]$Data,
        [int[]]$ExpectedExitCodes = @(0),
        [switch]$Auth
    )
    $info = New-BackportGitStartInfo -Config $Config -WorkingDirectory $WorkingDirectory -Arguments $Arguments -Auth:$Auth
    try {
        if ($ExpectedExitCodes.Count -eq 0 -or @($ExpectedExitCodes | Where-Object { $_ -notin @(0, 1) }).Count) {
            throw 'git_operation_failed'
        }
        $result = Invoke-BackportProcess -StartInfo $info -Data $Data
        if ($result.exit_code -notin $ExpectedExitCodes -or ($Auth -and $result.exit_code -ne 0)) {
            throw 'git_operation_failed'
        }
        return $result
    }
    catch {
        if ($Auth) { throw 'push_failed_or_ambiguous' }
        throw 'git_operation_failed'
    }
    finally {
        if ($info) {
            $null = $info.Environment.Remove('GIT_CONFIG_VALUE_0')
            $null = $info.Environment.Remove('GIT_CONFIG_KEY_0')
            $null = $info.Environment.Remove('GIT_CONFIG_COUNT')
        }
    }
}

function Get-BackportGitWorkDirectoryOwners {
    if (-not (Get-Variable -Name BackportGitWorkDirectoryOwners -Scope Script -ErrorAction SilentlyContinue)) {
        $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
        $script:BackportGitWorkDirectoryOwners = [Collections.Generic.Dictionary[string, object]]::new($comparer)
    }
    return ,$script:BackportGitWorkDirectoryOwners
}

function New-BackportGitWorkDirectory {
    param($Config)
    $directory = $null
    $registered = $false
    try {
        if (-not [IO.Path]::IsPathFullyQualified($Config.work_dir)) { throw 'git_operation_failed' }
        $parent = [IO.Path]::GetFullPath($Config.work_dir)
        Assert-BackportGitLocalConfig -Directory $parent -AllowUninitialized
        $null = [IO.Directory]::CreateDirectory($parent)
        $token = [guid]::NewGuid().ToString('N')
        $directory = Join-Path $parent ('repo-' + $token)
        $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
        $owner = [pscustomobject]@{ token = $token; marker = (Join-Path $directory '.backport-owner') }
        [IO.File]::WriteAllText($owner.marker, $token)
        (Get-BackportGitWorkDirectoryOwners).Add($directory, $owner)
        $registered = $true
        $null = Invoke-BackportGit -Config $Config -Directory $directory -Arguments @('init')
        $marker = Join-Path $directory '.git\backport-owner'
        [IO.File]::Move($owner.marker, $marker)
        $owner.marker = $marker
        $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
        foreach ($pair in @{
            'user.name' = 'github-actions[bot]'
            'user.email' = '41898282+github-actions[bot]@users.noreply.github.com'
            'core.autocrlf' = 'false'; 'core.attributesFile' = $nullDevice
            'core.longpaths' = 'true'; 'commit.gpgsign' = 'false'
        }.GetEnumerator()) {
            $null = Invoke-BackportGit -Config $Config -Directory $directory -Arguments @('config', $pair.Key, $pair.Value)
        }
        return $directory
    }
    catch {
        if ($registered) {
            try { Remove-BackportGitWorkDirectory -Directory $directory }
            catch { throw 'git_operation_failed' }
        }
        throw 'git_operation_failed'
    }
}

function Remove-BackportGitWorkDirectory {
    param([string]$Directory)
    try {
        if (-not [IO.Path]::IsPathFullyQualified($Directory)) { throw 'git_operation_failed' }
        $path = [IO.Path]::GetFullPath($Directory)
        $owners = Get-BackportGitWorkDirectoryOwners
        if (-not $owners.ContainsKey($path) -or -not [IO.Directory]::Exists($path)) { throw 'git_operation_failed' }
        $owner = $owners[$path]
        Assert-BackportGitLocalConfig -Directory $path -AllowUninitialized
        $marker = Get-Item -LiteralPath $owner.marker -Force -ErrorAction Stop
        if ($marker.PSIsContainer -or ($marker.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $marker.Length -ne 32 -or -not (Test-BackportLiteral -Value ([IO.File]::ReadAllText($owner.marker)) -Allowed @($owner.token))) {
            throw 'git_operation_failed'
        }
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        $null = $owners.Remove($path)
    }
    catch { throw 'git_operation_failed' }
}

function New-BackportHttpClient {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    return $client
}

function New-BackportHttpDeadline {
    [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(60))
}

function Invoke-BackportHttp {
    param(
        $Config,
        [string]$Method,
        [string]$Path,
        [AllowNull()]$Data
    )
    if (-not (Test-BackportLiteral -Value $Method -Allowed @('GET', 'POST', 'PATCH'))) { throw 'invalid_api_method' }
    $isGet = Test-BackportLiteral -Value $Method -Allowed @('GET')
    try {
        $root = '/repos/AleksanderGladkov/BCApps-Backport-Test'
        $route = $Path.Split('?', 2)[0]
        $repositoryRoute = (Test-BackportLiteral -Value $route -Allowed @($root)) -or $route.StartsWith($root + '/', [StringComparison]::Ordinal)
        $userRoute = $isGet -and $Path -cmatch '\A/users/[A-Za-z0-9-]+\z'
        if ((-not $repositoryRoute -and -not $userRoute) -or
            $Path -cmatch '[\\#\x00-\x20\x7f]' -or $Path -cmatch '%(?![0-9A-Fa-f]{2})') {
            throw 'invalid_api_path'
        }
        $decodedRoute = [uri]::UnescapeDataString($route)
        if ($decodedRoute -cmatch '[\\#\x00-\x20\x7f]' -or $decodedRoute -cmatch '(\A|/)\.{1,2}(/|\z)' -or
            $decodedRoute.Contains('%')) { throw 'invalid_api_path' }
        $uri = [uri]::new('https://api.github.com' + $Path, [UriKind]::Absolute)
        if (-not (Test-BackportLiteral -Value $uri.Host -Allowed @('api.github.com')) -or
            -not (Test-BackportLiteral -Value $uri.Scheme -Allowed @('https')) -or $uri.Port -ne 443 -or
            ($repositoryRoute -and -not (Test-BackportLiteral -Value $uri.AbsolutePath -Allowed @($root)) -and
                -not $uri.AbsolutePath.StartsWith($root + '/', [StringComparison]::Ordinal))) {
            throw 'invalid_api_path'
        }
    }
    catch { throw 'invalid_api_path' }
    if (-not $isGet -and $Config.dry_run) { throw 'dry_run_write_blocked' }
    $token = Get-BackportToken
    $client = $null
    $deadline = $null
    $request = $null
    $response = $null
    $stream = $null
    $body = $null
    $result = $null
    $failure = if ($isGet) { 'api_read_failed' } else { 'api_write_ambiguous' }
    try {
        $deadline = New-BackportHttpDeadline
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $uri)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $request.Headers.Accept.ParseAdd('application/vnd.github+json')
        $request.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
        $request.Headers.UserAgent.ParseAdd('bc-backport-demo')
        if ($null -ne $Data) {
            $request.Content = [Net.Http.ByteArrayContent]::new((ConvertTo-BackportJsonBytes -Value $Data))
        }
        else { $request.Content = [Net.Http.ByteArrayContent]::new([byte[]]::new(0)) }
        $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
        $client = New-BackportHttpClient
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {
            $failure = 'api_redirect_rejected'
            throw $failure
        }
        if (-not $response.IsSuccessStatusCode) { throw $failure }
        $stream = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
        $body = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(65536)
        $limit = 16 * 1024 * 1024
        while ($true) {
            $count = [int][Math]::Min($buffer.Length, $limit + 1 - $body.Length)
            $read = $stream.ReadAsync($buffer, 0, $count, $deadline.Token).GetAwaiter().GetResult()
            if ($read -eq 0) { break }
            $body.Write($buffer, 0, $read)
            if ($body.Length -gt $limit) {
                $failure = 'api_response_too_large'
                throw $failure
            }
        }
        $result = ConvertFrom-BackportJsonBytes -Bytes $body.ToArray()
    }
    catch { throw $failure }
    finally {
        $cleanupFailed = $false
        foreach ($resource in @($body, $stream, $response, $request, $client, $deadline)) {
            if ($null -ne $resource) {
                try { $resource.Dispose() }
                catch { $cleanupFailed = $true }
            }
        }
        $token = $null
        if ($cleanupFailed) { throw $failure }
    }
    return ,$result
}

function Get-BackportField {
    param([AllowNull()]$Value, [string]$Name, [AllowNull()]$Default = $null)
    if ($Value -isnot [Collections.IDictionary]) { throw 'invalid_data_or_local_io' }
    foreach ($key in $Value.psbase.Keys) {
        if ([string]::Equals($key, $Name, [StringComparison]::Ordinal)) { return ,$Value[$key] }
    }
    return ,$Default
}

function Get-BackportObjectField {
    param($Value, [string]$Name)
    return ,(Get-BackportField $Value $Name -Default (New-BackportDictionary))
}

function Test-BackportBodyMarker {
    param([AllowNull()]$Value, [string]$Marker)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $Value.Contains($Marker, [StringComparison]::Ordinal) }
    if ($Value -is [Collections.IDictionary]) {
        return [Array]::IndexOf[string]([string[]]@($Value.psbase.Keys), $Marker) -ge 0
    }
    if ($Value -is [array]) {
        foreach ($item in $Value) { if (Test-BackportLiteral $item @($Marker)) { return $true } }
        return $false
    }
    if (Test-BackportNumberEqual $Value 0) { return $false }
    throw 'invalid_data_or_local_io'
}

function Test-BackportNumberEqual {
    param([AllowNull()]$Left, [AllowNull()]$Right)
    # Python numeric equality does not coerce strings or round a float to an integer.
    $leftInteger = (Test-BackportInteger $Left) -or $Left -is [bool]
    $rightInteger = (Test-BackportInteger $Right) -or $Right -is [bool]
    if ($leftInteger -and $rightInteger) {
        return [Numerics.BigInteger]$Left -eq [Numerics.BigInteger]$Right
    }
    if ($Left -is [double] -and $Right -is [double]) { return $Left -eq $Right }
    if ($leftInteger -and $Right -is [double]) {
        return [double]::IsFinite($Right) -and [Math]::Truncate($Right) -eq $Right -and
            [Numerics.BigInteger]$Left -eq [Numerics.BigInteger]$Right
    }
    if ($rightInteger -and $Left -is [double]) {
        return [double]::IsFinite($Left) -and [Math]::Truncate($Left) -eq $Left -and
            [Numerics.BigInteger]$Left -eq [Numerics.BigInteger]$Right
    }
    return $false
}

function Assert-BackportSha {
    param([AllowNull()]$Value)
    if ($Value -isnot [string] -or -not [regex]::IsMatch($Value, '\A[0-9a-f]{40}\z')) { throw 'invalid_sha' }
    return $Value
}

function Test-BackportSequence {
    param([object[]]$Left, [object[]]$Right)
    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if (-not (Test-BackportLiteral $Left[$index] @($Right[$index]))) { return $false }
    }
    return $true
}

function Get-BackportPlanHash {
    param($Plan)
    Get-BackportHash (ConvertTo-BackportJsonBytes $Plan)
}

function Get-BackportBranch {
    param($Config)
    'backport/29.x/pr-' + [string]$Config.source_pr
}

function Invoke-BackportGitCommand {
    param($Config, [string]$Directory, [string[]]$Arguments,
        [AllowNull()][AllowEmptyCollection()][byte[]]$Data)
    # These commands use their native exit status as evidence, including non-1 failures.
    if (-not (Test-BackportLiteral $Arguments[0] @('merge-base','apply','cherry-pick'))) {
        throw 'git_operation_failed'
    }
    $info = New-BackportGitStartInfo -Config $Config -Directory $Directory -Arguments $Arguments
    Invoke-BackportProcess -StartInfo $info -Data $Data
}

function Get-BackportGitBytes {
    param($Config, [string]$Directory, [string[]]$Arguments)
    $result = Invoke-BackportGit -Config $Config -Directory $Directory -Arguments $Arguments
    return ,$result.stdout
}

function Get-BackportGitText {
    param($Config, [string]$Directory, [string[]]$Arguments)
    $bytes = Get-BackportGitBytes -Config $Config -Directory $Directory -Arguments $Arguments
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { throw 'invalid_data_or_local_io' }
    return $text.Trim((Get-BackportCompatibility).WhitespaceCharacters)
}

function Get-BackportLines {
    param([string]$Text)
    if ($Text.Length -eq 0) { return ,([string[]]@()) }
    $lines = [regex]::Split($Text, '\r\n|[\n\r\v\f\x1c-\x1e\x85\u2028\u2029]')
    if ($lines[-1].Length -eq 0) {
        return ,([string[]]$lines[0..($lines.Count - 2)])
    }
    return ,$lines
}

function Invoke-BackportFetch {
    param($Config, [string]$Directory)
    $null = Invoke-BackportGit -Config $Config -Directory $Directory -Arguments @(
        'fetch','--no-tags','--no-recurse-submodules',
        'https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
        '+refs/heads/main:refs/remotes/demo/main',
        '+refs/heads/releases/29.x:refs/remotes/demo/target',
        "+refs/pull/$($Config.source_pr)/head:refs/remotes/demo/head"
    )
}

function Test-BackportAncestor {
    param($Config, [string]$Directory, [string]$Old, [string]$New)
    $result = Invoke-BackportGitCommand -Config $Config -Directory $Directory -Arguments @('merge-base','--is-ancestor',$Old,$New)
    if ($result.exit_code -notin @(0,1)) { throw 'git_ancestry_failed' }
    return $result.exit_code -eq 0
}

function Get-BackportRawDiff {
    param($Config, [string]$Directory, [string]$Old, [string]$New)
    return ,(Get-BackportGitBytes -Config $Config -Directory $Directory -Arguments @(
        'diff','--raw','--no-abbrev','-z','--no-renames','--no-ext-diff','--no-textconv',$Old,$New,'--'
    ))
}

function Get-BackportPatch {
    param($Config, [string]$Directory, [string]$Old, [string]$New)
    $bytes = Get-BackportGitBytes -Config $Config -Directory $Directory -Arguments @(
        'diff','--binary','--full-index','--no-renames','--no-ext-diff','--no-textconv',$Old,$New,'--'
    )
    return ,(Assert-BackportPatch $bytes)
}

function Get-BackportCheckedDiff {
    param($Config, [string]$Directory, [string]$Old, [string]$New)
    $raw = Get-BackportRawDiff -Config $Config -Directory $Directory -Old $Old -New $New
    $entries = ConvertFrom-BackportRawDiff $raw
    $objects = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        foreach ($oid in @($entry.old_id, $entry.new_id)) {
            if ((Test-BackportLiteral $oid @('0' * 40)) -or -not $objects.Add($oid)) { continue }
            $size = Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('cat-file','-s',$oid)
            if ([Numerics.BigInteger]::Parse($size, [Globalization.CultureInfo]::InvariantCulture) -gt 1MB) { throw 'file_too_large' }
            $null = Assert-BackportBlob (Get-BackportGitBytes -Config $Config -Directory $Directory -Arguments @('cat-file','blob',$oid))
        }
    }
    $patch = Get-BackportPatch -Config $Config -Directory $Directory -Old $Old -New $New
    return @{ raw = $raw; entries = $entries; patch = $patch }
}

function Get-BackportSourceProof {
    param($Config, [string]$Directory, [string]$SourceSha, [string]$HeadSha,
        [string]$TargetSha, [object[]]$Commits, [AllowNull()]$Count = $null)
    $head = Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-parse','refs/remotes/demo/head')
    if (-not (Test-BackportLiteral $head @($HeadSha))) { throw 'source_head_changed' }
    if (-not (Test-BackportAncestor -Config $Config -Directory $Directory -Old $SourceSha -New 'refs/remotes/demo/main')) {
        throw 'source_not_on_main'
    }
    if (-not (Test-BackportAncestor -Config $Config -Directory $Directory -Old $TargetSha -New 'refs/remotes/demo/target')) {
        throw 'target_history_changed'
    }
    $parents = (Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-list','--parents','-n','1',$SourceSha)).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($parents.Count -ne 2) { throw 'source_not_squash' }
    $parent = Assert-BackportSha $parents[1]
    if ((Test-BackportLiteral $SourceSha $Commits) -and -not (Test-BackportSequence $Commits @($SourceSha))) {
        throw 'source_not_squash'
    }
    foreach ($commit in $Commits) {
        if (Test-BackportAncestor -Config $Config -Directory $Directory -Old $commit -New $parent) { throw 'source_not_squash' }
    }
    $bases = Get-BackportLines (Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('merge-base','--all',$parent,$HeadSha))
    if ($bases.Count -ne 1) { throw 'ambiguous_merge_base' }
    $checked = Get-BackportCheckedDiff -Config $Config -Directory $Directory -Old $parent -New $SourceSha
    $headDiff = Get-BackportRawDiff -Config $Config -Directory $Directory -Old (Assert-BackportSha $bases[0]) -New $HeadSha
    if ($checked.entries.Count -eq 0 -or -not [Linq.Enumerable]::SequenceEqual[byte]($checked.raw, $headDiff)) {
        throw 'source_not_squash'
    }
    if ($null -ne $Count -and (-not (Test-BackportInteger $Count) -or $checked.entries.Count -ne $Count)) {
        throw 'changed_files_mismatch'
    }
    return @{ files = [object[]]@($checked.entries | ForEach-Object { $_.path }); patch = $checked.patch }
}

function Invoke-BackportApply {
    param($Config, [string]$Directory, $Plan)
    $source = $Plan['source_sha']; $target = $Plan['target_base_sha']
    $null = Invoke-BackportGit -Config $Config -Directory $Directory -Arguments @('checkout','--detach',$target)
    if (Test-BackportAncestor -Config $Config -Directory $Directory -Old $source -New $target) {
        return @{ outcome = @{status='already_applied'; reason='source_ancestor'}; patch=[byte[]]@(); files=[object[]]@() }
    }
    $originalPatch = Get-BackportPatch -Config $Config -Directory $Directory -Old ($source + '^') -New $source
    $reverse = Invoke-BackportGitCommand -Config $Config -Directory $Directory -Arguments @('apply','--reverse','--check','--binary','-') -Data $originalPatch
    if ($reverse.exit_code -eq 0) {
        return @{ outcome = @{status='already_applied'; reason='reverse_patch_proven'}; patch=[byte[]]@(); files=[object[]]@() }
    }
    $picked = Invoke-BackportGitCommand -Config $Config -Directory $Directory -Arguments @('cherry-pick','-x',$source)
    $approved = [Collections.Generic.HashSet[string]]::new([string[]]$Plan['files'], [StringComparer]::Ordinal)
    if ($picked.exit_code -ne 0) {
        $raw = Get-BackportGitBytes -Config $Config -Directory $Directory -Arguments @('diff','--name-only','--diff-filter=U','-z')
        try { $names = [Text.UTF8Encoding]::new($false, $true).GetString($raw).Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) }
        catch { throw 'invalid_data_or_local_io' }
        $files = [object[]]@($names | ForEach-Object { Assert-BackportPath $_ })
        foreach ($file in $files) { if (-not $approved.Contains($file)) { throw 'unexpected_conflict_paths' } }
        if ($files.Count -eq 0) { throw 'unproven_empty_or_failed_cherry_pick' }
        return @{ outcome=@{status='needs-attention'; reason='cherry_pick_conflict'}; patch=[byte[]]@(); files=$files }
    }
    $commit = Assert-BackportSha (Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-parse','HEAD'))
    $checked = Get-BackportCheckedDiff -Config $Config -Directory $Directory -Old $target -New $commit
    if ($checked.entries.Count -eq 0) { throw 'unexpected_result_paths' }
    foreach ($entry in $checked.entries) { if (-not $approved.Contains($entry.path)) { throw 'unexpected_result_paths' } }
    $parent = Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-parse',($commit + '^'))
    if (-not (Test-BackportLiteral $parent @($target))) { throw 'wrong_commit_parent' }
    $tree = Assert-BackportSha (Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-parse','HEAD^{tree}'))
    return @{
        outcome = @{status='applied'; reason='clean_cherry_pick'; commit_sha=$commit; tree_sha=$tree}
        patch = $checked.patch; files = [object[]]@()
    }
}

function Get-BackportBranchHead {
    param($Config, [string]$Directory)
    $branch = Get-BackportBranch $Config
    $raw = Get-BackportGitBytes -Config $Config -Directory $Directory -Arguments @(
        'ls-remote','--heads','https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',('refs/heads/' + $branch)
    )
    foreach ($byte in $raw) { if ($byte -gt 127) { throw 'invalid_data_or_local_io' } }
    if ($raw.Length -eq 0) { return $null }
    $text = [Text.Encoding]::ASCII.GetString($raw)
    $lines = [regex]::Split($text, '\r\n|[\r\n]')
    if ($lines[-1].Length -eq 0) { $lines = [string[]]$lines[0..($lines.Count - 2)] }
    if ($lines.Count -gt 1) { throw 'ambiguous_branch' }
    if ($lines.Count -eq 0) { return $null }
    $fields = $lines[0].Split("`t")
    if ($fields.Count -ne 2 -or -not (Test-BackportLiteral $fields[1] @('refs/heads/' + $branch))) {
        throw 'invalid_branch_response'
    }
    $head = Assert-BackportSha $fields[0]
    $null = Invoke-BackportGit -Config $Config -Directory $Directory -Arguments @(
        'fetch','--no-tags','--no-recurse-submodules','https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
        ('+refs/heads/' + $branch + ':refs/remotes/demo/backport')
    )
    $fetched = Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-parse','refs/remotes/demo/backport')
    if (-not (Test-BackportLiteral $fetched @($head))) { throw 'branch_changed' }
    return $head
}

function Assert-BackportBranch {
    param($Config, [string]$Directory, [string]$Head, $Plan, [string]$Tree)
    $parents = (Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-list','--parents','-n','1',$Head)).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if (-not (Test-BackportSequence $parents @($Head, $Plan['target_base_sha']))) { throw 'existing_branch_parent_mismatch' }
    $actualTree = Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('rev-parse',($Head + '^{tree}'))
    if (-not (Test-BackportLiteral $actualTree @($Tree))) { throw 'existing_branch_tree_mismatch' }
    $stamp = '(cherry picked from commit ' + $Plan['source_sha'] + ')'
    $message = Get-BackportLines (Get-BackportGitText -Config $Config -Directory $Directory -Arguments @('show','-s','--format=%B',$Head))
    if (-not (Test-BackportLiteral $stamp $message)) { throw 'existing_branch_provenance_mismatch' }
}

function Invoke-BackportPush {
    param($Config, [string]$Directory)
    if ($Config.dry_run) { throw 'dry_run_write_blocked' }
    $ref = 'refs/heads/' + (Get-BackportBranch $Config)
    $null = Invoke-BackportGit -Config $Config -Directory $Directory -Auth -Arguments @(
        'push','--porcelain','https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
        ('--force-with-lease=' + $ref + ':'),('HEAD:' + $ref)
    )
}

function Get-BackportApiPages {
    param($Config, [string]$Suffix)
    $values = [Collections.Generic.List[object]]::new()
    $separator = if ($Suffix.Contains('?')) { '&' } else { '?' }
    for ($page = 1; $page -le 1000; $page++) {
        $chunk = Invoke-BackportHttp -Config $Config -Method GET -Path (
            '/repos/AleksanderGladkov/BCApps-Backport-Test' + $Suffix + $separator + 'per_page=100&page=' + $page
        )
        if ($chunk -isnot [array] -or $chunk.Count -gt 100) { throw 'invalid_api_page' }
        foreach ($item in $chunk) { $values.Add($item) }
        if ($chunk.Count -lt 100) { return ,$values.ToArray() }
    }
    throw 'pagination_limit'
}

function Assert-BackportRepository {
    param([AllowNull()]$Value)
    if ($Value -isnot [Collections.IDictionary]) { throw 'repository_mismatch' }
    $id = Get-BackportField $Value 'id'
    if (-not (Test-BackportInteger $id) -or $id -ne 1369849596 -or
        -not (Test-BackportLiteral (Get-BackportField $Value 'full_name') @('AleksanderGladkov/BCApps-Backport-Test'))) {
        throw 'repository_mismatch'
    }
}

function Get-BackportRunIdentity {
    param([AllowNull()]$Run)
    if ($Run -isnot [Collections.IDictionary]) { throw 'invalid_run_history' }
    foreach ($key in @('id','workflow_id','run_attempt')) {
        $value = Get-BackportField $Run $key
        if (-not (Test-BackportInteger $value) -or $value -le 0) { throw 'invalid_run_history' }
    }
    Assert-BackportRepository (Get-BackportField $Run 'repository')
    Assert-BackportRepository (Get-BackportField $Run 'head_repository')
    if (-not (Test-BackportLiteral (Get-BackportField $Run 'path') @('.github/workflows/backport-demo.yml')) -or
        -not (Test-BackportLiteral (Get-BackportField $Run 'event') @('workflow_dispatch')) -or
        -not (Test-BackportLiteral (Get-BackportField $Run 'head_branch') @('main'))) { throw 'unknown_run_history' }
    $title = Get-BackportField $Run 'display_title'
    if ($title -isnot [string]) { throw 'unknown_run_history' }
    $match = [regex]::Match($title, '\ABackport PR ([1-9][0-9]{0,9}) to 29\.x \(dry run = (true|false)\)\z')
    if (-not $match.Success) { throw 'unknown_run_history' }
    return @{
        source_pr = ConvertTo-BackportPositive $match.Groups[1].Value 2147483648
        dry_run = Test-BackportLiteral $match.Groups[2].Value @('true')
    }
}

function Assert-BackportFreshCreation {
    param($Config)
    if ($Config.dry_run) { throw 'dry_run_write_blocked' }
    $current = Invoke-BackportHttp -Config $Config -Method GET -Path (
        '/repos/AleksanderGladkov/BCApps-Backport-Test/actions/runs/' + $Config.run_id
    )
    $identity = Get-BackportRunIdentity $current
    if ($identity.source_pr -ne $Config.source_pr -or $identity.dry_run -ne $Config.dry_run -or
        $current['id'] -ne (ConvertTo-BackportPositive $Config.run_id) -or
        $current['run_attempt'] -ne (ConvertTo-BackportPositive $Config.run_attempt)) { throw 'current_run_mismatch' }
    if ($current['run_attempt'] -ne 1) { throw 'previous_run_may_have_written' }
    $seen = [Collections.Generic.HashSet[Numerics.BigInteger]]::new()
    $total = $null
    for ($page = 1; $page -le 1000; $page++) {
        $value = Invoke-BackportHttp -Config $Config -Method GET -Path (
            '/repos/AleksanderGladkov/BCApps-Backport-Test/actions/workflows/backport-demo.yml/runs?per_page=100&page=' + $page
        )
        if ($value -isnot [Collections.IDictionary]) { throw 'invalid_run_history_page' }
        $count = Get-BackportField $value 'total_count'
        $runs = Get-BackportField $value 'workflow_runs'
        if (-not (Test-BackportInteger $count) -or $count -lt 0 -or $runs -isnot [array]) {
            throw 'invalid_run_history_page'
        }
        if ($null -eq $total) {
            $total = $count
            if ($total -gt 100000) { throw 'pagination_limit' }
        }
        if ($count -ne $total) { throw 'run_history_changed' }
        if ($runs.Count -ne [Math]::Min(100, [int]$total - $seen.Count)) { throw 'incomplete_run_history' }
        foreach ($run in $runs) {
            $identity = Get-BackportRunIdentity $run
            if ($run['workflow_id'] -ne $current['workflow_id']) { throw 'wrong_history_workflow' }
            if (-not $seen.Add([Numerics.BigInteger]$run['id'])) { throw 'duplicate_run_history' }
            if ($run['id'] -eq $current['id']) {
                if ($run['run_attempt'] -ne $current['run_attempt'] -or
                    -not (Test-BackportLiteral $run['display_title'] @($current['display_title']))) { throw 'current_run_mismatch' }
            }
            elseif ($identity.source_pr -eq $Config.source_pr -and -not $identity.dry_run) { throw 'previous_run_may_have_written' }
        }
        if ($seen.Count -eq $total) {
            if (-not $seen.Contains([Numerics.BigInteger]$current['id'])) { throw 'current_run_missing_from_history' }
            return
        }
    }
    throw 'pagination_limit'
}

function Get-BackportRemoteContext {
    param($Config, [AllowNull()]$Plan = $null)
    Assert-BackportRepository (Invoke-BackportHttp -Config $Config -Method GET -Path '/repos/AleksanderGladkov/BCApps-Backport-Test')
    $user = Invoke-BackportHttp -Config $Config -Method GET -Path ('/users/' + [uri]::EscapeDataString($Config.triggering_actor))
    $id = Get-BackportField $user 'id'
    if (-not (Test-BackportInteger $id) -or $Config.allowed_actor_ids -notcontains $id -or
        $Config.allowed_actor_ids -notcontains $Config.actor_id) { throw 'triggering_actor_not_allowed' }
    $login = Get-BackportField $user 'login' -Default ''
    # Python container repr cannot match a login; PowerShell can unwrap singleton arrays.
    if ($login -is [array] -or $login -is [Collections.IDictionary]) { throw 'triggering_actor_mismatch' }
    $folded = if ($null -eq $login) { 'None' }
        elseif ($login -is [double]) {
            if ([double]::IsNaN($login)) { 'nan' }
            elseif ([double]::IsPositiveInfinity($login)) { 'inf' }
            elseif ([double]::IsNegativeInfinity($login)) { '-inf' }
            else {
                $text = $login.ToString('R', [Globalization.CultureInfo]::InvariantCulture).Replace('E', 'e')
                # Integral floats must not impersonate Python's integer spelling.
                if (-not $text.Contains('.') -and -not $text.Contains('e')) { $text += '.0' }
                $text
            }
        }
        else { [string]$login }
    if (-not (Test-BackportLiteral (ConvertTo-BackportCaseFold $folded) @((ConvertTo-BackportCaseFold $Config.triggering_actor)))) {
        throw 'triggering_actor_mismatch'
    }
    $source = Invoke-BackportHttp -Config $Config -Method GET -Path ('/repos/AleksanderGladkov/BCApps-Backport-Test/pulls/' + $Config.source_pr)
    $merged = Get-BackportField $source 'merged'
    if (-not (Test-BackportNumberEqual (Get-BackportField $source 'number') $Config.source_pr) -or
        $merged -isnot [bool] -or -not $merged) { throw 'source_not_merged' }
    $base = Get-BackportObjectField $source 'base'
    Assert-BackportRepository (Get-BackportField $base 'repo')
    if (-not (Test-BackportLiteral (Get-BackportField $base 'ref') @('main'))) { throw 'source_wrong_base' }
    $sourceSha = Assert-BackportSha (Get-BackportField $source 'merge_commit_sha')
    $head = Assert-BackportSha (Get-BackportField (Get-BackportObjectField $source 'head') 'sha')
    $branch = Invoke-BackportHttp -Config $Config -Method GET -Path '/repos/AleksanderGladkov/BCApps-Backport-Test/branches/releases%2F29.x'
    $target = Assert-BackportSha (Get-BackportField (Get-BackportField $branch 'commit') 'sha')
    if ($null -ne $Plan -and (-not (Test-BackportLiteral $sourceSha @($Plan['source_sha'])) -or
        -not (Test-BackportLiteral $head @($Plan['source_head_sha'])))) { throw 'source_changed' }
    return @{ source = $source; target = $target }
}

function Read-BackportPlan {
    param($Config)
    $plan = Read-BackportArtifact $Config 'plan.json'
    foreach ($key in @('source_sha','source_head_sha','target_base_sha')) { $null = Assert-BackportSha $plan[$key] }
    if (-not (Test-BackportLiteral $plan['target_ref'] @('releases/29.x'))) { throw 'wrong_target' }
    if ($plan['files'] -isnot [array] -or $plan['files'].Count -lt 1 -or $plan['files'].Count -gt 50) { throw 'invalid_plan_files' }
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $plan['files']) {
        $null = Assert-BackportPath $path
        if (-not $files.Add($path)) { throw 'duplicate_plan_files' }
    }
    if ($plan['commits'] -isnot [array] -or $plan['commits'].Count -lt 1 -or $plan['commits'].Count -gt 250) { throw 'invalid_plan_commits' }
    foreach ($commit in $plan['commits']) { $null = Assert-BackportSha $commit }
    if (-not (Test-BackportLiteral $plan['commits'][-1] @($plan['source_head_sha']))) { throw 'incomplete_commit_list' }
    return ,$plan
}

function Get-BackportSourceCommits {
    param($Config)
    $commits = [Collections.Generic.List[object]]::new()
    foreach ($item in (Get-BackportApiPages -Config $Config -Suffix ("/pulls/$($Config.source_pr)/commits"))) {
        $commits.Add((Assert-BackportSha (Get-BackportField $item 'sha')))
    }
    return ,$commits.ToArray()
}

function Assert-BackportPlanProof {
    param($Config, [string]$Directory, $Plan, $Source)
    $commits = Get-BackportSourceCommits $Config
    if (-not (Test-BackportSequence $commits $Plan['commits'])) { throw 'source_commits_changed' }
    Invoke-BackportFetch -Config $Config -Directory $Directory
    $proof = Get-BackportSourceProof -Config $Config -Directory $Directory -SourceSha $Plan['source_sha'] `
        -HeadSha $Plan['source_head_sha'] -TargetSha $Plan['target_base_sha'] -Commits $commits -Count (Get-BackportField $Source 'changed_files')
    if (-not (Test-BackportSequence $proof.files $Plan['files'])) { throw 'plan_files_mismatch' }
}

function Get-BackportMarker {
    param($Config, $Plan)
    '<!-- bc-backport:v1:1369849596:' + $Config.source_pr + ':' + $Plan['source_sha'] + ':29 -->'
}

function Get-BackportIssueBody {
    param($Config, $Plan)
    "Source: https://github.com/AleksanderGladkov/BCApps-Backport-Test/pull/$($Config.source_pr)`nSource SHA: $($Plan['source_sha'])`n`n" +
        (Get-BackportMarker $Config $Plan)
}

function Get-BackportPrBody {
    param($Config, $Plan, $Issue, [string]$Tree)
    "Backport of #$($Config.source_pr)`nFixes #$Issue`n`n" + (Get-BackportMarker $Config $Plan) +
        "`nSource SHA: $($Plan['source_sha'])`nTarget base: $($Plan['target_base_sha'])`nApplied tree: $Tree"
}

function Assert-BackportBot {
    param($Value)
    if (-not (Test-BackportNumberEqual (Get-BackportField (Get-BackportObjectField $Value 'user') 'id') 41898282)) {
        throw 'object_not_actions_bot_owned'
    }
}

function Get-BackportObjectUrl {
    param($Value, [string]$Kind)
    $number = Get-BackportField $Value 'number'
    if (-not (Test-BackportInteger $number) -or $number -le 0 -or $number -ge 2147483648) { throw 'invalid_object_number' }
    $id = Get-BackportField $Value 'id'
    if (-not (Test-BackportInteger $id) -or $id -le 0) { throw 'invalid_object_id' }
    $expected = 'https://github.com/AleksanderGladkov/BCApps-Backport-Test/' + $Kind + '/' + $number
    if (-not (Test-BackportLiteral (Get-BackportField $Value 'html_url') @($expected))) { throw 'invalid_object_url' }
    return $expected
}

function Assert-BackportIssue {
    param($Config, $Value, $Plan)
    Assert-BackportBot $Value
    $null = Get-BackportObjectUrl $Value 'issues'
    if ([Array]::IndexOf[string]([string[]]@($Value.psbase.Keys), 'pull_request') -ge 0 -or
        -not (Test-BackportLiteral (Get-BackportField $Value 'body') @((Get-BackportIssueBody $Config $Plan)))) { throw 'issue_marker_mismatch' }
    if (-not (Test-BackportLiteral (Get-BackportField $Value 'state') @('open','closed'))) { throw 'invalid_issue_state' }
}

function Get-BackportPulls {
    param($Config)
    $result = [Collections.Generic.List[object]]::new()
    $branch = Get-BackportBranch $Config
    foreach ($value in (Get-BackportApiPages -Config $Config -Suffix '/pulls?state=all')) {
        $head = Get-BackportObjectField $value 'head'
        if (Test-BackportLiteral (Get-BackportField $head 'ref') @($branch)) {
            $null = Get-BackportObjectUrl $value 'pull'
            Assert-BackportBot $value
            Assert-BackportRepository (Get-BackportField $head 'repo')
            $base = Get-BackportObjectField $value 'base'
            Assert-BackportRepository (Get-BackportField $base 'repo')
            if (-not (Test-BackportLiteral (Get-BackportField $base 'ref') @('releases/29.x'))) { throw 'branch_pr_base_mismatch' }
            $result.Add($value)
        }
    }
    if ($result.Count -gt 1) { throw 'duplicate_backport_prs' }
    return ,$result.ToArray()
}

function Assert-BackportPr {
    param($Config, $Value, $Plan, $Issue, [string]$Head, [string]$Tree)
    Assert-BackportBot $Value
    $null = Get-BackportObjectUrl $Value 'pull'
    foreach ($part in @('head','base')) { Assert-BackportRepository (Get-BackportField (Get-BackportObjectField $Value $part) 'repo') }
    $actualHead = Get-BackportField $Value 'head'
    $base = Get-BackportField $Value 'base'
    if (-not (Test-BackportLiteral (Get-BackportField $actualHead 'ref') @((Get-BackportBranch $Config))) -or
        -not (Test-BackportLiteral (Get-BackportField $actualHead 'sha') @($Head)) -or
        -not (Test-BackportLiteral (Get-BackportField $base 'ref') @('releases/29.x'))) { throw 'pr_branch_mismatch' }
    if (-not (Test-BackportLiteral (Get-BackportField $Value 'body') @((Get-BackportPrBody $Config $Plan $Issue $Tree)))) {
        throw 'pr_provenance_mismatch'
    }
    $state = Get-BackportField $Value 'state'; $merged = Get-BackportField $Value 'merged'
    if (-not (Test-BackportLiteral $state @('open')) -and
        -not ((Test-BackportLiteral $state @('closed')) -and $merged -is [bool] -and $merged)) { throw 'closed_unmerged_pr' }
}

function Assert-BackportExistingPrProof {
    param($Config, $Plan, $Issue, $Source)
    $candidates = Get-BackportPulls $Config
    if ($candidates.Count -ne 1) { throw 'issue_without_verified_pr' }
    $value = Invoke-BackportHttp -Config $Config -Method GET -Path (
        '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls/' + $candidates[0]['number']
    )
    $null = Get-BackportObjectUrl $value 'pull'
    $merged = Get-BackportField $value 'merged'
    if ((Test-BackportLiteral $Issue['state'] @('closed')) -and ($merged -isnot [bool] -or -not $merged)) {
        throw 'closed_issue_without_merged_pr'
    }
    $directory = New-BackportGitWorkDirectory $Config
    try {
        Assert-BackportPlanProof -Config $Config -Directory $directory -Plan $Plan -Source $Source
        $applied = Invoke-BackportApply -Config $Config -Directory $directory -Plan $Plan
        if (-not (Test-BackportLiteral $applied.outcome['status'] @('applied'))) { throw 'closed_issue_without_content_proof' }
        $head = Assert-BackportSha (Get-BackportField (Get-BackportObjectField $value 'head') 'sha')
        $null = Invoke-BackportGit -Config $Config -Directory $directory -Arguments @(
            'fetch','--no-tags','--no-recurse-submodules','https://github.com/AleksanderGladkov/BCApps-Backport-Test.git',
            "refs/pull/$($value['number'])/head"
        )
        $fetched = Get-BackportGitText -Config $Config -Directory $directory -Arguments @('rev-parse','FETCH_HEAD')
        if (-not (Test-BackportLiteral $fetched @($head))) { throw 'pr_head_changed' }
        Assert-BackportBranch -Config $Config -Directory $directory -Head $head -Plan $Plan -Tree $applied.outcome['tree_sha']
        Assert-BackportPr -Config $Config -Value $value -Plan $Plan -Issue $Issue['number'] -Head $head -Tree $applied.outcome['tree_sha']
    }
    finally { Remove-BackportGitWorkDirectory $directory }
}

function Read-BackportTracking {
    param($Config, $Plan, $Source)
    $value = Read-BackportArtifact $Config 'tracking.json'
    if (-not (Test-BackportLiteral $value['plan_hash'] @((Get-BackportPlanHash $Plan)))) { throw 'tracking_plan_mismatch' }
    if ($Config.dry_run) {
        if (-not (Test-BackportLiteral $value['status'] @('dry-run')) -or $null -ne $value['issue_number'] -or
            $null -ne $value['issue_id'] -or $null -ne $value['issue_url']) { throw 'invalid_dry_tracking' }
        return ,$value
    }
    if (-not (Test-BackportLiteral $value['status'] @('tracked'))) { throw 'tracking_incomplete' }
    $number = $value['issue_number']
    if (-not (Test-BackportInteger $number) -or $number -le 0 -or $number -ge 2147483648) { throw 'invalid_issue_number' }
    $issue = Invoke-BackportHttp -Config $Config -Method GET -Path ('/repos/AleksanderGladkov/BCApps-Backport-Test/issues/' + $number)
    Assert-BackportIssue -Config $Config -Value $issue -Plan $Plan
    if (-not (Test-BackportNumberEqual $issue['id'] $value['issue_id']) -or
        -not (Test-BackportLiteral $value['issue_url'] @($issue['html_url']))) { throw 'tracking_issue_mismatch' }
    if (Test-BackportLiteral $issue['state'] @('closed')) { Assert-BackportExistingPrProof -Config $Config -Plan $Plan -Issue $issue -Source $Source }
    return ,$value
}

function Add-BackportTextFile {
    param([string]$Path, [string]$Text)
    if (-not $Path) { return }
    Assert-BackportRegularFile $Path -AllowMissing
    # Match Python text-file newline translation without touching artifacts or HTTP bodies.
    $Text = $Text.Replace("`n", [Environment]::NewLine)
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length) }
    finally { $stream.Dispose() }
}

function Write-BackportOutput {
    param($Config, [Collections.IDictionary]$Values)
    $compat = Get-BackportCompatibility
    $builder = [Text.StringBuilder]::new()
    foreach ($key in $Values.psbase.Keys) {
        $value = $Values[$key]
        if ($key -isnot [string] -or -not [regex]::IsMatch($key, '\A[a-z_][a-z0-9_]*\z') -or
            $value -isnot [string]) { throw 'unsafe_output' }
        for ($index = 0; $index -lt $value.Length; $index++) {
            $point = [int]$value[$index]
            if ([char]::IsHighSurrogate($value[$index]) -and $index + 1 -lt $value.Length -and
                [char]::IsLowSurrogate($value[$index + 1])) {
                $point = [char]::ConvertToUtf32($value, $index)
                $index++
            }
            if ($compat.CategoryC[$point]) { throw 'unsafe_output' }
        }
        $null = $builder.Append($key).Append('=').Append($value).Append("`n")
    }
    Add-BackportTextFile -Path $Config.output -Text $builder.ToString()
}

function Write-BackportSummary {
    param($Config, [string]$Status, [AllowNull()]$Plan = $null)
    if (-not [regex]::IsMatch($Status, '\A[a-z_-]+\z')) { throw 'unsafe_summary' }
    $details = ''
    if ($null -ne $Plan) {
        $source = Assert-BackportSha $Plan['source_sha']
        $target = Assert-BackportSha $Plan['target_base_sha']
        if (-not (Test-BackportLiteral $Plan['target_ref'] @('releases/29.x'))) { throw 'wrong_target' }
        if ($Plan['files'] -isnot [array] -or $Plan['files'].Count -lt 1 -or $Plan['files'].Count -gt 50) { throw 'invalid_plan_files' }
        $files = [object[]]@($Plan['files'] | ForEach-Object { Assert-BackportPath $_ })
        $escaped = [string]::Join("`n", $files).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#x27;')
        $details = "`nSource: https://github.com/AleksanderGladkov/BCApps-Backport-Test/pull/$($Config.source_pr)" +
            "`n`nSource SHA: $source`n`nTarget: releases/29.x`n`nTarget base SHA: $target" +
            "`n`nBranch: $(Get-BackportBranch $Config)`n`nFiles ($($files.Count)):`n<pre>`n$escaped`n</pre>`n"
    }
    $dry = if ($Config.dry_run) { 'true' } else { 'false' }
    $noChanges = if ($Config.dry_run) { 'No remote changes. ' } else { '' }
    $text = "`n### Backport #$($Config.source_pr) to 29.x`n`nDry run: $dry. $($noChanges)Status: $Status.`n" + $details
    Add-BackportTextFile -Path $Config.summary -Text $text
}

function Invoke-BackportValidate {
    param($Config)
    $context = Get-BackportRemoteContext $Config
    $source = $context.source
    $commits = Get-BackportSourceCommits $Config
    $head = Get-BackportField (Get-BackportObjectField $source 'head') 'sha'
    if ($commits.Count -lt 1 -or $commits.Count -gt 250 -or -not (Test-BackportLiteral $commits[-1] @($head))) {
        throw 'incomplete_commit_list'
    }
    $directory = New-BackportGitWorkDirectory $Config
    try {
        Invoke-BackportFetch -Config $Config -Directory $directory
        $target = Get-BackportGitText -Config $Config -Directory $directory -Arguments @('rev-parse','refs/remotes/demo/target')
        if (-not (Test-BackportLiteral $target @($context.target))) { throw 'target_changed' }
        $proof = Get-BackportSourceProof -Config $Config -Directory $directory -SourceSha $source['merge_commit_sha'] `
            -HeadSha $head -TargetSha $context.target -Commits $commits -Count (Get-BackportField $source 'changed_files')
    }
    finally { Remove-BackportGitWorkDirectory $directory }
    $plan = Get-BackportBinding $Config
    $plan['source_sha'] = $source['merge_commit_sha']
    $plan['source_head_sha'] = $head
    $plan['target_ref'] = 'releases/29.x'
    $plan['target_base_sha'] = $context.target
    $plan['files'] = $proof.files
    $plan['commits'] = $commits
    if (Test-Path -LiteralPath (Get-BackportStatePath $Config 'plan.json')) {
        $previous = Read-BackportPlan $Config
        if (-not [Linq.Enumerable]::SequenceEqual[byte]((ConvertTo-BackportJsonBytes $previous), (ConvertTo-BackportJsonBytes $plan))) {
            throw 'existing_plan_changed'
        }
    }
    Write-BackportState $Config 'plan.json' $plan
    Write-BackportOutput -Config $Config -Values @{ plan_ready = 'true' }
    Write-BackportSummary -Config $Config -Status 'validated' -Plan $plan
    return ,$plan
}

function Invoke-BackportTrack {
    param($Config)
    $plan = Read-BackportPlan $Config
    $context = Get-BackportRemoteContext $Config $plan
    $state = Get-BackportBinding $Config
    $state['plan_hash'] = Get-BackportPlanHash $plan
    $state['status'] = 'dry-run'
    $state['issue_number'] = $null; $state['issue_id'] = $null; $state['issue_url'] = $null
    if ($Config.dry_run) {
        Write-BackportState $Config 'tracking.json' $state
        Write-BackportSummary -Config $Config -Status 'dry-run' -Plan $plan
        return ,$state
    }
    $marker = Get-BackportMarker $Config $plan
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($value in (Get-BackportApiPages -Config $Config -Suffix '/issues?state=all')) {
        if ($value -isnot [Collections.IDictionary]) { throw 'invalid_data_or_local_io' }
        if ([Array]::IndexOf[string]([string[]]@($value.psbase.Keys), 'pull_request') -ge 0) { continue }
        $body = Get-BackportField $value 'body'
        if (Test-BackportBodyMarker $body $marker) { $candidates.Add($value) }
    }
    if ($candidates.Count -gt 1) { throw 'duplicate_tracking_issues' }
    $pulls = Get-BackportPulls $Config
    if ($candidates.Count -gt 0) {
        $null = Get-BackportObjectUrl $candidates[0] 'issues'
        $issue = Invoke-BackportHttp -Config $Config -Method GET -Path (
            '/repos/AleksanderGladkov/BCApps-Backport-Test/issues/' + $candidates[0]['number']
        )
    }
    else {
        if ($pulls.Count -gt 0) { throw 'existing_pr_without_tracking_issue' }
        if (Test-Path -LiteralPath (Get-BackportStatePath $Config 'tracking.json')) {
            $previous = Read-BackportArtifact $Config 'tracking.json'
            if (Test-BackportLiteral $previous['status'] @('ambiguous')) { throw 'issue_create_ambiguous' }
            throw 'previous_issue_missing'
        }
        Assert-BackportFreshCreation $Config
        $state['status'] = 'ambiguous'
        Write-BackportState $Config 'tracking.json' $state
        $issue = Invoke-BackportHttp -Config $Config -Method POST -Path '/repos/AleksanderGladkov/BCApps-Backport-Test/issues' -Data @{
            title = "[29.x] Backport #$($Config.source_pr)"; body = Get-BackportIssueBody $Config $plan
        }
        $null = Get-BackportObjectUrl $issue 'issues'
        $issue = Invoke-BackportHttp -Config $Config -Method GET -Path ('/repos/AleksanderGladkov/BCApps-Backport-Test/issues/' + $issue['number'])
    }
    Assert-BackportIssue -Config $Config -Value $issue -Plan $plan
    if ((Test-BackportLiteral $issue['state'] @('closed')) -or $pulls.Count -gt 0) {
        Assert-BackportExistingPrProof -Config $Config -Plan $plan -Issue $issue -Source $context.source
    }
    $state['status'] = 'tracked'
    $state['issue_number'] = $issue['number']; $state['issue_id'] = $issue['id']; $state['issue_url'] = $issue['html_url']
    Write-BackportState $Config 'tracking.json' $state
    Write-BackportOutput -Config $Config -Values @{ issue_number = [string]$issue['number'] }
    Write-BackportSummary -Config $Config -Status 'tracked' -Plan $plan
    return ,$state
}

function Invoke-BackportPrepare {
    param($Config)
    $plan = Read-BackportPlan $Config
    $context = Get-BackportRemoteContext $Config $plan
    $null = Read-BackportTracking -Config $Config -Plan $plan -Source $context.source
    $directory = New-BackportGitWorkDirectory $Config
    $keep = $false
    try {
        Assert-BackportPlanProof -Config $Config -Directory $directory -Plan $plan -Source $context.source
        $applied = Invoke-BackportApply -Config $Config -Directory $directory -Plan $plan
        $result = Get-BackportBinding $Config
        $result['plan_hash'] = Get-BackportPlanHash $plan
        $result['published'] = $false; $result['commit_sha'] = $null; $result['tree_sha'] = $null
        $result['patch_sha256'] = Get-BackportHash $applied.patch
        foreach ($key in $applied.outcome.psbase.Keys) { $result[$key] = $applied.outcome[$key] }
        Write-BackportState $Config 'patch.bin' $applied.patch
        if ($applied.files.Count -gt 0) {
            $keep = $true
            $files = [object[]]@($applied.files | ForEach-Object {
                @{ relative_path = $_; absolute_path = [IO.Path]::GetFullPath([IO.Path]::Combine($directory, $_)) }
            })
            Write-BackportState $Config 'conflict.json' @{
                repo = 'AleksanderGladkov/BCApps-Backport-Test'; source_pr = $Config.source_pr
                source_sha = $plan['source_sha']; target_base_sha = $plan['target_base_sha']
                worktree = $directory; files = $files
            }
        }
        else {
            $conflict = Get-BackportStatePath $Config 'conflict.json'
            if (Test-Path -LiteralPath $conflict) { Remove-Item -LiteralPath $conflict -Force }
        }
        Write-BackportState $Config 'result.json' $result
    }
    finally { if (-not $keep) { Remove-BackportGitWorkDirectory $directory } }
    Write-BackportOutput -Config $Config -Values ([ordered]@{
        status = $result['status']; result_artifact = 'result.json'; result_sha256 = Get-BackportPlanHash $result
    })
    Write-BackportSummary -Config $Config -Status $result['status'] -Plan $plan
    return ,$result
}

function Read-BackportResult {
    param($Config, $Plan)
    $result = Read-BackportArtifact $Config 'result.json'
    if (-not (Test-BackportLiteral $result['plan_hash'] @((Get-BackportPlanHash $Plan))) -or
        $result['published'] -isnot [bool] -or $result['published']) { throw 'result_plan_mismatch' }
    $status = $result['status']; $reason = $result['reason']
    $supported = ((Test-BackportLiteral $status @('applied')) -and (Test-BackportLiteral $reason @('clean_cherry_pick'))) -or
        ((Test-BackportLiteral $status @('already_applied')) -and (Test-BackportLiteral $reason @('source_ancestor','reverse_patch_proven'))) -or
        ((Test-BackportLiteral $status @('needs-attention')) -and (Test-BackportLiteral $reason @('cherry_pick_conflict')))
    if (-not $supported) { throw 'unsupported_result' }
    if (Test-BackportLiteral $status @('applied')) {
        $null = Assert-BackportSha $result['commit_sha']
        $null = Assert-BackportSha $result['tree_sha']
    }
    elseif ($null -ne $result['commit_sha'] -or $null -ne $result['tree_sha']) { throw 'invalid_noop_result' }
    try {
        $path = Get-BackportStatePath $Config 'patch.bin'
        Assert-BackportRegularFile $path
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 5MB) { throw 'invalid_patch' }
            $bytes = [byte[]]::new([int]$stream.Length)
            $stream.ReadExactly($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
    }
    catch { throw 'invalid_patch' }
    $digest = $result['patch_sha256']
    if ($digest -isnot [string] -or -not [regex]::IsMatch($digest, '\A[0-9a-f]{64}\z') -or
        -not (Test-BackportLiteral (Get-BackportHash $bytes) @($digest))) { throw 'patch_digest_mismatch' }
    return ,$result
}

function Get-BackportPublicationJournal {
    param($Config, $Plan)
    if (Test-Path -LiteralPath (Get-BackportStatePath $Config 'publication.json')) {
        $value = Read-BackportArtifact $Config 'publication.json'
        if (-not (Test-BackportLiteral $value['plan_hash'] @((Get-BackportPlanHash $Plan))) -or
            $value['attempted'] -isnot [array]) { throw 'invalid_publication_journal' }
        foreach ($key in $value['attempted']) { if ($key -isnot [string]) { throw 'invalid_publication_journal' } }
        return ,$value
    }
    $value = Get-BackportBinding $Config
    $value['plan_hash'] = Get-BackportPlanHash $Plan
    $value['attempted'] = [object[]]@()
    return ,$value
}

function Invoke-BackportWriteOnce {
    param($Config, $Plan, [string]$Key, [string]$Method, [string]$Path, $Data)
    if ($Config.dry_run) { throw 'dry_run_write_blocked' }
    $journal = Get-BackportPublicationJournal $Config $Plan
    if (Test-BackportLiteral $Key $journal['attempted']) { throw 'publication_write_ambiguous' }
    if (Test-BackportLiteral $Method @('POST')) { Assert-BackportFreshCreation $Config }
    $journal['attempted'] = [object[]]@($journal['attempted']) + [object[]]@($Key)
    Write-BackportState $Config 'publication.json' $journal
    return ,(Invoke-BackportHttp -Config $Config -Method $Method -Path $Path -Data $Data)
}

function Invoke-BackportFeedback {
    param($Config, $Plan, $Tracking, [string]$Status, [string]$PrUrl = '', [string]$Reason = '')
    if (-not (Test-BackportLiteral $Status @('needs-attention','already_applied','pr-created','pr-reused'))) {
        throw 'invalid_feedback_status'
    }
    if (-not (Test-BackportLiteral $Reason @('','target_advanced','source_ancestor','reverse_patch_proven','cherry_pick_conflict'))) {
        throw 'invalid_feedback_reason'
    }
    $marker = (Get-BackportMarker $Config $Plan) + "`n<!-- bc-backport-status -->"
    $body = $marker + "`nBackport #$($Config.source_pr) to 29.x: $Status."
    if ($Reason) { $body += "`nReason: $Reason." }
    if ($PrUrl) { $body += "`n$PrUrl" }
    foreach ($number in @($Tracking['issue_number'], $Config.source_pr)) {
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($comment in (Get-BackportApiPages -Config $Config -Suffix ("/issues/$number/comments"))) {
            $commentBody = Get-BackportField $comment 'body'
            if ((Test-BackportNumberEqual (Get-BackportField (Get-BackportObjectField $comment 'user') 'id') 41898282) -and
                (Test-BackportBodyMarker $commentBody $marker)) { $matches.Add($comment) }
        }
        if ($matches.Count -gt 1) { throw 'duplicate_status_comments' }
        if ($matches.Count -gt 0) {
            $comment = $matches[0]
            $id = Get-BackportField $comment 'id'
            if (-not (Test-BackportInteger $id) -or $id -le 0) { throw 'invalid_comment_id' }
            if (Test-BackportLiteral (Get-BackportField $comment 'body') @($body)) { continue }
            $path = '/repos/AleksanderGladkov/BCApps-Backport-Test/issues/comments/' + $id
            $method = 'PATCH'
        }
        else {
            $path = "/repos/AleksanderGladkov/BCApps-Backport-Test/issues/$number/comments"
            $method = 'POST'
        }
        $suffix = if (Test-BackportLiteral $method @('POST')) { ':create' }
            else { ':' + (Get-BackportHash ([Text.UTF8Encoding]::new($false, $true).GetBytes($body))) }
        $key = 'comment:' + $number + $suffix
        $value = Invoke-BackportWriteOnce -Config $Config -Plan $Plan -Key $key -Method $method -Path $path -Data @{body=$body}
        Assert-BackportBot $value
        if (-not (Test-BackportLiteral (Get-BackportField $value 'body') @($body))) { throw 'comment_readback_mismatch' }
    }
}

function Complete-BackportStage {
    param($Config, $Plan, $Tracking, [string]$Status, [string]$PrUrl = '', [string]$Reason = '')
    if (-not $Config.dry_run) { Invoke-BackportFeedback -Config $Config -Plan $Plan -Tracking $Tracking -Status $Status -PrUrl $PrUrl -Reason $Reason }
    $values = [ordered]@{status=$Status}
    if ($PrUrl) { $values['pr_url'] = $PrUrl }
    Write-BackportOutput -Config $Config -Values $values
    Write-BackportSummary -Config $Config -Status $Status -Plan $Plan
    $result = New-BackportDictionary
    foreach ($key in $values.psbase.Keys) { $result[$key] = $values[$key] }
    $result['reason'] = $Reason
    return ,$result
}

function Invoke-BackportPublish {
    param($Config)
    $plan = Read-BackportPlan $Config
    $context = Get-BackportRemoteContext $Config $plan
    $tracking = Read-BackportTracking -Config $Config -Plan $plan -Source $context.source
    $result = Read-BackportResult -Config $Config -Plan $plan
    if ($Config.dry_run) { return ,(Complete-BackportStage -Config $Config -Plan $plan -Tracking $tracking -Status 'dry-run') }
    if (-not (Test-BackportLiteral $context.target @($plan['target_base_sha']))) {
        return ,(Complete-BackportStage -Config $Config -Plan $plan -Tracking $tracking -Status 'needs-attention' -Reason 'target_advanced')
    }
    $directory = New-BackportGitWorkDirectory $Config
    try {
        Assert-BackportPlanProof -Config $Config -Directory $directory -Plan $plan -Source $context.source
        $applied = Invoke-BackportApply -Config $Config -Directory $directory -Plan $plan
        $computed = $applied.outcome
        $tree = Get-BackportField $computed 'tree_sha'
        $sameTree = if ($null -eq $tree) { $null -eq $result['tree_sha'] } else { Test-BackportLiteral $tree @($result['tree_sha']) }
        if (-not (Test-BackportLiteral $computed['status'] @($result['status'])) -or
            -not (Test-BackportLiteral $computed['reason'] @($result['reason'])) -or -not $sameTree -or
            -not (Test-BackportLiteral (Get-BackportHash $applied.patch) @($result['patch_sha256']))) { throw 'recomputed_result_mismatch' }
        if (-not (Test-BackportLiteral $result['status'] @('applied'))) {
            return ,(Complete-BackportStage -Config $Config -Plan $plan -Tracking $tracking -Status $result['status'] -Reason $result['reason'])
        }
        $candidates = Get-BackportPulls $Config
        $head = Get-BackportBranchHead -Config $Config -Directory $directory
        if ($null -ne $head) { Assert-BackportBranch -Config $Config -Directory $directory -Head $head -Plan $plan -Tree $result['tree_sha'] }
        if ($candidates.Count -gt 0) {
            if ($null -eq $head) { throw 'existing_pr_branch_missing' }
            $value = Invoke-BackportHttp -Config $Config -Method GET -Path (
                '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls/' + $candidates[0]['number']
            )
            Assert-BackportPr -Config $Config -Value $value -Plan $plan -Issue $tracking['issue_number'] -Head $head -Tree $result['tree_sha']
            return ,(Complete-BackportStage -Config $Config -Plan $plan -Tracking $tracking -Status 'pr-reused' -PrUrl $value['html_url'])
        }
        $current = Get-BackportRemoteContext $Config $plan
        if (-not (Test-BackportLiteral $current.target @($plan['target_base_sha']))) {
            return ,(Complete-BackportStage -Config $Config -Plan $plan -Tracking $tracking -Status 'needs-attention' -Reason 'target_advanced')
        }
        $journal = Get-BackportPublicationJournal $Config $plan
        if (Test-BackportLiteral 'pr' $journal['attempted']) { throw 'pr_create_ambiguous' }
        if ($null -eq $head) {
            if (Test-BackportLiteral 'push' $journal['attempted']) { throw 'push_ambiguous' }
            Assert-BackportFreshCreation $Config
            $journal['attempted'] = [object[]]@($journal['attempted']) + [object[]]@('push')
            Write-BackportState $Config 'publication.json' $journal
            Invoke-BackportPush -Config $Config -Directory $directory
            $head = Get-BackportBranchHead -Config $Config -Directory $directory
            if (-not (Test-BackportLiteral $head @($computed['commit_sha']))) { throw 'push_readback_mismatch' }
            Assert-BackportBranch -Config $Config -Directory $directory -Head $head -Plan $plan -Tree $result['tree_sha']
        }
        $current = Get-BackportRemoteContext $Config $plan
        if (-not (Test-BackportLiteral $current.target @($plan['target_base_sha']))) {
            return ,(Complete-BackportStage -Config $Config -Plan $plan -Tracking $tracking -Status 'needs-attention' -Reason 'target_advanced')
        }
        $value = Invoke-BackportWriteOnce -Config $Config -Plan $plan -Key 'pr' -Method POST `
            -Path '/repos/AleksanderGladkov/BCApps-Backport-Test/pulls' -Data @{
                title = "Backport #$($Config.source_pr) to 29.x"; head = Get-BackportBranch $Config
                base = 'releases/29.x'; body = Get-BackportPrBody $Config $plan $tracking['issue_number'] $result['tree_sha']; draft = $false
            }
        $null = Get-BackportObjectUrl $value 'pull'
        $value = Invoke-BackportHttp -Config $Config -Method GET -Path ('/repos/AleksanderGladkov/BCApps-Backport-Test/pulls/' + $value['number'])
        Assert-BackportPr -Config $Config -Value $value -Plan $plan -Issue $tracking['issue_number'] -Head $head -Tree $result['tree_sha']
        return ,(Complete-BackportStage -Config $Config -Plan $plan -Tracking $tracking -Status 'pr-created' -PrUrl $value['html_url'])
    }
    finally { Remove-BackportGitWorkDirectory $directory }
}

function Get-BackportSafeReason {
    param([string]$Reason)
    $allowed = @(
        'invalid_stage','wrong_repository','wrong_repository_id','wrong_execution_ref','invalid_number',
        'wrong_workflow_ref','unsupported_event','invalid_event_file','invalid_label_event','sender_not_allowed','request_projection_mismatch',
        'actor_not_allowed','invalid_triggering_actor','invalid_dry_run','missing_local_directories',
        'invalid_local_path','overlapping_directories','script_inside_work_directory','invalid_output_path',
        'missing_or_invalid_token','invalid_compatibility_data','invalid_artifact','duplicate_json_key',
        'invalid_artifact_schema','artifact_context_mismatch','invalid_json_type','state_write_failed',
        'invalid_path','invalid_diff','unsafe_mode','too_many_files','ambiguous_paths','invalid_blob',
        'file_too_large','binary_file','invalid_patch','patch_too_large','git_operation_failed',
        'push_failed_or_ambiguous','dry_run_write_blocked','invalid_api_method','invalid_api_path',
        'api_read_failed','api_write_ambiguous','api_redirect_rejected','api_response_too_large',
        'invalid_sha','git_ancestry_failed','source_head_changed','source_not_on_main','target_history_changed',
        'source_not_squash','ambiguous_merge_base','changed_files_mismatch','unexpected_conflict_paths',
        'unproven_empty_or_failed_cherry_pick','unexpected_result_paths','wrong_commit_parent',
        'ambiguous_branch','invalid_branch_response','branch_changed','existing_branch_parent_mismatch',
        'existing_branch_tree_mismatch','existing_branch_provenance_mismatch','unsafe_output','unsafe_summary',
        'wrong_target','invalid_plan_files','invalid_api_page','pagination_limit','repository_mismatch',
        'invalid_run_history','unknown_run_history','current_run_mismatch','previous_run_may_have_written',
        'invalid_run_history_page','run_history_changed','incomplete_run_history','wrong_history_workflow',
        'duplicate_run_history','current_run_missing_from_history','triggering_actor_not_allowed',
        'triggering_actor_mismatch','source_not_merged','source_wrong_base','source_changed','duplicate_plan_files',
        'invalid_plan_commits','incomplete_commit_list','source_commits_changed','plan_files_mismatch',
        'object_not_actions_bot_owned','invalid_object_number','invalid_object_id','invalid_object_url',
        'issue_marker_mismatch','invalid_issue_state','branch_pr_base_mismatch','duplicate_backport_prs',
        'pr_branch_mismatch','pr_provenance_mismatch','closed_unmerged_pr','issue_without_verified_pr',
        'closed_issue_without_merged_pr','closed_issue_without_content_proof','pr_head_changed',
        'tracking_plan_mismatch','invalid_dry_tracking','tracking_incomplete','invalid_issue_number',
        'tracking_issue_mismatch','target_changed','existing_plan_changed','duplicate_tracking_issues',
        'existing_pr_without_tracking_issue','issue_create_ambiguous','previous_issue_missing',
        'result_plan_mismatch','unsupported_result','invalid_noop_result','patch_digest_mismatch',
        'invalid_publication_journal','publication_write_ambiguous','invalid_feedback_status',
        'invalid_feedback_reason','duplicate_status_comments','invalid_comment_id','comment_readback_mismatch',
        'recomputed_result_mismatch','existing_pr_branch_missing','pr_create_ambiguous','push_ambiguous',
        'push_readback_mismatch','invalid_data_or_local_io'
    )
    if (Test-BackportLiteral $Reason $allowed) { return $Reason }
    return 'invalid_data_or_local_io'
}

Export-ModuleMember -Function Invoke-BackportCli
