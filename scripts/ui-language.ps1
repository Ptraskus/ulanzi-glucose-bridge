Set-StrictMode -Version Latest

# Catalogs use stable source templates. Arguments are substituted literally:
# neither translations nor values are evaluated as PowerShell code.
if ($null -eq (Get-Variable UlanziLanguage -Scope Script -ErrorAction SilentlyContinue)) {
    $script:UlanziLanguage = if ($env:ULANZI_UI_LANGUAGE -in @("en", "pt-BR")) { $env:ULANZI_UI_LANGUAGE } else { "en" }
    $script:UlanziLanguageCatalogs = @{}
}
$script:UlanziLocaleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "locales"

function Get-UlanziLanguage { return $script:UlanziLanguage }

function Resolve-UlanziUiPreferenceRoot {
    param([AllowEmptyString()][string]$PreferenceRoot, [AllowEmptyString()][string]$LocalApplicationDataRoot)
    if (-not [string]::IsNullOrWhiteSpace($PreferenceRoot)) { return [IO.Path]::GetFullPath($PreferenceRoot) }
    if ([string]::IsNullOrWhiteSpace($LocalApplicationDataRoot)) {
        $LocalApplicationDataRoot = [Environment]::GetFolderPath("LocalApplicationData")
    }
    if ([string]::IsNullOrWhiteSpace($LocalApplicationDataRoot)) { $LocalApplicationDataRoot = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($LocalApplicationDataRoot)) { throw 'The local application data folder is unavailable.' }
    $currentRoot = Join-Path $LocalApplicationDataRoot "Ulanzi Glucose Bridge"
    # Reuse an existing profile across the rename, without copying or overwriting preferences.
    $legacyRoot = Join-Path $LocalApplicationDataRoot "Ulanzi Libre Bridge"
    if (-not [IO.File]::Exists((Join-Path $currentRoot "ui-preferences.json")) -and [IO.File]::Exists((Join-Path $legacyRoot "ui-preferences.json"))) {
        return $legacyRoot
    }
    return $currentRoot
}

function Set-UlanziLanguage {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("en", "pt-BR")][string]$Language,
        [AllowEmptyString()][string]$PreferenceRoot,
        [switch]$Persist
    )
    $normalized = if ($Language -ieq "pt-BR") { "pt-BR" } else { "en" }
    if ($Persist) {
        $PreferenceRoot = Resolve-UlanziUiPreferenceRoot -PreferenceRoot $PreferenceRoot
        [void][IO.Directory]::CreateDirectory($PreferenceRoot)
        $path = Join-Path $PreferenceRoot "ui-preferences.json"
        $payload = [ordered]@{ schemaVersion = 1; theme = "system"; language = $normalized }
        if ([IO.File]::Exists($path)) {
            try {
                $existing = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
                foreach ($property in $existing.PSObject.Properties) {
                    if ($property.Name -notin @("schemaVersion", "language")) { $payload[$property.Name] = $property.Value }
                }
            } catch { }
        }
        $temporaryPath = Join-Path $PreferenceRoot ("ui-language.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
        try {
            [IO.File]::WriteAllText($temporaryPath, ($payload | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporaryPath, $path, [NullString]::Value, $true) }
            else { [IO.File]::Move($temporaryPath, $path) }
        } finally {
            if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        }
    }
    $script:UlanziLanguage = $normalized
    return $normalized
}

function Initialize-UlanziLanguage {
    param([AllowEmptyString()][string]$EnvPath, [AllowEmptyString()][string]$PreferenceRoot)

    $language = "en"
    $PreferenceRoot = Resolve-UlanziUiPreferenceRoot -PreferenceRoot $PreferenceRoot
    try {
        $preference = [IO.File]::ReadAllText((Join-Path $PreferenceRoot "ui-preferences.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -ne $preference.PSObject.Properties["language"] -and $preference.language -in @("en", "pt-BR")) {
            $language = [string]$preference.language
        }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($EnvPath) -and [IO.File]::Exists($EnvPath)) {
        # Existing configurations without the key also adopt English by default.
        $language = "en"
        foreach ($line in [IO.File]::ReadAllLines($EnvPath, [Text.Encoding]::UTF8)) {
            if ($line -match '^\s*APP_LANGUAGE\s*=\s*["'']?(en|pt-BR)["'']?\s*(?:#.*)?$') { $language = $Matches[1] }
        }
    }
    if ($env:ULANZI_UI_LANGUAGE -in @("en", "pt-BR")) { $language = $env:ULANZI_UI_LANGUAGE }
    [void](Set-UlanziLanguage -Language $language)
    return $language
}

function Get-UlanziText {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Key,
        [Parameter(Position = 1)][AllowNull()][object[]]$Arguments = @()
    )
    foreach ($language in @("en", $script:UlanziLanguage) | Select-Object -Unique) {
        if (-not $script:UlanziLanguageCatalogs.ContainsKey($language)) {
            $catalog = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $path = Join-Path $script:UlanziLocaleRoot "$language.json"
            if ([IO.File]::Exists($path)) {
                Add-Type -AssemblyName System.Web.Extensions
                $serializer = [Web.Script.Serialization.JavaScriptSerializer]::new()
                $document = $serializer.DeserializeObject([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
                foreach ($keyName in $document.Keys) { $catalog[$keyName] = [string]$document[$keyName] }
            }
            $script:UlanziLanguageCatalogs[$language] = $catalog
        }
    }
    $text = $Key
    if ($script:UlanziLanguageCatalogs["en"].ContainsKey($Key)) { $text = $script:UlanziLanguageCatalogs["en"][$Key] }
    if ($script:UlanziLanguageCatalogs[$script:UlanziLanguage].ContainsKey($Key)) { $text = $script:UlanziLanguageCatalogs[$script:UlanziLanguage][$Key] }
    # Match the original template once so argument text containing {1}, etc.
    # cannot be interpreted as another placeholder.
    $values = $Arguments
    return [regex]::Replace($text, '\{(\d+)\}', {
        param($match)
        $index = [int]$match.Groups[1].Value
        if ($null -ne $values -and $index -lt $values.Count) { return [string]$values[$index] }
        return $match.Value
    }.GetNewClosure())
}

function Show-UlanziLanguagePicker {
    param([AllowEmptyString()][string]$PreferenceRoot)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = [Windows.Forms.Form]::new()
    $form.Name = "languagePickerForm"
    $form.Text = "Ulanzi Glucose - Language / Idioma"
    $form.ClientSize = [Drawing.Size]::new(430, 160)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = [Drawing.Font]::new("Segoe UI", 10)
    $label = [Windows.Forms.Label]::new()
    $label.Text = "Choose your language / Escolha seu idioma"
    $label.SetBounds(22, 18, 390, 28)
    $choice = [Windows.Forms.ComboBox]::new()
    $choice.Name = "languageControl"
    $choice.AccessibleName = "Language / Idioma"
    $choice.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $choice.Items.AddRange(@("English", (Get-UlanziText -Key 'Language.Portuguese')))
    $choice.SetBounds(22, 52, 385, 30)
    $choice.SelectedIndex = if ((Get-UlanziLanguage) -eq "pt-BR") { 1 } else { 0 }
    $continue = [Windows.Forms.Button]::new()
    $continue.Name = "continueLanguageButton"
    $continue.Text = "Continue / Continuar"
    $continue.SetBounds(222, 106, 185, 34)
    $continue.DialogResult = [Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $continue
    $form.Controls.AddRange(@($label, $choice, $continue))
    try {
        if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $false }
        $language = if ($choice.SelectedIndex -eq 1) { "pt-BR" } else { "en" }
        [void](Set-UlanziLanguage -Language $language -PreferenceRoot $PreferenceRoot -Persist)
        return $true
    } finally { $form.Dispose() }
}
