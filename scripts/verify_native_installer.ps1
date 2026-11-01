# SPDX-License-Identifier: GPL-3.0-only
# Inspect the newly built PE resources. Never execute or install the package.
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [Parameter(Mandatory = $true)][string]$ExpectedNumericVersion
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw 'The checked native installer is missing.'
}
$numericParts = @($ExpectedNumericVersion.Split('.') | ForEach-Object { [int]$_ })
if ($numericParts.Count -ne 4 -or @($numericParts | Where-Object { $_ -lt 0 -or $_ -gt 65535 }).Count -ne 0) {
    throw 'Expected a four-part numeric PE version.'
}
$info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo([System.IO.Path]::GetFullPath($Installer))
$fileParts = @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
$productParts = @($info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart, $info.ProductPrivatePart)
if ($info.ProductName -cne 'Knot Native Preview' -or
    $info.ProductVersion -cne $ExpectedVersion -or $info.FileVersion -cne $ExpectedNumericVersion -or
    ($fileParts -join '.') -cne $ExpectedNumericVersion -or ($productParts -join '.') -cne $ExpectedNumericVersion) {
    # Only public build metadata is reported; no installer execution or user state.
    [ordered]@{
        status = 'failed'
        productName = $info.ProductName
        productVersion = $info.ProductVersion
        fileVersion = $info.FileVersion
        fileParts = $fileParts
        productParts = $productParts
        expectedVersion = $ExpectedVersion
        expectedNumericVersion = $ExpectedNumericVersion
        installerExecuted = $false
    } | ConvertTo-Json -Depth 4 -Compress | Write-Output
    throw 'Native installer PE version metadata does not match this preview.'
}
[ordered]@{
    schema = 1
    status = 'passed'
    productName = $info.ProductName
    productVersion = $info.ProductVersion
    fileVersion = $info.FileVersion
    fileParts = $fileParts
    productParts = $productParts
    inspectionOnly = $true
    installerExecuted = $false
    inspector = 'System.Diagnostics.FileVersionInfo'
} | ConvertTo-Json -Depth 4 -Compress
