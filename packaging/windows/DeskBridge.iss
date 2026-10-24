; SPDX-License-Identifier: GPL-3.0-only
#ifndef AppVersion
  #define AppVersion "0.2.0-preview.19"
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
OutputDir=..\..\dist\release
OutputBaseFilename=Knot-{#AppVersion}-windows-x64-setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
PrivilegesRequired=admin
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\Assets\Brand\AppIcon.ico
UninstallDisplayName=Knot Windows Setup
UninstallDisplayIcon={app}\AppIcon.ico
DisableProgramGroupPage=yes
CloseApplications=no
[Files]
Source: "..\..\build\windows\Knot-Windows.exe"; DestDir: "{app}"; DestName: "DeskBridge-Windows.exe"; Flags: ignoreversion
Source: "..\..\Vendor\QRCodegen\NOTICE"; DestDir: "{app}"; DestName: "QRCodegen-LICENSE"; Flags: ignoreversion
Source: "..\..\Vendor\WindowsRuntime\NOTICE"; DestDir: "{app}"; DestName: "WindowsRuntime-NOTICE"; Flags: ignoreversion
Source: "..\..\host\windows\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\INSTALLATION.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\Assets\Brand\AppIcon.ico"; DestDir: "{app}"; Flags: ignoreversion
[InstallDelete]
; Remove only the two default shortcuts owned by the former installer.
Type: files; Name: "{commonprograms}\DeskBridge\DeskBridge 설정.lnk"
Type: files; Name: "{commonprograms}\DeskBridge\DeskBridge 제거.lnk"
Type: dirifempty; Name: "{commonprograms}\DeskBridge"
[Icons]
Name: "{group}\Knot 설정"; Filename: "{app}\DeskBridge-Windows.exe"; IconFilename: "{app}\AppIcon.ico"
Name: "{group}\Knot 제거"; Filename: "{uninstallexe}"; IconFilename: "{app}\AppIcon.ico"
[Run]
Filename: "{app}\DeskBridge-Windows.exe"; Description: "Knot 설정 열기"; Flags: postinstall nowait skipifsilent runasoriginaluser
[Code]
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
  Launched := Exec(ExpandConstant('{app}\DeskBridge-Windows.exe'), BrokerArguments,
    ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Result := Launched and (ExitCode = 0);
  if not Result then begin
    Log('Knot access revocation/inactivity verification failed. Retaining helper and shared data for manual recovery.');
    if (not UninstallSilent) then
      MsgBox('파일 접속 해제나 비활성 상태 확인을 완료하지 못했습니다. 도우미를 유지합니다. 관리자가 기존 SSH 설정과 남아 있는 Knot 파일 접속을 확인한 뒤 제거하세요.', mbError, MB_OK);
  end;
end;
