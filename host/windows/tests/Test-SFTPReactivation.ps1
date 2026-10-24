#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Fresh synthetic files plus injected PowerShell commands only. No service/firewall/account/native APIs.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupContract.psm1') -Force
$reactivationChecks=0
function Expect-Reactivation([bool] $Condition,[string] $Message) {
 if (-not $Condition) {throw $Message}; $script:reactivationChecks++
}
if (Get-Variable -Name KnotSyntheticReactivation,KnotSyntheticOwnershipStopScript -Scope Global -ErrorAction SilentlyContinue) {throw 'Synthetic fixture variable names must be unused'}
$global:KnotSyntheticOwnershipStopScript=(Get-Command Stop-ManagedSessionWorkers).ScriptBlock
$source=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Resume-DeskBridgeSFTP.ps1'))
# Retain the actual guards, transaction, try/catch and file writes. Only the platform
# requirements/module import and the four external OpenSSH process leaves are adapted.
Expect-Reactivation ([regex]::Matches($source,[regex]::Escape('& $keygen')).Count -eq 2 -and [regex]::Matches($source,[regex]::Escape('& $sshd')).Count -eq 2) 'Every external native process seam is explicitly enumerated'
$syntheticSource=[regex]::Replace($source,'(?m)^#Requires[^\r\n]*\r?\n','')
$syntheticSource=[regex]::Replace($syntheticSource,'(?m)^Import-Module[^\r\n]*\r?\n','')
$syntheticSource=$syntheticSource.Replace('& $keygen','Invoke-SyntheticKeygen').Replace('& $sshd','Invoke-SyntheticSshd')
$mocked=@('Enter-DeskBridgeLifecycleLease','Resolve-DesktopUser','Get-ManagedDeployment','Get-NamedManagedFirewallRules','Get-ManagedFirewallPolicy',
 'Get-NetFirewallRule','Remove-NetFirewallRule','New-NetFirewallRule','Disable-NetFirewallRule','Disable-LocalUser','Enable-LocalUser',
 'Stop-Service','Start-Service','Set-Service','Assert-ProtectedFile','Assert-PrivateHostKey','Set-ManagedConfigAcl',
 'Assert-ManagedConfig','Write-ManagedRecoveryRecord','Assert-ProtectedDirectory','Stop-ManagedSessionWorkers',
 'Invoke-SyntheticKeygen','Invoke-SyntheticSshd')
$savedFunctions=@{}
foreach ($name in $mocked) {
 $command=Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
 if ($command) {$savedFunctions[$name]=$command.ScriptBlock}
}
function New-ReactivationPolicy {
 [pscustomobject]@{RuleCount=1;AddressFilterCount=1;PortFilterCount=1;ApplicationFilterCount=1;ServiceFilterCount=1;
 InterfaceFilterCount=1;InterfaceTypeFilterCount=1;SecurityFilterCount=1;Name='DeskBridge-SFTP-In-TCP';Enabled='True';
 Direction='Inbound';Action='Allow';Profile='Any';LocalPort='22';RemotePort='Any';Protocol='TCP';RemoteAddress=@('192.168.1.10');
 LocalAddress='Any';Program='Any';Service='Any';InterfaceAlias='Any';InterfaceType='Any';EdgeTraversalPolicy='Block';
 Authentication='NotRequired';Encryption='NotRequired';LocalUser='Any';RemoteUser='Any';RemoteMachine='Any'}
}
function Invoke-ReactivationFixture([hashtable] $Case) {
 $temp=Join-Path ([IO.Path]::GetTempPath()) ('knot-reactivation-'+[guid]::NewGuid().ToString('N'))
 [IO.Directory]::CreateDirectory($temp) | Out-Null
 $prefix=[byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
 $publicKey='ssh-ed25519 '+[Convert]::ToBase64String([byte[]]($prefix+([byte[]](1)*32)))
 $keyPath=Join-Path $temp 'authorized_keys'; [IO.File]::WriteAllText($keyPath,$publicKey)
 $template=Join-Path $temp 'managed.conf'; [IO.File]::WriteAllText($template,'fresh synthetic configuration')
 $config=Join-Path $temp 'active.conf'; $fixture=Join-Path $temp 'Resume-Synthetic.ps1'
 [IO.File]::WriteAllText($fixture,$syntheticSource)
 $sid=[pscustomobject]@{Value='S-1-5-21-111-222-333-1001'}
 $record=[pscustomobject]@{Phase='Validated';UserName='deskbridge-transfer';ShareRoot=$temp;StartupBefore='Manual';ConfigSha256=('1'*64)}
 $oldRule=[pscustomobject]@{Name='DeskBridge-SFTP-In-TCP';Token='preexisting-rule'}
 $policy=New-ReactivationPolicy
 if ($Case.ContainsKey('Reuse')) {$policy.RemoteAddress=@('192.168.1.20')}
 if ($Case.ContainsKey('InvalidPolicy')) {$policy.Program='C:\foreign\ssh.exe'}
 if ($Case.ContainsKey('DuplicatePriorAddresses')) {$policy.RemoteAddress=@('192.168.1.10','192.168.1.10')}
 $global:KnotSyntheticReactivation=[pscustomobject]@{Case=$Case;Policy=$policy;PriorRule=$oldRule;CreatedRule=$null;Removed=@();
  NewAddresses=@();Disabled=0;Enabled=0;StopCalls=0;StartCalls=0;OwnershipCalls=0;Terminated=@();Released=0;
  LiveState='Stopped';LivePid=[uint32]0;Foreign=$false;Succeeded=$false;Error='';LeaseEntered=0;LeaseDisposed=0;
  Deployment=[pscustomobject]@{State=$temp;Record=$record;User=[pscustomobject]@{SID=$sid;Enabled=$false};Bin=$temp;
   Sshd=(Join-Path $temp 'sshd.exe');Service=[pscustomobject]@{State='Stopped'};Template=$template;Config=$config;KeyPath=$keyPath;ConfigExists=$false}}
 if ($Case.ContainsKey('Reuse')) {
  $global:KnotSyntheticReactivation.Deployment.ConfigExists=$true
  $global:KnotSyntheticReactivation.Deployment.Service.State='Running'
  $global:KnotSyntheticReactivation.Deployment.User.Enabled=$true
 }
 try {
  if ($Case.ContainsKey('EarlyKeyWriteFailure')) {(Get-Item -LiteralPath $keyPath).IsReadOnly=$true}
  & $fixture -ClientPublicKey $publicKey -AllowedClientAddress @('192.168.1.20') -DesktopUserSid $sid.Value | Out-Null
  $global:KnotSyntheticReactivation.Succeeded=$true
 } catch {$global:KnotSyntheticReactivation.Error=$_.Exception.Message}
 finally {
  (Get-Item -LiteralPath $keyPath -Force).IsReadOnly=$false
  [IO.Directory]::Delete($temp,$true)
 }
 return $global:KnotSyntheticReactivation
}
try {
 function global:Enter-DeskBridgeLifecycleLease {
  $global:KnotSyntheticReactivation.LeaseEntered++
  $lease=[pscustomobject]@{Disposed=$false;Fixture=$global:KnotSyntheticReactivation}
  $lease | Add-Member ScriptMethod Dispose {if (-not $this.Disposed) {$this.Disposed=$true;$this.Fixture.LeaseDisposed++}}
  $lease
 }
 function global:Resolve-DesktopUser {param($Sid) [pscustomobject]@{SID=[pscustomobject]@{Value=$Sid}}}
 function global:Get-ManagedDeployment {
  param([switch]$WizardDefaults,$DesktopUserSid)
  if ($global:KnotSyntheticReactivation.Case.ContainsKey('InventoryFailure')) {throw 'inert deployment inventory failed'}
  $global:KnotSyntheticReactivation.Deployment
 }
 function global:Get-NamedManagedFirewallRules {param($PolicyStore) $global:KnotSyntheticReactivation.PriorRule}
 function global:Get-ManagedFirewallPolicy {$global:KnotSyntheticReactivation.Policy}
 function global:Get-NetFirewallRule {param($Name,$ErrorAction) if ($Name -ne 'OpenSSH-Server-In-TCP') {throw 'Unexpected synthetic rule lookup'}}
 function global:Remove-NetFirewallRule {
  param($InputObject,$Name,$ErrorAction)
  if ($global:KnotSyntheticReactivation.Case.ContainsKey('EnableStartupCompensation') -and $Name -ceq 'DeskBridge-SFTP-In-TCP') {
   $global:KnotSyntheticReactivation.Removed+=@($global:KnotSyntheticReactivation.CreatedRule);return
  }
  if ($Name -or $null -eq $InputObject) {throw 'Firewall rollback/replacement used a name instead of the captured object'}
  $global:KnotSyntheticReactivation.Removed+=@($InputObject)
 }
 function global:New-NetFirewallRule {
  param($Name,$DisplayName,$Direction,$Protocol,$LocalPort,$RemoteAddress,$Action,$Profile)
  $global:KnotSyntheticReactivation.NewAddresses=@($RemoteAddress)
  $created=[pscustomobject]@{Name=$Name;Token=('created-'+[guid]::NewGuid().ToString('N'))}
  $global:KnotSyntheticReactivation.CreatedRule=$created; $created
 }
 function global:Disable-NetFirewallRule {throw 'No default rule exists in this synthetic fixture'}
 function global:Disable-LocalUser {
  param($SID,$ErrorAction)
  if ($SID.Value -cne $global:KnotSyntheticReactivation.Deployment.User.SID.Value) {throw 'Wrong synthetic account SID'}
  $global:KnotSyntheticReactivation.Disabled++
 }
 function global:Enable-LocalUser {param($SID) $global:KnotSyntheticReactivation.Enabled++}
 function global:Stop-Service {
  param($Name,$ErrorAction)
  if ($Name -cne 'sshd') {throw 'Unexpected synthetic service'}
  $global:KnotSyntheticReactivation.StopCalls++;$global:KnotSyntheticReactivation.LiveState='Stopped';$global:KnotSyntheticReactivation.LivePid=[uint32]0
 }
 function global:Start-Service {
  param($Name)
  $global:KnotSyntheticReactivation.StartCalls++;$global:KnotSyntheticReactivation.LiveState='Running';$global:KnotSyntheticReactivation.LivePid=[uint32]100
  if ($global:KnotSyntheticReactivation.Case.ContainsKey('StartupFailureForeignWorker')) {
   $global:KnotSyntheticReactivation.Foreign=$true;throw 'synthetic startup failure after account/rule enable'
  }
 }
 function global:Set-Service {param($Name,$StartupType,$ErrorAction)}
 function global:Assert-ProtectedFile {param($Path)}
 function global:Assert-PrivateHostKey {param($Path)}
 function global:Set-ManagedConfigAcl {param($Path,$SID,$Sha256)}
 function global:Assert-ManagedConfig {param($Path,$Sha256)}
 function global:Write-ManagedRecoveryRecord {param($State,$Record)}
 function global:Assert-ProtectedDirectory {param($Path)}
 function global:Invoke-SyntheticKeygen {$global:LASTEXITCODE=0}
 function global:Invoke-SyntheticSshd {
  $global:LASTEXITCODE=0
  if ($args -ccontains '-T') {
   $d=$global:KnotSyntheticReactivation.Deployment
   @('pubkeyauthentication yes','passwordauthentication no','authenticationmethods publickey',
    ('allowusers '+$d.Record.UserName),'disableforwarding yes','permittty no','forcecommand internal-sftp -d /files',
    ('chrootdirectory '+$d.Record.ShareRoot.Replace('\','/')),('authorizedkeysfile '+$d.KeyPath.Replace('\','/')))
  }
 }
 function global:Stop-ManagedSessionWorkers {
  param([scriptblock]$BeforeStop)
  $global:KnotSyntheticReactivation.OwnershipCalls++
  & $global:KnotSyntheticOwnershipStopScript -BeforeStop $BeforeStop -WindowsDirectory 'C:\Windows' -ServiceInventory {
   [pscustomobject]@{Name='sshd';State=$global:KnotSyntheticReactivation.LiveState;ProcessId=$global:KnotSyntheticReactivation.LivePid;PathName='C:\Windows\System32\OpenSSH\sshd.exe'}
  } -Inventory {
   if ($global:KnotSyntheticReactivation.LiveState -ceq 'Running') {
    [pscustomobject]@{Name='sshd.exe';ExecutablePath='C:\Windows\System32\OpenSSH\sshd.exe';ProcessId=[uint32]100;Parent=[uint32]4;Created=[long]1000}
   }
   if ($global:KnotSyntheticReactivation.Foreign) {
    [pscustomobject]@{Name='sshd.exe';ExecutablePath='C:\Windows\System32\OpenSSH\sshd.exe';ProcessId=[uint32]200;Parent=[uint32]44;Created=[long]2000}
   }
  } -Capture {
   param($worker)
   [pscustomobject]@{ProcessId=$worker.ProcessId;ParentProcessId=$worker.Parent;CreatedFileTime=$worker.Created;ExecutablePath=$worker.ExecutablePath;Alive=$true}
  } -Terminate {param($identity) $global:KnotSyntheticReactivation.Terminated+=@($identity.ProcessId)} -Release {param($identity) $global:KnotSyntheticReactivation.Released++}
 }
 $reuse=Invoke-ReactivationFixture @{Reuse=$true}
 Expect-Reactivation ($reuse.Succeeded -and $reuse.OwnershipCalls -eq 0 -and $reuse.StopCalls -eq 0 -and $reuse.Removed.Count -eq 0) 'Actual direct reactivation returns without mutation for its verified active deployment'
 Expect-Reactivation ($reuse.LeaseEntered -eq 1 -and $reuse.LeaseDisposed -eq 1) 'Actual direct return releases its invocation-owned lifecycle lease'
 $inventoryFailure=Invoke-ReactivationFixture @{InventoryFailure=$true}
 Expect-Reactivation (-not $inventoryFailure.Succeeded -and $inventoryFailure.Error -ceq 'inert deployment inventory failed' -and $inventoryFailure.OwnershipCalls -eq 0) 'Actual direct preflight failure refuses before service or worker operations'
 Expect-Reactivation ($inventoryFailure.LeaseEntered -eq 1 -and $inventoryFailure.LeaseDisposed -eq 1) 'Actual direct throw releases its invocation-owned lifecycle lease'
 $invalid=Invoke-ReactivationFixture @{InvalidPolicy=$true;EarlyKeyWriteFailure=$true}
 Expect-Reactivation (-not $invalid.Succeeded -and $invalid.Error -like '*retained firewall rule differs*') 'An unrelated same-name policy is rejected before reactivation reaches a configured key-write failure'
 Expect-Reactivation ($invalid.OwnershipCalls -eq 0 -and $invalid.StopCalls -eq 0 -and $invalid.Disabled -eq 0 -and $invalid.Removed.Count -eq 0) 'An altered prior rule is preserved before any service/account/rule mutation'
 $duplicate=Invoke-ReactivationFixture @{DuplicatePriorAddresses=$true}
 Expect-Reactivation (-not $duplicate.Succeeded -and $duplicate.OwnershipCalls -eq 0 -and $duplicate.Removed.Count -eq 0) 'Duplicate prior client addresses cannot authorize rule replacement'
 $early=Invoke-ReactivationFixture @{EarlyKeyWriteFailure=$true}
 Expect-Reactivation (-not $early.Succeeded -and $early.OwnershipCalls -eq 2 -and $early.StartCalls -eq 0) 'The actual key write fails inside reactivation before account activation'
 Expect-Reactivation ($early.Removed.Count -eq 0 -and $null -eq $early.CreatedRule) 'Early key-write failure preserves the prior rule without name-based rollback'
 $success=Invoke-ReactivationFixture @{}
 Expect-Reactivation ($success.Succeeded -and $success.StartCalls -eq 1 -and $success.NewAddresses.Count -eq 1 -and $success.NewAddresses[0] -ceq '192.168.1.20') 'A fully valid prior policy may change its approved address set'
 Expect-Reactivation ($success.Removed.Count -eq 1 -and [object]::ReferenceEquals($success.Removed[0],$success.PriorRule)) 'Normal replacement removes exactly the validated prior rule object'
 $failure=Invoke-ReactivationFixture @{StartupFailureForeignWorker=$true}
 Expect-Reactivation (-not $failure.Succeeded -and $failure.Error -like '*managed service ancestry*') 'Startup rollback surfaces unproven foreign worker ownership instead of claiming inactivity'
 Expect-Reactivation ($failure.Enabled -eq 1 -and $failure.Disabled -eq 2) 'A failed startup revokes its verified enabled account even when service ownership becomes ambiguous'
 Expect-Reactivation ($failure.Removed.Count -eq 2 -and [object]::ReferenceEquals($failure.Removed[1],$failure.CreatedRule) -and -not [object]::ReferenceEquals($failure.Removed[1],$failure.PriorRule)) 'Startup compensation revokes only the exact fresh rule object'
 Expect-Reactivation ($failure.StopCalls -eq 1 -and $failure.Terminated.Count -eq 0 -and $failure.Released -eq 2) 'Foreign daemon startup failure never invokes an additional service stop or any worker termination and releases both handles'
 # Execute the actual initial-setup compensation catch with only its created-resource
 # flags set and an ambiguous newly observed daemon. Never execute initial setup itself.
 $enablePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Enable-DeskBridgeSFTP.ps1'
 $tokens=$null;$errors=$null
 $enableAst=[Management.Automation.Language.Parser]::ParseFile($enablePath,[ref]$tokens,[ref]$errors)
 $startupCatch=@($enableAst.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Body.Extent.Text.Contains('if ($createdFirewall)') -and $node.Body.Extent.Text.Contains('if (-not $recordCommitted)')},$true))
 Expect-Reactivation ($errors.Count -eq 0 -and $startupCatch.Count -eq 1) 'Initial setup compensation is extracted from its actual unmodified catch body'
 $catchText=$startupCatch[0].Body.Extent.Text
 $catchBlock=[scriptblock]::Create($catchText.Substring(1,$catchText.Length-2))
 $catchRoot=Join-Path ([IO.Path]::GetTempPath()) ('knot-enable-catch-'+[guid]::NewGuid().ToString('N'))
 [IO.Directory]::CreateDirectory($catchRoot) | Out-Null
 try {
  $config=Join-Path $catchRoot 'owned-active.conf';[IO.File]::WriteAllText($config,'fresh synthetic owned config')
  $createdFirewall=$true;$createdUser=$true;$startedService=$true;$wroteConfig=$true;$recordCommitted=$true
  $rollback=[pscustomobject]@{ConfigSha256=('1'*64)};$startupBefore='Manual';$defaultRuleEnabled=$null
  $user=$failure.Deployment.User
  $global:KnotSyntheticReactivation.Case=@{EnableStartupCompensation=$true}
  $global:KnotSyntheticReactivation.Disabled=0;$global:KnotSyntheticReactivation.Removed=@()
  $global:KnotSyntheticReactivation.StopCalls=0;$global:KnotSyntheticReactivation.Terminated=@();$global:KnotSyntheticReactivation.Released=0
  $caught=''
  try {& $catchBlock} catch {$caught=$_.Exception.Message}
  Expect-Reactivation ($caught -like '*managed service ancestry*') 'Initial setup compensation preserves an ambiguous worker error instead of claiming inactivity'
  Expect-Reactivation ($global:KnotSyntheticReactivation.Disabled -eq 1 -and $global:KnotSyntheticReactivation.Removed.Count -eq 1) 'Initial setup failure may revoke only its separately tracked created account/rule resources'
  Expect-Reactivation ($global:KnotSyntheticReactivation.StopCalls -eq 0 -and $global:KnotSyntheticReactivation.Terminated.Count -eq 0 -and $global:KnotSyntheticReactivation.Released -eq 2 -and [IO.File]::Exists($config)) 'Initial setup failure does not stop an unproven daemon or archive configuration after ownership refusal'
 } finally {[IO.Directory]::Delete($catchRoot,$true)}
} finally {
 foreach ($name in $mocked) {
  Remove-Item -LiteralPath ('Function:global:'+$name) -ErrorAction SilentlyContinue
  if ($savedFunctions.ContainsKey($name)) {Set-Item -LiteralPath ('Function:global:'+$name) -Value $savedFunctions[$name]}
 }
}
Remove-Variable -Name KnotSyntheticReactivation,KnotSyntheticOwnershipStopScript -Scope Global -ErrorAction SilentlyContinue
@{status='passed';checks=$reactivationChecks;scope='actual reactivation control flow with four native leaves and Windows resource commands replaced by inert callbacks; fresh synthetic files only'} | ConvertTo-Json -Compress
