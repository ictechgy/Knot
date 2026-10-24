#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Exact production wait logic with inert tasks; never create a socket, service or GUI.
$ErrorActionPreference='Stop'
$hostFolder=Split-Path $PSScriptRoot -Parent
$repository=Split-Path (Split-Path $hostFolder -Parent) -Parent
$tokens=$null; $errors=$null
$module=Join-Path $hostFolder 'SetupReadiness.psm1'
$ast=[Management.Automation.Language.Parser]::ParseFile($module,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) {throw 'Readiness module has parse errors'}
$source=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('internal static class LocalPortWait')},$true))
if ($source.Count -ne 1) {throw 'Expected exactly one actual local port implementation'}
$fixture=Get-Content -LiteralPath (Join-Path $repository 'scripts/tests/SetupReadinessChecks.cs') -Raw -Encoding UTF8
Add-Type -TypeDefinition ($source[0].Value + "`n" + $fixture)
$checks=[Knot.Setup.SetupReadinessChecks]::Run()
if ($checks -lt 35) {throw 'Incomplete readiness fixture result'}

# Compose the actual UI control flow with inert UI, browser and task leaves.
# Only DoEvents is replaced; no WinForms assembly or real browser is loaded.
$guiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $hostFolder 'Setup-DeskBridge.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) {throw 'Setup UI has parse errors'}
$function=@($guiAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-SunshineLocalCheck'},$true))
if ($function.Count -ne 1) {throw 'Expected exactly one actual local port UI handler'}
$body=$function[0].Extent.Text.Replace('[Windows.Forms.Application]::DoEvents()','Invoke-InertSetupEvents')
Invoke-Expression $body
Import-Module (Join-Path $hostFolder 'SetupStatus.psm1') -Force
function Expect-Readiness([bool] $Condition,[string] $Message) { if (-not $Condition) {throw $Message}; $script:checks++ }
function Set-Busy([bool] $Busy) { $script:busyEvents+=@($Busy) }
function Start-Sleep {param($Milliseconds)}
function Start-Process {param($FilePath) $script:opened+=@([string]$FilePath); if ($script:browserFails) {throw 'synthetic browser failure'} }
function Invoke-InertSetupEvents { if ($script:cancelOnPoll -and $script:probeCreated) {$script:cancelLocalCheck=$true} }
function Start-SetupLocalPortProbe {
    param($WaitMilliseconds)
    $script:probeCreated=$true; $script:budgets+=@($WaitMilliseconds)
    return $script:fakeProbe
}
foreach ($mode in @('ready-settings','ready-pin','ready-encryption','closed-settings','closed-pin','closed-encryption','status-only','cancel','browser-failure','browser-failure-encryption','probe-failure')) {
    $script:opened=@(); $script:busyEvents=@(); $script:budgets=@(); $script:probeCreated=$false
    $script:browserFails=$mode.StartsWith('browser-failure'); $script:cancelOnPoll=$mode -ceq 'cancel'
    $status=[pscustomobject]@{Text=''}; $localPortStatus=[pscustomobject]@{Text=''}
    $localCheckCancel=[pscustomobject]@{Visible=$false;Enabled=$false}
    $script:completion=[Threading.Tasks.TaskCompletionSource[bool]]::new()
    if ($mode -ceq 'probe-failure') { $script:completion.SetException([Exception]::new('synthetic probe failure')) }
    elseif ($mode -cne 'cancel') { $ready=-not $mode.StartsWith('closed'); $script:completion.SetResult($ready) }
    $script:fakeProbe=[pscustomobject]@{Completion=$script:completion.Task;CancelCalls=0;DisposeCalls=0}
    $script:fakeProbe | Add-Member ScriptMethod Cancel { $this.CancelCalls++; [void]$script:completion.TrySetCanceled() }
    $script:fakeProbe | Add-Member ScriptMethod Dispose { if (-not $this.Completion.IsCompleted) {throw 'premature disposal'}; $this.DisposeCalls++ }
    $open=if ($mode.EndsWith('pin')) {'PIN'} elseif ($mode.EndsWith('encryption')) {'Encryption'} elseif ($mode -ceq 'status-only') {'Status'} else {'Settings'}
    Invoke-SunshineLocalCheck -WaitMilliseconds 125 -Open $open
    Expect-Readiness ($script:busyEvents.Count -eq 2 -and $script:busyEvents[0] -and -not $script:busyEvents[1]) ('Busy state must unwind: '+$mode)
    Expect-Readiness ($script:fakeProbe.DisposeCalls -eq 1 -and $script:fakeProbe.CancelCalls -ge 1 -and -not $localCheckCancel.Visible) ('Owned operation must stop/dispose and hide cancel: '+$mode)
    Expect-Readiness ($script:budgets.Count -eq 1 -and $script:budgets[0] -eq 125) ('UI preserves bounded operation budget: '+$mode)
    if ($mode -eq 'ready-settings' -or $mode -eq 'browser-failure') { Expect-Readiness ($script:opened.Count -eq 1 -and $script:opened[0] -ceq 'https://localhost:47990/') 'Settings only opens the fixed local root URL' }
    elseif ($mode -eq 'ready-pin') { Expect-Readiness ($script:opened.Count -eq 1 -and $script:opened[0] -ceq 'https://localhost:47990/pin') 'PIN only opens the dedicated fixed local PIN URL' }
    elseif ($mode -eq 'ready-encryption' -or $mode -eq 'browser-failure-encryption') { Expect-Readiness ($script:opened.Count -eq 1 -and $script:opened[0] -ceq 'https://localhost:47990/config#lan_encryption_mode') 'Encryption only opens the fixed local encryption fragment' }
    else { Expect-Readiness ($script:opened.Count -eq 0) ('No premature browser launch: '+$mode) }
    if ($mode -eq 'cancel') { Expect-Readiness ($status.Text -match '취소') 'Explicit cancellation is presented as cancellation' }
    elseif ($mode.StartsWith('closed')) { Expect-Readiness ($status.Text -match '아직 응답하지 않습니다') 'Unavailable local port does not imply install or stream success' }
    elseif ($mode.StartsWith('browser-failure')) { Expect-Readiness ($status.Text -match '이 Windows.*localhost.*Mac') 'Browser failure gives the correct computer and fixed manual URL' }
    elseif ($mode -eq 'ready-encryption') { Expect-Readiness ($status.Text -match 'Required for all clients' -and $status.Text -match '모든 사용자에게 필수' -and $status.Text -notmatch 'Mandatory') 'Encryption guidance uses the actual pinned English and Korean option labels' }
}
Expect-Readiness ((Get-SunshineInstallResult 0).Text -match '아직 확인하지 않았습니다') 'Installer success is separate from runtime readiness'
Expect-Readiness ((Get-SunshineLocalPortText $true) -match '화면 연결 성공.*아닙니다') 'A TCP response is not authenticated Sunshine or streaming readiness'
@{status='passed';checks=$checks;freshSyntheticOnly=$true;networkUsed=$false;guiUsed=$false;servicesChanged=$false;actualWaitLogic=$true;actualUIFlow=$true} | ConvertTo-Json -Compress
