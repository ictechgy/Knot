#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-only
# Presentation only. Importing this module never probes or changes Windows state.
function Get-SetupFailureText($ErrorRecord,[ValidateSet('General','DesktopUser','ElevatedToken','VirtualDisplay')][string] $Context='General') {
    $cause=$ErrorRecord.Exception
    while ($cause) {
        if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) {
            return '관리자 확인을 취소했습니다. 필요할 때 다시 시작하세요.'
        }
        $cause=$cause.InnerException
    }
    if ($Context -ceq 'ElevatedToken') {
        return '이 창은 관리자 권한으로 실행되어 설정을 시작할 수 없습니다. 창을 닫고 공유 파일을 사용할 Windows 사용자로 Knot을 일반 실행하세요. UAC를 끈 환경이나 기본 Administrator 계정에서는 일반 실행도 관리자 권한일 수 있습니다. 이 경우 관리자에게 일반 사용자 환경 또는 수동 설정을 요청하세요.'
    }
    if ($Context -ceq 'DesktopUser') {
        return '파일 자동 설정에는 활성화된 로컬 Windows 사용자 계정이 필요합니다. Microsoft 계정에 연결된 로컬 사용자는 지원합니다. 도메인·Entra 계정이나 로컬 사용자 확인이 제한된 조직 PC는 Windows 관리자에게 수동 통합을 요청하세요.'
    }
    # Exact authored messages only. Localized OS exceptions can contain Korean
    # user names and paths; language or exception type is not a provenance marker.
    $known=@(
        '관리자 확인을 취소했습니다. 필요할 때 다시 시작하세요.',
        '파일 자동 설정에는 활성화된 로컬 Windows 사용자 계정이 필요합니다. Microsoft 계정에 연결된 로컬 사용자는 지원합니다. 도메인·Entra 계정이나 로컬 사용자 확인이 제한된 조직 PC는 Windows 관리자에게 수동 통합을 요청하세요.',
        'Sunshine 설치 파일 정보가 올바르지 않습니다. 새 Knot 배포 파일을 사용하세요.',
        'Sunshine 설치 파일 검증에 실패했습니다. 실행하지 않았습니다. 새로 다운로드해 다시 시도하세요.',
        'Sunshine 설치 결과를 확인하지 못했습니다. Windows 설치 안내를 확인하세요.',
        'Sunshine 설치를 완료하지 못했습니다. Windows 설치 안내의 오류를 확인한 뒤 다시 시도하세요.',
        '먼저 Wi-Fi 또는 Tailscale에 연결한 뒤 주소를 새로고침하세요.',
        'Mac 설정 파일의 형식이나 공개 키·허용 주소를 확인하지 못했습니다. Mac의 파일 탭에서 새 설정 JSON을 저장해 다시 불러오세요.',
        '먼저 Mac 설정 파일을 불러오세요.',
        'Mac 설정 파일을 읽지 못했습니다. Mac에서 새로 저장한 JSON 파일을 불러오세요.',
        'Windows 주소를 선택하세요.',
        '설정을 완료하지 못했습니다. 관리자 창의 오류를 확인하세요. 기존 SSH가 있다면 수동 통합 안내를 사용하세요.',
        'Windows 연결 결과가 현재 Mac 설정과 다릅니다. 설정 파일과 선택한 PC 주소를 다시 확인하세요.',
        '설치 파일의 다운로드 주소를 확인하지 못했습니다.',
        '설치 파일 크기를 확인하지 못했습니다.',
        '설치 파일이 예상 크기를 초과했습니다.',
        '설치 파일을 끝까지 내려받지 못했습니다.',
        '설치 파일 다운로드를 완료하지 못했습니다.',
        '다운로드 제한 시간 10분을 넘었습니다. 네트워크를 확인한 뒤 다시 시도하세요.',
        '60초 동안 다운로드가 진행되지 않았습니다. 네트워크를 확인한 뒤 다시 시도하세요.'
    )
    $cause=$ErrorRecord.Exception
    while ($cause) {
        $message=[string]$cause.Message
        if ($known -ccontains $message) { return $message }
        $cause=$cause.InnerException
    }
    if ($Context -ceq 'VirtualDisplay') {
        return '가상 화면 작업을 완료하지 못했습니다. Knot 배포 파일과 저장 폴더의 접근 권한·Windows 보안 정책을 확인한 뒤 상태를 새로고침하세요. 기존 드라이버와 복구 기록은 자동으로 덮어쓰지 않습니다.'
    }
    return 'Windows 설정을 완료하지 못했습니다. 저장 폴더의 접근 권한과 기존 OpenSSH 설정·조직 보안 정책을 확인하세요. 기존 SSH 서버나 조직에서 관리하는 PC는 수동 통합·승인된 배포 안내를 사용하세요.'
}
function Get-SunshineInstallResult([Nullable[int]] $ExitCode,[switch] $Broker) {
    $state='Failed'; $text='Sunshine 설치를 완료하지 못했습니다. Windows 설치 안내의 오류를 확인한 뒤 다시 시도하세요.'
    switch ($ExitCode) {
        0 { $state='Installed'; $text='Sunshine 설치 프로그램이 완료되었습니다. 화면 연결 준비는 아직 확인하지 않았습니다.' }
        1602 { $state='Cancelled'; $text='Sunshine 설치를 취소했습니다. 필요할 때 다시 시작하세요.' }
        1618 { $state='Retry'; $text='다른 Windows 설치 작업이 진행 중입니다. 해당 설치가 끝난 뒤 Sunshine 설치를 다시 시작하세요.' }
        1641 { $state='RestartInitiated'; $text='Sunshine 설치가 완료되어 Windows 재시작이 시작되었습니다. 재시작한 뒤 Sunshine 초기 설정을 진행하세요.' }
        3010 { $state='RestartRequired'; $text='설치를 완료하려면 Windows를 다시 시작해야 합니다. 재시작한 뒤 Sunshine 초기 설정을 진행하세요.' }
        2 { if ($Broker) { $state='HandledFailure'; $text='설치를 완료하지 못했습니다. 표시된 오류 안내를 확인한 뒤 다시 시도하세요.' } }
    }
    return [pscustomobject]@{State=$state;Text=$text}
}
function Set-SetupStatusText($Control,[string] $Text) {
    # Repeated download polls must preserve text selection and avoid duplicate accessibility events.
    if ([string]$Control.Text -cne $Text) { $Control.Text=$Text }
}
function Get-SunshineLocalPortText([bool] $Responded,[switch] $Cancelled) {
    if ($Cancelled) { return '로컬 설정 포트 확인을 취소했습니다. 설정 상태 새로고침으로 다시 확인할 수 있습니다.' }
    if ($Responded) {
        return '로컬 설정 포트 응답 (127.0.0.1:47990) · 이 Windows에서 설정 페이지를 열어 보세요. Sunshine 로그인·암호화 설정·화면 연결 성공을 확인한 것은 아닙니다.'
    }
    return '로컬 설정 포트(127.0.0.1:47990)가 아직 응답하지 않습니다. Sunshine은 별도 창 없이 백그라운드에서 실행됩니다. 설치 후 잠시 기다리거나 Windows를 다시 시작하고 상태를 새로고침하세요. 이 Windows의 브라우저에서 아래 주소를 직접 열어 볼 수도 있습니다. 계속 안 되면 Windows 서비스에서 Sunshine 상태를 직접 확인하세요.'
}
function Get-KnotHeadlessAvailabilityText([string] $Reason) {
    if ($Reason -ceq 'manifest-invalid') {
        return '함께 제공된 가상 화면 설치 파일 정보를 확인하지 못해 자동 설치를 중단했습니다. 새 Knot 배포 파일로 다시 시도하세요. 기존 화면과 복구 기록은 보존됩니다.'
    }
    return '가상 화면 자동 설치는 현재 사용할 수 없습니다. 외부 드라이버의 보안 검토가 끝날 때까지 설치를 보류했습니다. 모니터 또는 HDMI 더미 플러그로 기존 화면 연결을 이용할 수 있습니다.'
}
function Test-KnotHeadlessDeviceProbeRequired([string] $Status,[bool] $InstallEnabled) {
    # A verified absent deployment with blocked installation has no available device operation.
    # Every managed/recovery state still needs the existing fresh device identity check.
    return ($Status -cne 'Absent' -or $InstallEnabled)
}
Export-ModuleMember -Function Get-SetupFailureText,Get-SunshineInstallResult,Set-SetupStatusText,Get-SunshineLocalPortText,Get-KnotHeadlessAvailabilityText,Test-KnotHeadlessDeviceProbeRequired
