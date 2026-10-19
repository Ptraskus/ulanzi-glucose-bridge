Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellPath, trayScript, command, openPanelArgument, exitCode

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
trayScript = fileSystem.BuildPath(scriptDirectory, "iniciar-bandeja.ps1")
openPanelArgument = ""
If WScript.Arguments.Named.Exists("OpenPanel") Then openPanelArgument = " -OpenPanel"
command = Chr(34) & powershellPath & Chr(34) & _
    " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & trayScript & Chr(34) & openPanelArgument

' Window style 0 keeps the console completely hidden. Waiting keeps the
' scheduled task alive so Windows can monitor and restart it if necessary.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
