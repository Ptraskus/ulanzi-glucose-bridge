[CmdletBinding()]
param(
    [switch]$OpenPanel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class UlanziTrayNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

$projectRoot = Split-Path -Parent $PSScriptRoot
$bridgeScript = Join-Path $PSScriptRoot "iniciar.ps1"
$envPath = Join-Path $projectRoot ".env"
$runtimePath = Join-Path $projectRoot ".runtime"
$statusPath = Join-Path $runtimePath "status.json"
$alarmStatePath = Join-Path $runtimePath "alarm-state.json"
$commandPath = Join-Path $runtimePath "command.json"
$stopRequestPath = Join-Path $runtimePath "stop.json"
$panelRequestPath = Join-Path $runtimePath "open-panel.request"
$themeUiScript = Join-Path $PSScriptRoot "ui-theme.ps1"
$configurationUiScript = Join-Path $PSScriptRoot "configuracoes-ui.ps1"
$firstRunUiScript = Join-Path $PSScriptRoot "configurar.ps1"
$diagnosticsUiScript = Join-Path $PSScriptRoot "diagnosticos-ui.ps1"
$maintenanceUiScript = Join-Path $PSScriptRoot "manutencao-ui.ps1"
$panelUiScript = Join-Path $PSScriptRoot "painel-ui.ps1"
if (-not (Test-Path -LiteralPath $themeUiScript)) {
    throw "O modulo de aparencia nao foi encontrado."
}
if (-not (Test-Path -LiteralPath $configurationUiScript)) {
    throw "O modulo da tela de configuracoes nao foi encontrado."
}
if (-not (Test-Path -LiteralPath $firstRunUiScript)) {
    throw "O assistente de primeira configuracao nao foi encontrado."
}
if (-not (Test-Path -LiteralPath $diagnosticsUiScript)) {
    throw "O modulo da tela de diagnosticos nao foi encontrado."
}
if (-not (Test-Path -LiteralPath $maintenanceUiScript)) {
    throw "O modulo da tela de manutencao nao foi encontrado."
}
if (-not (Test-Path -LiteralPath $panelUiScript)) {
    throw "O modulo do painel nao foi encontrado."
}
. $themeUiScript
. $configurationUiScript
. $diagnosticsUiScript
. $maintenanceUiScript
. $panelUiScript
[void](Initialize-UlanziWindowsIdentity -ApplicationId "UlanziLibre.Bridge")
$script:applicationIcon = Get-UlanziUiApplicationIcon -ProjectRoot $projectRoot
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$trayMutex = [Threading.Mutex]::new($false, "Local\UlanziLibreTray-$currentSid")
$ownsTrayMutex = $false
$script:bridgeProcess = $null
$script:closing = $false
$script:nextRestart = [DateTime]::MinValue
$script:widgetVisible = $true
$script:dynamicIcon = $null
$script:lastDisplaySignature = $null
$script:bridgeInstanceId = $null
$script:bridgeStartedAt = [DateTime]::MinValue
$script:lastRuntimeStatus = $null
$script:lastRuntimeStatusFileStamp = "<none>"
$script:bridgeRestartPhase = "idle"
$script:bridgeRestartDeadline = [DateTime]::MinValue
$script:bridgeRestartReason = ""
$script:bridgeRestartCompletionMessage = ""
$script:bridgeRestartRequiresConfigConfirmation = $false
$script:bridgeForcedStopProcess = $null
$script:pendingSoundRequestId = $null
$script:pendingSoundDeadline = [DateTime]::MinValue
$script:configurationDialogOpen = $false
$script:volumeDialogOpen = $false
$script:diagnosticsDialogOpen = $false
$script:maintenanceDialogOpen = $false
$script:pendingConfigApplyInstanceId = $null
$script:pendingConfigApplyDeadline = [DateTime]::MinValue
$script:windowsFallbackEnabled = $false
$script:windowsNotificationDelayMinutes = 2
$script:failureStartedAt = @{}
$script:failureNotified = @{}
$script:lastFallbackAlarmFingerprint = $null
$script:controlPanelController = $null
$script:preferredDialogOwner = $null
$script:preferredConfigurationTab = "alerts"
$script:configurationState = "checking"
$script:configurationMessage = "Verificando a configuracao inicial..."
$script:configurationCheckOperation = $null
$script:configurationCheckDeadline = [DateTime]::MinValue
$script:configurationCheckReason = "startup"
$script:firstRunProcess = $null
$script:firstRunOutputTask = $null
$script:firstRunErrorTask = $null

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DefaultValue
    )

    if (-not (Test-Path -LiteralPath $envPath)) { return $DefaultValue }
    foreach ($line in Get-Content -LiteralPath $envPath) {
        if ($line -match ('^' + [regex]::Escape($Name) + '=(.*)$')) {
            $value = $Matches[1].Trim()
            if (
                $value.Length -ge 2 -and
                (($value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') -or
                 ($value[0] -eq "'" -and $value[$value.Length - 1] -eq "'"))
            ) {
                return $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return $DefaultValue
}

function Get-EnvBoolean {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$DefaultValue
    )

    $raw = (Get-EnvValue -Name $Name -DefaultValue ([string]$DefaultValue)).Trim()
    if ($raw -match '^(1|true|yes|sim)$') { return $true }
    if ($raw -match '^(0|false|no|nao|não)$') { return $false }
    return $DefaultValue
}

function Update-TrayPreferences {
    $script:windowsFallbackEnabled = Get-EnvBoolean -Name "WINDOWS_FALLBACK_ALERT_ENABLED" -DefaultValue $false
    try {
        $delay = [int](Get-EnvValue -Name "WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES" -DefaultValue "2")
    } catch {
        $delay = 2
    }
    $script:windowsNotificationDelayMinutes = [Math]::Max(1, [Math]::Min(60, $delay))
}

function Write-StopBridgeRequest {
    param([Parameter(Mandatory = $true)][string]$TargetInstanceId)

    [void][IO.Directory]::CreateDirectory($runtimePath)
    $temporaryPath = "$stopRequestPath.$PID.tmp"
    $request = [ordered]@{
        version = 1
        command = "stop"
        targetInstanceId = $TargetInstanceId
        createdAt = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    }
    $json = $request | ConvertTo-Json -Compress
    try {
        [IO.File]::WriteAllText($temporaryPath, "$json`n", [Text.UTF8Encoding]::new($false))
        try {
            if ([IO.File]::Exists($stopRequestPath)) {
                [IO.File]::Replace($temporaryPath, $stopRequestPath, $null)
            } else {
                [IO.File]::Move($temporaryPath, $stopRequestPath)
            }
        } catch {
            if (-not [IO.File]::Exists($temporaryPath)) { throw }
            if ([IO.File]::Exists($stopRequestPath)) {
                [IO.File]::Replace($temporaryPath, $stopRequestPath, $null)
            } else {
                [IO.File]::Move($temporaryPath, $stopRequestPath)
            }
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-Bridge {
    if ($null -eq $script:bridgeProcess) {
        if ($null -ne $script:bridgeForcedStopProcess) {
            try {
                if (-not $script:bridgeForcedStopProcess.HasExited) { $script:bridgeForcedStopProcess.Kill() }
            } catch { } finally {
                $script:bridgeForcedStopProcess.Dispose()
                $script:bridgeForcedStopProcess = $null
            }
        }
        $script:bridgeRestartPhase = "idle"
        return
    }
    try {
        if (-not $script:bridgeProcess.HasExited) {
            if (-not [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId)) {
                try {
                    Write-StopBridgeRequest -TargetInstanceId $script:bridgeInstanceId
                    $gracefulDeadline = [DateTime]::UtcNow.AddSeconds(5)
                    while (-not $script:bridgeProcess.HasExited -and [DateTime]::UtcNow -lt $gracefulDeadline) {
                        Start-Sleep -Milliseconds 100
                        $script:bridgeProcess.Refresh()
                    }
                } catch {
                    # The forced fallback below remains available.
                }
            }
            if (-not $script:bridgeProcess.HasExited) {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $script:bridgeProcess.Id /T /F 2>$null | Out-Null
                $script:bridgeProcess.WaitForExit(3000)
            }
        }
    } catch {
        # The process may already have ended between the checks.
    } finally {
        Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
        $script:bridgeProcess.Dispose()
        $script:bridgeProcess = $null
        if ($null -ne $script:bridgeForcedStopProcess) {
            try {
                if (-not $script:bridgeForcedStopProcess.HasExited) { $script:bridgeForcedStopProcess.Kill() }
            } catch { } finally {
                $script:bridgeForcedStopProcess.Dispose()
                $script:bridgeForcedStopProcess = $null
            }
        }
        $script:bridgeRestartPhase = "idle"
    }
}

Update-TrayPreferences
$script:pollInterval = Get-EnvValue -Name "POLL_INTERVAL_SECONDS" -DefaultValue "60"
$script:nightscoutUrl = Get-EnvValue -Name "NIGHTSCOUT_URL" -DefaultValue ""
$requestTimeoutSeconds = 10
try {
    $requestTimeoutSeconds = [int](Get-EnvValue -Name "REQUEST_TIMEOUT_SECONDS" -DefaultValue "10")
} catch {
    $requestTimeoutSeconds = 10
}
$requestTimeoutSeconds = [Math]::Max(2, [Math]::Min(60, $requestTimeoutSeconds))
$testSoundTimeoutSeconds = [Math]::Max(120, ($requestTimeoutSeconds * 6) + 30)

$panelItem = [Windows.Forms.ToolStripMenuItem]::new("Abrir painel")
$panelItem.Font = [Drawing.Font]::new($panelItem.Font, [Drawing.FontStyle]::Bold)
$firstRunItem = [Windows.Forms.ToolStripMenuItem]::new("Configurar agora...")
$firstRunItem.Font = [Drawing.Font]::new($firstRunItem.Font, [Drawing.FontStyle]::Bold)
$firstRunItem.Visible = $false
$statusItem = [Windows.Forms.ToolStripMenuItem]::new("Status: iniciando")
$statusItem.Enabled = $false
$glucoseItem = [Windows.Forms.ToolStripMenuItem]::new("Glicemia: aguardando")
$glucoseItem.Enabled = $false
$sourceItem = [Windows.Forms.ToolStripMenuItem]::new("Fonte: aguardando")
$sourceItem.Enabled = $false
$readingItem = [Windows.Forms.ToolStripMenuItem]::new("Leitura: aguardando")
$readingItem.Enabled = $false
$clockItem = [Windows.Forms.ToolStripMenuItem]::new("Horario: aguardando")
$clockItem.Enabled = $false
$tc001Item = [Windows.Forms.ToolStripMenuItem]::new("TC001: aguardando")
$tc001Item.Enabled = $false
$soundItem = [Windows.Forms.ToolStripMenuItem]::new("Som: aguardando")
$soundItem.Enabled = $false
$deviceSoundItem = [Windows.Forms.ToolStripMenuItem]::new("Buzzer geral: ainda nao consultado")
$deviceSoundItem.Enabled = $false
$intervalItem = [Windows.Forms.ToolStripMenuItem]::new("Atualizacao: a cada $script:pollInterval segundos")
$intervalItem.Enabled = $false
$volumeControlItem = [Windows.Forms.ToolStripMenuItem]::new("Ligar ou desligar som do TC001...")
$volumeControlItem.Enabled = $false
$diagnosticsItem = [Windows.Forms.ToolStripMenuItem]::new("Verificar tudo...")
$diagnosticsItem.Enabled = $true
$maintenanceItem = [Windows.Forms.ToolStripMenuItem]::new("Atualizacoes e recuperacao...")
$testSoundItem = [Windows.Forms.ToolStripMenuItem]::new("Testar som")
$testSoundItem.Enabled = $false
$configureItem = [Windows.Forms.ToolStripMenuItem]::new("Configuracoes...")
$openNightscoutItem = [Windows.Forms.ToolStripMenuItem]::new("Abrir Nightscout")
if ([string]::IsNullOrWhiteSpace([string]$script:nightscoutUrl)) {
    $openNightscoutItem.Text = "Nightscout nao configurado"
    $openNightscoutItem.Enabled = $false
}
$openFolderItem = [Windows.Forms.ToolStripMenuItem]::new("Abrir pasta do projeto")
$restartItem = [Windows.Forms.ToolStripMenuItem]::new("Reiniciar conexao")
$toggleWidgetItem = [Windows.Forms.ToolStripMenuItem]::new("Ocultar mostrador")
$exitItem = [Windows.Forms.ToolStripMenuItem]::new("Encerrar")
$statusSeparator = [Windows.Forms.ToolStripSeparator]::new()
$actionsSeparator = [Windows.Forms.ToolStripSeparator]::new()
$exitSeparator = [Windows.Forms.ToolStripSeparator]::new()

$menu = [Windows.Forms.ContextMenuStrip]::new()
$menu.ShowImageMargin = $false
[void]$menu.Items.Add($panelItem)
[void]$menu.Items.Add($firstRunItem)
[void]$menu.Items.Add($glucoseItem)
[void]$menu.Items.Add($statusItem)
[void]$menu.Items.Add($statusSeparator)
[void]$menu.Items.Add($toggleWidgetItem)
[void]$menu.Items.Add($openNightscoutItem)
[void]$menu.Items.Add($restartItem)
[void]$menu.Items.Add($exitSeparator)
[void]$menu.Items.Add($exitItem)

$notifyIcon = [Windows.Forms.NotifyIcon]::new()
$notifyIcon.Icon = if ($null -ne $script:applicationIcon) { $script:applicationIcon } else { [Drawing.SystemIcons]::Information }
$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Text = "Ulanzi Libre: iniciando"
$notifyIcon.Visible = $true

$widget = [Windows.Forms.Form]::new()
$widget.Text = "Ulanzi Libre Glicemia"
[void](Set-UlanziUiApplicationIcon -Form $widget -ProjectRoot $projectRoot)
$widget.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
$widget.ShowInTaskbar = $false
$widget.TopMost = $true
$widget.BackColor = [Drawing.Color]::FromArgb(24, 24, 24)
$widget.Size = [Drawing.Size]::new(118, 44)
$widget.StartPosition = [Windows.Forms.FormStartPosition]::Manual
$widget.Opacity = 0.94
$widget.ContextMenuStrip = $menu

$glucoseLabel = [Windows.Forms.Label]::new()
$glucoseLabel.Dock = [Windows.Forms.DockStyle]::Fill
$glucoseLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$glucoseLabel.Font = [Drawing.Font]::new("Segoe UI", 17, [Drawing.FontStyle]::Bold)
$glucoseLabel.ForeColor = [Drawing.Color]::Gainsboro
$glucoseLabel.Text = "..."
$glucoseLabel.ContextMenuStrip = $menu
$widget.Controls.Add($glucoseLabel)

function Set-WidgetPosition {
    $workingArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $widget.Left = $workingArea.Right - $widget.Width - 8
    $widget.Top = $workingArea.Bottom - $widget.Height - 8
}

function Get-PreferredDialogOwner {
    if ($script:closing) { return $null }
    if ($null -ne $script:preferredDialogOwner) {
        try {
            $preferredControl = $script:preferredDialogOwner -as [Windows.Forms.Control]
            if (
                $null -ne $preferredControl -and
                -not $preferredControl.IsDisposed -and
                -not $preferredControl.Disposing -and
                $preferredControl.IsHandleCreated -and
                $preferredControl.Visible
            ) {
                return $preferredControl
            }
        } catch { }
    }
    if ($null -ne $script:controlPanelController) {
        try {
            $panelForm = $script:controlPanelController.Form
            if (
                $null -ne $panelForm -and
                -not $panelForm.IsDisposed -and
                -not $panelForm.Disposing -and
                $panelForm.IsHandleCreated -and
                $panelForm.Visible
            ) {
                return $panelForm
            }
        } catch { }
    }
    if (
        $null -ne $widget -and
        -not $widget.IsDisposed -and
        -not $widget.Disposing -and
        $widget.IsHandleCreated -and
        $widget.Visible
    ) {
        return $widget
    }
    return $null
}

function Invoke-PanelMenuAction {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.ToolStripMenuItem]$Item,
        [Parameter(Mandatory = $false)][AllowNull()][Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory = $true)][string]$UnavailableMessage
    )

    if (-not $Item.Enabled) { throw $UnavailableMessage }
    $script:preferredDialogOwner = $Owner
    try {
        $Item.PerformClick()
    } finally {
        $script:preferredDialogOwner = $null
    }
}

function Close-UlanziControlPanel {
    $controller = $script:controlPanelController
    if ($null -eq $controller) { return }
    $script:controlPanelController = $null
    try { & $controller.Dispose } catch { }
}

function Get-StatusProperty {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function ConvertTo-UtcDate {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    $parsed = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (
        [DateTime]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$parsed
        )
    ) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Format-Age {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Timestamp)

    $date = ConvertTo-UtcDate -Value $Timestamp
    if ($null -eq $date) { return "nunca" }
    $seconds = [Math]::Max(0, [Math]::Floor(([DateTime]::UtcNow - $date).TotalSeconds))
    if ($seconds -lt 5) { return "agora" }
    if ($seconds -lt 60) { return "ha $([int]$seconds) s" }
    if ($seconds -lt 3600) { return "ha $([int][Math]::Floor($seconds / 60)) min" }
    if ($seconds -lt 86400) { return "ha $([int][Math]::Floor($seconds / 3600)) h" }
    return "ha $([int][Math]::Floor($seconds / 86400)) d"
}

function Get-AlarmLabel {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Kind)

    switch ([string]$Kind) {
        "low"         { return "glicemia baixa" }
        "high"        { return "glicemia alta" }
        "up"          { return "subida" }
        "down"        { return "queda" }
        "double-up"   { return "subida rapida" }
        "no-data"     { return "sem dado" }
        "unavailable" { return "sem dado" }
        "test"        { return "teste" }
        default         { return "alarme" }
    }
}

function Set-ErrorToolTip {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.ToolStripItem]$Item,
        [Parameter(Mandatory = $false)][AllowNull()][object]$ErrorText
    )

    $text = [string]$ErrorText
    if ($text.Length -gt 240) { $text = $text.Substring(0, 240) }
    $Item.ToolTipText = $text
}

function Read-RuntimeStatus {
    if (-not (Test-Path -LiteralPath $statusPath)) {
        $script:lastRuntimeStatusFileStamp = "<missing>"
        return $script:lastRuntimeStatus
    }
    try {
        $file = Get-Item -LiteralPath $statusPath
        $fileStamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        if ($fileStamp -ceq [string]$script:lastRuntimeStatusFileStamp) {
            return $script:lastRuntimeStatus
        }
        $status = [IO.File]::ReadAllText($statusPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $version = 1
        try { $version = [int](Get-StatusProperty -Object $status -Name "version" -DefaultValue 1) } catch { $version = 1 }

        if ($version -ge 2) {
            $bridge = Get-StatusProperty -Object $status -Name "bridge"
            $instanceId = [string](Get-StatusProperty -Object $bridge -Name "instanceId" -DefaultValue "")
            if (
                [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId) -or
                $instanceId -cne [string]$script:bridgeInstanceId
            ) {
                $script:lastRuntimeStatus = $null
                $script:lastRuntimeStatusFileStamp = $fileStamp
                return $null
            }
        } elseif (
            $script:bridgeStartedAt -ne [DateTime]::MinValue -and
            $file.LastWriteTimeUtc -lt $script:bridgeStartedAt.AddSeconds(-1)
        ) {
            # Um status v1 nao tem instanceId. Ignore um arquivo claramente
            # anterior ao processo atual, mas continue aceitando bridges antigos.
            $script:lastRuntimeStatus = $null
            $script:lastRuntimeStatusFileStamp = $fileStamp
            return $null
        }

        $script:lastRuntimeStatus = $status
        $script:lastRuntimeStatusFileStamp = $fileStamp
        return $status
    } catch {
        # A troca atomica do arquivo pode coincidir com este tick. Preserve o
        # ultimo status valido da mesma instancia e tente novamente em seguida.
        return $script:lastRuntimeStatus
    }
}

function Set-GlucoseDisplay {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Color
    )

    $displaySignature = @($Text, $Color) -join '|'
    if ($script:lastDisplaySignature -eq $displaySignature) { return }
    $script:lastDisplaySignature = $displaySignature
    $glucoseLabel.Text = $Text
    try {
        $glucoseLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml($Color)
    } catch {
        $glucoseLabel.ForeColor = [Drawing.Color]::Gainsboro
    }
    $glucoseItem.Text = "Glicemia: $Text"

    $symbol = if ($Text -eq "SEM DADO") {
        "!"
    } elseif ($Text -eq "TROCAR") {
        "T"
    } elseif ($Text -eq "...") {
        "?"
    } else {
        ($Text -split ' ')[-1]
    }
    $newIcon = New-TrendIcon -Symbol $symbol -Color $Color
    $oldIcon = $script:dynamicIcon
    $script:dynamicIcon = $newIcon
    $notifyIcon.Icon = $newIcon
    if ($null -ne $oldIcon) { $oldIcon.Dispose() }
}

function New-TrendIcon {
    param(
        [Parameter(Mandatory = $true)][string]$Symbol,
        [Parameter(Mandatory = $true)][string]$Color
    )

    $bitmap = [Drawing.Bitmap]::new(32, 32, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $font = $null
    $brush = $null
    $backgroundBrush = $null
    $format = $null
    $handle = [IntPtr]::Zero
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        try {
            $backgroundColor = [Drawing.ColorTranslator]::FromHtml($Color)
        } catch {
            $backgroundColor = [Drawing.Color]::DimGray
        }
        $backgroundBrush = [Drawing.SolidBrush]::new($backgroundColor)
        $graphics.FillEllipse($backgroundBrush, 1, 1, 30, 30)

        $fontSize = if ($Symbol.Length -gt 1) { 15 } else { 20 }
        $font = [Drawing.Font]::new("Segoe UI Symbol", $fontSize, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $brush = [Drawing.SolidBrush]::new([Drawing.Color]::White)
        $format = [Drawing.StringFormat]::new()
        $format.Alignment = [Drawing.StringAlignment]::Center
        $format.LineAlignment = [Drawing.StringAlignment]::Center
        $graphics.DrawString($Symbol, $font, $brush, [Drawing.RectangleF]::new(0, -1, 32, 32), $format)

        $handle = $bitmap.GetHicon()
        $temporaryIcon = [Drawing.Icon]::FromHandle($handle)
        return $temporaryIcon.Clone()
    } finally {
        if ($handle -ne [IntPtr]::Zero) { [void][UlanziTrayNative]::DestroyIcon($handle) }
        if ($null -ne $format) { $format.Dispose() }
        if ($null -ne $brush) { $brush.Dispose() }
        if ($null -ne $backgroundBrush) { $backgroundBrush.Dispose() }
        if ($null -ne $font) { $font.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Update-GlucoseDisplay {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Status)

    if ($null -eq $Status) {
        Set-GlucoseDisplay -Text "..." -Color "#DCDCDC"
        return
    }
    try {
        $kind = [string](Get-StatusProperty -Object $Status -Name "kind" -DefaultValue "unavailable")
        if ($kind -eq "replace-sensor") {
            $replaceColor = [string](Get-StatusProperty -Object $Status -Name "textColor" -DefaultValue "#FF3131")
            Set-GlucoseDisplay -Text "TROCAR" -Color $replaceColor
            return
        }
        $reading = Get-StatusProperty -Object $Status -Name "reading"
        $expiresValue = Get-StatusProperty -Object $reading -Name "expiresAt"
        if ($null -eq $expiresValue) {
            $expiresValue = Get-StatusProperty -Object $Status -Name "expiresAt"
        }
        $expiresAt = ConvertTo-UtcDate -Value $expiresValue
        if (
            [string](Get-StatusProperty -Object $Status -Name "status" -DefaultValue "unavailable") -ne "active" -or
            ($null -ne $expiresAt -and [DateTime]::UtcNow -ge $expiresAt)
        ) {
            Set-GlucoseDisplay -Text "SEM DADO" -Color "#FF3131"
            return
        }
        $value = ([string](Get-StatusProperty -Object $Status -Name "text" -DefaultValue "") -split ' ')[0]
        if ([string]::IsNullOrWhiteSpace($value)) {
            Set-GlucoseDisplay -Text "SEM DADO" -Color "#FF3131"
            return
        }
        $arrow = switch ([string](Get-StatusProperty -Object $Status -Name "trend" -DefaultValue "unknown")) {
            "double-up"   { [char]0x21C8 }
            "up"          { [char]0x2191 }
            "up-slight"   { [char]0x2197 }
            "flat"        { [char]0x2192 }
            "down-slight" { [char]0x2198 }
            "down"        { [char]0x2193 }
            "double-down" { [char]0x21CA }
            default        { "?" }
        }
        $color = [string](Get-StatusProperty -Object $Status -Name "textColor" -DefaultValue "#DCDCDC")
        Set-GlucoseDisplay -Text "$value $arrow" -Color $color
    } catch {
        # Preserve o valor anterior e tente novamente no proximo tick.
    }
}

function Update-StatusDetails {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Status)

    Set-ErrorToolTip -Item $sourceItem -ErrorText ""
    Set-ErrorToolTip -Item $clockItem -ErrorText ""
    Set-ErrorToolTip -Item $tc001Item -ErrorText ""
    Set-ErrorToolTip -Item $soundItem -ErrorText ""
    Set-ErrorToolTip -Item $deviceSoundItem -ErrorText ""
    if ($null -eq $Status) {
        $sourceItem.Text = "Fonte: aguardando"
        $readingItem.Text = "Leitura: aguardando"
        $clockItem.Text = "Horario: aguardando"
        $tc001Item.Text = "TC001: aguardando"
        $soundItem.Text = "Som: aguardando"
        $deviceSoundItem.Text = "Buzzer geral: aguardando"
        return
    }

    $version = 1
    try { $version = [int](Get-StatusProperty -Object $Status -Name "version" -DefaultValue 1) } catch { $version = 1 }
    $reading = Get-StatusProperty -Object $Status -Name "reading"
    $readingTimestamp = Get-StatusProperty -Object $reading -Name "timestamp"
    if ($null -eq $readingTimestamp) {
        $readingTimestamp = Get-StatusProperty -Object $Status -Name "readingTimestamp"
    }
    $displayKind = [string](Get-StatusProperty -Object $Status -Name "kind" -DefaultValue "unavailable")
    if ($displayKind -eq "replace-sensor") {
        $readingItem.Text = "Leitura: trocar sensor"
    } elseif ($null -eq (ConvertTo-UtcDate -Value $readingTimestamp)) {
        $readingItem.Text = "Leitura: nenhuma recebida"
    } else {
        $readingItem.Text = "Leitura: $(Format-Age -Timestamp $readingTimestamp)"
    }

    if ($version -lt 2) {
        $sourceItem.Text = "Fonte: nao informada pelo status basico"
        $clockItem.Text = "Horario: nao informado pelo status basico"
        $tc001Item.Text = "TC001: nao informado pelo status basico"
        $soundItem.Text = "Som: nao informado pelo status basico"
        $deviceSoundItem.Text = "Buzzer geral: nao informado pelo status basico"
        return
    }

    $clock = Get-StatusProperty -Object $Status -Name "clock"
    $clockState = [string](Get-StatusProperty -Object $clock -Name "state" -DefaultValue "unknown")
    $offsetSeconds = 0
    try { $offsetSeconds = [int](Get-StatusProperty -Object $clock -Name "offsetSeconds" -DefaultValue 0) } catch { $offsetSeconds = 0 }
    $offsetMinutes = [Math]::Round([Math]::Abs($offsetSeconds) / 60, 1)
    switch ($clockState) {
        "ok" {
            $clockItem.Text = "Horario: coerente com a leitura"
        }
        "warning" {
            $clockItem.Text = "Horario: leitura adiantada em cerca de $offsetMinutes min"
            Set-ErrorToolTip -Item $clockItem -ErrorText (Get-StatusProperty -Object $clock -Name "message")
        }
        "error" {
            $clockItem.Text = "Horario: diferenca critica de cerca de $offsetMinutes min"
            Set-ErrorToolTip -Item $clockItem -ErrorText (Get-StatusProperty -Object $clock -Name "message")
        }
        default {
            $clockItem.Text = "Horario: aguardando uma leitura valida"
        }
    }

    $source = Get-StatusProperty -Object $Status -Name "source"
    $sourceState = [string](Get-StatusProperty -Object $source -Name "state" -DefaultValue "waiting")
    $sourceAttempt = Get-StatusProperty -Object $source -Name "lastAttemptAt"
    $sourceSuccess = Get-StatusProperty -Object $source -Name "lastSuccessAt"
    $sourceFailures = 0
    try { $sourceFailures = [int](Get-StatusProperty -Object $source -Name "consecutiveFailures" -DefaultValue 0) } catch { $sourceFailures = 0 }
    switch ($sourceState) {
        "connecting" {
            $lastOk = if ($null -eq (ConvertTo-UtcDate -Value $sourceSuccess)) {
                "primeira consulta"
            } else {
                "ultimo OK $(Format-Age -Timestamp $sourceSuccess)"
            }
            $sourceItem.Text = "Fonte: consultando agora - $lastOk"
        }
        "connected" {
            $sourceItem.Text = "Fonte: conectada - consulta OK $(Format-Age -Timestamp $sourceSuccess)"
        }
        "error" {
            $lastOk = if ($null -eq (ConvertTo-UtcDate -Value $sourceSuccess)) {
                "nenhuma consulta confirmada"
            } else {
                "ultimo OK $(Format-Age -Timestamp $sourceSuccess)"
            }
            $failureLabel = if ($sourceFailures -eq 1) { "1 falha" } else { "$sourceFailures falhas" }
            $sourceItem.Text = "Fonte: falhou $(Format-Age -Timestamp $sourceAttempt) - $lastOk ($failureLabel)"
            Set-ErrorToolTip -Item $sourceItem -ErrorText (Get-StatusProperty -Object $source -Name "lastError")
        }
        default {
            $sourceItem.Text = "Fonte: aguardando primeira consulta"
        }
    }

    $tc001 = Get-StatusProperty -Object $Status -Name "tc001"
    $tc001State = [string](Get-StatusProperty -Object $tc001 -Name "state" -DefaultValue "waiting")
    $tc001Attempt = Get-StatusProperty -Object $tc001 -Name "lastAttemptAt"
    $tc001Confirmed = Get-StatusProperty -Object $tc001 -Name "lastConfirmedAt"
    $tc001Mode = [string](Get-StatusProperty -Object $tc001 -Name "mode" -DefaultValue "")
    $modeLabel = if ([string]::IsNullOrWhiteSpace($tc001Mode)) { "" } elseif ($tc001Mode -eq "ng") { " (NG)" } else { " (AWTRIX 3)" }
    switch ($tc001State) {
        "sending" {
            $tc001Item.Text = "TC001: enviando agora$modeLabel"
        }
        "confirmed" {
            $tc001Item.Text = "TC001: envio confirmado $(Format-Age -Timestamp $tc001Confirmed)$modeLabel"
        }
        "error" {
            $lastOk = if ($null -eq (ConvertTo-UtcDate -Value $tc001Confirmed)) {
                "nenhum envio confirmado"
            } else {
                "ultimo OK $(Format-Age -Timestamp $tc001Confirmed)"
            }
            $tc001Item.Text = "TC001: falhou $(Format-Age -Timestamp $tc001Attempt) - $lastOk$modeLabel"
            Set-ErrorToolTip -Item $tc001Item -ErrorText (Get-StatusProperty -Object $tc001 -Name "lastError")
        }
        default {
            $tc001Item.Text = "TC001: aguardando primeiro envio"
        }
    }

    $sound = Get-StatusProperty -Object $Status -Name "sound"
    $soundEnabled = (Get-StatusProperty -Object $sound -Name "enabled" -DefaultValue $false) -eq $true
    $soundState = [string](Get-StatusProperty -Object $sound -Name "state" -DefaultValue "idle")
    $soundAttempt = Get-StatusProperty -Object $sound -Name "lastAttemptAt"
    $soundConfirmed = Get-StatusProperty -Object $sound -Name "lastConfirmedAt"
    $soundKind = Get-StatusProperty -Object $sound -Name "lastKind"
    $soundOrigin = [string](Get-StatusProperty -Object $sound -Name "lastOrigin" -DefaultValue "automatic")
    $soundLabel = if ($soundOrigin -eq "test") { "teste" } else { Get-AlarmLabel -Kind $soundKind }
    switch ($soundState) {
        "pending" {
            $pendingKind = Get-AlarmLabel -Kind (Get-StatusProperty -Object $sound -Name "pendingKind")
            $attempts = 0
            $maxAttempts = 0
            try { $attempts = [int](Get-StatusProperty -Object $sound -Name "pendingAttempts" -DefaultValue 0) } catch { $attempts = 0 }
            try { $maxAttempts = [int](Get-StatusProperty -Object $sound -Name "pendingMaxAttempts" -DefaultValue 0) } catch { $maxAttempts = 0 }
            $attemptLabel = if ($maxAttempts -gt 0) { " ($attempts/$maxAttempts)" } else { "" }
            $soundItem.Text = "Som: aguardando confirmacao - $pendingKind$attemptLabel"
        }
        "confirmed" {
            $prefix = if ($soundEnabled) { "Som" } else { "Som desativado; ultimo comando" }
            $soundItem.Text = "$prefix`: aceito $(Format-Age -Timestamp $soundConfirmed) ($soundLabel)"
        }
        "error" {
            $lastOk = if ($null -eq (ConvertTo-UtcDate -Value $soundConfirmed)) {
                "nenhum comando confirmado"
            } else {
                "ultimo aceito $(Format-Age -Timestamp $soundConfirmed) ($soundLabel)"
            }
            $soundItem.Text = "Som: falhou $(Format-Age -Timestamp $soundAttempt) - $lastOk"
            Set-ErrorToolTip -Item $soundItem -ErrorText (Get-StatusProperty -Object $sound -Name "lastError")
        }
        default {
            if ($null -ne (ConvertTo-UtcDate -Value $soundConfirmed)) {
                $prefix = if ($soundEnabled) { "Som" } else { "Som desativado; ultimo comando" }
                $soundItem.Text = "$prefix`: aceito $(Format-Age -Timestamp $soundConfirmed) ($soundLabel)"
            } elseif ($soundEnabled) {
                $soundItem.Text = "Som: nenhum comando confirmado"
            } else {
                $soundItem.Text = "Som: desativado - nenhum comando confirmado"
            }
        }
    }

    $deviceSound = Get-StatusProperty -Object $Status -Name "deviceSound"
    $deviceSoundState = [string](Get-StatusProperty -Object $deviceSound -Name "state" -DefaultValue "unknown")
    $deviceSoundMode = [string](Get-StatusProperty -Object $deviceSound -Name "mode" -DefaultValue "")
    $deviceSoundVolume = Get-StatusProperty -Object $deviceSound -Name "buzzerVolume"
    $volumeLabel = if ($null -eq $deviceSoundVolume) { "?" } else { "$deviceSoundVolume%" }
    switch ($deviceSoundState) {
        "reading" {
            $deviceSoundItem.Text = "Buzzer geral: consultando..."
        }
        "writing" {
            $deviceSoundItem.Text = "Buzzer geral: aplicando..."
        }
        "confirmed" {
            $deviceSoundItem.Text = "Buzzer geral: ligado (nivel tecnico $volumeLabel)"
        }
        "muted" {
            $deviceSoundItem.Text = "Buzzer geral: desligado (nivel tecnico $volumeLabel)"
        }
        "silent" {
            $deviceSoundItem.Text = "Buzzer geral: sem som"
        }
        "unsupported" {
            if ($deviceSoundMode -eq "3") {
                $deviceSoundItem.Text = "Buzzer geral: controlado pelo AWTRIX 3"
            } else {
                $deviceSoundItem.Text = "Buzzer geral: indisponivel neste TC001"
            }
        }
        "error" {
            $deviceSoundItem.Text = "Buzzer geral: nao confirmado"
            Set-ErrorToolTip -Item $deviceSoundItem -ErrorText (Get-StatusProperty -Object $deviceSound -Name "lastRequestError")
        }
        default {
            $deviceSoundItem.Text = "Buzzer geral: abra o controle para consultar"
        }
    }
}

function Get-BridgeResponsiveness {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Status)

    if (Test-BridgeRestartBusy) {
        return [pscustomobject]@{
            Responsive = $false
            Busy = $true
            Text = Get-BridgeRestartText
        }
    }
    if (-not (Test-BridgeRunning)) {
        return [pscustomobject]@{ Responsive = $false; Busy = $false; Text = "aplicativo parado" }
    }
    if ($null -eq $Status) {
        return [pscustomobject]@{ Responsive = $false; Busy = $false; Text = "aguardando status recente" }
    }

    $version = 1
    try { $version = [int](Get-StatusProperty -Object $Status -Name "version" -DefaultValue 1) } catch { $version = 1 }
    if ($version -lt 2) {
        return [pscustomobject]@{ Responsive = $true; Busy = $false; Text = "status basico recebido" }
    }

    $bridge = Get-StatusProperty -Object $Status -Name "bridge"
    $nextCycleAt = ConvertTo-UtcDate -Value (Get-StatusProperty -Object $bridge -Name "nextCycleAt")
    $cycleDeadlineAt = ConvertTo-UtcDate -Value (Get-StatusProperty -Object $bridge -Name "cycleDeadlineAt")
    $writtenAt = ConvertTo-UtcDate -Value (Get-StatusProperty -Object $Status -Name "writtenAt")
    $overdueGrace = [Math]::Max(30, $requestTimeoutSeconds * 6)
    if (
        $null -ne $nextCycleAt -and
        $null -ne $writtenAt -and
        [DateTime]::UtcNow -gt $nextCycleAt.AddSeconds($overdueGrace) -and
        [DateTime]::UtcNow -gt $writtenAt.AddSeconds($overdueGrace)
    ) {
        return [pscustomobject]@{ Responsive = $false; Busy = $false; Text = "bridge sem resposta" }
    }
    if ($null -ne $cycleDeadlineAt -and [DateTime]::UtcNow -gt $cycleDeadlineAt) {
        return [pscustomobject]@{ Responsive = $false; Busy = $false; Text = "ciclo do bridge excedeu o prazo" }
    }

    return [pscustomobject]@{ Responsive = $true; Busy = $false; Text = "status recente recebido" }
}

function Get-OverallTrayStatus {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Status)

    $bridgeHealth = Get-BridgeResponsiveness -Status $Status
    if (-not [bool]$bridgeHealth.Responsive) {
        return [pscustomobject]@{ Text = [string]$bridgeHealth.Text; Healthy = $false }
    }
    $version = 1
    try { $version = [int](Get-StatusProperty -Object $Status -Name "version" -DefaultValue 1) } catch { $version = 1 }
    if ($version -lt 2) {
        $legacyExpiresAt = ConvertTo-UtcDate -Value (Get-StatusProperty -Object $Status -Name "expiresAt")
        $active =
            [string](Get-StatusProperty -Object $Status -Name "status" -DefaultValue "unavailable") -eq "active" -and
            ($null -eq $legacyExpiresAt -or [DateTime]::UtcNow -lt $legacyExpiresAt)
        return [pscustomobject]@{
            Text = if ($active) { "ativo (status basico)" } else { "sem dado (status basico)" }
            Healthy = $active
        }
    }

    $source = Get-StatusProperty -Object $Status -Name "source"
    $clock = Get-StatusProperty -Object $Status -Name "clock"
    $tc001 = Get-StatusProperty -Object $Status -Name "tc001"
    $sound = Get-StatusProperty -Object $Status -Name "sound"
    $deviceSound = Get-StatusProperty -Object $Status -Name "deviceSound"
    $sourceState = [string](Get-StatusProperty -Object $source -Name "state" -DefaultValue "waiting")
    $clockState = [string](Get-StatusProperty -Object $clock -Name "state" -DefaultValue "unknown")
    $tc001State = [string](Get-StatusProperty -Object $tc001 -Name "state" -DefaultValue "waiting")
    $soundState = [string](Get-StatusProperty -Object $sound -Name "state" -DefaultValue "idle")
    $automaticSoundEnabled = (Get-StatusProperty -Object $sound -Name "enabled" -DefaultValue $false) -eq $true
    $deviceSoundState = [string](Get-StatusProperty -Object $deviceSound -Name "state" -DefaultValue "unknown")
    $displayState = [string](Get-StatusProperty -Object $Status -Name "status" -DefaultValue "unavailable")
    $displayKind = [string](Get-StatusProperty -Object $Status -Name "kind" -DefaultValue "unavailable")
    $reading = Get-StatusProperty -Object $Status -Name "reading"
    $readingExpiresAt = Get-StatusProperty -Object $reading -Name "expiresAt"
    if ($null -eq $readingExpiresAt) {
        $readingExpiresAt = Get-StatusProperty -Object $Status -Name "expiresAt"
    }
    $expiresAt = ConvertTo-UtcDate -Value $readingExpiresAt
    if ($clockState -eq "error" -or $clockState -eq "warning") {
        return [pscustomobject]@{ Text = "diferenca de horario detectada"; Healthy = $false }
    }
    if ($sourceState -eq "error") { return [pscustomobject]@{ Text = "fonte com erro"; Healthy = $false } }
    if ($tc001State -eq "error") { return [pscustomobject]@{ Text = "TC001 com erro"; Healthy = $false } }
    if ($displayKind -eq "replace-sensor") {
        return [pscustomobject]@{ Text = "trocar sensor"; Healthy = $false }
    }
    if ($displayState -ne "active" -or ($null -ne $expiresAt -and [DateTime]::UtcNow -ge $expiresAt)) {
        return [pscustomobject]@{ Text = "sem dado recente"; Healthy = $false }
    }
    if ($tc001State -eq "confirmed") {
        $readingTimestamp = ConvertTo-UtcDate -Value (Get-StatusProperty -Object $reading -Name "timestamp")
        $confirmedReadingTimestamp = ConvertTo-UtcDate -Value (Get-StatusProperty -Object $tc001 -Name "lastConfirmedReadingTimestamp")
        if (
            $null -ne $readingTimestamp -and
            ($null -eq $confirmedReadingTimestamp -or $readingTimestamp -ne $confirmedReadingTimestamp)
        ) {
            return [pscustomobject]@{ Text = "leitura aguardando envio ao TC001"; Healthy = $false }
        }
    }
    if ($soundState -eq "error") { return [pscustomobject]@{ Text = "comando de som com erro"; Healthy = $false } }
    if ($automaticSoundEnabled -and ($deviceSoundState -eq "muted" -or $deviceSoundState -eq "silent")) {
        return [pscustomobject]@{ Text = "alertas sonoros silenciados no TC001"; Healthy = $false }
    }
    if ($sourceState -eq "waiting" -or $tc001State -eq "waiting") {
        return [pscustomobject]@{ Text = "iniciando"; Healthy = $false }
    }
    if ($sourceState -eq "connecting") { return [pscustomobject]@{ Text = "consultando fonte"; Healthy = $true } }
    if ($tc001State -eq "sending") { return [pscustomobject]@{ Text = "atualizando TC001"; Healthy = $true } }
    if ($soundState -eq "pending") { return [pscustomobject]@{ Text = "alarme pendente"; Healthy = $false } }
    return [pscustomobject]@{ Text = "operando normalmente"; Healthy = $true }
}

function Set-TrayStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][bool]$Healthy
    )

    $statusItem.Text = "Status: $Status"
    if (-not $Healthy) {
        $notifyIcon.Icon = [Drawing.SystemIcons]::Error
    } elseif ($null -ne $script:dynamicIcon) {
        $notifyIcon.Icon = $script:dynamicIcon
    } else {
        $notifyIcon.Icon = if ($null -ne $script:applicationIcon) { $script:applicationIcon } else { [Drawing.SystemIcons]::Information }
    }
    $tooltip = "Ulanzi Libre: $Status | $script:pollInterval s"
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
    $notifyIcon.Text = $tooltip
}

function Test-BridgeRunning {
    if ($null -eq $script:bridgeProcess) { return $false }
    try { return -not $script:bridgeProcess.HasExited } catch { return $false }
}

function Show-TrayBalloon {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $false)][Windows.Forms.ToolTipIcon]$Icon = [Windows.Forms.ToolTipIcon]::Info
    )

    $notifyIcon.BalloonTipTitle = "Ulanzi Libre"
    $notifyIcon.BalloonTipText = $Text
    $notifyIcon.BalloonTipIcon = $Icon
    $notifyIcon.ShowBalloonTip(5000)
}

function Invoke-WindowsFallbackSound {
    try { [Media.SystemSounds]::Hand.Play() } catch { }
}

function Update-WindowsFallbackNotifications {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Status)

    if (-not $script:windowsFallbackEnabled) {
        $script:failureStartedAt.Clear()
        $script:failureNotified.Clear()
        return
    }

    $bridgeHealth = Get-BridgeResponsiveness -Status $Status
    $bridgeResponsive = [bool]$bridgeHealth.Responsive
    $checks = @(
        [pscustomobject]@{
            Key = "bridge"
            Failed = (-not $bridgeResponsive)
            Label = "aplicativo"
        }
    )
    if ($bridgeResponsive) {
        $source = Get-StatusProperty -Object $Status -Name "source"
        $tc001 = Get-StatusProperty -Object $Status -Name "tc001"
        $clock = Get-StatusProperty -Object $Status -Name "clock"
        $checks += @(
            [pscustomobject]@{
            Key = "source"
            Failed = ([string](Get-StatusProperty -Object $source -Name "state" -DefaultValue "waiting") -eq "error")
            Label = "fonte de glicemia"
            },
            [pscustomobject]@{
                Key = "tc001"
                Failed = ([string](Get-StatusProperty -Object $tc001 -Name "state" -DefaultValue "waiting") -eq "error")
                Label = "TC001"
            },
            [pscustomobject]@{
                Key = "clock"
                Failed = ([string](Get-StatusProperty -Object $clock -Name "state" -DefaultValue "unknown") -in @("warning", "error"))
                Label = "horario da fonte ou do computador"
            }
        )
    }
    $now = [DateTime]::UtcNow
    $delay = [TimeSpan]::FromMinutes($script:windowsNotificationDelayMinutes)
    $newFailures = [Collections.Generic.List[string]]::new()
    $recoveries = [Collections.Generic.List[string]]::new()
    foreach ($check in $checks) {
        if ($check.Failed) {
            if (-not $script:failureStartedAt.ContainsKey($check.Key)) {
                $script:failureStartedAt[$check.Key] = $now
            }
            if (
                -not $script:failureNotified.ContainsKey($check.Key) -and
                ($now - [DateTime]$script:failureStartedAt[$check.Key]) -ge $delay
            ) {
                $script:failureNotified[$check.Key] = $true
                $newFailures.Add([string]$check.Label)
            }
            continue
        }
        if ($script:failureNotified.ContainsKey($check.Key)) {
            $recoveries.Add([string]$check.Label)
        }
        [void]$script:failureStartedAt.Remove($check.Key)
        [void]$script:failureNotified.Remove($check.Key)
    }

    if ($newFailures.Count -gt 0) {
        Invoke-WindowsFallbackSound
        Show-TrayBalloon -Text "Falha persistente em: $($newFailures -join ', '). Abra Verificar tudo para obter orientacao." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($recoveries.Count -gt 0) {
        Show-TrayBalloon -Text "Conexao recuperada: $($recoveries -join ', ')." -Icon ([Windows.Forms.ToolTipIcon]::Info)
    }

    if (-not $bridgeResponsive) { return }
    $sound = Get-StatusProperty -Object $Status -Name "sound"
    $soundState = [string](Get-StatusProperty -Object $sound -Name "state" -DefaultValue "idle")
    $alarmEnabled = (Get-StatusProperty -Object $sound -Name "enabled" -DefaultValue $false) -eq $true
    $pendingKind = [string](Get-StatusProperty -Object $sound -Name "pendingKind" -DefaultValue "")
    if ($alarmEnabled -and $pendingKind -in @("low", "high", "up", "down", "unavailable") -and $soundState -eq "error") {
        $fingerprint = $pendingKind
        if ($fingerprint -cne [string]$script:lastFallbackAlarmFingerprint) {
            $script:lastFallbackAlarmFingerprint = $fingerprint
            Invoke-WindowsFallbackSound
            $fallbackText = switch ($pendingKind) {
                "low" { "Alerta de glicemia baixa nao confirmado pelo TC001. Confira a fonte agora." }
                "high" { "Alerta de glicemia alta nao confirmado pelo TC001. Confira a fonte agora." }
                "up" { "Alerta de subida nao confirmado pelo TC001. Confira a fonte agora." }
                "down" { "Alerta de queda nao confirmado pelo TC001. Confira a fonte agora." }
                default { "Aviso de ausencia de dados nao confirmado pelo TC001. Confira a fonte." }
            }
            Show-TrayBalloon -Text $fallbackText -Icon ([Windows.Forms.ToolTipIcon]::Error)
        }
    } elseif (
        [string]::IsNullOrWhiteSpace($pendingKind) -or
        (
            -not [string]::IsNullOrWhiteSpace([string]$script:lastFallbackAlarmFingerprint) -and
            $pendingKind -cne [string]$script:lastFallbackAlarmFingerprint
        )
    ) {
        $script:lastFallbackAlarmFingerprint = $null
    }
}

function Write-RuntimeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("test-sound", "read-device-sound", "write-device-sound")]
        [string]$Command,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][string]$TargetInstanceId,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Payload = $null
    )

    [void][IO.Directory]::CreateDirectory($runtimePath)
    $temporaryPath = "$commandPath.$PID.$RequestId.tmp"
    $request = [ordered]@{
        version = 1
        command = $Command
        requestId = $RequestId
        targetInstanceId = $TargetInstanceId
        createdAt = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Command -eq "write-device-sound") {
        if ($null -eq $Payload) { throw "Os ajustes de volume nao foram informados." }
        $soundEnabled = Get-StatusProperty -Object $Payload -Name "soundEnabled"
        if ($soundEnabled -isnot [bool]) { throw "O estado geral do som e invalido." }
        $buzzerVolumeRaw = Get-StatusProperty -Object $Payload -Name "buzzerVolume"
        $buzzerVolume = 0
        if (
            -not [int]::TryParse([string]$buzzerVolumeRaw, [ref]$buzzerVolume) -or
            $buzzerVolume -lt 0 -or
            $buzzerVolume -gt 100
        ) {
            throw "O volume precisa estar entre 0 e 100."
        }
        $request["soundEnabled"] = $soundEnabled
        $request["buzzerVolume"] = $buzzerVolume
    }
    $json = $request | ConvertTo-Json -Compress
    try {
        [IO.File]::WriteAllText($temporaryPath, "$json`n", [Text.UTF8Encoding]::new($false))
        try {
            if ([IO.File]::Exists($commandPath)) {
                [IO.File]::Replace($temporaryPath, $commandPath, $null)
            } else {
                [IO.File]::Move($temporaryPath, $commandPath)
            }
        } catch {
            # O bridge pode consumir o destino entre o teste e a troca. Repita
            # uma vez escolhendo a operacao correta para o estado mais recente.
            if (-not [IO.File]::Exists($temporaryPath)) { throw }
            if ([IO.File]::Exists($commandPath)) {
                [IO.File]::Replace($temporaryPath, $commandPath, $null)
            } else {
                [IO.File]::Move($temporaryPath, $commandPath)
            }
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Complete-SoundTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:pendingSoundRequestId = $null
    $script:pendingSoundDeadline = [DateTime]::MinValue
    $testSoundItem.Text = "Testar som"
    $testSoundItem.Enabled = ((Test-BridgeRunning) -and -not $script:configurationDialogOpen -and -not $script:volumeDialogOpen -and -not $script:diagnosticsDialogOpen -and -not $script:maintenanceDialogOpen)
    $icon = if ($Succeeded) { [Windows.Forms.ToolTipIcon]::Info } else { [Windows.Forms.ToolTipIcon]::Error }
    Show-TrayBalloon -Text $Message -Icon $icon
}

function Update-SoundTestRequest {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Status)

    if ([string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)) { return }
    if ($null -ne $Status) {
        $sound = Get-StatusProperty -Object $Status -Name "sound"
        $requestId = [string](Get-StatusProperty -Object $sound -Name "lastTestRequestId" -DefaultValue "")
        $state = [string](Get-StatusProperty -Object $sound -Name "lastTestState" -DefaultValue "")
        $lastError = [string](Get-StatusProperty -Object $sound -Name "lastTestError" -DefaultValue "")
        if ([string]::IsNullOrWhiteSpace($requestId)) {
            $origin = [string](Get-StatusProperty -Object $sound -Name "lastOrigin" -DefaultValue "")
            if ($origin -eq "test") {
                $requestId = [string](Get-StatusProperty -Object $sound -Name "lastRequestId" -DefaultValue "")
                $state = [string](Get-StatusProperty -Object $sound -Name "state" -DefaultValue "")
                $lastError = [string](Get-StatusProperty -Object $sound -Name "lastError" -DefaultValue "")
            }
        }
        if ($requestId -ceq [string]$script:pendingSoundRequestId) {
            if ($state -eq "confirmed") {
                Complete-SoundTest -Succeeded $true -Message "O TC001 aceitou o comando de teste de som."
                return
            }
            if ($state -eq "error") {
                $message = if ([string]::IsNullOrWhiteSpace($lastError)) {
                    "O TC001 nao confirmou o teste de som."
                } else {
                    "O teste de som falhou: $lastError"
                }
                Complete-SoundTest -Succeeded $false -Message $message
                return
            }
        }
    }
    if ([DateTime]::UtcNow -ge $script:pendingSoundDeadline) {
        Complete-SoundTest -Succeeded $false -Message "O bridge nao confirmou o teste de som dentro do prazo."
    }
}

function Get-UlanziSetupState {
    return [pscustomobject]@{
        State = [string]$script:configurationState
        Message = [string]$script:configurationMessage
    }
}

function Update-ConfigurationDependentValues {
    $script:pollInterval = Get-EnvValue -Name "POLL_INTERVAL_SECONDS" -DefaultValue "60"
    $script:nightscoutUrl = Get-EnvValue -Name "NIGHTSCOUT_URL" -DefaultValue ""
    Update-TrayPreferences
    $intervalItem.Text = "Atualizacao: a cada $script:pollInterval segundos"
    if ([string]::IsNullOrWhiteSpace([string]$script:nightscoutUrl)) {
        $openNightscoutItem.Text = "Nightscout nao configurado"
        $openNightscoutItem.Enabled = $false
    } else {
        $openNightscoutItem.Text = "Abrir Nightscout"
        $openNightscoutItem.Enabled = $true
    }
}

function Set-UlanziConfigurationRequired {
    param([Parameter(Mandatory = $true)][string]$Message)

    $script:configurationState = "required"
    $script:configurationMessage = $Message
    $script:nextRestart = [DateTime]::MaxValue
    $firstRunItem.Visible = $true
    $firstRunItem.Enabled = -not $script:configurationDialogOpen
    $restartItem.Enabled = $false
    Set-GlucoseDisplay -Text "CONFIG" -Color "#F4B942"
    $glucoseItem.Text = "Glicemia: aguardando configuracao"
    $sourceItem.Text = "Fonte: configure para conectar"
    $readingItem.Text = "Leitura: indisponivel ate configurar"
    $tc001Item.Text = "TC001: configure para conectar"
    $soundItem.Text = "Som: disponivel depois da configuracao"
    $deviceSoundItem.Text = "Buzzer geral: disponivel depois da configuracao"
    Set-TrayStatus -Status "configuracao necessaria" -Healthy $false
    if ($null -ne $script:applicationIcon) { $notifyIcon.Icon = $script:applicationIcon }
}

function Start-UlanziConfigurationCheck {
    param(
        [Parameter(Mandatory = $false)][ValidateSet("startup", "first-run", "recovery")][string]$Reason = "startup"
    )

    if ($null -ne $script:configurationCheckOperation) { return $false }
    $script:configurationState = "checking"
    $script:configurationMessage = switch ($Reason) {
        "first-run" { "Conferindo a configuracao que acabou de ser salva..." }
        "recovery" { "Conferindo a configuracao antes de recuperar a conexao..." }
        default { "Verificando a configuracao inicial..." }
    }
    $script:configurationCheckReason = $Reason
    $firstRunItem.Visible = $false
    try {
        $script:configurationCheckOperation = Start-UlanziConfigEditorOperation `
            -Command "read" `
            -ProjectRoot $projectRoot `
            -EnvPath $envPath
        $script:configurationCheckDeadline = [DateTime]::UtcNow.AddSeconds(30)
        $timer.Interval = 250
        return $true
    } catch {
        $message = if (Test-Path -LiteralPath $envPath) {
            "A configuracao salva precisa ser corrigida antes de iniciar."
        } else {
            "A configuracao inicial ainda nao foi concluida."
        }
        Set-UlanziConfigurationRequired -Message $message
        return $false
    }
}

function Complete-UlanziConfigurationCheck {
    if ($null -eq $script:configurationCheckOperation) { return }
    $operation = $script:configurationCheckOperation
    $timedOut = [DateTime]::UtcNow -ge $script:configurationCheckDeadline
    if (-not $operation.Process.HasExited -and -not $timedOut) { return }

    $reason = [string]$script:configurationCheckReason
    $script:configurationCheckOperation = $null
    $script:configurationCheckDeadline = [DateTime]::MinValue
    $timer.Interval = 2000
    $configurationReady = $false
    try {
        if ($timedOut -and -not $operation.Process.HasExited) {
            Stop-UlanziConfigEditorOperation -Operation $operation
            $operation = $null
            throw "A verificacao da configuracao excedeu o tempo limite."
        }
        try {
            [void](Complete-UlanziConfigEditorOperation -Operation $operation)
        } finally {
            $operation = $null
        }
        $configurationReady = $true
    } catch {
        $message = if (Test-Path -LiteralPath $envPath) {
            "A configuracao salva precisa ser corrigida antes de iniciar."
        } else {
            "A configuracao inicial ainda nao foi concluida."
        }
        Set-UlanziConfigurationRequired -Message $message
    } finally {
        if ($null -ne $operation) { Stop-UlanziConfigEditorOperation -Operation $operation }
    }

    if (-not $configurationReady) {
        switch ($reason) {
            "first-run" {
                Show-TrayBalloon -Text "A configuracao nao foi concluida. O aplicativo permanecera parado ate voce escolher Configurar agora." -Icon ([Windows.Forms.ToolTipIcon]::Info)
            }
            "recovery" {
                Show-TrayBalloon -Text "A configuracao foi removida ou deixou de ser valida. A conexao nao sera reiniciada ate voce corrigir a configuracao." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
            }
            default {
                Show-TrayBalloon -Text "Antes de usar o Ulanzi Libre, conclua a configuracao da fonte de glicemia e do TC001." -Icon ([Windows.Forms.ToolTipIcon]::Info)
            }
        }
        Show-UlanziControlPanel
        return
    }

    $script:configurationState = "ready"
    $script:configurationMessage = "Configuracao pronta."
    $firstRunItem.Visible = $false
    Update-ConfigurationDependentValues
    $restartReason = switch ($reason) {
        "first-run" { "configuration" }
        "recovery" { "recovery" }
        default { "startup" }
    }
    $completionMessage = if ($reason -eq "first-run") {
        "Configuracao concluida. A conexao foi iniciada e sera confirmada automaticamente."
    } else {
        ""
    }
    [void](Request-BridgeRestart `
        -Reason $restartReason `
        -CompletionMessage $completionMessage `
        -ConfirmConfigurationLoad:($reason -eq "first-run"))
    if ($reason -eq "first-run") { Show-UlanziControlPanel }
    if ($null -ne $script:controlPanelController) {
        try { & $script:controlPanelController.Refresh } catch { }
    }
}

function Start-UlanziFirstRunConfiguration {
    if ($script:closing -or $null -ne $script:firstRunProcess) { return $false }
    if ($null -ne $script:configurationCheckOperation) {
        Show-TrayBalloon -Text "Aguarde a verificacao da configuracao terminar." -Icon ([Windows.Forms.ToolTipIcon]::Info)
        return $false
    }

    $script:configurationDialogOpen = $true
    $script:configurationState = "configuring"
    $script:configurationMessage = "O assistente esta aberto. Conclua as etapas ou feche para continuar depois."
    $firstRunItem.Enabled = $false
    $configureItem.Enabled = $false
    $restartItem.Enabled = $false
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powershellExe
        $startInfo.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (ConvertTo-UlanziConfigProcessArgument -Value $firstRunUiScript)
        $startInfo.WorkingDirectory = $projectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $script:firstRunProcess = [Diagnostics.Process]::Start($startInfo)
        $script:firstRunOutputTask = $script:firstRunProcess.StandardOutput.ReadToEndAsync()
        $script:firstRunErrorTask = $script:firstRunProcess.StandardError.ReadToEndAsync()
        if ($null -ne $script:controlPanelController) {
            try { & $script:controlPanelController.Refresh } catch { }
        }
        return $true
    } catch {
        if ($null -ne $script:firstRunProcess) {
            try { $script:firstRunProcess.Dispose() } catch { }
        }
        $script:firstRunProcess = $null
        $script:firstRunOutputTask = $null
        $script:firstRunErrorTask = $null
        $script:configurationDialogOpen = $false
        Set-UlanziConfigurationRequired -Message "Nao foi possivel abrir o assistente. Tente novamente pelo painel."
        Show-TrayBalloon -Text $script:configurationMessage -Icon ([Windows.Forms.ToolTipIcon]::Error)
        return $false
    }
}

function Update-UlanziFirstRunConfiguration {
    if ($null -eq $script:firstRunProcess) { return }
    try {
        if (-not $script:firstRunProcess.HasExited) { return }
        $script:firstRunProcess.WaitForExit()
        if ($null -ne $script:firstRunOutputTask) { [void]$script:firstRunOutputTask.GetAwaiter().GetResult() }
        if ($null -ne $script:firstRunErrorTask) { [void]$script:firstRunErrorTask.GetAwaiter().GetResult() }
    } catch {
        # A validacao dos arquivos abaixo determina o resultado real do assistente.
    } finally {
        try { $script:firstRunProcess.Dispose() } catch { }
        $script:firstRunProcess = $null
        $script:firstRunOutputTask = $null
        $script:firstRunErrorTask = $null
        $script:configurationDialogOpen = $false
    }
    [void](Start-UlanziConfigurationCheck -Reason "first-run")
    if ($null -ne $script:controlPanelController) {
        try { & $script:controlPanelController.Refresh } catch { }
    }
}

function Stop-UlanziFirstRunConfiguration {
    if ($null -eq $script:firstRunProcess) { return }
    try {
        if (-not $script:firstRunProcess.HasExited) { $script:firstRunProcess.Kill() }
    } catch { } finally {
        try { $script:firstRunProcess.Dispose() } catch { }
        $script:firstRunProcess = $null
        $script:firstRunOutputTask = $null
        $script:firstRunErrorTask = $null
        $script:configurationDialogOpen = $false
    }
}

function Start-Bridge {
    if ($script:closing) { return $false }
    if ($script:configurationState -cne "ready") {
        throw "A configuracao precisa estar valida antes de iniciar o bridge."
    }
    if (Test-BridgeRunning) { throw "O bridge anterior ainda esta em execucao." }
    if ($null -ne $script:bridgeProcess) {
        try { $script:bridgeProcess.Dispose() } catch { }
        $script:bridgeProcess = $null
    }

    [void][IO.Directory]::CreateDirectory($runtimePath)
    Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
    $script:bridgeInstanceId = [Guid]::NewGuid().ToString("D")
    if (-not [string]::IsNullOrWhiteSpace([string]$script:pendingConfigApplyInstanceId)) {
        $script:pendingConfigApplyInstanceId = $script:bridgeInstanceId
    }
    $script:bridgeStartedAt = [DateTime]::UtcNow
    $script:lastRuntimeStatus = $null
    $script:lastRuntimeStatusFileStamp = "<invalidated>"
    $script:pendingSoundRequestId = $null
    $script:pendingSoundDeadline = [DateTime]::MinValue
    $testSoundItem.Text = "Testar som"

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powershellExe
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $bridgeScript + '"'
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables["ULANZI_INSTANCE_ID"] = $script:bridgeInstanceId
    $startInfo.EnvironmentVariables["ULANZI_STATUS_FILE"] = $statusPath
    $startInfo.EnvironmentVariables["ULANZI_ALARM_STATE_FILE"] = $alarmStatePath
    $startInfo.EnvironmentVariables["ULANZI_COMMAND_FILE"] = $commandPath
    $startInfo.EnvironmentVariables["ULANZI_STOP_FILE"] = $stopRequestPath
    $script:bridgeProcess = [Diagnostics.Process]::Start($startInfo)
    $script:nextRestart = [DateTime]::UtcNow.AddSeconds(10)
    Set-TrayStatus -Status "iniciando; aguardando status" -Healthy $false
    return $true
}

function Test-BridgeRestartBusy {
    return -not [string]::Equals([string]$script:bridgeRestartPhase, "idle", [StringComparison]::Ordinal)
}

function Get-BridgeRestartText {
    $operation = switch ([string]$script:bridgeRestartReason) {
        "startup" { "iniciando" }
        "recovery" { "recuperando a conexao" }
        "configuration" { "aplicando configuracoes" }
        "restoration" { "aplicando restauracao" }
        default { "reiniciando" }
    }
    switch ([string]$script:bridgeRestartPhase) {
        "stopping" { return "${operation}: encerrando conexao anterior" }
        "forcing-stop" { return "${operation}: finalizando conexao anterior" }
        "starting" { return "${operation}: iniciando nova conexao" }
        "awaiting-status" { return "${operation}: aguardando status da nova conexao" }
        default { return "reinicio nao esta em andamento" }
    }
}

function Clear-ExitedBridgeProcess {
    if ($null -eq $script:bridgeProcess) { return $true }
    try {
        if (-not $script:bridgeProcess.HasExited) { return $false }
    } catch {
        # Se o identificador do processo deixou de ser valido, descarte-o abaixo.
    }
    try { $script:bridgeProcess.Dispose() } catch { }
    $script:bridgeProcess = $null
    $script:bridgeInstanceId = $null
    $script:lastRuntimeStatus = $null
    $script:lastRuntimeStatusFileStamp = "<invalidated>"
    Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
    return $true
}

function Reset-BridgeRestartState {
    if ($null -ne $script:bridgeForcedStopProcess) {
        try {
            if (-not $script:bridgeForcedStopProcess.HasExited) { $script:bridgeForcedStopProcess.Kill() }
        } catch { } finally {
            $script:bridgeForcedStopProcess.Dispose()
            $script:bridgeForcedStopProcess = $null
        }
    }
    $script:bridgeRestartPhase = "idle"
    $script:bridgeRestartDeadline = [DateTime]::MinValue
    $script:bridgeRestartReason = ""
    $script:bridgeRestartCompletionMessage = ""
    $script:bridgeRestartRequiresConfigConfirmation = $false
    $timer.Interval = 2000
}

function Fail-BridgeRestart {
    param([Parameter(Mandatory = $true)][string]$Message)

    Reset-BridgeRestartState
    $script:nextRestart = [DateTime]::UtcNow.AddSeconds(10)
    Set-TrayStatus -Status $Message -Healthy $false
    Show-TrayBalloon -Text $Message -Icon ([Windows.Forms.ToolTipIcon]::Warning)
}

function Request-BridgeRestart {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("startup", "recovery", "manual", "configuration", "restoration")][string]$Reason,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$CompletionMessage = "",
        [Parameter(Mandatory = $false)][bool]$ConfirmConfigurationLoad = $false
    )

    if ($script:closing) { return $false }
    if (Test-BridgeRestartBusy) {
        Show-TrayBalloon -Text "Um reinicio ja esta em andamento: $(Get-BridgeRestartText)." -Icon ([Windows.Forms.ToolTipIcon]::Info)
        return $false
    }

    $script:bridgeRestartReason = $Reason
    $script:bridgeRestartCompletionMessage = $CompletionMessage
    $script:bridgeRestartRequiresConfigConfirmation = $ConfirmConfigurationLoad
    $script:pendingSoundRequestId = $null
    $script:pendingSoundDeadline = [DateTime]::MinValue
    $testSoundItem.Text = "Testar som"
    $script:lastRuntimeStatus = $null
    $script:lastRuntimeStatusFileStamp = "<invalidated>"
    $timer.Interval = 250

    if (Test-BridgeRunning) {
        $script:bridgeRestartPhase = "stopping"
        $script:bridgeRestartDeadline = [DateTime]::UtcNow.AddSeconds(5)
        if (-not [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId)) {
            try {
                Write-StopBridgeRequest -TargetInstanceId $script:bridgeInstanceId
            } catch {
                $script:bridgeRestartDeadline = [DateTime]::UtcNow
            }
        } else {
            $script:bridgeRestartDeadline = [DateTime]::UtcNow
        }
    } else {
        [void](Clear-ExitedBridgeProcess)
        $script:bridgeRestartPhase = "starting"
        $script:bridgeRestartDeadline = [DateTime]::UtcNow.AddSeconds(10)
    }

    $restartItem.Enabled = $false
    $configureItem.Enabled = $false
    $volumeControlItem.Enabled = $false
    $testSoundItem.Enabled = $false
    $diagnosticsItem.Enabled = $false
    $maintenanceItem.Enabled = $false
    Set-TrayStatus -Status (Get-BridgeRestartText) -Healthy $false
    return $true
}

function Start-BridgeForcedStop {
    if ($null -eq $script:bridgeProcess) {
        $script:bridgeRestartPhase = "starting"
        return
    }
    $processId = $script:bridgeProcess.Id
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "$env:SystemRoot\System32\taskkill.exe"
    $startInfo.Arguments = "/PID $processId /T /F"
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $script:bridgeForcedStopProcess = [Diagnostics.Process]::Start($startInfo)
    $script:bridgeRestartPhase = "forcing-stop"
    $script:bridgeRestartDeadline = [DateTime]::UtcNow.AddSeconds(5)
    Set-TrayStatus -Status (Get-BridgeRestartText) -Healthy $false
}

function Update-BridgeRestart {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Status)

    if (-not (Test-BridgeRestartBusy)) { return }
    switch ([string]$script:bridgeRestartPhase) {
        "stopping" {
            if (Clear-ExitedBridgeProcess) {
                $script:bridgeRestartPhase = "starting"
                $script:bridgeRestartDeadline = [DateTime]::UtcNow.AddSeconds(10)
                Set-TrayStatus -Status (Get-BridgeRestartText) -Healthy $false
                return
            }
            if ([DateTime]::UtcNow -ge $script:bridgeRestartDeadline) {
                try {
                    Start-BridgeForcedStop
                } catch {
                    Fail-BridgeRestart -Message "Nao foi possivel encerrar a conexao anterior; ela foi mantida."
                }
            }
            return
        }
        "forcing-stop" {
            if (Clear-ExitedBridgeProcess) {
                if ($null -ne $script:bridgeForcedStopProcess) {
                    try { $script:bridgeForcedStopProcess.Dispose() } catch { }
                    $script:bridgeForcedStopProcess = $null
                }
                $script:bridgeRestartPhase = "starting"
                $script:bridgeRestartDeadline = [DateTime]::UtcNow.AddSeconds(10)
                Set-TrayStatus -Status (Get-BridgeRestartText) -Healthy $false
                return
            }
            if ([DateTime]::UtcNow -ge $script:bridgeRestartDeadline) {
                Fail-BridgeRestart -Message "A conexao anterior nao encerrou dentro do prazo; o reinicio foi cancelado."
            }
            return
        }
        "starting" {
            try {
                [void](Start-Bridge)
                if ($script:bridgeRestartRequiresConfigConfirmation) {
                    $script:pendingConfigApplyInstanceId = $script:bridgeInstanceId
                    $script:pendingConfigApplyDeadline = [DateTime]::UtcNow.AddSeconds(90)
                }
                $script:bridgeRestartPhase = "awaiting-status"
                $script:bridgeRestartDeadline = [DateTime]::UtcNow.AddSeconds(45)
                Set-TrayStatus -Status (Get-BridgeRestartText) -Healthy $false
            } catch {
                Fail-BridgeRestart -Message "A conexao anterior encerrou, mas a nova nao pode ser iniciada."
            }
            return
        }
        "awaiting-status" {
            if ($null -ne $Status) {
                $completionMessage = [string]$script:bridgeRestartCompletionMessage
                Reset-BridgeRestartState
                if (-not [string]::IsNullOrWhiteSpace($completionMessage)) {
                    Show-TrayBalloon -Text $completionMessage -Icon ([Windows.Forms.ToolTipIcon]::Info)
                }
                return
            }
            if (-not (Test-BridgeRunning)) {
                [void](Clear-ExitedBridgeProcess)
                Fail-BridgeRestart -Message "A nova conexao encerrou antes de publicar o primeiro status."
                return
            }
            if ([DateTime]::UtcNow -ge $script:bridgeRestartDeadline) {
                Reset-BridgeRestartState
                Set-TrayStatus -Status "nova conexao iniciada; aguardando status" -Healthy $false
                Show-TrayBalloon -Text "A nova conexao foi iniciada, mas ainda nao publicou um status valido." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
            }
        }
    }
}

function Show-UlanziControlPanel {
    if ($script:closing) { return }
    if ($null -ne $script:controlPanelController) {
        try {
            if (-not $script:controlPanelController.Form.IsDisposed) {
                & $script:controlPanelController.Activate
                return
            }
        } catch {
            $script:controlPanelController = $null
        }
    }

    $openSettings = ({
        param(
            [AllowNull()][Windows.Forms.IWin32Window]$Owner,
            [Parameter(Mandatory = $false)][ValidateSet("alerts", "behavior", "display", "connections", "advanced", "startup")][string]$InitialTab = "alerts"
        )
        $script:preferredConfigurationTab = $InitialTab
        try {
            Invoke-PanelMenuAction -Item $configureItem -Owner $Owner -UnavailableMessage "Conclua a operacao atual antes de editar os ajustes."
        } finally {
            $script:preferredConfigurationTab = "alerts"
        }
    }).GetNewClosure()
    $openVolume = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        Invoke-PanelMenuAction -Item $volumeControlItem -Owner $Owner -UnavailableMessage "O controle do buzzer estara disponivel quando a conexao estiver pronta e nenhum comando de som estiver pendente."
    }).GetNewClosure()
    $requestSoundTest = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        Invoke-PanelMenuAction -Item $testSoundItem -Owner $Owner -UnavailableMessage "O teste de som estara disponivel quando a conexao estiver pronta e nenhum comando de som estiver pendente."
    }).GetNewClosure()
    $openDiagnostics = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        Invoke-PanelMenuAction -Item $diagnosticsItem -Owner $Owner -UnavailableMessage "Conclua a operacao atual antes de executar o teste completo."
    }).GetNewClosure()
    $openMaintenance = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        Invoke-PanelMenuAction -Item $maintenanceItem -Owner $Owner -UnavailableMessage "Conclua a operacao atual antes de abrir a manutencao."
    }).GetNewClosure()
    $openNightscout = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        if ([string]::IsNullOrWhiteSpace([string]$script:nightscoutUrl)) {
            throw "O endereco do Nightscout ainda nao foi configurado."
        }
        $openNightscoutItem.PerformClick()
    }).GetNewClosure()
    $openFolder = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        $openFolderItem.PerformClick()
    }).GetNewClosure()
    $restartBridge = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        Invoke-PanelMenuAction -Item $restartItem -Owner $Owner -UnavailableMessage "Conclua a janela aberta antes de reiniciar a conexao."
    }).GetNewClosure()
    $toggleWidget = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        $toggleWidgetItem.PerformClick()
    }).GetNewClosure()
    $getSetupState = { return Get-UlanziSetupState }
    $startSetup = ({
        param([AllowNull()][Windows.Forms.IWin32Window]$Owner)
        if (-not (Start-UlanziFirstRunConfiguration)) {
            if ($script:configurationState -eq "ready") {
                throw "A configuracao inicial ja foi concluida."
            }
        }
    }).GetNewClosure()
    $readPanelStatus = { return Read-RuntimeStatus }
    $readPanelHealth = {
        param([AllowNull()][object]$RuntimeStatus)
        return Get-BridgeResponsiveness -Status $RuntimeStatus
    }
    $getWidgetVisible = { return ($script:widgetVisible -and $widget.Visible) }
    $panelClosed = {
        $script:preferredDialogOwner = $null
        $script:controlPanelController = $null
    }

    try {
        $script:controlPanelController = New-UlanziControlPanel `
            -ProjectRoot $projectRoot `
            -EnvPath $envPath `
            -ReadStatus $readPanelStatus `
            -BridgeHealth $readPanelHealth `
            -OpenSettings $openSettings `
            -OpenVolume $openVolume `
            -RequestSoundTest $requestSoundTest `
            -OpenDiagnostics $openDiagnostics `
            -OpenMaintenance $openMaintenance `
            -OpenNightscout $openNightscout `
            -OpenFolder $openFolder `
            -RestartBridge $restartBridge `
            -ToggleWidget $toggleWidget `
            -GetWidgetVisible $getWidgetVisible `
            -GetSetupState $getSetupState `
            -StartSetup $startSetup `
            -OnClosed $panelClosed
        $script:controlPanelController.Form.Show()
        $script:controlPanelController.Form.Activate()
    } catch {
        Close-UlanziControlPanel
        throw
    }
}

$testSoundItem.add_Click({
    if ($script:configurationDialogOpen -or $script:volumeDialogOpen -or $script:diagnosticsDialogOpen -or $script:maintenanceDialogOpen) {
        Show-TrayBalloon -Text "Feche a janela aberta antes de testar o som." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)) { return }
    if (-not (Test-BridgeRunning) -or [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId)) {
        Show-TrayBalloon -Text "O bridge precisa estar em execucao para testar o som." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $knownDeviceSound = Get-StatusProperty -Object $script:lastRuntimeStatus -Name "deviceSound"
    $knownDeviceSoundState = [string](Get-StatusProperty -Object $knownDeviceSound -Name "state" -DefaultValue "unknown")
    if ($knownDeviceSoundState -eq "muted" -or $knownDeviceSoundState -eq "silent") {
        Show-TrayBalloon -Text "O buzzer geral do TC001 esta desligado. Abra Ligar ou desligar som antes de testar." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $requestId = [Guid]::NewGuid().ToString("D")
    try {
        Write-RuntimeCommand -Command "test-sound" -RequestId $requestId -TargetInstanceId $script:bridgeInstanceId
        $script:pendingSoundRequestId = $requestId
        $script:pendingSoundDeadline = [DateTime]::UtcNow.AddSeconds($testSoundTimeoutSeconds)
        $testSoundItem.Text = "Testando som..."
        $testSoundItem.Enabled = $false
    } catch {
        Show-TrayBalloon -Text "Nao foi possivel solicitar o teste de som: $($_.Exception.Message)" -Icon ([Windows.Forms.ToolTipIcon]::Error)
    }
})
$volumeControlItem.add_Click({
    if ($script:configurationDialogOpen -or $script:volumeDialogOpen -or $script:diagnosticsDialogOpen -or $script:maintenanceDialogOpen) { return }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)) {
        Show-TrayBalloon -Text "Aguarde o teste de som terminar antes de abrir o controle do buzzer." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    if (-not (Test-BridgeRunning) -or [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId)) {
        Show-TrayBalloon -Text "O bridge precisa estar em execucao para controlar o buzzer." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }

    $script:volumeDialogOpen = $true
    $volumeControlItem.Enabled = $false
    $diagnosticsItem.Enabled = $false
    $maintenanceItem.Enabled = $false
    $configureItem.Enabled = $false
    $testSoundItem.Enabled = $false
    $restartItem.Enabled = $false
    try {
        $sendCommand = {
            param(
                [Parameter(Mandatory = $true)][string]$Command,
                [Parameter(Mandatory = $false)][AllowNull()][object]$Payload = $null
            )

            if (-not (Test-BridgeRunning) -or [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId)) {
                throw "O bridge nao esta em execucao."
            }
            $requestId = [Guid]::NewGuid().ToString("D")
            Write-RuntimeCommand `
                -Command $Command `
                -RequestId $requestId `
                -TargetInstanceId $script:bridgeInstanceId `
                -Payload $Payload
            return $requestId
        }
        $readStatus = { return Read-RuntimeStatus }
        $bridgeRunning = {
            return (
                (Test-BridgeRunning) -and
                -not [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId)
            )
        }
        $dialogOwner = Get-PreferredDialogOwner
        [void](Show-UlanziVolumeDialog `
            -Owner $dialogOwner `
            -SendCommand $sendCommand `
            -ReadStatus $readStatus `
            -BridgeRunning $bridgeRunning `
            -CommandTimeoutSeconds 30 `
            -ProjectRoot $projectRoot)
    } catch {
        Show-TrayBalloon -Text "Nao foi possivel abrir ou usar o controle do buzzer: $($_.Exception.Message)" -Icon ([Windows.Forms.ToolTipIcon]::Error)
    } finally {
        $script:volumeDialogOpen = $false
    }
})
$diagnosticsItem.add_Click({
    if ($script:configurationDialogOpen -or $script:volumeDialogOpen -or $script:diagnosticsDialogOpen -or $script:maintenanceDialogOpen) { return }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)) {
        Show-TrayBalloon -Text "Aguarde o teste de som terminar antes de abrir o diagnostico." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $script:diagnosticsDialogOpen = $true
    $diagnosticsItem.Enabled = $false
    $maintenanceItem.Enabled = $false
    $configureItem.Enabled = $false
    $volumeControlItem.Enabled = $false
    $testSoundItem.Enabled = $false
    $restartItem.Enabled = $false
    try {
        $sendDiagnosticCommand = {
            param([string]$Command, [AllowNull()][object]$Payload = $null)
            if (-not (Test-BridgeRunning) -or [string]::IsNullOrWhiteSpace([string]$script:bridgeInstanceId)) {
                throw "O bridge nao esta em execucao."
            }
            $requestId = [Guid]::NewGuid().ToString("D")
            Write-RuntimeCommand -Command $Command -RequestId $requestId -TargetInstanceId $script:bridgeInstanceId -Payload $Payload
            return $requestId
        }
        $readDiagnosticStatus = { return Read-RuntimeStatus }
        $diagnosticBridgeRunning = { return (Test-BridgeRunning) }
        $diagnosticBridgeHealth = {
            param([AllowNull()][object]$RuntimeStatus)
            return Get-BridgeResponsiveness -Status $RuntimeStatus
        }
        $dialogOwner = Get-PreferredDialogOwner
        Show-UlanziDiagnosticsDialog `
            -Owner $dialogOwner `
            -ReadStatus $readDiagnosticStatus `
            -SendCommand $sendDiagnosticCommand `
            -BridgeRunning $diagnosticBridgeRunning `
            -BridgeHealth $diagnosticBridgeHealth `
            -ProjectRoot $projectRoot `
            -CommandTimeoutSeconds 30
    } catch {
        Show-TrayBalloon -Text "Nao foi possivel abrir o diagnostico: $($_.Exception.Message)" -Icon ([Windows.Forms.ToolTipIcon]::Error)
    } finally {
        $script:diagnosticsDialogOpen = $false
    }
})
$firstRunItem.add_Click({
    if ($script:configurationDialogOpen -or $script:volumeDialogOpen -or $script:diagnosticsDialogOpen -or $script:maintenanceDialogOpen) { return }
    [void](Start-UlanziFirstRunConfiguration)
})
$configureItem.add_Click({
    if ($script:configurationDialogOpen -or $script:volumeDialogOpen -or $script:diagnosticsDialogOpen -or $script:maintenanceDialogOpen) { return }
    if ($script:configurationState -cne "ready") {
        [void](Start-UlanziFirstRunConfiguration)
        return
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)) {
        Show-TrayBalloon -Text "Aguarde o teste de som terminar antes de alterar as configuracoes." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $script:configurationDialogOpen = $true
    $configureItem.Enabled = $false
    $diagnosticsItem.Enabled = $false
    $maintenanceItem.Enabled = $false
    $volumeControlItem.Enabled = $false
    $testSoundItem.Enabled = $false
    $restartItem.Enabled = $false
    try {
        $dialogOwner = Get-PreferredDialogOwner
        $result = Show-UlanziConfigurationDialog -Owner $dialogOwner -ProjectRoot $projectRoot -EnvPath $envPath -InitialTab $script:preferredConfigurationTab
        if ($result.Saved -ne $true) { return }
        if ($result.Changed -ne $true) {
            Show-TrayBalloon -Text "Nenhuma configuracao foi alterada." -Icon ([Windows.Forms.ToolTipIcon]::Info)
            return
        }
        Update-ConfigurationDependentValues
        if ($null -ne $script:controlPanelController) {
            try {
                if (-not $script:controlPanelController.Form.IsDisposed) {
                    & $script:controlPanelController.Refresh
                }
            } catch {
                # O temporizador do painel tentara atualizar novamente sem perder a janela existente.
            }
        }
        $restartRequested = Request-BridgeRestart `
            -Reason "configuration" `
            -ConfirmConfigurationLoad $true
        if ($restartRequested) {
            Show-TrayBalloon -Text "Configuracoes salvas e conferidas. Duracao do toque: $($result.SoundProfileLabel). O reinicio foi solicitado e sera confirmado pelo novo status." -Icon ([Windows.Forms.ToolTipIcon]::Info)
        }
    } catch {
        Show-TrayBalloon -Text "Nao foi possivel abrir ou aplicar as configuracoes: $($_.Exception.Message)" -Icon ([Windows.Forms.ToolTipIcon]::Error)
    } finally {
        $script:configurationDialogOpen = $false
        $configureItem.Enabled = ($script:configurationState -eq "ready" -and -not (Test-BridgeRestartBusy))
        $firstRunItem.Enabled = ($script:configurationState -eq "required" -and -not (Test-BridgeRestartBusy))
    }
})
$maintenanceItem.add_Click({
    if ($script:configurationDialogOpen -or $script:volumeDialogOpen -or $script:diagnosticsDialogOpen -or $script:maintenanceDialogOpen) { return }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)) {
        Show-TrayBalloon -Text "Aguarde o teste de som terminar antes de abrir a manutencao." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $script:maintenanceDialogOpen = $true
    $maintenanceItem.Enabled = $false
    $diagnosticsItem.Enabled = $false
    $configureItem.Enabled = $false
    $volumeControlItem.Enabled = $false
    $testSoundItem.Enabled = $false
    $restartItem.Enabled = $false
    try {
        $dialogOwner = Get-PreferredDialogOwner
        $result = Show-UlanziMaintenanceDialog -Owner $dialogOwner -ProjectRoot $projectRoot
        if ($result.InstallerStarted -eq $true) {
            $script:closing = $true
            $timer.Stop()
            Stop-Bridge
            $notifyIcon.Visible = $false
            [Windows.Forms.Application]::Exit()
            return
        }
        if ($result.ConfigurationRestored -eq $true) {
            $script:pollInterval = Get-EnvValue -Name "POLL_INTERVAL_SECONDS" -DefaultValue "60"
            $script:nightscoutUrl = Get-EnvValue -Name "NIGHTSCOUT_URL" -DefaultValue ""
            if ([string]::IsNullOrWhiteSpace([string]$script:nightscoutUrl)) {
                $openNightscoutItem.Text = "Nightscout nao configurado"
                $openNightscoutItem.Enabled = $false
            } else {
                $openNightscoutItem.Text = "Abrir Nightscout"
                $openNightscoutItem.Enabled = $true
            }
            Update-TrayPreferences
            $intervalItem.Text = "Atualizacao: a cada $script:pollInterval segundos"
            $restartRequested = Request-BridgeRestart `
                -Reason "restoration" `
                -ConfirmConfigurationLoad $true
            if ($restartRequested) {
                Show-TrayBalloon -Text "Configuracao anterior restaurada. O reinicio foi solicitado e sera confirmado pelo novo status." -Icon ([Windows.Forms.ToolTipIcon]::Info)
            }
        }
    } catch {
        Show-TrayBalloon -Text "Nao foi possivel abrir ou usar a manutencao: $($_.Exception.Message)" -Icon ([Windows.Forms.ToolTipIcon]::Error)
    } finally {
        $script:maintenanceDialogOpen = $false
    }
})
$openNightscoutItem.add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:nightscoutUrl)) {
        Start-Process $script:nightscoutUrl
    }
})
$openFolderItem.add_Click({ Start-Process explorer.exe -ArgumentList $projectRoot })
$restartItem.add_Click({
    if ($script:configurationDialogOpen -or $script:volumeDialogOpen -or $script:diagnosticsDialogOpen -or $script:maintenanceDialogOpen) {
        Show-TrayBalloon -Text "Feche a janela aberta antes de reiniciar o bridge." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    if (Request-BridgeRestart -Reason "manual" -CompletionMessage "Conexao reiniciada e confirmada por um novo status.") {
        Show-TrayBalloon -Text "Reinicio solicitado. A conexao anterior sera encerrada antes de uma nova ser iniciada." -Icon ([Windows.Forms.ToolTipIcon]::Info)
    }
})
$toggleWidgetItem.add_Click({
    $script:widgetVisible = -not $script:widgetVisible
    if ($script:widgetVisible) {
        Set-WidgetPosition
        $widget.Show()
        $toggleWidgetItem.Text = "Ocultar mostrador"
    } else {
        $widget.Hide()
        $toggleWidgetItem.Text = "Mostrar mostrador"
    }
})
$panelItem.add_Click({
    try {
        Show-UlanziControlPanel
    } catch {
        Show-TrayBalloon -Text "Nao foi possivel abrir o painel: $($_.Exception.Message)" -Icon ([Windows.Forms.ToolTipIcon]::Error)
    }
})
$exitItem.add_Click({
    if (
        $script:configurationDialogOpen -or
        $script:volumeDialogOpen -or
        $script:diagnosticsDialogOpen -or
        $script:maintenanceDialogOpen
    ) {
        Show-TrayBalloon -Text "Feche a janela aberta antes de encerrar o Ulanzi Libre." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $script:closing = $true
    Close-UlanziControlPanel
    $timer.Stop()
    Stop-Bridge
    $notifyIcon.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$notifyIcon.add_DoubleClick({
    $panelItem.PerformClick()
})
$widget.add_DoubleClick({ $panelItem.PerformClick() })
$glucoseLabel.add_DoubleClick({ $panelItem.PerformClick() })

function Invoke-PendingPanelRequest {
    if (-not [IO.File]::Exists($panelRequestPath)) { return }
    try {
        [IO.File]::Delete($panelRequestPath)
        $panelItem.PerformClick()
    } catch {
        # Uma solicitacao concorrente pode ser repetida pelo atalho.
    }
}

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 2000
$timer.add_Tick({
    if ($script:closing) { return }
    Invoke-PendingPanelRequest
    Update-UlanziFirstRunConfiguration
    Complete-UlanziConfigurationCheck
    $exitItem.Enabled = (
        -not $script:configurationDialogOpen -and
        -not $script:volumeDialogOpen -and
        -not $script:diagnosticsDialogOpen -and
        -not $script:maintenanceDialogOpen
    )
    Set-WidgetPosition
    if ($script:configurationState -cne "ready") {
        $testSoundItem.Enabled = $false
        $volumeControlItem.Enabled = $false
        $configureItem.Enabled = $false
        $restartItem.Enabled = $false
        $firstRunItem.Visible = $true
        $firstRunItem.Enabled = ($script:configurationState -eq "required" -and -not $script:configurationDialogOpen)
        $firstRunItem.Text = if ($script:configurationState -eq "configuring") { "Assistente de configuracao aberto" } else { "Configurar agora..." }
        Set-GlucoseDisplay -Text "CONFIG" -Color "#F4B942"
        $glucoseItem.Text = "Glicemia: aguardando configuracao"
        $setupStatus = switch ([string]$script:configurationState) {
            "checking" { "verificando configuracao" }
            "configuring" { "assistente de configuracao aberto" }
            default { "configuracao necessaria" }
        }
        Set-TrayStatus -Status $setupStatus -Healthy $false
        if ($null -ne $script:applicationIcon) { $notifyIcon.Icon = $script:applicationIcon }
        return
    }
    $firstRunItem.Visible = $false
    $status = Read-RuntimeStatus
    Update-BridgeRestart -Status $status
    $restartBusy = Test-BridgeRestartBusy
    $visibleStatus = if ($restartBusy) { $null } else { $status }
    Update-GlucoseDisplay -Status $visibleStatus
    Update-StatusDetails -Status $visibleStatus
    Update-SoundTestRequest -Status $visibleStatus
    Update-WindowsFallbackNotifications -Status $status
    if (-not $restartBusy -and -not [string]::IsNullOrWhiteSpace([string]$script:pendingConfigApplyInstanceId)) {
        if ($null -ne $status) {
            $script:pendingConfigApplyInstanceId = $null
            $script:pendingConfigApplyDeadline = [DateTime]::MinValue
            Show-TrayBalloon -Text "A nova configuracao foi carregada pelo bridge." -Icon ([Windows.Forms.ToolTipIcon]::Info)
        } elseif ([DateTime]::UtcNow -ge $script:pendingConfigApplyDeadline) {
            $script:pendingConfigApplyInstanceId = $null
            $script:pendingConfigApplyDeadline = [DateTime]::MinValue
            Show-TrayBalloon -Text "As configuracoes foram salvas, mas o bridge ainda nao confirmou que conseguiu carrega-las." -Icon ([Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    $bridgeRunning = Test-BridgeRunning
    $testSoundItem.Enabled = (
        -not $script:configurationDialogOpen -and
        -not $script:volumeDialogOpen -and
        -not $script:diagnosticsDialogOpen -and
        -not $script:maintenanceDialogOpen -and
        -not $restartBusy -and
        $bridgeRunning -and
        [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)
    )
    $configureItem.Enabled = (-not $script:configurationDialogOpen -and -not $script:volumeDialogOpen -and -not $script:diagnosticsDialogOpen -and -not $script:maintenanceDialogOpen -and -not $restartBusy)
    $volumeControlItem.Enabled = (
        -not $script:configurationDialogOpen -and
        -not $script:volumeDialogOpen -and
        -not $script:diagnosticsDialogOpen -and
        -not $script:maintenanceDialogOpen -and
        -not $restartBusy -and
        $bridgeRunning -and
        [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)
    )
    $diagnosticsItem.Enabled = (
        -not $script:configurationDialogOpen -and
        -not $script:volumeDialogOpen -and
        -not $script:diagnosticsDialogOpen -and
        -not $script:maintenanceDialogOpen -and
        -not $restartBusy -and
        [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)
    )
    $maintenanceItem.Enabled = (-not $script:configurationDialogOpen -and -not $script:volumeDialogOpen -and -not $script:diagnosticsDialogOpen -and -not $script:maintenanceDialogOpen -and -not $restartBusy -and [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId))
    $restartItem.Enabled = (-not $script:configurationDialogOpen -and -not $script:volumeDialogOpen -and -not $script:diagnosticsDialogOpen -and -not $script:maintenanceDialogOpen -and -not $restartBusy)
    if ($restartBusy) {
        Set-TrayStatus -Status (Get-BridgeRestartText) -Healthy $false
        return
    }
    if ($bridgeRunning) {
        $overall = Get-OverallTrayStatus -Status $status
        Set-TrayStatus -Status ([string]$overall.Text) -Healthy ([bool]$overall.Healthy)
        return
    }
    $testSoundItem.Enabled = $false
    $volumeControlItem.Enabled = $false
    $diagnosticsItem.Enabled = (
        -not $script:configurationDialogOpen -and
        -not $script:volumeDialogOpen -and
        -not $script:diagnosticsDialogOpen -and
        -not $script:maintenanceDialogOpen -and
        [string]::IsNullOrWhiteSpace([string]$script:pendingSoundRequestId)
    )
    Set-TrayStatus -Status "parado; aguardando verificacao para reconectar" -Healthy $false
    if ([DateTime]::UtcNow -ge $script:nextRestart) {
        [void](Start-UlanziConfigurationCheck -Reason "recovery")
    }
})

try {
    try {
        $ownsTrayMutex = $trayMutex.WaitOne(0, $false)
    } catch [Threading.AbandonedMutexException] {
        $ownsTrayMutex = $true
    }
    if (-not $ownsTrayMutex) {
        if ($OpenPanel) {
            try {
                [void][IO.Directory]::CreateDirectory($runtimePath)
                [IO.File]::WriteAllText(
                    $panelRequestPath,
                    [Guid]::NewGuid().ToString("D"),
                    [Text.UTF8Encoding]::new($false)
                )
            } catch {
                # A instancia principal continua segura; o usuario ainda pode usar o icone da bandeja.
            }
        }
        exit 0
    }

    Set-WidgetPosition
    $widget.Show()
    $notifyIcon.BalloonTipTitle = "Ulanzi Libre"
    $timer.Start()
    [void](Start-UlanziConfigurationCheck -Reason "startup")
    if ($OpenPanel) { $panelItem.PerformClick() }
    [Windows.Forms.Application]::Run()
} finally {
    $script:closing = $true
    if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
    if ($null -ne $script:configurationCheckOperation) {
        Stop-UlanziConfigEditorOperation -Operation $script:configurationCheckOperation
        $script:configurationCheckOperation = $null
    }
    Stop-UlanziFirstRunConfiguration
    Close-UlanziControlPanel
    Stop-Bridge
    if ($null -ne $widget) { $widget.Close(); $widget.Dispose() }
    if ($null -ne $notifyIcon) { $notifyIcon.Visible = $false; $notifyIcon.Dispose() }
    if ($null -ne $script:dynamicIcon) { $script:dynamicIcon.Dispose() }
    if ($null -ne $menu) { $menu.Dispose() }
    Clear-UlanziUiApplicationIconCache
    if ($ownsTrayMutex) { $trayMutex.ReleaseMutex() }
    $trayMutex.Dispose()
}
