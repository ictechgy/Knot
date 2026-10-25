#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Only newly created synthetic files/processes; no installation, user vault, service or network.
param([string] $NativeClosePath)
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
    if ($NativeClosePath) { $close=[IO.Path]::GetFullPath($NativeClosePath); if (-not [IO.File]::Exists($close)) {throw 'Built native bridge missing'} }
    $target=Join-Path $directory 'Knot.exe'
    & $compiler /nologo /noconfig /target:winexe /platform:x64 /langversion:5 /warnaserror+ /reference:System.dll /reference:System.Windows.Forms.dll "/out:$target" (Join-Path $root 'scripts/tests/UpdateCloseFixture.cs') (Join-Path $root 'scripts/tests/CoordinatedUpdateFixture.cs') (Join-Path $root 'host/windows/KnotUpdateForm.cs')
    if ($LASTEXITCODE -ne 0) {throw 'Inert update target compilation failed'}
    Copy-Item -LiteralPath $target -Destination (Join-Path $directory 'DeskBridge-Managed.exe')
    Copy-Item -LiteralPath $target -Destination (Join-Path $directory 'UnsupportedEngine.exe')
    foreach ($case in @('ready','child','busy','drain','owner-child','orphan','mixed','nonce')) {
        $receipt=Join-Path $directory $case
        $process=[Diagnostics.Process]::Start($target,($case+' "'+$receipt+'"')); $owned.Add($process); $null=$process.Handle
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($receipt+'.ready')) {
            if ($process.HasExited -or $watch.ElapsedMilliseconds -gt 10000) {throw 'Synthetic form startup timeout'}
            Start-Sleep -Milliseconds 50
        }
        if ([IO.File]::Exists($receipt+'.child')) {
            $child=[Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($receipt+'.child'))
            $null=$child.Handle
            if ($child.MainModule.FileName -notin @((Join-Path $directory 'DeskBridge-Managed.exe'),(Join-Path $directory 'UnsupportedEngine.exe'))) {throw 'Unexpected synthetic child identity'}
            $owned.Add($child)
        }
        if ($case -eq 'nonce') {
            if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0 -or [IO.File]::ReadAllText($receipt+'.closed') -ne '6') {throw 'Production form nonce cancellation/admission failed'}
            continue
        }
        $legacy=$null
        if ($case -eq 'mixed') {
            $legacy=[Diagnostics.Process]::Start($target,('busy "'+$receipt+'-legacy"')); $owned.Add($legacy); $null=$legacy.Handle
            if (-not $legacy.WaitForInputIdle(10000)) {throw 'Mixed synthetic form startup timeout'}
        }
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$close; $start.Arguments='"'+$target+'"'; $start.UseShellExecute=$false
        $closer=[Diagnostics.Process]::Start($start)
        $elapsed=[Diagnostics.Stopwatch]::StartNew()
        try {
            if (-not $closer.WaitForExit(35000)) {throw 'Graceful update closure exceeded its budget'}
            if ($case -in @('busy','mixed')) {
                if ($closer.ExitCode -eq 0 -or $process.HasExited -or $elapsed.ElapsedMilliseconds -gt 23000) {throw 'Busy legacy owner was closed or inherited another owner drain budget'}
            }
            elseif ($closer.ExitCode -ne 0 -or -not $process.WaitForExit(3000)) {throw ('Owned synthetic UI did not close normally: '+$case)}
            if ($case -in @('drain','owner-child','orphan') -and $elapsed.ElapsedMilliseconds -lt 15000) {throw 'Protected work or an observed child was skipped'}
            if ([IO.File]::Exists($receipt+'.unexpected-signal')) {throw 'Bridge signaled an observer-only descendant'}
            if ($case -in @('owner-child','orphan') -and -not $child.HasExited) {throw 'Observer-only descendant survived successful closure'}
        } finally {$closer.Dispose()}
        if (-not $process.HasExited) {$process.Kill();$process.WaitForExit()}
        if ($legacy -and -not $legacy.HasExited) {$legacy.Kill();$legacy.WaitForExit()}
    }
    @{status='passed';checks=8;freshSyntheticOnly=$true;gracefulCloseRuntimeTested=$true;busyRefusalTested=$true;coordinatedDrainTested=$true;nonceCancellationTested=$true;observerRetentionTested=$true;perOwnerBudgetTested=$true;existingProcessesTargeted=$false;installerExecuted=$false;nativeBridgeTested=[bool]$NativeClosePath}|ConvertTo-Json -Compress
} finally {
    foreach ($process in $owned) {try {if (-not $process.HasExited) {$process.Kill();$process.WaitForExit()}} finally {$process.Dispose()}}
    [IO.Directory]::Delete($directory,$true)
}
