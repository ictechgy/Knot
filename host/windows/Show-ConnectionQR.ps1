#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string] $Link, [object] $Owner)
$ErrorActionPreference='Stop'
if ([Text.Encoding]::UTF8.GetByteCount($Link) -gt 1536 -or -not $Link.StartsWith('deskbridge://connect?')) { throw 'Invalid connection link.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$hasQR=Test-Path -LiteralPath (Join-Path $PSScriptRoot 'DeskBridge-QR.dll') -PathType Leaf
if ($hasQR) { Add-Type -LiteralPath (Join-Path $PSScriptRoot 'DeskBridge-QR.dll') }
$bitmap=$null; $stream=$null; $window=$null
try {
    # A raw developer folder offers links without the compiled QR library.
    # EXEs embed it; errors from a present library are never hidden.
    if ($hasQR) {
        $qr=[Net.Codecrete.QrCodeGenerator.QrCode]::EncodeText($Link,[Net.Codecrete.QrCodeGenerator.QrCode+Ecc]::Medium)
        $stream=New-Object IO.MemoryStream(,$qr.ToBmpBitmap(4,6))
        $bitmap=[Drawing.Image]::FromStream($stream)
    }
    $window=New-Object Windows.Forms.Form
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'AppIcon.ico') -PathType Leaf) {
        $window.Icon=New-Object Drawing.Icon((Join-Path $PSScriptRoot 'AppIcon.ico'))
        $window.Add_Disposed({ param($sender,$eventArgs) if ($sender.Icon) { $sender.Icon.Dispose() } })
    }
    $window.Text='Windows 연결 QR'; $window.Size=New-Object Drawing.Size(700,730)
    $window.MinimumSize=New-Object Drawing.Size(480,360); $window.AutoScaleDimensions=New-Object Drawing.SizeF(96,96); $window.AutoScaleMode='Dpi'; $window.StartPosition='CenterParent'; $window.Font=New-Object Drawing.Font('Segoe UI',10)
    if (-not $hasQR) { $window.Text='Windows 연결 링크'; $window.Size=New-Object Drawing.Size(700,370) }
    $panel=New-Object Windows.Forms.FlowLayoutPanel
    $panel.Dock='Fill'; $panel.FlowDirection='TopDown'; $panel.WrapContents=$false; $panel.AutoScroll=$true
    $panel.Padding=New-Object Windows.Forms.Padding(22); $window.Controls.Add($panel)
    $heading=New-Object Windows.Forms.Label
    $heading.Text=if ($hasQR) {'Mac에서 QR을 가져오세요'} else {'Mac에서 연결 링크를 가져오세요'}
    $heading.AutoSize=$true; $heading.MaximumSize=New-Object Drawing.Size(630,0)
    $heading.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold); $panel.Controls.Add($heading)
    if ($hasQR) {
        $picture=New-Object Windows.Forms.PictureBox
        $picture.AccessibleName='이 Windows PC의 연결 QR'; $picture.AccessibleDescription='PC 이름과 주소를 담은 QR입니다. 아래 연결 링크를 복사하는 방법도 사용할 수 있습니다.'
        $picture.Image=$bitmap; $picture.SizeMode='Zoom'; $picture.Size=New-Object Drawing.Size(360,360)
        $picture.BackColor=[Drawing.Color]::White; $panel.Controls.Add($picture)
    }
    $help=New-Object Windows.Forms.Label
    $help.Text="Mac의 원격 화면에서 QR 이미지 열기 또는 카메라 스캔을 선택하세요.`r`nQR에는 이 PC의 이름·주소만 있습니다. 연결할 때 PIN으로 페어링합니다."
    if (-not $hasQR) { $help.Text="Mac의 원격 화면에서 연결 링크 입력을 선택하세요.`r`n이 개발자 폴더는 링크만 제공합니다. QR 이미지는 단일 EXE에서 만들 수 있습니다." }
    $help.AutoSize=$true; $help.MaximumSize=New-Object Drawing.Size(630,0); $panel.Controls.Add($help)
    $linkBox=New-Object Windows.Forms.TextBox
    $linkBox.AccessibleName='Windows 연결 링크'; $linkBox.AccessibleDescription='Mac의 연결 링크 입력에서 사용할 수 있습니다. 내용을 선택하거나 연결 링크 복사 버튼을 누르세요.'
    $linkBox.ReadOnly=$true; $linkBox.Multiline=$true; $linkBox.Size=New-Object Drawing.Size(630,58); $linkBox.Text=$Link
    $panel.Controls.Add($linkBox)
    $actions=New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize=$true; $actions.AutoSizeMode='GrowAndShrink'; $actions.MaximumSize=New-Object Drawing.Size(630,0); $panel.Controls.Add($actions)
    $save=New-Object Windows.Forms.Button; $save.Text='QR 이미지 저장…'; $save.Size=New-Object Drawing.Size(200,34)
    $save.Add_Click({
        $dialog=New-Object Windows.Forms.SaveFileDialog
        try {
            $dialog.Filter='PNG image (*.png)|*.png'; $dialog.FileName='Knot-Connection-QR.png'
            if ($dialog.ShowDialog($window) -eq 'OK') { $bitmap.Save($dialog.FileName,[Drawing.Imaging.ImageFormat]::Png) }
        } catch { [Windows.Forms.MessageBox]::Show('QR 이미지를 저장하지 못했습니다. 다른 위치를 선택하세요.','Knot','OK','Error') | Out-Null }
        finally { $dialog.Dispose() }
    }); if ($hasQR) { $actions.Controls.Add($save) }
    $copy=New-Object Windows.Forms.Button; $copy.Text='연결 링크 복사'; $copy.Size=New-Object Drawing.Size(200,34)
    $copy.Add_Click({
        try { [Windows.Forms.Clipboard]::SetText($Link) }
        catch { [Windows.Forms.MessageBox]::Show('링크를 복사하지 못했습니다. 위 링크를 직접 선택해 복사하세요.','Knot','OK','Error') | Out-Null }
    }); $actions.Controls.Add($copy)
    $script:qrContentWidth=-1
    $panel.Add_SizeChanged({
        $available=[Math]::Max(240,$panel.ClientSize.Width-$panel.Padding.Horizontal-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth-12)
        if ($available -eq $script:qrContentWidth) { return }
        $script:qrContentWidth=$available
        $panel.SuspendLayout()
        try {
            if ($heading.MaximumSize.Width -ne $available) { $heading.MaximumSize=New-Object Drawing.Size($available,0) }
            if ($help.MaximumSize.Width -ne $available) { $help.MaximumSize=New-Object Drawing.Size($available,0) }
            if ($linkBox.Width -ne $available) { $linkBox.Width=$available }
            if ($actions.MaximumSize.Width -ne $available) { $actions.MaximumSize=New-Object Drawing.Size($available,0) }
            if ($hasQR) {
                $side=[Math]::Min(360,$available)
                if ($picture.Width -ne $side -or $picture.Height -ne $side) { $picture.Size=New-Object Drawing.Size($side,$side) }
            }
        } finally { $panel.ResumeLayout($true) }
    })
    $window.Add_Shown({
        $area=[Windows.Forms.Screen]::FromControl($window).WorkingArea
        $window.MinimumSize=New-Object Drawing.Size([Math]::Min($window.MinimumSize.Width,$area.Width),[Math]::Min($window.MinimumSize.Height,$area.Height))
        $window.Size=New-Object Drawing.Size([Math]::Min($window.Width,$area.Width),[Math]::Min($window.Height,$area.Height))
        $window.Location=New-Object Drawing.Point(($area.Left+($area.Width-$window.Width)/2),($area.Top+($area.Height-$window.Height)/2))
    })
    if ($Owner) { [void]$window.ShowDialog($Owner) } else { [void]$window.ShowDialog() }
} finally {
    if ($window) { $window.Dispose() }
    if ($bitmap) { $bitmap.Dispose() }
    if ($stream) { $stream.Dispose() }
}
