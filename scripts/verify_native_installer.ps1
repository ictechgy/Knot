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
# Inno reserves fixed-width string resources and pads them with ASCII spaces.
# Keep the raw evidence; normalize only that suffix, never leading/control text.
$productName = $info.ProductName.TrimEnd([char[]]@([char]32))
$productVersion = $info.ProductVersion.TrimEnd([char[]]@([char]32))
$fileVersion = $info.FileVersion.TrimEnd([char[]]@([char]32))
$fileParts = @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
$productParts = @($info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart, $info.ProductPrivatePart)
if ($productName -cne 'Knot Native Preview' -or
    $productVersion -cne $ExpectedVersion -or $fileVersion -cne $ExpectedNumericVersion -or
    ($fileParts -join '.') -cne $ExpectedNumericVersion -or ($productParts -join '.') -cne $ExpectedNumericVersion) {
    # Only public build metadata is reported; no installer execution or user state.
    [ordered]@{
        status = 'failed'
        productName = $productName
        productVersion = $productVersion
        fileVersion = $fileVersion
        rawProductName = $info.ProductName
        rawProductVersion = $info.ProductVersion
        rawFileVersion = $info.FileVersion
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
    productName = $productName
    productVersion = $productVersion
    fileVersion = $fileVersion
    rawProductName = $info.ProductName
    rawProductVersion = $info.ProductVersion
    rawFileVersion = $info.FileVersion
    stringNormalization = 'trailing ASCII space only'
    fileParts = $fileParts
    productParts = $productParts
    inspectionOnly = $true
    installerExecuted = $false
    inspector = 'System.Diagnostics.FileVersionInfo'
} | ConvertTo-Json -Depth 4 -Compress
