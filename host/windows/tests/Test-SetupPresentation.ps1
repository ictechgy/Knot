#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Never execute the application entry point or show its production form.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$directory=Join-Path ([IO.Path]::GetTempPath()) ('knot-presentation-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
try {
    $exe=Join-Path $directory 'SyntheticPresentationChecks.exe'
    & $compiler /nologo /noconfig /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /target:exe /platform:x64 /langversion:5 /warnaserror+ "/out:$exe" (Join-Path $root 'scripts/tests/WindowsSetupPresentationChecks.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Presentation fixture compilation failed' }
    $output=@(& $exe (Join-Path $root 'build/windows/DeskBridge-Managed.exe') $directory)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { throw 'Actual form presentation checks failed' }
    $result=$output[-1] | ConvertFrom-Json
    if ($result.status -cne 'passed' -or $result.checks -lt 17 -or -not $result.actualPackagedForm -or -not $result.freshSyntheticOnly -or $result.shown -or $result.network -or $result.vaultAccess) { throw 'Incomplete presentation evidence' }
    $result | ConvertTo-Json -Compress
} finally { [IO.Directory]::Delete($directory,$true) }
