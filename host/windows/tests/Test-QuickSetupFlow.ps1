#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Execute the actual primary-action function with inert leaves. No GUI, sockets,
# SCM, installer, administrator token or user preference is accessed.
$ErrorActionPreference='Stop'
$folder=Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $folder 'Setup-DeskBridge.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) {throw 'Invalid setup syntax'}
$function=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-QuickSetup'},$true))
if ($function.Count -ne 1) {throw 'Expected actual primary action'}
Invoke-Expression ($function[0].Extent.Text.Replace('[Windows.Forms.Application]::DoEvents()','Invoke-InertEvents'))
$script:checks=0
function Expect([bool]$Condition,[string]$Message) {if (-not $Condition) {throw $Message};$script:checks++}
function Set-Busy([bool]$Busy) {$script:busy+=@($Busy)}
function Join-Path {param($Path,$ChildPath) return '/synthetic/installed.exe'}
function Test-Path {param($LiteralPath,$PathType) return $script:installed}
function Start-Sleep {param($Milliseconds)}
function Invoke-InertEvents {}
function Show-Failure {param($ErrorRecord) $status.Text='Fixed synthetic failure';$script:failed=$true}
function Get-Service {
    [CmdletBinding()]param($Name)
    Expect ($Name -ceq 'SunshineService') 'Must inspect only the fixed Sunshine service'
    if ($script:service -ceq 'present') {return [pscustomobject]@{Name='SunshineService'}}
    $category=if ($script:service -ceq 'missing') {[Management.Automation.ErrorCategory]::ObjectNotFound} else {[Management.Automation.ErrorCategory]::PermissionDenied}
    $record=[Management.Automation.ErrorRecord]::new([Exception]::new('synthetic SCM refusal'),'Synthetic',$category,$null)
    $PSCmdlet.ThrowTerminatingError($record)
}
function Invoke-SunshineLocalCheck {
    param($WaitMilliseconds)
    Expect ($WaitMilliseconds -eq 1000) 'Missing-install hint must use a bounded local check'
    $script:quickSetupPortResponded=$script:probe
}
function Start-Process {
    param($FilePath,$Verb,$ArgumentList,[switch]$PassThru)
    $script:starts++
    Expect ($FilePath -ceq '/synthetic/Knot.exe' -and $Verb -ceq 'RunAs' -and $PassThru) 'Only fixed native broker may cross UAC'
    Expect ($ArgumentList -ceq '--elevated-operation QuickSetupSunshine') 'No credential, URL, PIN or mutable result path may cross UAC'
    $process=[pscustomobject]@{Handle=1;HasExited=$true;ExitCode=$script:result}
    $process|Add-Member ScriptMethod WaitForExit {}
    return $process
}
foreach ($case in @('source','installed-ok','installed-cancel','installed-fail','installed-missing','custom-service','service-denied','custom-port','probe-unknown','fresh','fresh-fail')) {
    $LauncherPath=if ($case -ceq 'source') {''} else {'/synthetic/Knot.exe'}
    $form=[pscustomobject]@{IsDisposed=$false;Visible=$true}
    $form|Add-Member ScriptMethod Hide {$this.Visible=$false}
    $form|Add-Member ScriptMethod Show {$this.Visible=$true}
    $form|Add-Member ScriptMethod Activate {}
    $status=[pscustomobject]@{Text=''};$advancedPanel=[pscustomobject]@{Visible=$false}
    $script:busy=@();$script:starts=0;$script:installs=0;$script:failed=$false;$script:quickInstall=$false
    $script:installed=$case.StartsWith('installed')
    $script:service=if ($case -ceq 'custom-service') {'present'} elseif ($case -ceq 'service-denied') {'denied'} else {'missing'}
    $script:probe=if ($case -ceq 'probe-unknown') {$null} elseif ($case -ceq 'custom-port') {$true} else {$false}
    $script:result=if ($case -ceq 'installed-missing') {$null} elseif ($case -ceq 'installed-cancel') {1602} elseif ($case -ceq 'installed-fail') {2} else {0}
    $script:installAction={
        Expect $script:quickInstall 'Fresh install must choose combined install/native setup'
        $script:installs++
        if ($case -ceq 'fresh-fail') {throw 'synthetic installation failure'}
    }
    Invoke-QuickSetup
    Expect $form.Visible 'The single visible setup window must be restored after child exit or failure'
    Expect (-not $script:quickInstall) ('Combined-install admission must unwind: '+$case)
    if ($case -ceq 'source') {
        Expect ($script:busy.Count -eq 0 -and $advancedPanel.Visible) 'Developer source must show manual fallback without UAC'
    } else {
        Expect ($script:busy.Count -eq 2 -and $script:busy[0] -and -not $script:busy[1]) ('Busy lifetime must unwind: '+$case)
    }
    if ($case.StartsWith('installed')) {
        Expect ($script:starts -eq 1 -and $script:installs -eq 0) 'Existing standard installation must never reinstall'
    } elseif ($case.StartsWith('fresh')) {
        Expect ($script:starts -eq 0 -and $script:installs -eq 1) 'Fresh setup must use the single combined installer flow'
    } else {
        Expect ($script:starts -eq 0 -and $script:installs -eq 0) ('Ambiguous/custom/source setup must not mutate: '+$case)
    }
    if ($case -ceq 'installed-cancel') {Expect ($status.Text -match '유지') 'Cancel must retain completed configuration, not promise rollback'}
    if ($case -ceq 'installed-ok') {Expect ($status.Text -match '성공 여부는 Mac') 'Configured host must not imply a working stream'}
    if ($case -ceq 'installed-ok') {Expect ($status.Text.IndexOf('준비를 먼저') -ge 0 -and $status.Text.IndexOf('준비를 먼저') -lt $status.Text.IndexOf('Mac에서 PC 확인')) 'Windows preparation must precede creating the Mac pending PIN'}
    if ($case -ceq 'service-denied' -or $case -ceq 'fresh-fail' -or $case -ceq 'installed-missing') {Expect $script:failed 'Failure must be sanitized and stop automatic installation'}
}
# Execute the actual button wrapper after its creating function has returned.
# Only the two GUI object constructors are replaced with inert leaves.
$buttonFunction=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Add-Button'},$true))
if ($buttonFunction.Count -ne 1) {throw 'Expected actual button admission function'}
Invoke-Expression ($buttonFunction[0].Extent.Text.Replace('New-Object Drawing.Size(330,34)',"'synthetic-size'"))
function New-Object([string]$TypeName) {
    if ($TypeName -cne 'Windows.Forms.Button') {throw 'Unexpected synthetic constructor'}
    $value=[pscustomobject]@{Text='';Size=$null;Tag=$null;Handler=$null}
    $value|Add-Member ScriptMethod Add_Click {param($Handler) $this.Handler=$Handler}
    return $value
}
$script:section=[pscustomobject]@{Controls=[Collections.Generic.List[object]]::new()}
$form=[pscustomobject]@{UpdateCloseRequested=$false}
$script:buttonActions=0;$script:cancelDownload=$false
function Invoke-SyntheticButtonAction {$script:buttonActions++}
$normal=Add-Button 'synthetic action' {Invoke-SyntheticButtonAction}
$cancel=Add-Button 'synthetic cancel' {$script:cancelDownload=$true} -AllowDuringUpdate
& $normal.Handler $normal ([EventArgs]::Empty)
Expect ($script:buttonActions -eq 1) 'Returned action must resolve its original function/script scope'
$form.UpdateCloseRequested=$true
& $normal.Handler $normal ([EventArgs]::Empty)
Expect ($script:buttonActions -eq 1) 'Queued new action must be refused after update admission'
& $cancel.Handler $cancel ([EventArgs]::Empty)
Expect $script:cancelDownload 'Cleanup action must update the original cancellation flag'
$form.UpdateCloseRequested=$false
& $normal.Handler $normal ([EventArgs]::Empty)
Expect ($script:buttonActions -eq 2) 'Failed update cancellation must restore action admission'
@{status='passed';checks=$script:checks;actualPrimaryAction=$true;actualUpdateButtons=$true;freshSyntheticOnly=$true;network=$false;serviceAccess=$false;gui=$false} | ConvertTo-Json -Compress
