Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellPath, configurePath, command, exitCode

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
configurePath = fileSystem.BuildPath(scriptDirectory, "configurar-instalado.ps1")
command = Chr(34) & powershellPath & Chr(34) & _
    " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & configurePath & Chr(34)

' WScript creates no console and waits while the graphical wizard is open.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
