; SPDX-License-Identifier: GPL-3.0-only
#ifndef AppVersion
  #define AppVersion "0.2.0-preview.20"
#endif
[Setup]
AppId={{7BB82A17-E531-4D04-A1FA-E8912E9E8E99}
AppName=Knot Windows Setup
AppVersion={#AppVersion}
AppVerName=Knot {#AppVersion}
AppPublisher=Knot contributors
VersionInfoProductName=Knot
VersionInfoDescription=Knot Windows x64 Setup
VersionInfoProductTextVersion={#AppVersion}
DefaultDirName={autopf}\Knot
UsePreviousAppDir=yes
DefaultGroupName=Knot
UsePreviousGroup=no
SetupMutex=KnotInstaller-7BB82A17-E531-4D04-A1FA-E8912E9E8E99
OutputDir=..\..\dist\release
OutputBaseFilename=Knot-{#AppVersion}-windows-x64-setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
PrivilegesRequired=admin
WizardStyle=modern
AppComments=실행 중인 Knot 창을 정상 종료하고 업데이트합니다. 진행 중인 원격 접속은 먼저 마쳐 주세요.
Compression=lzma2
SolidCompression=yes
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\Assets\Brand\AppIcon.ico
UninstallDisplayName=Knot Windows Setup
UninstallDisplayIcon={app}\AppIcon.ico
DisableProgramGroupPage=yes
CloseApplications=no
[Files]
Source: "..\..\build\windows\KnotCloseForUpdate.exe"; Flags: dontcopy
Source: "..\..\build\windows\Knot-Windows.exe"; DestDir: "{app}"; DestName: "Knot.exe"; Flags: ignoreversion
Source: "..\..\Vendor\QRCodegen\NOTICE"; DestDir: "{app}"; DestName: "QRCodegen-LICENSE"; Flags: ignoreversion
Source: "..\..\Vendor\WindowsRuntime\NOTICE"; DestDir: "{app}"; DestName: "WindowsRuntime-NOTICE"; Flags: ignoreversion
Source: "..\..\host\windows\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\INSTALLATION.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\Assets\Brand\AppIcon.ico"; DestDir: "{app}"; Flags: ignoreversion
[InstallDelete]
Type: files; Name: "{app}\DeskBridge-Windows.exe"
Type: files; Name: "{group}\Knot 설정.lnk"
; Remove only the two default shortcuts owned by the former installer.
Type: files; Name: "{commonprograms}\DeskBridge\DeskBridge 설정.lnk"
Type: files; Name: "{commonprograms}\DeskBridge\DeskBridge 제거.lnk"
Type: dirifempty; Name: "{commonprograms}\DeskBridge"
[Icons]
Name: "{group}\Knot"; Filename: "{app}\Knot.exe"; IconFilename: "{app}\AppIcon.ico"
Name: "{group}\Knot 제거"; Filename: "{uninstallexe}"; IconFilename: "{app}\AppIcon.ico"
[Run]
Filename: "{app}\Knot.exe"; Description: "Knot 열기 · 자동 연결 준비"; Flags: postinstall nowait skipifsilent runasoriginaluser
[Code]
function CloseInstalledKnot(const Name: String): Boolean;
var
  CloseResult: Integer;
begin
  Result := True;
  if not FileExists(ExpandConstant('{app}\' + Name)) then exit;
  Result := Exec(ExpandConstant('{tmp}\KnotCloseForUpdate.exe'),
      '"' + ExpandConstant('{app}\' + Name) + '"', ExpandConstant('{tmp}'),
      SW_HIDE, ewWaitUntilTerminated, CloseResult);
  Result := Result and (CloseResult = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  ExtractTemporaryFile('KnotCloseForUpdate.exe');
  if (not CloseInstalledKnot('DeskBridge-Windows.exe')) or (not CloseInstalledKnot('Knot.exe')) then
    Result := 'Knot 설정 작업이나 원격 연결을 먼저 마쳐 주세요. 관리자 준비 창도 닫은 뒤 다시 시도하면 설치가 계속됩니다. Sunshine 화면 공유와 파일 설정은 유지됩니다.';
end;

function InitializeSetup(): Boolean;
begin
  Result := not IsARM64;
  if not Result then
    MsgBox('This preview supports Windows 11 x64 only.', mbError, MB_OK);
end;

function InitializeUninstall(): Boolean;
var
  ExitCode: Integer;
  BrokerArguments: String;
  Launched: Boolean;
begin
  { Metadata absence is not proof of inactivity. The broker always inventories fixed resources. }
  Result := False;
  ExitCode := -1;
  Launched := False;
  if (not UninstallSilent) and
     (MsgBox('파일 접속 상태를 확인하고 설정된 Knot 파일 접속을 즉시 해제합니다. 이후 제거 확인을 취소해도 접속 해제는 유지됩니다. 상태를 확인할 수 없으면 제거를 중단합니다. 공유 파일과 Sunshine, 가상 화면은 보존됩니다. 가상 화면이 필요 없으면 먼저 Knot의 모니터 없이 사용에서 제거하세요. 계속할까요?', mbConfirmation, MB_OKCANCEL) <> IDOK) then
    exit;
  BrokerArguments := '--elevated-operation DisableFiles';
  if UninstallSilent then
    BrokerArguments := BrokerArguments + ' --silent';
  Launched := Exec(ExpandConstant('{app}\Knot.exe'), BrokerArguments,
    ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Result := Launched and (ExitCode = 0);
  if not Result then begin
    Log('Knot access revocation/inactivity verification failed. Retaining helper and shared data for manual recovery.');
    if (not UninstallSilent) then
      MsgBox('파일 접속 해제나 비활성 상태 확인을 완료하지 못했습니다. 도우미를 유지합니다. 관리자가 기존 SSH 설정과 남아 있는 Knot 파일 접속을 확인한 뒤 제거하세요.', mbError, MB_OK);
  end;
end;
