#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Actual lifecycle policy/factory with inert callbacks or fresh GUID-only Windows mutexes.
# Never opens the production global name, CIM, services, firewall, accounts, UI or preferences.
$ErrorActionPreference='Stop'
$modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupContract.psm1'
Import-Module $modulePath -Force
$leaseChecks=0
function Expect-Lease([bool]$Condition,[string]$Message) {if (-not $Condition) {throw $Message};$script:leaseChecks++}
function Reject-Lease([scriptblock]$Body,[string]$Message) {$rejected=$false;try {& $Body | Out-Null} catch {$rejected=$true};Expect-Lease $rejected $Message}
$tokens=$null;$errors=$null
$moduleAst=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
$initializer=$moduleAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Initialize-DeskBridgeLifecycleLease'},$true)
$definition=$initializer.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuotedHereString'},$true).Value
if (-not ('DeskBridge.SFTPLifecycleLease' -as [type])) {Add-Type -TypeDefinition $definition -ErrorAction Stop}
$leaseType='DeskBridge.SFTPLifecycleLease' -as [type]
$trustedPolicy=$leaseType.GetMethod('TrustedPolicy',[Reflection.BindingFlags]'NonPublic,Static')
function Invoke-PolicyFixture([string]$Owner='S-1-5-32-544',[bool]$Protected=$true,[string[]]$Sids=@('S-1-5-18','S-1-5-32-544'),[int[]]$Masks=@(2031617,2031617),[int[]]$Flags=@(0,0),[bool[]]$Allows=@($true,$true)) {
 $values=New-Object object[] 6;$values[0]=$Owner;$values[1]=$Protected;$values[2]=$Sids;$values[3]=$Masks;$values[4]=$Flags;$values[5]=$Allows
 [bool]$trustedPolicy.Invoke($null,$values)
}
Expect-Lease (Invoke-PolicyFixture) 'Actual compiled policy accepts exactly protected SYSTEM/Administrators full access'
Expect-Lease (Invoke-PolicyFixture -Owner 'S-1-5-18' -Masks @(268435456,268435456)) 'Generic-all normalization and SYSTEM ownership remain trusted'
Expect-Lease (-not (Invoke-PolicyFixture -Owner 'S-1-5-21-111-222-333-1001')) 'Unknown mutex owner is rejected'
Expect-Lease (-not (Invoke-PolicyFixture -Protected $false)) 'Unprotected mutex DACL is rejected'
Expect-Lease (-not (Invoke-PolicyFixture -Sids @('S-1-5-18','S-1-1-0'))) 'An untrusted allow principal is rejected'
Expect-Lease (-not (Invoke-PolicyFixture -Sids @('S-1-5-18','S-1-5-18'))) 'Duplicate trusted SID cannot replace the other required principal'
Expect-Lease (-not (Invoke-PolicyFixture -Masks @(1048576,2031617))) 'Partial access is not adopted as the protected lifecycle mutex'
Expect-Lease (-not (Invoke-PolicyFixture -Flags @(16,0))) 'Inherited or propagation ACE flags are rejected'
Expect-Lease (-not (Invoke-PolicyFixture -Allows @($true,$false))) 'Deny/callback/nonplain ACEs are rejected'
Expect-Lease (-not (Invoke-PolicyFixture -Sids @('S-1-5-18','S-1-5-32-544','S-1-1-0') -Masks @(2031617,2031617,2031617) -Flags @(0,0,0) -Allows @($true,$true,$true))) 'Extra permissions are rejected'

# The actual public acquisition adapter accepts an explicit inert factory for source-only tests.
$ledger=[pscustomobject]@{Held=$false;Disposed=0;Calls=0}
$factory={
 $ledger.Calls++
 if ($ledger.Held) {throw 'synthetic busy'}
 $ledger.Held=$true
 $result=[pscustomobject]@{Ledger=$ledger;Closed=$false}
 $result | Add-Member ScriptMethod Dispose {if (-not $this.Closed) {$this.Closed=$true;$this.Ledger.Held=$false;$this.Ledger.Disposed++}}
 $result
}.GetNewClosure()
$first=Enter-DeskBridgeLifecycleLease -Acquire $factory
try {Reject-Lease {Enter-DeskBridgeLifecycleLease -Acquire $factory} 'Independent cooperating caller fails before entering held lifecycle work'} finally {$first.Dispose()}
Expect-Lease (-not $ledger.Held -and $ledger.Disposed -eq 1) 'The owning invocation releases its held lease'
try {$second=Enter-DeskBridgeLifecycleLease -Acquire $factory;try {throw 'synthetic body failure'} finally {$second.Dispose()}} catch {}
Expect-Lease (-not $ledger.Held -and $ledger.Disposed -eq 2) 'Error unwind releases the owning invocation lease'
Reject-Lease {Enter-DeskBridgeLifecycleLease -Acquire {throw 'synthetic untrusted mutex'}} 'Acquisition refusal never enters work'

Assert-NoOpenSSHWorkers -Inventory {}
Expect-Lease $true 'Fresh provisioning admits a successful empty worker inventory'
foreach ($name in @('sshd.exe','sshd-session.exe','sshd-auth.exe')) {
 Reject-Lease {Assert-NoOpenSSHWorkers -Inventory {[pscustomobject]@{Name=$name;ProcessId=123;ExecutablePath='C:\Windows\System32\OpenSSH\sshd.exe';CommandLine='-f alternate.conf -p 2222'}}} 'Any existing OpenSSH worker prevents fresh provisioning'
}
Reject-Lease {Assert-NoOpenSSHWorkers -Inventory {throw 'synthetic inventory failed'}} 'Failed worker inventory cannot authorize fresh provisioning'

# Execute the complete actual enabled scope after the already accepted Apply/
# ShouldProcess boundary. An inert key-validation barrier ensures that a broken
# admission guard cannot reach platform resources even in a failing fixture.
$enablePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Enable-DeskBridgeSFTP.ps1'
$enableAst=[Management.Automation.Language.Parser]::ParseFile($enablePath,[ref]$tokens,[ref]$errors)
$enableAcquire=@($enableAst.EndBlock.Statements | Where-Object {$_.Extent.Text -ceq '$lifecycleLease=Enter-DeskBridgeLifecycleLease'})
$enableScope=@($enableAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
Expect-Lease ($errors.Count -eq 0 -and $enableAcquire.Count -eq 1 -and $enableScope.Count -eq 1) 'Fresh setup fixture extracts the actual complete lease and enabled scope'
$enableBody=[scriptblock]::Create($enableAcquire[0].Extent.Text+[Environment]::NewLine+$enableScope[0].Extent.Text)
$actualAbsence=(Get-Command Assert-NoOpenSSHWorkers).ScriptBlock
$actualAdapter=(Get-Command Enter-DeskBridgeLifecycleLease).ScriptBlock
foreach ($inventory in @({[pscustomobject]@{Name='sshd.exe';ProcessId=200;CommandLine='-f alternate.conf -p 2222'}},{throw 'inert inventory unavailable'})) {
 $flow=[pscustomobject]@{Entered=0;Disposed=0;Boundary=0;Error=''}
 & {
  function Enter-DeskBridgeLifecycleLease {& $actualAdapter -Acquire {
   $flow.Entered++;$item=[pscustomobject]@{Flow=$flow};$item | Add-Member ScriptMethod Dispose {$this.Flow.Disposed++};$item
  }}
  function Assert-NoOpenSSHWorkers {& $actualAbsence -Inventory $inventory}
  function Get-CanonicalPublicKey {$flow.Boundary++;throw 'inert post-admission barrier; no resources available'}
  try {& $enableBody} catch {$flow.Error=$_.Exception.Message}
 }
 Expect-Lease ($flow.Error -like '*unproven deployment*' -or $flow.Error -ceq 'inert inventory unavailable') 'Actual initial setup refuses existing foreign workers or unknown inventory'
 Expect-Lease ($flow.Entered -eq 1 -and $flow.Disposed -eq 1 -and $flow.Boundary -eq 0) 'Initial setup refusal releases its lease before key validation, state creation or any account/firewall/service work'
}

# Source binding complements executable factory tests: every supported entry acquires
# before its first preflight, and its scope has one matching finally release.
$entryFirst=@{'Enable-DeskBridgeSFTP.ps1'='Assert-NoOpenSSHWorkers';'Resume-DeskBridgeSFTP.ps1'='Get-CanonicalPublicKey';'Disable-DeskBridgeSFTP.ps1'='Get-ManagedDeployment';'Invoke-DeskBridgeSetup.ps1'='Test-FileAccessInactive'}
foreach ($name in $entryFirst.Keys) {
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) $name),[ref]$tokens,[ref]$errors)
 $acquires=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Enter-DeskBridgeLifecycleLease'},$true))
 $preflight=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq $entryFirst[$name]},$true))
 $releases=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text.Contains('$lifecycleLease.Dispose()')},$true))
 Expect-Lease ($errors.Count -eq 0 -and $acquires.Count -eq 1 -and $preflight.Count -gt 0 -and $acquires[0].Extent.StartOffset -lt $preflight[0].Extent.StartOffset -and $releases.Count -eq 1) ('Lifecycle scope precedes preflight and releases through finally: '+$name)
}
$enable=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Enable-DeskBridgeSFTP.ps1'))
Expect-Lease ([regex]::Matches($enable,'(?m)^\s*Assert-NoOpenSSHWorkers\s*$').Count -eq 2 -and $enable.LastIndexOf('Assert-NoOpenSSHWorkers') -lt $enable.IndexOf('Enable-LocalUser -SID $user.SID')) 'Fresh provisioning rechecks worker absence before account/service activation'

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
 # Test-only native creator retains an UNOWNED handle so child-process exit cannot
 # erase an abandoned-mutex signal and falsely pass a missing-finally regression.
 Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class KnotSyntheticMutex {
 [StructLayout(LayoutKind.Sequential)] struct Attributes {public int Length;public IntPtr Descriptor;[MarshalAs(UnmanagedType.Bool)] public bool Inherit;}
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr descriptor,out uint size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeWaitHandle CreateMutexEx(ref Attributes attributes,string name,uint flags,uint access);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
 public static SafeWaitHandle Keep(string name,string sddl) {
  if (!System.Text.RegularExpressions.Regex.IsMatch(name,@"\AGlobal\\Knot\.SFTP\.Synthetic\.[0-9A-F]{32}\z")) throw new InvalidOperationException("Only a fresh synthetic namespace is allowed.");
  IntPtr descriptor=IntPtr.Zero;
  try {uint size;if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out descriptor,out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
   var attributes=new Attributes();attributes.Length=Marshal.SizeOf(typeof(Attributes));attributes.Descriptor=descriptor;
   var result=CreateMutexEx(ref attributes,name,0,0x001F0001);if(result.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());return result;
  } finally {if(descriptor!=IntPtr.Zero) LocalFree(descriptor);}
 }
}
'@
 $factoryMethod=$leaseType.GetMethod('AcquireName',[Reflection.BindingFlags]'NonPublic,Static')
 function Open-SyntheticLease([string]$Name) {
  if ($Name -cnotmatch '\AGlobal\\Knot\.SFTP\.Synthetic\.[0-9A-F]{32}\z') {throw 'Only a fresh synthetic lifecycle name is allowed'}
  $factoryMethod.Invoke($null,([object[]]@($Name)))
 }
 $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('knot-lifecycle-native-'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($testRoot)
 $hostProcess=[Diagnostics.Process]::GetCurrentProcess()
 try {$runner=$hostProcess.MainModule.FileName} finally {$hostProcess.Dispose()}
 $encodedDefinition=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($definition))
 $enterAst=$moduleAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Enter-DeskBridgeLifecycleLease'},$true)
 $adapter=$enterAst.Extent.Text.Replace('function Enter-DeskBridgeLifecycleLease','function Invoke-ExactLifecycleAdapter')
 function Invoke-LeaseChild([string]$Name,[string]$Body,[int]$ExpectedExit) {
  $path=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.ps1')
  $prefix=@'
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__DEFINITION__')))
$script:syntheticName='__NAME__'
$script:factory=('DeskBridge.SFTPLifecycleLease' -as [type]).GetMethod('AcquireName',[Reflection.BindingFlags]'NonPublic,Static')
__ADAPTER__
function Enter-DeskBridgeLifecycleLease {Invoke-ExactLifecycleAdapter -Acquire {$script:factory.Invoke($null,([object[]]@($script:syntheticName)))}}
'@
  $prefix=$prefix.Replace('__DEFINITION__',$encodedDefinition).Replace('__NAME__',$Name).Replace('__ADAPTER__',$adapter)
  [IO.File]::WriteAllText($path,($prefix+[Environment]::NewLine+$Body),(New-Object Text.UTF8Encoding($true)))
  $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$runner
  $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$path+'"'
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $child=New-Object Diagnostics.Process;$child.StartInfo=$start;$started=$false
  try {
   $started=$child.Start();if (-not $started) {throw 'Fresh lifecycle fixture child did not start'}
   if (-not $child.WaitForExit(15000)) {throw 'Fresh lifecycle fixture child timed out'}
   $stdout=$child.StandardOutput.ReadToEnd();$stderr=$child.StandardError.ReadToEnd()
   Expect-Lease ($child.ExitCode -eq $ExpectedExit) ('Fresh child lifecycle result: '+$child.ExitCode+' expected '+$ExpectedExit+' '+$stderr)
   return $stdout
  } finally {try {if($started -and -not $child.HasExited) {$child.Kill();[void]$child.WaitForExit(5000)}} finally {$child.Dispose()}}
 }
 $trusted='O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)'
 try {
  $name='Global\Knot.SFTP.Synthetic.'+[guid]::NewGuid().ToString('N').ToUpperInvariant()
  $keep=[KnotSyntheticMutex]::Keep($name,$trusted)
  try {
   $outer=Enter-DeskBridgeLifecycleLease -Acquire {Open-SyntheticLease $name}
   try {
    Import-Module $modulePath -Force
    $inner=Enter-DeskBridgeLifecycleLease -Acquire {Open-SyntheticLease $name}
    try {$null=Invoke-LeaseChild $name 'try {$lease=Enter-DeskBridgeLifecycleLease;try {exit 0} finally {$lease.Dispose()}} catch {exit 11}' 11} finally {$inner.Dispose()}
    $null=Invoke-LeaseChild $name 'try {$lease=Enter-DeskBridgeLifecycleLease;try {exit 0} finally {$lease.Dispose()}} catch {exit 11}' 11
   } finally {$outer.Dispose()}
   $outer.Dispose()
   $null=Invoke-LeaseChild $name '$lease=Enter-DeskBridgeLifecycleLease;try {exit 0} finally {$lease.Dispose()}' 0
   Expect-Lease $true 'Recursive acquisition survives Import-Force; releasing the inner scope preserves exclusion; Dispose is idempotent'
   try {$lease=Enter-DeskBridgeLifecycleLease -Acquire {Open-SyntheticLease $name};try {throw 'synthetic held body failure'} finally {$lease.Dispose()}} catch {}
   $afterError=Open-SyntheticLease $name;$afterError.Dispose()
   Expect-Lease $true 'Exception cleanup releases without abandoning the fresh kernel object'

   # Execute the actual broker success/exit/finally under a synthetic acquisition leaf.
   $brokerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-DeskBridgeSetup.ps1'),[ref]$tokens,[ref]$errors)
   $brokerHelper=@($brokerAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Write-SetupSuccessReceipt'})
   $brokerBody=@($brokerAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
   Expect-Lease ($errors.Count -eq 0 -and $brokerHelper.Count -eq 1 -and $brokerBody.Count -eq 1) 'Native exit fixture extracts actual broker helper and complete try/catch/finally'
   $body='$Operation="DisableFiles";$SuccessReceipt=$true;$NoPause=$true;$lifecycleLease=$null;function Test-FileAccessInactive {param($Projection) $true};function Get-FileAccessInactivityProjection {return $null};'+[Environment]::NewLine+$brokerHelper[0].Extent.Text+[Environment]::NewLine+$brokerBody[0].Extent.Text
   $null=Invoke-LeaseChild $name $body 0
   $afterExit=Open-SyntheticLease $name;$afterExit.Dispose()
   Expect-Lease $true 'Actual broker exit releases in finally; retained unowned handle would expose an abandonment otherwise'

   # The complete actual direct reactivation scope returns for a verified active
   # deployment or throws at its read-only inventory. Neither path reaches an OS
   # resource leaf. A nested native lease exposes an unbalanced direct finally.
   $resumeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Resume-DeskBridgeSFTP.ps1'),[ref]$tokens,[ref]$errors)
   $resumeAcquire=@($resumeAst.EndBlock.Statements | Where-Object {$_.Extent.Text -ceq '$lifecycleLease=Enter-DeskBridgeLifecycleLease'})
   $resumeScope=@($resumeAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
   Expect-Lease ($errors.Count -eq 0 -and $resumeAcquire.Count -eq 1 -and $resumeScope.Count -eq 1) 'Native direct fixture extracts the actual complete reactivation scope'
   $pureNames=@('Get-CanonicalPublicKey','Get-PrivateIPv4','Test-ManagedFirewallPolicy','Get-ManagedDeploymentAction')
   $pureDefinitions=@($moduleAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -cin $pureNames} | ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine
   $directPrelude=@'
$keyBytes=[byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)+([byte[]](1)*32)
$ClientPublicKey='ssh-ed25519 '+[Convert]::ToBase64String($keyBytes)
$AllowedClientAddress=@('192.168.1.10');$DesktopUserSid='S-1-5-21-111-222-333-1001'
$script:keyPath=Join-Path $PSScriptRoot 'fresh-authorized-keys'
[IO.File]::WriteAllText($script:keyPath,$ClientPublicKey)
function Resolve-DesktopUser {param($Sid) [pscustomobject]@{SID=[pscustomobject]@{Value=$Sid}}}
function Get-ManagedDeployment {
 param([switch]$WizardDefaults,$DesktopUserSid)
 if ($script:throwDeployment) {throw 'inert deployment refusal'}
 [pscustomobject]@{State=$PSScriptRoot;Record=[pscustomobject]@{Phase='Validated'};
  User=[pscustomobject]@{Enabled=$true};Service=[pscustomobject]@{State='Running'};
  KeyPath=$script:keyPath;ConfigExists=$true}
}
function Get-NamedManagedFirewallRules {param($PolicyStore) [pscustomobject]@{Name='DeskBridge-SFTP-In-TCP'}}
function Get-ManagedFirewallPolicy {
 [pscustomobject]@{RuleCount=1;AddressFilterCount=1;PortFilterCount=1;ApplicationFilterCount=1;ServiceFilterCount=1;
 InterfaceFilterCount=1;InterfaceTypeFilterCount=1;SecurityFilterCount=1;Name='DeskBridge-SFTP-In-TCP';Enabled='True';
 Direction='Inbound';Action='Allow';Profile='Any';LocalPort='22';RemotePort='Any';Protocol='TCP';RemoteAddress=@('192.168.1.10');
 LocalAddress='Any';Program='Any';Service='Any';InterfaceAlias='Any';InterfaceType='Any';EdgeTraversalPolicy='Block';
 Authentication='NotRequired';Encryption='NotRequired';LocalUser='Any';RemoteUser='Any';RemoteMachine='Any'}
}
function Stop-ManagedSessionWorkers {throw 'Unexpected mutation boundary in direct lifecycle fixture'}
'@
   $directBody=$resumeAcquire[0].Extent.Text+[Environment]::NewLine+$resumeScope[0].Extent.Text
   foreach ($throwDeployment in @($false,$true)) {
    $mode=if ($throwDeployment) {'$true'} else {'$false'}
    $body=$pureDefinitions+[Environment]::NewLine+$directPrelude+[Environment]::NewLine+
     '$script:throwDeployment='+$mode+';$outer=Enter-DeskBridgeLifecycleLease;$caught=$false;try {try {& {'+[Environment]::NewLine+$directBody+[Environment]::NewLine+
     '}} catch {if (-not $script:throwDeployment -or $_.Exception.Message -cne "inert deployment refusal") {throw};$caught=$true}} finally {$outer.Dispose()};if ($caught -ne $script:throwDeployment) {exit 12};exit 0'
    $null=Invoke-LeaseChild $name $body 0
    $afterDirect=Open-SyntheticLease $name;$afterDirect.Dispose()
    Expect-Lease $true 'Actual direct reactivation return/throw balances its nested native lease without abandonment'
   }
  } finally {$keep.Dispose()}
  foreach ($bad in @('O:BAG:BAD:(A;;GA;;;SY)(A;;GA;;;BA)','O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;WD)')) {
   $badName='Global\Knot.SFTP.Synthetic.'+[guid]::NewGuid().ToString('N').ToUpperInvariant()
   $badKeep=[KnotSyntheticMutex]::Keep($badName,$bad)
   try {Reject-Lease {Open-SyntheticLease $badName} 'Native factory rejects unprotected or untrusted synthetic ACL before work'} finally {$badKeep.Dispose()}
  }
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  try {$userSid=$identity.User.Value} finally {$identity.Dispose()}
  if ($userSid -notin @('S-1-5-18','S-1-5-32-544')) {
   $badName='Global\Knot.SFTP.Synthetic.'+[guid]::NewGuid().ToString('N').ToUpperInvariant()
   $badKeep=[KnotSyntheticMutex]::Keep($badName,('O:'+ $userSid+'G:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)'))
   try {Reject-Lease {Open-SyntheticLease $badName} 'Native factory rejects unknown synthetic owner even with trusted ACEs'} finally {$badKeep.Dispose()}
  }
  # Keep an unowned handle alive, then let a fresh child die while holding it.
  $abandonedName='Global\Knot.SFTP.Synthetic.'+[guid]::NewGuid().ToString('N').ToUpperInvariant()
  $abandonedKeep=[KnotSyntheticMutex]::Keep($abandonedName,$trusted)
  try {
   $null=Invoke-LeaseChild $abandonedName '$lease=Enter-DeskBridgeLifecycleLease;[Environment]::Exit(0)' 0
   Reject-Lease {Open-SyntheticLease $abandonedName} 'Abandoned synthetic lifecycle acquisition fails closed instead of entering work'
   $afterAbandon=Open-SyntheticLease $abandonedName;$afterAbandon.Dispose()
   Expect-Lease $true 'Abandoned rejection released its acquired ownership and closed its handle'
  } finally {$abandonedKeep.Dispose()}
 } finally {[IO.Directory]::Delete($testRoot,$true)}
 Write-Output 'Native lifecycle lease fixture: passed; fresh GUID-only Global objects, no production namespace or Windows resources'
} else {Write-Output 'Native lifecycle lease fixture: skipped (Windows APIs unavailable); actual definition compilation, actual pure policy and inert adapter passed'}
@{status='passed';checks=$leaseChecks;nativeFixtureWindows=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT);productionMutexOpened=$false;freshSyntheticOnly=$true} | ConvertTo-Json -Compress
