#ifndef AppVersion
  #error AppVersion must be supplied by build-windows-package.ps1
#endif
#ifndef SourceDir
  #error SourceDir must be supplied by build-windows-package.ps1
#endif
#ifndef ProjectDir
  #error ProjectDir must be supplied by build-windows-package.ps1
#endif
#ifndef ChineseLanguageFile
  #error ChineseLanguageFile must be supplied by build-windows-package.ps1
#endif

[Setup]
AppId={{A0AB43B2-4D95-4D29-9C2C-27B35B496EC9}
AppName=哈妮丝
AppVersion={#AppVersion}
AppVerName=哈妮丝 {#AppVersion}
AppPublisher=DesktopPet
DefaultDirName={localappdata}\Programs\DesktopPet
DefaultGroupName=哈妮丝
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
AppMutex=DesktopPetWindowsSingleInstance
CloseApplications=yes
RestartApplications=no
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#ProjectDir}\windows\cat-icon.ico
UninstallDisplayIcon={app}\DesktopPet-Windows-x64.exe
OutputBaseFilename=DesktopPet-Windows-v{#AppVersion}-Agent-x64-Setup
VersionInfoVersion={#AppVersion}
VersionInfoProductName=哈妮丝
VersionInfoDescription=哈妮丝 Windows Agent 安装程序
VersionInfoCompany=DesktopPet
#ifdef SigningEnabled
SignTool=desktoppet
SignedUninstaller=yes
#endif

[Languages]
Name: "chinesesimp"; MessagesFile: "{#ChineseLanguageFile}"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: filesandordirs; Name: "{app}\DesktopPetAgent"

[Icons]
Name: "{group}\哈妮丝"; Filename: "{app}\DesktopPet-Windows-x64.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\哈妮丝"; Filename: "{app}\DesktopPet-Windows-x64.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\DesktopPet-Windows-x64.exe"; Description: "启动哈妮丝"; Flags: nowait postinstall skipifsilent
