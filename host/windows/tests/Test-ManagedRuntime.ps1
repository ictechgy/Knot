#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Only newly created synthetic files/processes; no installation, user vault, service or network.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$directory=Join-Path ([IO.Path]::GetTempPath()) ('knot-managed-runtime-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($directory)
$owned=New-Object 'Collections.Generic.List[Diagnostics.Process]'
try {
    $account=Join-Path $directory 'SyntheticAccountChecks.exe'
    & $compiler /nologo /noconfig /target:exe /platform:x64 /langversion:5 /warnaserror+ /reference:System.dll /reference:System.Core.dll /reference:System.Security.dll /define:KNOT_QUICKSETUP_POLICY_ONLY,KNOT_ACCOUNT_STORE_FIXTURE /main:ManagedAccountRuntimeChecks "/out:$account" (Join-Path $root 'host/windows/SunshineQuickSetup.cs') (Join-Path $root 'host/windows/SunshineAccount.cs') (Join-Path $root 'scripts/tests/ManagedAccountRuntimeChecks.cs')
    if ($LASTEXITCODE -ne 0) {throw 'Synthetic account fixture compilation failed'}
    $vault=Join-Path $directory 'fresh-vault'; $null=[IO.Directory]::CreateDirectory($vault)
    & $account $vault
    if ($LASTEXITCODE -ne 0) {throw 'Fresh DPAPI/account fixture failed'}
    $close=Join-Path $directory 'Close.exe'
    & $compiler /nologo /noconfig /target:winexe /platform:x64 /langversion:5 /warnaserror+ /reference:System.dll /reference:System.Core.dll "/out:$close" (Join-Path $root 'packaging/windows/KnotCloseForUpdate.cs')
    if ($LASTEXITCODE -ne 0) {throw 'Update close helper compilation failed'}
    $target=Join-Path $directory 'Knot.exe'
    & $compiler /nologo /noconfig /target:winexe /platform:x64 /langversion:5 /warnaserror+ /reference:System.dll /reference:System.Windows.Forms.dll "/out:$target" (Join-Path $root 'scripts/tests/UpdateCloseFixture.cs')
    if ($LASTEXITCODE -ne 0) {throw 'Inert update target compilation failed'}
    Copy-Item -LiteralPath $target -Destination (Join-Path $directory 'DeskBridge-Managed.exe')
    foreach ($case in @('ready','child','busy')) {
        $process=[Diagnostics.Process]::Start($target,$case); $owned.Add($process); $null=$process.Handle
        if ($case -eq 'child') {Start-Sleep -Milliseconds 1500} else {if (-not $process.WaitForInputIdle(10000)) {throw 'Synthetic form startup timeout'}}
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$close; $start.Arguments='"'+$target+'"'; $start.UseShellExecute=$false
        $closer=[Diagnostics.Process]::Start($start)
        try {
            if (-not $closer.WaitForExit(25000)) {throw 'Graceful update closure exceeded its budget'}
            if ($case -eq 'busy') {if ($closer.ExitCode -eq 0 -or $process.HasExited) {throw 'Busy synthetic work was force-closed'}}
            elseif ($closer.ExitCode -ne 0 -or -not $process.WaitForExit(3000)) {throw ('Owned synthetic UI did not close normally: '+$case)}
        } finally {$closer.Dispose()}
        if (-not $process.HasExited) {$process.Kill();$process.WaitForExit()}
    }
    @{status='passed';checks=3;freshSyntheticOnly=$true;gracefulCloseRuntimeTested=$true;busyRefusalTested=$true;existingProcessesTargeted=$false;installerExecuted=$false}|ConvertTo-Json -Compress
} finally {
    foreach ($process in $owned) {try {if (-not $process.HasExited) {$process.Kill();$process.WaitForExit()}} finally {$process.Dispose()}}
    [IO.Directory]::Delete($directory,$true)
}
