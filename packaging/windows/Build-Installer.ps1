#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string] $Compiler, [string] $SigningCertificate, [string] $NativeCompiler)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$version=[IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim()
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$') {throw 'Invalid version'}
if (-not $NativeCompiler) { $NativeCompiler=(Get-Command zig -CommandType Application -ErrorAction Stop).Source }
# No code signing certificate is consulted unless explicitly configured.
if ($SigningCertificate) {
 $cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $SigningCertificate)
}
function Sign-DistributionArtifact([string] $Path) {
 $result=Set-AuthenticodeSignature -LiteralPath $Path -Certificate $cert -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
 $verified=Get-AuthenticodeSignature -LiteralPath $Path
 if ($result.Status -ne 'Valid' -or $verified.Status -ne 'Valid' -or -not $verified.SignerCertificate -or -not $verified.TimeStamperCertificate -or
     $verified.SignerCertificate.Thumbprint -ine $cert.Thumbprint) {throw 'Artifact signature did not verify against the selected certificate'}
}
# The helper's signature covers its exact-source embedded scripts. Never modify tracked scripts.
& (Join-Path $PSScriptRoot 'Build-Launcher.ps1') -NativeCompiler $NativeCompiler
if ($SigningCertificate) {
 $launcher=Join-Path $root 'build\windows\Knot-Windows.exe'
 $manifest=Join-Path $root 'build\windows\Knot-Windows.build.json'
 $record=Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
 $unsigned=(Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash.ToLowerInvariant()
 if ($record.sha256 -cne $unsigned -or $record.authenticodeSigned) {throw 'The unsigned helper does not match its build manifest'}
 Sign-DistributionArtifact $launcher
 $record.sha256=(Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash.ToLowerInvariant()
 $record.authenticodeSigned=$true
 $record | Add-Member -NotePropertyName unsignedSha256 -NotePropertyValue $unsigned -Force
 $record | Add-Member -NotePropertyName signing -NotePropertyValue ([pscustomobject]@{
  transformation='Authenticode signature on exact-source helper; payload bytes unchanged'
  certificateThumbprint=$cert.Thumbprint;hashAlgorithm='SHA256';verified=$true;timestampVerified=$true
 }) -Force
 [IO.File]::WriteAllText($manifest,($record | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
}
& python (Join-Path $root 'scripts\test_windows_launcher.py') --dotnet dotnet --native-compiler $NativeCompiler
if ($LASTEXITCODE -ne 0) {throw 'Windows helper payload checks failed'}
& $Compiler ('/DAppVersion='+$version) (Join-Path $PSScriptRoot 'DeskBridge.iss')
if ($LASTEXITCODE -ne 0) {throw 'Inno Setup compilation failed'}
$file=Join-Path $root ('dist\release\Knot-'+$version+'-windows-x64-setup.exe')
if ($SigningCertificate) {
 Sign-DistributionArtifact $file
}
$quick=Join-Path (Split-Path $file -Parent) ('Knot-'+$version+'-windows-x64-quick-setup-preview.exe')
Copy-Item -LiteralPath (Join-Path $root 'build\windows\Knot-Windows.exe') -Destination $quick -Force
$notice=Join-Path (Split-Path $file -Parent) 'WindowsRuntime-NOTICE.txt'
Copy-Item -LiteralPath (Join-Path $root 'Vendor\WindowsRuntime\NOTICE') -Destination $notice -Force
$records=@('Knot-Windows.build.json','Knot-Windows.checks.json') | ForEach-Object {
 $source=Join-Path $root ('build\windows\'+$_)
 if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {throw 'The exact helper build/check records are required for distribution'}
 $destination=Join-Path (Split-Path $file -Parent) $_
 Copy-Item -LiteralPath $source -Destination $destination -Force
 $destination
}
(@($file,$quick,$notice)+@($records)) | ForEach-Object {
 (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($_)
} | Set-Content -LiteralPath (Join-Path (Split-Path $file -Parent) 'WINDOWS-SHA256SUMS') -Encoding ASCII
