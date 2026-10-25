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
SetupMutex=KnotInstaller-7BB82A17-E531-4D04-A1FA-E8912E9E8E99,Global\KnotInstaller-7BB82A17-E531-4D04-A1FA-E8912E9E8E99
OutputDir=..\..\dist\release
OutputBaseFilename=Knot-{#AppVersion}-windows-x64-setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
PrivilegesRequired=admin
WizardStyle=modern
AppComments=진행 중인 설정을 기다리고 Knot을 자동 종료·업데이트·재실행합니다.
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
Filename: "{app}\Knot.exe"; Flags: nowait runasoriginaluser; Check: RestartFromThisInstaller
[Code]
function RestartFromThisInstaller(): Boolean;
begin
  { The non-elevated signed-update handoff owns its own single restart. }
  Result := ExpandConstant('{param:KNOTUPDATERHANDOFF|0}') <> '1';
end;

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
    Result := '진행 중인 설정이 아직 끝나지 않았거나 Knot의 정상 종료를 확인하지 못했습니다. 설정이 끝나면 다시 시도하세요. 강제 종료하지 않았으며 기존 앱·Sunshine·파일 설정은 보존됩니다.';
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
