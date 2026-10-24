#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Actual client parser/certificate pin/framing, with MemoryStreams only. No GUI,
# service, network connection, existing identity, preferences or user data.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=[IO.File]::ReadAllText((Join-Path $root 'EnrollmentClient.cs'))
$checks=@'
namespace Knot.Enrollment {
 internal sealed class FragmentedMemory : System.IO.MemoryStream {
  public FragmentedMemory() : base() { }
  public override System.Threading.Tasks.Task<int> ReadAsync(byte[] buffer,int offset,int count,System.Threading.CancellationToken token) {
   return base.ReadAsync(buffer,offset,System.Math.Min(1,count),token);
  }
 }
 public static class SyntheticChecks {
  private static int count;
  private static void Expect(bool value) { if (!value) throw new System.Exception("enrollment fixture failed"); count++; }
  private static void Reject(System.Action action) { bool rejected=false; try { action(); } catch { rejected=true; } Expect(rejected); }
  public static int Run() {
   count=0;
   string id="11111111-1111-4111-8111-111111111111", pin=new string('a',64), token=new string('b',64);
   string good="knot-enroll://192.168.1.20:20000/"+id+"#"+pin+"."+token;
   var link=Link.Parse(good); Expect(link.Address=="192.168.1.20" && link.Port==20000 && link.SessionID==id);
   foreach (string bad in new string[]{good+"\n",good+"?x=1",good.Replace("20000","020000"),good.Replace("192.168.1.20","127.0.0.1"),good.Replace("192.168.1.20","8.8.8.8"),good.Replace("192.168.1.20","169.254.1.20"),good.Replace("knot-enroll","https"),good.Replace("192.168.1.20","user@192.168.1.20"),good.Replace("#","?x=#"),good.Replace(pin,new string('A',64)),good.Replace(id,"invalid"),new string('a',513)}) Reject(delegate { Link.Parse(bad); });
   foreach (string address in new string[]{"10.1.2.3","172.16.1.2","172.31.1.2","100.64.1.2","100.127.1.2"}) Expect(Link.Parse(good.Replace("192.168.1.20",address)).Address==address);
   foreach (string address in new string[]{"172.15.1.2","172.32.1.2","100.63.1.2","100.128.1.2","192.169.1.2"}) Reject(delegate { Link.Parse(good.Replace("192.168.1.20",address)); });
   foreach (string local in new string[]{"192.168.1.20","100.80.1.20"}) {
    var endpoint=new System.Net.IPEndPoint(System.Net.IPAddress.Parse(local),50000);
    Expect(Link.LocalAddressFromEndpoint(endpoint)==local);
    Expect(Client.SelectLocalAddress(local,new string[]{"192.168.1.20","100.80.1.20"})==local);
    Reject(delegate { Client.SelectLocalAddress(local,new string[]{"10.0.0.1"}); });
   }
   foreach (string local in new string[]{"127.0.0.1","8.8.8.8","169.254.1.20","::1"}) {
    Reject(delegate { Link.LocalAddressFromEndpoint(new System.Net.IPEndPoint(System.Net.IPAddress.Parse(local),50000)); });
    Reject(delegate { Client.SelectLocalAddress(local,new string[]{local}); });
   }
   Reject(delegate { Link.LocalAddressFromEndpoint(null); });
   Reject(delegate { Link.LocalAddressFromEndpoint(new System.Net.DnsEndPoint("synthetic.invalid",50000)); });
   Reject(delegate { Client.SelectLocalAddress("192.168.001.20",new string[]{"192.168.001.20"}); });
   var waiting=new ReplyWindow(100);
   Expect(waiting.Active(219.5)); Expect(!waiting.CanReply(219.5));
   waiting.Authorize(219.5); Expect(waiting.CanReply(819.4));
   Reject(delegate { waiting.Authorize(819.4); });
   Expect(!waiting.Active(819.5)); Expect(!waiting.Active(819.4));
   Reject(delegate { waiting.Authorize(819.4); });
   var expired=new ReplyWindow(100);
   Expect(!expired.Active(220)); Reject(delegate { expired.Authorize(219); });
   var replay=new ReplyWindow(100); replay.Authorize(101);
   Reject(delegate { replay.Authorize(650); }); Expect(!replay.CanReply(701));
   var cancelled=new ReplyWindow(100); cancelled.Cancel();
   Expect(!cancelled.Active(101)); Reject(delegate { cancelled.Authorize(101); });
   foreach (double invalid in new double[]{Double.NaN,Double.PositiveInfinity,-1,99}) {
    var clock=new ReplyWindow(100); Expect(!clock.Active(invalid)); Reject(delegate { clock.Authorize(101); });
   }
   byte[] certificate=System.Text.Encoding.UTF8.GetBytes("fresh inert bytes; not a real certificate");
   string expected; using (var hash=System.Security.Cryptography.SHA256.Create()) expected=System.BitConverter.ToString(hash.ComputeHash(certificate)).Replace("-","").ToLowerInvariant();
   Expect(Link.MatchesPin(certificate,expected)); Expect(!Link.MatchesPin(certificate,pin)); Expect(!Link.MatchesPin(null,expected)); Expect(!Link.MatchesPin(certificate,""));
   foreach (int size in new int[]{1,2,16384}) {
    byte[] bytes=new byte[size]; for (int i=0;i<size;i++) bytes[i]=(byte)(i%256);
    using (var stream=new FragmentedMemory()) {
     Frames.WriteAsync(stream,bytes,System.Threading.CancellationToken.None).GetAwaiter().GetResult();
     Expect(stream.Length==size+4); stream.Position=0;
     var result=Frames.ReadAsync(stream,System.Threading.CancellationToken.None).GetAwaiter().GetResult();
     Expect(result.Length==size); for (int i=0;i<size;i++) if (result[i]!=bytes[i]) throw new System.Exception("frame bytes changed");
    }
   }
   foreach (byte[] bad in new byte[][]{new byte[0],new byte[]{0},new byte[]{0,0,0,0},new byte[]{0,0,64,1},new byte[]{255,255,255,255},new byte[]{0,0,0,2,1}}) {
    using (var stream=new System.IO.MemoryStream(bad)) Reject(delegate { Frames.ReadAsync(stream,System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
   }
   using (var stream=new System.IO.MemoryStream()) {
    Reject(delegate { Frames.WriteAsync(stream,new byte[0],System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
    Reject(delegate { Frames.WriteAsync(stream,new byte[16385],System.Threading.CancellationToken.None).GetAwaiter().GetResult(); });
    using (var cancel=new System.Threading.CancellationTokenSource()) { cancel.Cancel(); Reject(delegate { Frames.ReadAsync(stream,cancel.Token).GetAwaiter().GetResult(); }); }
   }
   return count;
  }
 }
}
'@
# Distinct namespace makes the actual client source and same-assembly helpers
# replayable even when another suite already loaded production types.
$namespace='Knot.Enrollment.Fixture'+[Guid]::NewGuid().ToString('N')
Add-Type -TypeDefinition (($source+"`n"+$checks).Replace('namespace Knot.Enrollment {',('namespace '+$namespace+' {')))
$type=($namespace+'.SyntheticChecks') -as [type]
$count=$type.GetMethod('Run').Invoke($null,@())
# Parse modified WinForms code without loading it or executing native leaves.
$tokens=$null; $errors=$null
# PS5 ParseFile/Extent.Text can expose a different newline/BOM view from its
# absolute offsets. Decode explicitly and parse one normalized string buffer.
$utf8=New-Object Text.UTF8Encoding($false,$true)
$guiSource=[IO.File]::ReadAllText((Join-Path $root 'Setup-DeskBridge.ps1'),$utf8).Replace("`r`n","`n").Replace("`r","`n")
[void][Management.Automation.Language.Parser]::ParseInput($guiSource,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Enrollment setup UI has PowerShell parse errors.' }
# The real broker rebuilds a public reply from the CURRENT request even when
# the existing, identical managed deployment is reused. Execute only that
# hashtable AST with inert public variables, never the broker or Resume script.
Import-Module (Join-Path $root 'SetupContract.psm1') -Force
$brokerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-DeskBridgeSetup.ps1'),[ref]$tokens,[ref]$errors)
$assign=@($brokerAst.FindAll({param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'reply'
},$true))
if ($errors.Count -or $assign.Count -ne 1 -or @($assign[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.HashtableAst]},$true)).Count -ne 1) { throw 'Broker reply fixture extraction failed.' }
if ((Get-ManagedDeploymentAction $true $true $true $true $true $true $true) -cne 'Reuse') { throw 'Matching setup retry did not reuse deployment.' }
$prefix=[byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
$clientKey='ssh-ed25519 '+[Convert]::ToBase64String([byte[]]($prefix+(@(1)*32)))
$key='ssh-ed25519 '+[Convert]::ToBase64String([byte[]]($prefix+(@(2)*32)))
$address='192.168.1.30'; $previousID=$null
foreach ($id in @('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222')) {
    $request=ConvertFrom-MacSetup (@{kind='deskbridge.mac-setup';version=1;requestID=$id;clientPublicKey=$clientKey;allowedClientAddresses=@('192.168.1.20')} | ConvertTo-Json -Compress)
    $reply=& ([scriptblock]::Create($assign[0].Right.Extent.Text))
    if ($reply.requestID -cne $id -or $reply.requestID -ceq $previousID -or $reply.clientPublicKey -cne $clientKey -or $reply.address -cne $address -or $reply.serverPublicKey -cne $key) { throw 'Reused setup returned stale public enrollment identity.' }
    $previousID=$reply.requestID; $count++
}
# Execute the ACTUAL UI operation and failure handler, replacing only native
# user/approval/process/file-dialog/read leaves with inert callbacks. In
# particular the real try/catch/status assignments and sanitizer are retained.
function Assert-EnrollmentFixtureSyntax([string] $Source,[string] $Stage) {
    $fixtureTokens=$null; $fixtureErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$fixtureTokens,[ref]$fixtureErrors)
    if ($fixtureErrors.Count) {
        # Stable parser IDs and positions only; never dump transformed source,
        # exception text, fixture values or any runtime/user data.
        $safe=@($fixtureErrors | ForEach-Object { $_.ErrorId+'@'+$_.Extent.StartLineNumber+':'+$_.Extent.StartColumnNumber })
        throw ('Enrollment fixture syntax failure at '+$Stage+': '+($safe -join ', '))
    }
    return $ast
}
function Get-InertEnrollmentHandler([string] $Name,[string] $Source) {
    $normalized=$Source.Replace("`r`n","`n").Replace("`r","`n")
    $guiAst=Assert-EnrollmentFixtureSyntax $normalized 'input'
    $definition=@($guiAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true))
    if ($definition.Count -ne 1) { throw 'Enrollment handler fixture extraction failed.' }
    $function=$definition[0]
    # Slice the SAME buffer that ParseInput indexed, rather than relying on
    # engine-specific formatting returned by IScriptExtent.Text.
    $text=$normalized.Substring($function.Extent.StartOffset,$function.Extent.EndOffset-$function.Extent.StartOffset)
    $edits=@()
    foreach ($node in $function.FindAll({param($item) $item -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $item.Static},$true)) {
        if ($node.Expression -isnot [Management.Automation.Language.TypeExpressionAst]) { continue }
        $typeName=$node.Expression.TypeName.FullName
        if ($typeName -ceq 'Windows.Forms.MessageBox' -and $node.Member.Value -ceq 'Show') {
            $edits+=@{Offset=$node.Extent.StartOffset-$function.Extent.StartOffset;Length=$node.Extent.EndOffset-$node.Extent.StartOffset;Text="'OK'"}
        } elseif ($typeName -ceq 'Security.Principal.WindowsIdentity' -and $node.Member.Value -ceq 'GetCurrent') {
            $edits+=@{Offset=$node.Extent.StartOffset-$function.Extent.StartOffset;Length=$node.Extent.EndOffset-$node.Extent.StartOffset;Text="([pscustomobject]@{User=[pscustomobject]@{Value='S-1-5-21-100-200-300-1001'}})"}
        }
    }
    foreach ($node in $function.FindAll({param($item) $item -is [Management.Automation.Language.CommandAst] -and $item.GetCommandName() -ceq 'New-Object'},$true)) {
        if ($node.CommandElements.Count -eq 2 -and $node.CommandElements[1].Value -ceq 'Windows.Forms.SaveFileDialog') {
            $edits+=@{Offset=$node.Extent.StartOffset-$function.Extent.StartOffset;Length=$node.Extent.EndOffset-$node.Extent.StartOffset;Text="([pscustomobject]@{Filter='';FileName=''})"}
        }
    }
    foreach ($edit in @($edits | Sort-Object @{Expression={[int]$_['Offset']}} -Descending)) {
        # Explicit dictionary access avoids PS5 adapted-member differences
        # (notably Length) while applying original-source offsets.
        $offset=[int]$edit['Offset']; $length=[int]$edit['Length']; $replacement=[string]$edit['Text']
        if ($offset -lt 0 -or $length -lt 1 -or $offset+$length -gt $text.Length) { throw 'Enrollment fixture edit bounds are invalid.' }
        $text=$text.Remove($offset,$length).Insert($offset,$replacement)
    }
    [void](Assert-EnrollmentFixtureSyntax $text 'transformed-handler')
    return $text
}
$operationSource=Get-InertEnrollmentHandler 'Invoke-FileSetup' $guiSource
$failureSource=Get-InertEnrollmentHandler 'Show-Failure' $guiSource
$lineEndingChecks=0
foreach ($name in @('Invoke-FileSetup','Show-Failure')) {
    $lf=Get-InertEnrollmentHandler $name $guiSource
    $crlf=Get-InertEnrollmentHandler $name ($guiSource.Replace("`n","`r`n"))
    if ($lf -cne $crlf) { throw 'Actual enrollment handler changes with CRLF source.' }
    $lineEndingChecks++
}
# New inert Unicode/quoted-argument fixture stresses edit offsets before the
# exact syntax that failed in native PS5 CI. It is parsed, never executed.
$quotedFixture=@'
# 앞선 Unicode text shifts character offsets; this is synthetic source only.
function SyntheticEnrollmentHandler {
    $arguments='--operation synthetic'
    if ([Windows.Forms.MessageBox]::Show('한글 "안내"','Knot','OKCancel','Information') -eq 'OK') {
        $sid=([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $arguments='-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "' + $script + '" -Operation ' + $Operation
        $save=New-Object Windows.Forms.SaveFileDialog
    }
}
'@
$quotedFixture=$quotedFixture.Replace("`r`n","`n").Replace("`r","`n")
$quotedLF=Get-InertEnrollmentHandler 'SyntheticEnrollmentHandler' $quotedFixture
$quotedCRLF=Get-InertEnrollmentHandler 'SyntheticEnrollmentHandler' ($quotedFixture.Replace("`n","`r`n"))
if ($quotedLF -cne $quotedCRLF -or -not $quotedLF.Contains('$arguments=''-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "'' + $script + ''" -Operation '' + $Operation')) { throw 'Quoted enrollment fixture changed outside the approved native leaves.' }
$lineEndingChecks++
# A deliberately invalid new fixture proves syntax assertions fail before any
# ScriptBlock.Create/handler invocation, with parser IDs/positions only.
$invalidRejected=$false
try { [void](Assert-EnrollmentFixtureSyntax 'function Broken { "' 'synthetic-invalid') }
catch {
    $invalidRejected=$_.Exception.Message.StartsWith('Enrollment fixture syntax failure at synthetic-invalid: ')
    if ($_.Exception.Message.Contains('function Broken')) { throw 'Fixture syntax diagnostics exposed source text.' }
}
if (-not $invalidRejected) { throw 'Enrollment fixture failed to reject invalid transformed syntax.' }
$lineEndingChecks++
$count+=$lineEndingChecks
Import-Module (Join-Path $root 'SetupStatus.psm1') -Force
$handlerCases=0
foreach ($operation in @('EnableFiles','Export','DisableFiles')) {
    $modes=if ($operation -ceq 'DisableFiles') { @('disable') } else { @('expired','send-failed','before-provision','native-failed','wrong-reply','bad-server-key','success','manual-save-cancel') }
    foreach ($mode in $modes) {
        $caseResult = & {
            param($OperationSource,$FailureSource,$Operation,$Mode,$ClientKey,$ServerKey)
            . ([scriptblock]::Create($OperationSource))
            . ([scriptblock]::Create($FailureSource))
            $script:deliveryTestMode=$Mode; $script:deliveryNativeCompleted=$false; $script:deliveryReadCount=0; $script:deliverySendCount=0; $script:deliveryBusyDepth=0; $script:deliveryLaunches=@()
            $status=[pscustomobject]@{Text=''}; $enrollmentCancel=[pscustomobject]@{Enabled=$false}
            $LauncherPath='synthetic-not-executed.exe'; $addresses=[pscustomobject]@{SelectedItem='192.168.1.30'}
            $requestBox=[pscustomobject]@{Text='synthetic-not-opened.json'}
            $expectedRequest=[pscustomobject]@{kind='deskbridge.mac-setup';version=1;requestID='11111111-1111-4111-8111-111111111111';clientPublicKey=$ClientKey;allowedClientAddresses=@('192.168.1.20')}
            $script:deliveryReply=[pscustomobject]@{kind='deskbridge.windows-connection';version=1;requestID=$expectedRequest.requestID;clientPublicKey=$ClientKey;address='192.168.1.30';port=22;username='deskbridge-transfer';serverPublicKey=$ServerKey}
            if ($Mode -ceq 'wrong-reply') { $script:deliveryReply.requestID='22222222-2222-4222-8222-222222222222' }
            if ($Mode -ceq 'bad-server-key') { $script:deliveryReply.serverPublicKey='ssh-ed25519 invalid' }
            $rawMarker='SYNTHETIC_PRIVATE_TOKEN_DO_NOT_DISPLAY'
            function Set-Busy([bool] $Busy) { if ($Busy) { $script:deliveryBusyDepth++ } else { $script:deliveryBusyDepth-- } }
            function Resolve-DesktopUser($Sid) { return [pscustomobject]@{Name='Synthetic Desktop';SID=[pscustomobject]@{Value='S-1-5-21-100-200-300-1001'}} }
            function Read-MacSetup($Path) { return $expectedRequest }
            function Join-Path($Path,$ChildPath) { return 'synthetic-result-not-opened' }
            function Get-Content($LiteralPath,[switch]$Raw) {
                if ($LiteralPath -cne 'synthetic-result-not-opened') { throw 'Unexpected fixture file request.' }
                $script:deliveryReadCount++
                return $script:deliveryReply | ConvertTo-Json -Compress
            }
            function Save-DeskBridgeConnectionReply($Reply,$Dialog) { return 'Cancelled' }
            function Start-Process($FilePath,$Verb,$ArgumentList,[switch]$PassThru) {
                # Capture the actual broker boundary before any inert failure.
                # Assertions run outside the handler's catch so it cannot hide them.
                $script:deliveryLaunches+=@([pscustomobject]@{FilePath=$FilePath;Verb=$Verb;ArgumentList=$ArgumentList;PassThru=[bool]$PassThru})
                if ($script:deliveryTestMode -ceq 'before-provision') { throw 'SYNTHETIC_PRIVATE_TOKEN_DO_NOT_DISPLAY C:\synthetic-untrusted-path' }
                $exitCode=if ($script:deliveryTestMode -ceq 'native-failed') {1} else {0}
                $process=[pscustomobject]@{Handle=1;HasExited=$true;ExitCode=$exitCode}
                $process | Add-Member ScriptMethod WaitForExit { $script:deliveryNativeCompleted=$true }
                return $process
            }
            $client=New-Object PSObject
            $client | Add-Member ScriptProperty Active { return -not ($script:deliveryTestMode -ceq 'expired' -and $script:deliveryNativeCompleted) }
            $client | Add-Member ScriptMethod SendReplyAsync {
                param($Text)
                $script:deliverySendCount++
                if ($script:deliveryTestMode -ceq 'send-failed') { return [Threading.Tasks.Task]::FromException([InvalidOperationException]::new('SYNTHETIC_PRIVATE_TOKEN_DO_NOT_DISPLAY C:\synthetic-untrusted-path')) }
                $completion=[Threading.Tasks.TaskCompletionSource[object]]::new()
                $completion.SetResult($null)
                return $completion.Task
            }
            if ($Mode -in @('manual-save-cancel','disable')) { Invoke-FileSetup $Operation }
            else { Invoke-FileSetup $Operation -AutomaticRequest $expectedRequest -AutomaticClient $client }
            $checks=0; $fingerprint=Get-KeyFingerprint $ServerKey
            if ($script:deliveryLaunches.Count -ne 1) { throw 'Actual handler did not make exactly one broker request.' }; $checks++
            $launch=$script:deliveryLaunches[0]
            if ($launch.FilePath -cne $LauncherPath -or $launch.Verb -cne 'RunAs' -or -not $launch.PassThru) { throw 'Actual broker boundary lost its installed executable/elevation/wait contract.' }; $checks++
            $argv=@(([string]$launch.ArgumentList) -split ' ')
            $expectedArgc=if ($Operation -ceq 'EnableFiles') {8} elseif ($Operation -ceq 'Export') {6} else {2}
            if ($argv.Count -ne $expectedArgc -or $argv[0] -cne '--elevated-operation' -or $argv[1] -cne $Operation) { throw 'Actual broker operation/argument allowlist changed.' }; $checks++
            if ($Operation -cne 'DisableFiles') {
                if ($argv[2] -cne '--request-base64' -or $argv[4] -cne '--windows-address' -or $argv[5] -cne '192.168.1.30') { throw 'Actual broker lost its public-request/address contract.' }; $checks++
                $decoded=(New-Object Text.UTF8Encoding($false,$true)).GetString([Convert]::FromBase64String($argv[3]))
                $canonical=ConvertFrom-MacSetup $decoded
                $expectedCanonical=ConvertFrom-MacSetup ($expectedRequest | ConvertTo-Json -Depth 4 -Compress)
                $expectedJson=$expectedCanonical | ConvertTo-Json -Depth 4 -Compress
                if ($decoded -cne $expectedJson -or ($canonical | ConvertTo-Json -Depth 4 -Compress) -cne $expectedJson) { throw 'Actual broker received a stale, empty or noncanonical Mac request.' }; $checks++
                if ($decoded.Contains('synthetic-not-opened.json') -or $decoded.Contains('synthetic-result-not-opened')) { throw 'An input/output file path crossed the installed broker boundary.' }; $checks++
            }
            if ($Operation -ceq 'EnableFiles') {
                if ($argv[6] -cne '--desktop-user-sid' -or $argv[7] -cne 'S-1-5-21-100-200-300-1001') { throw 'Actual broker lost the original non-elevated desktop SID.' }; $checks++
            }
            if ($status.Text.Contains($rawMarker) -or $status.Text.Contains('C:\synthetic-untrusted-path')) { throw 'Enrollment delivery leaked a raw exception/path.' }; $checks++
            if ($script:deliveryBusyDepth -ne 0) { throw 'Enrollment handler failed to restore UI admission.' }; $checks++
            if ($Mode -in @('expired','send-failed')) {
                if (-not $status.Text.Contains('Windows 파일 설정 완료') -or -not $status.Text.Contains($fingerprint)) { throw 'Confirmed setup lost its success state or SSH fingerprint after delivery failure.' }; $checks++
                foreach ($text in @('새 자동 파일 설정 연결','같은 Mac 키','이미 설정한 연결 파일 다시 저장','해제하거나 다시 설치할 필요는 없습니다')) {
                    if (-not $status.Text.Contains($text)) { throw 'Confirmed setup lost actionable non-destructive delivery recovery.' }; $checks++
                }
                if ($script:deliveryReadCount -ne 1 -or ($Mode -ceq 'expired' -and $script:deliverySendCount -ne 0) -or ($Mode -ceq 'send-failed' -and $script:deliverySendCount -ne 1)) { throw 'Delivery recovery was reached without the validated native/public reply sequence.' }; $checks++
            } elseif ($Mode -ceq 'success') {
                if (-not $status.Text.Contains('Mac에 전달했습니다') -or -not $status.Text.Contains($fingerprint) -or $script:deliverySendCount -ne 1) { throw 'Successful automatic delivery behavior regressed.' }; $checks++
            } elseif ($Mode -ceq 'disable') {
                if (-not $status.Text.Contains('파일 접속을 해제했습니다') -or $status.Text.Contains($fingerprint) -or $script:deliveryReadCount -ne 0 -or $script:deliverySendCount -ne 0) { throw 'Legacy confirmed file revocation behavior regressed.' }; $checks++
            } elseif ($Mode -ceq 'manual-save-cancel') {
                if (-not $status.Text.Contains('연결 파일 저장을 취소') -or -not $status.Text.Contains($fingerprint) -or $script:deliverySendCount -ne 0) { throw 'Legacy manual export/save cancellation behavior regressed.' }; $checks++
            } else {
                if (-not $status.Text.StartsWith('완료하지 못했습니다.') -or $status.Text.Contains('Windows 파일 설정 완료') -or $status.Text.Contains($fingerprint) -or $script:deliverySendCount -ne 0) { throw 'Unconfirmed Windows activation was promoted to delivery-only success.' }; $checks++
                if ($Mode -in @('before-provision','native-failed') -and $script:deliveryReadCount -ne 0) { throw 'Unsuccessful native activation read/published a public result.' }; $checks++
            }
            return $checks
        } $operationSource $failureSource $operation $mode $clientKey $key
        # PowerShell may expose the reflection-only VoidTaskResult/null of an
        # awaited successful native Task; it carries no fixture/status value.
        $results=@($caseResult | Where-Object { $null -ne $_ -and $_.GetType().FullName -cne 'System.Threading.Tasks.VoidTaskResult' })
        if ($results.Count -ne 1 -or $results[0] -isnot [int]) { throw ('Unexpected inert handler outputs for ' + $operation + '/' + $mode) }
        $count += $results[0]
        $handlerCases++
    }
}
@{status='passed';checks=$count+3;freshSyntheticOnly=$true;network=$false;ui=$false;services=$false;actualBrokerReplyProjection=$true;actualUIHandlerCases=$handlerCases;lineEndingChecks=$lineEndingChecks} | ConvertTo-Json -Compress
