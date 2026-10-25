#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Runs a copied, actual packaging script against NEW synthetic fixtures only.
# Signing, certificate access, launcher compilation and Inno compilation are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$global:DeskBridgeInstallerContractCheckCount=0
$script:caseCount=0
$sourceRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$actualBuilder=Join-Path $sourceRoot 'packaging/windows/Build-Installer.ps1'
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('deskbridge-installer-contract-'+[Guid]::NewGuid().ToString('N'))
$utf8=New-Object Text.UTF8Encoding($false)
function Expect([bool] $Condition,[string] $Message) {
 if (-not $Condition) {throw $Message}
 $global:DeskBridgeInstallerContractCheckCount++
}
function Hash([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
# Read the actual Pascal uninstall function as data. No Inno/native process is run.
$innoSource=[IO.File]::ReadAllText((Join-Path $sourceRoot 'packaging/windows/DeskBridge.iss'))
# Inno's numeric ProductVersion cannot contain prerelease text. The signed
# updater reads the textual ProductVersion, which must retain the full VERSION.
Expect ([regex]::Matches($innoSource,'(?m)^VersionInfoProductTextVersion=\{#AppVersion\}\r?$').Count -eq 1 -and
        -not [regex]::IsMatch($innoSource,'(?m)^VersionInfoProductVersion=\{#AppVersion\}\r?$')) 'Full prerelease versions must use the textual Inno product version field.'
# Rebranding must overwrite the existing broker, not strand a privileged old copy.
Expect ($innoSource.Contains('AppId={{7BB82A17-E531-4D04-A1FA-E8912E9E8E99}') -and
        $innoSource.Contains('UsePreviousAppDir=yes')) 'Installer identity and previous installation directory must remain stable on upgrades.'
Expect ($innoSource.Contains('DefaultDirName={autopf}\Knot')) 'Fresh installations must use the public Knot folder name.'
Expect ($innoSource.Contains('UninstallDisplayIcon={app}\AppIcon.ico')) 'Installed Apps must show the Knot icon.'
foreach ($shortcut in @('Knot','Knot 제거')) {
 $line=@($innoSource -split '\r?\n' | Where-Object { $_.StartsWith('Name: "{group}\'+$shortcut+'";') })
 Expect ($line.Count -eq 1 -and $line[0].Contains('IconFilename: "{app}\AppIcon.ico"')) 'Every public shortcut must use the same Knot icon.'
}
Expect ($innoSource.Contains('Source: "..\..\build\windows\Knot-Windows.exe"; DestDir: "{app}"; DestName: "Knot.exe";')) 'The installed public executable must use the Knot name.'
Expect ($innoSource.Contains('Type: files; Name: "{app}\DeskBridge-Windows.exe"') -and $innoSource.Contains("CloseInstalledKnot('DeskBridge-Windows.exe')")) 'Legacy broker must close before exact-file migration cleanup.'
$runSection=[regex]::Match($innoSource,'(?ms)^\[Run\]\r?\n(?<body>.*?)^\[')
Expect $runSection.Success 'Actual installer run section must be present.'
$runEntries=@($runSection.Groups['body'].Value -split '\r?\n' | Where-Object { $_.StartsWith('Filename:') })
Expect ($runEntries.Count -eq 1 -and $runEntries[0] -ceq 'Filename: "{app}\Knot.exe"; Flags: nowait runasoriginaluser; Check: RestartFromThisInstaller') 'Manual installation must automatically reopen the replaced broker once as the original user, without a finish-page checkbox.'
# Evaluate only the actual allowlisted constant/comparison in the Pascal restart
# predicate. Never execute the installer or arbitrary translated source.
$restart=[regex]::Match($innoSource,"(?s)function RestartFromThisInstaller\(\): Boolean;\s*begin\s*\{[^}]*\}\s*Result := ExpandConstant\('\{param:(?<name>[A-Z]+)\|(?<default>[01])\}'\) <> '(?<suppressed>[01])';\s*end;")
Expect ($restart.Success -and $restart.Groups['name'].Value -ceq 'KNOTUPDATERHANDOFF') 'Restart ownership must be guarded by the exact handoff parameter.'
$comparison=[scriptblock]::Create('$value -cne '+"'"+$restart.Groups['suppressed'].Value+"'")
foreach ($case in @(@($null,$true),@('0',$true),@('1',$false),@('other',$true))) {
 $value=if ($null -eq $case[0]) {$restart.Groups['default'].Value} else {$case[0]}
 Expect ((& $comparison) -eq $case[1]) 'Only the signed handoff flag may suppress the manual installer restart.'
}
$handoff=[IO.File]::ReadAllText((Join-Path $sourceRoot 'packaging/windows/KnotUpdateHandoff.cs'))
Expect ([regex]::Matches($handoff,'/KNOTUPDATERHANDOFF=1').Count -eq 1) 'The verified handoff must suppress Inno restart so its existing non-elevated relaunch remains the single owner.'
$uninstallStart=$innoSource.IndexOf('function InitializeUninstall(): Boolean;',[StringComparison]::Ordinal)
Expect ($uninstallStart -ge 0) 'Actual uninstall callback must be present.'
$uninstall=$innoSource.Substring($uninstallStart)
Expect (-not [regex]::IsMatch($uninstall,'\b(DirExists|FileExists)\s*\(','IgnoreCase')) 'Missing metadata must never skip broker inventory.'
Expect ([regex]::Matches($uninstall,'Launched\s*:=\s*Exec\(').Count -eq 1 -and $uninstall.Contains("BrokerArguments := '--elevated-operation DisableFiles';")) 'Every noncancelled uninstall must dispatch the single fixed revocation broker.'
Expect ($uninstall.Contains('Result := False;') -and $uninstall.Contains('Result := Launched and (ExitCode = 0);')) 'Only a launched successful attested broker may authorize removal.'
$dialog=[regex]::Match($uninstall,'if (.+) then\s*\r?\n\s*MsgBox\(')
Expect $dialog.Success 'Actual failure dialog predicate must be identified.'
# Translate only the allowlisted Boolean/integer Pascal expression, not arbitrary source.
$predicate=$dialog.Groups[1].Value
$unknown=$predicate -replace '\b(UninstallSilent|Launched|ExitCode|not|and|or)\b','' -replace '[()<>0-9\s]',''
Expect ($unknown.Length -eq 0 -and $predicate.Length -lt 256) 'Only the known uninstall result predicate may be evaluated.'
$predicate=$predicate -replace '\bUninstallSilent\b','$UninstallSilent' -replace '\bLaunched\b','$Launched' -replace '\bExitCode\b','$ExitCode' -replace '\bnot\b','-not' -replace '\band\b','-and' -replace '\bor\b','-or' -replace '<>','-ne'
$dialogCondition=[scriptblock]::Create($predicate)
foreach ($case in @(@($false,$false,2,$true),@($false,$true,2,$true),@($false,$true,1,$true),@($true,$false,2,$false),@($false,$true,0,$true))) {
 $UninstallSilent=$case[0];$Launched=$case[1];$ExitCode=$case[2]
 # The zero case is unreachable inside `if not Result`; test the predicate independently.
 Expect ((& $dialogCondition) -eq $case[3]) 'Every interactive failed uninstall must explain that the helper is retained, including an acknowledged broker failure.'
}
# These commands shadow signing/certificate commands only in this fresh test process.
function Get-Item {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)][string] $LiteralPath)
 if ($LiteralPath.StartsWith('Cert:\',[StringComparison]::OrdinalIgnoreCase)) {
  $global:DeskBridgeInstallerFixture.CertificateCalls++
  Expect ($LiteralPath -ceq ('Cert:\CurrentUser\My\'+$global:DeskBridgeInstallerFixture.Thumbprint)) 'Selected certificate lookup changed.'
  return [pscustomobject]@{Thumbprint=$global:DeskBridgeInstallerFixture.Thumbprint}
 }
 return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
}
function Set-AuthenticodeSignature {
 [CmdletBinding()]
 param([string] $LiteralPath,[object] $Certificate,[string] $TimestampServer,[string] $HashAlgorithm)
 Expect ($Certificate.Thumbprint -ceq $global:DeskBridgeInstallerFixture.Thumbprint) 'Signing used the wrong selected certificate.'
 Expect ($HashAlgorithm -ceq 'SHA256' -and $TimestampServer) 'Signing must retain SHA256 and timestamping.'
 $global:DeskBridgeInstallerFixture.SignedPaths.Add([IO.Path]::GetFullPath($LiteralPath))
 [IO.File]::AppendAllText($LiteralPath,'|synthetic-signature:'+$Certificate.Thumbprint,(New-Object Text.UTF8Encoding($false)))
 return [pscustomobject]@{Status=$global:DeskBridgeInstallerFixture.SignStatus}
}
function Get-AuthenticodeSignature {
 [CmdletBinding()]
 param([string] $LiteralPath)
 $global:DeskBridgeInstallerFixture.VerifiedPaths.Add([IO.Path]::GetFullPath($LiteralPath))
 $thumb=if ($global:DeskBridgeInstallerFixture.WrongSigner) {'2222222222222222222222222222222222222222'} else {$global:DeskBridgeInstallerFixture.Thumbprint}
 $timestamp=if ($global:DeskBridgeInstallerFixture.MissingTimestamp) {$null} else {[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'}}
 return [pscustomobject]@{Status=$global:DeskBridgeInstallerFixture.VerifyStatus;SignerCertificate=[pscustomobject]@{Thumbprint=$thumb};TimeStamperCertificate=$timestamp}
}
function python {
 [CmdletBinding()]
 param([Parameter(ValueFromRemainingArguments=$true)][string[]] $CheckArguments)
 $global:DeskBridgeInstallerFixture.PayloadCheckCalls++
 $checkRoot=Split-Path (Split-Path $CheckArguments[0] -Parent) -Parent
 [IO.File]::WriteAllText((Join-Path $checkRoot 'build/windows/Knot-Windows.checks.json'),'{"status":"passed","synthetic":true}')
 Expect ($CheckArguments.Count -eq 5 -and [IO.Path]::GetFileName($CheckArguments[0]) -ceq 'test_windows_launcher.py' -and
         $CheckArguments[1] -ceq '--dotnet' -and $CheckArguments[2] -ceq 'dotnet' -and
         $CheckArguments[3] -ceq '--native-compiler' -and $CheckArguments[4] -ceq 'synthetic-zig-compiler') 'Payload checker must receive the exact native compiler selection.'
 $global:LASTEXITCODE=$global:DeskBridgeInstallerFixture.PayloadCheckStatus
}
$fakeLauncher=@'
[CmdletBinding()]
param([string] $NativeCompiler)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$global:DeskBridgeInstallerFixture.NativeCompiler=$NativeCompiler
$folder=Join-Path $root 'build/windows'
[IO.Directory]::CreateDirectory($folder) | Out-Null
$file=Join-Path $folder 'Knot-Windows.exe'
[IO.File]::WriteAllBytes($file,[Text.Encoding]::ASCII.GetBytes('MZ-synthetic-native-outer-with-exact-managed-resource'))
$digest=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
$global:DeskBridgeInstallerFixture.UnsignedHash=$digest
$record=[ordered]@{
 schema=1;version='9.8.7-preview.synthetic';sha256=$digest;authenticodeSigned=$false
 sourceManifest=[ordered]@{gitHead='1111111111111111111111111111111111111111';treeSha256=('a'*64);files=[ordered]@{'host/windows/Synthetic.ps1'=$global:DeskBridgeInstallerFixture.ScriptHash}}
 payloadSha256=[ordered]@{'Synthetic.ps1'=$global:DeskBridgeInstallerFixture.ScriptHash;'Synthetic.psm1'=$global:DeskBridgeInstallerFixture.ModuleHash}
 managedSha256=('b'*64);nativeResourceSha256=('b'*64);nativeCompiler='synthetic-native-toolchain'
}
if ($global:DeskBridgeInstallerFixture.BadUnsignedManifest) {$record.sha256='0'*64}
[IO.File]::WriteAllText((Join-Path $folder 'Knot-Windows.build.json'),($record | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
$global:DeskBridgeInstallerFixture.OriginalManifest=$record | ConvertTo-Json -Depth 20 -Compress
'@
$fakeCompiler=@'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]] $CompilerArguments)
$ErrorActionPreference='Stop'
$global:DeskBridgeInstallerFixture.CompilerCalls++
if ($CompilerArguments.Count -ne 2 -or $CompilerArguments[0] -cne '/DAppVersion=9.8.7-preview.synthetic' -or
    [IO.Path]::GetFileName($CompilerArguments[1]) -cne 'DeskBridge.iss') {throw 'Unexpected synthetic Inno arguments.'}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$folder=Join-Path $root 'dist/release'
[IO.Directory]::CreateDirectory($folder) | Out-Null
[IO.File]::WriteAllBytes((Join-Path $folder 'Knot-9.8.7-preview.synthetic-windows-x64-setup.exe'),[Text.Encoding]::ASCII.GetBytes('MZ-synthetic-inno-installer'))
$global:LASTEXITCODE=0
'@
try {
 [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
 foreach ($scenario in @('Signed','Unsigned','WrongSigner','InvalidSigningResult','InvalidVerifiedSignature','MissingTimestamp','MismatchedUnsignedManifest','WrongPayloadChecks')) {
  $script:caseCount++
  $root=Join-Path $fixtureRoot $scenario
  $packaging=Join-Path $root 'packaging/windows'; $hostFiles=Join-Path $root 'host/windows'
  [IO.Directory]::CreateDirectory($packaging) | Out-Null
  [IO.Directory]::CreateDirectory($hostFiles) | Out-Null
  $noticeFolder=Join-Path $root 'Vendor/WindowsRuntime'
  [IO.Directory]::CreateDirectory($noticeFolder) | Out-Null
  [IO.File]::WriteAllText((Join-Path $noticeFolder 'NOTICE'),'synthetic pinned runtime notice',$utf8)
  [IO.File]::WriteAllText((Join-Path $root 'VERSION'),'9.8.7-preview.synthetic',$utf8)
  # Copy the actual builder bytes; executable/code fixtures around it are entirely synthetic.
  [IO.File]::WriteAllBytes((Join-Path $packaging 'Build-Installer.ps1'),[IO.File]::ReadAllBytes($actualBuilder))
  [IO.File]::WriteAllText((Join-Path $packaging 'Build-Launcher.ps1'),$fakeLauncher,$utf8)
  [IO.File]::WriteAllText((Join-Path $packaging 'SyntheticCompiler.ps1'),$fakeCompiler,$utf8)
  [IO.File]::WriteAllText((Join-Path $packaging 'DeskBridge.iss'),'; synthetic Inno input, never compiled',$utf8)
  [IO.File]::WriteAllText((Join-Path $hostFiles 'Synthetic.ps1'),'# synthetic committed script; never execute or sign',$utf8)
  [IO.File]::WriteAllText((Join-Path $hostFiles 'Synthetic.psm1'),'# synthetic committed module; never execute or sign',$utf8)
  $before=@{}
  foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) { $before[$file.FullName]=Hash $file.FullName }
  $global:DeskBridgeInstallerFixture=[pscustomobject]@{
   Thumbprint='1111111111111111111111111111111111111111';CertificateCalls=0;CompilerCalls=0;PayloadCheckCalls=0
   PayloadCheckStatus=$(if ($scenario -eq 'WrongPayloadChecks') {1} else {0})
   SignedPaths=(New-Object 'Collections.Generic.List[string]');VerifiedPaths=(New-Object 'Collections.Generic.List[string]')
   SignStatus=$(if ($scenario -eq 'InvalidSigningResult') {'UnknownError'} else {'Valid'})
   VerifyStatus=$(if ($scenario -eq 'InvalidVerifiedSignature') {'NotSigned'} else {'Valid'})
   WrongSigner=($scenario -eq 'WrongSigner');BadUnsignedManifest=($scenario -eq 'MismatchedUnsignedManifest')
   MissingTimestamp=($scenario -eq 'MissingTimestamp')
   ScriptHash=(Hash (Join-Path $hostFiles 'Synthetic.ps1'));ModuleHash=(Hash (Join-Path $hostFiles 'Synthetic.psm1'))
   NativeCompiler='';UnsignedHash='';OriginalManifest=''
  }
  $invoke=@{Compiler=(Join-Path $packaging 'SyntheticCompiler.ps1');NativeCompiler='synthetic-zig-compiler'}
  if ($scenario -ne 'Unsigned') {$invoke.SigningCertificate=$global:DeskBridgeInstallerFixture.Thumbprint}
  $failed=$null
  try { & (Join-Path $packaging 'Build-Installer.ps1') @invoke | Out-Null } catch { $failed=$_ }
  foreach ($path in $before.Keys) { Expect ((Hash $path) -ceq $before[$path]) ('Committed script/input changed in '+$scenario) }
  if ($global:DeskBridgeInstallerFixture.NativeCompiler -cne 'synthetic-zig-compiler' -and $failed) { throw ('Fixture failed before launcher handoff in '+$scenario+': '+$failed.Exception.Message) }
  Expect ($global:DeskBridgeInstallerFixture.NativeCompiler -ceq 'synthetic-zig-compiler') 'Native compiler selection was not passed to Build-Launcher.'
  $output=Join-Path $root 'dist/release'
  $quick=Join-Path $output 'Knot-9.8.7-preview.synthetic-windows-x64-quick-setup-preview.exe'
  if ($scenario -notin @('Signed','Unsigned')) {
   Expect ($null -ne $failed) ('Invalid signing/provenance case was accepted: '+$scenario)
   $expected=if ($scenario -eq 'MismatchedUnsignedManifest') {'unsigned helper does not match'} elseif ($scenario -eq 'WrongPayloadChecks') {'helper payload checks failed'} else {'signature did not verify'}
   Expect ($failed.Exception.Message -like ('*'+$expected+'*')) ('Unexpected rejection in '+$scenario+': '+$failed.Exception.Message)
   Expect ($global:DeskBridgeInstallerFixture.CompilerCalls -eq 0 -and -not (Test-Path -LiteralPath $quick)) 'Rejected signing must stop before publishing installer/quick EXE.'
   continue
  }
  if ($failed) {throw $failed}
  Expect ($global:DeskBridgeInstallerFixture.PayloadCheckCalls -eq 1) 'Payload checks must pass once before Inno compilation.'
  Expect ($global:DeskBridgeInstallerFixture.CompilerCalls -eq 1) 'Inno compiler should run once.'
  $launcher=Join-Path $root 'build/windows/Knot-Windows.exe'
  $manifest=Get-Content -LiteralPath (Join-Path $root 'build/windows/Knot-Windows.build.json') -Raw | ConvertFrom-Json
  $original=$global:DeskBridgeInstallerFixture.OriginalManifest | ConvertFrom-Json
  foreach ($name in @('sourceManifest','payloadSha256','managedSha256','nativeResourceSha256','nativeCompiler')) {
   Expect (($manifest.$name | ConvertTo-Json -Depth 20 -Compress) -ceq ($original.$name | ConvertTo-Json -Depth 20 -Compress)) ('Signing changed provenance field '+$name)
  }
  Expect ($manifest.sha256 -ceq (Hash $launcher)) 'Final launcher digest was not refreshed.'
  if ($scenario -eq 'Signed') {
   Expect ($global:DeskBridgeInstallerFixture.CertificateCalls -eq 1 -and $global:DeskBridgeInstallerFixture.SignedPaths.Count -eq 2 -and $global:DeskBridgeInstallerFixture.VerifiedPaths.Count -eq 2) 'Only helper and installer should be signed and verified.'
   Expect ($manifest.authenticodeSigned -and $manifest.unsignedSha256 -ceq $global:DeskBridgeInstallerFixture.UnsignedHash -and $manifest.sha256 -cne $manifest.unsignedSha256) 'Signed manifest must retain the original unsigned digest.'
   Expect ($manifest.signing.verified -and $manifest.signing.timestampVerified -and $manifest.signing.certificateThumbprint -ceq $global:DeskBridgeInstallerFixture.Thumbprint -and $manifest.signing.hashAlgorithm -ceq 'SHA256') 'Manifest must bind timestamped verified signing to the selected certificate.'
  } else {
   Expect ($global:DeskBridgeInstallerFixture.CertificateCalls -eq 0 -and $global:DeskBridgeInstallerFixture.SignedPaths.Count -eq 0 -and $global:DeskBridgeInstallerFixture.VerifiedPaths.Count -eq 0) 'Unsigned builds must not consult certificates/signing APIs.'
   Expect (-not $manifest.authenticodeSigned -and $manifest.sha256 -ceq $global:DeskBridgeInstallerFixture.UnsignedHash) 'Unsigned build manifest changed.'
  }
  $installer=Join-Path $output 'Knot-9.8.7-preview.synthetic-windows-x64-setup.exe'
  Expect ([IO.File]::ReadAllText((Join-Path $output 'WindowsRuntime-NOTICE.txt')) -ceq 'synthetic pinned runtime notice') 'Runtime notice must accompany the distributed quick EXE.'
  Expect ((Hash $quick) -ceq (Hash $launcher)) 'Shipped quick EXE must match the final signed/unsigned helper.'
  $sums=@(Get-Content -LiteralPath (Join-Path $output 'WINDOWS-SHA256SUMS'))
  $buildRecord=Join-Path $output 'Knot-Windows.build.json'; $checkRecord=Join-Path $output 'Knot-Windows.checks.json'
  Expect ((Hash $buildRecord) -ceq (Hash (Join-Path $root 'build/windows/Knot-Windows.build.json')) -and
          (Hash $checkRecord) -ceq (Hash (Join-Path $root 'build/windows/Knot-Windows.checks.json'))) 'Distribution must retain exact build and check provenance bytes.'
  Expect ($sums.Count -eq 5) 'Distributed executables, runtime notice and build/check records need checksums.'
  foreach ($file in @($installer,$quick,(Join-Path $output 'WindowsRuntime-NOTICE.txt'),$buildRecord,$checkRecord)) {
   Expect ($sums -ccontains ((Hash $file)+'  '+[IO.Path]::GetFileName($file))) 'Published checksum does not match distributed executable.'
  }
 }
 @{status='passed';cases=$script:caseCount;checks=$global:DeskBridgeInstallerContractCheckCount;scope='actual copied Build-Installer with synthetic artifacts and mocked certificate/signing/compiler; no real signing or Windows setup'} | ConvertTo-Json -Compress
} finally {
 Remove-Variable -Name DeskBridgeInstallerFixture -Scope Global -ErrorAction SilentlyContinue
 Remove-Variable -Name DeskBridgeInstallerContractCheckCount -Scope Global -ErrorAction SilentlyContinue
 if ([IO.Directory]::Exists($fixtureRoot)) {[IO.Directory]::Delete($fixtureRoot,$true)}
}

# A successful test must not leak the deliberately failing mock native status.
# Keep this after the try/finally so assertion or cleanup failures still terminate.
$global:LASTEXITCODE=0
