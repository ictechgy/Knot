#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([switch] $Apply)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
if (-not $Apply) { Write-Output 'Review mode: -Apply stops the dedicated sshd deployment, disables its account and firewall rule, and archives its SSH config. Shared files and host keys are retained.'; return }
if (-not $PSCmdlet.ShouldProcess('DeskBridge SFTP deployment', 'Disable remote file access; retain shared data')) { return }
$lifecycleLease=Enter-DeskBridgeLifecycleLease
try {
$deployment=Get-ManagedDeployment -Revoke
$state=$deployment.State; $record=$deployment.Record; $config=$deployment.Config
if (-not $deployment.ConfigExists) {
    if ($deployment.User.Enabled -or $deployment.Service.State -ne 'Stopped') { throw 'The retained deployment is not fully disabled. Review manually; no service/account changes were made.' }
}
# Prove the live service ancestry and hold process handles before changing access.
# A stopped service with unproven remnants requires manual recovery, never a name-based kill.
Stop-ManagedSessionWorkers -BeforeStop {
    if ($deployment.ConfigExists) {
        Disable-LocalUser -SID $deployment.User.SID
        Stop-Service -Name sshd
    }
}
Remove-ManagedFirewallAccess
if (-not $deployment.ConfigExists) {
    Set-Service -Name sshd -StartupType $record.StartupBefore
    Write-Output ('Knot access is already disabled. Verified retained metadata/account and confirmed no remaining OpenSSH workers. OpenSSH service is currently stopped; restored startup type: ' + $record.StartupBefore + '. The default OpenSSH firewall rule was not changed during this call.')
    return
}
Move-Item -LiteralPath $config -Destination (Join-Path $state ('sshd_config.disabled-' + (Get-Date -Format 'yyyyMMddTHHmmss'))) 
Set-Service -Name sshd -StartupType $record.StartupBefore
if ($record.DefaultRuleEnabled -eq 'True') { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' }
$defaultRuleNotice=if ($record.DefaultRuleEnabled -eq 'True') {'The previously enabled default OpenSSH firewall rule was re-enabled.'} else {'The default OpenSSH firewall rule was not re-enabled.'}
Write-Output ('Knot access disabled. Files, disabled account, host keys and archived configuration remain for review. OpenSSH optional feature remains installed. The service is currently stopped; restored startup type: ' + $record.StartupBefore + '. ' + $defaultRuleNotice + ' Review the retained service and firewall settings if OpenSSH is no longer needed.')

} finally {$lifecycleLease.Dispose()}
