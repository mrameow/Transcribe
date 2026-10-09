; Inno Setup script for the Windows installer. Built by .github/workflows/build.yml:
;   iscc /DAppVersion=1.2.3 windows\installer\transcribe.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{8F2B6C1E-4D7A-4B53-9E21-6A3C5D7F9B10}
AppName=Transcribe
AppVersion={#AppVersion}
AppVerName=Transcribe {#AppVersion}
AppPublisher=mrameow
AppPublisherURL=https://github.com/mrameow/Transcribe
DefaultDirName={localappdata}\Programs\Transcribe
DefaultGroupName=Transcribe
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=Transcribe-windows-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\transcribe.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Transcribe"; Filename: "{app}\transcribe.exe"
Name: "{autodesktop}\Transcribe"; Filename: "{app}\transcribe.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\transcribe.exe"; Description: "Start Transcribe"; Flags: nowait postinstall skipifsilent
