#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('EnableFiles','Export','DisableFiles')][string] $Operation,
    [string] $RequestPath,
    [string] $WindowsAddress,
    [string] $DesktopUserSid,
    [switch] $NoPause,
    [switch] $SuccessReceipt
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
function Write-SetupSuccessReceipt {
    if (-not $SuccessReceipt) { return }
    # Broker-only fixed file in its fresh administrator-owned payload stage; never a caller path.
    $receipt=[IO.File]::Open((Join-Path $PSScriptRoot 'operation-success'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $receipt.Dispose()
}
$lifecycleLease=$null
try {
    $lifecycleLease=Enter-DeskBridgeLifecycleLease
    if ($Operation -eq 'DisableFiles') {
        if (Test-FileAccessInactive (Get-FileAccessInactivityProjection)) {
            Write-Output 'DeskBridge file access is already inactive. No configuration, accounts, services, firewall rules, metadata or shared files were changed.'
            Write-SetupSuccessReceipt
            exit 0
        }
        $state = Join-Path $env:ProgramData 'DeskBridgeSFTP'
        if (-not (Test-Path -LiteralPath (Join-Path $state 'rollback.json'))) {
            throw 'Inactivity could not be verified and no managed recovery record exists. Retain shared data and review manually; no resources were changed.'
        }
        & (Join-Path $PSScriptRoot 'Disable-DeskBridgeSFTP.ps1') -Apply -Confirm:$false
        if (-not (Test-FileAccessInactive (Get-FileAccessInactivityProjection))) {
            throw 'File access inactivity could not be verified after revocation. Retain the helper and review remaining resources manually.'
        }
        Write-SetupSuccessReceipt
        exit 0
    }
    $request = Read-MacSetup $RequestPath
    $address = Get-PrivateIPv4 $WindowsAddress
    if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ceq $address })) { throw 'The selected Windows address is no longer assigned to this PC.' }
    $state = Join-Path $env:ProgramData 'DeskBridgeSFTP'
    $recordPath = Join-Path $state 'rollback.json'
    if ($Operation -eq 'EnableFiles') {
        $desktopUser=Resolve-DesktopUser $DesktopUserSid
        Write-Host ('Shared files will be available to local desktop user ' + $desktopUser.Name + ' (' + $desktopUser.SID.Value + ').')
        if (Test-Path -LiteralPath $recordPath) {
            & (Join-Path $PSScriptRoot 'Resume-DeskBridgeSFTP.ps1') -ClientPublicKey $request.clientPublicKey -AllowedClientAddress $request.allowedClientAddresses -DesktopUserSid $desktopUser.SID.Value
        } else {
            & (Join-Path $PSScriptRoot 'Enable-DeskBridgeSFTP.ps1') -ClientPublicKey $request.clientPublicKey -AllowedClientAddress $request.allowedClientAddresses -DesktopUserSid $desktopUser.SID.Value -Apply -Confirm:$false
        }
    }
    # Export shares lifecycle preflight; changed identities/configuration are never adopted.
    $deployment=Get-ManagedDeployment -RequireConfig -RequireValidated -WizardDefaults
    $record=$deployment.Record; $keyPath=$deployment.KeyPath
    $authorized = Get-CanonicalPublicKey ([IO.File]::ReadAllText($keyPath).Trim())
    if ($authorized -cne $request.clientPublicKey) { throw 'A different Mac key is already configured. Revoke that deployment before configuring another key.' }
    if ($deployment.Service.State -ne 'Running' -or -not $deployment.User.Enabled) { throw 'DeskBridge SFTP is not active.' }
    if (-not (Test-ManagedFirewallPolicy (Get-ManagedFirewallPolicy) $request.allowedClientAddresses)) {
        throw 'The managed firewall rule changed or is disabled. Revoke file access and configure it again; no connection file was exported.'
    }
    $hostPublicKey=Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub'
    Assert-ProtectedFile $hostPublicKey
    Assert-PrivateHostKey (Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key')
    $key = Get-CanonicalPublicKey ([IO.File]::ReadAllText($hostPublicKey).Trim())
    # Fixed administrator-owned output only. Never write an elevated result to a user-supplied path.
    $output = Join-Path $env:ProgramData 'DeskBridgeSetup'
    Initialize-ConnectionExportDirectory $output
    $target = Join-Path $output 'connection.json'
    $reply = @{kind='deskbridge.windows-connection';version=1;requestID=$request.requestID;clientPublicKey=$request.clientPublicKey;address=$address;port=22;username='deskbridge-transfer';serverPublicKey=$key}
    $staging = Join-Path $output ('connection-' + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($staging,($reply | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $target) { Assert-ProtectedFile $target }
    Move-Item -LiteralPath $staging -Destination $target -Force
    Write-Output ('SSH host fingerprint: ' + (Get-KeyFingerprint $key))
    Write-SetupSuccessReceipt
    exit 0
} catch {
    $failure=$_
    if ($lifecycleLease) {try {$lifecycleLease.Dispose()} finally {$lifecycleLease=$null}}
    Write-Host $failure.Exception.Message -ForegroundColor Red
    if (-not $NoPause) {
        [void](Read-Host 'Setup failed. Press Enter to close this administrator window')
        # Only a displayed and acknowledged interactive error is reported as handled.
        exit 2
    }
    exit 1
}
 finally {if ($lifecycleLease) {$lifecycleLease.Dispose()}}
