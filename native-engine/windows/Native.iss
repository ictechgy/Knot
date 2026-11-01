; SPDX-License-Identifier: GPL-3.0-only
#ifndef NativeOutput
  #error NativeOutput must name the checked native experiment output directory
#endif
#ifndef NativeVersion
  #error NativeVersion must name the checked native preview version
#endif
#ifndef NativeNumericVersion
  #error NativeNumericVersion must name its four-part numeric file version
#endif
[Setup]
AppId={{17D88B30-1311-463F-A795-EE397E601B39}
AppName=Knot Native Preview
AppVersion={#NativeVersion}
AppVerName=Knot Native Preview {#NativeVersion}
AppPublisher=Knot contributors
VersionInfoProductName=Knot Native Preview
VersionInfoVersion={#NativeNumericVersion}
VersionInfoTextVersion={#NativeNumericVersion}
VersionInfoProductVersion={#NativeNumericVersion}
VersionInfoProductTextVersion={#NativeVersion}
VersionInfoDescription=Experimental independent Windows host
DefaultDirName={localappdata}\Programs\Knot Native Preview
DefaultGroupName=Knot Native Preview
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir={#NativeOutput}
OutputBaseFilename=Knot-Native-{#NativeVersion}-windows-x64-setup
SetupIconFile=..\..\Assets\Brand\AppIcon.ico
UninstallDisplayIcon={app}\AppIcon.ico
UninstallDisplayName=Knot Native Preview
LicenseFile=..\..\LICENSE
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no
[Files]
Source: "{#NativeOutput}\Knot-Native-Preview.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#NativeOutput}\KnotNativeMedia.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#NativeOutput}\KnotNativePairing.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#NativeOutput}\AppIcon.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\pairing\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
[Icons]
Name: "{group}\Knot Native Preview"; Filename: "{app}\Knot-Native-Preview.exe"; IconFilename: "{app}\AppIcon.ico"
[Run]
Filename: "{app}\Knot-Native-Preview.exe"; Description: "Open Knot Native Preview"; Flags: nowait postinstall skipifsilent
