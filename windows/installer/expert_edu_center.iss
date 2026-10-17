; Windows installer (Inno Setup 6), built by .github/workflows/windows.yml:
;   iscc /DAppVersion=1.7.1 /DBuildNumber=9 windows\installer\expert_edu_center.iss
; from the repo root, after `flutter build windows --release`.
;
; Installs per user (no administrator rights), so the app can update
; itself: it downloads the next setup and runs it with /SILENT, which
; closes the running app, replaces the files and starts it again.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BuildNumber
  #define BuildNumber "0"
#endif

#define AppName "Expert Edu Center"
#define AppExe "expert_edu_center.exe"
#define Release "..\..\build\windows\x64\runner\Release"

[Setup]
; Never change: it's how Windows recognises an update to the same app.
AppId={{7F3D2BCF-594A-4190-8DC5-DF63F855F877}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
VersionInfoVersion={#AppVersion}.{#BuildNumber}
AppPublisher=Expert Learning Center
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\windows\installer
OutputBaseFilename=expert-edu-center-setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; An update closes the running app first, and the [Run] entry below
; starts it again.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Files a previous version had and this one doesn't.
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; After a normal install: the "Launch" checkbox on the last page.
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; After a silent self-update: start the app again straight away.
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: WizardSilent
