; Inno Setup script — wraps the PyInstaller --onedir output of the LAN Media
; Wall Windows player into a single self-contained install wizard
; (lan-media-wall-player-setup.exe).
;
; SourceDir and OutputDir are injected by the CI step via /D defines so this
; script does not hard-code runner paths:
;   ISCC.exe /DMySourceDir="...\dist\lan-media-wall-player" /DMyOutputDir="...\installer_out"
;
; The PyInstaller onedir layout is: <exe> at the root plus an _internal\ folder
; holding Python, the co-bundled mpv.exe and config.example.yaml. We ship the
; whole tree so the runtime hook (rthook_mpv.py) finds mpv.exe via sys._MEIPASS.

#ifndef MySourceDir
  #define MySourceDir "..\dist\lan-media-wall-player"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\installer_out"
#endif

[Setup]
AppName=LAN Media Wall Player
AppVersion=1.0.1
DefaultDirName={autopf}\LAN Media Wall Player
DefaultGroupName=LAN Media Wall Player
UninstallDisplayIcon={app}\lan-media-wall-player.exe
OutputDir={#MyOutputDir}
OutputBaseFilename=lan-media-wall-player-setup
Compression=lzma2/ultra
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Files]
; Recurse the entire onedir tree (exe + _internal\...).
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\LAN Media Wall Player"; Filename: "{app}\lan-media-wall-player.exe"
Name: "{group}\Uninstall LAN Media Wall Player"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\lan-media-wall-player.exe"; Description: "Launch LAN Media Wall Player"; Flags: nowait postinstall skipifsilent
