#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Actual policy/session source + inert protocol replies; no HTTP, UI, host APIs or private data.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$source = Join-Path $root 'host/windows/SunshineQuickSetup.cs'
$fixture = Join-Path $root 'scripts/tests/SunshineQuickSetupChecks.cs'
$windowsFolder = [Environment]::GetFolderPath('Windows')
$compiler = $null
if ($windowsFolder) { $compiler = Join-Path $windowsFolder 'Microsoft.NET/Framework64/v4.0.30319/csc.exe' }
if ($compiler -and (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('knot-quick-setup-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    try {
        $executable = Join-Path $directory 'SyntheticQuickSetupChecks.exe'
        & $compiler /nologo /noconfig /reference:System.dll /reference:System.Core.dll /target:exe /platform:x64 /langversion:5 /warnaserror+ /define:KNOT_QUICKSETUP_POLICY_ONLY "/out:$executable" $source $fixture
        if ($LASTEXITCODE -ne 0) { throw 'Quick setup policy failed Framework C# 5 compilation.' }
        $output = @(& $executable)
        if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { throw 'Quick setup synthetic checks failed.' }
        $result = $output[-1] | ConvertFrom-Json
        $framework = $true
    } finally { [IO.Directory]::Delete($directory, $true) }
} elseif ($PSVersionTable.PSEdition -eq 'Core') {
    $definition = "#define KNOT_QUICKSETUP_POLICY_ONLY`n" + [IO.File]::ReadAllText($source) + "`n" + [IO.File]::ReadAllText($fixture)
    Add-Type -TypeDefinition $definition -CompilerOptions '/langversion:5'
    $result = [SunshineQuickSetupChecks]::Run() | ConvertFrom-Json
    $framework = $false
} else { throw 'The protected Framework C# compiler or PowerShell Core is required.' }
if ($result.status -cne 'passed' -or $result.checks -lt 148 -or -not $result.freshSyntheticOnly -or $result.nativeApisInvoked) { throw 'Incomplete quick setup fixture result.' }
$result | Add-Member -NotePropertyName frameworkCompiler -NotePropertyValue $framework
$result | ConvertTo-Json -Compress
