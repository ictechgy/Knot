#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Pure synthetic checks only. Never install software, touch accounts/services/firewall or open the UI.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupContract.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupStatus.psm1') -Force
$count=0
function Expect([bool] $Condition,[string] $Message) { if (-not $Condition) { throw $Message }; $script:count++ }
function Reject([scriptblock] $Body) { $rejected=$false; try { & $Body | Out-Null } catch { $rejected=$true }; Expect $rejected 'Invalid input accepted' }
function Expect-SourceOrder([string] $Source,[string] $Before,[string] $After,[string] $Message) {
 $first=$Source.IndexOf($Before); $second=$Source.IndexOf($After)
 Expect ($first -ge 0 -and $second -ge 0 -and $first -lt $second) $Message
}
function Test-ElevationGuardOrder([string] $Source) {
 $tokens=$null; $errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
 $guards=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-DesktopSetupToken'},$true))
 $forms=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-Object' -and $node.CommandElements.Count -gt 1 -and $node.CommandElements[1].Extent.Text -eq 'Windows.Forms.Form'},$true))
 return $errors.Count -eq 0 -and $guards.Count -eq 1 -and $forms.Count -eq 1 -and $guards[0].Extent.StartOffset -lt $forms[0].Extent.StartOffset
}
$prefix=[byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
$key='ssh-ed25519 ' + [Convert]::ToBase64String([byte[]]($prefix + ([byte[]](1)*32)))
Expect ((Get-CanonicalPublicKey ($key + ' synthetic')) -ceq $key) 'Key canonicalization'
Expect ((Get-KeyFingerprint $key) -like 'SHA256:*') 'Fingerprint'
foreach ($ip in @('10.0.0.1','172.16.0.1','172.31.0.1','192.168.1.10','100.64.0.1','100.127.1.1','169.254.1.2')) { Expect ((Get-PrivateIPv4 $ip) -ceq $ip) 'Private address' }
foreach ($ip in @('8.8.8.8','127.0.0.1','0.0.0.0','192.168.01.1','100.128.1.1','172.32.0.1','::1','192.168.1.1/24','192.168.1.1 --arg')) { Reject { Get-PrivateIPv4 $ip } }
foreach ($bad in @('ssh-rsa AAAA','ssh-ed25519 AAAA',($key + "`nInjected"))) { Reject { Get-CanonicalPublicKey $bad } }
$request=@{kind='deskbridge.mac-setup';version=1;requestID='11111111-1111-4111-8111-111111111111';clientPublicKey=$key;allowedClientAddresses=@('192.168.1.10','100.80.1.2')}
$result=ConvertFrom-MacSetup ($request | ConvertTo-Json)
Expect ($result.allowedClientAddresses.Count -eq 2 -and $result.clientPublicKey -ceq $key) 'Request roundtrip'
$single=$request.Clone(); $single.allowedClientAddresses=@('192.168.1.10')
$singleResult=ConvertFrom-MacSetup ($single | ConvertTo-Json)
Expect ($singleResult.allowedClientAddresses.Count -eq 1 -and $singleResult.allowedClientAddresses[0] -ceq '192.168.1.10') 'Nested singleton address array must retain the one-address contract'
$scalar=$request.Clone(); $scalar.allowedClientAddresses='192.168.1.10'
Reject { ConvertFrom-MacSetup ($scalar | ConvertTo-Json) }
foreach ($entry in @(@('version',2),@('kind','other'),@('requestID','invalid'),@('command','whoami'),@('allowedClientAddresses',@('8.8.8.8')),@('allowedClientAddresses',@('10.0.0.1','10.0.0.1')))) {
 $invalid=$request.Clone(); $invalid[$entry[0]]=$entry[1]; Reject { ConvertFrom-MacSetup ($invalid | ConvertTo-Json) }
}
Reject { ConvertFrom-MacSetup (' '*16385) }
foreach ($version in @([int]1,[long]1)) {
 $parsed=$request.Clone(); $parsed.version=$version
 Expect ((ConvertFrom-MacSetup ($parsed | ConvertTo-Json)).version -eq 1) 'Integral version representation'
}
foreach ($version in @($true,'1',1.5)) {
 $invalid=$request.Clone(); $invalid.version=$version
 Reject {ConvertFrom-MacSetup ($invalid | ConvertTo-Json)}
}
Expect ((Get-ManagedDeploymentAction $true $true $true $true $true $true) -eq 'Reuse') 'Active unchanged deployment'
Expect ((Get-ManagedDeploymentAction $false $false $false $false $true $true) -eq 'Reactivate') 'Revoked retained deployment'
Expect ((Get-ManagedDeploymentAction $false $false $false $false $false $false) -eq 'Reactivate') 'Revoked deployment can change key/addresses'
Expect ((Get-ManagedDeploymentAction $true $true $false $false $true $true) -eq 'Reactivate') 'Stopped partial managed configuration'
Reject {Get-ManagedDeploymentAction $true $false $false $false $true $true}
Reject {Get-ManagedDeploymentAction $true $true $true $true $false $true}
Reject {Get-ManagedDeploymentAction $false $false $true $false $true $true}
Expect ((Get-ManagedDeploymentAction $false $false $false $false $true $true $false) -eq 'Reactivate') 'Prepared failed setup must validate on reactivation'
Reject {Get-ManagedDeploymentAction $true $true $true $true $true $true $false}
# SID shapes for broad groups/services and Entra users must not fall back to a local ACL grant.
foreach ($sid in @('S-1-1-0','S-1-5-32-545','S-1-5-18','S-1-12-1-1-2-3-4','invalid')) { Reject {Resolve-DesktopUser $sid} }
$expectedSSHD='C:\Windows\System32\OpenSSH\sshd.exe'
foreach ($path in @($expectedSSHD,('"' + $expectedSSHD + '"'),$expectedSSHD.ToLowerInvariant())) {
 Assert-OpenSSHServicePath ([pscustomobject]@{PathName=$path}) $expectedSSHD
 Expect $true 'Exact Windows OpenSSH service path accepted'
}
Reject {Assert-OpenSSHServicePath $null $expectedSSHD}
foreach ($path in @('C:\Other\sshd.exe',($expectedSSHD + ' -f C:\other.conf'),('"' + $expectedSSHD + '" -D'),('""' + $expectedSSHD + '""'),'')) {
 Reject {Assert-OpenSSHServicePath ([pscustomobject]@{PathName=$path}) $expectedSSHD}
}
# All lookups below are injected synthetic objects; never inspect a local account/token.
$retained=[pscustomobject]@{UserName='deskbridge-transfer';UserSid='S-1-5-21-111-222-333-1001'}
$matched=Resolve-ManagedTransferUser $retained {
 param($sid)
 if ($sid -cne 'S-1-5-21-111-222-333-1001') {throw 'Lookup must use the recorded SID'}
 [pscustomobject]@{Name='deskbridge-transfer';SID=[pscustomobject]@{Value=$sid};Enabled=$true}
}
Expect ($matched.SID.Value -ceq $retained.UserSid) 'Recorded name and SID resolve together'
$disabled=Resolve-ManagedTransferUser $retained {param($sid) [pscustomobject]@{Name='deskbridge-transfer';SID=[pscustomobject]@{Value=$sid};Enabled=$false}}
Expect (-not $disabled.Enabled -and $disabled.SID.Value -ceq $retained.UserSid) 'A disabled account with the retained SID remains a valid lifecycle identity'
# Deleted account, reused name/replacement SID, and renamed original account must all fail.
Reject {Resolve-ManagedTransferUser $retained {param($sid) throw 'Synthetic account not found'}}
Reject {Resolve-ManagedTransferUser $retained {param($sid) $null}}
Reject {Resolve-ManagedTransferUser $retained {param($sid) [pscustomobject]@{Name='deskbridge-transfer';SID=[pscustomobject]@{Value='S-1-5-21-111-222-333-1002'}}}}
Reject {Resolve-ManagedTransferUser $retained {param($sid) [pscustomobject]@{Name='renamed-transfer';SID=[pscustomobject]@{Value=$sid}}}}
$invalidIdentity=[pscustomobject]@{UserName='deskbridge-transfer';UserSid='S-1-5-18'}
$script:lookupTouched=$false
Reject {Resolve-ManagedTransferUser $invalidIdentity {$script:lookupTouched=$true; throw 'Unexpected lookup'}}
Expect (-not $script:lookupTouched) 'Invalid identity rejected before account lookup'
Assert-DesktopSetupToken { $false }
Expect $true 'Standard or filtered administrator token allowed'
Reject {Assert-DesktopSetupToken { $true }}
# Pure validation-scope fixtures: these paths and SDDL labels are never opened.
$directoryRecord=[pscustomobject]@{StateSDDL='synthetic-state-acl';ShareRoot='synthetic-share';ShareRootSDDL='synthetic-root-acl';FilesSDDL='synthetic-files-acl'}
$activation=@(Get-ManagedDirectoryRecords 'synthetic-state' $directoryRecord)
Expect ($activation.Count -eq 3 -and $activation[1].Path -ceq 'synthetic-share' -and $activation[2].Sddl -ceq 'synthetic-files-acl') 'Activation retains all recorded share directory checks'
$revocation=@(Get-ManagedDirectoryRecords 'synthetic-state' $directoryRecord -Revoke)
Expect ($revocation.Count -eq 1 -and $revocation[0].Path -ceq 'synthetic-state' -and $revocation[0].Sddl -ceq 'synthetic-state-acl') 'Revocation validates state without opening mutable shared directories'
$missingShare=[pscustomobject]@{StateSDDL='synthetic-state-acl'}
Expect (@(Get-ManagedDirectoryRecords 'synthetic-state' $missingShare -Revoke).Count -eq 1) 'Revocation directory selection never reads missing share fields'
# These static heuristics compare named guard/mutator offsets and account parameters.
# They do not prove full control flow or real Windows ACL/service behavior.
$root=Split-Path $PSScriptRoot -Parent
foreach ($entry in @(@('Disable-DeskBridgeSFTP.ps1','Stop-Service'),@('Resume-DeskBridgeSFTP.ps1','Disable-LocalUser'),@('Invoke-DeskBridgeSetup.ps1','Initialize-ConnectionExportDirectory'))) {
 $tokens=$null; $errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $entry[0]),[ref]$tokens,[ref]$errors)
 $preflight=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-ManagedDeployment'},$true))
 $isRevoke=@($preflight[0].CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Revoke'}).Count -ne 0
 Expect ($isRevoke -eq ($entry[0] -eq 'Disable-DeskBridgeSFTP.ps1')) ('Only revocation selects its narrower preflight: ' + $entry[0])
 $mutations=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $entry[1]},$true))
 Expect ($preflight.Count -eq 1 -and $mutations.Count -gt 0 -and $preflight[0].Extent.StartOffset -lt $mutations[0].Extent.StartOffset) ('Lifecycle preflight precedes mutation: ' + $entry[0])
 foreach ($command in $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Enable-LocalUser','Disable-LocalUser')},$true)) {
  $parameters=@($command.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]} | ForEach-Object {$_.ParameterName})
  Expect ('SID' -in $parameters -and 'Name' -notin $parameters) ('Lifecycle account mutation uses SID: ' + $entry[0])
 }
}
$disableSource=[IO.File]::ReadAllText((Join-Path $root 'Disable-DeskBridgeSFTP.ps1'))
Expect-SourceOrder $disableSource 'Stop-ManagedSessionWorkers' 'Knot access is already disabled.' 'Repeated revocation worker cleanup precedes its success message in source'
Expect-SourceOrder $disableSource 'Set-Service -Name sshd -StartupType $record.StartupBefore' 'Knot access is already disabled.' 'Repeated revocation startup restore precedes its success message in source'
$enableSource=[IO.File]::ReadAllText((Join-Path $root 'Enable-DeskBridgeSFTP.ps1'))
Expect-SourceOrder $enableSource 'Assert-ProtectedDirectory $sshDirectory' 'Get-WindowsCapability' 'Existing SSH directory check precedes optional-feature operations in source'
Expect-SourceOrder $enableSource 'Assert-ProtectedFile $keygen -WindowsBinary' '& $keygen -l' 'Key generator check precedes execution in source'
Expect-SourceOrder $enableSource 'Assert-ProtectedFile $sshd -WindowsBinary' '& $sshd -t' 'Server binary check precedes execution in source'
Expect-SourceOrder $enableSource 'Set-ManagedConfigAcl $config' '& $sshd -t' 'Published config protection precedes server validation in source'
Expect-SourceOrder $enableSource 'Assert-PrivateHostKey' 'Start-Service sshd' 'Host key permission checks precede activation in source'
$resumeSource=[IO.File]::ReadAllText((Join-Path $root 'Resume-DeskBridgeSFTP.ps1'))
Expect-SourceOrder $resumeSource 'Start-Service sshd' 'Set-Service -Name sshd -StartupType Automatic' 'Automatic startup follows successful reactivation in source'
Expect-SourceOrder $disableSource 'Stop-ManagedSessionWorkers -BeforeStop {' 'Stop-Service -Name sshd' 'Revocation service stop is inside the proven ownership transaction'
Expect-SourceOrder $resumeSource 'Stop-ManagedSessionWorkers -BeforeStop {' 'Disable-LocalUser -SID $user.SID' 'Reactivation ownership proof precedes its account mutation'
Expect ($enableSource.Contains("if (`$service.Status -ne 'Stopped') { throw")) 'Initial setup refuses an unexpectedly active service'
Expect ($enableSource.Contains('if ($startedService -or $wroteConfig) {') -and -not $enableSource.Contains('if ($createdState -or $startedService -or $wroteConfig) { Stop-Service')) 'A created state directory alone cannot authorize service stop'
Expect-SourceOrder $resumeSource 'Set-Service -Name sshd -StartupType $record.StartupBefore' "'sshd_config.failed-'" 'Failed reactivation restores startup before config archive in source'
Expect-SourceOrder $resumeSource 'Set-ManagedConfigAcl $config' '& $sshd -t' 'Restored config protection precedes server validation in source'
$gui=[IO.File]::ReadAllText((Join-Path $root 'Setup-DeskBridge.ps1'))
Expect (Test-ElevationGuardOrder $gui) 'Actual elevation guard command precedes the form creation command'
Expect (Test-ElevationGuardOrder ('Assert-DesktopSetupToken' + "`n" + '$form=New-Object Windows.Forms.Form')) 'Positive synthetic guard-order parser fixture'
foreach ($negative in @('$form=New-Object Windows.Forms.Form',('# Assert-DesktopSetupToken' + "`n" + '$form=New-Object Windows.Forms.Form'),('$form=New-Object Windows.Forms.Form' + "`n" + 'Assert-DesktopSetupToken'))) {
 Expect (-not (Test-ElevationGuardOrder $negative)) 'Missing, commented or late elevation guard rejected by parser fixture'
}
Expect-SourceOrder $gui '$expected=Read-MacSetup $requestPath' '$process=Start-Process -FilePath $elevatedExecutable -Verb RunAs' 'Request captured before native broker elevation in source'
Expect ($gui.Contains('$control -is [Windows.Forms.ComboBox]') -and $gui.Contains('$reply.address -cne $selectedAddress')) 'Busy controls and result comparison use the captured selection'
Expect ([regex]::Matches($gui,'\$null=\$process\.Handle').Count -eq 3 -and [regex]::Matches($gui,'\$null -eq \$process\.ExitCode').Count -eq 3) 'All three child process paths cache handles and reject missing exit codes'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
 $coreRejected=$false
 try { Initialize-ConnectionExportDirectory 'C:\SyntheticExportNeverCreated' }
 catch { $coreRejected=$_.Exception.Message -like '*Windows PowerShell 5.1 (Desktop)*' }
 Expect $coreRejected 'Core rejects export initialization at the explicit Desktop boundary before filesystem access'
}
# Exercise the actual metadata policy using projected ACL rules; no Windows ACL APIs.
function Synthetic-Ace([string] $Sid,[int] $Rights,[int] $Flags=0) {
 return [pscustomobject]@{IdentityReference=[pscustomobject]@{Value=$Sid};FileSystemRights=$Rights;PropagationFlags=$Flags;AccessControlType='Allow'}
}
$adminAce=Synthetic-Ace 'S-1-5-32-544' 2032127
$creatorOwner=Synthetic-Ace 'S-1-3-0' 0x10000000 2
$creatorGroup=Synthetic-Ace 'S-1-3-1' 0x10000000 2
Expect (Test-ManagedMetadataAcl 'S-1-5-32-544' @($adminAce,$creatorOwner)) 'Creator owner inherit-only generic-all is safe under protected child creation'
Expect (-not (Test-ManagedMetadataAcl 'S-1-5-32-544' @($adminAce,$creatorGroup))) 'Creator group inherit-only generic-all remains forbidden because the primary group may be untrusted'
Expect (-not (Test-ManagedMetadataAcl 'S-1-5-32-544' @($adminAce,(Synthetic-Ace 'S-1-1-0' 2 2)))) 'Untrusted inherit-only concrete write ACE remains forbidden'
Expect (-not (Test-ManagedMetadataAcl 'S-1-5-32-544' @($adminAce,(Synthetic-Ace 'S-1-1-0' 0x10000000)))) 'Effective untrusted generic-all remains forbidden'
Expect (-not (Test-ManagedMetadataAcl 'S-1-5-32-544' @($adminAce,(Synthetic-Ace 'S-1-1-0' 0x40000000)))) 'Effective untrusted generic-write remains forbidden'
Expect (-not (Test-ManagedMetadataAcl 'S-1-5-32-544' @($adminAce,$creatorOwner,(Synthetic-Ace 'S-1-1-0' 2)))) 'Creator placeholder never permits effective untrusted child creation'
Expect (-not (Test-ManagedMetadataAcl 'S-1-5-32-544' @($adminAce,(Synthetic-Ace 'S-1-3-0' 0x10000000)))) 'Effective creator generic-all is not skipped'
Expect (-not (Test-ManagedMetadataAcl 'S-1-5-21-1-2-3-1001' @($adminAce,$creatorOwner))) 'Untrusted metadata owner remains forbidden'
$setupAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-DeskBridgeSetup.ps1'),[ref]$tokens,[ref]$errors)
$successExits=@($setupAst.FindAll({param($node) $node -is [Management.Automation.Language.ExitStatementAst] -and $node.Pipeline.Extent.Text -ceq '0'},$true))
Expect ($successExits.Count -eq 3) 'All completed setup/no-op/revocation exits are enumerated'
foreach ($exit in $successExits) {
 $before=@($exit.Parent.Statements | Where-Object {$_.Extent.EndOffset -le $exit.Extent.StartOffset})
 Expect ($before.Count -gt 0 -and $before[-1].Extent.Text -ceq 'Write-SetupSuccessReceipt') 'Every success exit immediately follows fixed completion receipt creation'
}
$catchReceipt=@($setupAst.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Extent.Text.Contains('Write-SetupSuccessReceipt')},$true))
Expect ($catchReceipt.Count -eq 0) 'Error handling never publishes a success receipt'
$guiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Setup-DeskBridge.ps1'),[ref]$tokens,[ref]$errors)
$manualGuard=@($guiAst.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '-not $LauncherPath'},$true))
Expect ($manualGuard.Count -eq 1 -and $manualGuard[0].Clauses[0].Item2.Statements[-1] -is [Management.Automation.Language.ReturnStatementAst]) 'Manual GUI completion is explicitly unverified and returns'
Expect-SourceOrder $gui 'if (-not $LauncherPath)' '$replyPath=Join-Path' 'Manual GUI returns before reading or saving a potentially stale connection reply'
# These AST checks lock the export boundary without invoking any elevated script.
$moduleAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'SetupContract.psm1'),[ref]$tokens,[ref]$errors)
$initializer=@($moduleAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-ConnectionExportDirectory'},$true))[0]
$creates=@($initializer.FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'CreateDirectory'},$true))
Expect ($creates.Count -eq 1 -and $creates[0].Arguments.Count -eq 2) 'Export creation passes its final ACL to Framework CreateDirectory'
$repairs=@($initializer.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('New-Item','Set-Acl')},$true))
Expect ($repairs.Count -eq 0) 'Export initialization never creates then repairs or re-ACLs existing output'
$protectedChecks=@($initializer.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-ProtectedDirectory'},$true))
Expect ($protectedChecks.Count -eq 2 -and $protectedChecks[0].Extent.StartOffset -lt $creates[0].Extent.StartOffset -and $protectedChecks[1].Extent.StartOffset -gt $creates[0].Extent.StartOffset) 'Existing and raced-new export directories both require protected validation'
$exportSource=[IO.File]::ReadAllText((Join-Path $root 'Invoke-DeskBridgeSetup.ps1'))
Expect-SourceOrder $exportSource 'Initialize-ConnectionExportDirectory $output' '[IO.File]::WriteAllText($staging' 'Export directory/old connection validation precedes staging write'
Expect ($initializer.Extent.Text.Contains('Assert-ProtectedFile $target') -and $initializer.Extent.Text.Contains('DeleteSubdirectoriesAndFiles') -and $initializer.Extent.Text.Contains('Assert-NoReparsePath $parent.FullName')) 'Export target and ancestor rename/reparse guards remain active'
# Source guards complement actual synthetic firewall cleanup tests; never run privileged setup.
Expect-SourceOrder $exportSource "'Disable-DeskBridgeSFTP.ps1') -Apply" 'File access inactivity could not be verified after revocation.' 'Actual revocation must re-inspect inactivity before attesting completion'
$revocationTail=$exportSource.Substring($exportSource.IndexOf("'Disable-DeskBridgeSFTP.ps1') -Apply"))
Expect-SourceOrder $revocationTail 'File access inactivity could not be verified after revocation.' 'Write-SetupSuccessReceipt' 'Failed post-revocation inspection must precede its completion receipt'
$enableAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Enable-DeskBridgeSFTP.ps1'),[ref]$tokens,[ref]$errors)
$moduleAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'SetupContract.psm1'),[ref]$tokens,[ref]$errors)
$protectedCompiler=@($moduleAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ProtectedCompilation'},$true))[0]
$compilerSource=$protectedCompiler.Extent.Text
$compiles=@($moduleAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type'},$true))
Expect ($compiles.Count -eq 1 -and $compiles[0].Extent.Text.StartsWith('Add-Type -CompilerParameters $compilerOptions -TypeDefinition')) 'All privileged compilation uses one protected compiler helper'
Expect-SourceOrder $compilerSource '[IO.Directory]::CreateDirectory($compilerDirectory,$compilerAcl)' 'Add-Type -CompilerParameters' 'Compiler scratch final ACL precedes compilation'
Expect-SourceOrder $compilerSource "SetEnvironmentVariable('TEMP',`$compilerDirectory,'Process')" 'Add-Type -CompilerParameters' 'Compiler child TEMP uses only the private directory'
Expect ($compilerSource.Contains('TempFiles=New-Object CodeDom.Compiler.TempFileCollection($compilerDirectory,$false)') -and $compilerSource.Contains("SetEnvironmentVariable('TEMP',`$priorTemp,'Process')") -and $compilerSource.Contains("SetEnvironmentVariable('TMP',`$priorTmp,'Process')") -and $compilerSource.Contains('[IO.Directory]::Delete($compilerDirectory,$false)')) 'Compiler tracks private scratch, restores environment, cleans only owned files'
Expect ($enableSource.Contains('Invoke-ProtectedCompilation -TypeDefinition')) 'Share helper reuses the protected compiler boundary'
# Pure UI policy fixtures: no form, process, token, installer, or device API is used.
$syntheticError=[pscustomobject]@{Exception=[Exception]::new('synthetic platform failure')}
Expect ((Get-SetupFailureText $syntheticError) -notmatch '네트워크') 'Unknown failures must not be classified as network errors'
$koreanError=[pscustomobject]@{Exception=[Exception]::new('합성 오류 안내')}
Expect ((Get-SetupFailureText $koreanError) -notmatch '합성 오류') 'Unknown Korean failures do not become authored guidance'
$pathError=[pscustomobject]@{Exception=(New-Object UnauthorizedAccessException "'C:\Users\합성사용자\x' 경로에 대한 액세스가 거부되었습니다.")}
Expect ((Get-SetupFailureText $pathError) -notmatch '합성사용자|C:\\') 'Localized OS paths must not reach setup guidance'
$authored='Sunshine 설치 파일 정보가 올바르지 않습니다. 새 Knot 배포 파일을 사용하세요.'
try { throw $authored } catch { $authoredError=$_ }
Expect ((Get-SetupFailureText $authoredError) -ceq $authored) 'Exact authored script guidance is preserved'
$downloadText='60초 동안 다운로드가 진행되지 않았습니다. 네트워크를 확인한 뒤 다시 시도하세요.'
$downloadError=[pscustomobject]@{Exception=(New-Object InvalidOperationException 'synthetic wrapper',(New-Object TimeoutException $downloadText))}
Expect ((Get-SetupFailureText $downloadError) -ceq $downloadText) 'Exact authored downloader guidance survives wrappers'
Expect ((Get-SetupFailureText $syntheticError -Context VirtualDisplay) -match '가상 화면.*복구 기록' -and (Get-SetupFailureText $syntheticError -Context VirtualDisplay) -notmatch '네트워크|OpenSSH') 'Unknown display failures retain display-specific recovery guidance'
Expect ((Get-SetupFailureText $downloadError -Context VirtualDisplay) -ceq $downloadText) 'Known download failures retain their specific guidance in display setup'
Expect ((Get-SetupFailureText $syntheticError -Context DesktopUser) -match '로컬.*Entra') 'Desktop identity refusal explains the supported account type'
Expect ((Get-SetupFailureText $syntheticError -Context ElevatedToken) -match 'UAC.*Administrator') 'Elevated startup refusal explains environments without a filtered token'
$cancelledError=[pscustomobject]@{Exception=[Exception]::new('synthetic wrapper',[ComponentModel.Win32Exception]::new(1223))}
Expect ((Get-SetupFailureText $cancelledError) -match '취소') 'Nested UAC cancellation retains cancellation guidance'
foreach ($case in @(@(0,'Installed'),@(1602,'Cancelled'),@(1618,'Retry'),@(1641,'RestartInitiated'),@(3010,'RestartRequired'),@(1603,'Failed'),@($null,'Failed'))) {
    $result=Get-SunshineInstallResult -ExitCode $case[0]
    Expect ($result.State -ceq $case[1] -and $result.Text -match '[가-힣]') ('MSI outcome: '+$case[0])
}
Expect ((Get-SunshineInstallResult 2 -Broker).State -ceq 'HandledFailure') 'Only broker exit 2 means the failure was already displayed'
Expect ((Get-SunshineInstallResult 2).State -ceq 'Failed') 'Raw MSI exit 2 does not attest a displayed error'
Expect ((Get-SunshineInstallResult 1618 -Broker).Text -match '다른 Windows 설치') 'Installer contention tells the user which work to wait for'
$statusFixture=[pscustomobject]@{StoredText='download 0%';WriteCount=0}
$statusFixture | Add-Member -MemberType ScriptProperty -Name Text -Value {$this.StoredText} -SecondValue {param($value) $this.StoredText=[string]$value; $this.WriteCount++}
1..50 | ForEach-Object { Set-SetupStatusText $statusFixture 'download 0%' }
Expect ($statusFixture.WriteCount -eq 0) 'Repeated integer-percent polls preserve the existing status control value'
Set-SetupStatusText $statusFixture 'download 1%'
Set-SetupStatusText $statusFixture 'verify 1%'
Expect ($statusFixture.WriteCount -eq 2 -and $statusFixture.Text -ceq 'verify 1%') 'Percent and phase changes each update status exactly once'
Expect (-not (Test-KnotHeadlessDeviceProbeRequired 'Absent' $false)) 'Absent and policy-blocked setup skips native initialization/probing'
Expect (Test-KnotHeadlessDeviceProbeRequired 'Absent' $true) 'An allowed install still requires the native device probe'
foreach ($state in @('Installed','InstalledPendingRestart','RemovalPending','RecoveryRequired','Conflict','Unknown')) {
    Expect (Test-KnotHeadlessDeviceProbeRequired $state $false) ('A non-absent state cannot bypass the existing device identity gate: '+$state)
}
Expect ((Get-KnotHeadlessAvailabilityText 'manifest-invalid') -match '새 Knot 배포') 'Invalid package metadata has distinct recovery guidance'
Expect ((Get-KnotHeadlessAvailabilityText 'upstream-ipc-review') -match '보안 검토') 'Driver policy hold keeps its existing explanation'
# Parse every shipped PowerShell file, without running the GUI or elevated backend.
$repository=Split-Path (Split-Path $root -Parent) -Parent
foreach ($scriptRoot in @($root,(Join-Path $repository 'scripts'),(Join-Path $repository 'packaging'))) {
 foreach ($file in Get-ChildItem -LiteralPath $scriptRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') }) {
  # Windows PowerShell 5.1 treats BOM-less source as ANSI. Require explicit
  # UTF-8 for translated text before parsing, including installer tooling.
  $bytes=[IO.File]::ReadAllBytes($file.FullName); $asciiOnly=$true
  foreach ($byte in $bytes) { if ($byte -gt 127) { $asciiOnly=$false; break } }
  $utf8Bom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
  Expect ($asciiOnly -or $utf8Bom) ('PowerShell 5.1 source encoding: ' + $file.Name)
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
  Expect ($errors.Count -eq 0) ('PowerShell parse: ' + $file.Name)
 }
}
@{status='passed';checks=$count;scope='pure synthetic contract and syntax checks, no Windows configuration or GUI'} | ConvertTo-Json

# Compile the actual native definition without calling any Windows native function.
# This also runs on Windows PowerShell 5.1 CI; no protected production compiler path is invoked.
$moduleAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'SetupContract.psm1'),[ref]$null,[ref]$null)
$initializer=$moduleAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Initialize-ManagedWorkerHandle'},$true)
$nativeDefinition=$initializer.Find({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -eq 'SingleQuotedHereString'},$true)
Expect ($null -ne $nativeDefinition) 'Native ownership definition is present in the actual source'
if (-not ('DeskBridge.ManagedWorkerHandle' -as [type])) {Add-Type -TypeDefinition $nativeDefinition.Value -ErrorAction Stop}
$nativeType='DeskBridge.ManagedWorkerHandle' -as [type]
$basic=$nativeType.GetNestedType('BasicInformation',[Reflection.BindingFlags]::NonPublic)
$expectedSize=if ([IntPtr]::Size -eq 8) {48} else {24}
Expect ([Runtime.InteropServices.Marshal]::SizeOf([type]$basic) -eq $expectedSize) 'Native process basic information matches the active x86/x64 ABI size'
$offsets=if ([IntPtr]::Size -eq 8) {@(0,8,16,24,32,40)} else {@(0,4,8,12,16,20)}
$nativeFields=@('ExitStatus','PebBaseAddress','AffinityMask','BasePriority','UniqueProcessId','InheritedFromUniqueProcessId')
for ($i=0;$i -lt $nativeFields.Count;$i++) {
 Expect ([Runtime.InteropServices.Marshal]::OffsetOf([type]$basic,$nativeFields[$i]).ToInt32() -eq $offsets[$i]) ('Native ownership ABI offset: '+$nativeFields[$i])
}
# Fixed-width inert copies check both layouts even when the runner has one architecture.
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct KnotOwnershipLayout32 {
 public int ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId;
}
[StructLayout(LayoutKind.Sequential)] public struct KnotOwnershipLayout64 {
 public int ExitStatus; public long PebBaseAddress, AffinityMask;
 public int BasePriority; public long UniqueProcessId, InheritedFromUniqueProcessId;
}
'@
Expect ([Runtime.InteropServices.Marshal]::SizeOf([type][KnotOwnershipLayout32]) -eq 24) 'Inert x86 process basic information layout'
Expect ([Runtime.InteropServices.Marshal]::SizeOf([type][KnotOwnershipLayout64]) -eq 48) 'Inert x64 process basic information layout'

function Reject-NativeOwnershipGuard([scriptblock] $Body,[string] $ExpectedMessage,[string] $Boundary) {
 $failure=$null
 try {& $Body | Out-Null} catch {
  $failure=$_.Exception
  while ($failure.InnerException) {$failure=$failure.InnerException}
 }
 Expect ($failure -is [InvalidOperationException] -and $failure.Message -ceq $ExpectedMessage) ('Actual native ownership guard did not reject at '+$Boundary)
}
# Member-access property reads suppress .NET getter exceptions in PowerShell.
# Invoke the actual getter METHOD so the assertion observes its precise guard,
# rather than mistaking a silent null result or a binder error for a rejection.
$closedProbe=New-Object DeskBridge.ManagedWorkerHandle
try {
 $closedProbe.Dispose()
 Reject-NativeOwnershipGuard {$closedProbe.get_Alive()} 'OpenSSH ownership handle is closed.' 'fresh empty/disposed handle'
} finally {$closedProbe.Dispose()}

# On Windows only, exercise the actual native class against one NEW child owned by
# this test process. Never inspect sshd/CIM/services/accounts/firewall or existing PIDs.
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
 $nativeFixtureTimer=[Diagnostics.Stopwatch]::StartNew()
 $childScript=Join-Path ([IO.Path]::GetTempPath()) ('knot-owned-native-child-'+[guid]::NewGuid().ToString('N')+'.ps1')
 $childScriptCreated=$false;$ownedChild=$null;$ownedHandle=$null;$childStarted=$false
 try {
  $stream=[IO.File]::Open($childScript,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $childScriptCreated=$true
  try {
   $bytes=[Text.Encoding]::UTF8.GetBytes('Start-Sleep -Seconds 18')
   $stream.Write($bytes,0,$bytes.Length)
  } finally {$stream.Dispose()}
  $currentHost=[Diagnostics.Process]::GetCurrentProcess()
  try {$hostExecutable=$currentHost.MainModule.FileName} finally {$currentHost.Dispose()}
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=$hostExecutable
  $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$childScript+'"'
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $ownedChild=New-Object Diagnostics.Process;$ownedChild.StartInfo=$start
  if (-not $ownedChild.Start()) {throw 'Could not start the fresh native ownership child fixture'}
  $childStarted=$true
  $ownedHandle=[DeskBridge.ManagedWorkerHandle]::Capture([uint32]$ownedChild.Id,$hostExecutable)
  Expect ($ownedHandle.ProcessId -eq $ownedChild.Id -and $ownedHandle.ParentProcessId -eq [uint32]$PID -and $ownedHandle.CreatedFileTime -gt 0 -and $ownedHandle.Alive) 'Actual Windows native capture binds the fresh child PID, current test parent, creation time, image and liveness'
  Reject-NativeOwnershipGuard {[DeskBridge.ManagedWorkerHandle]::Capture([uint32]$ownedChild.Id,'C:\SyntheticWrongImage\sshd.exe')} 'OpenSSH worker identity changed.' 'fresh child wrong expected image'
  Expect (-not $ownedChild.HasExited -and $ownedHandle.Alive) 'Rejecting a wrong expected image never terminates the fresh child'
  $ownedHandle.Stop()
  Expect ($ownedChild.WaitForExit(5000) -and -not $ownedHandle.Alive) 'Actual native stop terminates only the same held test-child object'
  $ownedHandle.Dispose()
  Reject-NativeOwnershipGuard {$ownedHandle.get_Alive()} 'OpenSSH ownership handle is closed.' 'disposed held child handle'
 } finally {
  if ($ownedHandle) {$ownedHandle.Dispose()}
  if ($ownedChild) {
   try {
    # This Process instance retains the handle obtained from Start; never reopen a PID.
    if ($childStarted -and -not $ownedChild.HasExited) {$ownedChild.Kill();[void]$ownedChild.WaitForExit(5000)}
   } finally {$ownedChild.Dispose()}
  }
  if ($childScriptCreated) {[IO.File]::Delete($childScript)}
 }
 $nativeFixtureTimer.Stop()
 Expect ($nativeFixtureTimer.Elapsed.TotalSeconds -lt 30) 'Native owned-child fixture completes within its bounded lifetime'
 Write-Output 'Native worker handle fixture: passed on Windows using one fresh owned child only'
} else {
 Write-Output 'Native worker handle fixture: skipped (Windows APIs unavailable); actual definition compilation and ABI projections passed'
}

# Actual transaction with wholly inert service/process inventories and held-handle projections.
# No Get-CimInstance, Stop-Service, process termination or native API is called by these fixtures.
function New-OwnershipWorker([uint32] $Id,[uint32] $Parent,[long] $Created,[string] $Name='sshd.exe') {
 [pscustomobject]@{Name=$Name;ExecutablePath=('C:\Windows\System32\OpenSSH\'+$Name);ProcessId=$Id;
  NativeParent=$Parent;NativeCreated=$Created;NativeAlive=$true;CommandLine='unused: never an ownership signal'}
}
function Invoke-OwnershipFixture([hashtable] $Case) {
 $service=[pscustomobject]@{Name='sshd';State='Running';ProcessId=[uint32]100;PathName='C:\Windows\System32\OpenSSH\sshd.exe'}
 $workers=@((New-OwnershipWorker 100 4 1000),(New-OwnershipWorker 101 100 2000 'sshd-session.exe'),(New-OwnershipWorker 102 101 3000 'sshd-auth.exe'))
 if ($Case.ContainsKey('Workers')) {$workers=@($Case.Workers)}
 if ($Case.ContainsKey('Stopped') -and $Case.Stopped) {$service.State='Stopped';$service.ProcessId=[uint32]0}
 $script:ownership=[pscustomobject]@{Case=$Case;Service=$service;Workers=$workers;InventoryCalls=0;ServiceCalls=0;
  Captured=@();Terminated=@();Released=@();BeforeCalls=0;Events=@();Succeeded=$false;Error=''}
 try {
  Stop-ManagedSessionWorkers -WindowsDirectory 'C:\Windows' -BeforeStop {
   $o=$script:ownership; $o.BeforeCalls++; $o.Events+=@('before-stop')
   $o.Service.State='Stopped'; $o.Service.ProcessId=[uint32]0
   if ($o.Case.ContainsKey('BeforeFailure')) {throw 'synthetic stop callback failure'}
  } -Inventory {
   $o=$script:ownership; $o.InventoryCalls++
   if ($o.InventoryCalls -eq 1) {
    if ($o.Case.ContainsKey('InventoryFailure')) {throw 'synthetic inventory denied'}
    return $o.Workers
   }
   if ($o.Case.ContainsKey('PostInventoryFailure')) {throw 'synthetic post inventory denied'}
   if ($o.Case.ContainsKey('PostWorkers')) {return $o.Case.PostWorkers}
  } -ServiceInventory {
   $o=$script:ownership; $o.ServiceCalls++
   if ($o.Case.ContainsKey('MissingService')) {return}
   if ($o.ServiceCalls -eq 2) {
    if ($o.Case.ContainsKey('RecheckPid')) {$o.Service.ProcessId=[uint32]200}
    if ($o.Case.ContainsKey('RecheckPath')) {$o.Service.PathName='C:\Other\sshd.exe'}
    if ($o.Case.ContainsKey('RecheckState')) {$o.Service.State='Stopped';$o.Service.ProcessId=[uint32]0}
    if ($o.Case.ContainsKey('RecheckExit')) {$o.Captured[0].Alive=$false}
   }
   if ($o.ServiceCalls -eq 3 -and $o.Case.ContainsKey('PostServiceActive')) {$o.Service.State='Running';$o.Service.ProcessId=[uint32]200}
   # Project a value snapshot, matching fresh CIM instances rather than a shared mutable object.
   [pscustomobject]@{Name=$o.Service.Name;State=$o.Service.State;ProcessId=$o.Service.ProcessId;PathName=$o.Service.PathName}
  } -Capture {
   param($worker)
   $o=$script:ownership
   if ($o.Case.ContainsKey('CaptureFailure') -and $worker.ProcessId -eq 101) {throw 'synthetic handle open denied'}
   $identity=[pscustomobject]@{ProcessId=$worker.ProcessId;ParentProcessId=$worker.NativeParent;CreatedFileTime=[long]$worker.NativeCreated;
    ExecutablePath=$worker.ExecutablePath;Alive=$worker.NativeAlive;Token=[guid]::NewGuid().ToString('N')}
   if ($o.Case.ContainsKey('CapturePidMismatch') -and $worker.ProcessId -eq 101) {$identity.ProcessId=[uint32]201}
   if ($o.Case.ContainsKey('CaptureImageMismatch') -and $worker.ProcessId -eq 101) {$identity.ExecutablePath='C:\Other\sshd.exe'}
   $o.Captured+=@($identity); $o.Events+=@('capture-'+$worker.ProcessId)
   $identity
  } -Terminate {
   param($identity)
   $o=$script:ownership
   if ($o.BeforeCalls -ne 1) {throw 'Termination preceded ownership preflight/stop callback'}
   $held=@($o.Captured | Where-Object {$_.Token -ceq $identity.Token})
   if ($held.Count -ne 1 -or -not [object]::ReferenceEquals($held[0],$identity)) {throw 'Termination reopened or replaced the held object'}
   $o.Terminated+=@($identity);$o.Events+=@('terminate-'+$identity.ProcessId)
   if ($o.Case.ContainsKey('TerminateFailure')) {throw 'synthetic termination denied'}
  } -Release {
   param($identity)
   $o=$script:ownership;$o.Released+=@($identity);$o.Events+=@('release-'+$identity.ProcessId)
  }
  $script:ownership.Succeeded=$true
 } catch {$script:ownership.Error=$_.Exception.Message}
 return $script:ownership
}
$owned=Invoke-OwnershipFixture @{}
Expect ($owned.Succeeded -and $owned.BeforeCalls -eq 1 -and $owned.InventoryCalls -eq 2 -and $owned.ServiceCalls -eq 3) 'Proven live service transaction requires final worker and service inventories'
Expect (($owned.Terminated.ProcessId -join ',') -ceq '102,101,100') 'Held descendants stop before their service root'
Expect ($owned.Captured.Count -eq 3 -and $owned.Released.Count -eq 3) 'Every captured process object is released after successful termination'
$permuted=Invoke-OwnershipFixture @{Workers=@((New-OwnershipWorker 102 101 3000 'sshd-auth.exe'),(New-OwnershipWorker 101 100 2000 'sshd-session.exe'),(New-OwnershipWorker 100 4 1000))}
Expect ($permuted.Succeeded -and $permuted.Captured[0].ProcessId -eq 100) 'Service handle is captured first regardless of inventory order'
$stopped=Invoke-OwnershipFixture @{Stopped=$true;Workers=@()}
Expect ($stopped.Succeeded -and $stopped.BeforeCalls -eq 1 -and $stopped.Captured.Count -eq 0) 'A stopped service with no workers may finish the verified transaction'
$foreign=New-OwnershipWorker 200 44 4000
$foreign.CommandLine='sshd.exe -f C:\independent.conf -p 2222'
$cases=@(
 @{Name='independent same-system-binary alternate config';Workers=@((New-OwnershipWorker 100 4 1000),$foreign)},
 @{Name='independent daemon with an identical command line';Workers=@((New-OwnershipWorker 100 4 1000),(New-OwnershipWorker 200 44 4000))},
 @{Name='stopped service with a remnant';Stopped=$true;Workers=@((New-OwnershipWorker 101 100 2000 'sshd-session.exe'))},
 @{Name='missing live service root';Workers=@((New-OwnershipWorker 101 100 2000 'sshd-session.exe'))},
 @{Name='missing intermediate ancestor';Workers=@((New-OwnershipWorker 100 4 1000),(New-OwnershipWorker 102 101 3000 'sshd-auth.exe'))},
 @{Name='orphan whose parent PID is absent';Workers=@((New-OwnershipWorker 100 4 1000),(New-OwnershipWorker 102 999 3000 'sshd-auth.exe'))},
 @{Name='reused parent PID is younger than the child';Workers=@((New-OwnershipWorker 100 4 3000),(New-OwnershipWorker 101 100 2000 'sshd-session.exe'))},
 @{Name='equal creation times cannot prove ancestry';Workers=@((New-OwnershipWorker 100 4 1000),(New-OwnershipWorker 101 100 1000 'sshd-session.exe'))},
 @{Name='cyclic ancestry';Workers=@((New-OwnershipWorker 100 4 1000),(New-OwnershipWorker 101 102 2000),(New-OwnershipWorker 102 101 3000))},
 @{Name='duplicate PID';Workers=@((New-OwnershipWorker 100 4 1000),(New-OwnershipWorker 101 100 2000),(New-OwnershipWorker 101 100 2000))},
 @{Name='worker inventory denied';InventoryFailure=$true},@{Name='service inventory absent';MissingService=$true},
 @{Name='kernel handle capture denied';CaptureFailure=$true},@{Name='PID changed during capture';CapturePidMismatch=$true},
 @{Name='image changed during capture';CaptureImageMismatch=$true},@{Name='service PID changed before stop';RecheckPid=$true},
 @{Name='service image changed before stop';RecheckPath=$true},@{Name='service stopped before ownership completed';RecheckState=$true},
 @{Name='held ancestor exited before stop';RecheckExit=$true}
)
foreach ($invalid in $cases) {
 $result=Invoke-OwnershipFixture $invalid
 Expect (-not $result.Succeeded -and $result.BeforeCalls -eq 0 -and $result.Terminated.Count -eq 0) ('Ambiguous ownership refuses before any stop callback: '+$invalid.Name)
 Expect ($result.Released.Count -eq $result.Captured.Count) ('Every partial capture is released after refusal: '+$invalid.Name)
}
$badPath=New-OwnershipWorker 101 100 2000;$badPath.ExecutablePath='C:\Other\sshd.exe'
$badPid=New-OwnershipWorker 101 100 2000;$badPid.ProcessId=0
$noImage=New-OwnershipWorker 101 100 2000;$noImage.ExecutablePath=$null
$dead=New-OwnershipWorker 101 100 2000;$dead.NativeAlive=$false
foreach ($invalid in @($badPath,$badPid,$noImage,$dead)) {
 $result=Invoke-OwnershipFixture @{Workers=@((New-OwnershipWorker 100 4 1000),$invalid)}
 Expect (-not $result.Succeeded -and $result.BeforeCalls -eq 0 -and $result.Terminated.Count -eq 0) 'Malformed or exited worker never authorizes mutation'
 Expect ($result.Released.Count -eq $result.Captured.Count) 'Malformed worker failure releases every opened object'
}
foreach ($failure in @(@{BeforeFailure=$true},@{TerminateFailure=$true},@{PostInventoryFailure=$true},@{PostServiceActive=$true},@{PostWorkers=@((New-OwnershipWorker 101 100 2000 'sshd-session.exe'))})) {
 $result=Invoke-OwnershipFixture $failure
 Expect (-not $result.Succeeded -and $result.BeforeCalls -eq 1) 'A failed stop or failed final inactivity projection cannot report completion'
 Expect ($result.Released.Count -eq $result.Captured.Count) 'Stop/post-inventory failure releases all held objects'
}
$newWorker=Invoke-OwnershipFixture @{PostWorkers=@($foreign)}
Expect (-not $newWorker.Succeeded -and $newWorker.Terminated.Count -eq 3 -and 200 -notin $newWorker.Terminated.ProcessId) 'A newly observed independent worker is never adopted or terminated and prevents completion'
Reject {Stop-ManagedSessionWorkers -BeforeStop {} -WindowsDirectory 'C:\Windows' -Inventory {throw 'synthetic inventory denied'} -ServiceInventory {[pscustomobject]@{Name='sshd';State='Stopped';ProcessId=[uint32]0;PathName='C:\Windows\System32\OpenSSH\sshd.exe'}} -Terminate {param($item)}}
Write-Output ('Worker ownership synthetic checks completed; total checks: ' + $count)

# Query only the managed rule; classify provider-generated absence, never access/store errors.
$script:firewallMode='present'; $script:queriedName=''
function global:Get-NetFirewallRule {
    param($Name,$PolicyStore,$ErrorAction)
    $script:queriedName=$Name
    if ($script:firewallMode -eq 'missing') {
        $errorRecord=New-Object Management.Automation.ErrorRecord((New-Object Exception('synthetic absent')),'CmdletizationQuery_NotFound_Name,Get-NetFirewallRule','ObjectNotFound',$null)
        throw $errorRecord
    }
    if ($script:firewallMode -eq 'denied') { throw 'synthetic access denied' }
    [pscustomobject]@{Name='DeskBridge-SFTP-In-TCP'}
}
Expect (@(Get-NamedManagedFirewallRules PersistentStore).Count -eq 1 -and $script:queriedName -eq 'DeskBridge-SFTP-In-TCP') 'Firewall lookup is named, not a whole-store enumeration'
$script:firewallMode='missing'
Expect (@(Get-NamedManagedFirewallRules ActiveStore).Count -eq 0) 'Named absent rule returns no rules'
$script:firewallMode='denied'
Reject {Get-NamedManagedFirewallRules ActiveStore}
Remove-Item Function:global:Get-NetFirewallRule
Write-Output ('Final synthetic contract checks: ' + $count)

# Actual local-export helper with inert dialogs and only fresh synthetic files.
$exportFixture=Join-Path ([IO.Path]::GetTempPath()) ('deskbridge-export-check-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($exportFixture) | Out-Null
try {
    foreach ($mode in @('save','cancel','failure')) {
        $target=Join-Path $exportFixture ($mode+'.json')
        if ($mode -eq 'failure') {
            $blocker=Join-Path $exportFixture 'synthetic-file-not-folder'
            [IO.File]::WriteAllText($blocker,'synthetic blocker')
            $target=Join-Path $blocker 'reply.json'
        }
        $dialog=[pscustomobject]@{FileName=$target;Result=$(if ($mode -eq 'cancel') {'Cancel'} else {'OK'});Disposed=$false}
        $dialog | Add-Member ScriptMethod ShowDialog {return $this.Result}
        $dialog | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $outcome=Save-DeskBridgeConnectionReply -Reply ([pscustomobject]@{kind='synthetic-public-reply'}) -Dialog $dialog
        $expected=if ($mode -eq 'save') {'Saved'} elseif ($mode -eq 'cancel') {'Cancelled'} else {'Failed'}
        Expect ($outcome -ceq $expected -and $dialog.Disposed) 'Export distinguishes save/cancel/local write failure and always disposes'
        if ($mode -eq 'save') { Expect (([IO.File]::ReadAllText($target) | ConvertFrom-Json).kind -ceq 'synthetic-public-reply') 'Actual export helper wrote synthetic reply' }
        else { Expect (-not [IO.File]::Exists($target)) 'Cancel/failure did not publish a local export' }
    }
} finally { [IO.Directory]::Delete($exportFixture,$true) }
Write-Output ('Final export + contract checks: ' + $count)

# The reactivation fixture runs the actual script control flow through inert platform seams.
& (Join-Path $PSScriptRoot 'Test-SFTPReactivation.ps1')

# Global serialization is exercised only with inert factories or fresh GUID test names.
& (Join-Path $PSScriptRoot 'Test-LifecycleLease.ps1')

# Bounded loopback startup/open/PIN checks use fake transports and inert UI leaves.
# This suite therefore runs under both existing Windows PowerShell 5.1 and PS7 CI lanes.
& (Join-Path $PSScriptRoot 'Test-SetupReadiness.ps1')
& (Join-Path $PSScriptRoot 'Test-Enrollment.ps1')
