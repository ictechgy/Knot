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
    if ($case -ceq 'service-denied' -or $case -ceq 'fresh-fail' -or $case -ceq 'installed-missing') {Expect $script:failed 'Failure must be sanitized and stop automatic installation'}
}
@{status='passed';checks=$script:checks;actualPrimaryAction=$true;freshSyntheticOnly=$true;network=$false;serviceAccess=$false;gui=$false} | ConvertTo-Json -Compress
