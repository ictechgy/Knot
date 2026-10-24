#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Compile actual process ownership code with fresh inert executables; no production engine or UI.
$ErrorActionPreference='Stop'
$repository=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {throw 'The Windows .NET Framework compiler is required'}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('knot-engine-lifecycle-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
try {
    $pin=Join-Path $directory 'SyntheticEnginePin.cs'
    # EngineStore is compiled to retain the real EngineLease type. No installation method runs.
    [IO.File]::WriteAllText($pin,'namespace DeskBridge.Reverse { internal static class EnginePin { internal const string Version="synthetic", Url="https://github.com/synthetic", SHA256="unused"; internal const long Bytes=1; internal static readonly RuntimeEntry[] Entries=new RuntimeEntry[0]; } }')
    $executable=Join-Path $directory 'Lifecycle.exe'
    $sources=@('client/windows/EngineProcess.cs','client/windows/StreamQualityPolicy.cs','client/windows/EngineStore.cs','client/windows/PrivateFiles.cs','client/windows/ConnectionPolicy.cs','client/windows/ReverseErrors.cs','scripts/tests/EngineProcessLifecycle.cs') | ForEach-Object {Join-Path $repository $_}
    & $compiler /nologo /target:exe /platform:x64 /langversion:5 /main:DeskBridge.Reverse.EngineProcessLifecycle ("/out:"+$executable) /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll @sources $pin
    if ($LASTEXITCODE -ne 0) {throw 'Lifecycle fixture compilation failed'}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$executable; $start.Arguments='"'+$directory+'"'; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $child=[Diagnostics.Process]::Start($start)
    try {
        if (-not $child.WaitForExit(60000)) { $child.Kill(); $child.WaitForExit(); throw 'Lifecycle fixture timed out' }
        $output=$child.StandardOutput.ReadToEnd(); $errorOutput=$child.StandardError.ReadToEnd()
        if ($child.ExitCode -ne 0) {throw ('Lifecycle fixture failed: '+$errorOutput)}
        $record=$output | ConvertFrom-Json
        if ($record.status -ne 'passed' -or $record.checks -lt 35 -or $record.windowsJobRuntimeTested -ne $true) {throw 'Incomplete lifecycle evidence'}
        $output.Trim()
    } finally {$child.Dispose()}
} finally { [IO.Directory]::Delete($directory,$true) }
