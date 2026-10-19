Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ui-language.ps1")

Add-Type -AssemblyName System.Drawing -ErrorAction Stop
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

$script:UlanziUiThemeNames = @("system", "light", "dark")
$script:UlanziUiPaletteNames = @(
    "Window",
    "Surface",
    "Elevated",
    "Input",
    "Text",
    "Muted",
    "Border",
    "Accent",
    "AccentText",
    "Header",
    "HeaderMuted",
    "Success",
    "Warning",
    "Error"
)
$script:UlanziUiApplicationIconCache = $null
$script:UlanziUiApplicationIconCachePath = ""

function Initialize-UlanziWindowsIdentity {
    # Keep the historical internal identity so upgrades retain taskbar grouping.
    param(
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
        [string]$ApplicationId = "UlanziLibre.Bridge"
    )

    try {
        if ($null -eq ("UlanziUiIdentityNative" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class UlanziUiIdentityNative
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
}
"@ -ErrorAction Stop
        }
        return ([UlanziUiIdentityNative]::SetCurrentProcessExplicitAppUserModelID($ApplicationId) -ge 0)
    } catch {
        return $false
    }
}

function Get-UlanziUiApplicationIcon {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    try {
        $iconPath = [IO.Path]::GetFullPath((Join-Path $ProjectRoot "assets\ulanzi-glucose.ico"))
        if (-not [IO.File]::Exists($iconPath)) { return $null }

        if (
            $null -ne $script:UlanziUiApplicationIconCache -and
            $script:UlanziUiApplicationIconCachePath -ieq $iconPath
        ) {
            return $script:UlanziUiApplicationIconCache
        }

        $bytes = [IO.File]::ReadAllBytes($iconPath)
        $stream = [IO.MemoryStream]::new($bytes, $false)
        $sourceIcon = $null
        try {
            $sourceIcon = [Drawing.Icon]::new($stream)
            $loadedIcon = [Drawing.Icon]$sourceIcon.Clone()
        } finally {
            if ($null -ne $sourceIcon) { $sourceIcon.Dispose() }
            $stream.Dispose()
        }

        if ($null -ne $script:UlanziUiApplicationIconCache) {
            $script:UlanziUiApplicationIconCache.Dispose()
        }
        $script:UlanziUiApplicationIconCache = $loadedIcon
        $script:UlanziUiApplicationIconCachePath = $iconPath
        return $script:UlanziUiApplicationIconCache
    } catch {
        return $null
    }
}

function Set-UlanziUiApplicationIcon {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.Form]$Form,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $applicationIcon = Get-UlanziUiApplicationIcon -ProjectRoot $ProjectRoot
    if ($null -eq $applicationIcon) { return $false }

    $ownedIcon = [Drawing.Icon]$applicationIcon.Clone()
    $Form.Icon = $ownedIcon
    $Form.add_Disposed(({
        try { $ownedIcon.Dispose() } catch { }
    }).GetNewClosure())
    return $true
}

function Clear-UlanziUiApplicationIconCache {
    if ($null -ne $script:UlanziUiApplicationIconCache) {
        try { $script:UlanziUiApplicationIconCache.Dispose() } catch { }
        $script:UlanziUiApplicationIconCache = $null
        $script:UlanziUiApplicationIconCachePath = ""
    }
}

function Get-UlanziUiPreferencePath {
    param(
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PreferenceRoot
    )

    $PreferenceRoot = Resolve-UlanziUiPreferenceRoot -PreferenceRoot $PreferenceRoot

    return Join-Path ([IO.Path]::GetFullPath($PreferenceRoot)) "ui-preferences.json"
}

function Get-UlanziUiThemePreference {
    param(
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PreferenceRoot
    )

    try {
        $preferencePath = Get-UlanziUiPreferencePath -PreferenceRoot $PreferenceRoot
        if (-not [IO.File]::Exists($preferencePath)) { return "system" }

        $document = [IO.File]::ReadAllText($preferencePath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $document) { return "system" }
        if ($null -eq $document.PSObject.Properties["schemaVersion"]) { return "system" }
        if ([int]$document.schemaVersion -ne 1) { return "system" }
        if ($null -eq $document.PSObject.Properties["theme"]) { return "system" }

        $theme = ([string]$document.theme).Trim().ToLowerInvariant()
        if ($script:UlanziUiThemeNames -notcontains $theme) { return "system" }
        return $theme
    } catch {
        return "system"
    }
}

function Set-UlanziUiThemePreference {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("system", "light", "dark")]
        [string]$Theme,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PreferenceRoot
    )

    $normalizedTheme = $Theme.Trim().ToLowerInvariant()
    $preferencePath = Get-UlanziUiPreferencePath -PreferenceRoot $PreferenceRoot
    $directory = [IO.Path]::GetDirectoryName($preferencePath)
    [void][IO.Directory]::CreateDirectory($directory)

    $payload = [ordered]@{
        schemaVersion = 1
        theme = $normalizedTheme
    }
    if ([IO.File]::Exists($preferencePath)) {
        try {
            $existing = [IO.File]::ReadAllText($preferencePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($property in $existing.PSObject.Properties) {
                if ($property.Name -notin @("schemaVersion", "theme")) { $payload[$property.Name] = $property.Value }
            }
        } catch { }
    }
    $json = $payload | ConvertTo-Json -Depth 3 -Compress
    $utf8 = [Text.UTF8Encoding]::new($false)
    $temporaryPath = Join-Path $directory ("ui-preferences.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    $stream = $null

    try {
        $bytes = $utf8.GetBytes($json)
        $stream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if ([IO.File]::Exists($preferencePath)) {
            [IO.File]::Replace($temporaryPath, $preferencePath, [NullString]::Value, $true)
        } else {
            try {
                [IO.File]::Move($temporaryPath, $preferencePath)
            } catch [IO.IOException] {
                if (-not [IO.File]::Exists($preferencePath)) { throw }
                [IO.File]::Replace($temporaryPath, $preferencePath, [NullString]::Value, $true)
            }
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }

    return $normalizedTheme
}

function Resolve-UlanziUiTheme {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("system", "light", "dark")]
        [string]$Theme = "system",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PreferenceRoot
    )

    $normalizedPreference = $Theme.Trim().ToLowerInvariant()

    $highContrast = $false
    try {
        $highContrast = [bool][Windows.Forms.SystemInformation]::HighContrast
    } catch {
        $highContrast = $false
    }

    $effectiveTheme = $normalizedPreference
    if ($normalizedPreference -eq "system") {
        $effectiveTheme = "light"
        try {
            $personalizePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            $personalize = Get-ItemProperty -LiteralPath $personalizePath -Name "AppsUseLightTheme" -ErrorAction Stop
            if ([int]$personalize.AppsUseLightTheme -eq 0) {
                $effectiveTheme = "dark"
            }
        } catch {
            $effectiveTheme = "light"
        }
    }

    return [PSCustomObject][ordered]@{
        Preference = $normalizedPreference
        Theme = $effectiveTheme
        HighContrast = $highContrast
        EffectiveMode = $(if ($highContrast) { "high-contrast" } else { $effectiveTheme })
    }
}

function ConvertTo-UlanziUiColor {
    param(
        [Parameter(Mandatory = $true)][string]$HtmlColor
    )

    return [Drawing.ColorTranslator]::FromHtml($HtmlColor)
}

function Get-UlanziUiPalette {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("system", "light", "dark")]
        [string]$Theme = "system",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PreferenceRoot,

        [Parameter(Mandatory = $false)]
        [switch]$HighContrast
    )

    $resolved = Resolve-UlanziUiTheme -Theme $Theme -PreferenceRoot $PreferenceRoot
    if ($HighContrast.IsPresent -or $resolved.HighContrast) {
        return [PSCustomObject][ordered]@{
            Window = [Drawing.SystemColors]::Window
            Surface = [Drawing.SystemColors]::Control
            Elevated = [Drawing.SystemColors]::Control
            Input = [Drawing.SystemColors]::Window
            Text = [Drawing.SystemColors]::WindowText
            Muted = [Drawing.SystemColors]::GrayText
            Border = [Drawing.SystemColors]::WindowFrame
            Accent = [Drawing.SystemColors]::Highlight
            AccentText = [Drawing.SystemColors]::HighlightText
            Header = [Drawing.SystemColors]::Control
            HeaderMuted = [Drawing.SystemColors]::ControlText
            Success = [Drawing.SystemColors]::HotTrack
            Warning = [Drawing.SystemColors]::Highlight
            Error = [Drawing.SystemColors]::Highlight
        }
    }

    if ($resolved.Theme -eq "dark") {
        return [PSCustomObject][ordered]@{
            Window = ConvertTo-UlanziUiColor "#12171C"
            Surface = ConvertTo-UlanziUiColor "#1A2128"
            Elevated = ConvertTo-UlanziUiColor "#232C34"
            Input = ConvertTo-UlanziUiColor "#11161B"
            Text = ConvertTo-UlanziUiColor "#F1F5F7"
            Muted = ConvertTo-UlanziUiColor "#AAB7C0"
            Border = ConvertTo-UlanziUiColor "#394650"
            Accent = ConvertTo-UlanziUiColor "#4DA3FF"
            AccentText = ConvertTo-UlanziUiColor "#07111B"
            Header = ConvertTo-UlanziUiColor "#1C2A36"
            HeaderMuted = ConvertTo-UlanziUiColor "#B6C7D3"
            Success = ConvertTo-UlanziUiColor "#66BB6A"
            Warning = ConvertTo-UlanziUiColor "#FFB74D"
            Error = ConvertTo-UlanziUiColor "#EF6A6A"
        }
    }

    return [PSCustomObject][ordered]@{
        Window = ConvertTo-UlanziUiColor "#F4F7F9"
        Surface = ConvertTo-UlanziUiColor "#FFFFFF"
        Elevated = ConvertTo-UlanziUiColor "#FFFFFF"
        Input = ConvertTo-UlanziUiColor "#FFFFFF"
        Text = ConvertTo-UlanziUiColor "#18212A"
        Muted = ConvertTo-UlanziUiColor "#60717D"
        Border = ConvertTo-UlanziUiColor "#D7E0E5"
        Accent = ConvertTo-UlanziUiColor "#1976D2"
        AccentText = ConvertTo-UlanziUiColor "#FFFFFF"
        Header = ConvertTo-UlanziUiColor "#EAF3FA"
        HeaderMuted = ConvertTo-UlanziUiColor "#5C7282"
        Success = ConvertTo-UlanziUiColor "#2E7D32"
        Warning = ConvertTo-UlanziUiColor "#A85E00"
        Error = ConvertTo-UlanziUiColor "#C62828"
    }
}

function Get-UlanziUiTagInstruction {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Tag
    )

    $role = $null
    $preserveColors = $false
    if ($null -eq $Tag) {
        return [PSCustomObject]@{ Role = $role; PreserveColors = $preserveColors }
    }

    if ($Tag -is [Collections.IDictionary]) {
        foreach ($key in @("ThemeRole", "UiRole", "Role", "SemanticColor")) {
            if ($Tag.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$Tag[$key])) {
                $role = [string]$Tag[$key]
                break
            }
        }
        foreach ($key in @("PreserveColors", "PreserveSemanticColor", "NoTheme")) {
            if ($Tag.Contains($key) -and [bool]$Tag[$key]) {
                $preserveColors = $true
            }
        }
    } elseif ($Tag -isnot [string]) {
        foreach ($propertyName in @("ThemeRole", "UiRole", "Role", "SemanticColor")) {
            $property = $Tag.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $role = [string]$property.Value
                break
            }
        }
        foreach ($propertyName in @("PreserveColors", "PreserveSemanticColor", "NoTheme")) {
            $property = $Tag.PSObject.Properties[$propertyName]
            if ($null -ne $property -and [bool]$property.Value) {
                $preserveColors = $true
            }
        }
    } else {
        $tagText = ([string]$Tag).Trim()
        if ($tagText -match "(?i)(?:^|[;,|])\s*(?:theme(?:role)?|uirole|role|semantic)\s*[:=]\s*([a-z]+)") {
            $role = $Matches[1]
        } elseif ($script:UlanziUiPaletteNames -contains $tagText) {
            $role = $tagText
        }
        if ($tagText -match "(?i)(?:preserve(?:semantic)?colors?|preserve-semantic-color|no-?theme)") {
            $preserveColors = $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$role)) {
        $canonicalRole = $script:UlanziUiPaletteNames | Where-Object { $_ -ieq $role } | Select-Object -First 1
        $role = $canonicalRole
    }

    return [PSCustomObject]@{
        Role = $role
        PreserveColors = $preserveColors
    }
}

function Set-UlanziUiControlRole {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.Control]$Control,
        [Parameter(Mandatory = $true)][PSCustomObject]$Palette,
        [Parameter(Mandatory = $true)][string]$Role
    )

    switch ($Role) {
        "Window" {
            $Control.BackColor = $Palette.Window
            $Control.ForeColor = $Palette.Text
        }
        "Surface" {
            $Control.BackColor = $Palette.Surface
            $Control.ForeColor = $Palette.Text
        }
        "Elevated" {
            $Control.BackColor = $Palette.Elevated
            $Control.ForeColor = $Palette.Text
        }
        "Input" {
            $Control.BackColor = $Palette.Input
            $Control.ForeColor = $Palette.Text
        }
        "Text" { $Control.ForeColor = $Palette.Text }
        "Muted" { $Control.ForeColor = $Palette.Muted }
        "Border" { $Control.BackColor = $Palette.Border }
        "Accent" {
            $Control.BackColor = $Palette.Accent
            $Control.ForeColor = $Palette.AccentText
        }
        "AccentText" { $Control.ForeColor = $Palette.AccentText }
        "Header" {
            $Control.BackColor = $Palette.Header
            $Control.ForeColor = $Palette.Text
        }
        "HeaderMuted" {
            $Control.BackColor = $Palette.Header
            $Control.ForeColor = $Palette.HeaderMuted
        }
        "Success" { $Control.ForeColor = $Palette.Success }
        "Warning" { $Control.ForeColor = $Palette.Warning }
        "Error" { $Control.ForeColor = $Palette.Error }
    }

    if ($Control -is [Windows.Forms.Button] -and $Control.FlatStyle -eq [Windows.Forms.FlatStyle]::Flat) {
        $Control.FlatAppearance.BorderColor = $Palette.Border
    }
}

function Set-UlanziUiControlDefaultTheme {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.Control]$Control,
        [Parameter(Mandatory = $true)][PSCustomObject]$Palette
    )

    if ($Control -is [Windows.Forms.Form]) {
        Set-UlanziUiControlRole -Control $Control -Palette $Palette -Role "Window"
        return
    }

    if (
        $Control -is [Windows.Forms.TextBoxBase] -or
        $Control -is [Windows.Forms.NumericUpDown] -or
        $Control -is [Windows.Forms.ComboBox] -or
        $Control -is [Windows.Forms.ListBox] -or
        $Control -is [Windows.Forms.ListView] -or
        $Control -is [Windows.Forms.DataGridView]
    ) {
        Set-UlanziUiControlRole -Control $Control -Palette $Palette -Role "Input"
        return
    }

    if ($Control -is [Windows.Forms.Button]) {
        Set-UlanziUiControlRole -Control $Control -Palette $Palette -Role "Surface"
        if ($Control.FlatStyle -eq [Windows.Forms.FlatStyle]::Flat) {
            $Control.FlatAppearance.BorderColor = $Palette.Border
        }
        return
    }

    if (
        $Control -is [Windows.Forms.Label] -or
        $Control -is [Windows.Forms.CheckBox] -or
        $Control -is [Windows.Forms.RadioButton] -or
        $Control -is [Windows.Forms.LinkLabel]
    ) {
        $Control.ForeColor = $Palette.Text
        return
    }

    $Control.BackColor = $Palette.Surface
    $Control.ForeColor = $Palette.Text
}

function Apply-UlanziUiTheme {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias("Root")]
        [Windows.Forms.Control]$Control,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet("system", "light", "dark")]
        [string]$Theme = "system",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PreferenceRoot,

        [Parameter(Mandatory = $false)]
        [switch]$HighContrast
    )

    $Palette = Get-UlanziUiPalette -Theme $Theme -PreferenceRoot $PreferenceRoot -HighContrast:$HighContrast
    foreach ($paletteName in $script:UlanziUiPaletteNames) {
        if ($null -eq $Palette.PSObject.Properties[$paletteName]) {
            throw (Get-UlanziText -Key 'A paleta nao contem a cor obrigatoria ''{0}''.' -Arguments @(($paletteName)))
        }
    }

    $pending = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
    $pending.Enqueue($Control)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        $instruction = Get-UlanziUiTagInstruction -Tag $current.Tag

        if (-not $instruction.PreserveColors) {
            if (-not [string]::IsNullOrWhiteSpace([string]$instruction.Role)) {
                Set-UlanziUiControlRole -Control $current -Palette $Palette -Role $instruction.Role
            } else {
                Set-UlanziUiControlDefaultTheme -Control $current -Palette $Palette
            }
        }

        foreach ($child in $current.Controls) {
            $pending.Enqueue([Windows.Forms.Control]$child)
        }
    }

    $Control.Invalidate($true)
}
