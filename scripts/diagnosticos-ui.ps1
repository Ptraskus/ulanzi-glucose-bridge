Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ui-language.ps1")

function ConvertTo-UlanziDiagnosticsProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.IndexOf('"') -ge 0 -or $Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
        throw (Get-UlanziText -Key 'Um caminho local contem caracteres que nao podem ser usados com seguranca.')
    }
    return '"' + $Value + '"'
}

function Start-UlanziDiagnosticsExport {
    param(
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $arguments = @(
        (ConvertTo-UlanziDiagnosticsProcessArgument $ScriptPath),
        (ConvertTo-UlanziDiagnosticsProcessArgument $ProjectRoot),
        (ConvertTo-UlanziDiagnosticsProcessArgument $DestinationPath)
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $NodePath
    $startInfo.Arguments = $arguments -join " "
    $startInfo.WorkingDirectory = $ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $process | Add-Member -MemberType NoteProperty -Name UlanziStandardOutputTask -Value $standardOutputTask
    $process | Add-Member -MemberType NoteProperty -Name UlanziStandardErrorTask -Value $standardErrorTask
    return $process
}

function Complete-UlanziDiagnosticsExport {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    if (-not $Process.HasExited) { throw (Get-UlanziText -Key 'A exportacao de diagnostico ainda nao terminou.') }
    $Process.WaitForExit()
    $standardOutput = $Process.UlanziStandardOutputTask.GetAwaiter().GetResult()
    $standardError = $Process.UlanziStandardErrorTask.GetAwaiter().GetResult()
    $payload = $null
    foreach ($candidate in @($standardOutput, $standardError)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $payload = $candidate.Trim() | ConvertFrom-Json -ErrorAction Stop
            break
        } catch { }
    }
    if ($Process.ExitCode -ne 0 -or $null -eq $payload -or $payload.ok -ne $true) {
        $safeMessage = if ($null -ne $payload -and -not [string]::IsNullOrWhiteSpace([string]$payload.message)) {
            [string]$payload.message
        } else {
            (Get-UlanziText -Key 'A exportacao local nao foi concluida.')
        }
        throw $safeMessage
    }
    return $payload
}

function Show-UlanziDiagnosticsDialog {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory = $true)][scriptblock]$ReadStatus,
        [Parameter(Mandatory = $true)][scriptblock]$SendCommand,
        [Parameter(Mandatory = $true)][scriptblock]$BridgeRunning,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$BridgeHealth = $null,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $false)][ValidateRange(10, 120)][int]$CommandTimeoutSeconds = 30
    )

    $Owner = Get-UlanziUsableDialogOwner -Owner $Owner

    $getProperty = {
        param([AllowNull()][object]$Object, [string]$Name, [AllowNull()][object]$DefaultValue = $null)
        if ($null -eq $Object) { return $DefaultValue }
        if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $DefaultValue }
        return $property.Value
    }

    $getBridgeHealth = {
        param([AllowNull()][object]$RuntimeStatus)
        if ($null -eq $BridgeHealth) {
            $running = ((& $BridgeRunning) -eq $true)
            return [pscustomobject]@{
                Responsive = ($running -and $null -ne $RuntimeStatus)
                Text = if ($running) { (Get-UlanziText -Key 'aguardando status recente') } else { (Get-UlanziText -Key 'aplicativo parado') }
            }
        }
        try {
            $result = & $BridgeHealth $RuntimeStatus
            return [pscustomobject]@{
                Responsive = ((& $getProperty $result "Responsive" $false) -eq $true)
                Text = [string](& $getProperty $result "Text" (Get-UlanziText -Key 'aplicativo sem resposta'))
            }
        } catch {
            return [pscustomobject]@{ Responsive = $false; Text = (Get-UlanziText -Key 'nao foi possivel confirmar o aplicativo') }
        }
    }

    $form = [Windows.Forms.Form]::new()
    $form.Text = (Get-UlanziText -Key 'Verificar tudo - Ulanzi Glucose')
    $form.ClientSize = [Drawing.Size]::new(660, 525)
    $form.MinimumSize = [Drawing.Size]::new(660, 525)
    $form.StartPosition = if ($null -ne $Owner) { [Windows.Forms.FormStartPosition]::CenterParent } else { [Windows.Forms.FormStartPosition]::CenterScreen }
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::Sizable
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = ($null -eq $Owner)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = [Drawing.Font]::new("Segoe UI", 9)
    $form.BackColor = [Drawing.ColorTranslator]::FromHtml("#F5F7F8")
    $form.Tag = "Window"
    $setIconCommand = Get-Command Set-UlanziUiApplicationIcon -ErrorAction SilentlyContinue
    if ($null -ne $setIconCommand) {
        [void](& $setIconCommand -Form $form -ProjectRoot $ProjectRoot)
    }

    $header = [Windows.Forms.Panel]::new()
    $header.Dock = [Windows.Forms.DockStyle]::Top
    $header.Height = 78
    $header.BackColor = [Drawing.ColorTranslator]::FromHtml("#173A4D")
    $header.Tag = "Header"
    $title = [Windows.Forms.Label]::new()
    $title.Text = (Get-UlanziText -Key 'Verificar tudo')
    $title.AutoSize = $true
    $title.Location = [Drawing.Point]::new(20, 12)
    $title.Font = [Drawing.Font]::new("Segoe UI", 17, [Drawing.FontStyle]::Bold)
    $title.ForeColor = [Drawing.Color]::White
    $title.Tag = "Text"
    $subtitle = [Windows.Forms.Label]::new()
    $subtitle.Text = (Get-UlanziText -Key 'Confirme cada elo sem incluir glicemia ou credenciais no relatorio.')
    $subtitle.AutoSize = $true
    $subtitle.Location = [Drawing.Point]::new(22, 48)
    $subtitle.ForeColor = [Drawing.ColorTranslator]::FromHtml("#D4E7EF")
    $subtitle.Tag = "HeaderMuted"
    $header.Controls.Add($title)
    $header.Controls.Add($subtitle)

    $table = [Windows.Forms.TableLayoutPanel]::new()
    $table.Location = [Drawing.Point]::new(20, 94)
    $table.Size = [Drawing.Size]::new(620, 270)
    $table.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $table.BackColor = [Drawing.Color]::White
    $table.Tag = "Elevated"
    $table.Padding = [Windows.Forms.Padding]::new(10)
    $table.ColumnCount = 2
    $table.RowCount = 6
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 190))
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))

    $checkLabels = @{}
    $rows = @(
        @("bridge", (Get-UlanziText -Key 'Aplicativo')),
        @("source", (Get-UlanziText -Key 'Fonte de glicemia')),
        @("reading", (Get-UlanziText -Key 'Leitura recente')),
        @("clock", (Get-UlanziText -Key 'Horario')),
        @("tc001", (Get-UlanziText -Key 'TC001 e visor')),
        @("sound", (Get-UlanziText -Key 'Buzzer e aviso audivel'))
    )
    for ($index = 0; $index -lt $rows.Count; $index++) {
        [void]$table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, (100 / $rows.Count)))
        $name = [Windows.Forms.Label]::new()
        $name.Text = [string]$rows[$index][1]
        $name.Dock = [Windows.Forms.DockStyle]::Fill
        $name.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $name.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
        $name.Tag = "Text"
        $value = [Windows.Forms.Label]::new()
        $value.Text = (Get-UlanziText -Key 'Aguardando...')
        $value.Dock = [Windows.Forms.DockStyle]::Fill
        $value.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $value.AutoEllipsis = $true
        $value.AccessibleName = (Get-UlanziText -Key 'Estado de {0}' -Arguments @(($([string]$rows[$index][1]))))
        $value.AccessibleDescription = (Get-UlanziText -Key 'Aguardando verificacao.')
        $value.Tag = "Muted"
        [void]$table.Controls.Add($name, 0, $index)
        [void]$table.Controls.Add($value, 1, $index)
        $checkLabels[[string]$rows[$index][0]] = $value
    }

    $statusLabel = [Windows.Forms.Label]::new()
    $statusLabel.Text = (Get-UlanziText -Key 'Clique em Verificar tudo para executar tambem os testes do volume e do som.')
    $statusLabel.Location = [Drawing.Point]::new(22, 377)
    $statusLabel.Size = [Drawing.Size]::new(616, 42)
    $statusLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $statusLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $statusLabel.Tag = "Muted"

    $progressBar = [Windows.Forms.ProgressBar]::new()
    $progressBar.Location = [Drawing.Point]::new(22, 428)
    $progressBar.Size = [Drawing.Size]::new(616, 9)
    $progressBar.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Style = [Windows.Forms.ProgressBarStyle]::Continuous
    $progressBar.Value = 0
    $progressBar.Visible = $false
    $progressBar.AccessibleName = (Get-UlanziText -Key 'Progresso do diagnostico')
    $progressBar.AccessibleDescription = (Get-UlanziText -Key 'Nenhuma verificacao em andamento.')

    $footer = [Windows.Forms.Panel]::new()
    $footer.Dock = [Windows.Forms.DockStyle]::Bottom
    # A largura precisa existir antes dos controles ancorados a direita.
    $footer.Size = [Drawing.Size]::new($form.ClientSize.Width, 70)
    $footer.BackColor = [Drawing.Color]::White
    $footer.Tag = "Surface"
    $verifyButton = [Windows.Forms.Button]::new()
    $verifyButton.Text = (Get-UlanziText -Key 'Verificar tudo')
    $verifyButton.Size = [Drawing.Size]::new(112, 34)
    $verifyButton.Location = [Drawing.Point]::new(16, 18)
    $verifyButton.BackColor = [Drawing.ColorTranslator]::FromHtml("#167A91")
    $verifyButton.ForeColor = [Drawing.Color]::White
    $verifyButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $verifyButton.FlatAppearance.BorderSize = 0
    $verifyButton.Tag = "Accent"
    $exportButton = [Windows.Forms.Button]::new()
    $exportButton.Text = (Get-UlanziText -Key 'Exportar diagnostico')
    $exportButton.Size = [Drawing.Size]::new(142, 34)
    $exportButton.Location = [Drawing.Point]::new(138, 18)
    $exportButton.Tag = "Surface"
    $copyButton = [Windows.Forms.Button]::new()
    $copyButton.Text = (Get-UlanziText -Key 'Copiar resumo')
    $copyButton.Size = [Drawing.Size]::new(112, 34)
    $copyButton.Location = [Drawing.Point]::new(290, 18)
    $copyButton.Tag = "Surface"
    $closeButton = [Windows.Forms.Button]::new()
    $closeButton.Text = (Get-UlanziText -Key 'Fechar')
    $closeButton.Size = [Drawing.Size]::new(88, 34)
    $closeButton.Location = [Drawing.Point]::new(552, 18)
    $closeButton.Anchor = [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
    $closeButton.Tag = "Surface"
    $footer.Controls.Add($verifyButton)
    $footer.Controls.Add($exportButton)
    $footer.Controls.Add($copyButton)
    $footer.Controls.Add($closeButton)

    $form.Controls.Add($statusLabel)
    $form.Controls.Add($progressBar)
    $form.Controls.Add($table)
    $form.Controls.Add($footer)
    $form.Controls.Add($header)
    $form.CancelButton = $closeButton

    $state = [pscustomobject]@{
        Closing = $false
        PendingRequestId = $null
        PendingCommand = $null
        PendingDeadline = [DateTime]::MinValue
        PendingExportProcess = $null
        PendingExportPath = $null
        PendingExportDeadline = [DateTime]::MinValue
        RunAll = $false
        SoundAccepted = $false
        SoundHeard = $null
        DisplaySeen = $null
        LastStatus = $null
        BridgeResponsive = $false
    }

    # A paleta e resolvida uma unica vez ao abrir; atualizacoes de status apenas
    # reaplicam o papel semantico e nao consultam tema/registro a cada timer.
    $uiPalette = $null
    $setUiRoleCommand = Get-Command Set-UlanziUiControlRole -ErrorAction SilentlyContinue
    $setSemanticRole = {
        param(
            [Parameter(Mandatory = $true)][Windows.Forms.Control]$Control,
            [ValidateSet("Muted", "Success", "Warning", "Error")][string]$Role
        )
        $Control.Tag = "Semantic=$Role"
        if ($null -ne $uiPalette -and $null -ne $setUiRoleCommand) {
            & $setUiRoleCommand -Control $Control -Palette $uiPalette -Role $Role
            return
        }
        $fallbackColor = switch ($Role) {
            "Success" { [Drawing.ColorTranslator]::FromHtml("#16733D") }
            "Warning" { [Drawing.ColorTranslator]::FromHtml("#8A5A00") }
            "Error" { [Drawing.Color]::Firebrick }
            default { [Drawing.ColorTranslator]::FromHtml("#1D5D7A") }
        }
        $Control.ForeColor = $fallbackColor
    }

    $setCheck = {
        param([string]$Key, [string]$Text, [ValidateSet("ok", "warning", "error", "waiting")][string]$Level)
        $label = $checkLabels[$Key]
        $levelText = switch ($Level) {
            "ok" { "OK" }
            "warning" { (Get-UlanziText -Key 'ATENCAO') }
            "error" { (Get-UlanziText -Key 'PROBLEMA') }
            default { (Get-UlanziText -Key 'AGUARDANDO') }
        }
        $displayText = "$levelText - $Text"
        $semanticRole = switch ($Level) {
            "ok" { "Success" }
            "warning" { "Warning" }
            "error" { "Error" }
            default { "Muted" }
        }
        if ($label.Text -cne $displayText) { $label.Text = $displayText }
        & $setSemanticRole $label $semanticRole
        $label.AccessibleDescription = "$levelText. $Text"
    }

    $setProgress = {
        param(
            [bool]$Visible,
            [ValidateSet("determinate", "indeterminate")][string]$Mode = "determinate",
            [ValidateRange(0, 100)][int]$Value = 0,
            [string]$Description = ""
        )
        if (-not $Visible) {
            $progressBar.Visible = $false
            $progressBar.Style = [Windows.Forms.ProgressBarStyle]::Continuous
            $progressBar.Value = 0
            $progressBar.AccessibleDescription = if ([string]::IsNullOrWhiteSpace($Description)) { (Get-UlanziText -Key 'Nenhuma verificacao em andamento.') } else { $Description }
            return
        }
        $progressBar.Style = if ($Mode -eq "indeterminate") {
            [Windows.Forms.ProgressBarStyle]::Marquee
        } else {
            [Windows.Forms.ProgressBarStyle]::Continuous
        }
        $progressBar.MarqueeAnimationSpeed = if ($Mode -eq "indeterminate") { 24 } else { 0 }
        if ($Mode -eq "determinate") { $progressBar.Value = $Value }
        $progressBar.AccessibleDescription = $Description
        $progressBar.Visible = $true
    }

    $setOperationBusy = {
        param([bool]$Busy)
        if ($Busy) {
            $verifyButton.Enabled = $false
        } else {
            $verifyButton.Enabled = [bool]$state.BridgeResponsive
        }
        $exportButton.Enabled = -not $Busy
        $closeButton.Enabled = -not $Busy
        $form.UseWaitCursor = $Busy
    }

    $updateFromStatus = {
        param([AllowNull()][object]$RuntimeStatus)
        $state.LastStatus = $RuntimeStatus
        $bridgeHealthResult = & $getBridgeHealth $RuntimeStatus
        $state.BridgeResponsive = [bool]$bridgeHealthResult.Responsive
        if (-not [bool]$bridgeHealthResult.Responsive) {
            & $setCheck "bridge" ([string]$bridgeHealthResult.Text) "error"
            foreach ($key in @("source", "reading", "clock", "tc001", "sound")) { & $setCheck $key (Get-UlanziText -Key 'Nao foi possivel verificar') "waiting" }
            if ([string]::IsNullOrWhiteSpace([string]$state.PendingRequestId)) { $verifyButton.Enabled = $false }
            return
        }
        & $setCheck "bridge" (Get-UlanziText -Key 'Em execucao e publicando status') "ok"
        $source = & $getProperty $RuntimeStatus "source" $null
        $sourceState = [string](& $getProperty $source "state" "waiting")
        if ($sourceState -eq "connected") { & $setCheck "source" (Get-UlanziText -Key 'Conexao confirmada') "ok" }
        elseif ($sourceState -eq "error") { & $setCheck "source" ([string](& $getProperty $source "lastError" (Get-UlanziText -Key 'Falha de conexao'))) "error" }
        else { & $setCheck "source" (Get-UlanziText -Key 'Consulta em andamento') "waiting" }

        $reading = & $getProperty $RuntimeStatus "reading" $null
        $readingTimestamp = & $getProperty $reading "timestamp" $null
        $expiresAt = $null
        try { $expiresAt = [DateTime]::Parse([string](& $getProperty $reading "expiresAt" "")).ToUniversalTime() } catch { }
        if ($null -ne $readingTimestamp -and $null -ne $expiresAt -and [DateTime]::UtcNow -lt $expiresAt) { & $setCheck "reading" (Get-UlanziText -Key 'Leitura valida e dentro do prazo') "ok" }
        else { & $setCheck "reading" (Get-UlanziText -Key 'Sem leitura recente') "error" }

        $clock = & $getProperty $RuntimeStatus "clock" $null
        $clockState = [string](& $getProperty $clock "state" "unknown")
        if ($clockState -eq "ok") { & $setCheck "clock" (Get-UlanziText -Key 'Horario coerente com a fonte') "ok" }
        elseif ($clockState -in @("warning", "error")) { & $setCheck "clock" ([string](& $getProperty $clock "message" (Get-UlanziText -Key 'Diferenca de horario detectada'))) "error" }
        else { & $setCheck "clock" (Get-UlanziText -Key 'Aguardando leitura para comparar') "waiting" }

        $tc001 = & $getProperty $RuntimeStatus "tc001" $null
        $tc001State = [string](& $getProperty $tc001 "state" "waiting")
        if ($tc001State -eq "confirmed" -and $state.DisplaySeen -eq $true) { & $setCheck "tc001" (Get-UlanziText -Key 'Envio confirmado e visor conferido por voce') "ok" }
        elseif ($tc001State -eq "confirmed" -and $state.DisplaySeen -eq $false) { & $setCheck "tc001" (Get-UlanziText -Key 'O comando foi aceito, mas o visor nao foi confirmado') "error" }
        elseif ($tc001State -eq "confirmed") { & $setCheck "tc001" (Get-UlanziText -Key 'Envio aceito; falta confirmar visualmente') "warning" }
        elseif ($tc001State -eq "error") { & $setCheck "tc001" ([string](& $getProperty $tc001 "lastError" (Get-UlanziText -Key 'Falha no TC001'))) "error" }
        else { & $setCheck "tc001" (Get-UlanziText -Key 'Aguardando envio') "waiting" }

        $deviceSound = & $getProperty $RuntimeStatus "deviceSound" $null
        $deviceState = [string](& $getProperty $deviceSound "state" "unknown")
        $volume = & $getProperty $deviceSound "buzzerVolume" $null
        if ($state.SoundHeard -eq $true) { & $setCheck "sound" (Get-UlanziText -Key 'Melodia ouvida; nivel tecnico informado {0}%' -Arguments @(($volume))) "ok" }
        elseif ($state.SoundHeard -eq $false) { & $setCheck "sound" (Get-UlanziText -Key 'Comando aceito, mas a melodia nao foi ouvida') "error" }
        elseif ($deviceState -eq "confirmed") { & $setCheck "sound" (Get-UlanziText -Key 'Buzzer ligado; falta o teste auditivo') "warning" }
        elseif ($deviceState -eq "muted" -or $deviceState -eq "silent") { & $setCheck "sound" (Get-UlanziText -Key 'Som geral desligado ou em 0%') "error" }
        elseif ($deviceState -eq "unsupported") { & $setCheck "sound" (Get-UlanziText -Key 'Controle seguro indisponivel neste firmware') "warning" }
        elseif ($deviceState -eq "error") { & $setCheck "sound" ([string](& $getProperty $deviceSound "lastRequestError" (Get-UlanziText -Key 'Falha ao consultar o som'))) "error" }
        else { & $setCheck "sound" (Get-UlanziText -Key 'Buzzer ainda nao consultado') "waiting" }
    }

    $startCommand = {
        param([string]$Command)
        if (-not [string]::IsNullOrWhiteSpace([string]$state.PendingRequestId)) { return $false }
        if (-not [bool]$state.BridgeResponsive) { throw (Get-UlanziText -Key 'O bridge esta parado ou sem resposta.') }
        $requestResult = & $SendCommand $Command ([ordered]@{})
        $requestId = if ($requestResult -is [string]) { [string]$requestResult } else { [string](& $getProperty $requestResult "requestId" "") }
        if ([string]::IsNullOrWhiteSpace($requestId)) { throw (Get-UlanziText -Key 'O bridge nao forneceu um identificador para o teste.') }
        $state.PendingRequestId = $requestId
        $state.PendingCommand = $Command
        $state.PendingDeadline = [DateTime]::UtcNow.AddSeconds($CommandTimeoutSeconds)
        $timer.Interval = 250
        & $setOperationBusy $true
        return $true
    }

    $finishRunAll = {
        if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        & $setProgress $true "determinate" 85 (Get-UlanziText -Key 'Confirmando o que apareceu no visor do TC001.')
        $runtimeStatus = & $ReadStatus
        & $updateFromStatus $runtimeStatus
        $displayAnswer = Show-UlanziOwnedMessageBox `
            -Owner $form `
            -Text (Get-UlanziText -Key 'O TC001 esta mostrando a leitura atual do Ulanzi Glucose?') `
            -Caption (Get-UlanziText -Key 'Confirmar visor') `
            -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
            -Icon ([Windows.Forms.MessageBoxIcon]::Question)
        if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        $state.DisplaySeen = $displayAnswer -eq [Windows.Forms.DialogResult]::Yes
        & $updateFromStatus $runtimeStatus
        $state.RunAll = $false
        $statusLabel.Text = (Get-UlanziText -Key 'Verificacao concluida. Itens marcados como PROBLEMA precisam de atencao; o relatorio pode ser exportado sem dados sensiveis.')
        & $setSemanticRole $statusLabel "Muted"
        $timer.Interval = 1000
        & $setProgress $false "determinate" 100 (Get-UlanziText -Key 'Verificacao concluida.')
        & $setOperationBusy $false
    }

    $verifyButton.add_Click({
        try {
            $state.RunAll = $true
            $state.SoundAccepted = $false
            $state.SoundHeard = $null
            $state.DisplaySeen = $null
            & $setOperationBusy $true
            & $setProgress $true "determinate" 15 (Get-UlanziText -Key 'Lendo o estado atual do aplicativo e do TC001.')
            & $updateFromStatus (& $ReadStatus)
            $statusLabel.Text = (Get-UlanziText -Key 'Consultando o estado real do buzzer do TC001...')
            & $setSemanticRole $statusLabel "Muted"
            [void](& $startCommand "read-device-sound")
            & $setProgress $true "determinate" 35 (Get-UlanziText -Key 'Aguardando a resposta do buzzer do TC001.')
        } catch {
            $state.RunAll = $false
            $state.PendingRequestId = $null
            $state.PendingCommand = $null
            $state.PendingDeadline = [DateTime]::MinValue
            $timer.Interval = 1000
            & $setProgress $false "determinate" 0 (Get-UlanziText -Key 'A verificacao nao pode ser iniciada.')
            & $setOperationBusy $false
            $statusLabel.Text = (Get-UlanziText -Key 'Nao foi possivel iniciar: {0}' -Arguments @(($($_.Exception.Message))))
            & $setSemanticRole $statusLabel "Error"
        }
    })

    $copyButton.add_Click({
        $lines = foreach ($row in $rows) { "$($row[1]): $($checkLabels[[string]$row[0]].Text)" }
        [Windows.Forms.Clipboard]::SetText(($lines -join [Environment]::NewLine))
        $statusLabel.Text = (Get-UlanziText -Key 'Resumo copiado sem valor de glicemia ou credenciais.')
        & $setSemanticRole $statusLabel "Success"
    })

    $exportButton.add_Click({
        $dialog = [Windows.Forms.SaveFileDialog]::new()
        $dialog.Title = (Get-UlanziText -Key 'Salvar diagnostico higienizado')
        $dialog.Filter = (Get-UlanziText -Key 'Relatorio JSON (*.json)|*.json')
        $dialog.FileName = "ulanzi-glucose-diagnostico-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).json"
        try {
            if ($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
            $node = Get-Command node -ErrorAction Stop
            $scriptPath = Join-Path $ProjectRoot "src\support-diagnostics-cli.mjs"
            $destinationPath = [string]$dialog.FileName
            $state.PendingExportProcess = Start-UlanziDiagnosticsExport `
                -NodePath $node.Source `
                -ScriptPath $scriptPath `
                -ProjectRoot $ProjectRoot `
                -DestinationPath $destinationPath
            $state.PendingExportPath = $destinationPath
            $state.PendingExportDeadline = [DateTime]::UtcNow.AddSeconds(30)
            $timer.Interval = 250
            & $setOperationBusy $true
            & $setProgress $true "indeterminate" 0 (Get-UlanziText -Key 'Coletando e higienizando o diagnostico local.')
            $statusLabel.Text = (Get-UlanziText -Key 'Coletando e higienizando o diagnostico, sem glicemia nem credenciais...')
            & $setSemanticRole $statusLabel "Muted"
        } catch {
            $state.PendingExportProcess = $null
            $state.PendingExportPath = $null
            $state.PendingExportDeadline = [DateTime]::MinValue
            $timer.Interval = 1000
            & $setProgress $false "determinate" 0 (Get-UlanziText -Key 'A exportacao nao pode ser iniciada.')
            & $setOperationBusy $false
            $statusLabel.Text = (Get-UlanziText -Key 'Nao foi possivel exportar: {0}' -Arguments @(($($_.Exception.Message))))
            & $setSemanticRole $statusLabel "Error"
        } finally {
            $dialog.Dispose()
        }
    })

    $closeButton.add_Click({ $form.Close() })
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 1000
    $timer.add_Tick({
        if ($state.Closing) { return }
        if ($null -ne $state.PendingExportProcess) {
            $exportProcess = $state.PendingExportProcess
            if (-not $exportProcess.HasExited) {
                if ([DateTime]::UtcNow -ge $state.PendingExportDeadline) {
                    try { $exportProcess.Kill() } catch { }
                    $state.PendingExportProcess = $null
                    $state.PendingExportPath = $null
                    $state.PendingExportDeadline = [DateTime]::MinValue
                    $exportProcess.Dispose()
                    $timer.Interval = 1000
                    & $setProgress $false "determinate" 0 (Get-UlanziText -Key 'A exportacao excedeu o tempo limite.')
                    & $setOperationBusy $false
                    $statusLabel.Text = (Get-UlanziText -Key 'A exportacao excedeu o tempo limite de 30 segundos. Tente novamente.')
                    & $setSemanticRole $statusLabel "Error"
                }
                return
            }
            $destinationPath = [string]$state.PendingExportPath
            $state.PendingExportProcess = $null
            $state.PendingExportPath = $null
            $state.PendingExportDeadline = [DateTime]::MinValue
            try {
                [void](Complete-UlanziDiagnosticsExport -Process $exportProcess)
                $statusLabel.Text = (Get-UlanziText -Key 'Diagnostico salvo em {0}.' -Arguments @(($destinationPath)))
                & $setSemanticRole $statusLabel "Success"
                & $setProgress $false "determinate" 100 (Get-UlanziText -Key 'Exportacao concluida.')
            } catch {
                $statusLabel.Text = (Get-UlanziText -Key 'Nao foi possivel exportar: {0}' -Arguments @(($($_.Exception.Message))))
                & $setSemanticRole $statusLabel "Error"
                & $setProgress $false "determinate" 0 (Get-UlanziText -Key 'A exportacao falhou.')
            } finally {
                $exportProcess.Dispose()
                $timer.Interval = 1000
                & $setOperationBusy $false
            }
            return
        }
        $runtimeStatus = & $ReadStatus
        & $updateFromStatus $runtimeStatus
        if ([string]::IsNullOrWhiteSpace([string]$state.PendingRequestId)) {
            $bridgeIsResponsive = [bool]$state.BridgeResponsive
            $verifyButton.Enabled = $bridgeIsResponsive
            if ($bridgeIsResponsive -and $statusLabel.Text.StartsWith((Get-UlanziText -Key 'O aplicativo esta parado ou sem resposta'))) {
                $statusLabel.Text = (Get-UlanziText -Key 'O aplicativo voltou a funcionar. Clique em Verificar tudo para executar os testes.')
                & $setSemanticRole $statusLabel "Success"
            } elseif (-not $bridgeIsResponsive) {
                $statusLabel.Text = (Get-UlanziText -Key 'O aplicativo esta parado ou sem resposta. Voce ainda pode copiar o resumo ou exportar o diagnostico.')
                & $setSemanticRole $statusLabel "Error"
            }
            return
        }
        $requestId = ""
        $requestState = ""
        $requestError = ""
        if ($state.PendingCommand -eq "test-sound") {
            $sound = & $getProperty $runtimeStatus "sound" $null
            $requestId = [string](& $getProperty $sound "lastTestRequestId" "")
            $requestState = [string](& $getProperty $sound "lastTestState" "")
            $requestError = [string](& $getProperty $sound "lastTestError" "")
        } else {
            $deviceSound = & $getProperty $runtimeStatus "deviceSound" $null
            $requestId = [string](& $getProperty $deviceSound "lastRequestId" "")
            $requestState = [string](& $getProperty $deviceSound "lastRequestState" "")
            $requestError = [string](& $getProperty $deviceSound "lastRequestError" "")
        }
        if ($requestId -ceq [string]$state.PendingRequestId -and $requestState -in @("confirmed", "unsupported", "error")) {
            $completedCommand = [string]$state.PendingCommand
            $state.PendingRequestId = $null
            $state.PendingCommand = $null
            $state.PendingDeadline = [DateTime]::MinValue
            if ($completedCommand -eq "read-device-sound") {
                $deviceSound = & $getProperty $runtimeStatus "deviceSound" $null
                $deviceState = [string](& $getProperty $deviceSound "state" "unknown")
                if ($deviceState -in @("muted", "silent")) {
                    & $setProgress $true "determinate" 65 (Get-UlanziText -Key 'O buzzer esta desligado; o teste auditivo foi pulado.')
                    $statusLabel.Text = (Get-UlanziText -Key 'O som esta desligado ou em 0%; o teste auditivo foi pulado.')
                    & $setSemanticRole $statusLabel "Warning"
                    & $finishRunAll
                    return
                }
                $statusLabel.Text = if ($requestState -eq "confirmed") {
                    (Get-UlanziText -Key 'Buzzer confirmado. Enviando uma melodia curta...')
                } elseif ($requestState -eq "unsupported") {
                    (Get-UlanziText -Key 'O buzzer nao pode ser consultado neste firmware. Testando a melodia mesmo assim...')
                } else {
                    (Get-UlanziText -Key 'A consulta do buzzer falhou. Testando a melodia mesmo assim...')
                }
                & $setSemanticRole $statusLabel $(if ($requestState -eq "confirmed") { "Muted" } else { "Warning" })
                & $setProgress $true "determinate" 60 (Get-UlanziText -Key 'Enviando uma melodia curta ao TC001.')
                try {
                    [void](& $startCommand "test-sound")
                } catch {
                    $statusLabel.Text = (Get-UlanziText -Key 'Nao foi possivel iniciar o teste auditivo: {0}' -Arguments @(($($_.Exception.Message))))
                    & $setSemanticRole $statusLabel "Error"
                    & $finishRunAll
                }
                return
            }
            if ($requestState -eq "confirmed" -and $completedCommand -eq "test-sound") {
                $state.SoundAccepted = $true
                & $setProgress $true "determinate" 75 (Get-UlanziText -Key 'Confirmando se a melodia do TC001 foi ouvida.')
                $heardAnswer = Show-UlanziOwnedMessageBox `
                    -Owner $form `
                    -Text (Get-UlanziText -Key 'Voce ouviu a melodia curta no TC001?') `
                    -Caption (Get-UlanziText -Key 'Confirmar som') `
                    -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
                    -Icon ([Windows.Forms.MessageBoxIcon]::Question)
                if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
                $state.SoundHeard = $heardAnswer -eq [Windows.Forms.DialogResult]::Yes
                & $finishRunAll
                return
            }
            & $setProgress $true "determinate" 70 (Get-UlanziText -Key 'Uma etapa nao foi confirmada; concluindo as verificacoes restantes.')
            $statusLabel.Text = if ([string]::IsNullOrWhiteSpace($requestError)) { (Get-UlanziText -Key 'O TC001 nao confirmou uma etapa do teste.') } else { $requestError }
            & $setSemanticRole $statusLabel "Warning"
            & $finishRunAll
            return
        }
        if ([DateTime]::UtcNow -ge $state.PendingDeadline) {
            $state.PendingRequestId = $null
            $state.PendingCommand = $null
            $state.PendingDeadline = [DateTime]::MinValue
            & $setProgress $true "determinate" 70 (Get-UlanziText -Key 'O teste atingiu o tempo limite; concluindo as verificacoes restantes.')
            $statusLabel.Text = (Get-UlanziText -Key 'O bridge nao confirmou o teste dentro do prazo.')
            & $setSemanticRole $statusLabel "Error"
            & $finishRunAll
        }
    })

    $form.add_Shown({
        $runtimeStatus = & $ReadStatus
        & $updateFromStatus $runtimeStatus
        if (-not [bool]$state.BridgeResponsive) {
            $verifyButton.Enabled = $false
            $statusLabel.Text = (Get-UlanziText -Key 'O aplicativo esta parado ou sem resposta. Voce ainda pode copiar o resumo ou exportar o diagnostico.')
            & $setSemanticRole $statusLabel "Error"
        }
        $timer.Start()
    })
    $form.add_FormClosing({
        param($sender, $eventArgs)
        if (
            $eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing -and
            (
                -not [string]::IsNullOrWhiteSpace([string]$state.PendingRequestId) -or
                $null -ne $state.PendingExportProcess
            )
        ) {
            $eventArgs.Cancel = $true
            $statusLabel.Text = (Get-UlanziText -Key 'Aguarde a etapa atual terminar antes de fechar.')
            & $setSemanticRole $statusLabel "Warning"
            return
        }
        $state.Closing = $true
        $timer.Stop()
    })

    try {
        try {
            $themeCommand = Get-Command Apply-UlanziUiTheme -ErrorAction SilentlyContinue
            if ($null -ne $themeCommand) {
                $theme = "system"
                $themePreferenceCommand = Get-Command Get-UlanziUiThemePreference -ErrorAction SilentlyContinue
                if ($null -ne $themePreferenceCommand) {
                    try { $theme = [string](& $themePreferenceCommand) } catch { $theme = "system" }
                }
                if ($theme -notin @("system", "light", "dark")) { $theme = "system" }
                $paletteCommand = Get-Command Get-UlanziUiPalette -ErrorAction SilentlyContinue
                if ($null -ne $paletteCommand) { $uiPalette = & $paletteCommand -Theme $theme }
                & $themeCommand -Control $form -Theme $theme
            } else {
                $fallbackThemeCommand = Get-Command Apply-UlanziCurrentUiTheme -ErrorAction SilentlyContinue
                if ($null -ne $fallbackThemeCommand) { & $fallbackThemeCommand -Control $form }
            }
        } catch { $uiPalette = $null }
        if ($null -ne $Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    } finally {
        $state.Closing = $true
        $timer.Stop()
        if ($null -ne $state.PendingExportProcess) {
            $pendingExportProcess = $state.PendingExportProcess
            $state.PendingExportProcess = $null
            try {
                if (-not $pendingExportProcess.HasExited) { $pendingExportProcess.Kill() }
            } catch { } finally {
                $pendingExportProcess.Dispose()
            }
        }
        $timer.Dispose()
        $form.Dispose()
    }
}
