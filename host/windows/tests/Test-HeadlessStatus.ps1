#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
param([string] $BootstrapPolicyRunner)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'HeadlessStatus.psm1') -Force
$count=0
function Check([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message }; $script:count++ }
foreach ($state in @('Unsupported','DeviceIdentityUnavailable','BootEvidenceUnavailable','Absent','Installed','InstalledPendingRestart','RemovalPending','LegacyRecoveryRequired','RecoveryRequired','Conflict','unknown','installed','')) {
    $text=Get-KnotHeadlessStatusText $state
    Check (-not [string]::IsNullOrWhiteSpace($text)) ('Missing state text: '+$state)
}
Check ((Get-KnotHeadlessStatusText 'LegacyRecoveryRequired') -match '관리자') 'Legacy pending must require manual recovery'
Check ((Get-KnotHeadlessStatusText 'InstalledPendingRestart') -match '재시작') 'Successful install must retain restart notice'
foreach ($operation in @('InstallVirtualDisplay','RemoveVirtualDisplay')) {
    foreach ($code in @(0,12,13,3010,2,1,1602)) {
        $text=Get-KnotHeadlessOperationText $operation $code
        Check (-not [string]::IsNullOrWhiteSpace($text)) 'Missing operation notice'
        if ($code -eq 13) { Check ($text -match '관리자' -and $text -match '반복') 'Blocked recovery must require investigation instead of another restart' }
        if ($code -eq 12) { Check ($text -match '완료하지 못|완료되지') 'Pending recovery must not claim completed installation/removal' }
        if ($code -eq 3010 -and $operation -ceq 'RemoveVirtualDisplay') { Check ($text -match '완료하지 못') 'Unexpected completed-removal restart must not attest success' }
    }
}
# Execute only the real wrapper's receipt helper and try/catch in a fresh child.
# Backend calls are inert, no Requires/elevation/import/device APIs are executed.
$wrapper=Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-DeskBridgeHeadless.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Wrapper parse failed' }
$helper=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Write-HeadlessReceipt' })
$body=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($helper.Count -ne 1 -or $body.Count -ne 1) { throw 'Wrapper test requires exact production helper and body' }
$runner=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$root=Join-Path ([IO.Path]::GetTempPath()) ('knot-headless-status-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $cases=@(
        @{Status='Installed';Completed=$true;Reboot=$false;Code=0;Receipts=@('operation-success')},
        @{Status='InstalledPendingRestart';Completed=$true;Reboot=$true;Code=3010;Receipts=@('operation-success','reboot-required')},
        @{Status='RemovalPending';Completed=$false;Reboot=$true;Code=12;Receipts=@('reboot-required')},
        @{Status='LegacyRecoveryRequired';Completed=$false;Reboot=$false;Code=13;Receipts=@('recovery-blocked')},
        @{Status='BootEvidenceUnavailable';Completed=$false;Reboot=$false;Code=13;Receipts=@('recovery-blocked')},
        @{Status='DeviceIdentityUnavailable';Completed=$false;Reboot=$false;Code=13;Receipts=@('recovery-blocked')},
        @{Status='LegacyRecoveryRequired';Completed=$false;Reboot=$true;Code=1;Receipts=@()},
        @{Status='RecoveryRequired';Completed=$false;Reboot=$false;Code=1;Receipts=@()}
    )
    foreach ($case in $cases) {
        $directory=Join-Path $root ([Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($directory)
        $fixture=[pscustomobject]@{Status=$case.Status;Completed=$case.Completed;RebootRequired=$case.Reboot} | ConvertTo-Json -Compress
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fixture))
        $prefix='$ErrorActionPreference="Stop"; $SuccessReceipt=$true; $NoPause=$true; $Operation="RemoveVirtualDisplay"; $script:FixtureResult=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encoded+'")) | ConvertFrom-Json; function Install-KnotVirtualDisplay { return $script:FixtureResult }; function Remove-KnotVirtualDisplay { return $script:FixtureResult }'
        $path=Join-Path $directory 'synthetic-wrapper.ps1'
        [IO.File]::WriteAllText($path,($prefix+[Environment]::NewLine+$helper[0].Extent.Text+[Environment]::NewLine+$body[0].Extent.Text),(New-Object Text.UTF8Encoding($true)))
        $output=@(& $runner -NoLogo -NoProfile -NonInteractive -File $path)
        $actualExit=$LASTEXITCODE; $expectedExit=$case.Code
        if ([IO.Path]::DirectorySeparatorChar -ne [char]92) { $expectedExit=$expectedExit -band 255 }
        Check ($actualExit -eq $expectedExit) ('Wrapper exit mismatch for '+$case.Status+': '+$actualExit)
        foreach ($name in @('operation-success','reboot-required','recovery-blocked')) {
            $receipt=Join-Path $directory $name; $exists=[IO.File]::Exists($receipt)
            Check ($exists -eq ($name -cin $case.Receipts) -and (-not $exists -or (Get-Item -LiteralPath $receipt).Length -eq 0)) ('Wrapper receipt mismatch: '+$case.Status+'/'+$name)
        }
        if ($BootstrapPolicyRunner) {
            $policyInput=$actualExit
            if ([IO.Path]::DirectorySeparatorChar -ne [char]92 -and $actualExit -eq (3010 -band 255) -and $case.Code -eq 3010) { $policyInput=3010 }
            $policyOutput=@(& $BootstrapPolicyRunner --headless-result RemoveVirtualDisplay $policyInput)
            if ($LASTEXITCODE -ne 0 -or $policyOutput.Count -ne 1) { throw 'Compiled outer bootstrap policy returned no result' }
            $policy=$policyOutput[0] | ConvertFrom-Json
            $expectedFinal=$case.Code; if ($expectedFinal -eq 1) { $expectedFinal=2 }
            Check ($policy.exitCode -eq $expectedFinal) ('Actual wrapper result lost at compiled native boundary: '+$case.Status)
            Check ($policy.showFailure -is [bool] -and $policy.showFailure -eq ($case.Code -eq 1)) ('Native boundary showed unexpected generic guidance: '+$case.Status)
        }
    }
} finally { [IO.Directory]::Delete($root,$true) }
# Execute the real refresh function with only event pumping, native scan creation and
# stopwatch creation replaced by inert leaves. No Form, display API or device inventory is used.
$uiPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Show-HeadlessSetup.ps1'
$uiAst=[Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$errors)
$refresh=@($uiAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Update-HeadlessState'})
Check ($errors.Count -eq 0 -and $refresh.Count -eq 1) 'Refresh fixture extracts one complete actual production function'
$refreshSource=$refresh[0].Extent.Text
Check ([regex]::Matches($refreshSource,[regex]::Escape('[Windows.Forms.Application]::DoEvents()')).Count -eq 3 -and
       [regex]::Matches($refreshSource,[regex]::Escape('[Knot.Headless.Native]::ScanAsync()')).Count -eq 1 -and
       [regex]::Matches($refreshSource,[regex]::Escape('[Diagnostics.Stopwatch]::StartNew()')).Count -eq 1) 'Every refresh fixture platform leaf is explicitly enumerated'
$refreshFixture=$refreshSource.Replace('[Windows.Forms.Application]::DoEvents()','Invoke-InertHeadlessEvents').Replace('[Knot.Headless.Native]::ScanAsync()','Get-InertHeadlessScan').Replace('[Diagnostics.Stopwatch]::StartNew()','New-InertHeadlessTimer')
$ownedId='ROOT\KNOTVDD\0123456789ABCDEF0123456789ABCDEF'
$probeCases=@(
 @{Status='Installed';Mode='Failed';Managed=$true;Remove=$true},
 @{Status='InstalledPendingRestart';Mode='Timeout';Managed=$true;Remove=$true},
 @{Status='RemovalPending';Mode='Failed';Managed=$true;Remove=$true},
 @{Status='RecoveryRequired';Mode='Timeout';Managed=$true;Remove=$true},
 @{Status='Installed';Mode='InitializeFailed';Managed=$true;Remove=$true},
 @{Status='Installed';Mode='StateFailed';Managed=$true;Remove=$false},
 @{Status='Installed';Mode='Failed';Managed=$false;Remove=$false},
 @{Status='Installed';Mode='Failed';Managed='true';Remove=$false},
 @{Status='Installed';Mode='Failed';Managed=$null;Remove=$false},
 @{Status='Installed';Mode='Failed';Managed=$true;InstanceId='ROOT\FOREIGN\0000';Remove=$false},
 @{Status='Installed';Mode='Failed';Managed=$true;InstanceId='ROOT\KNOTVDD\0123456789abcdef0123456789abcdef';Remove=$false},
 @{Status='Absent';Mode='Failed';Managed=$false;Remove=$false;InstallEnabled=$true},
 @{Status='Absent';Mode='Timeout';Managed=$false;Remove=$false;InstallEnabled=$true},
 @{Status='Absent';Mode='Success';Managed=$false;Remove=$false;InstallEnabled=$false;ExpectedScans=0},
 @{Status='Absent';Mode='Success';Managed=$false;Remove=$false;InstallEnabled=$true;Install=$true},
 @{Status='Installed';Mode='Success';Managed=$true;Remove=$true},
 @{Status='Installed';Mode='Foreign';Managed=$true;Remove=$false},
 @{Status='RecoveryRequired';Mode='Foreign';Managed=$true;Remove=$false},
 @{Status='Installed';Mode='Missing';Managed=$true;Remove=$false},
 @{Status='RecoveryRequired';Mode='Missing';Managed=$true;Remove=$true}
)
foreach ($blockedStatus in @('Conflict','LegacyRecoveryRequired','Unsupported','BootEvidenceUnavailable','DeviceIdentityUnavailable','unknown','installed','')) {
 $probeCases+=@{Status=$blockedStatus;Mode='Failed';Managed=$true;Remove=$false;ExpectedScans=0}
}
$probeRoot=Join-Path ([IO.Path]::GetTempPath()) ('knot-headless-refresh-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($probeRoot)
try {
 $statusModule=Join-Path (Split-Path $PSScriptRoot -Parent) 'HeadlessStatus.psm1'
 $setupModule=Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupStatus.psm1'
 foreach ($case in $probeCases) {
  $id=$ownedId;if ($case.ContainsKey('InstanceId')) {$id=$case.InstanceId}
  $enabled=$false;if ($case.ContainsKey('InstallEnabled')) {$enabled=$case.InstallEnabled}
  $payload=[pscustomobject]@{Mode=$case.Mode;Enabled=$enabled;State=[pscustomobject]@{Status=$case.Status;Managed=$case.Managed;InstanceId=$id;RebootRequired=$false}}
  $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 4 -Compress)))
  $prefix=@'
$ErrorActionPreference='Stop'
$script:headlessFixture=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
Import-Module '__STATUS_MODULE__' -Force
Import-Module '__SETUP_MODULE__' -Force
$script:scan=$null;$script:canInstall=$false;$script:canRemove=$false;$script:headlessBusy=$false;$script:scanCalls=0
$status=[pscustomobject]@{Text=''}
function Invoke-InertHeadlessEvents {}
function New-InertHeadlessTimer {[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=16}}}
function Get-KnotHeadlessState {
 if ($script:headlessFixture.Mode -ceq 'StateFailed') {throw 'synthetic journal read failed'}
 $script:headlessFixture.State
}
function Get-KnotHeadlessAvailability {[pscustomobject]@{Enabled=$script:headlessFixture.Enabled;Reason='upstream-ipc-review'}}
function Initialize-KnotHeadlessNative {if ($script:headlessFixture.Mode -ceq 'InitializeFailed') {throw 'synthetic native initialization failed'}}
function Set-HeadlessBusy {param([bool]$Busy)}
function Get-InertHeadlessScan {
 $script:scanCalls++
 $scan=[pscustomobject]@{IsCompleted=($script:headlessFixture.Mode -cne 'Timeout')}
 $scan | Add-Member ScriptMethod GetAwaiter {return $this}
 $scan | Add-Member ScriptMethod GetResult {
  if ($script:headlessFixture.Mode -ceq 'Failed') {throw 'synthetic optional display scan failed'}
  $devices=@()
  if ($script:headlessFixture.Mode -ceq 'Foreign') {$devices=@([pscustomobject]@{InstanceId='ROOT\FOREIGN\0000'})}
  elseif ($script:headlessFixture.Mode -cne 'Missing' -and $script:headlessFixture.State.Status -cne 'Absent') {$devices=@([pscustomobject]@{InstanceId=$script:headlessFixture.State.InstanceId})}
  [pscustomobject]@{Devices=$devices;Displays=@()}
 }
 $scan
}
'@
  $prefix=$prefix.Replace('__PAYLOAD__',$encoded).Replace('__STATUS_MODULE__',$statusModule.Replace("'","''")).Replace('__SETUP_MODULE__',$setupModule.Replace("'","''"))
  $tail="Update-HeadlessState; [pscustomobject]@{canInstall=`$script:canInstall;canRemove=`$script:canRemove;scanCalls=`$script:scanCalls;text=`$status.Text} | ConvertTo-Json -Compress"
  $fixturePath=Join-Path $probeRoot ([guid]::NewGuid().ToString('N')+'.ps1')
  [IO.File]::WriteAllText($fixturePath,($prefix+[Environment]::NewLine+$refreshFixture+[Environment]::NewLine+$tail),(New-Object Text.UTF8Encoding($true)))
  $output=@(& $runner -NoLogo -NoProfile -NonInteractive -File $fixturePath)
  Check ($LASTEXITCODE -eq 0 -and $output.Count -eq 1) ('Inert actual refresh failed: '+$case.Status+'/'+$case.Mode)
  $actual=$output[0] | ConvertFrom-Json
  $install=$false;if ($case.ContainsKey('Install')) {$install=$case.Install}
  Check ($actual.canRemove -is [bool] -and $actual.canRemove -eq $case.Remove) ('Removal admission mismatch: '+$case.Status+'/'+$case.Mode)
  Check ($actual.canInstall -is [bool] -and $actual.canInstall -eq $install) ('Install must require a fresh successful scan: '+$case.Status+'/'+$case.Mode)
  if ($case.ContainsKey('ExpectedScans')) {Check ($actual.scanCalls -eq $case.ExpectedScans) ('A refused/policy-held state unexpectedly probed: '+$case.Status)}
  if ($case.Remove -and $case.Mode -cin @('Failed','Timeout','InitializeFailed')) {Check ($actual.text -match '관리자.*다시 검증') 'Probe failure with owned removal must explain the fresh elevated verification'}
 }
} finally {[IO.Directory]::Delete($probeRoot,$true)}

[pscustomobject]@{status='passed';checks=$count;freshSyntheticOnly=$true;nativeApisInvoked=$false;bootstrapPolicyComposed=[bool]$BootstrapPolicyRunner} | ConvertTo-Json -Compress
# Expected failing child fixtures must not become the successful checker's process status.
$global:LASTEXITCODE=0
