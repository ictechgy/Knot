# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1')

function New-DeskBridgeConnectionLink([string] $PCName, [string[]] $Address) {
    if ([string]::IsNullOrEmpty($PCName) -or $PCName.Length -gt 64 -or
        [Text.Encoding]::UTF8.GetByteCount($PCName) -gt 128 -or $PCName.Trim() -cne $PCName -or
        $PCName -match '[\p{Cc}\p{Cf}]' -or $null -eq $Address -or $Address.Count -lt 1 -or $Address.Count -gt 8) {
        throw 'Invalid PC name or address list.'
    }
    $checked=@($Address | ForEach-Object { Get-PrivateIPv4 $_ })
    if (@($checked | Select-Object -Unique).Count -ne $checked.Count) { throw 'Duplicate PC addresses.' }
    $link='deskbridge://connect?v=2&platform=windows&name=' + [Uri]::EscapeDataString($PCName)
    foreach ($ip in $checked) { $link += '&address=' + [Uri]::EscapeDataString($ip) }
    if ([Text.Encoding]::UTF8.GetByteCount($link) -gt 1536) { throw 'Connection link is too large.' }
    return $link
}
Export-ModuleMember -Function New-DeskBridgeConnectionLink
