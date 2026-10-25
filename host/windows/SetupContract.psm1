# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version Latest
function Get-CanonicalPublicKey([string] $Key) {
    if ($Key.Length -gt 4096 -or $Key -match '[\r\n\x00]') { throw 'Supply one Ed25519 public key, never a private key.' }
    $parts = $Key.Trim() -split ' +'
    if ($parts.Count -lt 2 -or $parts[0] -cne 'ssh-ed25519') { throw 'An Ed25519 public key is required.' }
    try { $blob = [Convert]::FromBase64String($parts[1]) } catch { throw 'Invalid public key.' }
    $prefix = [byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
    if ($blob.Length -ne 51) { throw 'Invalid Ed25519 key length.' }
    for ($i=0; $i -lt $prefix.Length; $i++) { if ($blob[$i] -ne $prefix[$i]) { throw 'Invalid Ed25519 key structure.' } }
    return 'ssh-ed25519 ' + [Convert]::ToBase64String($blob)
}
function Get-KeyFingerprint([string] $Key) {
    $canonical = Get-CanonicalPublicKey $Key
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return 'SHA256:' + [Convert]::ToBase64String($hash.ComputeHash([Convert]::FromBase64String(($canonical -split ' ')[1]))).TrimEnd('=') }
    finally { $hash.Dispose() }
}
function Get-PrivateIPv4([string] $Address) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsed.ToString() -cne $Address) { throw 'Use a literal LAN or Tailscale IPv4 address.' }
    $b = $parsed.GetAddressBytes()
    if (-not ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or ($b[0] -eq 169 -and $b[1] -eq 254))) { throw 'Public, loopback and broad-range addresses are not allowed.' }
    return $Address
}
function ConvertFrom-MacSetup([string] $Text) {
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 16384) { throw 'Setup file is too large.' }
    $r = $Text | ConvertFrom-Json -ErrorAction Stop
    $expected = @('allowedClientAddresses','clientPublicKey','kind','requestID','version')
    if (@(Compare-Object -CaseSensitive @($r.PSObject.Properties.Name | Sort-Object) $expected).Count -ne 0) { throw 'Unexpected setup file fields.' }
    $id = [Guid]::Empty
    if ($r.kind -cne 'deskbridge.mac-setup' -or -not ($r.version -is [int] -or $r.version -is [long]) -or $r.version -ne 1 -or -not [Guid]::TryParseExact([string]$r.requestID,'D',[ref]$id)) { throw 'Unsupported setup file version or identity.' }
    if ($r.allowedClientAddresses -isnot [Array] -or $r.allowedClientAddresses.Count -lt 1 -or $r.allowedClientAddresses.Count -gt 8) { throw 'Choose one to eight Mac addresses.' }
    $addresses = @($r.allowedClientAddresses | ForEach-Object { Get-PrivateIPv4 $_ })
    if (@($addresses | Select-Object -Unique).Count -ne $addresses.Count) { throw 'Duplicate Mac addresses.' }
    $r.clientPublicKey = Get-CanonicalPublicKey $r.clientPublicKey
    $r.allowedClientAddresses = $addresses
    return $r
}
function Read-MacSetup([string] $Path) {
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 16384 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Choose a small ordinary setup JSON file.' }
    return ConvertFrom-MacSetup ([IO.File]::ReadAllText($file.FullName))
}
function Test-ManagedFirewallPolicy([object] $Policy,[string[]] $AllowedClientAddress) {
    # Pure projection validator. No firewall lookup or policy mutation occurs here.
    if (-not $Policy -or $AllowedClientAddress.Count -lt 1 -or $AllowedClientAddress.Count -gt 8) { return $false }
    foreach ($name in @('RuleCount','AddressFilterCount','PortFilterCount','ApplicationFilterCount','ServiceFilterCount','InterfaceFilterCount','InterfaceTypeFilterCount','SecurityFilterCount')) {
        if (-not $Policy.PSObject.Properties[$name] -or $Policy.$name -ne 1) { return $false }
    }
    foreach ($entry in @(@('Name','DeskBridge-SFTP-In-TCP'),@('Enabled','True'),@('Direction','Inbound'),@('Action','Allow'),
        @('Profile','Any'),@('LocalPort','22'),@('RemotePort','Any'),@('LocalAddress','Any'),@('Program','Any'),
        @('Service','Any'),@('InterfaceAlias','Any'),@('InterfaceType','Any'),@('EdgeTraversalPolicy','Block'),
        @('Authentication','NotRequired'),@('Encryption','NotRequired'),@('LocalUser','Any'),@('RemoteUser','Any'),@('RemoteMachine','Any'))) {
        $name=$entry[0]
        if (-not $Policy.PSObject.Properties[$name] -or @($Policy.$name).Count -ne 1 -or [string]$Policy.$name -ine $entry[1]) { return $false }
    }
    if (-not $Policy.PSObject.Properties['Protocol'] -or [string]$Policy.Protocol -notin @('TCP','6') -or
        -not $Policy.PSObject.Properties['RemoteAddress']) { return $false }
    try {
        $expected=@($AllowedClientAddress | ForEach-Object { Get-PrivateIPv4 $_ } | Sort-Object)
        $actual=@($Policy.RemoteAddress | ForEach-Object { Get-PrivateIPv4 ([string]$_) } | Sort-Object)
    } catch { return $false } # Malformed address data is a policy mismatch, never a trusted rule.
    return $expected.Count -eq @($expected | Select-Object -Unique).Count -and $actual.Count -eq $expected.Count -and
        @((Compare-Object $actual $expected)).Count -eq 0
}
function Get-ManagedFirewallPolicy {
    # Only the helper-owned rule is inspected. Other machine/GPO policies are not adopted.
    $rules=@(Get-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -ErrorAction SilentlyContinue)
    if ($rules.Count -ne 1) { return [pscustomobject]@{RuleCount=$rules.Count} }
    $a=@($rules | Get-NetFirewallAddressFilter); $p=@($rules | Get-NetFirewallPortFilter)
    $app=@($rules | Get-NetFirewallApplicationFilter); $svc=@($rules | Get-NetFirewallServiceFilter)
    $iface=@($rules | Get-NetFirewallInterfaceFilter); $kind=@($rules | Get-NetFirewallInterfaceTypeFilter)
    $security=@($rules | Get-NetFirewallSecurityFilter)
    foreach ($count in @($a.Count,$p.Count,$app.Count,$svc.Count,$iface.Count,$kind.Count,$security.Count)) {
        if ($count -ne 1) { return [pscustomobject]@{RuleCount=0} }
    }
    return [pscustomobject]@{
        RuleCount=1;AddressFilterCount=$a.Count;PortFilterCount=$p.Count;ApplicationFilterCount=$app.Count
        ServiceFilterCount=$svc.Count;InterfaceFilterCount=$iface.Count;InterfaceTypeFilterCount=$kind.Count;SecurityFilterCount=$security.Count
        Name=$rules[0].Name;Enabled=[string]$rules[0].Enabled;Direction=[string]$rules[0].Direction;Action=[string]$rules[0].Action
        Profile=[string]$rules[0].Profile;EdgeTraversalPolicy=[string]$rules[0].EdgeTraversalPolicy
        LocalAddress=$a[0].LocalAddress;RemoteAddress=$a[0].RemoteAddress;Protocol=[string]$p[0].Protocol
        LocalPort=$p[0].LocalPort;RemotePort=$p[0].RemotePort;Program=$app[0].Program;Service=$svc[0].Service
        InterfaceAlias=$iface[0].InterfaceAlias;InterfaceType=[string]$kind[0].InterfaceType
        Authentication=[string]$security[0].Authentication;Encryption=[string]$security[0].Encryption
        LocalUser=$security[0].LocalUser;RemoteUser=$security[0].RemoteUser;RemoteMachine=$security[0].RemoteMachine
    }
}
function Get-ManagedDeploymentAction([bool] $ConfigExists,[bool] $ConfigMatches,[bool] $ServiceRunning,[bool] $AccountEnabled,[bool] $KeyMatches,[bool] $AddressesMatch,[bool] $Validated=$true) {
    if ($ConfigExists -and -not $ConfigMatches) { throw 'SSH configuration was changed; manual integration is required.' }
    if (-not $ServiceRunning) { return 'Reactivate' }
    if (-not $Validated) { throw 'An unvalidated deployment is unexpectedly running. Stop and review it manually.' }
    if ($ConfigExists -and $ConfigMatches -and $AccountEnabled -and $KeyMatches -and $AddressesMatch) { return 'Reuse' }
    throw 'An active deployment differs. Revoke file access first, then configure the new Mac key or addresses.'
}
function Test-FileAccessInactive([object] $Projection) {
    # Pure fail-closed validator; these projections never authorize mutation or adopt retained metadata.
    if (-not $Projection) { return $false }
    foreach ($name in @('InspectionSucceeded','ConfigState','FirewallRuleCount','AccountCount','AccountState','ServiceCount','ServiceState','WorkerCount')) {
        if (-not $Projection.PSObject.Properties[$name]) { return $false }
    }
    if ($Projection.InspectionSucceeded -isnot [bool] -or -not $Projection.InspectionSucceeded -or
        $Projection.ConfigState -isnot [string] -or $Projection.ConfigState -cne 'Absent') { return $false }
    foreach ($name in @('FirewallRuleCount','AccountCount','ServiceCount','WorkerCount')) {
        if (-not ($Projection.$name -is [int] -or $Projection.$name -is [long]) -or $Projection.$name -lt 0) { return $false }
    }
    if ($Projection.FirewallRuleCount -ne 0 -or $Projection.WorkerCount -ne 0) { return $false }
    if ($Projection.AccountState -isnot [string] -or $Projection.ServiceState -isnot [string]) { return $false }
    $accountInactive=($Projection.AccountCount -eq 0 -and $Projection.AccountState -ceq 'Missing') -or
        ($Projection.AccountCount -eq 1 -and $Projection.AccountState -ceq 'Disabled')
    $serviceInactive=($Projection.ServiceCount -eq 0 -and $Projection.ServiceState -ceq 'Missing') -or
        ($Projection.ServiceCount -eq 1 -and $Projection.ServiceState -ceq 'Stopped')
    return $accountInactive -and $serviceInactive
}
function Test-SystemOpenSSHWorkerPath([object] $Worker,[string] $WindowsDirectory) {
    # Pure exact-path classification. A same-named worker outside the OS OpenSSH directory is unknown, never absent.
    if (-not $Worker -or -not $Worker.PSObject.Properties['Name'] -or -not $Worker.PSObject.Properties['ExecutablePath'] -or
        $Worker.Name -isnot [string] -or $Worker.Name -notin @('sshd.exe','sshd-session.exe','sshd-auth.exe') -or
        $Worker.ExecutablePath -isnot [string] -or $Worker.ExecutablePath.Length -gt 1024 -or
        $WindowsDirectory -notmatch '^[A-Za-z]:\\[^\\/:*?"<>|\x00-\x1f]+(?:\\[^\\/:*?"<>|\x00-\x1f]+)*$' -or
        $WindowsDirectory -match '(?:^|\\)\.{1,2}(?:\\|$)|[ .](?:\\|$)') { return $false }
    $expected=$WindowsDirectory+'\System32\OpenSSH\'+$Worker.Name
    return [string]::Equals($Worker.ExecutablePath,$expected,[StringComparison]::OrdinalIgnoreCase)
}
function Invoke-ProtectedCompilation([string] $TypeDefinition) {
    $compilerParent=[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if ($compilerParent -notmatch '^[A-Za-z]:\\') { throw 'A fixed local Program Files directory is required for compilation.' }
    $parent=[IO.DirectoryInfo]$compilerParent
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $danger=[int][Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor 1073741824 -bor 268435456
    while ($parent) {
        Assert-NoReparsePath $parent.FullName
        $parentAcl=Get-Acl -LiteralPath $parent.FullName
        if ($parentAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Compiler path ancestors must be administrator-owned.' }
        foreach ($rule in $parentAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -notin $trusted -and (([int]$rule.FileSystemRights) -band $danger)) { throw 'Compiler path ancestors must not permit untrusted rename or permission changes.' }
        }
        $parent=$parent.Parent
    }
    Assert-ProtectedDirectory $compilerParent -WindowsBinary
    $compilerDirectory=Join-Path $compilerParent ('DeskBridge-Compiler-'+[Guid]::NewGuid().ToString('N'))
    $compilerCreated=$false; $compilerOptions=$null
    $priorTemp=[Environment]::GetEnvironmentVariable('TEMP','Process'); $priorTmp=[Environment]::GetEnvironmentVariable('TMP','Process')
    try {
        if (Test-Path -LiteralPath $compilerDirectory) { throw 'Compiler path must be new.' }
        # Windows PowerShell Desktop applies the final ACL atomically; its protected parent excludes untrusted creators.
        $compilerAcl=New-Object Security.AccessControl.DirectorySecurity
        $compilerAcl.SetAccessRuleProtection($true,$false)
        $compilerAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
            $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $compilerAcl.AddAccessRule($rule)
        }
        [IO.Directory]::CreateDirectory($compilerDirectory,$compilerAcl) | Out-Null
        $compilerCreated=$true
        Assert-ProtectedDirectory $compilerDirectory
        if (-not (Get-Acl -LiteralPath $compilerDirectory).AreAccessRulesProtected -or @([IO.Directory]::EnumerateFileSystemEntries($compilerDirectory)).Count -ne 0) { throw 'Compiler directory must be protected and empty.' }
        $compilerOptions=New-Object CodeDom.Compiler.CompilerParameters
        $compilerOptions.GenerateInMemory=$true
        [void]$compilerOptions.ReferencedAssemblies.Add([ComponentModel.Win32Exception].Assembly.Location)
        $compilerOptions.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($compilerDirectory,$false)
        [Environment]::SetEnvironmentVariable('TEMP',$compilerDirectory,'Process')
        [Environment]::SetEnvironmentVariable('TMP',$compilerDirectory,'Process')
        # Native create-new applies the final share/state descriptor before exposing that path.
        Add-Type -CompilerParameters $compilerOptions -TypeDefinition $TypeDefinition
    } finally {
        [Environment]::SetEnvironmentVariable('TEMP',$priorTemp,'Process')
        [Environment]::SetEnvironmentVariable('TMP',$priorTmp,'Process')
        # Delete only CodeDOM's tracked files and our empty directory, never unknown generated content recursively.
        if ($compilerOptions -and $compilerOptions.TempFiles) { $compilerOptions.TempFiles.Delete() }
        if ($compilerCreated) {
            try { [IO.Directory]::Delete($compilerDirectory,$false) }
            catch { Write-Warning 'An administrator-only compiler temporary directory remains for manual cleanup.' }
        }
    }
}
function Assert-NoOpenSSHWorkers {
    param([scriptblock] $Inventory = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name='sshd.exe' OR Name='sshd-session.exe' OR Name='sshd-auth.exe'" -Property Name,ProcessId -ErrorAction Stop) })
    if (@(& $Inventory).Count -ne 0) {
        throw 'An OpenSSH server or session worker already exists. This helper will not provision alongside an unproven deployment; review it manually.'
    }
}
function Initialize-DeskBridgeLifecycleLease {
    if ('DeskBridge.SFTPLifecycleLease' -as [type]) { return }
    Invoke-ProtectedCompilation -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Threading;
using Microsoft.Win32.SafeHandles;
namespace DeskBridge {
 public sealed class SFTPLifecycleLease : IDisposable {
  const uint MutexAllAccess=0x001F0001, WaitObject=0, WaitAbandoned=0x80, WaitTimeout=0x102;
  const string ProductionName="Global\\Knot.SFTP.Lifecycle.v1";
  const string Security="O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)";
  [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {
   public int Length; public IntPtr Descriptor;
   [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
  }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeWaitHandle CreateMutexEx(ref SecurityAttributes attributes, string name, uint flags, uint access);
  [DllImport("advapi32.dll")] static extern uint GetSecurityInfo(SafeWaitHandle handle, int type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
  [DllImport("advapi32.dll", SetLastError=true)] static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr allocation);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(SafeWaitHandle handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReleaseMutex(SafeWaitHandle handle);
  SafeWaitHandle mutex; bool owned; int threadId;
  SFTPLifecycleLease() {}
  public static SFTPLifecycleLease Acquire() { return AcquireName(ProductionName); }
  // Kept private: the production API has one fixed machine-wide name. CI reflects this
  // same factory only for newly generated synthetic names, never the production object.
  static SFTPLifecycleLease AcquireName(string name) {
   var result=new SFTPLifecycleLease(); IntPtr descriptor=IntPtr.Zero;
   try {
    uint size;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptor(Security, 1, out descriptor, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
    var attributes=new SecurityAttributes(); attributes.Length=Marshal.SizeOf(typeof(SecurityAttributes));
    attributes.Descriptor=descriptor; attributes.Inherit=false;
    result.mutex=CreateMutexEx(ref attributes, name, 0, MutexAllAccess);
    if (result.mutex.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
    ValidateSecurity(result.mutex);
    uint wait=WaitForSingleObject(result.mutex, 0); // Fail fast; no queued stale preflight.
    if (wait==WaitTimeout) throw new InvalidOperationException("Another Knot file-access operation is running. Wait for it to finish, then retry.");
    if (wait!=WaitObject && wait!=WaitAbandoned) throw new Win32Exception(Marshal.GetLastWin32Error());
    result.owned=true; result.threadId=Thread.CurrentThread.ManagedThreadId;
    if (wait==WaitAbandoned) throw new InvalidOperationException("A previous Knot file-access operation ended unexpectedly. Review the retained state before retrying.");
    return result;
   } catch { result.Dispose(); throw; }
   finally { if (descriptor!=IntPtr.Zero) LocalFree(descriptor); }
  }
  static bool TrustedPolicy(string owner, bool protectedDacl, string[] sids, int[] masks, int[] flags, bool[] plainAllows) {
   if ((owner!="S-1-5-18" && owner!="S-1-5-32-544") || !protectedDacl || sids==null || masks==null || flags==null || plainAllows==null ||
       sids.Length!=2 || masks.Length!=2 || flags.Length!=2 || plainAllows.Length!=2) return false;
   bool system=false, admins=false;
   for (int i=0;i<2;i++) {
    if (!plainAllows[i] || flags[i]!=0 || (masks[i]!=(int)MutexAllAccess && masks[i]!=0x10000000)) return false;
    if (sids[i]=="S-1-5-18" && !system) system=true;
    else if (sids[i]=="S-1-5-32-544" && !admins) admins=true;
    else return false;
   }
   return system && admins;
  }
  static void ValidateSecurity(SafeWaitHandle handle) {
   IntPtr owner, group, dacl, sacl, descriptor;
   uint error=GetSecurityInfo(handle, 6, 0x00000005, out owner, out group, out dacl, out sacl, out descriptor);
   if (error!=0) throw new Win32Exception((int)error);
   try {
    uint length=GetSecurityDescriptorLength(descriptor);
    if (length==0 || length>65536) throw new InvalidOperationException("Invalid Knot lifecycle mutex security descriptor.");
    var bytes=new byte[length]; Marshal.Copy(descriptor, bytes, 0, (int)length);
    var security=new RawSecurityDescriptor(bytes, 0);
    int count=security.DiscretionaryAcl==null ? 0 : security.DiscretionaryAcl.Count;
    var sids=new string[count];var masks=new int[count];var flags=new int[count];var allows=new bool[count];
    for (int i=0;i<count;i++) {
     var ace=security.DiscretionaryAcl[i] as CommonAce;
     if (ace==null) continue;
     sids[i]=ace.SecurityIdentifier.Value;masks[i]=ace.AccessMask;flags[i]=(int)ace.AceFlags;
     allows[i]=!ace.IsCallback && ace.AceQualifier==AceQualifier.AccessAllowed;
    }
    bool trusted=TrustedPolicy(security.Owner==null ? null : security.Owner.Value,
      (security.ControlFlags & ControlFlags.DiscretionaryAclProtected)!=0, sids,masks,flags,allows);
    if (!trusted) throw new InvalidOperationException("The Knot lifecycle mutex is not protected for SYSTEM and Administrators. Review its owner and permissions; no operation was started.");
   } finally { if (descriptor!=IntPtr.Zero) LocalFree(descriptor); }
  }
  public void Dispose() {
   if (mutex==null) return;
   if (owned && threadId!=Thread.CurrentThread.ManagedThreadId) throw new InvalidOperationException("The Knot lifecycle lease must be released by its owning thread.");
   try {
    if (owned && !ReleaseMutex(mutex)) throw new Win32Exception(Marshal.GetLastWin32Error());
    owned=false;
   } finally { mutex.Dispose(); mutex=null; }
  }
 }
}
'@
}
function Enter-DeskBridgeLifecycleLease {
    param([scriptblock] $Acquire)
    if ($Acquire) { $lease=& $Acquire }
    else {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'File-access lifecycle operations require Windows.' }
        Initialize-DeskBridgeLifecycleLease
        $lease=[DeskBridge.SFTPLifecycleLease]::Acquire()
    }
    if ($null -eq $lease -or -not $lease.PSObject.Methods['Dispose']) { throw 'The file-access lifecycle lease was not acquired.' }
    return $lease
}
function Initialize-ManagedWorkerHandle {
    if ('DeskBridge.ManagedWorkerHandle' -as [type]) { return }
    Invoke-ProtectedCompilation -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace DeskBridge {
 public sealed class ManagedWorkerHandle : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct BasicInformation {
   public int ExitStatus; public IntPtr PebBaseAddress; public UIntPtr AffinityMask;
   public int BasePriority; public UIntPtr UniqueProcessId; public UIntPtr InheritedFromUniqueProcessId;
  }
  [DllImport("kernel32.dll", SetLastError=true)] static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder name, ref uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(SafeProcessHandle process, out long created, out long exited, out long kernel, out long user);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(SafeProcessHandle process, int kind, out BasicInformation information, int size, out int returned);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(SafeProcessHandle process, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);
  SafeProcessHandle process;
  public uint ProcessId { get; private set; }
  public uint ParentProcessId { get; private set; }
  public long CreatedFileTime { get; private set; }
  public string ExecutablePath { get; private set; }
  public bool Alive {
   get {
    if (process == null || process.IsClosed || process.IsInvalid) throw new InvalidOperationException("OpenSSH ownership handle is closed.");
    uint state=WaitForSingleObject(process, 0);
    if (state==0) return false;
    if (state==258) return true;
    throw new Win32Exception(Marshal.GetLastWin32Error());
   }
  }
  public static ManagedWorkerHandle Capture(uint pid, string expected) {
   var result=new ManagedWorkerHandle();
   try {
    // Hold this object from ancestry inspection through termination. Stop never reopens a PID.
    result.process=OpenProcess(0x00101401, false, pid);
    if (result.process.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
    var name=new StringBuilder(32768); uint size=32768;
    if (!QueryFullProcessImageName(result.process, 0, name, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
    if (!String.Equals(name.ToString(), expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("OpenSSH worker identity changed.");
    long created, exited, kernel, user;
    if (!GetProcessTimes(result.process, out created, out exited, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
    BasicInformation info; int returned; int length=Marshal.SizeOf(typeof(BasicInformation));
    int status=NtQueryInformationProcess(result.process, 0, out info, length, out returned);
    if (status!=0 || returned!=length || info.UniqueProcessId.ToUInt64()!=pid || info.InheritedFromUniqueProcessId.ToUInt64()>UInt32.MaxValue || created<=0)
     throw new InvalidOperationException("OpenSSH native ancestry could not be verified.");
    result.ProcessId=pid; result.ParentProcessId=(uint)info.InheritedFromUniqueProcessId.ToUInt64();
    result.CreatedFileTime=created; result.ExecutablePath=name.ToString();
    if (!result.Alive) throw new InvalidOperationException("OpenSSH worker exited during ownership inspection.");
    return result;
   } catch { result.Dispose(); throw; }
  }
  public void Stop() {
   if (!Alive) return;
   if (!TerminateProcess(process, 1)) {
    int error=Marshal.GetLastWin32Error();
    if (WaitForSingleObject(process, 0)!=0) throw new Win32Exception(error);
   }
   if (WaitForSingleObject(process, 5000)!=0) throw new InvalidOperationException("Owned OpenSSH worker did not stop.");
  }
  public void Dispose() { if (process!=null) { process.Dispose(); process=null; } }
 }
}
'@
}
function Stop-ManagedSessionWorkers {
    param([Parameter(Mandatory=$true)][scriptblock] $BeforeStop,
          [string] $WindowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
          [scriptblock] $Inventory = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name='sshd.exe' OR Name='sshd-session.exe' OR Name='sshd-auth.exe'" -ErrorAction Stop) },
          [scriptblock] $ServiceInventory = { @(Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction Stop) },
          [scriptblock] $Capture,[scriptblock] $Terminate,[scriptblock] $Release)
    # The verified deployment caller supplies the account/service stop transaction. No mutation
    # may occur until every worker is proven to descend from this live service instance.
    $services=@(& $ServiceInventory)
    if ($services.Count -ne 1) { throw 'The dedicated OpenSSH service could not be inspected. Review manually.' }
    $service=$services[0]
    foreach ($field in @('Name','State','ProcessId','PathName')) {
        if (-not $service.PSObject.Properties[$field]) { throw 'Incomplete OpenSSH service identity. Review manually.' }
    }
    $expected=$WindowsDirectory+'\System32\OpenSSH\sshd.exe'
    Assert-OpenSSHServicePath $service $expected
    if ($service.Name -ine 'sshd' -or $service.State -cnotin @('Running','Stopped') -or
        -not ($service.ProcessId -is [uint32] -or $service.ProcessId -is [int]) -or $service.ProcessId -lt 0 -or
        ($service.State -ceq 'Stopped' -and $service.ProcessId -ne 0) -or ($service.State -ceq 'Running' -and $service.ProcessId -le 0)) {
        throw 'OpenSSH service lifetime is ambiguous. Review manually before changing access.'
    }
    $workers=@(& $Inventory)
    foreach ($worker in $workers) {
        if (-not (Test-SystemOpenSSHWorkerPath $worker $WindowsDirectory) -or
            -not $worker.PSObject.Properties['ProcessId'] -or
            -not ($worker.ProcessId -is [uint32] -or $worker.ProcessId -is [int]) -or $worker.ProcessId -le 0) {
            throw 'Unknown OpenSSH worker identity. Review the dedicated service manually.'
        }
    }
    if ($service.State -ceq 'Stopped' -and $workers.Count -gt 0) {
        # A persisted PID, executable path or orphan's parent PID cannot prove service ownership.
        throw 'OpenSSH workers remain without a live managed service ancestor. No workers were stopped; manual recovery is required.'
    }
    if ($service.State -ceq 'Running' -and @($workers | Where-Object {$_.ProcessId -eq $service.ProcessId -and $_.Name -ieq 'sshd.exe'}).Count -ne 1) {
        throw 'The live OpenSSH service process was not found. No workers were stopped; review manually.'
    }
    if (($Capture -or $Terminate -or $Release) -and -not ($Capture -and $Terminate -and $Release)) {
        throw 'Synthetic worker callbacks must supply capture, termination and release together.'
    }
    if (-not $Capture -and $workers.Count -gt 0) {
        Initialize-ManagedWorkerHandle
        $Capture={param($worker) [DeskBridge.ManagedWorkerHandle]::Capture([uint32]$worker.ProcessId,[string]$worker.ExecutablePath)}
        $Terminate={param($identity) $identity.Stop()}
        $Release={param($identity) $identity.Dispose()}
    }
    $handles=New-Object 'Collections.Generic.List[object]'
    $byPid=@{}
    try {
        # Capture the service root first. Native parent PID, time and image all come from
        # the held process object, not from a stale CIM projection or a command-line guess.
        foreach ($worker in @($workers | Sort-Object {$_.ProcessId -ne $service.ProcessId})) {
            $identity=& $Capture $worker
            if ($null -eq $identity) { throw 'OpenSSH ownership capture returned no handle.' }
            $handles.Add($identity)
            foreach ($field in @('ProcessId','ParentProcessId','CreatedFileTime','ExecutablePath','Alive')) {
                if (-not $identity.PSObject.Properties[$field]) { throw 'Incomplete OpenSSH ownership handle.' }
            }
            if ($identity.ProcessId -ne $worker.ProcessId -or $identity.ExecutablePath -ine $worker.ExecutablePath -or
                $identity.CreatedFileTime -isnot [long] -or $identity.CreatedFileTime -le 0 -or
                -not ($identity.ParentProcessId -is [uint32] -or $identity.ParentProcessId -is [int]) -or $identity.ParentProcessId -lt 0 -or
                $identity.Alive -isnot [bool] -or -not $identity.Alive -or $byPid.ContainsKey([string]$identity.ProcessId)) {
                throw 'OpenSSH ownership changed during capture. No workers were stopped; review manually.'
            }
            $byPid[[string]$identity.ProcessId]=$identity
        }
        foreach ($identity in $handles) {
            $cursor=$identity; $visited=@{}
            while ($cursor.ProcessId -ne $service.ProcessId) {
                $key=[string]$cursor.ProcessId
                $parentKey=[string]$cursor.ParentProcessId
                if ($visited.ContainsKey($key) -or -not $byPid.ContainsKey($parentKey)) {
                    throw 'An OpenSSH worker has no proven managed service ancestry. No workers were stopped; review unrelated deployments manually.'
                }
                $visited[$key]=$true; $parent=$byPid[$parentKey]
                if ($parent.CreatedFileTime -ge $cursor.CreatedFileTime) {
                    throw 'OpenSSH parent identity was reused or ambiguous. No workers were stopped; review manually.'
                }
                $cursor=$parent
            }
        }
        $current=@(& $ServiceInventory)
        if ($current.Count -ne 1 -or $current[0].Name -ine 'sshd' -or $current[0].State -cne $service.State -or
            $current[0].ProcessId -ne $service.ProcessId -or $current[0].PathName -cne $service.PathName) {
            throw 'OpenSSH service changed during ownership inspection. No workers were stopped; review manually.'
        }
        foreach ($identity in $handles) {
            if (-not $identity.Alive) { throw 'OpenSSH ancestry exited during inspection. No workers were stopped; review manually.' }
        }
        & $BeforeStop | Out-Null
        # Descendants first, using only the captured handles. A later PID reuse cannot
        # retarget termination, and a newly observed worker is never adopted here.
        foreach ($identity in @($handles | Sort-Object CreatedFileTime -Descending)) { & $Terminate $identity }
        # Stop success is not inactivity evidence: new/unknown workers force manual review.
        if (@(& $Inventory).Count -ne 0) { throw 'OpenSSH workers remain. Access inactivity is unproven; review manually before resuming.' }
        $stopped=@(& $ServiceInventory)
        if ($stopped.Count -ne 1 -or $stopped[0].Name -ine 'sshd' -or $stopped[0].State -cne 'Stopped' -or
            $stopped[0].ProcessId -ne 0 -or $stopped[0].PathName -cne $service.PathName) {
            throw 'OpenSSH service inactivity could not be verified. Review manually before resuming.'
        }
    } finally {
        foreach ($identity in $handles) { & $Release $identity }
    }
}
function Save-DeskBridgeConnectionReply([object] $Reply,[object] $Dialog) {
    # Only local export is recoverable here. Backend/reply identity validation stays with the caller.
    try {
        if ($Dialog.ShowDialog() -ne 'OK') { return 'Cancelled' }
        [IO.File]::WriteAllText([string]$Dialog.FileName,($Reply | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
        return 'Saved'
    } catch { return 'Failed' }
    finally { if ($Dialog) { try { [void]$Dialog.Dispose() } catch {} } }
}
function Get-NamedManagedFirewallRules([ValidateSet('PersistentStore','ActiveStore')][string] $PolicyStore) {
    try { Get-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -PolicyStore $PolicyStore -ErrorAction Stop }
    catch {
        # CDXML named-query absence only. Store/provider/access errors remain failures.
        $id=($_.FullyQualifiedErrorId -split ',')[0]
        if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -and
            $id -in @('CmdletizationQuery_NotFound_Name','CmdletizationQuery_NotFound')) { return }
        throw
    }
}
function Remove-ManagedFirewallAccess {
    # Never remove foreign rules or effective/GPO policy. Errors and surviving effective rules block completion.
    $configured=@(Get-NamedManagedFirewallRules -PolicyStore PersistentStore)
    if ($configured.Count -gt 0) { Remove-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -PolicyStore PersistentStore -ErrorAction Stop }
    foreach ($store in @('PersistentStore','ActiveStore')) {
        $remaining=@(Get-NamedManagedFirewallRules -PolicyStore $store)
        if ($remaining.Count -ne 0) { throw 'Knot firewall access remains configured or effective. Retain the helper and review policy manually.' }
    }
}
function Get-FileAccessInactivityProjection {
    # Product-runtime read-only inventory. Never infer absence from a failed cmdlet or missing process path.
    $result=[ordered]@{InspectionSucceeded=$false;ConfigState='Unknown';FirewallRuleCount=0;AccountCount=0;AccountState='Unknown';ServiceCount=0;ServiceState='Unknown';WorkerCount=0}
    try {
        if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Inactivity inspection requires Windows PowerShell Desktop.' }
        $programData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        $windows=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        if ($programData -notmatch '^[A-Za-z]:\\' -or $windows -notmatch '^[A-Za-z]:\\') { throw 'Expected fixed local Windows paths.' }
        Assert-NoReparsePath $programData
        # Enumerate fixed names so an absent item is an empty successful result, never a suppressed error.
        $sshDirectories=@(Get-ChildItem -LiteralPath $programData -Filter 'ssh' -Force -ErrorAction Stop)
        if ($sshDirectories.Count -eq 0) { $result.ConfigState='Absent' }
        elseif ($sshDirectories.Count -eq 1 -and $sshDirectories[0].PSIsContainer -and
                [string]::Equals($sshDirectories[0].FullName,(Join-Path $programData 'ssh'),[StringComparison]::OrdinalIgnoreCase)) {
            Assert-NoReparsePath $sshDirectories[0].FullName
            $configs=@(Get-ChildItem -LiteralPath $sshDirectories[0].FullName -Filter 'sshd_config' -Force -ErrorAction Stop)
            $result.ConfigState=if ($configs.Count -eq 0) {'Absent'} else {'Present'}
        } else { throw 'Unknown fixed SSH configuration path.' }
        # Include both configured and effective stores. Any occurrence forces ordinary managed preflight.
        $configuredRules=@(Get-NamedManagedFirewallRules -PolicyStore PersistentStore)
        $effectiveRules=@(Get-NamedManagedFirewallRules -PolicyStore ActiveStore)
        $result.FirewallRuleCount=$configuredRules.Count+$effectiveRules.Count
        $users=@(Get-LocalUser -ErrorAction Stop | Where-Object {$_.Name -ieq 'deskbridge-transfer'})
        $result.AccountCount=$users.Count
        if ($users.Count -eq 0) { $result.AccountState='Missing' }
        elseif ($users.Count -eq 1 -and $users[0].Enabled -is [bool]) { $result.AccountState=if ($users[0].Enabled) {'Enabled'} else {'Disabled'} }
        $services=@(Get-Service -ErrorAction Stop | Where-Object {$_.Name -ieq 'sshd'})
        $result.ServiceCount=$services.Count
        if ($services.Count -eq 0) { $result.ServiceState='Missing' }
        elseif ($services.Count -eq 1) { $result.ServiceState=[string]$services[0].Status }
        $workers=@(Get-CimInstance Win32_Process -Filter "Name='sshd.exe' OR Name='sshd-session.exe' OR Name='sshd-auth.exe'" -ErrorAction Stop)
        foreach ($worker in $workers) {
            if (-not (Test-SystemOpenSSHWorkerPath $worker $windows)) { throw 'Unknown OpenSSH worker executable path.' }
            $result.WorkerCount++
        }
        $result.InspectionSucceeded=$true
    } catch {
        # No output/log contains inventory or raw platform diagnostics. Caller falls back to strict preflight.
        $result.InspectionSucceeded=$false
    }
    return [pscustomobject]$result
}
function Resolve-DesktopUser([string] $Value) {
    # Local users include Microsoft-account-linked users. SID shape alone also matches groups.
    if ($Value -cnotmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Choose a local Windows desktop user. Domain/Entra accounts require manual integration.' }
    $sid=New-Object Security.Principal.SecurityIdentifier($Value)
    try { $user=Get-LocalUser -SID $sid -ErrorAction Stop } catch { throw 'The desktop SID must resolve to a local user; domain/Entra accounts require manual integration.' }
    if (-not $user -or -not $user.Enabled -or $user.SID.Value -cne $Value -or $user.Name -ceq 'deskbridge-transfer') { throw 'Choose an enabled local desktop user, not the transfer account.' }
    return $user
}
function Assert-OpenSSHServicePath([object] $Service,[string] $ExpectedPath) {
    if (-not $Service -or -not ($Service.PathName -is [string]) -or
        (-not [string]::Equals($Service.PathName,$ExpectedPath,[StringComparison]::OrdinalIgnoreCase) -and
         -not [string]::Equals($Service.PathName,('"' + $ExpectedPath + '"'),[StringComparison]::OrdinalIgnoreCase))) {
        throw 'The SSH service executable is not the dedicated Windows OpenSSH binary. Manual integration is required.'
    }
}
function Assert-DesktopSetupToken([scriptblock] $IsElevated = {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}) {
    # IsInRole checks this process token: an administrator's filtered token is allowed.
    if (& $IsElevated) { throw 'Close this administrator window and open Knot normally as the Windows user who will use the shared files. Do not choose Run as administrator; Knot asks for UAC when needed.' }
}
function Resolve-ManagedTransferUser([object] $Record,[scriptblock] $LookupBySid = {
    param($Sid) Get-LocalUser -SID $Sid -ErrorAction Stop
}) {
    if ($Record.UserSid -cnotmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $Record.UserName -cnotmatch '^[a-z][a-z0-9-]{2,30}$') { throw 'Invalid retained account identity. Manual recovery is required.' }
    try { $user=& $LookupBySid $Record.UserSid } catch { throw 'The retained transfer account is missing or changed. No account was selected by its reusable name.' }
    if (-not $user -or $user.SID.Value -cne $Record.UserSid -or $user.Name -cne $Record.UserName) { throw 'The retained transfer account identity changed. Manual recovery is required.' }
    return $user
}
function Assert-NoReparsePath([string] $Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Managed paths and their ancestors must not be reparse points.' }
        # Parent/Directory return raw .NET objects without provider-added PSIsContainer.
        if ($item -is [IO.DirectoryInfo]) { $item=$item.Parent }
        elseif ($item -is [IO.FileInfo]) { $item=$item.Directory }
        else { throw 'Managed paths must be filesystem files or directories.' }
    }
}
function Assert-ManagedConfig([string] $Path,[string] $Sha256) {
    Assert-ProtectedMetadata $Path
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 65536 -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Sha256 -or
        (Get-Content -LiteralPath $Path -TotalCount 1) -notlike '# DeskBridge dedicated SFTP deployment.*') {
        throw 'The managed SSH configuration changed. Manual review is required before any service or account change.'
    }
}
function Assert-ProtectedDirectory([string] $Path,[switch] $WindowsBinary) {
    if (-not (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).PSIsContainer) { throw 'Expected a protected directory.' }
    Assert-ProtectedMetadata $Path -WindowsBinary:$WindowsBinary
}
function Assert-ProtectedFile([string] $Path,[switch] $WindowsBinary) {
    if ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).PSIsContainer) { throw 'Expected a protected ordinary file.' }
    Assert-ProtectedMetadata $Path -WindowsBinary:$WindowsBinary
}
function Initialize-ConnectionExportDirectory([string] $Path) {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Connection export requires Windows PowerShell 5.1 (Desktop).' }
    $Path=[IO.Path]::GetFullPath($Path)
    if ($Path -notmatch '^[A-Za-z]:\\[^\\]+') { throw 'Connection export requires a local directory below a drive root.' }
    # The final directory ACL cannot protect against an untrusted ancestor renaming it.
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $rename=[int][Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor 1073741824 -bor 268435456
    $parent=[IO.DirectoryInfo]([IO.Path]::GetDirectoryName($Path))
    while ($parent) {
        Assert-NoReparsePath $parent.FullName
        $parentAcl=Get-Acl -LiteralPath $parent.FullName
        if ($parentAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Connection export ancestors must be administrator-owned.' }
        foreach ($rule in $parentAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -notin $trusted -and (([int]$rule.FileSystemRights) -band $rename)) { throw 'Connection export ancestors permit untrusted rename or permission changes.' }
        }
        $parent=$parent.Parent
    }
    if (Test-Path -LiteralPath $Path) {
        # Never tighten an existing untrusted path into a trusted export directory.
        Assert-ProtectedDirectory $Path
    } else {
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $admins=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $system=New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $users=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $acl.SetOwner($admins); $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @($admins,$system)) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))) }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
        # Framework applies the final DACL at creation; no inherited-write interval.
        # A raced existing directory must pass the same validation before any file is written.
        [IO.Directory]::CreateDirectory($Path,$acl) | Out-Null
        Assert-ProtectedDirectory $Path
    }
    $target=Join-Path $Path 'connection.json'
    if (Test-Path -LiteralPath $target) { Assert-ProtectedFile $target }
}
function Set-ManagedConfigAcl([string] $Path,[Security.Principal.SecurityIdentifier] $UserSid,[string] $Sha256) {
    # Do not repair/adopt an unknown file. Only a matching protected published config is tightened.
    Assert-ManagedConfig $Path $Sha256
    $acl=New-Object Security.AccessControl.FileSecurity
    $admins=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system=New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.SetOwner($admins); $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @($admins,$system)) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow'))) }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($UserSid,'Read','Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-ManagedConfig $Path $Sha256
}
function Assert-PrivateHostKey([string] $Path) {
    Assert-ProtectedFile $Path
    $acl=Get-Acl -LiteralPath $Path
    $read=[long]2147483648 -bor [long]268435456 -bor [int][Security.AccessControl.FileSystemRights]::ReadData
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and (([long]$rule.FileSystemRights) -band $read)) { throw 'The server private key is readable outside Administrators/SYSTEM. Manual key recovery is required.' }
    }
}
function Get-ManagedDirectoryRecords([string] $State,[object] $Record,[switch] $Revoke) {
    $entries=@([pscustomobject]@{Path=$State;Sddl=$Record.StateSDDL})
    if (-not $Revoke) {
        $entries += [pscustomobject]@{Path=$Record.ShareRoot;Sddl=$Record.ShareRootSDDL}
        $entries += [pscustomobject]@{Path=(Join-Path $Record.ShareRoot 'files');Sddl=$Record.FilesSDDL}
    }
    return $entries
}
function Get-ManagedDeployment([switch] $RequireConfig,[switch] $RequireValidated,[switch] $WizardDefaults,[string] $DesktopUserSid,[switch] $Revoke) {
    # All lifecycle entry points finish this read-only preflight before mutating resources.
    $state=Join-Path $env:ProgramData 'DeskBridgeSFTP'
    Assert-ProtectedDirectory $state
    $recordFile=Join-Path $state 'rollback.json'
    Assert-ProtectedMetadata $recordFile
    $item=Get-Item -LiteralPath $recordFile
    if ($item.PSIsContainer -or $item.Length -gt 65536) { throw 'Unexpected managed metadata size or type.' }
    $record=Get-Content -LiteralPath $recordFile -Raw | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('Schema','Phase','DesktopUserSid','UserName','UserSid','ShareRoot','StartupBefore','DefaultRuleEnabled','ConfigSha256','StateSDDL','ShareRootSDDL','FilesSDDL')) {
        if ($null -eq $record -or $field -cnotin @($record.PSObject.Properties.Name)) { throw 'Incomplete managed metadata requires manual recovery.' }
    }
    if ($record.Schema -ne 2 -or $record.Phase -cnotin @('Prepared','Validated') -or
        ($RequireValidated -and $record.Phase -cne 'Validated') -or
        ($DesktopUserSid -and $record.DesktopUserSid -cne $DesktopUserSid)) { throw 'This deployment uses an unsupported state or another desktop user. Manual review is required.' }
    if (($WizardDefaults -and ($record.UserName -cne 'deskbridge-transfer' -or $record.ShareRoot -ine 'C:\DeskBridgeShare')) -or
        $record.ShareRoot -notmatch '^[A-Za-z]:\\[^\\]+' -or $record.ShareRoot -match '[%\r\n\x00]' -or
        [IO.Path]::GetFullPath($record.ShareRoot) -ine $record.ShareRoot -or
        $record.DesktopUserSid -cnotmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or
        $record.ConfigSha256 -cnotmatch '^[0-9A-Fa-f]{64}$' -or
        $record.StartupBefore -cnotin @('Automatic','Manual','Disabled') -or
        ($null -ne $record.DefaultRuleEnabled -and $record.DefaultRuleEnabled -cnotin @('True','False'))) { throw 'This older/custom deployment requires manual recovery; retained files and SSH settings were not changed.' }
    # Revocation never opens the mutable share. Deleted files/changed share ACLs
    # must not prevent disabling the verified account and dedicated SSH deployment.
    $directoryRecords=@(Get-ManagedDirectoryRecords $state $record -Revoke:$Revoke)
    foreach ($entry in $directoryRecords) {
        Assert-NoReparsePath $entry.Path
        $directory=Get-Item -LiteralPath $entry.Path
        $acl=Get-Acl -LiteralPath $entry.Path
        if (-not $directory.PSIsContainer -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544') -or $acl.Sddl -cne $entry.Sddl) { throw 'Managed directory ownership/permissions changed. Manual review is required.' }
    }
    $user=Resolve-ManagedTransferUser $record
    if (-not $Revoke) {
        $admins=Get-LocalGroup -SID 'S-1-5-32-544'
        if (Get-LocalGroupMember -Group $admins.Name | Where-Object {$_.SID.Value -ceq $record.UserSid}) { throw 'The transfer account must not be an administrator.' }
    }
    $bin=Join-Path $env:WINDIR 'System32\OpenSSH'
    $sshd=Join-Path $bin 'sshd.exe'
    Assert-ProtectedDirectory $bin -WindowsBinary
    Assert-ProtectedFile $sshd -WindowsBinary
    $service=Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop
    Assert-OpenSSHServicePath $service $sshd
    $template=Join-Path $state 'sshd_config.managed'
    if (-not $Revoke) { Assert-ManagedConfig $template $record.ConfigSha256 }
    $config=Join-Path $env:ProgramData 'ssh\sshd_config'
    # Validate the config directory even when a revoked deployment has no config yet.
    Assert-ProtectedDirectory (Split-Path $config -Parent)
    $exists=Test-Path -LiteralPath $config
    if ($exists) { Assert-ManagedConfig $config $record.ConfigSha256 }
    elseif ($RequireConfig) { throw 'The managed SSH configuration is absent. Manual review is required.' }
    $keyPath=Join-Path $state 'authorized_keys'
    if (-not $Revoke) {
        Assert-ProtectedFile $keyPath
        Assert-ProtectedFile (Join-Path $bin 'ssh-keygen.exe') -WindowsBinary
    }
    return [pscustomobject]@{State=$state;Record=$record;User=$user;Service=$service;Bin=$bin;Sshd=$sshd;Template=$template;Config=$config;ConfigExists=$exists;KeyPath=$keyPath}
}
function Remove-NewEmptyDirectory([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item=Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Partial shared data was retained for manual recovery.'
    }
    # This API refuses a nonempty directory, including files created after Get-Item.
    # Never use Remove-Item's interactive recursive-removal confirmation here.
    [IO.Directory]::Delete($item.FullName,$false)
}
function Write-ManagedRecoveryRecord([string] $State,[object] $Record) {
    Assert-ProtectedMetadata $State
    $destination=Join-Path $State 'rollback.json'
    $temporary=Join-Path $State ('.rollback-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($temporary,($Record | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        $acl=New-Object Security.AccessControl.FileSecurity
        $admins=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $system=New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $acl.SetOwner($admins); $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @($admins,$system)) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow')))
        }
        Set-Acl -LiteralPath $temporary -AclObject $acl
        Assert-ProtectedMetadata $temporary
        if (Test-Path -LiteralPath $destination) {
            Assert-ProtectedMetadata $destination
            # PowerShell converts $null to an empty string for a .NET string parameter.
            [IO.File]::Replace($temporary,$destination,[NullString]::Value)
        } else { [IO.File]::Move($temporary,$destination) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Test-ManagedMetadataAcl([string] $Owner,[object[]] $Rule,[switch] $WindowsBinary) {
    $trusted=@('S-1-5-18','S-1-5-32-544')
    if ($WindowsBinary) { $trusted += 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' }
    if ($Owner -notin $trusted) { return $false }
    # Integer arithmetic preserves generic bits that PowerShell refuses to cast to this enum.
    $write=[int][Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData -bor [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor [Security.AccessControl.FileSystemRights]::WriteAttributes -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor 0x50000000
    foreach ($entry in $Rule) {
        if ($entry.AccessControlType -ne 'Allow') { continue }
        $sid=$entry.IdentityReference.Value
        # Inherit-only CREATOR OWNER becomes the actual child creator. CREATOR GROUP
        # can resolve to an untrusted primary group and receives no exception.
        # Effective untrusted add-file/add-directory rights below still cause refusal.
        if ($sid -eq 'S-1-3-0' -and (([int]$entry.PropagationFlags) -band [int][Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($sid -notin $trusted -and (([int]$entry.FileSystemRights) -band $write)) { return $false }
    }
    return $true
}
function Assert-ProtectedMetadata([string] $Path,[switch] $WindowsBinary) {
    Assert-NoReparsePath $Path
    $acl=Get-Acl -LiteralPath $Path
    $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if (-not (Test-ManagedMetadataAcl $owner $rules -WindowsBinary:$WindowsBinary)) {
        throw 'Managed metadata ownership/permissions are not protected. 관리자가 해당 폴더와 권한을 확인하세요. 기존 폴더는 자동으로 변경하거나 삭제하지 않습니다.'
    }
}
Export-ModuleMember -Function Assert-NoOpenSSHWorkers,Enter-DeskBridgeLifecycleLease,Test-ManagedMetadataAcl,Initialize-ConnectionExportDirectory,Get-CanonicalPublicKey,Get-KeyFingerprint,Get-PrivateIPv4,ConvertFrom-MacSetup,Read-MacSetup,Get-ManagedDeploymentAction,Assert-ProtectedMetadata,Resolve-DesktopUser,Assert-OpenSSHServicePath,Remove-NewEmptyDirectory,Write-ManagedRecoveryRecord,Assert-DesktopSetupToken,Resolve-ManagedTransferUser,Get-ManagedDeployment,Assert-ProtectedDirectory,Assert-ProtectedFile,Assert-ManagedConfig,Assert-NoReparsePath,Get-ManagedDirectoryRecords,Set-ManagedConfigAcl,Assert-PrivateHostKey,Test-ManagedFirewallPolicy,Get-ManagedFirewallPolicy,Test-FileAccessInactive,Get-FileAccessInactivityProjection,Test-SystemOpenSSHWorkerPath,Invoke-ProtectedCompilation,Stop-ManagedSessionWorkers,Save-DeskBridgeConnectionReply,Get-NamedManagedFirewallRules,Remove-ManagedFirewallAccess
