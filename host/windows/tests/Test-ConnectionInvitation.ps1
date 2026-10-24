#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Synthetic values only; no UI, adapter discovery, clipboard or Windows changes.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'SetupContract.psm1') -Force
Import-Module (Join-Path $root 'ConnectionInvitation.psm1') -Force
$count=0
function Expect([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message }; $script:count++ }
function Reject([scriptblock] $Body) { $failed=$false; try { & $Body | Out-Null } catch { $failed=$true }; Expect $failed 'Invalid invitation accepted' }
$link=New-DeskBridgeConnectionLink -PCName 'Synthetic PC' -Address '192.168.1.20','100.80.10.20'
Expect ($link -ceq 'deskbridge://connect?v=2&platform=windows&name=Synthetic%20PC&address=192.168.1.20&address=100.80.10.20') 'Windows invitations explicitly identify their role without changing legacy parsing'
foreach ($name in @('개발 PC','PC & Mac + 1','PC?address=8.8.8.8')) {
    $value=New-DeskBridgeConnectionLink -PCName $name -Address '192.168.1.20'
    Expect ($value.Contains('name=' + [Uri]::EscapeDataString($name)) -and ($value -split '&address=').Count -eq 2) 'Display name cannot inject query fields'
}
foreach ($name in @('',('x'*65),('한'*43),"PC`nName",('PC'+[char]0x202e),' PC','PC ')) {
    Reject { New-DeskBridgeConnectionLink -PCName $name -Address '192.168.1.20' }
}
foreach ($ip in @('8.8.8.8','127.0.0.1','localhost','::1','192.168.01.20','192.168.1.20:22','100.128.1.2')) {
    Reject { New-DeskBridgeConnectionLink -PCName 'PC' -Address $ip }
}
Reject { New-DeskBridgeConnectionLink -PCName 'PC' -Address @() }
Reject { New-DeskBridgeConnectionLink -PCName 'PC' -Address @('192.168.1.20','192.168.1.20') }
Reject { New-DeskBridgeConnectionLink -PCName 'PC' -Address (1..9 | ForEach-Object { '192.168.1.'+$_ }) }
Expect ((Get-PrivateIPv4 '192.168.1.20') -ceq '192.168.1.20') 'Dependent import does not remove the GUI setup contract'
@{status='passed';checks=$count;scope='pure synthetic invitation serialization; no UI, clipboard or network'} | ConvertTo-Json
