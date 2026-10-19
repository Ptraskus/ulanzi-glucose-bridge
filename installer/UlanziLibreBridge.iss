; Ulanzi Libre Bridge - instalador por usuário
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
AppId={{4B234792-EB6C-43EB-B892-FC97B9B91C34}
AppName=Ulanzi Libre Bridge
AppVersion={#AppVersion}
AppVerName=Ulanzi Libre Bridge {#AppVersion}
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductName=Ulanzi Libre Bridge
VersionInfoDescription=Instalador do Ulanzi Libre Bridge
VersionInfoCompany=Ulanzi Libre Bridge contributors
AppPublisher=Ulanzi Libre Bridge contributors
DefaultDirName={localappdata}\Programs\Ulanzi Libre Bridge
DefaultGroupName=Ulanzi Libre Bridge
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.17763
ArchitecturesAllowed=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Ulanzi-Libre-Bridge-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=yes
RestartApplications=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes
Uninstallable=yes
UninstallDisplayName=Ulanzi Libre Bridge {#AppVersion}
SetupIconFile={#SourceDir}\assets\ulanzi-libre.ico
UninstallDisplayIcon={app}\assets\ulanzi-libre.ico
LicenseFile={#SourceDir}\LICENSE
InfoBeforeFile={#SourceDir}\PRIVACY.md
ChangesEnvironment=no

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "startup"; Description: "Iniciar automaticamente com o Windows"; GroupDescription: "Inicialização:"; Flags: unchecked
Name: "desktopicon"; Description: "Criar um atalho na área de trabalho"; GroupDescription: "Atalhos adicionais:"; Flags: unchecked

[Files]
; Não use UninstallDelete recursivo: a pasta pode conter configuração, cofre,
; histórico, logs e atualizações pertencentes ao usuário.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Ulanzi Libre Bridge"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"" /OpenPanel"; WorkingDir: "{app}"; IconFilename: "{app}\assets\ulanzi-libre.ico"; AppUserModelID: "UlanziLibre.Bridge"
Name: "{group}\Desinstalar Ulanzi Libre Bridge"; Filename: "{uninstallexe}"; IconFilename: "{app}\assets\ulanzi-libre.ico"
Name: "{autodesktop}\Ulanzi Libre Bridge"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"" /OpenPanel"; WorkingDir: "{app}"; IconFilename: "{app}\assets\ulanzi-libre.ico"; AppUserModelID: "UlanziLibre.Bridge"; Tasks: desktopicon
Name: "{autostartup}\Ulanzi Libre Bridge"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\ulanzi-libre.ico"; AppUserModelID: "UlanziLibre.Bridge"; Tasks: startup

[InstallDelete]
; Versoes anteriores criavam uma segunda entrada publica. A configuracao agora
; fica no painel principal, em Conexoes.
Type: files; Name: "{group}\Configurar Ulanzi Libre Bridge.lnk"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\installer\iniciar-instalado.vbs"" /OpenPanel"; WorkingDir: "{app}"; Description: "Abrir o Ulanzi Libre Bridge"; Flags: postinstall nowait skipifsilent
