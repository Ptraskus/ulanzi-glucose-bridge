[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet("en", "pt-BR")][string]$Language,
    [string]$PreferenceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

# An upgrade must keep the user's existing configuration and UI preferences.
if (Test-Path -LiteralPath (Join-Path $projectRoot ".env")) { exit 0 }
. (Join-Path $projectRoot "scripts\ui-language.ps1")
$PreferenceRoot = Resolve-UlanziUiPreferenceRoot -PreferenceRoot $PreferenceRoot
$preferencePath = Join-Path $PreferenceRoot "ui-preferences.json"
if (Test-Path -LiteralPath $preferencePath -PathType Leaf) {
    try {
        $preferences = Get-Content -LiteralPath $preferencePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $preferences.PSObject.Properties["language"] -and $preferences.language -in @("en", "pt-BR")) { exit 0 }
    } catch { }
}
[void](Set-UlanziLanguage -Language $Language -PreferenceRoot $PreferenceRoot -Persist)
