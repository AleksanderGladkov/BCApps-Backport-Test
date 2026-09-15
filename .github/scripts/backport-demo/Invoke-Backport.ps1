# Deliberately no parameter binder: errors must not echo untrusted argument values.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.4' -or [Environment]::Version -lt [version]'8.0') {
    [Console]::Error.WriteLine('backport_failed: unsupported_runtime')
    exit 1
}
try {
    Import-Module (Join-Path $PSScriptRoot 'Backport.psm1') -Force
    exit (Invoke-BackportCli -Arguments $args)
}
catch {
    [Console]::Error.WriteLine('backport_failed: backport_failed')
    exit 1
}
