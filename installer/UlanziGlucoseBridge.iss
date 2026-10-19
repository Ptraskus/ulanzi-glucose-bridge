; Ulanzi Glucose Bridge - instalador por usuário
; Compile somente por scripts/build-release.ps1, que prepara uma origem saneada.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef AppVersionNumeric
  #define AppVersionNumeric "0.0.0.0"
#endif
#ifndef SourceDir
  #error SourceDir deve apontar para o payload saneado criado por build-release.ps1
#endif
#ifndef OutputDir
  #define OutputDir AddBackslash(SourcePath) + "Output"
#endif

#if FileExists(AddBackslash(SourceDir) + ".env")
  #error O payload contém .env e foi recusado
#endif
#if FileExists(AddBackslash(SourceDir) + ".env.new")
  #error O payload contém .env.new e foi recusado
#endif
#if FileExists(AddBackslash(SourceDir) + ".env.backup")
  #error O payload contém .env.backup e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + ".secrets")
  #error O payload contém .secrets e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + ".runtime")
  #error O payload contém .runtime e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + ".config-history")
  #error O payload contém histórico de configurações e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + ".updates")
  #error O payload contém downloads de atualizações e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + "backups")
  #error O payload contém backups e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + "firmware")
  #error O payload contém firmware e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + "diagnostics")
  #error O payload contém diagnósticos e foi recusado
#endif
#if DirExists(AddBackslash(SourceDir) + "diagnosticos")
  #error O payload contém diagnósticos e foi recusado
#endif

[Setup]
; Keep this AppId stable so existing installations upgrade in place.
AppId={{4B234792-EB6C-43EB-B892-FC97B9B91C34}
AppName=Ulanzi Glucose Bridge
AppVersion={#AppVersion}
AppVerName=Ulanzi Glucose Bridge {#AppVersion}
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductName=Ulanzi Glucose Bridge
VersionInfoDescription=Ulanzi Glucose Bridge Setup
VersionInfoCompany=Ulanzi Glucose Bridge contributors
AppPublisher=Ulanzi Glucose Bridge contributors
DefaultDirName={code:GetDefaultInstallDir}
DefaultGroupName=Ulanzi Glucose Bridge
UsePreviousGroup=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.17763
ArchitecturesAllowed=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Ulanzi-Glucose-Bridge-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=yes
RestartApplications=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes
Uninstallable=yes
UninstallDisplayName=Ulanzi Glucose Bridge {#AppVersion}
SetupIconFile={#SourceDir}\assets\ulanzi-glucose.ico
UninstallDisplayIcon={app}\assets\ulanzi-glucose.ico
LicenseFile={#SourceDir}\LICENSE
InfoBeforeFile={#SourceDir}\PRIVACY.md
ChangesEnvironment=no
ShowLanguageDialog=yes
LanguageDetectionMethod=none

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[CustomMessages]
english.StartupTask=Start automatically with Windows
english.StartupGroup=Startup:
english.DesktopTask=Create a desktop shortcut
english.ShortcutGroup=Additional shortcuts:
english.OpenApp=Open Ulanzi Glucose Bridge
english.UninstallApp=Uninstall Ulanzi Glucose Bridge
english.AppLanguage=en
brazilianportuguese.StartupTask=Iniciar automaticamente com o Windows
brazilianportuguese.StartupGroup=Inicialização:
brazilianportuguese.DesktopTask=Criar um atalho na área de trabalho
brazilianportuguese.ShortcutGroup=Atalhos adicionais:
brazilianportuguese.OpenApp=Abrir o Ulanzi Glucose Bridge
brazilianportuguese.UninstallApp=Desinstalar Ulanzi Glucose Bridge
brazilianportuguese.AppLanguage=pt-BR

[Tasks]
Name: "startup"; Description: "{cm:StartupTask}"; GroupDescription: "{cm:StartupGroup}"; Flags: unchecked
Name: "desktopicon"; Description: "{cm:DesktopTask}"; GroupDescription: "{cm:ShortcutGroup}"; Flags: unchecked

[Files]
; Não use UninstallDelete recursivo: a pasta pode conter configuração, cofre,
; histórico, logs e atualizações pertencentes ao usuário.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The internal AppUserModelID remains stable across the product rename.
Name: "{group}\Ulanzi Glucose Bridge"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"" /OpenPanel"; WorkingDir: "{app}"; IconFilename: "{app}\assets\ulanzi-glucose.ico"; AppUserModelID: "UlanziLibre.Bridge"
Name: "{group}\{cm:UninstallApp}"; Filename: "{uninstallexe}"; IconFilename: "{app}\assets\ulanzi-glucose.ico"
Name: "{autodesktop}\Ulanzi Glucose Bridge"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"" /OpenPanel"; WorkingDir: "{app}"; IconFilename: "{app}\assets\ulanzi-glucose.ico"; AppUserModelID: "UlanziLibre.Bridge"; Tasks: desktopicon
Name: "{autostartup}\Ulanzi Glucose Bridge"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\ulanzi-glucose.ico"; AppUserModelID: "UlanziLibre.Bridge"; Tasks: startup

[InstallDelete]
; Remove only known application files and old shortcuts; never user data.
Type: files; Name: "{app}\assets\ulanzi-libre.ico"
Type: files; Name: "{userprograms}\Ulanzi Libre Bridge\Ulanzi Libre Bridge.lnk"
Type: files; Name: "{userprograms}\Ulanzi Libre Bridge\Configurar Ulanzi Libre Bridge.lnk"
Type: files; Name: "{userprograms}\Ulanzi Libre Bridge\Desinstalar Ulanzi Libre Bridge.lnk"
Type: files; Name: "{userprograms}\Ulanzi Libre Bridge\Uninstall Ulanzi Libre Bridge.lnk"
Type: dirifempty; Name: "{userprograms}\Ulanzi Libre Bridge"
Type: files; Name: "{autodesktop}\Ulanzi Libre Bridge.lnk"
Type: files; Name: "{autostartup}\Ulanzi Libre Bridge.lnk"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\installer\set-language.ps1"" -Language {cm:AppLanguage}"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated
Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"" /OpenPanel"; WorkingDir: "{app}"; Description: "{cm:OpenApp}"; Flags: postinstall nowait skipifsilent

[Code]
function GetDefaultInstallDir(Param: String): String;
var
  PreviousPath, ProgramsRoot: String;
begin
  ProgramsRoot := AddBackslash(ExpandConstant('{localappdata}\Programs'));
  Result := ProgramsRoot + 'Ulanzi Glucose Bridge';
  { A prepared local package used this registry key before the rename. }
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\UlanziLibreBridge', 'InstallLocation', PreviousPath) then
  begin
    PreviousPath := RemoveBackslashUnlessRoot(ExpandFileName(PreviousPath));
    if (Length(PreviousPath) > Length(ProgramsRoot)) and
       (Pos(Lowercase(ProgramsRoot), Lowercase(AddBackslash(PreviousPath))) = 1) and
       FileExists(AddBackslash(PreviousPath) + 'checksums.sha256') then
    begin
      Result := PreviousPath;
      Exit;
    end;
  end;
  PreviousPath := ProgramsRoot + 'Ulanzi Libre Bridge';
  if not FileExists(AddBackslash(Result) + 'checksums.sha256') and
     FileExists(AddBackslash(PreviousPath) + 'checksums.sha256') then
    Result := PreviousPath;
end;

procedure InitializeWizard;
begin
  { Preserve pre-rename shortcuts; the user can still turn each option off. }
  if FileExists(ExpandConstant('{autostartup}\Ulanzi Libre Bridge.lnk')) then
    WizardSelectTasks('startup');
  if FileExists(ExpandConstant('{autodesktop}\Ulanzi Libre Bridge.lnk')) then
    WizardSelectTasks('desktopicon');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PreviousPath: String;
begin
  { Inno takes over the local install entry only when updating the same folder. }
  if CurStep = ssPostInstall then
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\UlanziLibreBridge', 'InstallLocation', PreviousPath) then
      if CompareText(RemoveBackslashUnlessRoot(PreviousPath), RemoveBackslashUnlessRoot(ExpandConstant('{app}'))) = 0 then
        RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\UlanziLibreBridge');
end;
