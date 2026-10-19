Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellPath, launcherPath, command, openPanelArgument, exitCode

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
launcherPath = fileSystem.BuildPath(scriptDirectory, "iniciar-instalado.ps1")
openPanelArgument = ""
If WScript.Arguments.Named.Exists("OpenPanel") Then openPanelArgument = " -OpenPanel"
command = Chr(34) & powershellPath & Chr(34) & _
    " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & launcherPath & Chr(34) & openPanelArgument

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
