#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
# SPDX-License-Identifier: GPL-3.0-only
# Explicit UAC-owned reactivation of this helper's retained deployment, never adoption of another SSH server.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string] $ClientPublicKey,[Parameter(Mandatory=$true)][string[]] $AllowedClientAddress,
      [Parameter(Mandatory=$true)][string] $DesktopUserSid)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
$lifecycleLease=Enter-DeskBridgeLifecycleLease
try {
$key=Get-CanonicalPublicKey $ClientPublicKey
$desktopUser=Resolve-DesktopUser $DesktopUserSid
$addresses=@($AllowedClientAddress | ForEach-Object {Get-PrivateIPv4 $_})
if ($addresses.Count -lt 1 -or $addresses.Count -gt 8 -or @($addresses | Select-Object -Unique).Count -ne $addresses.Count) {throw 'Invalid Mac addresses'}
$deployment=Get-ManagedDeployment -WizardDefaults -DesktopUserSid $desktopUser.SID.Value
$state=$deployment.State; $record=$deployment.Record; $user=$deployment.User
$bin=$deployment.Bin; $sshd=$deployment.Sshd; $service=$deployment.Service
$template=$deployment.Template; $config=$deployment.Config; $keyPath=$deployment.KeyPath
$exists=$deployment.ConfigExists; $configMatches=$exists
$oldKey=Get-CanonicalPublicKey ([IO.File]::ReadAllText($keyPath).Trim())
# Validate an existing rule against its OWN prior address set before any stop or replacement.
# A requested address change is allowed; an altered/unknown rule is never adopted by name.
$priorRules=@(Get-NamedManagedFirewallRules PersistentStore)
$priorPolicy=Get-ManagedFirewallPolicy
if ($priorRules.Count -gt 1 -or $null -eq $priorPolicy -or -not $priorPolicy.PSObject.Properties['RuleCount'] -or
    $priorPolicy.RuleCount -ne $priorRules.Count) {throw 'The retained firewall rule cannot be verified. Review manually before reactivation.'}
$rule=$null
if ($priorRules.Count -eq 1) {
 if (-not $priorPolicy.PSObject.Properties['RemoteAddress'] -or
     -not (Test-ManagedFirewallPolicy $priorPolicy @($priorPolicy.RemoteAddress))) {
  throw 'The retained firewall rule differs from the managed policy. No service or rule was changed; review manually.'
 }
 $rule=$priorRules[0]
}
$addressMatch=Test-ManagedFirewallPolicy $priorPolicy $addresses
$action=Get-ManagedDeploymentAction -ConfigExists $exists -ConfigMatches $configMatches -ServiceRunning ($service.State -eq 'Running') -AccountEnabled $user.Enabled -KeyMatches ($oldKey -ceq $key) -AddressesMatch $addressMatch -Validated ($record.Phase -ceq 'Validated')
if ($action -eq 'Reuse') {return}
# A live ancestor proves ownership; stopped-service remnants require manual recovery.
Stop-ManagedSessionWorkers -BeforeStop {
 Disable-LocalUser -SID $user.SID
 Stop-Service -Name sshd
}
$resumeCreatedFirewall=@(); $resumeAccountEnableAttempted=$false
try {
 [IO.File]::WriteAllText($keyPath,$key + "`n",(New-Object Text.UTF8Encoding($false)))
 $keygen=Join-Path $bin 'ssh-keygen.exe'
 & $keygen -l -f $keyPath | Out-Null
 if ($LASTEXITCODE -ne 0) {throw 'The client public key is not accepted by OpenSSH'}
 & $keygen -A
 if ($LASTEXITCODE -ne 0) {throw 'Could not generate server host keys'}
 $sshDirectory=Split-Path $config -Parent
 Assert-ProtectedFile (Join-Path $sshDirectory 'ssh_host_ed25519_key.pub')
 Assert-PrivateHostKey (Join-Path $sshDirectory 'ssh_host_ed25519_key')
 Copy-Item -LiteralPath $template -Destination $config -Force
 Set-ManagedConfigAcl $config $user.SID $record.ConfigSha256
 Assert-ManagedConfig $config $record.ConfigSha256
 & $sshd -t -f $config
 if ($LASTEXITCODE -ne 0) {throw 'sshd rejected the restored configuration'}
 # Prepared records may come from failed first setup: validate policy again before any access.
 $rootForConfig=$record.ShareRoot.Replace('\','/')
 $keyForConfig=$keyPath.Replace('\','/')
 $effective=& $sshd -T -f $config -C "user=$($record.UserName),host=localhost,addr=127.0.0.1"
 if ($LASTEXITCODE -ne 0) {throw 'sshd could not evaluate the restored configuration'}
 $required=@('pubkeyauthentication yes','passwordauthentication no','authenticationmethods publickey',
     "allowusers $($record.UserName)",'disableforwarding yes','permittty no','forcecommand internal-sftp -d /files',
     "chrootdirectory $rootForConfig","authorizedkeysfile $keyForConfig")
 foreach ($setting in $required) {if (-not ($effective -contains $setting)) {throw "Effective SSH restriction did not validate: $setting"}}
 $record.Phase='Validated'
 Write-ManagedRecoveryRecord $state $record
 Assert-ProtectedDirectory (Split-Path $config -Parent)
 Assert-ManagedConfig $config $record.ConfigSha256
 $defaultRule=Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
 if ($defaultRule) {Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'}
 if ($rule) {Remove-NetFirewallRule -InputObject $rule}
 $resumeCreatedFirewall=@(New-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -DisplayName 'Knot SFTP from approved Mac addresses' -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $addresses -Action Allow -Profile Any)
 if ($resumeCreatedFirewall.Count -ne 1) {throw 'The new managed firewall rule could not be identified. Manual review is required.'}
 # A stopped service may retain Disabled startup. Permit this start without
 # leaving an automatic service behind if account enable/start fails.
 Set-Service -Name sshd -StartupType Manual
 $resumeAccountEnableAttempted=$true
 Enable-LocalUser -SID $user.SID
 Start-Service sshd
 Set-Service -Name sshd -StartupType Automatic
} catch {
 # Revoke future authentication and our rule even if ownership inspection must fail closed.
 if ($resumeAccountEnableAttempted) {Disable-LocalUser -SID $user.SID -ErrorAction SilentlyContinue}
 foreach ($createdRule in $resumeCreatedFirewall) {Remove-NetFirewallRule -InputObject $createdRule -ErrorAction SilentlyContinue}
 Stop-ManagedSessionWorkers -BeforeStop {Stop-Service -Name sshd}
 Set-Service -Name sshd -StartupType $record.StartupBefore -ErrorAction SilentlyContinue
 if (Test-Path -LiteralPath $config) {Move-Item -LiteralPath $config -Destination (Join-Path $state ('sshd_config.failed-' + [Guid]::NewGuid().ToString('N'))) }
 throw
}

} finally {$lifecycleLease.Dispose()}
