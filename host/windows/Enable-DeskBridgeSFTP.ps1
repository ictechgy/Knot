#Requires -Version 5.1
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator
<#
Explicit opt-in setup for a NEW Windows OpenSSH installation. Does not run from the Mac app.
Refuses an existing sshd_config, running sshd, or conflicting service image to avoid taking over another SSH deployment.
Review first; run with -Apply only after choosing the exact Mac LAN/Tailscale addresses.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string] $ClientPublicKey,
    [Parameter(Mandatory = $true)][string[]] $AllowedClientAddress,
    [Parameter(Mandatory = $true)][string] $DesktopUserSid,
    [ValidatePattern('^[a-z][a-z0-9-]{2,30}$')][string] $UserName = 'deskbridge-transfer',
    [string] $ShareRoot = 'C:\DeskBridgeShare',
    [switch] $Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
if (-not $Apply) {
    Write-Output 'Review mode: no changes. With -Apply this installs OpenSSH Server if needed, creates a dedicated standard user and NEW local share, restricts SSH to that key/user and the supplied client IPs, and starts sshd.'
    Write-Output 'Existing sshd configuration/running service, existing account, existing share or existing DeskBridge state cause refusal. No router ports or Tailscale policy are changed.'
    return
}
if (-not $PSCmdlet.ShouldProcess('Windows OpenSSH Server, dedicated account, NTFS share ACLs and firewall', 'Configure key-only DeskBridge SFTP')) { return }
$lifecycleLease=Enter-DeskBridgeLifecycleLease
try {
Assert-NoOpenSSHWorkers

$publicKey = Get-CanonicalPublicKey $ClientPublicKey
$desktopUser = Resolve-DesktopUser $DesktopUserSid
Write-Output ('Granting shared-file access to local desktop user ' + $desktopUser.Name + ' (' + $DesktopUserSid + ').')
$AllowedClientAddress = @($AllowedClientAddress | ForEach-Object { Get-PrivateIPv4 $_ })
if ($AllowedClientAddress.Count -lt 1 -or $AllowedClientAddress.Count -gt 8 -or
    @($AllowedClientAddress | Select-Object -Unique).Count -ne $AllowedClientAddress.Count) { throw 'Choose one to eight distinct Mac LAN/Tailscale IPv4 addresses.' }
$ShareRoot = [IO.Path]::GetFullPath($ShareRoot)
if ($ShareRoot -notmatch '^[A-Za-z]:\\[^\\]+' -or $ShareRoot.Contains('%') -or $ShareRoot -match '[\r\n\x00]') { throw 'ShareRoot must be a new local directory, not a drive root, network share or tokenized path.' }
$state = Join-Path $env:ProgramData 'DeskBridgeSFTP'
$sshDirectory = Join-Path $env:ProgramData 'ssh'
$config = Join-Path $sshDirectory 'sshd_config'
$expectedSSHD = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
if (Test-Path -LiteralPath $sshDirectory) { Assert-ProtectedDirectory $sshDirectory }
else { Assert-NoReparsePath $env:ProgramData }
if (Test-Path -LiteralPath $config) { throw 'An sshd_config already exists. Use the manual integration instructions; this helper will not replace it.' }
$service = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') { throw 'sshd is active. This helper refuses to change an existing SSH deployment.' }
if ($service) { Assert-OpenSSHServicePath (Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop) $expectedSSHD }
if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) { throw 'The requested account exists. Choose a new dedicated username.' }
if ((Test-Path -LiteralPath $ShareRoot) -or (Test-Path -LiteralPath $state)) { throw 'Share/state directories must be new. Existing data and configuration are never adopted.' }
$ancestor = [IO.DirectoryInfo]([IO.Path]::GetDirectoryName($ShareRoot))
while ($ancestor) {
    if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Share path ancestors must not be reparse points.' }
    $ancestor = $ancestor.Parent
}

$createdUser = $false; $wroteConfig = $false; $createdFirewall = $false; $startedService = $false
$createdState = $false; $createdShare = $false; $createdFiles = $false; $recordCommitted = $false
$user = $null
$defaultRuleEnabled = $null; $startupBefore = if ($service) { [string]$service.StartType } else { 'Manual' }
function New-PrivateDirectoryAcl([Security.Principal.SecurityIdentifier] $UserSid, [Security.AccessControl.FileSystemRights] $Rights, [Security.Principal.SecurityIdentifier] $DesktopSid=$null) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.SetOwner($admins); $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($admins, $system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    foreach ($sid in @($UserSid,$DesktopSid)) {
        if ($sid) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
    }
    return $acl
}
# Compile only in a fresh administrator-owned directory: CodeDOM's temp files must never use shared TEMP.
if (-not ('DeskBridgeSecureDirectory' -as [type])) {
        Invoke-ProtectedCompilation -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
public static class DeskBridgeSecureDirectory {
    [StructLayout(LayoutKind.Sequential)] struct Attributes {
        public int Length; public IntPtr Descriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateDirectory(string path, ref Attributes attributes);
    public static void CreateNew(string path, DirectorySecurity acl) {
        byte[] descriptor=acl.GetSecurityDescriptorBinaryForm();
        GCHandle pinned=GCHandle.Alloc(descriptor,GCHandleType.Pinned);
        try {
            Attributes attributes=new Attributes(); attributes.Length=Marshal.SizeOf(typeof(Attributes)); attributes.Descriptor=pinned.AddrOfPinnedObject();
            if (!CreateDirectory(path,ref attributes)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { pinned.Free(); }
    }
}
'@
}

function New-PrivateDirectory([string] $Path,[Security.AccessControl.DirectorySecurity] $Acl) {
    # A writable ancestor could rename even a protected child. Create-folder rights alone do not permit that.
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $danger=[int][Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor 1073741824 -bor 268435456
    $parent=[IO.DirectoryInfo]([IO.Path]::GetDirectoryName($Path))
    while ($parent) {
        Assert-NoReparsePath $parent.FullName
        $parentAcl=Get-Acl -LiteralPath $parent.FullName
        if ($parentAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Share/state ancestors must be administrator-owned.' }
        foreach ($rule in $parentAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -notin $trusted -and (([int]$rule.FileSystemRights) -band $danger)) { throw 'Share/state ancestors must not allow untrusted rename or permission changes.' }
        }
        $parent=$parent.Parent
    }
    [DeskBridgeSecureDirectory]::CreateNew($Path,$Acl)
    Assert-NoReparsePath $Path
    $actual=Get-Acl -LiteralPath $Path
    if ($actual.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544' -or -not $actual.AreAccessRulesProtected) { throw 'New directory owner/protection did not validate.' }
    # Compare descriptor ACEs independently of Windows' automatic-inheritance control flag normalization.
    $expectedRules=@($Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value + '|' + $_.FileSystemRights + '|' + $_.InheritanceFlags + '|' + $_.PropagationFlags + '|' + $_.AccessControlType } | Sort-Object)
    $actualRules=@($actual.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value + '|' + $_.FileSystemRights + '|' + $_.InheritanceFlags + '|' + $_.PropagationFlags + '|' + $_.AccessControlType } | Sort-Object)
    if (@(Compare-Object -CaseSensitive $actualRules $expectedRules).Count -ne 0 -or @([IO.Directory]::EnumerateFileSystemEntries($Path)).Count -ne 0) { throw 'New directory descriptor or empty state did not validate.' }
    return Get-Item -LiteralPath $Path
}
function Set-PrivateDirectoryAcl([string] $Path, [Security.Principal.SecurityIdentifier] $UserSid, [Security.AccessControl.FileSystemRights] $Rights, [Security.Principal.SecurityIdentifier] $DesktopSid=$null) {
    Set-Acl -LiteralPath $Path -AclObject (New-PrivateDirectoryAcl $UserSid $Rights $DesktopSid)
}
function Set-PrivateKeyAcl([string] $Path, [Security.Principal.SecurityIdentifier] $UserSid) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.SetOwner($admins); $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($admins, $system)) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($UserSid, 'Read', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
try {
    # Capture only pre-existing policy, before optional-feature installation can create a broad rule.
    $priorDefaultRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    $defaultRuleEnabled = if ($priorDefaultRule) { [string]$priorDefaultRule.Enabled } else { 'False' }
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($capability.State -ne 'Installed') {
        [void](Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0')
    }
    $sshBin = Join-Path $env:WINDIR 'System32\OpenSSH'
    $sshd = Join-Path $sshBin 'sshd.exe'; $keygen = Join-Path $sshBin 'ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $sshd)) { throw 'Windows OpenSSH Server is unavailable after installation.' }
    Assert-ProtectedDirectory $sshBin -WindowsBinary
    Assert-ProtectedFile $sshd -WindowsBinary
    Assert-ProtectedFile $keygen -WindowsBinary
    Assert-OpenSSHServicePath (Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop) $sshd
    # Installation must not start a partially configured endpoint.
    $service = Get-Service -Name sshd
    if ($service.Status -ne 'Stopped') { throw 'OpenSSH became active during setup. This helper will not stop an unproven deployment.' }
    # Recovery/key metadata must never pass through an inherited writable-directory window.
    New-PrivateDirectory $state (New-PrivateDirectoryAcl $null 'ReadAndExecute') | Out-Null
    Assert-ProtectedDirectory $state
    $createdState = $true
    if (-not (Test-Path -LiteralPath $sshDirectory)) {
        # Windows PowerShell 5.1/.NET Framework applies this ACL at creation,
        # avoiding an inherited ProgramData write window. A raced existing path
        # is not tightened and must pass the same protection check below.
        $sshAcl=New-PrivateDirectoryAcl $null 'ReadAndExecute'
        [IO.Directory]::CreateDirectory($sshDirectory,$sshAcl) | Out-Null
    }
    Assert-ProtectedDirectory $sshDirectory
    if (Test-Path -LiteralPath $config) { throw 'Installation produced an existing configuration; review it manually before continuing.' }
    $defaultConfig = Join-Path $sshBin 'sshd_config_default'
    if (Test-Path -LiteralPath $defaultConfig) { Copy-Item -LiteralPath $defaultConfig -Destination (Join-Path $state 'sshd_config_default.backup') }
    $defaultRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($defaultRule) { Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' }
    $bytes = New-Object byte[] 48; $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $password = ConvertTo-SecureString ([Convert]::ToBase64String($bytes)) -AsPlainText -Force
    [Array]::Clear($bytes, 0, $bytes.Length)
    $user = New-LocalUser -Name $UserName -Password $password -Disabled -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'DeskBridge key-only restricted SFTP transfer account'
    $createdUser = $true
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    $alreadyInUsers = Get-LocalGroupMember -Group $usersGroup.Name | Where-Object { $_.SID -eq $user.SID }
    if (-not $alreadyInUsers) { Add-LocalGroupMember -Group $usersGroup.Name -Member $user.Name }
    New-PrivateDirectory $ShareRoot (New-PrivateDirectoryAcl $user.SID 'ReadAndExecute' $desktopUser.SID) | Out-Null; $createdShare = $true
    $files = New-PrivateDirectory (Join-Path $ShareRoot 'files') (New-PrivateDirectoryAcl $user.SID 'Modify' $desktopUser.SID); $createdFiles = $true
    Set-PrivateDirectoryAcl $state $user.SID 'ReadAndExecute'
    $keyFile = Join-Path $state 'authorized_keys'
    [IO.File]::WriteAllText($keyFile, $publicKey + "`n", (New-Object Text.UTF8Encoding($false)))
    Set-PrivateKeyAcl $keyFile $user.SID
    $rootForConfig = $ShareRoot.Replace('\', '/')
    $keyForConfig = $keyFile.Replace('\', '/')
    $content = @"
# DeskBridge dedicated SFTP deployment. Original template and rollback state are in $state.
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
AuthenticationMethods publickey
AllowUsers $UserName
DisableForwarding yes
PermitTTY no
Subsystem sftp sftp-server.exe
Match User $UserName
    AuthorizedKeysFile "$keyForConfig"
    ChrootDirectory "$rootForConfig"
    ForceCommand internal-sftp -d /files
"@
    # Publish recoverable, explicitly unvalidated metadata before fallible external commands.
    $template = Join-Path $state 'sshd_config.managed'
    [IO.File]::WriteAllText($template, $content + "`n", (New-Object Text.UTF8Encoding($false)))
    Set-PrivateKeyAcl $template $user.SID
    $rollback = @{ Schema=2; Phase='Prepared'; DesktopUserSid=$desktopUser.SID.Value;
        UserName=$UserName; UserSid=$user.SID.Value; ShareRoot=$ShareRoot; StartupBefore=$startupBefore; DefaultRuleEnabled=$defaultRuleEnabled; CreatedConfig=$true;
        ConfigSha256=(Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash;
        ShareRootSDDL=(Get-Acl -LiteralPath $ShareRoot).Sddl; FilesSDDL=(Get-Acl -LiteralPath $files.FullName).Sddl; StateSDDL=(Get-Acl -LiteralPath $state).Sddl }
    Write-ManagedRecoveryRecord $state $rollback
    $recordCommitted = $true
    Assert-ManagedConfig $template $rollback.ConfigSha256
    Assert-ProtectedFile $keyFile
    & $keygen -l -f $keyFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The client public key is not accepted by OpenSSH.' }
    & $keygen -A
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate server host keys.' }
    Assert-ProtectedFile (Join-Path $sshDirectory 'ssh_host_ed25519_key.pub')
    Assert-PrivateHostKey (Join-Path $sshDirectory 'ssh_host_ed25519_key')
    $wroteConfig = $true
    Copy-Item -LiteralPath $template -Destination $config
    Set-ManagedConfigAcl $config $user.SID $rollback.ConfigSha256
    Assert-ManagedConfig $config $rollback.ConfigSha256
    & $sshd -t -f $config
    if ($LASTEXITCODE -ne 0) { throw 'sshd rejected the new configuration; the service will not start.' }
    $effective = & $sshd -T -f $config -C "user=$UserName,host=localhost,addr=127.0.0.1"
    $effectiveExit = $LASTEXITCODE
    $required = @('pubkeyauthentication yes', 'passwordauthentication no', 'authenticationmethods publickey', "allowusers $UserName", 'disableforwarding yes', 'permittty no', 'forcecommand internal-sftp -d /files', "chrootdirectory $rootForConfig", "authorizedkeysfile $keyForConfig")
    if ($effectiveExit -ne 0) { throw 'sshd could not evaluate the dedicated user configuration.' }
    foreach ($setting in $required) {
        if (-not ($effective -contains $setting)) { throw "Effective SSH restriction did not validate: $setting" }
    }
    $rollback.Phase = 'Validated'
    Write-ManagedRecoveryRecord $state $rollback
    Assert-ProtectedDirectory $sshDirectory
    Assert-ManagedConfig $config $rollback.ConfigSha256
    New-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -DisplayName 'DeskBridge SFTP from approved Mac addresses' -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $AllowedClientAddress -Action Allow -Profile Any | Out-Null
    $createdFirewall = $true
    Assert-NoOpenSSHWorkers
    Set-Service -Name sshd -StartupType Automatic
    Enable-LocalUser -SID $user.SID
    Start-Service sshd; $startedService = $true
    Write-Output 'DeskBridge SFTP is configured. Share /files is the only writable SFTP tree. Keep the account out of Administrators.'
    Write-Output 'Verify this SERVER host key fingerprint on the Mac using the separately supplied public key:'
    $hostKey = Join-Path $sshDirectory 'ssh_host_ed25519_key.pub'
    & $keygen -l -E sha256 -f $hostKey
    Get-Content -LiteralPath $hostKey
    Write-Output 'Rollback: run Disable-DeskBridgeSFTP.ps1 -Apply. Shared files are retained.'
} catch {
    if ($createdFirewall) { Remove-NetFirewallRule -Name 'DeskBridge-SFTP-In-TCP' -ErrorAction SilentlyContinue }
    if ($createdUser) { Disable-LocalUser -SID $user.SID -ErrorAction SilentlyContinue }
    if ($startedService -or $wroteConfig) {
        # A newly created state directory alone never authorizes stopping an SSH server.
        Assert-ManagedConfig $config $rollback.ConfigSha256
        Stop-ManagedSessionWorkers -BeforeStop {Stop-Service -Name sshd}
    }
    if ($wroteConfig -and (Test-Path -LiteralPath $config)) { Move-Item -LiteralPath $config -Destination (Join-Path $state 'sshd_config.failed') -Force }
    if (-not $recordCommitted) {
        # Only compensate resources created by THIS invocation, matching the actual account SID.
        try {
            if ($createdUser) {
                $actual=Get-LocalUser -Name $UserName -ErrorAction Stop
                if ($actual.SID.Value -cne $user.SID.Value) { throw 'Created account identity changed; manual review required.' }
                Remove-LocalUser -SID $user.SID
            }
            if ($createdFiles) { Remove-NewEmptyDirectory (Join-Path $ShareRoot 'files') }
            if ($createdShare) { Remove-NewEmptyDirectory $ShareRoot }
            if ($createdState) {
                foreach ($name in @('sshd_config_default.backup','authorized_keys','sshd_config.managed')) {
                    $path=Join-Path $state $name
                    if (Test-Path -LiteralPath $path) {
                        Assert-ProtectedMetadata $path
                        if ((Get-Item -LiteralPath $path).PSIsContainer) { throw 'Unexpected state directory; manual review required.' }
                        Remove-Item -LiteralPath $path -Force
                    }
                }
                Remove-NewEmptyDirectory $state
            }
        } catch { Write-Warning ('Incomplete setup was left disabled for manual recovery: ' + $_.Exception.Message) }
    }
    if ($defaultRuleEnabled -eq 'True') { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue }
    elseif ($defaultRuleEnabled -eq 'False') { Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue }
    Set-Service -Name sshd -StartupType $startupBefore -ErrorAction SilentlyContinue
    throw
}

} finally {$lifecycleLease.Dispose()}
