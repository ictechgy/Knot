#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Run only the ACTUAL catch body in fresh synthetic child scripts, never the privileged setup script.
$ErrorActionPreference='Stop'
$count=0
function Expect([bool] $Condition,[string] $Message) {if (-not $Condition) {throw $Message}; $script:count++}
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-DeskBridgeSetup.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
$handlers=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Extent.Text.Contains('Setup failed. Press Enter')},$true))
Expect ($errors.Count -eq 0 -and $handlers.Count -eq 1) 'The actual setup error handler must be uniquely identified'
$directory=Join-Path ([IO.Path]::GetTempPath()) ('deskbridge-setup-exit-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
try {
 $fixture=Join-Path $directory 'synthetic-handler.ps1'
 $prefix=@'
param([switch] $NoPause,[switch] $FailAck,[switch] $FailDisplay)
$ErrorActionPreference='Stop'
$script:leaseReleased=$false
$lifecycleLease=New-Object PSObject
$lifecycleLease | Add-Member -MemberType ScriptMethod -Name Dispose -Value {$script:leaseReleased=$true}
function Assert-LeaseReleased {if (-not $script:leaseReleased -or $null -ne $lifecycleLease) {throw 'synthetic lifecycle lease retained during failure UI'}}
function Write-Host { param($Object,$ForegroundColor) Assert-LeaseReleased; if ($FailDisplay) {throw 'synthetic display failure'}; [Console]::Out.WriteLine('synthetic-displayed') }
function Read-Host { param($Prompt) Assert-LeaseReleased; if ($FailAck) {throw 'synthetic acknowledgement failure'}; [Console]::Out.WriteLine('synthetic-acknowledged'); return 'ack' }
try {throw 'synthetic setup failure'} catch
'@
 [IO.File]::WriteAllText($fixture,$prefix+$handlers[0].Body.Extent.Text,(New-Object Text.UTF8Encoding($false)))
 foreach ($case in @(@('',2,$true,$true),@('-NoPause',1,$true,$false),@('-FailAck',1,$true,$false),@('-FailDisplay',1,$false,$false))) {
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $start.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$fixture+'" '+$case[0]
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $child=[Diagnostics.Process]::Start($start)
  try {
   $output=$child.StandardOutput.ReadToEnd();$errorOutput=$child.StandardError.ReadToEnd()
   if (-not $child.WaitForExit(10000)) {$child.Kill();throw 'Synthetic handler timed out'}
   Expect ($child.ExitCode -eq $case[1]) 'Only displayed and acknowledged interactive failures may return handled exit 2'
   Expect ($output.Contains('synthetic-displayed') -eq $case[2]) 'Displayed-error marker changed'
   Expect ($output.Contains('synthetic-acknowledged') -eq $case[3]) 'Acknowledgement marker changed'
  } finally {$child.Dispose()}
 }
 # Run the actual receipt helper in the same fresh fixture. No real setup commands are present.
 $helpers=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-SetupSuccessReceipt'},$true))
 Expect ($helpers.Count -eq 1) 'The actual receipt helper is uniquely identified'
 $receiptFixture=Join-Path $directory 'synthetic-receipt.ps1'
 $receiptPath=Join-Path $directory 'operation-success'
 $receiptSource='param([switch] $SuccessReceipt)' + "`n" + '$ErrorActionPreference=''Stop''' + "`n" + $helpers[0].Extent.Text + "`nWrite-SetupSuccessReceipt`n"
 [IO.File]::WriteAllText($receiptFixture,$receiptSource,(New-Object Text.UTF8Encoding($false)))
 foreach ($case in @(@('',0,$false),@('-SuccessReceipt',0,$true),@('-SuccessReceipt',1,$true))) {
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $start.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$receiptFixture+'" '+$case[0]
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $child=[Diagnostics.Process]::Start($start)
  try {
   $output=$child.StandardOutput.ReadToEnd();$errorOutput=$child.StandardError.ReadToEnd()
   if (-not $child.WaitForExit(10000)) {$child.Kill();throw 'Synthetic receipt helper timed out'}
   Expect ($child.ExitCode -eq $case[1]) 'Receipt creation uses create-new, not overwrite/adoption'
   Expect ((Test-Path -LiteralPath $receiptPath) -eq $case[2]) 'Only broker-requested completion creates the fixed receipt'
   if ($case[2]) {Expect ((Get-Item -LiteralPath $receiptPath).Length -eq 0) 'Completion receipt is zero length'}
  } finally {$child.Dispose()}
 }
} finally {if ([IO.Directory]::Exists($directory)) {[IO.Directory]::Delete($directory,$true)}}
@{status='passed';checks=$count;scope='actual setup catch body with synthetic output/acknowledgement; no privileged setup or Windows operations'} | ConvertTo-Json -Compress
