[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
& (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\launch-app.ps1") -Setup
