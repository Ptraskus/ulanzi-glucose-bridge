function Show-UlanziOwnedMessageBox {
    [CmdletBinding()]
    [OutputType([Windows.Forms.DialogResult])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Caption,
        [Parameter(Mandatory = $false)][Windows.Forms.MessageBoxButtons]$Buttons = [Windows.Forms.MessageBoxButtons]::OK,
        [Parameter(Mandatory = $false)][Windows.Forms.MessageBoxIcon]$Icon = [Windows.Forms.MessageBoxIcon]::None
    )

    if ($null -ne $Owner -and $Owner -is [Windows.Forms.Control]) {
        $ownerControl = [Windows.Forms.Control]$Owner
        if ($ownerControl.IsDisposed -or $ownerControl.Disposing -or -not $ownerControl.IsHandleCreated) {
            return [Windows.Forms.DialogResult]::Cancel
        }
    }

    try {
        if ($null -eq $Owner) {
            return [Windows.Forms.MessageBox]::Show($Text, $Caption, $Buttons, $Icon)
        }
        return [Windows.Forms.MessageBox]::Show($Owner, $Text, $Caption, $Buttons, $Icon)
    } catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [ObjectDisposedException]) {
            return [Windows.Forms.DialogResult]::Cancel
        }
        throw
    }
}

function Get-UlanziUsableDialogOwner {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][Windows.Forms.IWin32Window]$Owner
    )

    if ($null -eq $Owner) { return $null }
    if ($Owner -isnot [Windows.Forms.Control]) { return $Owner }
    $ownerControl = [Windows.Forms.Control]$Owner
    if ($ownerControl.IsDisposed -or $ownerControl.Disposing -or -not $ownerControl.IsHandleCreated -or -not $ownerControl.Visible) {
        return $null
    }
    return $ownerControl
}

function ConvertTo-UlanziConfigProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.IndexOf('"') -ge 0 -or $Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
        throw "Um caminho local contem caracteres que nao podem ser usados com seguranca."
    }
    return '"' + $Value + '"'
}

function Start-UlanziConfigEditorOperation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("read", "write")][string]$Command,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Request
    )

    $runtimeDirectory = Join-Path $ProjectRoot ".runtime"
    [void][IO.Directory]::CreateDirectory($runtimeDirectory)
    $requestId = [Guid]::NewGuid().ToString("N")
    $requestPath = Join-Path $runtimeDirectory "config-ui-request-$requestId.json"
    $resultPath = Join-Path $runtimeDirectory "config-ui-result-$requestId.json"
    $vaultPath = Join-Path $ProjectRoot ".secrets\vault.json"
    $editorPath = Join-Path $ProjectRoot "src\config-editor-cli.mjs"
    $utf8 = [Text.UTF8Encoding]::new($false)

    $process = $null
    try {
        if ($Command -eq "write") {
            if ($null -eq $Request) { throw "O pedido de salvamento esta vazio." }
            $requestJson = $Request | ConvertTo-Json -Depth 8 -Compress
            [IO.File]::WriteAllText($requestPath, $requestJson, $utf8)
            $arguments = @($editorPath, "write", $EnvPath, $vaultPath, $requestPath, $resultPath)
        } else {
            $arguments = @($editorPath, "read", $EnvPath, $vaultPath, $resultPath)
        }

        $node = Get-Command node -ErrorAction Stop
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = if (-not [string]::IsNullOrWhiteSpace([string]$node.Source)) { [string]$node.Source } else { [string]$node.Path }
        $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-UlanziConfigProcessArgument -Value ([string]$_) }) -join " ")
        $startInfo.WorkingDirectory = $ProjectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        return [pscustomobject]@{
            Command = $Command
            Process = $process
            RequestPath = $requestPath
            ResultPath = $resultPath
            StandardOutputTask = $standardOutputTask
            StandardErrorTask = $standardErrorTask
        }
    } catch {
        if ($null -ne $process) { $process.Dispose() }
        if ([IO.File]::Exists($requestPath)) { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }
        if ([IO.File]::Exists($resultPath)) { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Complete-UlanziConfigEditorOperation {
    param([Parameter(Mandatory = $true)][object]$Operation)

    $process = [Diagnostics.Process]$Operation.Process
    $utf8 = [Text.UTF8Encoding]::new($false)
    try {
        if (-not $process.HasExited) { throw "O editor de configuracoes ainda nao terminou." }
        $process.WaitForExit()
        [void]$Operation.StandardOutputTask.GetAwaiter().GetResult()
        [void]$Operation.StandardErrorTask.GetAwaiter().GetResult()
        $editorExitCode = $process.ExitCode
        if (-not [IO.File]::Exists([string]$Operation.ResultPath)) {
            throw "O editor de configuracoes nao produziu uma resposta valida."
        }
        $result = [IO.File]::ReadAllText([string]$Operation.ResultPath, $utf8) | ConvertFrom-Json
        if ($result.ok -ne $true) {
            $message = [string]$result.message
            if ([string]::IsNullOrWhiteSpace($message)) { $message = "Nao foi possivel validar a configuracao." }
            throw $message
        }
        if ($editorExitCode -ne 0) { throw "O editor de configuracoes terminou com erro." }
        return $result
    } finally {
        if ([IO.File]::Exists([string]$Operation.RequestPath)) { Remove-Item -LiteralPath ([string]$Operation.RequestPath) -Force -ErrorAction SilentlyContinue }
        if ([IO.File]::Exists([string]$Operation.ResultPath)) { Remove-Item -LiteralPath ([string]$Operation.ResultPath) -Force -ErrorAction SilentlyContinue }
        $process.Dispose()
    }
}

function Stop-UlanziConfigEditorOperation {
    param([Parameter(Mandatory = $true)][object]$Operation)

    try {
        $process = [Diagnostics.Process]$Operation.Process
        if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
            try { [void]$process.WaitForExit(2000) } catch { }
        }
        $process.Dispose()
    } catch { }
    if ([IO.File]::Exists([string]$Operation.RequestPath)) { Remove-Item -LiteralPath ([string]$Operation.RequestPath) -Force -ErrorAction SilentlyContinue }
    if ([IO.File]::Exists([string]$Operation.ResultPath)) { Remove-Item -LiteralPath ([string]$Operation.ResultPath) -Force -ErrorAction SilentlyContinue }
}

function Invoke-UlanziConfigEditor {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("read", "write")][string]$Command,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Request,
        [Parameter(Mandatory = $false)][ValidateRange(5, 120)][int]$TimeoutSeconds = 30
    )

    $operation = Start-UlanziConfigEditorOperation -Command $Command -ProjectRoot $ProjectRoot -EnvPath $EnvPath -Request $Request
    try {
        if (-not $operation.Process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-UlanziConfigEditorOperation -Operation $operation
            $operation = $null
            throw "O editor de configuracoes excedeu o tempo limite de $TimeoutSeconds segundos."
        }
        $result = Complete-UlanziConfigEditorOperation -Operation $operation
        $operation = $null
        return $result
    } finally {
        if ($null -ne $operation) { Stop-UlanziConfigEditorOperation -Operation $operation }
    }
}

function New-UlanziSettingsTable {
    $table = [Windows.Forms.TableLayoutPanel]::new()
    $table.Dock = [Windows.Forms.DockStyle]::Top
    $table.AutoSize = $true
    $table.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $table.AutoScroll = $false
    $table.Padding = [Windows.Forms.Padding]::new(14, 10, 14, 10)
    $table.ColumnCount = 3
    $table.RowCount = 0
    $table.GrowStyle = [Windows.Forms.TableLayoutPanelGrowStyle]::AddRows
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 125))
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 72))
    return $table
}

function Add-UlanziSection {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.TableLayoutPanel]$Table,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $row = $Table.RowCount
    $Table.RowCount += 1
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 38))
    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Dock = [Windows.Forms.DockStyle]::Fill
    $label.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
    $label.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $label.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $label.Margin = [Windows.Forms.Padding]::new(4, 6, 4, 2)
    [void]$Table.Controls.Add($label, 0, $row)
    $Table.SetColumnSpan($label, 3)
}

function Add-UlanziNumberSetting {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.TableLayoutPanel]$Table,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][decimal]$Minimum,
        [Parameter(Mandatory = $true)][decimal]$Maximum,
        [Parameter(Mandatory = $true)][decimal]$Value,
        [Parameter(Mandatory = $true)][string]$Unit,
        [Parameter(Mandatory = $false)][int]$DecimalPlaces = 0,
        [Parameter(Mandatory = $false)][decimal]$Increment = 1
    )

    $row = $Table.RowCount
    $Table.RowCount += 1
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 62))

    $information = [Windows.Forms.Panel]::new()
    $information.Dock = [Windows.Forms.DockStyle]::Fill
    $information.Margin = [Windows.Forms.Padding]::new(4, 2, 8, 2)
    $titleLabel = [Windows.Forms.Label]::new()
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Location = [Drawing.Point]::new(0, 6)
    $titleLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $descriptionLabel = [Windows.Forms.Label]::new()
    $descriptionLabel.Text = $Description
    $descriptionLabel.AutoSize = $true
    $descriptionLabel.Location = [Drawing.Point]::new(0, 29)
    $descriptionLabel.ForeColor = [Drawing.Color]::DimGray
    $information.Controls.Add($titleLabel)
    $information.Controls.Add($descriptionLabel)

    $control = [Windows.Forms.NumericUpDown]::new()
    $control.Minimum = $Minimum
    $control.Maximum = $Maximum
    $control.DecimalPlaces = $DecimalPlaces
    $control.Increment = $Increment
    $control.Value = [Math]::Min($Maximum, [Math]::Max($Minimum, $Value))
    $control.Dock = [Windows.Forms.DockStyle]::Fill
    $control.Margin = [Windows.Forms.Padding]::new(8, 17, 8, 17)
    $control.TextAlign = [Windows.Forms.HorizontalAlignment]::Right
    $control.ThousandsSeparator = $true

    $unitLabel = [Windows.Forms.Label]::new()
    $unitLabel.Text = $Unit
    $unitLabel.Dock = [Windows.Forms.DockStyle]::Fill
    $unitLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
    $unitLabel.ForeColor = [Drawing.Color]::DimGray

    [void]$Table.Controls.Add($information, 0, $row)
    [void]$Table.Controls.Add($control, 1, $row)
    [void]$Table.Controls.Add($unitLabel, 2, $row)
    return $control
}

function Add-UlanziBooleanSetting {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.TableLayoutPanel]$Table,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][bool]$Checked
    )

    $row = $Table.RowCount
    $Table.RowCount += 1
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 62))
    $panel = [Windows.Forms.Panel]::new()
    $panel.Dock = [Windows.Forms.DockStyle]::Fill
    $panel.Margin = [Windows.Forms.Padding]::new(4, 2, 4, 2)
    $checkBox = [Windows.Forms.CheckBox]::new()
    $checkBox.Text = $Title
    $checkBox.Checked = $Checked
    $checkBox.AutoSize = $true
    $checkBox.Location = [Drawing.Point]::new(0, 6)
    $checkBox.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $descriptionLabel = [Windows.Forms.Label]::new()
    $descriptionLabel.Text = $Description
    $descriptionLabel.AutoSize = $true
    $descriptionLabel.Location = [Drawing.Point]::new(22, 31)
    $descriptionLabel.ForeColor = [Drawing.Color]::DimGray
    $panel.Controls.Add($checkBox)
    $panel.Controls.Add($descriptionLabel)
    [void]$Table.Controls.Add($panel, 0, $row)
    $Table.SetColumnSpan($panel, 3)
    return $checkBox
}

function Add-UlanziChoiceSetting {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.TableLayoutPanel]$Table,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string[]]$Options,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$SelectedIndex
    )

    if ($Options.Count -eq 0 -or $SelectedIndex -ge $Options.Count) {
        throw "As opcoes desta configuracao sao invalidas."
    }

    $row = $Table.RowCount
    $Table.RowCount += 1
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 68))

    $information = [Windows.Forms.Panel]::new()
    $information.Dock = [Windows.Forms.DockStyle]::Fill
    $information.Margin = [Windows.Forms.Padding]::new(4, 2, 8, 2)
    $titleLabel = [Windows.Forms.Label]::new()
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Location = [Drawing.Point]::new(0, 6)
    $titleLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $descriptionLabel = [Windows.Forms.Label]::new()
    $descriptionLabel.Text = $Description
    $descriptionLabel.AutoSize = $true
    $descriptionLabel.Location = [Drawing.Point]::new(0, 29)
    $descriptionLabel.ForeColor = [Drawing.Color]::DimGray
    $information.Controls.Add($titleLabel)
    $information.Controls.Add($descriptionLabel)

    $control = [Windows.Forms.ComboBox]::new()
    $control.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $control.Dock = [Windows.Forms.DockStyle]::Fill
    $control.Margin = [Windows.Forms.Padding]::new(8, 19, 8, 17)
    [void]$control.Items.AddRange($Options)
    $control.SelectedIndex = $SelectedIndex

    [void]$Table.Controls.Add($information, 0, $row)
    [void]$Table.Controls.Add($control, 1, $row)
    $Table.SetColumnSpan($control, 2)
    return $control
}

function Add-UlanziInformation {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.TableLayoutPanel]$Table,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $false)][int]$Height = 58
    )

    $row = $Table.RowCount
    $Table.RowCount += 1
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $Height))
    $panel = [Windows.Forms.Panel]::new()
    $panel.Dock = [Windows.Forms.DockStyle]::Fill
    $panel.Margin = [Windows.Forms.Padding]::new(4, 5, 4, 5)
    $panel.BackColor = [Drawing.ColorTranslator]::FromHtml("#EAF4F8")
    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Dock = [Windows.Forms.DockStyle]::Fill
    $label.Padding = [Windows.Forms.Padding]::new(10, 7, 10, 7)
    $label.ForeColor = [Drawing.ColorTranslator]::FromHtml("#244A5A")
    $panel.Controls.Add($label)
    [void]$Table.Controls.Add($panel, 0, $row)
    $Table.SetColumnSpan($panel, 3)
    return $label
}

function Complete-UlanziSettingsTable {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.TableLayoutPanel]$Table
    )

    # TableLayoutPanel entrega todo o espaco vertical restante para a ultima
    # linha quando so existem linhas absolutas. Uma linha flexivel vazia mantem
    # o ultimo campo com a altura correta e deixa o conteudo alinhado ao topo.
    $row = $Table.RowCount
    $Table.RowCount += 1
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 1))
    $spacer = [Windows.Forms.Panel]::new()
    $spacer.Dock = [Windows.Forms.DockStyle]::Fill
    $spacer.Margin = [Windows.Forms.Padding]::Empty
    $spacer.TabStop = $false
    [void]$Table.Controls.Add($spacer, 0, $row)
    $Table.SetColumnSpan($spacer, 3)
}

function Connect-UlanziSettingsScrolling {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.TabPage]$Tab,
        [Parameter(Mandatory = $true)][Windows.Forms.TableLayoutPanel]$Table
    )

    $scrollState = [pscustomobject]@{ Updating = $false }
    $updateScrolling = ({
        if ($scrollState.Updating -or $Tab.IsDisposed -or $Table.IsDisposed) { return }
        $scrollState.Updating = $true
        try {
            $contentHeight = [Math]::Max($Table.Height, $Table.PreferredSize.Height)
            $needsScrolling = $contentHeight -gt $Tab.ClientSize.Height
            if ($Tab.AutoScroll -ne $needsScrolling) {
                $Tab.AutoScroll = $needsScrolling
            }
        } finally {
            $scrollState.Updating = $false
        }
    }).GetNewClosure()

    $Tab.add_ClientSizeChanged($updateScrolling)
    $Table.add_SizeChanged($updateScrolling)
    & $updateScrolling
}

function Apply-UlanziCurrentUiTheme {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.Control]$Control
    )

    # A tela continua independente: instalacoes antigas que ainda nao carregam
    # ui-theme.ps1 simplesmente preservam as cores definidas neste arquivo.
    $applyThemeCommand = Get-Command Apply-UlanziUiTheme -ErrorAction SilentlyContinue
    if ($null -eq $applyThemeCommand) { return }

    $theme = "system"
    $readThemeCommand = Get-Command Get-UlanziUiThemePreference -ErrorAction SilentlyContinue
    if ($null -ne $readThemeCommand) {
        try {
            $theme = [string](& $readThemeCommand)
        } catch {
            $theme = "system"
        }
    }
    if ($theme -notin @("system", "light", "dark")) { $theme = "system" }

    try {
        & $applyThemeCommand -Control $Control -Theme $theme
    } catch {
        # Aparencia nunca deve impedir o usuario de abrir uma tela essencial.
    }
}

function Show-UlanziVolumeDialog {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory = $true)][scriptblock]$SendCommand,
        [Parameter(Mandatory = $true)][scriptblock]$ReadStatus,
        [Parameter(Mandatory = $true)][scriptblock]$BridgeRunning,
        [Parameter(Mandatory = $false)][ValidateRange(15, 600)][int]$CommandTimeoutSeconds = 150,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$ConfirmAudibleEffect = $null,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ProjectRoot = ""
    )

    $Owner = Get-UlanziUsableDialogOwner -Owner $Owner

    # Callback contract:
    #   SendCommand <command> <payload> -> requestId (string or object.requestId)
    #   ReadStatus                       -> runtime status v2 (or $null)
    #   BridgeRunning                    -> boolean
    #   ConfirmAudibleEffect <owner> <technical-level> -> boolean (optional test hook)
    # Network access remains in the bridge. This dialog only writes a command
    # through the callback and observes its correlated status without blocking
    # the WinForms thread.
    $getProperty = {
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

    $requestIdFromResult = {
        param([Parameter(Mandatory = $false)][AllowNull()][object]$Result)

        if ($Result -is [string]) { return [string]$Result }
        if ($Result -is [Array] -and $Result.Count -gt 0) {
            $Result = $Result[$Result.Count - 1]
            if ($Result -is [string]) { return [string]$Result }
        }
        return [string](& $getProperty $Result "requestId" "")
    }

    $form = [Windows.Forms.Form]::new()
    $form.Text = "Som do TC001"
    $form.ClientSize = [Drawing.Size]::new(530, 310)
    $form.MaximumSize = [Drawing.Size]::new(700, 430)
    $form.StartPosition = if ($null -ne $Owner) {
        [Windows.Forms.FormStartPosition]::CenterParent
    } else {
        [Windows.Forms.FormStartPosition]::CenterScreen
    }
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::Sizable
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = ($null -eq $Owner)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = [Drawing.Font]::new("Segoe UI", 9)
    $form.BackColor = [Drawing.ColorTranslator]::FromHtml("#F5F7F8")
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $setIconCommand = Get-Command Set-UlanziUiApplicationIcon -ErrorAction SilentlyContinue
        if ($null -ne $setIconCommand) {
            [void](& $setIconCommand -Form $form -ProjectRoot $ProjectRoot)
        }
    }
    # MinimumSize mede a moldura inteira, enquanto ClientSize mede somente a
    # area util. Preserve a composicao compacta quando a pessoa reduzir.
    $form.MinimumSize = $form.Size

    $header = [Windows.Forms.Panel]::new()
    $header.Dock = [Windows.Forms.DockStyle]::Top
    $header.Height = 76
    $header.BackColor = [Drawing.ColorTranslator]::FromHtml("#173A4D")
    $header.Tag = "Header"

    $titleLabel = [Windows.Forms.Label]::new()
    $titleLabel.Text = "Som do TC001"
    $titleLabel.AutoSize = $true
    $titleLabel.Location = [Drawing.Point]::new(20, 13)
    $titleLabel.Font = [Drawing.Font]::new("Segoe UI", 17, [Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [Drawing.Color]::White

    $subtitleLabel = [Windows.Forms.Label]::new()
    $subtitleLabel.Text = "Ative ou silencie os sons do relogio."
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = [Drawing.Point]::new(22, 48)
    $subtitleLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#D4E7EF")
    $subtitleLabel.Tag = "HeaderMuted"
    $header.Controls.Add($titleLabel)
    $header.Controls.Add($subtitleLabel)

    $statePanel = [Windows.Forms.Panel]::new()
    $statePanel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $statePanel.Location = [Drawing.Point]::new(20, 94)
    $statePanel.Size = [Drawing.Size]::new(490, 102)
    $statePanel.BackColor = [Drawing.Color]::White
    $statePanel.Tag = "Surface"

    $stateAccent = [Windows.Forms.Panel]::new()
    $stateAccent.Dock = [Windows.Forms.DockStyle]::Left
    $stateAccent.Width = 4
    $stateAccent.BackColor = [Drawing.ColorTranslator]::FromHtml("#56C596")
    $stateAccent.Tag = "Success"

    $stateTitleLabel = [Windows.Forms.Label]::new()
    $stateTitleLabel.Text = "Som geral do relogio"
    $stateTitleLabel.AutoSize = $true
    $stateTitleLabel.Location = [Drawing.Point]::new(18, 13)
    $stateTitleLabel.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)

    $scopeLabel = [Windows.Forms.Label]::new()
    $scopeLabel.Text = "Este ajuste vale para todos os sons do TC001."
    $scopeLabel.AutoSize = $true
    $scopeLabel.Location = [Drawing.Point]::new(18, 36)
    $scopeLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#5B6870")
    $scopeLabel.Tag = "Muted"

    $soundEnabledControl = [Windows.Forms.CheckBox]::new()
    $soundEnabledControl.Text = "Ativar som no TC001"
    $soundEnabledControl.AutoSize = $true
    $soundEnabledControl.Location = [Drawing.Point]::new(21, 68)
    $soundEnabledControl.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $soundEnabledControl.Enabled = $false
    $soundEnabledControl.TabIndex = 0
    $soundEnabledControl.AccessibleDescription = "Ativa ou desativa o som geral do TC001."

    $stateValueLabel = [Windows.Forms.Label]::new()
    $stateValueLabel.Text = "Verificando..."
    $stateValueLabel.Location = [Drawing.Point]::new(366, 66)
    $stateValueLabel.Size = [Drawing.Size]::new(105, 24)
    $stateValueLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $stateValueLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
    $stateValueLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $stateValueLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $stateValueLabel.AccessibleName = "Estado selecionado do som"

    $volumeControl = [Windows.Forms.TrackBar]::new()
    $volumeControl.Minimum = 0
    $volumeControl.Maximum = 100
    $volumeControl.Value = 0
    $volumeControl.TickFrequency = 10
    $volumeControl.SmallChange = 5
    $volumeControl.LargeChange = 10
    $volumeControl.Location = [Drawing.Point]::new(0, 0)
    $volumeControl.Size = [Drawing.Size]::new(1, 1)
    # O valor continua sendo preservado no comando para nao sobrescrever uma
    # configuracao feita fora deste aplicativo. Ele nao e exposto como controle:
    # no piezo do TC001 a escala numerica nao corresponde a volume audivel.
    $volumeControl.Enabled = $false
    $volumeControl.Visible = $false
    $volumeControl.TabStop = $false

    $statusLabel = [Windows.Forms.Label]::new()
    $statusLabel.Text = "Verificando o TC001..."
    $statusLabel.Location = [Drawing.Point]::new(22, 211)
    $statusLabel.Size = [Drawing.Size]::new(486, 34)
    $statusLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $statusLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $statusLabel.AccessibleName = "Estado da operacao de som"

    $footer = [Windows.Forms.Panel]::new()
    $footer.Dock = [Windows.Forms.DockStyle]::Bottom
    # Defina a largura antes de adicionar controles ancorados a direita.
    # Um Panel novo nasce com 200 px; se a ancora for calculada nesse estado,
    # o WinForms preserva uma margem negativa e desloca os botoes para fora
    # quando o painel finalmente ocupa a largura do formulario.
    $footer.Size = [Drawing.Size]::new($form.ClientSize.Width, 58)
    $footer.BackColor = [Drawing.Color]::White

    $volumeProgress = [Windows.Forms.ProgressBar]::new()
    $volumeProgress.Dock = [Windows.Forms.DockStyle]::Top
    $volumeProgress.Height = 4
    $volumeProgress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $volumeProgress.MarqueeAnimationSpeed = 0
    $volumeProgress.Visible = $false
    $volumeProgress.TabStop = $false
    $volumeProgress.AccessibleName = "Progresso da operacao de som"
    $volumeProgress.AccessibleDescription = "Nenhuma operacao de som esta em andamento."

    $refreshButton = [Windows.Forms.Button]::new()
    $refreshButton.Text = "Tentar novamente"
    $refreshButton.Size = [Drawing.Size]::new(126, 32)
    $refreshButton.Location = [Drawing.Point]::new(18, 14)
    $refreshButton.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Bottom
    $refreshButton.Enabled = $false
    $refreshButton.Visible = $false
    $refreshButton.TabIndex = 1

    $applyButton = [Windows.Forms.Button]::new()
    $applyButton.Text = "Salvar"
    $applyButton.Size = [Drawing.Size]::new(100, 32)
    $applyButton.Location = [Drawing.Point]::new(174, 14)
    $applyButton.Anchor = [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
    $applyButton.BackColor = [Drawing.ColorTranslator]::FromHtml("#167A91")
    $applyButton.ForeColor = [Drawing.Color]::White
    $applyButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $applyButton.FlatAppearance.BorderSize = 0
    $applyButton.Enabled = $false
    $applyButton.Tag = "Accent"
    $applyButton.TabIndex = 2

    $testButton = [Windows.Forms.Button]::new()
    $testButton.Text = "Testar som"
    $testButton.Size = [Drawing.Size]::new(126, 32)
    $testButton.Location = [Drawing.Point]::new(282, 14)
    $testButton.Anchor = [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
    $testButton.Enabled = $false
    $testButton.TabIndex = 3

    $closeButton = [Windows.Forms.Button]::new()
    $closeButton.Text = "Fechar"
    $closeButton.Size = [Drawing.Size]::new(94, 32)
    $closeButton.Location = [Drawing.Point]::new(416, 14)
    $closeButton.Anchor = [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
    $closeButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $closeButton.TabIndex = 4

    $footer.Controls.Add($refreshButton)
    $footer.Controls.Add($applyButton)
    $footer.Controls.Add($testButton)
    $footer.Controls.Add($closeButton)
    $footer.Controls.Add($volumeProgress)
    $statePanel.Controls.Add($stateTitleLabel)
    $statePanel.Controls.Add($scopeLabel)
    $statePanel.Controls.Add($soundEnabledControl)
    $statePanel.Controls.Add($stateValueLabel)
    $statePanel.Controls.Add($stateAccent)
    $form.Controls.Add($statusLabel)
    $form.Controls.Add($volumeControl)
    $form.Controls.Add($statePanel)
    $form.Controls.Add($footer)
    $form.Controls.Add($header)
    $form.CancelButton = $closeButton

    $dialogState = [pscustomobject]@{
        Closing = $false
        PendingRequestId = $null
        PendingCommand = $null
        PendingDeadline = [DateTime]::MinValue
        HasDeviceState = $false
        DeviceSupported = $false
        DeviceSoundEnabled = $null
        DeviceBuzzerVolume = $null
        Dirty = $false
        SuppressChanges = $false
        Applied = $false
        TestAfterWrite = $false
        AudibleConfirmation = $null
        LastBridgeRunning = $false
    }

    $setStatus = {
        param(
            [Parameter(Mandatory = $true)][string]$Text,
            [Parameter(Mandatory = $false)][ValidateSet("info", "success", "warning", "error")][string]$Level = "info"
        )

        if ($dialogState.Closing) { return }
        $statusLabel.Text = $Text
        $statusLabel.ForeColor = switch ($Level) {
            "success" { [Drawing.ColorTranslator]::FromHtml("#16733D") }
            "warning" { [Drawing.ColorTranslator]::FromHtml("#8A5A00") }
            "error" { [Drawing.ColorTranslator]::FromHtml("#B42318") }
            default { [Drawing.ColorTranslator]::FromHtml("#1D5D7A") }
        }
    }

    $isBridgeRunning = {
        try {
            return (& $BridgeRunning) -eq $true
        } catch {
            return $false
        }
    }

    $updateSoundSelection = {
        if ($soundEnabledControl.Checked) {
            $stateValueLabel.Text = "Ligado"
            $stateValueLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#16733D")
        } else {
            $stateValueLabel.Text = "Desligado"
            $stateValueLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#5B6870")
        }
    }

    $clearAudibleConfirmation = {
        $dialogState.AudibleConfirmation = $null
    }

    $audibleConfirmationForCurrentSnapshot = {
        $confirmation = $dialogState.AudibleConfirmation
        if (
            $null -eq $confirmation -or
            -not $dialogState.HasDeviceState -or
            -not $dialogState.DeviceSupported -or
            [bool]$confirmation.SoundEnabled -ne [bool]$dialogState.DeviceSoundEnabled -or
            [int]$confirmation.BuzzerVolume -ne [int]$dialogState.DeviceBuzzerVolume
        ) {
            return $null
        }
        return [bool]$confirmation.Confirmed
    }

    $updateInteractivity = {
        if ($dialogState.Closing) { return }
        $running = & $isBridgeRunning
        $busy = -not [string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId)
        $ready = (
            $running -and
            -not $busy -and
            $dialogState.HasDeviceState -and
            $dialogState.DeviceSupported
        )
        $soundEnabledControl.Enabled = $ready
        $applyButton.Enabled = $ready -and $dialogState.Dirty
        $testButton.Text = if ($dialogState.Dirty) { "Salvar e testar" } else { "Testar som" }
        $testButton.Enabled = $ready
        $refreshButton.Enabled = $running -and -not $busy
        $refreshButton.Visible = -not $busy -and (-not $dialogState.HasDeviceState -or -not $dialogState.DeviceSupported)
        $closeButton.Enabled = -not $busy
        $volumeProgress.Visible = $busy
        $volumeProgress.MarqueeAnimationSpeed = if ($busy) { 28 } else { 0 }
        $volumeProgress.AccessibleDescription = if ($busy) {
            switch ([string]$dialogState.PendingCommand) {
                "read-device-sound" { "Consultando o estado do som no TC001." }
                "write-device-sound" { "Aplicando o estado do som no TC001." }
                "test-sound" { "Enviando e confirmando a melodia de teste." }
                default { "Uma operacao de som esta em andamento." }
            }
        } else {
            "Nenhuma operacao de som esta em andamento."
        }
    }

    $setUnavailable = {
        param(
            [Parameter(Mandatory = $true)][string]$Message,
            [Parameter(Mandatory = $false)][ValidateSet("warning", "error")][string]$Level = "error"
        )

        $dialogState.HasDeviceState = $false
        $dialogState.DeviceSupported = $false
        $dialogState.Dirty = $false
        $dialogState.TestAfterWrite = $false
        & $clearAudibleConfirmation
        $stateValueLabel.Text = "Indisponivel"
        $stateValueLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#8A5A00")
        & $setStatus $Message $Level
        & $updateInteractivity
    }

    $applyDeviceSnapshot = {
        param([Parameter(Mandatory = $true)][object]$DeviceSound)

        $supportedValue = & $getProperty $DeviceSound "supported" $null
        $mode = [string](& $getProperty $DeviceSound "mode" "")
        $state = [string](& $getProperty $DeviceSound "state" "")
        $reason = [string](& $getProperty $DeviceSound "reason" "")
        if ($state -eq "error") {
            $lastError = [string](& $getProperty $DeviceSound "lastRequestError" "")
            if ([string]::IsNullOrWhiteSpace($lastError)) { $lastError = $reason }
            if ([string]::IsNullOrWhiteSpace($lastError)) { $lastError = "Nao foi possivel consultar o som do TC001." }
            & $setUnavailable $lastError "error"
            return $false
        }
        if ($supportedValue -eq $false -or ($mode -and $mode -ne "ng") -or $state -eq "unsupported") {
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = "Este TC001 nao permite controlar o som por aqui."
            }
            & $setUnavailable $reason "warning"
            return $false
        }
        if ($supportedValue -ne $true -or $state -in @("unknown", "reading", "writing")) {
            & $setUnavailable "Ainda nao foi possivel confirmar o som. Tente novamente." "warning"
            return $false
        }

        $enabledValue = & $getProperty $DeviceSound "soundEnabled" $null
        $volumeValue = & $getProperty $DeviceSound "buzzerVolume" $null
        $volume = 0
        $validVolume = [int]::TryParse([string]$volumeValue, [ref]$volume)
        if (
            $enabledValue -isnot [bool] -or
            -not $validVolume -or
            $volume -lt 0 -or
            $volume -gt 100
        ) {
            & $setUnavailable "O TC001 respondeu sem um estado de som valido." "error"
            return $false
        }

        $audibleConfirmation = $dialogState.AudibleConfirmation
        if (
            $null -ne $audibleConfirmation -and
            (
                [bool]$audibleConfirmation.SoundEnabled -ne [bool]$enabledValue -or
                [int]$audibleConfirmation.BuzzerVolume -ne $volume
            )
        ) {
            & $clearAudibleConfirmation
        }

        $dialogState.SuppressChanges = $true
        try {
            $soundEnabledControl.Checked = [bool]$enabledValue -and $volume -gt 0
            $volumeControl.Value = $volume
        } finally {
            $dialogState.SuppressChanges = $false
        }
        $dialogState.HasDeviceState = $true
        $dialogState.DeviceSupported = $true
        $dialogState.DeviceSoundEnabled = [bool]$enabledValue
        $dialogState.DeviceBuzzerVolume = $volume
        $dialogState.Dirty = $false
        & $updateSoundSelection
        & $updateInteractivity
        return $true
    }

    $startCommand = {
        param(
            [Parameter(Mandatory = $true)][ValidateSet("read-device-sound", "write-device-sound", "test-sound")][string]$Command,
            [Parameter(Mandatory = $false)][AllowNull()][object]$Payload = $null
        )

        if ($dialogState.Closing) { return $false }
        if (-not [string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId)) { return $false }
        if (-not (& $isBridgeRunning)) {
            & $setUnavailable "O TC001 esta indisponivel. Aguarde a reconexao e tente novamente." "error"
            return $false
        }

        try {
            $result = & $SendCommand $Command $Payload
            $requestId = [string](& $requestIdFromResult $result)
            if ([string]::IsNullOrWhiteSpace($requestId) -or $requestId.Length -lt 8) {
                throw "O bridge nao forneceu um identificador valido para o comando."
            }
            $dialogState.PendingRequestId = $requestId
            $dialogState.PendingCommand = $Command
            $dialogState.PendingDeadline = [DateTime]::UtcNow.AddSeconds($CommandTimeoutSeconds)
            switch ($Command) {
                "read-device-sound" { & $setStatus "Verificando o TC001..." "info" }
                "write-device-sound" { & $setStatus "Salvando a alteracao..." "info" }
                "test-sound" { & $setStatus "Enviando o som de teste..." "info" }
            }
            if ($Command -in @("write-device-sound", "test-sound")) {
                & $clearAudibleConfirmation
            }
            & $updateInteractivity
            return $true
        } catch {
            & $setStatus "Nao foi possivel solicitar a operacao: $($_.Exception.Message)" "error"
            & $updateInteractivity
            return $false
        }
    }

    $completePending = {
        param(
            [Parameter(Mandatory = $true)][bool]$Succeeded,
            [Parameter(Mandatory = $true)][string]$Message,
            [Parameter(Mandatory = $false)][AllowNull()][object]$DeviceSound = $null
        )

        $completedCommand = [string]$dialogState.PendingCommand
        $dialogState.PendingRequestId = $null
        $dialogState.PendingCommand = $null
        $dialogState.PendingDeadline = [DateTime]::MinValue

        if ($Succeeded -and $null -ne $DeviceSound) {
            if (-not (& $applyDeviceSnapshot $DeviceSound)) {
                & $updateInteractivity
                return
            }
        }
        if ($Succeeded -and $completedCommand -eq "write-device-sound") {
            $dialogState.Applied = $true
        }
        & $setStatus $Message $(if ($Succeeded) { "success" } else { "error" })
        & $updateInteractivity
    }

    $markDirty = {
        if ($dialogState.SuppressChanges -or -not $dialogState.HasDeviceState) { return }
        & $clearAudibleConfirmation
        & $updateSoundSelection
        $deviceAudible = (
            [bool]$dialogState.DeviceSoundEnabled -and
            [int]$dialogState.DeviceBuzzerVolume -gt 0
        )
        $dialogState.Dirty = $soundEnabledControl.Checked -ne $deviceAudible
        if ($dialogState.Dirty) {
            & $setStatus "Alteracao ainda nao salva." "info"
        } else {
            $storedState = if ($deviceAudible) { "ligado" } else { "desligado" }
            & $setStatus "Som $storedState no TC001." "info"
        }
        & $updateInteractivity
    }

    $confirmAudible = {
        param([Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$Volume)

        if ($null -ne $ConfirmAudibleEffect) {
            try {
                return (& $ConfirmAudibleEffect $form $Volume) -eq $true
            } catch {
                return $false
            }
        }

        if ($dialogState.Closing -or $form.IsDisposed -or $form.Disposing) { return $false }
        $answer = Show-UlanziOwnedMessageBox `
            -Owner $form `
            -Text "Voce ouviu o som?" `
            -Caption "Teste de som" `
            -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
            -Icon ([Windows.Forms.MessageBoxIcon]::Question)
        if ($dialogState.Closing -or $form.IsDisposed -or $form.Disposing) { return $false }
        return $answer -eq [Windows.Forms.DialogResult]::Yes
    }

    $soundEnabledControl.add_CheckedChanged({ & $markDirty })

    $refreshButton.add_Click({
        [void](& $startCommand "read-device-sound" ([ordered]@{}))
    })
    $applyButton.add_Click({
        if (-not $dialogState.HasDeviceState -or -not $dialogState.DeviceSupported) { return }
        $dialogState.TestAfterWrite = $false
        $targetVolume = if ($soundEnabledControl.Checked -and [int]$dialogState.DeviceBuzzerVolume -le 0) {
            100
        } else {
            [int]$dialogState.DeviceBuzzerVolume
        }
        $payload = [ordered]@{
            soundEnabled = [bool]$soundEnabledControl.Checked
            buzzerVolume = $targetVolume
        }
        [void](& $startCommand "write-device-sound" $payload)
    })
    $testButton.add_Click({
        if (-not $dialogState.HasDeviceState -or -not $dialogState.DeviceSupported) { return }
        if ($dialogState.Dirty) {
            if (-not [bool]$soundEnabledControl.Checked) {
                & $setStatus "Ative o som antes de testar. Voce ainda pode salvar o modo silencioso." "warning"
                return
            }
            $targetVolume = if ([int]$dialogState.DeviceBuzzerVolume -le 0) { 100 } else { [int]$dialogState.DeviceBuzzerVolume }
            $payload = [ordered]@{
                soundEnabled = [bool]$soundEnabledControl.Checked
                buzzerVolume = $targetVolume
            }
            $dialogState.TestAfterWrite = $true
            if (-not (& $startCommand "write-device-sound" $payload)) {
                $dialogState.TestAfterWrite = $false
            }
            return
        }
        if (-not [bool]$dialogState.DeviceSoundEnabled) {
            & $setStatus "Ative e salve o som antes de testar." "warning"
            return
        }
        if ([int]$dialogState.DeviceBuzzerVolume -le 0) {
            & $setStatus "Ative e salve o som antes de testar." "warning"
            return
        }
        [void](& $startCommand "test-sound" ([ordered]@{}))
    })
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 400
    $timer.add_Tick({
        if ($dialogState.Closing) { return }

        $running = & $isBridgeRunning
        if (-not $running) {
            if (-not [string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId)) {
                $dialogState.PendingRequestId = $null
                $dialogState.PendingCommand = $null
                $dialogState.PendingDeadline = [DateTime]::MinValue
                $dialogState.TestAfterWrite = $false
            }
            if ($dialogState.LastBridgeRunning -or $dialogState.HasDeviceState) {
                & $setUnavailable "O TC001 esta indisponivel. Aguarde a reconexao e tente novamente." "error"
            }
            $dialogState.LastBridgeRunning = $false
            & $updateInteractivity
            return
        }

        if (-not $dialogState.LastBridgeRunning) {
            $dialogState.LastBridgeRunning = $true
            if ([string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId)) {
                [void](& $startCommand "read-device-sound" ([ordered]@{}))
                return
            }
        }

        $status = $null
        try {
            $status = & $ReadStatus
        } catch {
            & $clearAudibleConfirmation
            & $setStatus "Nao foi possivel atualizar o estado do TC001." "error"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId) -and $null -ne $status) {
            $requestId = ""
            $requestState = ""
            $requestError = ""
            $deviceSound = & $getProperty $status "deviceSound" $null
            if ($dialogState.PendingCommand -eq "test-sound") {
                $sound = & $getProperty $status "sound" $null
                $requestId = [string](& $getProperty $sound "lastTestRequestId" "")
                $requestState = [string](& $getProperty $sound "lastTestState" "")
                $requestError = [string](& $getProperty $sound "lastTestError" "")
            } else {
                $requestId = [string](& $getProperty $deviceSound "lastRequestId" "")
                $requestState = [string](& $getProperty $deviceSound "lastRequestState" "")
                $requestError = [string](& $getProperty $deviceSound "lastRequestError" "")
            }

            if ($requestId -ceq [string]$dialogState.PendingRequestId) {
                if ($requestState -in @("confirmed", "completed", "success")) {
                    switch ([string]$dialogState.PendingCommand) {
                        "read-device-sound" {
                            $confirmedVolume = [int](& $getProperty $deviceSound "buzzerVolume" 0)
                            $confirmedEnabled = (& $getProperty $deviceSound "soundEnabled" $false) -eq $true
                            $confirmedState = if ($confirmedEnabled -and $confirmedVolume -gt 0) { "ligado" } else { "desligado" }
                            & $completePending $true "Som $confirmedState no TC001." $deviceSound
                        }
                        "write-device-sound" {
                            $testAfterWrite = [bool]$dialogState.TestAfterWrite
                            $dialogState.TestAfterWrite = $false
                            $confirmedVolume = [int](& $getProperty $deviceSound "buzzerVolume" 0)
                            $confirmedEnabled = (& $getProperty $deviceSound "soundEnabled" $false) -eq $true
                            $storedMessage = if (-not $confirmedEnabled) {
                                "Som desligado no TC001."
                            } elseif ($confirmedVolume -le 0) {
                                "O TC001 confirmou a alteracao, mas o som continua indisponivel."
                            } else {
                                "Som ligado no TC001."
                            }
                            & $completePending $true $storedMessage $deviceSound
                            if (
                                $testAfterWrite -and
                                $dialogState.HasDeviceState -and
                                $dialogState.DeviceSupported -and
                                [bool]$dialogState.DeviceSoundEnabled -and
                                [int]$dialogState.DeviceBuzzerVolume -gt 0
                            ) {
                                if (& $startCommand "test-sound" ([ordered]@{})) {
                                    & $setStatus "Som ligado. Enviando o teste..." "info"
                                }
                            }
                        }
                        "test-sound" {
                            $volume = [int]$dialogState.DeviceBuzzerVolume
                            & $completePending $true "Teste enviado ao TC001."
                            $heard = & $confirmAudible $volume
                            if ($dialogState.Closing -or $form.IsDisposed -or $form.Disposing) { return }
                            $dialogState.AudibleConfirmation = [pscustomobject]@{
                                SoundEnabled = [bool]$dialogState.DeviceSoundEnabled
                                BuzzerVolume = $volume
                                Confirmed = [bool]$heard
                            }
                            if ($heard) {
                                & $setStatus "Som ligado e teste confirmado." "success"
                            } else {
                                & $setStatus "O teste foi enviado, mas voce nao ouviu o som. Verifique o relogio." "warning"
                            }
                        }
                    }
                    return
                }
                if ($requestState -in @("error", "failed", "unsupported")) {
                    $failedCommand = [string]$dialogState.PendingCommand
                    $dialogState.TestAfterWrite = $false
                    if ([string]::IsNullOrWhiteSpace($requestError)) {
                        $requestError = if ($requestState -eq "unsupported") {
                            "Este TC001 nao permite controlar o som por aqui."
                        } else {
                            "O TC001 nao confirmou a operacao."
                        }
                    }
                    & $completePending $false $requestError
                    if ($failedCommand -ne "test-sound" -and $null -ne $deviceSound) {
                        [void](& $applyDeviceSnapshot $deviceSound)
                    }
                    return
                }
            }
        }

        if (
            -not [string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId) -and
            [DateTime]::UtcNow -ge $dialogState.PendingDeadline
        ) {
            $timedOutCommand = [string]$dialogState.PendingCommand
            $dialogState.TestAfterWrite = $false
            & $completePending $false "O TC001 demorou para responder. Tente novamente."
            if ($timedOutCommand -ne "test-sound") {
                $dialogState.HasDeviceState = $false
                $dialogState.DeviceSupported = $false
                $dialogState.Dirty = $false
                $stateValueLabel.Text = "Indisponivel"
            }
            & $updateInteractivity
            return
        }

        if (
            [string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId) -and
            $null -ne $status
        ) {
            $deviceSound = & $getProperty $status "deviceSound" $null
            $deviceState = [string](& $getProperty $deviceSound "state" "")
            if ($deviceState -in @("unsupported", "error") -or (& $getProperty $deviceSound "supported" $null) -eq $false) {
                [void](& $applyDeviceSnapshot $deviceSound)
            } elseif (-not $dialogState.Dirty -and $null -ne $deviceSound) {
                # Keep the dialog in sync when another authorized UI changes the
                # device while it is open, but never overwrite a local edit.
                [void](& $applyDeviceSnapshot $deviceSound)
            }
        }
        & $updateInteractivity
    })

    $form.add_Shown({
        $dialogState.LastBridgeRunning = & $isBridgeRunning
        if ($dialogState.LastBridgeRunning) {
            [void](& $startCommand "read-device-sound" ([ordered]@{}))
        } else {
            & $setUnavailable "O TC001 esta indisponivel. Aguarde a reconexao e tente novamente." "error"
        }
        $timer.Start()
    })
    $form.add_FormClosing({
        param($sender, $eventArgs)

        if (
            $eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing -and
            -not [string]::IsNullOrWhiteSpace([string]$dialogState.PendingRequestId)
        ) {
            $eventArgs.Cancel = $true
            & $setStatus "Aguarde o TC001 confirmar a operacao antes de fechar esta janela." "warning"
            return
        }
        $dialogState.Closing = $true
        $timer.Stop()
    })

    try {
        Apply-UlanziCurrentUiTheme -Control $form
        if ($null -ne $Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
        return [pscustomobject]@{
            Applied = [bool]$dialogState.Applied
            SoundEnabled = $dialogState.DeviceSoundEnabled
            BuzzerVolume = $dialogState.DeviceBuzzerVolume
            AudibleConfirmed = & $audibleConfirmationForCurrentSnapshot
        }
    } finally {
        $dialogState.Closing = $true
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
    }
}

function Show-UlanziConfigurationDialog {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $false)][ValidateSet("alerts", "behavior", "display", "connections", "advanced", "startup")][string]$InitialTab = "alerts",
        [Parameter(Mandatory = $false)][ValidateRange(5, 120)][int]$EditorTimeoutSeconds = 30
    )

    $Owner = Get-UlanziUsableDialogOwner -Owner $Owner

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $projectIdentityBytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ProjectRoot).ToUpperInvariant())
    $projectIdentityHash = [Security.Cryptography.SHA256]::Create()
    try {
        $projectIdentity = -join @($projectIdentityHash.ComputeHash($projectIdentityBytes) | Select-Object -First 8 | ForEach-Object { $_.ToString("x2") })
    } finally {
        $projectIdentityHash.Dispose()
    }
    $mutex = [Threading.Mutex]::new($false, "Local\UlanziLibreConfig-$currentSid-$projectIdentity")
    $ownsMutex = $false
    try {
        try {
            $ownsMutex = $mutex.WaitOne(0, $false)
        } catch [Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }
        if (-not $ownsMutex) {
            [void][Windows.Forms.MessageBox]::Show(
                "Outra janela de configuracoes ja esta aberta.",
                "Ulanzi Libre",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information
            )
            return [pscustomobject]@{ Saved = $false; Changed = $false }
        }

        $readResult = Invoke-UlanziConfigEditor -Command "read" -ProjectRoot $ProjectRoot -EnvPath $EnvPath
        $state = $readResult.state
        if (@($state.overriddenKeys).Count -gt 0) {
            $externalLabels = @{
                LOW_THRESHOLD_MGDL = "limite baixo"
                HIGH_THRESHOLD_MGDL = "limite alto"
                STALE_AFTER_MINUTES = "tempo ate SEM DADO"
                LIBRE_SENSOR_LIFETIME_DAYS = "duracao do sensor"
                POLL_INTERVAL_SECONDS = "frequencia de consulta"
                GLUCOSE_ALARM_ENABLED = "controle geral dos alarmes"
                GLUCOSE_ALARM_SOUND_PROFILE = "padrao dos avisos sonoros"
                GLUCOSE_ALARM_LOW_THRESHOLD_MGDL = "limite baixo para o som"
                GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL = "limite alto para o som"
                GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL = "limite da seta diagonal"
                GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL = "limite das setas para baixo"
                GLUCOSE_ALARM_DOUBLE_UP_ENABLED = "seta dupla para cima"
                GLUCOSE_ALARM_NO_DATA_ENABLED = "som de SEM DADO"
                GLUCOSE_ALARM_HYSTERESIS_MGDL = "distancia para rearmar"
                GLUCOSE_ALARM_COOLDOWN_MINUTES = "tempo minimo entre alarmes"
                GLUCOSE_ALARM_ON_STARTUP_EXTREME = "alarme na primeira leitura"
                GLUCOSE_ALARM_ON_RECOVERY_EXTREME = "alarme ao recuperar dados"
                GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS = "tentativas por rodada"
                GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS = "intervalo entre tentativas"
                WINDOWS_FALLBACK_ALERT_ENABLED = "aviso de contingencia do Windows"
                WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES = "espera do aviso de conexao"
            }
            $controlledLabels = @($state.overriddenKeys | ForEach-Object {
                if ($externalLabels.ContainsKey([string]$_)) { $externalLabels[[string]$_] } else { [string]$_ }
            })
            throw "Alguns ajustes sao controlados externamente pelo Windows e nao podem ser salvos nesta tela: $($controlledLabels -join ', '). Remova essas variaveis externas e abra a tela novamente."
        }
        $values = $state.values

        $form = [Windows.Forms.Form]::new()
        $form.Name = "UlanziSettingsForm"
        $form.Text = "Configuracoes - Ulanzi Libre"
        $form.ClientSize = [Drawing.Size]::new(780, 680)
        $form.MinimumSize = [Drawing.Size]::new(720, 640)
        $form.StartPosition = if ($null -ne $Owner) {
            [Windows.Forms.FormStartPosition]::CenterParent
        } else {
            [Windows.Forms.FormStartPosition]::CenterScreen
        }
        $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::Sizable
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ShowInTaskbar = ($null -eq $Owner)
        $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
        $form.Font = [Drawing.Font]::new("Segoe UI", 9)
        $form.BackColor = [Drawing.ColorTranslator]::FromHtml("#F5F7F8")
        $setIconCommand = Get-Command Set-UlanziUiApplicationIcon -ErrorAction SilentlyContinue
        if ($null -ne $setIconCommand) {
            [void](& $setIconCommand -Form $form -ProjectRoot $ProjectRoot)
        }
        $form.Tag = [pscustomobject]@{ Saved = $false; Changed = $false }
        $settingsState = [pscustomobject]@{
            Dirty = $false
            Saving = $false
            AllowClose = $false
            Revision = [string]$state.revision
            PendingEditor = $null
            PendingStage = $null
            PendingDeadline = [DateTime]::MinValue
            PendingValues = $null
            PendingWriteResult = $null
        }

        $header = [Windows.Forms.Panel]::new()
        $header.Dock = [Windows.Forms.DockStyle]::Top
        $header.Height = 76
        $header.BackColor = [Drawing.ColorTranslator]::FromHtml("#173A4D")
        $header.Tag = "Header"
        $title = [Windows.Forms.Label]::new()
        $title.Text = "Configuracoes"
        $title.AutoSize = $true
        $title.Location = [Drawing.Point]::new(20, 13)
        $title.Font = [Drawing.Font]::new("Segoe UI", 17, [Drawing.FontStyle]::Bold)
        $title.ForeColor = [Drawing.Color]::White
        $subtitle = [Windows.Forms.Label]::new()
        $subtitle.Text = "Alertas, tela, sensor e conexoes organizados por assunto."
        $subtitle.AutoSize = $true
        $subtitle.Location = [Drawing.Point]::new(22, 48)
        $subtitle.ForeColor = [Drawing.ColorTranslator]::FromHtml("#D4E7EF")
        $subtitle.Tag = "HeaderMuted"
        $header.Controls.Add($title)
        $header.Controls.Add($subtitle)

        $footer = [Windows.Forms.Panel]::new()
        $footer.Dock = [Windows.Forms.DockStyle]::Bottom
        # Inicialize a largura real antes de adicionar os botoes ancorados.
        # Caso contrario, o WinForms calcula a ancora usando os 200 px padrao
        # do Panel e "Salvar e aplicar" fica inteiramente fora da tela.
        $footer.Size = [Drawing.Size]::new($form.ClientSize.Width, 106)
        $footer.BackColor = [Drawing.Color]::White

        $safetyLabel = [Windows.Forms.Label]::new()
        $safetyLabel.Text = "Estas opcoes controlam apenas o visor e os alertas; nao sao recomendacoes de tratamento."
        $safetyLabel.AutoSize = $true
        $safetyLabel.Location = [Drawing.Point]::new(18, 11)
        $safetyLabel.ForeColor = [Drawing.Color]::DimGray

        $statusLabel = [Windows.Forms.Label]::new()
        $statusLabel.Text = "Altere os valores e use Salvar e aplicar para confirmar."
        $statusLabel.AutoSize = $true
        $statusLabel.Location = [Drawing.Point]::new(18, 37)
        $statusLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
        $statusLabel.AccessibleName = "Estado do salvamento"

        $saveProgress = [Windows.Forms.ProgressBar]::new()
        $saveProgress.Location = [Drawing.Point]::new(18, 56)
        $saveProgress.Size = [Drawing.Size]::new(742, 4)
        $saveProgress.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
        $saveProgress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
        $saveProgress.MarqueeAnimationSpeed = 0
        $saveProgress.Visible = $false
        $saveProgress.TabStop = $false
        $saveProgress.AccessibleName = "Progresso do salvamento da configuracao"
        $saveProgress.AccessibleDescription = "Nenhum salvamento esta em andamento."

        $saveButton = [Windows.Forms.Button]::new()
        $saveButton.Name = "saveSettingsButton"
        $saveButton.Text = "Salvar e aplicar"
        $saveButton.Size = [Drawing.Size]::new(150, 32)
        $saveButton.Anchor = [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
        $saveButton.Location = [Drawing.Point]::new(610, 64)
        $saveButton.BackColor = [Drawing.ColorTranslator]::FromHtml("#167A91")
        $saveButton.ForeColor = [Drawing.Color]::White
        $saveButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $saveButton.FlatAppearance.BorderSize = 0
        $saveButton.Tag = "Accent"

        $cancelButton = [Windows.Forms.Button]::new()
        $cancelButton.Name = "cancelSettingsButton"
        $cancelButton.Text = "Cancelar"
        $cancelButton.Size = [Drawing.Size]::new(92, 32)
        $cancelButton.Anchor = [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
        $cancelButton.Location = [Drawing.Point]::new(508, 64)
        $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel

        $defaultsButton = [Windows.Forms.Button]::new()
        $defaultsButton.Name = "restoreRecommendedButton"
        $defaultsButton.Text = "Usar valores recomendados"
        $defaultsButton.Size = [Drawing.Size]::new(206, 32)
        $defaultsButton.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Bottom
        $defaultsButton.Location = [Drawing.Point]::new(18, 64)
        $defaultsButton.AccessibleDescription = "Restaura somente ajustes de funcionamento, preservando limites e escolhas pessoais."

        $footer.Controls.Add($safetyLabel)
        $footer.Controls.Add($statusLabel)
        $footer.Controls.Add($saveProgress)
        $footer.Controls.Add($saveButton)
        $footer.Controls.Add($cancelButton)
        $footer.Controls.Add($defaultsButton)

        $tabs = [Windows.Forms.TabControl]::new()
        $tabs.Name = "settingsTabs"
        $tabs.Dock = [Windows.Forms.DockStyle]::Fill
        $tabs.Padding = [Drawing.Point]::new(18, 6)
        $tabs.Font = [Drawing.Font]::new("Segoe UI", 9)
        $tabs.ShowToolTips = $true

        $alarmsTab = [Windows.Forms.TabPage]::new("Alertas e som")
        $alarmsTab.Name = "alertsTab"
        $alarmsTab.ToolTipText = "Escolha quando os alertas tocam e quanto tempo duram."
        $alarmsTab.BackColor = [Drawing.Color]::White
        $alarmsTab.AutoScroll = $false
        $alarmsTable = New-UlanziSettingsTable
        $alarmsTab.Controls.Add($alarmsTable)
        Add-UlanziSection -Table $alarmsTable -Text "Geral"
        $alarmEnabledControl = Add-UlanziBooleanSetting -Table $alarmsTable -Title "Ativar alertas sonoros de glicemia" -Description "Liga os alertas desta aplicacao; o som geral do TC001 e controlado separadamente no painel." -Checked ([bool]$values.GLUCOSE_ALARM_ENABLED)
        Add-UlanziSection -Table $alarmsTable -Text "Valores de glicemia que disparam som (sempre em mg/dL)"
        $alarmLowControl = Add-UlanziNumberSetting -Table $alarmsTable -Title "Tocar quando estiver abaixo de" -Description "Limite pessoal para o alerta sonoro de glicemia baixa." -Minimum 20 -Maximum 300 -Value ([decimal]$values.GLUCOSE_ALARM_LOW_THRESHOLD_MGDL) -Unit "mg/dL" -DecimalPlaces 1
        $alarmHighControl = Add-UlanziNumberSetting -Table $alarmsTable -Title "Tocar quando estiver acima de" -Description "Limite pessoal para o alerta sonoro de glicemia alta." -Minimum 40 -Maximum 600 -Value ([decimal]$values.GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL) -Unit "mg/dL" -DecimalPlaces 1
        [void](Add-UlanziInformation -Table $alarmsTable -Height 54 -Text "Esses limites controlam o som. As cores do TC001 sao ajustadas separadamente em 'Tela e sensor'.")
        Add-UlanziSection -Table $alarmsTable -Text "Tendencia e falta de dados"
        $upSlightControl = Add-UlanziNumberSetting -Table $alarmsTable -Title "Seta diagonal para cima: tocar acima de" -Description "O limite e estrito: no valor exato o som nao toca." -Minimum 20 -Maximum 600 -Value ([decimal]$values.GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL) -Unit "mg/dL" -DecimalPlaces 1
        $downControl = Add-UlanziNumberSetting -Table $alarmsTable -Title "Setas para baixo: tocar abaixo de" -Description "Inclui seta para baixo e diagonal para baixo; no valor exato o som nao toca." -Minimum 20 -Maximum 600 -Value ([decimal]$values.GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL) -Unit "mg/dL" -DecimalPlaces 1
        $doubleUpControl = Add-UlanziBooleanSetting -Table $alarmsTable -Title "Tocar para seta dupla para cima" -Description "Avisa tambem quando a leitura indica uma subida muito rapida." -Checked ([bool]$values.GLUCOSE_ALARM_DOUBLE_UP_ENABLED)
        $noDataControl = Add-UlanziBooleanSetting -Table $alarmsTable -Title "Tocar uma vez ao entrar em SEM DADO" -Description "TROCAR e um aviso visual separado e nao usa este som." -Checked ([bool]$values.GLUCOSE_ALARM_NO_DATA_ENABLED)
        Add-UlanziSection -Table $alarmsTable -Text "Duracao do aviso"
        $profileKeys = @("discreet", "normal", "reinforced")
        $profileLabels = @("Discreto (~0,6 s)", "Normal (~1,2 s)", "Reforcado (~2,1 s)")
        $profileValue = [string]$values.GLUCOSE_ALARM_SOUND_PROFILE
        $profileIndex = [Array]::IndexOf($profileKeys, $profileValue)
        if ($profileIndex -lt 0) { $profileIndex = 1 }
        $soundProfileControl = Add-UlanziChoiceSetting -Table $alarmsTable -Title "Duracao do toque" -Description "Escolha um aviso curto, normal ou reforcado." -Options $profileLabels -SelectedIndex $profileIndex
        $soundProfileControl.Name = "soundProfileControl"
        [void](Add-UlanziInformation -Table $alarmsTable -Height 52 -Text "O som geral do relogio pode ser ligado ou desligado em Alertas > Configurar som no painel.")
        Complete-UlanziSettingsTable -Table $alarmsTable
        Connect-UlanziSettingsScrolling -Tab $alarmsTab -Table $alarmsTable

        $behaviorTab = [Windows.Forms.TabPage]::new("Comportamento")
        $behaviorTab.Name = "behaviorTab"
        $behaviorTab.ToolTipText = "Evite repeticoes e escolha o que acontece ao iniciar ou recuperar dados."
        $behaviorTab.BackColor = [Drawing.Color]::White
        $behaviorTab.AutoScroll = $false
        $behaviorTable = New-UlanziSettingsTable
        $behaviorTab.Controls.Add($behaviorTable)
        Add-UlanziSection -Table $behaviorTable -Text "Evitar sons repetidos"
        $hysteresisControl = Add-UlanziNumberSetting -Table $behaviorTable -Title "Folga para liberar um novo alerta" -Description "Exige afastar-se um pouco do limite antes de permitir outro som." -Minimum 0 -Maximum 30 -Value ([decimal]$values.GLUCOSE_ALARM_HYSTERESIS_MGDL) -Unit "mg/dL" -DecimalPlaces 1
        $cooldownControl = Add-UlanziNumberSetting -Table $behaviorTable -Title "Pausa antes de repetir o mesmo alerta" -Description "Nao muda a duracao do toque; evita repetir o aviso logo depois." -Minimum 0 -Maximum 1440 -Value ([decimal]$values.GLUCOSE_ALARM_COOLDOWN_MINUTES) -Unit "min" -DecimalPlaces 1
        $rearmLabel = Add-UlanziInformation -Table $behaviorTable -Text "" -Height 58
        Add-UlanziSection -Table $behaviorTable -Text "Ao abrir ou recuperar dados"
        $startupControl = Add-UlanziBooleanSetting -Table $behaviorTable -Title "Ao iniciar, tocar se a primeira leitura ja estiver baixa ou alta" -Description "Vale quando nao existe um historico de alarmes recente para restaurar." -Checked ([bool]$values.GLUCOSE_ALARM_ON_STARTUP_EXTREME)
        $recoveryControl = Add-UlanziBooleanSetting -Table $behaviorTable -Title "Ao recuperar de SEM DADO, tocar se voltar baixa ou alta" -Description "A recuperacao e tratada separadamente de uma leitura normal." -Checked ([bool]$values.GLUCOSE_ALARM_ON_RECOVERY_EXTREME)
        [void](Add-UlanziInformation -Table $behaviorTable -Height 50 -Text "O aplicativo preserva alertas ja confirmados para evitar repeticoes depois de reiniciar.")
        Complete-UlanziSettingsTable -Table $behaviorTable
        Connect-UlanziSettingsScrolling -Tab $behaviorTab -Table $behaviorTable

        $rangesTab = [Windows.Forms.TabPage]::new("Tela e sensor")
        $rangesTab.Name = "displayTab"
        $rangesTab.ToolTipText = "Ajuste as cores, a atualizacao da leitura e o sensor Libre."
        $rangesTab.BackColor = [Drawing.Color]::White
        $rangesTab.AutoScroll = $false
        $rangesTable = New-UlanziSettingsTable
        $rangesTab.Controls.Add($rangesTable)
        Add-UlanziSection -Table $rangesTable -Text "Cores e faixa visual no TC001 (sempre em mg/dL)"
        [void](Add-UlanziInformation -Table $rangesTable -Height 54 -Text "Estes valores mudam as cores exibidas; nao definem quando um alerta sonoro toca.")
        $lowControl = Add-UlanziNumberSetting -Table $rangesTable -Title "Mostrar como baixa abaixo de" -Description "Define apenas a faixa visual e a cor de glicemia baixa." -Minimum 20 -Maximum 300 -Value ([decimal]$values.LOW_THRESHOLD_MGDL) -Unit "mg/dL" -DecimalPlaces 1
        $highControl = Add-UlanziNumberSetting -Table $rangesTable -Title "Mostrar como alta acima de" -Description "Define apenas a faixa visual e a cor de glicemia alta." -Minimum 40 -Maximum 600 -Value ([decimal]$values.HIGH_THRESHOLD_MGDL) -Unit "mg/dL" -DecimalPlaces 1
        Add-UlanziSection -Table $rangesTable -Text "Atualizacao da leitura"
        $pollMinimum = if ([string]$state.source -eq "nightscout") { 30 } else { 10 }
        $pollControl = Add-UlanziNumberSetting -Table $rangesTable -Title "Buscar uma nova leitura a cada" -Description "Intervalos menores atualizam mais rapido, mas fazem mais requisicoes." -Minimum $pollMinimum -Maximum 3600 -Value ([decimal]$values.POLL_INTERVAL_SECONDS) -Unit "s"
        $staleControl = Add-UlanziNumberSetting -Table $rangesTable -Title "Mostrar SEM DADO depois de" -Description "Tempo sem uma leitura nova antes de considerar o valor desatualizado." -Minimum 2 -Maximum 240 -Value ([decimal]$values.STALE_AFTER_MINUTES) -Unit "min" -DecimalPlaces 1
        Add-UlanziSection -Table $rangesTable -Text "Sensor Libre"
        $sensorControl = Add-UlanziNumberSetting -Table $rangesTable -Title "Duracao deste modelo de sensor" -Description "Usada com Sensor Start/Change para mostrar TROCAR no final." -Minimum 1 -Maximum 30 -Value ([decimal]$values.LIBRE_SENSOR_LIFETIME_DAYS) -Unit "dias"
        $sensorInformation = if ([string]$state.source -eq "nightscout") {
            "O aviso TROCAR depende de o Nightscout registrar corretamente o inicio ou a troca do sensor."
        } else {
            "Disponivel somente quando a fonte configurada e Nightscout."
        }
        [void](Add-UlanziInformation -Table $rangesTable -Height 62 -Text $sensorInformation)
        if ([string]$state.source -ne "nightscout") { $sensorControl.Enabled = $false }
        Complete-UlanziSettingsTable -Table $rangesTable
        Connect-UlanziSettingsScrolling -Tab $rangesTab -Table $rangesTable

        $connectionTab = [Windows.Forms.TabPage]::new("Conexao e avisos")
        $connectionTab.Name = "connectionsTab"
        $connectionTab.ToolTipText = "Defina avisos no computador e a entrega dos alertas ao TC001."
        $connectionTab.BackColor = [Drawing.Color]::White
        $connectionTab.AutoScroll = $false
        $connectionTable = New-UlanziSettingsTable
        $connectionTab.Controls.Add($connectionTable)
        Add-UlanziSection -Table $connectionTable -Text "Avisos no computador"
        $windowsFallbackControl = Add-UlanziBooleanSetting -Table $connectionTable -Title "Avisar pelo Windows quando houver falha" -Description "Usa uma notificacao e som local se um alerta critico nao chegar ao TC001 ou uma conexao ficar indisponivel." -Checked ([bool]$values.WINDOWS_FALLBACK_ALERT_ENABLED)
        $windowsDelayControl = Add-UlanziNumberSetting -Table $connectionTable -Title "Esperar antes de avisar uma falha de conexao" -Description "Evita notificacoes causadas por interrupcoes muito curtas." -Minimum 1 -Maximum 60 -Value ([decimal]$values.WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES) -Unit "min"
        Add-UlanziSection -Table $connectionTable -Text "Entrega dos alertas ao TC001"
        $attemptsControl = Add-UlanziNumberSetting -Table $connectionTable -Title "Quantidade de tentativas seguidas" -Description "Se todas falharem, o alerta continua pendente e tenta outra rodada depois." -Minimum 1 -Maximum 5 -Value ([decimal]$values.GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS) -Unit "vezes"
        $retryControl = Add-UlanziNumberSetting -Table $connectionTable -Title "Intervalo para tentar novamente" -Description "Espera antes de uma nova tentativa; nao muda a duracao do toque." -Minimum 5 -Maximum 300 -Value ([decimal]$values.GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS) -Unit "s"
        $retryControl.Name = "deliveryRetrySecondsControl"
        Complete-UlanziSettingsTable -Table $connectionTable
        Connect-UlanziSettingsScrolling -Tab $connectionTab -Table $connectionTable

        [void]$tabs.TabPages.Add($alarmsTab)
        [void]$tabs.TabPages.Add($behaviorTab)
        [void]$tabs.TabPages.Add($rangesTab)
        [void]$tabs.TabPages.Add($connectionTab)
        $tabs.SelectedTab = switch ($InitialTab) {
            { $_ -in @("behavior", "startup") } { $behaviorTab; break }
            "display" { $rangesTab }
            { $_ -in @("connections", "advanced") } { $connectionTab; break }
            default { $alarmsTab }
        }

        $form.Controls.Add($tabs)
        $form.Controls.Add($footer)
        $form.Controls.Add($header)
        $form.AcceptButton = $saveButton
        $form.CancelButton = $cancelButton

        $errorProvider = [Windows.Forms.ErrorProvider]::new()
        $errorProvider.BlinkStyle = [Windows.Forms.ErrorBlinkStyle]::NeverBlink
        $errorProvider.ContainerControl = $form

        $alarmControls = @(
            $soundProfileControl,
            $alarmLowControl,
            $alarmHighControl,
            $upSlightControl,
            $downControl,
            $doubleUpControl,
            $noDataControl,
            $hysteresisControl,
            $cooldownControl,
            $attemptsControl,
            $retryControl,
            $startupControl,
            $recoveryControl
        )
        $updateAlarmControls = {
            foreach ($control in $alarmControls) { $control.Enabled = $alarmEnabledControl.Checked }
        }
        $updateWindowsFallbackControls = {
            $windowsDelayControl.Enabled = $windowsFallbackControl.Checked
        }
        $updateRearmSummary = {
            $margin = [decimal]$hysteresisControl.Value
            $rearmLabel.Text = if ($margin -le 0) {
                "Sem folga adicional: um novo alerta pode ser liberado assim que a leitura voltar ao limite."
            } else {
                "Com a folga de $margin mg/dL, um novo alerta so e liberado depois que a leitura se afasta do limite. Isso evita sons repetidos perto do mesmo valor."
            }
        }
        $alarmEnabledControl.add_CheckedChanged($updateAlarmControls)
        $windowsFallbackControl.add_CheckedChanged($updateWindowsFallbackControls)
        $alarmLowControl.add_ValueChanged($updateRearmSummary)
        $alarmHighControl.add_ValueChanged($updateRearmSummary)
        $upSlightControl.add_ValueChanged($updateRearmSummary)
        $downControl.add_ValueChanged($updateRearmSummary)
        $hysteresisControl.add_ValueChanged($updateRearmSummary)
        & $updateAlarmControls
        & $updateWindowsFallbackControls
        & $updateRearmSummary

        $markConfigurationDirty = ({
            if ($settingsState.Saving -or $settingsState.Dirty) { return }
            $settingsState.Dirty = $true
            $saveButton.Text = "Salvar e aplicar *"
            $statusLabel.Text = "Ha alteracoes nao salvas. Clique em Salvar e aplicar."
            $statusLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
        }).GetNewClosure()
        $numberControls = @(
            $alarmLowControl,
            $alarmHighControl,
            $upSlightControl,
            $downControl,
            $lowControl,
            $highControl,
            $sensorControl,
            $pollControl,
            $staleControl,
            $hysteresisControl,
            $cooldownControl,
            $attemptsControl,
            $windowsDelayControl
        )
        foreach ($control in $numberControls) {
            $control.add_ValueChanged($markConfigurationDirty)
            $control.add_TextChanged($markConfigurationDirty)
        }
        foreach ($control in @(
            $alarmEnabledControl,
            $doubleUpControl,
            $noDataControl,
            $windowsFallbackControl,
            $startupControl,
            $recoveryControl
        )) {
            $control.add_CheckedChanged($markConfigurationDirty)
        }
        $soundProfileControl.add_SelectedIndexChanged($markConfigurationDirty)
        $retryControl.add_ValueChanged($markConfigurationDirty)
        $retryControl.add_TextChanged($markConfigurationDirty)

        $setSavingUi = ({
            param(
                [Parameter(Mandatory = $true)][bool]$Busy,
                [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Message = ""
            )

            $settingsState.Saving = $Busy
            $form.UseWaitCursor = $Busy
            $tabs.Enabled = -not $Busy
            $saveButton.Enabled = -not $Busy
            $cancelButton.Enabled = -not $Busy
            $defaultsButton.Enabled = -not $Busy
            $saveProgress.Visible = $Busy
            $saveProgress.MarqueeAnimationSpeed = if ($Busy) { 26 } else { 0 }
            $saveProgress.AccessibleDescription = if ($Busy) {
                if ([string]::IsNullOrWhiteSpace($Message)) { "A configuracao esta sendo salva e conferida." } else { $Message }
            } else {
                "Nenhum salvamento esta em andamento."
            }
            if (-not [string]::IsNullOrWhiteSpace($Message)) {
                $statusLabel.Text = $Message
                $statusLabel.AccessibleDescription = $Message
            }
        }).GetNewClosure()

        $clearPendingEditor = ({
            if ($null -ne $settingsState.PendingEditor) {
                Stop-UlanziConfigEditorOperation -Operation $settingsState.PendingEditor
            }
            $settingsState.PendingEditor = $null
            $settingsState.PendingStage = $null
            $settingsState.PendingDeadline = [DateTime]::MinValue
        }).GetNewClosure()

        $failSaving = ({
            param([Parameter(Mandatory = $true)][string]$Message)

            & $clearPendingEditor
            $settingsState.PendingValues = $null
            $settingsState.PendingWriteResult = $null
            & $setSavingUi $false
            $statusLabel.Text = "Nao foi possivel concluir o salvamento. Revise a mensagem e tente novamente."
            $statusLabel.AccessibleDescription = $statusLabel.Text
            $statusLabel.ForeColor = [Drawing.Color]::Firebrick
            if (-not $form.IsDisposed -and -not $form.Disposing -and $form.IsHandleCreated) {
                [void](Show-UlanziOwnedMessageBox `
                    -Owner $form `
                    -Text $Message `
                    -Caption "Erro ao salvar configuracoes" `
                    -Buttons ([Windows.Forms.MessageBoxButtons]::OK) `
                    -Icon ([Windows.Forms.MessageBoxIcon]::Error))
            }
        }).GetNewClosure()

        $saveTimer = [Windows.Forms.Timer]::new()
        $saveTimer.Interval = 120
        $saveTimer.add_Tick(({
            if (-not $settingsState.Saving -or $null -eq $settingsState.PendingEditor) { return }

            $operation = $settingsState.PendingEditor
            try {
                if (-not $operation.Process.HasExited) {
                    if ([DateTime]::UtcNow -ge $settingsState.PendingDeadline) {
                        $stageLabel = if ($settingsState.PendingStage -eq "write") { "gravacao" } else { "conferencia" }
                        & $failSaving "A etapa de $stageLabel excedeu o tempo limite de $EditorTimeoutSeconds segundos. Nenhuma nova tentativa foi iniciada."
                    }
                    return
                }

                $completedStage = [string]$settingsState.PendingStage
                $settingsState.PendingEditor = $null
                $settingsState.PendingStage = $null
                $settingsState.PendingDeadline = [DateTime]::MinValue
                $response = Complete-UlanziConfigEditorOperation -Operation $operation

                if ($completedStage -eq "write") {
                    $settingsState.PendingWriteResult = $response
                    $settingsState.Revision = [string]$response.state.revision
                    $verificationMessage = "Etapa 2 de 2: relendo o arquivo e confirmando cada valor..."
                    $settingsState.PendingEditor = Start-UlanziConfigEditorOperation -Command "read" -ProjectRoot $ProjectRoot -EnvPath $EnvPath
                    $settingsState.PendingStage = "verify"
                    $settingsState.PendingDeadline = [DateTime]::UtcNow.AddSeconds($EditorTimeoutSeconds)
                    $statusLabel.Text = $verificationMessage
                    $statusLabel.AccessibleDescription = $verificationMessage
                    $saveProgress.AccessibleDescription = $verificationMessage
                    return
                }

                $verifiedValues = $response.state.values
                $unconfirmedKeys = [Collections.Generic.List[string]]::new()
                foreach ($key in $settingsState.PendingValues.Keys) {
                    $property = $verifiedValues.PSObject.Properties[$key]
                    if ($null -eq $property -or [string]$property.Value -cne [string]$settingsState.PendingValues[$key]) {
                        [void]$unconfirmedKeys.Add([string]$key)
                    }
                }
                if ($unconfirmedKeys.Count -gt 0) {
                    throw "O arquivo foi gravado, mas estes valores nao puderam ser confirmados pela releitura: $($unconfirmedKeys -join ', '). Abra a tela novamente antes de tentar outra alteracao."
                }

                $writeResult = $settingsState.PendingWriteResult
                $settingsState.PendingValues = $null
                $settingsState.PendingWriteResult = $null
                $settingsState.Dirty = $false
                $settingsState.AllowClose = $true
                & $setSavingUi $false
                $statusLabel.Text = "Salvamento confirmado. Fechando a janela..."
                $statusLabel.AccessibleDescription = $statusLabel.Text
                $form.Tag = [pscustomobject]@{
                    Saved = $true
                    Changed = [bool]$writeResult.changed
                    Revision = [string]$response.state.revision
                    SoundProfile = [string]$profileKeys[$soundProfileControl.SelectedIndex]
                    SoundProfileLabel = [string]$profileLabels[$soundProfileControl.SelectedIndex]
                }
                $saveTimer.Stop()
                $form.DialogResult = [Windows.Forms.DialogResult]::OK
                $form.Close()
            } catch {
                & $failSaving $_.Exception.Message
            }
        }).GetNewClosure())

        $form.add_FormClosing(({
            param($sender, $eventArgs)
            if ($settingsState.Saving) {
                if (
                    $eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing -and
                    -not $form.IsDisposed -and
                    -not $form.Disposing -and
                    $form.IsHandleCreated
                ) {
                    $eventArgs.Cancel = $true
                    $statusLabel.Text = "Aguarde o salvamento e a conferencia terminarem antes de fechar."
                    $statusLabel.AccessibleDescription = $statusLabel.Text
                    $statusLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
                } else {
                    $settingsState.AllowClose = $true
                }
                return
            }
            if ($settingsState.AllowClose -or -not $settingsState.Dirty) { return }
            if (
                $eventArgs.CloseReason -ne [Windows.Forms.CloseReason]::UserClosing -or
                $form.IsDisposed -or
                $form.Disposing -or
                -not $form.IsHandleCreated
            ) {
                $settingsState.AllowClose = $true
                return
            }
            $answer = Show-UlanziOwnedMessageBox `
                -Owner $form `
                -Text "Existem alteracoes que ainda nao foram salvas. Deseja descarta-las?" `
                -Caption "Alteracoes nao salvas" `
                -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
                -Icon ([Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                $eventArgs.Cancel = $true
            }
        }).GetNewClosure())

        $defaultsButton.add_Click({
            $answer = Show-UlanziOwnedMessageBox `
                -Owner $form `
                -Text "Usar os valores recomendados para os ajustes de funcionamento? Isso redefine atualizacao da leitura, controle de repeticao, tentativas de entrega e tempo de espera dos avisos do Windows. Limites pessoais, tipos de alerta, som geral, duracao do sensor e a escolha de ativar avisos do Windows serao preservados. Nada sera salvo ate voce clicar em Salvar e aplicar." `
                -Caption "Usar valores recomendados" `
                -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
                -Icon ([Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            $staleControl.Value = 15
            $pollControl.Value = 60
            $hysteresisControl.Value = 5
            $cooldownControl.Value = 5
            $attemptsControl.Value = 3
            $retryControl.Value = 30
            $windowsDelayControl.Value = 2
            $statusLabel.Text = "Valores recomendados carregados, mas ainda nao salvos. Revise e clique em Salvar e aplicar."
            $statusLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
        })

        $saveButton.add_Click({
            [void]$form.ValidateChildren()
            $errorProvider.Clear()
            $valid = $true
            $invalidTab = $null
            $invalidControl = $null
            if ($highControl.Value -le $lowControl.Value) {
                $message = "Na faixa visual, o limite alto deve ser maior que o limite baixo."
                $errorProvider.SetError($highControl, $message)
                $errorProvider.SetError($lowControl, $message)
                $valid = $false
                $invalidTab = $rangesTab
                $invalidControl = $highControl
            }
            if ($alarmHighControl.Value -le $alarmLowControl.Value) {
                $message = "Nos alertas sonoros, o limite alto deve ser maior que o limite baixo."
                $errorProvider.SetError($alarmHighControl, $message)
                $errorProvider.SetError($alarmLowControl, $message)
                $valid = $false
                if ($null -eq $invalidTab) {
                    $invalidTab = $alarmsTab
                    $invalidControl = $alarmHighControl
                }
            }
            if ([decimal]$pollControl.Value -ge ([decimal]$staleControl.Value * 60)) {
                $message = "A busca de novas leituras precisa ocorrer antes do tempo definido para mostrar SEM DADO."
                $errorProvider.SetError($pollControl, $message)
                $errorProvider.SetError($staleControl, $message)
                $valid = $false
                if ($null -eq $invalidTab) {
                    $invalidTab = $rangesTab
                    $invalidControl = $pollControl
                }
            }
            if (
                $alarmEnabledControl.Checked -and
                ([decimal]$hysteresisControl.Value * 2) -ge ([decimal]$alarmHighControl.Value - [decimal]$alarmLowControl.Value)
            ) {
                $message = "A folga deve ser menor que metade da distancia entre os limites sonoros."
                $errorProvider.SetError($hysteresisControl, $message)
                $valid = $false
                if ($null -eq $invalidTab) {
                    $invalidTab = $behaviorTab
                    $invalidControl = $hysteresisControl
                }
            }
            if (-not $valid) {
                $statusLabel.Text = "Revise os campos marcados antes de salvar."
                $statusLabel.ForeColor = [Drawing.Color]::Firebrick
                $tabs.SelectedTab = $invalidTab
                [void]$invalidControl.Focus()
                return
            }

            $newValues = [ordered]@{
                LOW_THRESHOLD_MGDL = [double]$lowControl.Value
                HIGH_THRESHOLD_MGDL = [double]$highControl.Value
                STALE_AFTER_MINUTES = [double]$staleControl.Value
                LIBRE_SENSOR_LIFETIME_DAYS = [int]$sensorControl.Value
                POLL_INTERVAL_SECONDS = [int]$pollControl.Value
                GLUCOSE_ALARM_ENABLED = [bool]$alarmEnabledControl.Checked
                GLUCOSE_ALARM_SOUND_PROFILE = [string]$profileKeys[$soundProfileControl.SelectedIndex]
                GLUCOSE_ALARM_LOW_THRESHOLD_MGDL = [double]$alarmLowControl.Value
                GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL = [double]$alarmHighControl.Value
                GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL = [double]$upSlightControl.Value
                GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL = [double]$downControl.Value
                GLUCOSE_ALARM_DOUBLE_UP_ENABLED = [bool]$doubleUpControl.Checked
                GLUCOSE_ALARM_NO_DATA_ENABLED = [bool]$noDataControl.Checked
                GLUCOSE_ALARM_HYSTERESIS_MGDL = [double]$hysteresisControl.Value
                GLUCOSE_ALARM_COOLDOWN_MINUTES = [double]$cooldownControl.Value
                GLUCOSE_ALARM_ON_STARTUP_EXTREME = [bool]$startupControl.Checked
                GLUCOSE_ALARM_ON_RECOVERY_EXTREME = [bool]$recoveryControl.Checked
                GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS = [int]$attemptsControl.Value
                GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS = [int]$retryControl.Value
                WINDOWS_FALLBACK_ALERT_ENABLED = [bool]$windowsFallbackControl.Checked
                WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES = [int]$windowsDelayControl.Value
            }

            $episodeKeys = @(
                "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL",
                "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL",
                "GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL",
                "GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL",
                "GLUCOSE_ALARM_DOUBLE_UP_ENABLED",
                "GLUCOSE_ALARM_NO_DATA_ENABLED",
                "GLUCOSE_ALARM_HYSTERESIS_MGDL",
                "GLUCOSE_ALARM_ON_STARTUP_EXTREME",
                "GLUCOSE_ALARM_ON_RECOVERY_EXTREME"
            )
            $episodeChanged = $false
            foreach ($key in $episodeKeys) {
                $oldValue = $values.PSObject.Properties[$key].Value
                if ([string]$oldValue -cne [string]$newValues[$key]) {
                    $episodeChanged = $true
                    break
                }
            }
            if ($episodeChanged) {
                $answer = Show-UlanziOwnedMessageBox `
                    -Owner $form `
                    -Text "Estas mudancas iniciam um novo acompanhamento dos episodios de alarme. Se a primeira leitura estiver baixa ou alta, ela podera tocar conforme a opcao da aba Comportamento. Deseja continuar?" `
                    -Caption "Reiniciar acompanhamento dos alarmes" `
                    -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
                    -Icon ([Windows.Forms.MessageBoxIcon]::Warning)
                if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            }

            if ($settingsState.Saving) { return }
            $savingMessage = "Etapa 1 de 2: validando, criando a copia de seguranca e salvando..."
            try {
                $settingsState.PendingValues = $newValues
                $settingsState.PendingWriteResult = $null
                & $setSavingUi $true $savingMessage
                $statusLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
                $request = [ordered]@{
                    revision = [string]$settingsState.Revision
                    values = $newValues
                }
                $settingsState.PendingEditor = Start-UlanziConfigEditorOperation -Command "write" -ProjectRoot $ProjectRoot -EnvPath $EnvPath -Request $request
                $settingsState.PendingStage = "write"
                $settingsState.PendingDeadline = [DateTime]::UtcNow.AddSeconds($EditorTimeoutSeconds)
                $saveTimer.Start()
            } catch {
                & $failSaving $_.Exception.Message
            }
        })

        try {
            Apply-UlanziCurrentUiTheme -Control $form
            $dialogResult = if ($null -ne $Owner) { $form.ShowDialog($Owner) } else { $form.ShowDialog() }
            $result = $form.Tag
            if ($dialogResult -ne [Windows.Forms.DialogResult]::OK) {
                return [pscustomobject]@{ Saved = $false; Changed = $false }
            }
            return $result
        } finally {
            $saveTimer.Stop()
            & $clearPendingEditor
            $saveTimer.Dispose()
            $errorProvider.Dispose()
            if (-not $form.IsDisposed) { $form.Dispose() }
        }
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
