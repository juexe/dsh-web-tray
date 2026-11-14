#define MyAppName "DSH Web Tray"
#define MyAppPublisher "Juexe"
#define MyAppURL "https://github.com/juexe/dsh-web-tray"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\dist"
#endif

[Setup]
AppId={{BB109E8F-3178-4DD6-ABF2-98060CDDD7A5}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\dsh-web-tray
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
LicenseFile=..\LICENSE
OutputDir={#MyOutputDir}
OutputBaseFilename=dsh-web-tray-{#MyAppVersion}-setup
SetupIconFile=..\assets\dsh-web-tray.ico
UninstallDisplayIcon={app}\assets\dsh-web-tray.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
VersionInfoDescription=DSH Web Tray Setup
VersionInfoCompany={#MyAppPublisher}
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "zhcn"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dsh-web-tray.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dsh-web-tray.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\dsh-web-tray.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#MyAppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\dsh-web-tray.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\dsh-web-tray.ico"; Comment: "在系统托盘托管 DSH Web"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\dsh-web-tray.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\dsh-web-tray.ico"; Comment: "在系统托盘托管 DSH Web"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\dsh-web-tray.ps1"""; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\dsh-web-tray.ps1"" -Stop"; Flags: runhidden waituntilterminated; RunOnceId: "StopTrayHost"

[UninstallDelete]
Type: files; Name: "{userstartup}\DSH Web Tray.lnk"

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if Exec(ExpandConstant('{cmd}'), '/c where /q dsh', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode <> 0) then
  begin
    if SuppressibleMsgBox(
      '未在 PATH 中找到 dsh 命令。' + #13#10 + #13#10 +
      '请先安装 DeepSeek Harness CLI（npm install -g @deepseek-ai/dsh），并确认 dsh 已加入 PATH。' + #13#10 + #13#10 +
      '仍要继续安装吗？',
      mbConfirmation, MB_YESNO, IDYES) = IDNO then
      Result := False;
  end;
end;
