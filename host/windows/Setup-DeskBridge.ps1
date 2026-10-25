#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# The UI is non-elevated. Only explicit installation/file actions ask Windows for UAC.
[CmdletBinding()]
param([string] $LauncherPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SetupContract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ConnectionInvitation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SetupDownload.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SetupStatus.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SetupReadiness.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Enrollment.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('KnotUpdateForm' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'KnotUpdateForm.cs') -ReferencedAssemblies System.dll,System.Windows.Forms.dll,System.Drawing.dll
}
[Windows.Forms.Application]::EnableVisualStyles()
try { Assert-DesktopSetupToken } catch {
    [Windows.Forms.MessageBox]::Show((Get-SetupFailureText $_ -Context 'ElevatedToken'),'Knot','OK','Error') | Out-Null
    exit 3
}
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or [Environment]::OSVersion.Version.Build -lt 22000) {
    [Windows.Forms.MessageBox]::Show('이 프리뷰는 Windows 11 x64에서 사용할 수 있습니다. PC의 Windows 버전과 시스템 종류를 확인하세요.','Knot','OK','Error') | Out-Null
    exit 3
}
$form = New-Object KnotUpdateForm
$form.Text = 'Knot · Windows 연결'; $form.Size = New-Object Drawing.Size(780,760)
$form.MinimumSize = New-Object Drawing.Size(640,480); $form.StartPosition = 'CenterScreen'
$form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96); $form.AutoScaleMode='Dpi'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'AppIcon.ico') -PathType Leaf) {
    $form.Icon=New-Object Drawing.Icon((Join-Path $PSScriptRoot 'AppIcon.ico'))
}
$flow = New-Object Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
$flow.Padding = New-Object Windows.Forms.Padding(20)
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.ColumnCount=1; $layout.RowCount=2
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',84)))
$form.Controls.Add($layout)
$layout.Controls.Add($flow,0,0)
$script:section=$flow
function Add-Text([string] $Text,[int] $Height=40) {
    $label = New-Object Windows.Forms.Label; $label.Text=$Text; $label.AutoSize=$true
    $label.MinimumSize=New-Object Drawing.Size(0,$Height); $label.MaximumSize=New-Object Drawing.Size(710,0)
    $script:section.Controls.Add($label); return $label
}
function Add-Button([string] $Text,[scriptblock] $Action,[switch] $AllowDuringUpdate) {
    $button=New-Object Windows.Forms.Button; $button.Text=$Text; $button.Size=New-Object Drawing.Size(330,34)
    # Keep the original script scope (including cancellation flags), rather than
    # copying actions into a dynamic module via GetNewClosure.
    $button.Tag=[pscustomobject]@{Action=$Action;AllowDuringUpdate=[bool]$AllowDuringUpdate}
    $button.Add_Click({ param($sender,$eventArgs)
        if (-not $form.UpdateCloseRequested -or $sender.Tag.AllowDuringUpdate) { & $sender.Tag.Action }
    })
    $script:section.Controls.Add($button); return $button
}
$title = Add-Text 'Windows를 Mac의 한 화면으로' 38
$title.Font = New-Object Drawing.Font('Segoe UI',17,[Drawing.FontStyle]::Bold)
$null = Add-Text '필요한 구성요소 설치와 계정·보안 설정을 자동으로 준비합니다. Sunshine을 따로 열 필요가 없습니다.' 48
$script:quickInstall=$false
$quick=Add-Button '연결 준비 · 자동 설정' { Invoke-QuickSetup }
$quick.AccessibleDescription='화면 공유 구성요소 설치, 계정 생성과 보안 설정을 자동으로 진행합니다. Mac PIN만 이 창에서 승인합니다.'
$null = Add-Text 'Windows 관리자 승인 후 처음 계정은 자동으로 만듭니다. 기존 Sunshine 계정만 처음 한 번 로그인하세요. Mac의 PIN을 승인한 뒤에는 저장된 연결을 사용하세요. 보안 설정을 처음 적용하거나 다시 적용할 때 Sunshine이 재시작될 수 있습니다.' 64
$status=New-Object Windows.Forms.TextBox
$status.AccessibleName='Windows 연결 설정 상태'; $status.AccessibleDescription='진행 상황과 다음 단계 안내입니다. 내용을 선택해 복사할 수 있습니다.'
$status.ReadOnly=$true; $status.Multiline=$true; $status.ScrollBars='Vertical'; $status.BorderStyle='None'; $status.BackColor=[Drawing.SystemColors]::Control
$status.Text='연결 준비를 시작합니다. 관리자 승인 후 Mac의 요청과 PIN을 확인하세요.'
$status.Dock='Fill'
$status.Margin=New-Object Windows.Forms.Padding(20,8,20,8)
$layout.Controls.Add($status,0,1)
$status.ForeColor=[Drawing.SystemColors]::HotTrack
function Show-Failure($ErrorRecord) {
    $cause=$ErrorRecord.Exception
    while ($cause) {
        if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) {
            $status.Text='관리자 확인을 취소했습니다. 필요할 때 다시 시작하세요.'
            return
        }
        $cause=$cause.InnerException
    }
    $message=Get-SetupFailureText $ErrorRecord
    $status.Text='완료하지 못했습니다. ' + $message
    [Windows.Forms.MessageBox]::Show($message,'Knot','OK','Error') | Out-Null
}
function Get-SetupControls($Root) {
    foreach ($control in $Root.Controls) { $control; Get-SetupControls $control }
}
$script:setupBusyDepth=0
function Update-BusyControls {
    $effectiveBusy=$script:setupBusyDepth -gt 0
    foreach ($control in (Get-SetupControls $flow)) {
        # Keep an already enabled cancellation button usable while draining.
        # Its original action can only cancel owned work; never enable a dormant one.
        if ($form.UpdateCloseRequested -and $control.Tag -and
            $control.Tag.PSObject.Properties['AllowDuringUpdate'] -and $control.Tag.AllowDuringUpdate) { continue }
        if ($control -is [Windows.Forms.Button] -or $control -is [Windows.Forms.ComboBox]) { $control.Enabled = -not ($effectiveBusy -or $form.UpdateCloseRequested) }
    }
    $form.UseWaitCursor=$effectiveBusy
    $form.UpdateWorkDidFinish()
}
$form.UpdateProtectedWork=[Func[bool]]{ $script:setupBusyDepth -gt 0 }
$form.Add_UpdateCloseStateChanged({
    if ($form.UpdateCloseRequested) { $status.Text='진행 중인 설정을 마치면 Knot을 자동으로 업데이트하고 다시 엽니다.' }
    Update-BusyControls
})
function Set-Busy([bool] $Busy) {
    # Installation can run its bounded local check before download cleanup.
    # Keep the outer operation's controls locked until its own finally exits.
    if ($Busy) { $script:setupBusyDepth++ }
    else { $script:setupBusyDepth=[Math]::Max(0,$script:setupBusyDepth-1) }
    Update-BusyControls
}
function Invoke-SunshineLocalCheck([int] $WaitMilliseconds=2000,[ValidateSet('Status','Settings','PIN','Encryption')][string] $Open='Status') {
    Set-Busy $true; $probe=$null; $script:quickSetupPortResponded=$null
    try {
        $script:cancelLocalCheck=$false; $localCheckCancel.Visible=$true; $localCheckCancel.Enabled=$true
        $status.Text='이 Windows의 로컬 설정 포트 응답을 확인하는 중…'; [Windows.Forms.Application]::DoEvents()
        $probe=Start-SetupLocalPortProbe -WaitMilliseconds $WaitMilliseconds
        while (-not $probe.Completion.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            if ($script:cancelLocalCheck) { $probe.Cancel(); $localCheckCancel.Enabled=$false }
            Start-Sleep -Milliseconds 50
        }
        $responded=$probe.Completion.GetAwaiter().GetResult()
        $script:quickSetupPortResponded=[bool]$responded
        $localPortStatus.Text=Get-SunshineLocalPortText $responded
        $status.Text=$localPortStatus.Text
        if ($responded -and $Open -cne 'Status') {
            # Fixed local URLs only. The probe does not authenticate the listener
            # and never changes TLS validation, Sunshine settings or services.
            $url=if ($Open -ceq 'PIN') {'https://localhost:47990/pin'} elseif ($Open -ceq 'Encryption') {'https://localhost:47990/config#lan_encryption_mode'} else {'https://localhost:47990/'}
            try {
                Start-Process $url
                $status.Text=if ($Open -ceq 'PIN') {
                    '이 Windows의 브라우저에서 PIN 입력 화면을 열었습니다. Sunshine에 로그인한 뒤 Mac에 표시된 PIN을 입력하세요. 아직 Mac에서 PIN을 만들지 않았다면 먼저 「PIN으로 연결」을 누르세요.'
                } elseif ($Open -ceq 'Encryption') {
                    'LAN Encryption Mode와 WAN Encryption Mode를 둘 다 Required for all clients로 선택하세요. 한국어 화면에서는 LAN/WAN 암호화 모드 → 모든 사용자에게 필수입니다. Save 후 Apply/재시작까지 완료하고 Mac에서 다시 연결하세요. 기존 PIN 페어링은 유지하세요.'
                } else {
                    '이 Windows의 브라우저에서 초기 계정을 만들고 로그인하세요. 다음으로 영상 암호화 설정 열기를 눌러 LAN/WAN 암호화 모드를 둘 다 Required for all clients(모든 사용자에게 필수)로 Save하고 Apply/재시작하세요. 이후 3단계에서 Mac의 PIN을 승인합니다.'
                }
            } catch {
                $status.Text='이 Windows의 설정 브라우저를 열지 못했습니다. 이 Windows의 Edge/Chrome 주소창에 ' + $url + ' 을 직접 입력하세요. Mac에서 localhost를 열면 이 Windows에 연결되지 않습니다.'
            }
        }
    } catch [OperationCanceledException] {
        $localPortStatus.Text=Get-SunshineLocalPortText $false -Cancelled
        $status.Text=$localPortStatus.Text
    } catch {
        $localPortStatus.Text='로컬 설정 포트 확인을 완료하지 못했습니다. 이 Windows의 브라우저에서 https://localhost:47990/ 을 확인하거나 잠시 후 다시 시도하세요.'
        $status.Text=$localPortStatus.Text
    } finally {
        $localCheckCancel.Visible=$false
        try {
            if ($probe) {
                $probe.Cancel()
                while (-not $probe.Completion.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
                $probe.Dispose()
            }
        } finally { Set-Busy $false }
    }
}
function Invoke-QuickSetup {
    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        $status.Text='간편 연결은 설치된 Knot EXE에서 사용할 수 있습니다. 소스 폴더에서는 고급·수동 설정을 사용하세요.'
        $advancedPanel.Visible=$true; return
    }
    Set-Busy $true
    try {
        # A file-presence hint only selects the path. The protected native helper
        # independently validates the installation and pins the local TLS API.
        $installed=Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe') -PathType Leaf
        if (-not $installed) {
            # A custom or inaccessible deployment must not be overwritten by a
            # convenient installer. Inspect only the fixed service's existence.
            try {
                $existing=@(Get-Service -Name 'SunshineService' -ErrorAction Stop)
            } catch {
                if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw }
                $existing=@()
            }
            if ($existing.Count -gt 0) {
                $status.Text='기존 Sunshine 서비스가 있습니다. 표준 설치 위치를 확인하지 못해 다시 설치하지 않습니다. 고급·수동 설정을 사용하세요.'
                $advancedPanel.Visible=$true; return
            }
            Invoke-SunshineLocalCheck -WaitMilliseconds 1000
            if ($script:quickSetupPortResponded -ne $false -or $null -eq $script:quickSetupPortResponded) {
                $status.Text='기존 또는 확인되지 않은 로컬 서비스가 있어 자동 설치를 중단했습니다. 고급·수동 설정을 확인하세요.'
                $advancedPanel.Visible=$true; return
            }
            $script:quickInstall=$true
            & $script:installAction
            return
        }
        $status.Text='Windows 관리자 확인 후 Knot 간편 연결 창을 여는 중…'
        $process=Start-Process -FilePath $LauncherPath -Verb RunAs -ArgumentList '--elevated-operation QuickSetupSunshine' -PassThru
        $null=$process.Handle
        if ($process) { $form.Hide() }
        while (-not $process.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $process.WaitForExit()
        if ($null -eq $process.ExitCode) { throw 'Sunshine 설치 결과를 확인하지 못했습니다. Windows 설치 안내를 확인하세요.' }
        if ($process.ExitCode -eq 0) {
            $status.Text='간편 연결 창을 닫았습니다. 새로 페어링하려면 이 버튼으로 Windows의 준비를 먼저 마치고 창을 열어 둔 뒤 Mac에서 PC 확인 → PIN으로 연결을 시작하세요. 저장된 보안 설정이 맞으면 다시 시작하지 않고 PIN을 승인합니다. 화면 연결 성공 여부는 Mac에서 확인하세요.'
        } elseif ($process.ExitCode -eq 1602) {
            $status.Text='간편 연결 창을 닫았습니다. 완료된 설치·설정과 기존 페어링은 유지됩니다. 필요할 때 다시 누르세요.'
        } else {
            $status.Text='간편 연결을 완료하지 못했습니다. 관리자 창의 안내를 확인하거나 고급·수동 설정을 사용하세요. 기존 인증서는 유지됩니다.'
        }
    } catch { Show-Failure $_ }
    finally { $script:quickInstall=$false; if (-not $form.IsDisposed) { $form.Show(); $form.Activate() }; Set-Busy $false }
}
$remoteActions=New-Object Windows.Forms.FlowLayoutPanel; $remoteActions.AutoSize=$true
foreach ($remote in @(@('Mac에 접속',10),@('Linux에 접속',11),@('업데이트 / 버전',12))) {
    $button=New-Object Windows.Forms.Button; $button.Text=$remote[0]; $button.Tag=$remote[1]; $button.AutoSize=$true
    $button.Add_Click({ param($sender,$eventArgs) $form.Tag=[int]$sender.Tag; $form.Close() })
    $remoteActions.Controls.Add($button)
}
$flow.Controls.Add($remoteActions)
$advancedToggle=Add-Button '＋ 고급·수동 설정' {}
$advancedPanel=New-Object Windows.Forms.FlowLayoutPanel
$advancedPanel.FlowDirection='TopDown'; $advancedPanel.WrapContents=$false; $advancedPanel.AutoSize=$true
$advancedPanel.AutoSizeMode='GrowAndShrink'; $advancedPanel.Width=710; $advancedPanel.Visible=$false
$flow.Controls.Add($advancedPanel)
$advancedToggle.Add_Click({
    $advancedPanel.Visible=-not $advancedPanel.Visible
    $advancedToggle.Text=if ($advancedPanel.Visible) {'－ 고급·수동 설정 접기'} else {'＋ 고급·수동 설정'}
})
$script:section=$advancedPanel
$null = Add-Text '1   화면 연결 프로그램 설치' 30
$null = Add-Text 'Sunshine이 Windows 화면을 Mac으로 전달합니다. 이미 설치했다면 다음 단계로 가세요.' 36
$script:installAction={
    Set-Busy $true; $folder=$null; $download=$null; $verifiedDownload=$null
    try {
        $dep=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SunshineDependency.json') -Raw | ConvertFrom-Json
        if ($dep.url -notmatch '^https://github\.com/LizardByte/Sunshine/releases/download/v[0-9.]+/Sunshine-Windows-AMD64-installer\.msi$' -or $dep.sha256 -notmatch '^[0-9a-f]{64}$' -or ($dep.bytes -isnot [int] -and $dep.bytes -isnot [long]) -or $dep.bytes -lt 1 -or $dep.bytes -gt 268435456) { throw 'Sunshine 설치 파일 정보가 올바르지 않습니다. 새 Knot 배포 파일을 사용하세요.' }
        $status.Text='Sunshine 공식 설치 파일을 내려받는 중…'; [Windows.Forms.Application]::DoEvents()
        $folder=Join-Path ([IO.Path]::GetTempPath()) ('DeskBridgeDownload-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $file=Join-Path $folder 'Sunshine.msi'
        $download=Start-SetupDownload -Url $dep.url -Path $file -ExpectedBytes $dep.bytes
        $downloadCancel.Visible=$true; $downloadCancel.Enabled=$true; $script:cancelDownload=$false
        while (-not $download.Completion.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            if ($script:cancelDownload) { $download.Cancel(); $downloadCancel.Enabled=$false }
            Set-SetupStatusText $status ('Sunshine 공식 설치 파일을 내려받는 중… ' + [Math]::Min(100,[Math]::Floor(100.0*$download.Bytes/$dep.bytes)) + '%')
            Start-Sleep -Milliseconds 80
        }
        $download.Completion.GetAwaiter().GetResult()
        $downloadCancel.Visible=$false; $downloadCancel.Enabled=$false
        # Keep this data snapshot locked for the developer-folder fallback too.
        $verifiedDownload=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $digest=[BitConverter]::ToString($sha.ComputeHash($verifiedDownload)).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($verifiedDownload.Length -ne $dep.bytes -or $digest -cne $dep.sha256) { throw 'Sunshine 설치 파일 검증에 실패했습니다. 실행하지 않았습니다. 새로 다운로드해 다시 시도하세요.' }
        $status.Text=if ($script:quickInstall) {'관리자 확인 후 Sunshine을 설치하고 간편 연결 창을 엽니다. 설치 중 Windows가 자동 재시작되지는 않습니다.'} else {'공식 Sunshine 설치 안내를 완료하세요. 게임패드 드라이버는 업무용 연결에 필요하지 않습니다.'}
        if ($LauncherPath) {
            # The native elevated broker makes and verifies its own protected copy against its embedded pin.
            $installExecutable=$LauncherPath
            $installOperation=if ($script:quickInstall) {'InstallSunshineAndSetup'} else {'InstallSunshine'}
            $installArguments='--elevated-operation ' + $installOperation + ' --msi-path "' + $file + '"'
        } else {
            # Explicit raw developer-folder workflow: the held read handle excludes writes/deletes until exit.
            $installExecutable=Join-Path $env:WINDIR 'System32\msiexec.exe'
            $installArguments='/i "' + $file + '"'
        }
        $process=Start-Process -FilePath $installExecutable -Verb RunAs -ArgumentList $installArguments -PassThru
        $null=$process.Handle
        if ($process) { $form.Hide() }
        while (-not $process.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $process.WaitForExit()
        if ($null -eq $process.ExitCode) { throw 'Sunshine 설치 결과를 확인하지 못했습니다. Windows 설치 안내를 확인하세요.' }
        if ($script:quickInstall -and $process.ExitCode -in @(0,1602,2)) {
            $status.Text=if ($process.ExitCode -eq 0) {'설치와 계정 확인을 마쳤습니다. PIN 승인에는 이 버튼으로 Windows의 준비를 먼저 마치고 창을 열어 둔 뒤 Mac에서 PC 확인 → PIN으로 연결을 시작하세요. 화면 전송 성공은 Mac에서 확인하세요.'} elseif ($process.ExitCode -eq 1602) {'간편 연결을 취소했습니다. 이미 완료된 설치·설정은 유지됩니다. 연결 준비로 다시 시작하세요.'} else {'간편 연결을 완료하지 못했습니다. 표시된 안내나 고급·수동 설정을 확인하세요. 이미 완료된 단계와 기존 인증서는 유지됩니다.'}
            return
        }
        $result=Get-SunshineInstallResult -ExitCode $process.ExitCode -Broker:([bool]$LauncherPath)
        if ($result.State -ceq 'Failed') { throw $result.Text }
        $status.Text=$result.Text
        if ($result.State -cne 'Installed') { return }
        $install.Text='Sunshine 다시 설치'
        # Installer exit 0 is not service, TLS, pairing or stream readiness.
        # Wait at most 15 seconds, then leave the explicit settings action to the user.
        Invoke-SunshineLocalCheck -WaitMilliseconds 15000
    } catch [OperationCanceledException] { $status.Text='Sunshine 다운로드를 취소했습니다. 필요할 때 다시 시작하세요.' }
    catch { Show-Failure $_ }
    finally {
        $downloadCancel.Visible=$false
        try {
            if ($verifiedDownload) { $verifiedDownload.Dispose() }
            if ($download) {
                $download.Cancel()
                while (-not $download.Completion.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
                $download.Dispose()
            }
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                try { Remove-Item -LiteralPath $folder -Recurse -Force }
                catch { $status.Text += [Environment]::NewLine+'임시 다운로드 파일을 정리하지 못했습니다. 설정은 다시 시도하거나 창을 닫을 수 있습니다.' }
            }
        } finally { if (-not $form.IsDisposed) { $form.Show(); $form.Activate() }; Set-Busy $false }
    }
}
$install=Add-Button 'Sunshine 설치 · 수동' $script:installAction
$downloadCancel=Add-Button '다운로드 취소' { $script:cancelDownload=$true } -AllowDuringUpdate; $downloadCancel.Visible=$false
$advancedPanel.Controls.Remove($downloadCancel); $flow.Controls.Add($downloadCancel)
$null = Add-Text '2   이 Windows에서 Sunshine 초기 설정 · 처음 한 번' 30
$null = Add-Text "Sunshine은 별도 창 없이 백그라운드에서 실행됩니다. 아래 버튼으로 이 Windows의 브라우저를 여세요. 초기 계정을 만들고 로그인합니다. 이 계정은 Sunshine 설정용이며 Mac에서 로그인하지 않습니다.`r`n영상 암호화 설정 열기 → LAN Encryption Mode / WAN Encryption Mode를 둘 다 Required for all clients로 선택하세요. 한국어: LAN/WAN 암호화 모드 → 모든 사용자에게 필수. Save → Apply/재시작까지 완료하세요. Wi-Fi와 Tailscale도 LAN으로 분류될 수 있어 LAN 설정이 필요합니다. Desktop 앱도 확인하세요." 118
$localPortStatus=Add-Text '로컬 설정 포트: 아직 확인하지 않았습니다. 포트 응답은 Sunshine 로그인이나 화면 연결 성공을 의미하지 않습니다.' 46
$checkLocal=Add-Button '설정 상태 새로고침' { Invoke-SunshineLocalCheck }
$localCheckCancel=Add-Button '설정 포트 확인 취소' { $script:cancelLocalCheck=$true } -AllowDuringUpdate; $localCheckCancel.Visible=$false
$open = Add-Button '이 Windows에서 Sunshine 설정 열기' { Invoke-SunshineLocalCheck -Open Settings }
$encryption = Add-Button '영상 암호화 설정 열기' { Invoke-SunshineLocalCheck -Open Encryption }
$null = Add-Text '직접 열기: 이 Windows의 Edge/Chrome → https://localhost:47990/ · localhost는 현재 브라우저를 연 컴퓨터를 뜻합니다. Mac에서는 열지 마세요.' 48
$services=Add-Button 'Windows 서비스 상태 직접 확인…' {
    try { Start-Process 'services.msc'; $status.Text='Windows 서비스 목록에서 Sunshine 상태를 직접 확인하세요. Knot은 서비스를 자동으로 시작하거나 설정을 바꾸지 않았습니다.' }
    catch { $status.Text='Windows 서비스 창을 열지 못했습니다. Windows 시작 메뉴에서 「서비스」를 검색한 뒤 Sunshine 상태를 직접 확인하세요.' }
}
$headless = Add-Button '모니터 없이 사용… (선택)' {
    Set-Busy $true
    try { & (Join-Path $PSScriptRoot 'Show-HeadlessSetup.ps1') -Owner $form -LauncherPath $LauncherPath }
    catch { Show-Failure $_ }
    finally { Set-Busy $false }
}
$null = Add-Text '3   Mac에서 PIN 만들기 → 이 Windows에서 승인' 30
$null = Add-Text 'Mac의 Windows 화면에서 근처 PC 선택 → 「PIN으로 연결」을 누르세요. Mac에 표시된 PIN을 아래 버튼으로 연 이 Windows의 Sunshine 페이지에 입력합니다. Windows에서 PIN 승인을 마친 뒤 Mac에서 「Windows 열기」를 누르세요.' 65
$pin=Add-Button '이 Windows에서 PIN 입력 화면 열기' { Invoke-SunshineLocalCheck -Open PIN }
$null = Add-Text 'Sunshine 로그인이 먼저 나오면 2단계에서 만든 계정으로 로그인한 뒤 PIN 메뉴를 여세요. 설정을 바꾼 뒤에도 기존 PIN 페어링은 지우지 마세요. PC가 목록에 없으면 아래 QR / 링크를 사용하세요.' 55
$script:section=$flow
$null = Add-Text 'Windows의 연결 준비 창을 열어 두세요. 이어서 Mac에서 근처 PC → PC 확인 → PIN으로 연결을 누르고, Windows 창에서 Mac의 요청과 PIN을 승인합니다. 검색되지 않으면 QR / 링크를 사용하세요.' 68
$qrButton = Add-Button '연결 QR / 링크 보기…' {
    Set-Busy $true
    try {
        if (-not $addresses.SelectedItem) { throw '먼저 Wi-Fi 또는 Tailscale에 연결한 뒤 주소를 새로고침하세요.' }
        $items=@([string]$addresses.SelectedItem) + @($addresses.Items | ForEach-Object { [string]$_ })
        $unique=@($items | Select-Object -Unique)
        $chosen=@($unique | Select-Object -First 8)
        if ($unique.Count -gt 8) { $status.Text='연결 QR에 선택한 주소를 포함한 8개를 넣었습니다. 나머지 ' + ($unique.Count-8) + '개는 주소 목록에서 선택한 뒤 QR을 다시 만드세요.' }
        $link=New-DeskBridgeConnectionLink -PCName $env:COMPUTERNAME -Address $chosen
        & (Join-Path $PSScriptRoot 'Show-ConnectionQR.ps1') -Link $link -Owner $form
    } catch { Show-Failure $_ }
    finally { Set-Busy $false }
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'DeskBridge-QR.dll') -PathType Leaf)) { $qrButton.Text='연결 링크 보기…' }
$null = Add-Text '연결 QR과 링크에는 주소만 들어 있습니다. PIN 승인은 별도로 필요합니다. Wi-Fi 또는 Tailscale 양쪽에서 도달 가능한 주소를 선택하세요.' 48
$qrAddressHint=Add-Text (Get-QRAddressHintText '' 0) 48
$qrAddressHint.AccessibleName='QR에 포함되는 연결 주소'
$addresses=New-Object Windows.Forms.ComboBox; $addresses.AccessibleName='이 PC의 연결 주소'; $addresses.AccessibleDescription='Mac에서 도달할 수 있는 Wi-Fi 또는 Tailscale 주소를 선택하세요.'; $addresses.DropDownStyle='DropDownList'; $addresses.Width=710
$addresses.Add_SelectedIndexChanged({ $qrAddressHint.Text=Get-QRAddressHintText ([string]$addresses.SelectedItem) $addresses.Items.Count })
function Update-WindowsAddresses {
    $previous=[string]$addresses.SelectedItem
    $addresses.Items.Clear()
    foreach ($item in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object InterfaceMetric,IPAddress)) {
        try {
            $ip=Get-PrivateIPv4 $item.IPAddress
            if ($ip.StartsWith('169.254.') -or [string]$item.AddressState -ne 'Preferred' -or [string]$item.InterfaceAlias -like 'vEthernet*') { continue }
            if (-not $addresses.Items.Contains($ip)) { [void]$addresses.Items.Add($ip) }
        } catch {}
    }
    if ($addresses.Items.Contains($previous)) { $addresses.SelectedItem=$previous }
    elseif ($addresses.Items.Count -gt 0) { $addresses.SelectedIndex=0 }
    $qrAddressHint.Text=Get-QRAddressHintText ([string]$addresses.SelectedItem) $addresses.Items.Count
}
$advancedPanel.Controls.Add($addresses)
$script:section=$advancedPanel
$copy = Add-Button '선택한 Windows 주소 복사' {
    if ($addresses.SelectedItem) {
        try { [Windows.Forms.Clipboard]::SetText([string]$addresses.SelectedItem); $status.Text='주소를 복사했습니다. Mac의 원격 화면 탭에 입력하세요.' }
        catch { Show-Failure $_ }
    } else { $status.Text='연결 가능한 주소가 없습니다. Wi-Fi 또는 Tailscale에 연결한 뒤 주소를 새로고침하세요.' }
}
$refresh = Add-Button '주소 새로고침' { try { Update-WindowsAddresses } catch { Show-Failure $_ } }
$script:section=$flow
$filesToggle = Add-Button '＋ 파일 전송도 설정하기 (선택)' {}
$filePanel=New-Object Windows.Forms.FlowLayoutPanel
$filePanel.FlowDirection='TopDown'; $filePanel.WrapContents=$false; $filePanel.AutoSize=$true
$filePanel.AutoSizeMode='GrowAndShrink'; $filePanel.Width=710; $filePanel.Visible=$false
$flow.Controls.Add($filePanel)
$filesToggle.Add_Click({
    $filePanel.Visible=-not $filePanel.Visible
    $filesToggle.Text=if ($filePanel.Visible) {'－ 파일 전송 설정 접기'} else {'＋ 파일 전송도 설정하기 (선택)'}
    if ($filePanel.Visible) { $flow.ScrollControlIntoView($filePanel) }
})
$script:section=$filePanel
$null = Add-Text '파일 전송 · 필요할 때 한 번' 30
$null = Add-Text '화면 연결에는 아래 설정이 필요 없습니다. 파일 기능은 Mac 전용 키와 별도의 Windows 파일 계정을 사용합니다.' 42
$null = Add-Text 'Mac의 파일 탭에서 자동 파일 설정을 시작하고 표시된 일회용 연결을 아래에 붙여 넣으세요. 공개 설정을 자동으로 주고받으며 개인 키는 Mac에 남습니다.' 48
$null = Add-Text 'Mac에서 Windows 대상을 Tailscale 주소로 선택했다면 Mac 설정 주소도 Tailscale 주소를 사용하세요. 같은 Wi-Fi에서는 두 PC의 Wi-Fi 주소를 선택하세요. 주소 종류를 섞으면 자동 연결이 거부될 수 있습니다.' 64
$script:enrollmentClient=$null; $script:enrollmentRequest=$null
$enrollmentBox=New-Object Windows.Forms.TextBox; $enrollmentBox.Width=710
$enrollmentBox.AccessibleName='Mac의 일회용 자동 파일 설정 연결'; $filePanel.Controls.Add($enrollmentBox)
$automatic=Add-Button '자동 파일 설정 · Mac 연결 받기…' {
    Set-Busy $true; $client=$null
    try {
        if ([string]::IsNullOrWhiteSpace($LauncherPath)) { throw '자동 파일 설정에는 설치된 Knot EXE를 사용하세요. 개발자 소스 폴더에서는 아래 JSON 복구를 사용하세요.' }
        $client=Start-KnotFileEnrollment (([string]$enrollmentBox.Text).Trim([char[]]" `t`r`n"))
        $enrollmentBox.Clear()
        $enrollmentCancel.Visible=$true; $enrollmentCancel.Enabled=$true
        $script:enrollmentClient=$client
        $status.Text='Mac에 보안 연결하고 공개 설정을 받는 중…'
        while (-not $client.Request.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        $bytes=$client.Request.GetAwaiter().GetResult()
        $text=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)
        $expected=ConvertFrom-MacSetup $text
        if ($expected.requestID -cne $client.Connection.SessionID -or $expected.allowedClientAddresses -cnotcontains $client.Connection.Address) { throw '현재 Mac 자동 설정 연결과 받은 공개 설정이 다릅니다. Mac에서 새로 시작하세요.' }
        # The Mac admitted this exact TCP peer. Reuse its local interface address
        # for the reply rather than the first Wi-Fi/virtual-adapter selection.
        $automaticAddress=[Knot.Enrollment.Client]::SelectLocalAddress($client.LocalAddress,[string[]]@($addresses.Items))
        $client.AuthorizeReply([string]$expected.requestID,[string[]]@($expected.allowedClientAddresses))
        $addresses.SelectedItem=$automaticAddress
        $script:enrollmentRequest=$expected
        Invoke-FileSetup 'EnableFiles' -AutomaticRequest $expected -AutomaticClient $client
    } catch { Show-Failure $_ }
    finally {
        $script:enrollmentRequest=$null; $script:enrollmentClient=$null
        if ($client) { $client.Cancel(); $client.Dispose() }
        $enrollmentCancel.Visible=$false
        Set-Busy $false
    }
}
$enrollmentCancel=Add-Button '자동 파일 설정 연결 취소' {
    if ($script:enrollmentClient) { $script:enrollmentClient.Cancel() }
    $enrollmentCancel.Enabled=$false
} -AllowDuringUpdate
$enrollmentCancel.Visible=$false
$null=Add-Text '수동 복구: 자동 연결이 어려울 때만 Mac에서 설정 JSON을 저장해 아래에서 불러오세요.' 40
$requestBox = New-Object Windows.Forms.TextBox; $requestBox.ReadOnly=$true; $requestBox.Width=710; $filePanel.Controls.Add($requestBox)
$requestBox.AccessibleName='불러온 Mac 설정 파일'; $requestBox.AccessibleDescription='Mac 설정 파일 불러오기에서 선택한 JSON 파일의 위치입니다.'
$load = Add-Button 'Mac 설정 파일 불러오기…' {
    try {
        $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Filter='Knot JSON (*.json)|*.json'
        if ($dialog.ShowDialog() -eq 'OK') {
            try { $request=Read-MacSetup $dialog.FileName } catch { throw 'Mac 설정 파일의 형식이나 공개 키·허용 주소를 확인하지 못했습니다. Mac의 파일 탭에서 새 설정 JSON을 저장해 다시 불러오세요.' }
            $requestBox.Text=$dialog.FileName
            $status.Text='허용할 Mac: ' + ($request.allowedClientAddresses -join ', ') + '. 파일 설정은 새 전용 계정과 공유 폴더를 만듭니다.'
        }
        $dialog.Dispose()
    } catch { $requestBox.Text=''; Show-Failure $_ }
}
function Invoke-FileSetup([string] $Operation, $AutomaticRequest=$null, $AutomaticClient=$null) {
    # Set only after a validated native completion and canonical current reply.
    $confirmedAutomaticReply=$null
    Set-Busy $true
    if ($AutomaticClient) { $enrollmentCancel.Enabled=$true }
    try {
        $expected=$null; $requestPath=$null; $selectedAddress=$null
        if ($Operation -ne 'DisableFiles') {
            if ($AutomaticRequest) {
                if (-not $LauncherPath -or -not $AutomaticClient.Active) { throw '자동 파일 설정 연결이 만료되었거나 취소되었습니다. Mac에서 새로 시작하세요.' }
                $expected=ConvertFrom-MacSetup ($AutomaticRequest | ConvertTo-Json -Depth 4 -Compress)
            } else {
            $requestPath=[string]$requestBox.Text
            if ([string]::IsNullOrWhiteSpace($requestPath)) { throw '먼저 Mac 설정 파일을 불러오세요.' }
            try { $expected=Read-MacSetup $requestPath } catch { throw 'Mac 설정 파일을 읽지 못했습니다. Mac에서 새로 저장한 JSON 파일을 불러오세요.' }
            }
            if (-not $addresses.SelectedItem) { throw 'Windows 주소를 선택하세요.' }
            $selectedAddress=Get-PrivateIPv4 ([string]$addresses.SelectedItem)
        }
        $desktopUser=$null
        if ($Operation -eq 'EnableFiles') {
            # Capture THIS non-elevated user's SID before UAC, including alternate-admin credentials.
            try { $desktopUser=Resolve-DesktopUser ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
            catch { throw (Get-SetupFailureText $_ -Context 'DesktopUser') }
        }
        $message=if ($Operation -eq 'DisableFiles') {'파일 접속을 해제하고 현재 파일 연결을 종료합니다. 공유 파일은 보존됩니다.'} elseif ($Operation -eq 'EnableFiles') {
            'OpenSSH Server, 전용 일반 계정, Knot 공유 폴더 (기존 파일 경로 유지), 선택한 Mac 주소 전용 방화벽을 설정합니다. 공유 파일을 사용할 Windows 사용자: ' + $desktopUser.Name + ' (' + $desktopUser.SID.Value + '). 기존 SSH 설정은 바꾸지 않습니다. 계속할까요?'
        } else {'Windows 호스트 공개 키를 내보내기 위해 관리자 확인이 필요합니다.'}
        if ($Operation -eq 'EnableFiles') {
            $message += "`n`nMac 공개 키 지문: " + (Get-KeyFingerprint $expected.clientPublicKey)
            $message += "`n`n허용할 Mac 주소: " + ([string[]]$expected.allowedClientAddresses -join ', ') + "`n이 주소와 등록한 SSH 키로만 파일 접속을 허용합니다. 주소를 직접 확인하세요."
        }
        if ([Windows.Forms.MessageBox]::Show($message,'Knot','OKCancel','Information') -ne 'OK') { return }
        if ($LauncherPath) {
            $elevatedExecutable=$LauncherPath
            $arguments='--elevated-operation ' + $Operation
            if ($Operation -ne 'DisableFiles') {
                # Freeze only validated PUBLIC data; no user-owned script or request-file path crosses UAC.
                $requestJson=$expected | ConvertTo-Json -Depth 4 -Compress
                $requestBytes=[Text.Encoding]::UTF8.GetBytes($requestJson)
                if ($requestBytes.Length -gt 16384) { throw 'Setup request is too large.' }
                $arguments += ' --request-base64 ' + [Convert]::ToBase64String($requestBytes) + ' --windows-address ' + $selectedAddress
            }
            if ($desktopUser) { $arguments += ' --desktop-user-sid ' + $desktopUser.SID.Value }
        } else {
            # Source/developer folders are a manual script workflow, outside the primary EXE broker.
            if ([Windows.Forms.MessageBox]::Show('개발자 폴더의 PowerShell 스크립트를 관리자 권한으로 실행합니다. 배포용 Knot EXE를 사용하는 것이 좋습니다. 계속할까요?','Knot · 수동 개발자 설정','OKCancel','Warning') -ne 'OK') { return }
            $elevatedExecutable=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $script=Join-Path $PSScriptRoot 'Invoke-DeskBridgeSetup.ps1'
            $arguments='-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "' + $script + '" -Operation ' + $Operation
            if ($Operation -ne 'DisableFiles') { $arguments += ' -RequestPath "' + $requestPath + '" -WindowsAddress "' + $selectedAddress + '"' }
            if ($desktopUser) { $arguments += ' -DesktopUserSid "' + $desktopUser.SID.Value + '"' }
        }
        if ($AutomaticClient -and -not $AutomaticClient.Active) { throw '자동 파일 설정이 만료되었거나 취소되었습니다. Mac에서 새로 시작하세요.' }
        $status.Text='관리자 창에서 설정을 진행 중입니다. 완료 후 이 창으로 돌아오세요.'
        $process=Start-Process -FilePath $elevatedExecutable -Verb RunAs -ArgumentList $arguments -PassThru
        $null=$process.Handle
        # Keep the non-elevated form repainting while the separate administrator window works.
        while (-not $process.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $process.WaitForExit()
        if ($LauncherPath -and $process.ExitCode -eq 2) { $status.Text='설정을 완료하지 못했습니다. 표시된 오류 안내를 확인한 뒤 다시 시도하세요.'; return }
        if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) { throw '설정을 완료하지 못했습니다. 관리자 창의 오류를 확인하세요. 기존 SSH가 있다면 수동 통합 안내를 사용하세요.' }
        if (-not $LauncherPath) { $status.Text='수동 설정 명령이 종료되었습니다. Ctrl+C로 중단해도 성공 코드가 반환될 수 있으므로 관리자 창과 실제 설정에서 완료 여부를 확인하세요. 자동 완료 확인과 연결 파일 저장은 배포용 EXE를 사용하세요.'; return }
        if ($Operation -eq 'DisableFiles') { $status.Text='Knot 파일 접속을 해제했습니다. 공유 파일은 유지됩니다. OpenSSH 설치와 기존 서비스 시작·방화벽 정책은 그대로 남거나 원래 상태로 복원될 수 있습니다. 필요하지 않다면 Windows 관리자와 기존 설정을 확인하세요.'; return }
        $replyPath=Join-Path $env:ProgramData 'DeskBridgeSetup\connection.json'
        $reply=Get-Content -LiteralPath $replyPath -Raw | ConvertFrom-Json
        if ($reply.requestID -cne $expected.requestID -or $reply.clientPublicKey -cne $expected.clientPublicKey -or $reply.address -cne $selectedAddress) { throw 'Windows 연결 결과가 현재 Mac 설정과 다릅니다. 설정 파일과 선택한 PC 주소를 다시 확인하세요.' }
        $fingerprint=Get-KeyFingerprint $reply.serverPublicKey
        $confirmedAutomaticReply=[pscustomobject]@{Fingerprint=$fingerprint}
        $status.Text="Windows SSH 지문 (Mac 화면과 비교):`r`n" + $fingerprint
        if ($AutomaticClient) {
            if (-not $AutomaticClient.Active) { throw 'Windows 파일 설정은 완료됐지만 Mac 자동 연결이 만료되었습니다. 새 Mac 연결로 다시 시도하거나 연결 파일 다시 저장을 사용하세요. 설정을 제거할 필요가 없습니다.' }
            $replyText=$reply | ConvertTo-Json -Depth 4 -Compress
            $send=$AutomaticClient.SendReplyAsync($replyText)
            while (-not $send.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            $send.GetAwaiter().GetResult()
            $status.Text="파일 설정을 Mac에 전달했습니다. Mac에서 아래 SSH 지문이 같은지 확인하고 등록하세요.`r`nWindows SSH 지문: " + $fingerprint
            return
        }
        $save=New-Object Windows.Forms.SaveFileDialog; $save.Filter='Knot JSON (*.json)|*.json'; $save.FileName='Knot-Windows-Connection.json'
        $saved=Save-DeskBridgeConnectionReply -Reply $reply -Dialog $save
        if ($saved -eq 'Saved') { $status.Text+="`r`n연결 파일을 저장했습니다. Mac에서 불러오세요." }
        else {
            $detail=if ($saved -eq 'Cancelled') {'연결 파일 저장을 취소했습니다.'} else {'연결 파일을 저장하지 못했습니다.'}
            $status.Text="파일 설정 완료 · " + $detail + "`r`nWindows SSH 지문: " + $fingerprint + "`r`n‘이미 설정한 연결 파일 다시 저장’으로 다시 저장하세요. 설정을 다시 설치할 필요가 없습니다."
        }
    } catch {
        if ($AutomaticClient -and $null -ne $confirmedAutomaticReply) {
            # Native provisioning/export succeeded and this request's public
            # reply was validated. Delivery failure must not erase its verified
            # SSH fingerprint or misreport Windows activation as failed. Render
            # fixed authored guidance only; never surface transport exceptions.
            $status.Text="Windows 파일 설정 완료 · Mac으로 연결 결과를 전달하지 못했습니다.`r`nWindows SSH 지문: " + $confirmedAutomaticReply.Fingerprint + "`r`nMac에서 새 자동 파일 설정 연결을 만든 뒤 같은 Mac 키로 다시 시도하세요. 또는 「이미 설정한 연결 파일 다시 저장」으로 전달하세요. 파일 접속을 해제하거나 다시 설치할 필요는 없습니다. Mac에서 SSH 지문을 직접 비교한 뒤 등록하세요."
        } else { Show-Failure $_ }
    }
    finally { Set-Busy $false }
}
$enable = Add-Button '파일 전송 설정 · 연결 파일 만들기…' { Invoke-FileSetup 'EnableFiles' }
$export = Add-Button '이미 설정한 연결 파일 다시 저장…' { Invoke-FileSetup 'Export' }
$disable = Add-Button '이 Windows의 파일 접속 해제…' { Invoke-FileSetup 'DisableFiles' }
$null = Add-Text '저장한 Windows 연결 파일을 Mac에서 불러오고, 표시된 SSH 지문이 같은지 직접 비교하세요. 공유 폴더: Knot 공유 폴더 (기존 파일 경로 유지)' 50
$script:setupContentWidth=-1; $script:setupContentDpi=0
function Resize-SetupContent {
    $available=[Math]::Max(280,$flow.ClientSize.Width-$flow.Padding.Horizontal-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth-12)
    if ($available -eq $script:setupContentWidth -and $form.DeviceDpi -eq $script:setupContentDpi) { return }
    $script:setupContentWidth=$available; $script:setupContentDpi=$form.DeviceDpi
    $flow.SuspendLayout(); $filePanel.SuspendLayout()
    try {
        if ($filePanel.Width -ne $available) { $filePanel.Width=$available }
        if ($advancedPanel.Width -ne $available) { $advancedPanel.Width=$available }
        foreach ($control in (Get-SetupControls $flow)) {
            if ($control -is [Windows.Forms.Label]) {
                if ($control.MaximumSize.Width -ne $available) { $control.MaximumSize=New-Object Drawing.Size($available,0) }
            } elseif ($control -is [Windows.Forms.TextBox] -or $control -is [Windows.Forms.ComboBox]) {
                if ($control.Width -ne $available) { $control.Width=$available }
            } elseif ($control -is [Windows.Forms.Button]) {
                $buttonWidth=[Math]::Min([int][Math]::Round(330*$form.DeviceDpi/96.0),$available)
                if ($control.Width -ne $buttonWidth) { $control.Width=$buttonWidth }
            }
        }
    } finally { $filePanel.ResumeLayout($true); $flow.ResumeLayout($true) }
}
$flow.Add_SizeChanged({ Resize-SetupContent })
$form.Add_Shown({
    $area=[Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.MinimumSize=New-Object Drawing.Size([Math]::Min($form.MinimumSize.Width,$area.Width),[Math]::Min($form.MinimumSize.Height,$area.Height))
    $form.Size=New-Object Drawing.Size([Math]::Min($form.Width,$area.Width),[Math]::Min($form.Height,$area.Height))
    $form.Location=New-Object Drawing.Point(($area.Left+($area.Width-$form.Width)/2),($area.Top+($area.Height-$form.Height)/2))
    Resize-SetupContent
    Update-WindowsAddresses
    # Opening Knot is the user's connection-preparation action. Source scripts stay manual.
    if ($LauncherPath) { $form.BeginInvoke([Action]{ Invoke-QuickSetup }) | Out-Null }
})
$form.Add_FormClosing({param($sender,$eventArgs) if ($form.UseWaitCursor) {$eventArgs.Cancel=$true}})
[void]$form.ShowDialog()
$roleExit=if ($form.Tag -in @(10,11,12)) {[int]$form.Tag} else {0}
if ($form.Icon) { $form.Icon.Dispose() }
$form.Dispose()
exit $roleExit
