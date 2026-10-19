[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet("en", "pt-BR")][string]$Language,
    [string]$PreferenceRoot = (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Ulanzi Libre Bridge")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

# An upgrade must keep the user's existing configuration and UI preferences.
if (Test-Path -LiteralPath (Join-Path $projectRoot ".env")) { exit 0 }
$preferencePath = Join-Path $PreferenceRoot "ui-preferences.json"
if (Test-Path -LiteralPath $preferencePath -PathType Leaf) {
    try {
        $preferences = Get-Content -LiteralPath $preferencePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $preferences.PSObject.Properties["language"] -and $preferences.language -in @("en", "pt-BR")) { exit 0 }
    } catch { }
}
. (Join-Path $projectRoot "scripts\ui-language.ps1")
[void](Set-UlanziLanguage -Language $Language -PreferenceRoot $PreferenceRoot -Persist)
