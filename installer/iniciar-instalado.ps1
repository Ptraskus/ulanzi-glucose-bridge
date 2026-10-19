[CmdletBinding()]
param([switch]$OpenPanel)

$ErrorActionPreference = "Stop"
& (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\launch-app.ps1") -OpenPanel:$OpenPanel
