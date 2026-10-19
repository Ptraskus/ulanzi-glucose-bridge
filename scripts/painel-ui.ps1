Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ui-language.ps1")

function Get-UlanziPanelProperty {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function ConvertTo-UlanziPanelDate {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [DateTime]::Parse([string]$Value).ToUniversalTime() } catch { return $null }
}

function Format-UlanziPanelAge {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    $date = ConvertTo-UlanziPanelDate -Value $Value
    if ($null -eq $date) { return (Get-UlanziText -Key 'horario desconhecido') }
    $seconds = [Math]::Max(0, [Math]::Floor(([DateTime]::UtcNow - $date).TotalSeconds))
    if ($seconds -lt 10) { return (Get-UlanziText -Key 'agora') }
    if ($seconds -lt 60) { return (Get-UlanziText -Key 'ha {0} segundos' -Arguments @(($([int]$seconds)))) }
    if ($seconds -lt 3600) {
        $minutes = [int][Math]::Floor($seconds / 60)
        return $(if ($minutes -eq 1) { (Get-UlanziText -Key 'ha 1 minuto') } else { (Get-UlanziText -Key 'ha {0} minutos' -Arguments @(($minutes))) })
    }
    if ($seconds -lt 86400) {
        $hours = [int][Math]::Floor($seconds / 3600)
        return $(if ($hours -eq 1) { (Get-UlanziText -Key 'ha 1 hora') } else { (Get-UlanziText -Key 'ha {0} horas' -Arguments @(($hours))) })
    }
    $days = [int][Math]::Floor($seconds / 86400)
    return $(if ($days -eq 1) { (Get-UlanziText -Key 'ha 1 dia') } else { (Get-UlanziText -Key 'ha {0} dias' -Arguments @(($days))) })
}

function New-UlanziPanelLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $false)][float]$Size = 9,
        [Parameter(Mandatory = $false)][switch]$Bold,
        [Parameter(Mandatory = $false)][string]$Role = "Text"
    )

    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [Drawing.Point]::new($X, $Y)
    $label.Size = [Drawing.Size]::new($Width, $Height)
    $label.AutoEllipsis = $true
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = [Drawing.Font]::new("Segoe UI", $Size, $style)
    $label.Tag = $Role
    return $label
}

function New-UlanziPanelButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $false)][int]$Width = 150,
        [Parameter(Mandatory = $false)][string]$Role = "Surface"
    )

    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Size = [Drawing.Size]::new($Width, 36)
    $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.Tag = $Role
    $button.AccessibleName = $Text
    return $button
}

function Get-UlanziPanelConfigurationStamp {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath
    )

    $parts = [Collections.Generic.List[string]]::new()
    foreach ($path in @($EnvPath, (Join-Path $ProjectRoot ".secrets\vault.json"))) {
        try {
            if ([IO.File]::Exists($path)) {
                $file = [IO.FileInfo]::new($path)
                $parts.Add("$($file.FullName)|$($file.LastWriteTimeUtc.Ticks)|$($file.Length)")
            } else {
                $parts.Add("$([IO.Path]::GetFullPath($path))|missing")
            }
        } catch {
            $parts.Add("$path|unknown")
        }
    }
    return $parts -join ";"
}

function New-UlanziGlucoseMark {
    $mark = [Windows.Forms.Panel]::new()
    $mark.Location = [Drawing.Point]::new(20, 15)
    $mark.Size = [Drawing.Size]::new(46, 54)
    $mark.Tag = @{ PreserveColors = $true }
    $mark.AccessibleName = (Get-UlanziText -Key 'Simbolo de glicose e tendencia')
    $mark.AccessibleDescription = (Get-UlanziText -Key 'Uma gota com uma linha de tendencia, identidade visual do Ulanzi Glucose.')
    $mark.add_Paint(({
        param($sender, $eventArgs)
        try {
            $graphics = $eventArgs.Graphics
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $dropPen = [Drawing.Pen]::new($sender.ForeColor, 2.4)
            $trendPen = [Drawing.Pen]::new($sender.ForeColor, 2.1)
            $trendPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
            $trendPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
            $path = [Drawing.Drawing2D.GraphicsPath]::new()
            try {
                $dropPoints = [Drawing.PointF[]]@(
                    [Drawing.PointF]::new(23, 3),
                    [Drawing.PointF]::new(39, 25),
                    [Drawing.PointF]::new(36, 40),
                    [Drawing.PointF]::new(23, 48),
                    [Drawing.PointF]::new(10, 40),
                    [Drawing.PointF]::new(7, 25)
                )
                $path.AddClosedCurve($dropPoints, 0.42)
                $graphics.DrawPath($dropPen, $path)
                $trendPoints = [Drawing.PointF[]]@(
                    [Drawing.PointF]::new(13, 33),
                    [Drawing.PointF]::new(19, 29),
                    [Drawing.PointF]::new(25, 34),
                    [Drawing.PointF]::new(33, 24)
                )
                $graphics.DrawLines($trendPen, $trendPoints)
            } finally {
                $path.Dispose()
                $trendPen.Dispose()
                $dropPen.Dispose()
            }
        } catch {
            # O simbolo e decorativo; uma falha de desenho nunca deve afetar o painel.
        }
    }).GetNewClosure())
    return $mark
}

function New-UlanziPanelCard {
    param([Parameter(Mandatory = $true)][string]$Title)

    $panel = [Windows.Forms.Panel]::new()
    $panel.Dock = [Windows.Forms.DockStyle]::Fill
    $panel.Margin = [Windows.Forms.Padding]::new(6)
    $panel.Tag = "Elevated"
    $panel.AccessibleName = (Get-UlanziText -Key 'Cartao {0}' -Arguments @(($Title)))
    $panel.AccessibleRole = [Windows.Forms.AccessibleRole]::Grouping

    $indicator = [Windows.Forms.Panel]::new()
    $indicator.Dock = [Windows.Forms.DockStyle]::Left
    $indicator.Width = if ($Title -like (Get-UlanziText -Key 'Leitura*')) { 6 } else { 4 }
    $indicator.Tag = @{ PreserveColors = $true }
    $indicator.AccessibleName = (Get-UlanziText -Key 'Indicador de estado de {0}' -Arguments @(($Title)))

    $cardBody = [Windows.Forms.Panel]::new()
    $cardBody.Dock = [Windows.Forms.DockStyle]::Fill
    $cardBody.Padding = [Windows.Forms.Padding]::new(14, 10, 14, 10)
    $cardBody.Tag = "Elevated"

    $titleLabel = [Windows.Forms.Label]::new()
    $titleLabel.Text = $Title
    $titleLabel.Dock = [Windows.Forms.DockStyle]::Top
    $titleLabel.Height = 23
    $titleLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $titleLabel.Tag = "Muted"

    $valueLabel = [Windows.Forms.Label]::new()
    $valueLabel.Text = (Get-UlanziText -Key 'Aguardando...')
    $valueLabel.Dock = [Windows.Forms.DockStyle]::Top
    $valueLabel.Height = 34
    $valueLabel.Font = [Drawing.Font]::new("Segoe UI", 13, [Drawing.FontStyle]::Bold)
    $valueLabel.AutoEllipsis = $true
    $valueLabel.Tag = "Warning"

    $detailLabel = [Windows.Forms.Label]::new()
    $detailLabel.Text = ""
    $detailLabel.Dock = [Windows.Forms.DockStyle]::Fill
    $detailLabel.Font = [Drawing.Font]::new("Segoe UI", 8.5)
    $detailLabel.AutoEllipsis = $true
    $detailLabel.Tag = "Muted"

    $cardBody.Controls.Add($detailLabel)
    $cardBody.Controls.Add($valueLabel)
    $cardBody.Controls.Add($titleLabel)
    $panel.Controls.Add($cardBody)
    $panel.Controls.Add($indicator)
    return [pscustomobject]@{
        Panel = $panel
        Value = $valueLabel
        Detail = $detailLabel
        Indicator = $indicator
        Level = "warning"
    }
}

function New-UlanziPanelFeature {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.Control]$Parent,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$ButtonText,
        [Parameter(Mandatory = $true)][scriptblock]$Click,
        [Parameter(Mandatory = $false)][ValidateSet("Surface", "Accent")][string]$ButtonRole = "Surface",
        [Parameter(Mandatory = $false)][string]$SecondaryButtonText,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$SecondaryClick = $null
    )

    $panel = [Windows.Forms.Panel]::new()
    $panel.Location = [Drawing.Point]::new(24, $Y)
    $panel.Size = [Drawing.Size]::new(700, 104)
    $panel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $panel.Tag = "Elevated"
    $titleLabel = New-UlanziPanelLabel -Text $Title -X 16 -Y 12 -Width 420 -Height 24 -Size 10 -Bold
    $descriptionLabel = New-UlanziPanelLabel -Text $Description -X 16 -Y 40 -Width 430 -Height 50 -Role "Muted"
    $button = New-UlanziPanelButton -Text $ButtonText -Width 170 -Role $ButtonRole
    $button.Location = [Drawing.Point]::new(510, 18)
    $button.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $button.add_Click($Click)
    $panel.Controls.Add($titleLabel)
    $panel.Controls.Add($descriptionLabel)
    $panel.Controls.Add($button)
    if (-not [string]::IsNullOrWhiteSpace($SecondaryButtonText) -and $null -ne $SecondaryClick) {
        $secondary = New-UlanziPanelButton -Text $SecondaryButtonText -Width 170
        $secondary.Location = [Drawing.Point]::new(510, 58)
        $secondary.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
        $secondary.add_Click($SecondaryClick)
        $panel.Controls.Add($secondary)
    }
    $Parent.Controls.Add($panel)
    return [pscustomobject]@{ Panel = $panel; PrimaryButton = $button }
}

function New-UlanziControlPanel {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][scriptblock]$ReadStatus,
        [Parameter(Mandatory = $true)][scriptblock]$BridgeHealth,
        [Parameter(Mandatory = $true)][scriptblock]$OpenSettings,
        [Parameter(Mandatory = $true)][scriptblock]$OpenVolume,
        [Parameter(Mandatory = $true)][scriptblock]$RequestSoundTest,
        [Parameter(Mandatory = $true)][scriptblock]$OpenDiagnostics,
        [Parameter(Mandatory = $true)][scriptblock]$OpenMaintenance,
        [Parameter(Mandatory = $true)][scriptblock]$OpenNightscout,
        [Parameter(Mandatory = $true)][scriptblock]$OpenFolder,
        [Parameter(Mandatory = $true)][scriptblock]$RestartBridge,
        [Parameter(Mandatory = $true)][scriptblock]$ToggleWidget,
        [Parameter(Mandatory = $true)][scriptblock]$GetWidgetVisible,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$GetSetupState = $null,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$StartSetup = $null,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock]$OnClosed = $null,
        [Parameter(Mandatory = $false)][AllowNull()][string]$PreferenceRoot = $null
    )

    $form = [Windows.Forms.Form]::new()
    $form.Text = (Get-UlanziText -Key 'Painel do Ulanzi Glucose')
    $form.ClientSize = [Drawing.Size]::new(960, 680)
    $form.MinimumSize = [Drawing.Size]::new(940, 620)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::Sizable
    $form.MaximizeBox = $true
    $form.MinimizeBox = $true
    $form.ShowInTaskbar = $true
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = [Drawing.Font]::new("Segoe UI", 9)
    $form.KeyPreview = $true
    $form.Tag = "Window"
    [void](Set-UlanziUiApplicationIcon -Form $form -ProjectRoot $ProjectRoot)

    $state = [pscustomobject]@{
        Closing = $false
        TickBusy = $false
        ActionBusy = $false
        BusyDepth = 0
        RuntimeBusy = $false
        RuntimeBusyMessage = ""
        SetupState = "ready"
        ActivePage = "overview"
        Theme = "system"
        ResolvedTheme = ""
        Palette = $null
        ConfigurationLoaded = $false
        ConfigurationStamp = ""
        ConfigurationOperation = $null
        ConfigurationDeadline = [DateTime]::MinValue
        NextThemeCheckAt = [DateTime]::MinValue
        LiveUpdatesSuspended = $false
        LastStatus = $null
        BeginBusy = $null
        EndBusy = $null
        RefreshPalette = $null
        InvokeAction = $null
        SetCard = $null
        RefreshWidgetText = $null
        RefreshConfiguration = $null
        CompleteConfiguration = $null
        RefreshStatus = $null
        SelectPage = $null
    }

    $header = [Windows.Forms.Panel]::new()
    $header.Dock = [Windows.Forms.DockStyle]::Top
    $header.Width = $form.ClientSize.Width
    $header.Height = 88
    $header.Tag = "Header"
    $glucoseMark = New-UlanziGlucoseMark
    $title = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Painel do Ulanzi Glucose') -X 78 -Y 12 -Width 500 -Height 34 -Size 18 -Bold -Role "Text"
    $subtitle = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Glicose, alertas e conexoes em um unico lugar.') -X 80 -Y 50 -Width 520 -Height 24 -Role "HeaderMuted"
    $themeLabel = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Tema') -X 698 -Y 13 -Width 220 -Height 20 -Bold -Role "HeaderMuted"
    $themeLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $themeCombo = [Windows.Forms.ComboBox]::new()
    $themeCombo.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $themeCombo.Items.AddRange(@((Get-UlanziText -Key 'Usar tema do Windows'), (Get-UlanziText -Key 'Claro'), (Get-UlanziText -Key 'Escuro')))
    $themeCombo.Location = [Drawing.Point]::new(698, 37)
    $themeCombo.Size = [Drawing.Size]::new(230, 28)
    $themeCombo.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $themeCombo.Tag = "Input"
    $themeCombo.AccessibleName = (Get-UlanziText -Key 'Tema do painel')
    $header.Controls.Add($glucoseMark)
    $header.Controls.Add($title)
    $header.Controls.Add($subtitle)
    $header.Controls.Add($themeLabel)
    $header.Controls.Add($themeCombo)

    $footer = [Windows.Forms.Panel]::new()
    $footer.Dock = [Windows.Forms.DockStyle]::Bottom
    $footer.Width = $form.ClientSize.Width
    $footer.Height = 56
    $footer.Tag = "Surface"
    $footerProgress = [Windows.Forms.ProgressBar]::new()
    $footerProgress.Location = [Drawing.Point]::new(0, 0)
    $footerProgress.Size = [Drawing.Size]::new($form.ClientSize.Width, 4)
    $footerProgress.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $footerProgress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $footerProgress.MarqueeAnimationSpeed = 0
    $footerProgress.Visible = $false
    $footerProgress.TabStop = $false
    $footerProgress.AccessibleName = (Get-UlanziText -Key 'Carregamento do painel')
    $footerProgress.AccessibleDescription = (Get-UlanziText -Key 'Indica que uma configuracao ou operacao ainda esta sendo carregada.')
    $footerStatus = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Atualizacao automatica ativa.') -X 18 -Y 18 -Width 640 -Height 24 -Role "Muted"
    $footerStatus.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Top
    $footerStatus.AccessibleName = (Get-UlanziText -Key 'Estado do painel')
    $footerStatus.AccessibleRole = [Windows.Forms.AccessibleRole]::StatusBar
    $closeButton = New-UlanziPanelButton -Text (Get-UlanziText -Key 'Fechar') -Width 100
    $closeButton.Location = [Drawing.Point]::new(840, 10)
    $closeButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $footer.Controls.Add($footerProgress)
    $footer.Controls.Add($footerStatus)
    $footer.Controls.Add($closeButton)
    $languageButton = New-UlanziPanelButton -Text "Language / Idioma" -Width 155
    $languageButton.Name = "languageSettingsButton"
    $languageButton.Location = [Drawing.Point]::new(675, 10)
    $languageButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $languageButton.add_Click(({
        if ($state.SetupState -ne "ready" -and $null -ne $StartSetup) {
            & $state.InvokeAction $StartSetup @() (Get-UlanziText -Key 'Abrindo o assistente de configuracao...')
        } else {
            & $state.InvokeAction $OpenSettings @("display") (Get-UlanziText -Key 'Abrindo configuracoes de tela e sensor...')
        }
    }).GetNewClosure())
    $footer.Controls.Add($languageButton)

    $body = [Windows.Forms.Panel]::new()
    $body.Dock = [Windows.Forms.DockStyle]::Fill
    $body.Tag = "Window"
    $navigation = [Windows.Forms.Panel]::new()
    $navigation.Dock = [Windows.Forms.DockStyle]::Left
    $navigation.Width = 190
    $navigation.Padding = [Windows.Forms.Padding]::new(10, 16, 10, 10)
    $navigation.Tag = "Surface"
    $content = [Windows.Forms.Panel]::new()
    $content.Dock = [Windows.Forms.DockStyle]::Fill
    $content.Padding = [Windows.Forms.Padding]::new(0)
    $content.Tag = "Window"
    $body.Controls.Add($content)
    $body.Controls.Add($navigation)
    $form.Controls.Add($body)
    $form.Controls.Add($footer)
    $form.Controls.Add($header)

    $pages = @{}
    $initialPageSize = [Drawing.Size]::new(
        ($form.ClientSize.Width - $navigation.Width),
        ($form.ClientSize.Height - $header.Height - $footer.Height)
    )
    foreach ($pageName in @("overview", "alerts", "display", "connections", "support")) {
        $page = [Windows.Forms.Panel]::new()
        $page.Dock = [Windows.Forms.DockStyle]::Fill
        $page.AutoScroll = $true
        $page.Visible = $false
        $page.Tag = "Window"
        $pages[$pageName] = $page
        $content.Controls.Add($page)
        $page.Size = $initialPageSize
    }

    $navButtons = @{}
    $navigationItems = @(
        @("overview", (Get-UlanziText -Key 'Inicio')),
        @("alerts", (Get-UlanziText -Key 'Alertas')),
        @("display", (Get-UlanziText -Key 'Tela e sensor')),
        @("connections", (Get-UlanziText -Key 'Conexoes')),
        @("support", (Get-UlanziText -Key 'Suporte'))
    )
    for ($index = $navigationItems.Count - 1; $index -ge 0; $index--) {
        $pageName = [string]$navigationItems[$index][0]
        $button = New-UlanziPanelButton -Text ([string]$navigationItems[$index][1]) -Width 168 -Role "Surface"
        $button.Dock = [Windows.Forms.DockStyle]::Top
        $button.Height = 46
        $button.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 6)
        $button.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $button.Padding = [Windows.Forms.Padding]::new(12, 0, 0, 0)
        $button.Tag = "Surface"
        $button.Name = "nav-$pageName"
        $button.AccessibleDescription = (Get-UlanziText -Key 'Abrir a pagina {0}' -Arguments @(($($navigationItems[$index][1]))))
        $navButtons[$pageName] = $button
        $navigation.Controls.Add($button)
    }

    $overviewPage = $pages.overview
    $overviewHeading = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Inicio') -X 24 -Y 18 -Width 500 -Height 34 -Size 16 -Bold
    $overallLabel = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Aguardando o aplicativo...') -X 24 -Y 54 -Width 700 -Height 32 -Size 11 -Bold -Role "Warning"
    $overallLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $overviewPage.Controls.Add($overviewHeading)
    $overviewPage.Controls.Add($overallLabel)
    $cards = [Windows.Forms.TableLayoutPanel]::new()
    $cards.Location = [Drawing.Point]::new(18, 94)
    $cards.Size = [Drawing.Size]::new(724, 342)
    $cards.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $cards.ColumnCount = 2
    $cards.RowCount = 3
    $cards.Tag = "Window"
    [void]$cards.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 50))
    [void]$cards.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 50))
    for ($row = 0; $row -lt 3; $row++) { [void]$cards.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 33.333)) }
    $statusCards = [ordered]@{
        reading = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Leitura atual')
        alarms = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Alertas de glicose')
        source = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Fonte de glicemia')
        tc001 = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Envio ao TC001')
        application = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Aplicativo')
        volume = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Som do TC001')
    }
    $cardIndex = 0
    foreach ($card in $statusCards.Values) {
        [void]$cards.Controls.Add($card.Panel, ($cardIndex % 2), [Math]::Floor($cardIndex / 2))
        $cardIndex++
    }
    $overviewPage.Controls.Add($cards)

    $setupPanel = [Windows.Forms.Panel]::new()
    $setupPanel.Name = "firstRunPanel"
    $setupPanel.Location = [Drawing.Point]::new(24, 94)
    $setupPanel.Size = [Drawing.Size]::new(700, 286)
    $setupPanel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $setupPanel.Tag = "Elevated"
    $setupPanel.Visible = $false
    $setupPanel.AccessibleName = (Get-UlanziText -Key 'Primeira configuracao')
    $setupTitle = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Vamos configurar o Ulanzi Glucose') -X 24 -Y 22 -Width 620 -Height 34 -Size 15 -Bold
    $setupDescription = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Prepare o AWTRIX, conecte a fonte e teste o TC001 em um unico assistente. O aplicativo so comecara depois que tudo for salvo e conferido.') -X 24 -Y 64 -Width 640 -Height 50 -Size 10 -Role "Muted"
    $setupSteps = New-UlanziPanelLabel -Text (Get-UlanziText -Key '1. Preparar  2. AWTRIX  3. Fonte  4. Teste  5. TC001  6. Preferencias  7. Revisao') -X 24 -Y 126 -Width 640 -Height 30 -Size 9 -Role "Muted"
    $setupMessage = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'A configuracao inicial ainda nao foi concluida.') -X 24 -Y 166 -Width 640 -Height 32 -Size 10 -Bold -Role "Warning"
    $startSetupButton = New-UlanziPanelButton -Text (Get-UlanziText -Key 'Configurar agora') -Width 190 -Role "Accent"
    $startSetupButton.Name = "startSetupButton"
    $startSetupButton.Location = [Drawing.Point]::new(24, 216)
    $startSetupButton.AccessibleDescription = (Get-UlanziText -Key 'Abrir o assistente grafico de primeira configuracao')
    $setupPanel.Controls.Add($setupTitle)
    $setupPanel.Controls.Add($setupDescription)
    $setupPanel.Controls.Add($setupSteps)
    $setupPanel.Controls.Add($setupMessage)
    $setupPanel.Controls.Add($startSetupButton)
    $overviewPage.Controls.Add($setupPanel)
    $setupPanel.BringToFront()

    $alertsPage = $pages.alerts
    $alertsPage.Controls.Add((New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Alertas') -X 24 -Y 18 -Width 500 -Height 34 -Size 16 -Bold))
    $alertNotice = [Windows.Forms.Panel]::new()
    $alertNotice.Location = [Drawing.Point]::new(24, 60)
    $alertNotice.Size = [Drawing.Size]::new(700, 78)
    $alertNotice.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $alertNotice.Tag = "Elevated"
    $alertNoticeText = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Os alertas deste aplicativo sao complementares. Mantenha os alarmes oficiais do seu CGM e use os limites definidos com sua equipe de saude.') -X 14 -Y 13 -Width 665 -Height 52 -Role "Text"
    $alertNoticeText.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $alertNotice.Controls.Add($alertNoticeText)
    $alertsPage.Controls.Add($alertNotice)
    $alarmSummaryTitle = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Configuracao atual') -X 24 -Y 158 -Width 300 -Height 26 -Size 10 -Bold
    $alarmSummary = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Carregando os ajustes...') -X 24 -Y 190 -Width 700 -Height 100 -Size 10 -Role "Muted"
    $alarmSummary.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $alertsPage.Controls.Add($alarmSummaryTitle)
    $alertsPage.Controls.Add($alarmSummary)
    [void](New-UlanziPanelFeature -Parent $alertsPage -Y 306 -Title (Get-UlanziText -Key 'Alertas de glicose') -Description (Get-UlanziText -Key 'Defina limites, tendencias, falta de dados e a duracao dos avisos.') -ButtonText (Get-UlanziText -Key 'Configurar alertas') -ButtonRole "Accent" -Click ({ & $state.InvokeAction $OpenSettings @("alerts") (Get-UlanziText -Key 'Abrindo configuracoes de alertas...') }).GetNewClosure())
    [void](New-UlanziPanelFeature -Parent $alertsPage -Y 424 -Title (Get-UlanziText -Key 'Som do TC001') -Description (Get-UlanziText -Key 'Ative, silencie ou teste o som geral do relogio.') -ButtonText (Get-UlanziText -Key 'Configurar som') -Click ({ & $state.InvokeAction $OpenVolume @() (Get-UlanziText -Key 'Consultando o som geral do TC001...') }).GetNewClosure() -SecondaryButtonText (Get-UlanziText -Key 'Testar som') -SecondaryClick ({ & $state.InvokeAction $RequestSoundTest }).GetNewClosure())

    $displayPage = $pages.display
    $displayPage.Controls.Add((New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Tela e sensor') -X 24 -Y 18 -Width 500 -Height 34 -Size 16 -Bold))
    $displaySummary = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Carregando os ajustes...') -X 24 -Y 62 -Width 700 -Height 78 -Size 10 -Role "Muted"
    $displaySummary.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $displayPage.Controls.Add($displaySummary)
    $widgetFeature = New-UlanziPanelFeature -Parent $displayPage -Y 154 -Title (Get-UlanziText -Key 'Mostrador no computador') -Description (Get-UlanziText -Key 'Mostra a leitura perto do relogio do Windows. Esta escolha nao altera o TC001.') -ButtonText (Get-UlanziText -Key 'Mostrar ou ocultar') -Click ({ & $state.InvokeAction $ToggleWidget; & $state.RefreshWidgetText }).GetNewClosure()
    $widgetButton = $widgetFeature.PrimaryButton
    [void](New-UlanziPanelFeature -Parent $displayPage -Y 272 -Title (Get-UlanziText -Key 'Tela do TC001 e sensor') -Description (Get-UlanziText -Key 'Ajuste cores, atualizacao da leitura e duracao do sensor.') -ButtonText (Get-UlanziText -Key 'Configurar tela e sensor') -ButtonRole "Accent" -Click ({ & $state.InvokeAction $OpenSettings @("display") (Get-UlanziText -Key 'Abrindo configuracoes de tela e sensor...') }).GetNewClosure())

    $connectionsPage = $pages.connections
    $connectionsPage.Controls.Add((New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Conexoes') -X 24 -Y 18 -Width 500 -Height 34 -Size 16 -Bold))
    $connectionsIntro = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Confira separadamente a fonte, o horario e o ultimo envio ao TC001. Senhas e tokens nunca aparecem aqui.') -X 24 -Y 58 -Width 700 -Height 48 -Role "Muted"
    $connectionsIntro.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $connectionsPage.Controls.Add($connectionsIntro)
    $connectionSource = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Fonte de glicemia')
    $connectionClock = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Data e hora da leitura')
    $connectionTc001 = New-UlanziPanelCard -Title (Get-UlanziText -Key 'Envio ao TC001')
    $connectionSource.Panel.Dock = [Windows.Forms.DockStyle]::None
    $connectionClock.Panel.Dock = [Windows.Forms.DockStyle]::None
    $connectionTc001.Panel.Dock = [Windows.Forms.DockStyle]::None
    $connectionSource.Panel.Location = [Drawing.Point]::new(24, 118)
    $connectionClock.Panel.Location = [Drawing.Point]::new(24, 232)
    $connectionTc001.Panel.Location = [Drawing.Point]::new(24, 346)
    foreach ($connectionCard in @($connectionSource, $connectionClock, $connectionTc001)) {
        $connectionCard.Panel.Size = [Drawing.Size]::new(700, 100)
        $connectionCard.Panel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
        $connectionsPage.Controls.Add($connectionCard.Panel)
    }
    $connectionActions = [Windows.Forms.FlowLayoutPanel]::new()
    $connectionActions.Location = [Drawing.Point]::new(24, 470)
    $connectionActions.Size = [Drawing.Size]::new(700, 55)
    $connectionActions.Tag = "Window"
    $connectionActions.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $connectionsVerify = New-UlanziPanelButton -Text (Get-UlanziText -Key 'Verificar conexoes') -Width 170 -Role "Accent"
    $connectionsNightscout = New-UlanziPanelButton -Text (Get-UlanziText -Key 'Abrir Nightscout') -Width 150
    $connectionsReconfigure = New-UlanziPanelButton -Text (Get-UlanziText -Key 'Refazer configuracao') -Width 175
    $connectionsReconfigure.Name = "connectionsReconfigureButton"
    [void]$connectionActions.Controls.Add($connectionsVerify)
    [void]$connectionActions.Controls.Add($connectionsNightscout)
    [void]$connectionActions.Controls.Add($connectionsReconfigure)
    $connectionsPage.Controls.Add($connectionActions)

    $supportPage = $pages.support
    $supportPage.Controls.Add((New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Suporte e manutencao') -X 24 -Y 18 -Width 500 -Height 34 -Size 16 -Bold))
    $supportIntro = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Ferramentas para verificar, recuperar e atualizar o aplicativo sem expor credenciais ou leituras no relatorio.') -X 24 -Y 58 -Width 700 -Height 46 -Role "Muted"
    $supportIntro.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $supportPage.Controls.Add($supportIntro)
    [void](New-UlanziPanelFeature -Parent $supportPage -Y 116 -Title (Get-UlanziText -Key 'Diagnostico e suporte') -Description (Get-UlanziText -Key 'Teste cada conexao e exporte um relatorio higienizado quando precisar de ajuda.') -ButtonText (Get-UlanziText -Key 'Abrir diagnostico') -ButtonRole "Accent" -Click ({ & $state.InvokeAction $OpenDiagnostics @() (Get-UlanziText -Key 'Preparando o diagnostico...') }).GetNewClosure())
    [void](New-UlanziPanelFeature -Parent $supportPage -Y 234 -Title (Get-UlanziText -Key 'Atualizacoes e recuperacao') -Description (Get-UlanziText -Key 'Verifique atualizacoes assinadas ou restaure uma configuracao anterior valida.') -ButtonText (Get-UlanziText -Key 'Atualizar ou recuperar') -Click ({ & $state.InvokeAction $OpenMaintenance @() (Get-UlanziText -Key 'Carregando manutencao e recuperacao...') }).GetNewClosure())
    [void](New-UlanziPanelFeature -Parent $supportPage -Y 352 -Title (Get-UlanziText -Key 'Ferramentas avancadas') -Description (Get-UlanziText -Key 'Abra a pasta local para suporte ou reinicie somente a conexao em segundo plano.') -ButtonText (Get-UlanziText -Key 'Abrir pasta') -Click ({ & $state.InvokeAction $OpenFolder }).GetNewClosure() -SecondaryButtonText (Get-UlanziText -Key 'Reiniciar conexao') -SecondaryClick ({ & $state.InvokeAction $RestartBridge @() (Get-UlanziText -Key 'Reiniciando a conexao...') }).GetNewClosure())
    $version = (Get-UlanziText -Key 'versao desconhecida')
    try {
        $packageData = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot "package.json") | ConvertFrom-Json
        $version = (Get-UlanziText -Key 'versao {0}' -Arguments @(($([string]$packageData.version))))
    } catch { }
    $supportVersion = New-UlanziPanelLabel -Text (Get-UlanziText -Key 'Ulanzi Glucose Bridge - {0}. Consulte README, PRIVACY e SECURITY na pasta do aplicativo.' -Arguments @(($version))) -X 24 -Y 486 -Width 700 -Height 40 -Role "Muted"
    $supportVersion.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $supportPage.Controls.Add($supportVersion)

    $allCards = @($statusCards.Values) + @($connectionSource, $connectionClock, $connectionTc001)
    $readSetupState = ({
        if ($null -eq $GetSetupState) {
            return [pscustomobject]@{ State = "ready"; Message = (Get-UlanziText -Key 'Configuracao pronta.') }
        }
        try {
            $result = & $GetSetupState
            $setupState = [string](Get-UlanziPanelProperty -Object $result -Name "State" -DefaultValue "ready")
            if ($setupState -notin @("checking", "configuring", "required", "ready")) { $setupState = "required" }
            $setupText = [string](Get-UlanziPanelProperty -Object $result -Name "Message" -DefaultValue "")
            return [pscustomobject]@{ State = $setupState; Message = $setupText }
        } catch {
            return [pscustomobject]@{
                State = "required"
                Message = (Get-UlanziText -Key 'Nao foi possivel confirmar a configuracao. Tente abrir o assistente novamente.')
            }
        }
    }).GetNewClosure()

    $state.BeginBusy = ({
        param([string]$Message = (Get-UlanziText -Key 'Carregando...'))
        if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        $state.BusyDepth++
        if (-not [string]::IsNullOrWhiteSpace($Message) -and $footerStatus.Text -cne $Message) {
            $footerStatus.Text = $Message
        }
        $footerProgress.Visible = $true
        $footerProgress.MarqueeAnimationSpeed = 28
        $footerProgress.BringToFront()
        $navigation.Enabled = $false
        $content.Enabled = $false
        $form.UseWaitCursor = $true
        if ($form.IsHandleCreated) {
            $footer.Update()
            $form.Update()
        }
    }).GetNewClosure()

    $state.EndBusy = ({
        param([string]$Message = (Get-UlanziText -Key 'Atualizacao automatica ativa.'))
        if ($state.BusyDepth -gt 0) { $state.BusyDepth-- }
        if ($state.BusyDepth -gt 0 -or $state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        if ($state.RuntimeBusy) {
            $footerProgress.Visible = $true
            $navigation.Enabled = $false
            $content.Enabled = $false
            $form.UseWaitCursor = $false
            if (-not [string]::IsNullOrWhiteSpace([string]$state.RuntimeBusyMessage)) {
                $footerStatus.Text = [string]$state.RuntimeBusyMessage
            }
            return
        }
        $footerProgress.Visible = $false
        $footerProgress.MarqueeAnimationSpeed = 0
        $navigation.Enabled = $true
        $content.Enabled = $true
        $form.UseWaitCursor = $false
        if (-not [string]::IsNullOrWhiteSpace($Message) -and $footerStatus.Text -cne $Message) {
            $footerStatus.Text = $Message
        }
    }).GetNewClosure()

    $state.RefreshPalette = ({
        $resolved = Resolve-UlanziUiTheme -Theme $state.Theme
        $state.ResolvedTheme = [string](Get-UlanziPanelProperty -Object $resolved -Name "EffectiveMode" -DefaultValue (Get-UlanziPanelProperty -Object $resolved -Name "Theme" -DefaultValue $resolved))
        $state.NextThemeCheckAt = [DateTime]::UtcNow.AddSeconds(7)
        $state.Palette = Get-UlanziUiPalette -Theme $state.Theme -PreferenceRoot $PreferenceRoot
        $glucoseMark.BackColor = $state.Palette.Header
        $glucoseMark.ForeColor = $state.Palette.Accent
        $glucoseMark.Invalidate()
        foreach ($card in $allCards) {
            $role = switch ([string]$card.Level) { "ok" { "Success" }; "error" { "Error" }; default { "Warning" } }
            Set-UlanziUiControlRole -Control $card.Value -Palette $state.Palette -Role $role
            $card.Indicator.BackColor = switch ([string]$card.Level) {
                "ok" { $state.Palette.Success }
                "error" { $state.Palette.Error }
                default { $state.Palette.Warning }
            }
        }
        foreach ($name in $navButtons.Keys) {
            $role = if ($name -eq $state.ActivePage) { "Accent" } else { "Surface" }
            $navButtons[$name].Tag = $role
            Set-UlanziUiControlRole -Control $navButtons[$name] -Palette $state.Palette -Role $role
        }
        $overallLabel.ForeColor = switch ([string]$overallLabel.Tag) {
            "Success" { $state.Palette.Success }
            "Error" { $state.Palette.Error }
            default { $state.Palette.Warning }
        }
    }).GetNewClosure()

    $state.InvokeAction = ({
        param(
            [AllowNull()][scriptblock]$Action,
            [Parameter(Mandatory = $false)][object[]]$ActionArguments = @(),
            [Parameter(Mandatory = $false)][string]$BusyMessage = ""
        )
        if ($null -eq $Action -or $state.Closing -or $state.ActionBusy) { return }
        $showBusy = -not [string]::IsNullOrWhiteSpace($BusyMessage)
        try {
            $state.ActionBusy = $true
            if ($showBusy) { & $state.BeginBusy $BusyMessage }
            & $Action $form @ActionArguments
        } catch {
            if ($state.Closing -or $form.IsDisposed -or $form.Disposing -or -not $form.IsHandleCreated) { return }
            [void](Show-UlanziOwnedMessageBox `
                -Owner $form `
                -Text $_.Exception.Message `
                -Caption "Ulanzi Glucose" `
                -Buttons ([Windows.Forms.MessageBoxButtons]::OK) `
                -Icon ([Windows.Forms.MessageBoxIcon]::Error))
        } finally {
            $state.ActionBusy = $false
            if (-not $state.Closing -and -not $form.IsDisposed -and -not $form.Disposing) {
                $form.Activate()
                if ($null -ne $state.RefreshConfiguration -and $state.ActivePage -in @("alerts", "display")) {
                    & $state.RefreshConfiguration
                }
                if ($null -ne $state.RefreshStatus) { & $state.RefreshStatus }
            }
            if ($showBusy -and $null -ne $state.EndBusy) { & $state.EndBusy (Get-UlanziText -Key 'Atualizacao automatica ativa.') }
        }
    }).GetNewClosure()

    $state.SetCard = ({
        param([object]$Card, [string]$Value, [string]$Detail, [ValidateSet("ok", "warning", "error")][string]$Level)
        $role = switch ($Level) { "ok" { "Success" }; "error" { "Error" }; default { "Warning" } }
        if ($Card.Value.Text -cne $Value) { $Card.Value.Text = $Value }
        if ([string]$Card.Value.Tag -cne $role) { $Card.Value.Tag = $role }
        if ($Card.Detail.Text -cne $Detail) { $Card.Detail.Text = $Detail }
        if ([string]$Card.Level -cne $Level) { $Card.Level = $Level }
        if ($null -ne $state.Palette) {
            $color = switch ($Level) {
                "ok" { $state.Palette.Success }
                "error" { $state.Palette.Error }
                default { $state.Palette.Warning }
            }
            if ($Card.Value.ForeColor.ToArgb() -ne $color.ToArgb()) { $Card.Value.ForeColor = $color }
            if ($Card.Indicator.BackColor.ToArgb() -ne $color.ToArgb()) { $Card.Indicator.BackColor = $color }
        }
        $accessibleDescription = (Get-UlanziText -Key 'Estado: {0}. {1}' -Arguments @(($Value), ($Detail)))
        if ($Card.Indicator.AccessibleDescription -cne $accessibleDescription) {
            $Card.Indicator.AccessibleDescription = $accessibleDescription
        }
    }).GetNewClosure()

    $state.RefreshWidgetText = ({
        $visible = ((& $GetWidgetVisible) -eq $true)
        $newText = if ($visible) { (Get-UlanziText -Key 'Ocultar mostrador') } else { (Get-UlanziText -Key 'Mostrar mostrador') }
        if ($widgetButton.Text -cne $newText) { $widgetButton.Text = $newText }
    }).GetNewClosure()

    $configurationTimer = [Windows.Forms.Timer]::new()
    $configurationTimer.Interval = 120

    $applyConfigurationResult = ({
        param([object]$ReadResult)
        $values = $ReadResult.state.values
        $alarmEnabled = [bool]$values.GLUCOSE_ALARM_ENABLED
        $alarmLow = Get-UlanziPanelProperty -Object $values -Name "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL" -DefaultValue $values.LOW_THRESHOLD_MGDL
        $alarmHigh = Get-UlanziPanelProperty -Object $values -Name "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL" -DefaultValue $values.HIGH_THRESHOLD_MGDL
        $soundProfile = switch ([string](Get-UlanziPanelProperty -Object $values -Name "GLUCOSE_ALARM_SOUND_PROFILE" -DefaultValue "normal")) {
            "discreet" { (Get-UlanziText -Key 'Discreto (~0,6 s)') }
            "reinforced" { (Get-UlanziText -Key 'Reforcado (~2,1 s)') }
            default { (Get-UlanziText -Key 'Normal (~1,2 s)') }
        }
        $types = [Collections.Generic.List[string]]::new()
        $types.Add((Get-UlanziText -Key 'baixa abaixo de {0} mg/dL' -Arguments @(($alarmLow))))
        $types.Add((Get-UlanziText -Key 'alta acima de {0} mg/dL' -Arguments @(($alarmHigh))))
        $types.Add((Get-UlanziText -Key 'seta diagonal acima de {0} mg/dL' -Arguments @(($($values.GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL)))))
        $types.Add((Get-UlanziText -Key 'setas para baixo abaixo de {0} mg/dL' -Arguments @(($($values.GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL)))))
        if ([bool]$values.GLUCOSE_ALARM_DOUBLE_UP_ENABLED) { $types.Add((Get-UlanziText -Key 'seta dupla para cima')) }
        if ([bool]$values.GLUCOSE_ALARM_NO_DATA_ENABLED) { $types.Add((Get-UlanziText -Key 'perda de dados')) }
        $newAlarmSummary = if ($alarmEnabled) {
            (Get-UlanziText -Key 'Alertas ligados, duracao {0}. Serao avisados: {1}.' -Arguments @(($soundProfile), ($($types -join '; '))))
        } else {
            (Get-UlanziText -Key 'Alertas sonoros deste aplicativo estao desligados. A faixa visual continua ativa e nao produz som.')
        }
        $sensorEstimate = if ([decimal]$values.SENSOR_LIFETIME_DAYS -eq 0) { (Get-UlanziText -Key 'Estimativa do sensor desativada') } else { (Get-UlanziText -Key 'Estimativa do sensor: {0} dias' -Arguments @($values.SENSOR_LIFETIME_DAYS)) }
        $newDisplaySummary = (Get-UlanziText -Key 'Faixa visual: {0} a {1} mg/dL. {2}. SEM DADO depois de {3} min; consulta a cada {4} s.' -Arguments @($values.LOW_THRESHOLD_MGDL, $values.HIGH_THRESHOLD_MGDL, $sensorEstimate, $values.STALE_AFTER_MINUTES, $values.POLL_INTERVAL_SECONDS))
        if ($alarmSummary.Text -cne $newAlarmSummary) { $alarmSummary.Text = $newAlarmSummary }
        if ($displaySummary.Text -cne $newDisplaySummary) { $displaySummary.Text = $newDisplaySummary }
    }).GetNewClosure()

    $showConfigurationError = ({
        $alarmError = (Get-UlanziText -Key 'Os ajustes nao puderam ser lidos. Abra Suporte para diagnosticar ou recuperar uma configuracao anterior.')
        $displayError = (Get-UlanziText -Key 'A configuracao de tela e sensor nao esta disponivel neste momento.')
        if ($alarmSummary.Text -cne $alarmError) { $alarmSummary.Text = $alarmError }
        if ($displaySummary.Text -cne $displayError) { $displaySummary.Text = $displayError }
    }).GetNewClosure()

    $state.RefreshConfiguration = ({
        param([bool]$Force = $false)
        if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        $setupSnapshot = & $readSetupState
        if ([string]$setupSnapshot.State -cne "ready") {
            $alarmSummary.Text = (Get-UlanziText -Key 'Conclua a configuracao inicial para definir os alertas.')
            $displaySummary.Text = (Get-UlanziText -Key 'Conclua a configuracao inicial para definir a tela e o sensor.')
            & $state.RefreshWidgetText
            return
        }
        if ($null -ne $state.ConfigurationOperation) { return }
        $currentStamp = Get-UlanziPanelConfigurationStamp -ProjectRoot $ProjectRoot -EnvPath $EnvPath
        if (-not $Force -and $state.ConfigurationLoaded -and $currentStamp -ceq $state.ConfigurationStamp) {
            & $state.RefreshWidgetText
            return
        }
        try {
            & $state.BeginBusy (Get-UlanziText -Key 'Carregando configuracao segura...')
            $state.ConfigurationOperation = Start-UlanziConfigEditorOperation -Command "read" -ProjectRoot $ProjectRoot -EnvPath $EnvPath
            $state.ConfigurationDeadline = [DateTime]::UtcNow.AddSeconds(30)
            $configurationTimer.Start()
        } catch {
            & $showConfigurationError
            $state.ConfigurationStamp = Get-UlanziPanelConfigurationStamp -ProjectRoot $ProjectRoot -EnvPath $EnvPath
            $state.ConfigurationLoaded = $true
            & $state.EndBusy (Get-UlanziText -Key 'A configuracao nao pode ser carregada; o status continua ativo.')
        }
        & $state.RefreshWidgetText
    }).GetNewClosure()

    $state.CompleteConfiguration = ({
        if ($null -eq $state.ConfigurationOperation) { return }
        $operation = $state.ConfigurationOperation
        $timedOut = [DateTime]::UtcNow -ge $state.ConfigurationDeadline
        if (-not $operation.Process.HasExited -and -not $timedOut) { return }
        $state.ConfigurationOperation = $null
        $configurationTimer.Stop()
        try {
            if ($timedOut -and -not $operation.Process.HasExited) {
                Stop-UlanziConfigEditorOperation -Operation $operation
                $operation = $null
                throw (Get-UlanziText -Key 'A leitura da configuracao excedeu o tempo limite.')
            }
            try {
                $readResult = Complete-UlanziConfigEditorOperation -Operation $operation
            } finally {
                $operation = $null
            }
            & $applyConfigurationResult $readResult
            & $state.EndBusy (Get-UlanziText -Key 'Configuracao carregada; atualizacao automatica ativa.')
        } catch {
            & $showConfigurationError
            & $state.EndBusy (Get-UlanziText -Key 'A configuracao nao pode ser carregada; o status continua ativo.')
        } finally {
            if ($null -ne $operation) { Stop-UlanziConfigEditorOperation -Operation $operation }
            $state.ConfigurationStamp = Get-UlanziPanelConfigurationStamp -ProjectRoot $ProjectRoot -EnvPath $EnvPath
            $state.ConfigurationLoaded = $true
            $state.ConfigurationDeadline = [DateTime]::MinValue
            & $state.RefreshWidgetText
        }
    }).GetNewClosure()

    $configurationTimer.add_Tick(({
        if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        & $state.CompleteConfiguration
    }).GetNewClosure())

    $state.RefreshStatus = ({
        if ($state.TickBusy -or $state.Closing) { return }
        $state.TickBusy = $true
        try {
            $setupSnapshot = & $readSetupState
            $state.SetupState = [string]$setupSnapshot.State
            if ($state.SetupState -cne "ready") {
                $setupPanel.Visible = $true
                $cards.Visible = $false
                $setupMessage.Text = if ([string]::IsNullOrWhiteSpace([string]$setupSnapshot.Message)) {
                    (Get-UlanziText -Key 'A configuracao inicial ainda nao foi concluida.')
                } else {
                    [string]$setupSnapshot.Message
                }
                $startSetupButton.Enabled = ($state.SetupState -eq "required" -and $null -ne $StartSetup)
                $startSetupButton.Text = switch ($state.SetupState) {
                    "checking" { (Get-UlanziText -Key 'Verificando...') }
                    "configuring" { (Get-UlanziText -Key 'Assistente aberto') }
                    default { (Get-UlanziText -Key 'Configurar agora') }
                }
                foreach ($name in $navButtons.Keys) {
                    $navButtons[$name].Enabled = ($name -in @("overview", "support"))
                }
                $setupBusy = $state.SetupState -in @("checking", "configuring")
                $state.RuntimeBusy = $setupBusy
                $state.RuntimeBusyMessage = if ($state.SetupState -eq "configuring") {
                    (Get-UlanziText -Key 'Assistente aberto; conclua as etapas ou feche para continuar depois.')
                } elseif ($setupBusy) {
                    (Get-UlanziText -Key 'Verificando a configuracao inicial...')
                } else {
                    (Get-UlanziText -Key 'Configuracao necessaria.')
                }
                if ($setupBusy) {
                    $footerProgress.Visible = $true
                    $footerProgress.MarqueeAnimationSpeed = 28
                    $footerProgress.BringToFront()
                    $navigation.Enabled = $false
                    $content.Enabled = $false
                } elseif ($state.BusyDepth -eq 0) {
                    $footerProgress.Visible = $false
                    $footerProgress.MarqueeAnimationSpeed = 0
                    $navigation.Enabled = $true
                    $content.Enabled = $true
                }
                $overallLabel.Text = switch ($state.SetupState) {
                    "checking" { (Get-UlanziText -Key 'Verificando a configuracao...') }
                    "configuring" { (Get-UlanziText -Key 'Conclua o assistente de configuracao') }
                    default { (Get-UlanziText -Key 'Configuracao necessaria') }
                }
                $overallLabel.Tag = "Warning"
                return
            }

            $setupPanel.Visible = $false
            $cards.Visible = $true
            foreach ($name in $navButtons.Keys) { $navButtons[$name].Enabled = $true }
            if ($state.BusyDepth -eq 0 -and $state.RuntimeBusy) {
                $footerProgress.Visible = $false
                $footerProgress.MarqueeAnimationSpeed = 0
                $navigation.Enabled = $true
                $content.Enabled = $true
            }
            $state.RuntimeBusy = $false
            $state.RuntimeBusyMessage = ""
            $runtimeStatus = & $ReadStatus
            $state.LastStatus = $runtimeStatus
            $health = & $BridgeHealth $runtimeStatus
            $responsive = ((Get-UlanziPanelProperty -Object $health -Name "Responsive" -DefaultValue $false) -eq $true)
            $healthText = [string](Get-UlanziPanelProperty -Object $health -Name "Text" -DefaultValue (Get-UlanziText -Key 'aplicativo sem resposta'))
            $runtimeBusy = ((Get-UlanziPanelProperty -Object $health -Name "Busy" -DefaultValue $false) -eq $true)
            $state.RuntimeBusy = $runtimeBusy
            $state.RuntimeBusyMessage = if ($runtimeBusy) { (Get-UlanziText -Key 'Operacao em andamento: {0}.' -Arguments @(($healthText))) } else { "" }
            if ($runtimeBusy) {
                $footerProgress.Visible = $true
                $footerProgress.MarqueeAnimationSpeed = 28
                $footerProgress.BringToFront()
                $navigation.Enabled = $false
                $content.Enabled = $false
                if ($footerStatus.Text -cne $state.RuntimeBusyMessage) { $footerStatus.Text = $state.RuntimeBusyMessage }
                $overallLabel.Text = (Get-UlanziText -Key 'Reiniciando a conexao')
                $overallLabel.Tag = "Warning"
                & $state.SetCard $statusCards.application (Get-UlanziText -Key 'Reiniciando') $healthText "warning"
                foreach ($key in @("source", "reading", "tc001", "alarms", "volume")) {
                    & $state.SetCard $statusCards[$key] (Get-UlanziText -Key 'Aguardando') (Get-UlanziText -Key 'A nova conexao sera confirmada automaticamente.') "warning"
                }
                & $state.SetCard $connectionSource (Get-UlanziText -Key 'Aguardando') (Get-UlanziText -Key 'A fonte sera consultada pela nova conexao.') "warning"
                & $state.SetCard $connectionClock (Get-UlanziText -Key 'Aguardando') (Get-UlanziText -Key 'O horario sera verificado depois da proxima leitura.') "warning"
                & $state.SetCard $connectionTc001 (Get-UlanziText -Key 'Aguardando') (Get-UlanziText -Key 'O proximo envio confirmara a nova conexao.') "warning"
                return
            } elseif ($state.BusyDepth -eq 0 -and $footerProgress.Visible) {
                $footerProgress.Visible = $false
                $footerProgress.MarqueeAnimationSpeed = 0
                $navigation.Enabled = $true
                $content.Enabled = $true
            }
            if (-not $responsive) {
                $overallLabel.Text = (Get-UlanziText -Key 'Precisa de atencao - {0}' -Arguments @(($healthText)))
                $overallLabel.Tag = "Error"
                & $state.SetCard $statusCards.application (Get-UlanziText -Key 'Sem resposta') $healthText "error"
                foreach ($key in @("source", "reading", "tc001", "alarms", "volume")) {
                    & $state.SetCard $statusCards[$key] (Get-UlanziText -Key 'Nao verificavel') (Get-UlanziText -Key 'Aguardando o aplicativo responder.') "warning"
                }
                & $state.SetCard $connectionSource (Get-UlanziText -Key 'Nao verificavel') (Get-UlanziText -Key 'O aplicativo esta parado ou sem resposta.') "warning"
                & $state.SetCard $connectionClock (Get-UlanziText -Key 'Nao verificavel') (Get-UlanziText -Key 'O aplicativo esta parado ou sem resposta.') "warning"
                & $state.SetCard $connectionTc001 (Get-UlanziText -Key 'Nao verificavel') (Get-UlanziText -Key 'O aplicativo esta parado ou sem resposta.') "warning"
                return
            }

            $runtimeVersion = 1
            try { $runtimeVersion = [int](Get-UlanziPanelProperty -Object $runtimeStatus -Name "version" -DefaultValue 1) } catch { $runtimeVersion = 1 }
            if ($runtimeVersion -lt 2) {
                $legacyExpiresAt = ConvertTo-UlanziPanelDate (Get-UlanziPanelProperty -Object $runtimeStatus -Name "expiresAt")
                $legacyActive = (
                    [string](Get-UlanziPanelProperty -Object $runtimeStatus -Name "status" -DefaultValue "unavailable") -eq "active" -and
                    ($null -eq $legacyExpiresAt -or [DateTime]::UtcNow -lt $legacyExpiresAt)
                )
                $overallLabel.Text = if ($legacyActive) { (Get-UlanziText -Key 'Funcionando com status basico') } else { (Get-UlanziText -Key 'Sem leitura recente (status basico)') }
                $overallLabel.Tag = if ($legacyActive) { "Warning" } else { "Error" }
                & $state.SetCard $statusCards.application (Get-UlanziText -Key 'Status basico') (Get-UlanziText -Key 'Atualize o aplicativo para ver cada conexao separadamente.') "warning"
                & $state.SetCard $statusCards.reading ([string](Get-UlanziPanelProperty -Object $runtimeStatus -Name "text" -DefaultValue (Get-UlanziText -Key 'SEM DADO'))) (Get-UlanziText -Key 'O status antigo nao informa todos os detalhes da leitura.') $(if ($legacyActive) { "ok" } else { "error" })
                foreach ($key in @("source", "tc001", "alarms", "volume")) {
                    & $state.SetCard $statusCards[$key] (Get-UlanziText -Key 'Nao informado') (Get-UlanziText -Key 'Detalhe indisponivel no status basico.') "warning"
                }
                & $state.SetCard $connectionSource (Get-UlanziText -Key 'Nao informado') (Get-UlanziText -Key 'A versao antiga nao separa a fonte.') "warning"
                & $state.SetCard $connectionClock (Get-UlanziText -Key 'Nao informado') (Get-UlanziText -Key 'A versao antiga nao informa a coerencia do horario.') "warning"
                & $state.SetCard $connectionTc001 (Get-UlanziText -Key 'Nao informado') (Get-UlanziText -Key 'A versao antiga nao confirma o TC001 separadamente.') "warning"
                return
            }

            $overallState = [string](Get-UlanziPanelProperty -Object $runtimeStatus -Name "healthStatus" -DefaultValue "starting")
            $overallLabel.Text = switch ($overallState) {
                "active" { (Get-UlanziText -Key 'Tudo funcionando') }
                "action-required" { (Get-UlanziText -Key 'Acao necessaria') }
                "unavailable" { (Get-UlanziText -Key 'Sem leitura recente') }
                "degraded" { (Get-UlanziText -Key 'Precisa de atencao') }
                default { (Get-UlanziText -Key 'Conectando...') }
            }
            $overallLevel = if ($overallState -eq "active") { "ok" } elseif ($overallState -eq "starting") { "warning" } else { "error" }
            $overallLabel.Tag = switch ($overallLevel) { "ok" { "Success" }; "error" { "Error" }; default { "Warning" } }
            & $state.SetCard $statusCards.application (Get-UlanziText -Key 'Funcionando') $healthText "ok"

            $source = Get-UlanziPanelProperty -Object $runtimeStatus -Name "source"
            $sourceState = [string](Get-UlanziPanelProperty -Object $source -Name "state" -DefaultValue "waiting")
            $sourceValue = switch ($sourceState) { "connected" { (Get-UlanziText -Key 'Conectada') }; "connecting" { (Get-UlanziText -Key 'Consultando...') }; "error" { (Get-UlanziText -Key 'Falha') }; default { (Get-UlanziText -Key 'Aguardando') } }
            $sourceLevel = if ($sourceState -eq "connected") { "ok" } elseif ($sourceState -eq "error") { "error" } else { "warning" }
            $sourceLastSuccessAt = Get-UlanziPanelProperty -Object $source -Name "lastSuccessAt"
            $sourceHasSuccess = $null -ne (ConvertTo-UlanziPanelDate $sourceLastSuccessAt)
            $sourceLastSuccessText = if ($sourceHasSuccess) { (Get-UlanziText -Key 'Ultima consulta confirmada {0}.' -Arguments @(($(Format-UlanziPanelAge $sourceLastSuccessAt)))) } else { (Get-UlanziText -Key 'Nenhuma consulta foi confirmada nesta execucao.') }
            $sourceError = [string](Get-UlanziPanelProperty -Object $source -Name "lastError" -DefaultValue "")
            $sourceDetail = switch ($sourceState) {
                "connected" { $sourceLastSuccessText }
                "connecting" { (Get-UlanziText -Key 'Consultando a fonte. {0}' -Arguments @(($sourceLastSuccessText))) }
                "error" {
                    if ([string]::IsNullOrWhiteSpace($sourceError)) { (Get-UlanziText -Key 'A consulta falhou. {0}' -Arguments @(($sourceLastSuccessText))) } else { "$sourceError $sourceLastSuccessText" }
                }
                default { (Get-UlanziText -Key 'Aguardando uma consulta valida. {0}' -Arguments @(($sourceLastSuccessText))) }
            }
            & $state.SetCard $statusCards.source $sourceValue $sourceDetail $sourceLevel
            & $state.SetCard $connectionSource $sourceValue $sourceDetail $sourceLevel

            $kind = [string](Get-UlanziPanelProperty -Object $runtimeStatus -Name "kind" -DefaultValue "unavailable")
            $reading = Get-UlanziPanelProperty -Object $runtimeStatus -Name "reading"
            $readingTimestamp = Get-UlanziPanelProperty -Object $reading -Name "timestamp"
            $readingValue = if ($kind -eq "replace-sensor") { (Get-UlanziText -Key 'TROCAR') } elseif ($kind -eq "unavailable") { (Get-UlanziText -Key 'SEM DADO') } else { [string](Get-UlanziPanelProperty -Object $runtimeStatus -Name "text" -DefaultValue (Get-UlanziText -Key 'Leitura atual')) }
            $readingLevel = if ($kind -eq "replace-sensor" -or $kind -eq "unavailable") { "error" } else { "ok" }
            $readingUnits = if ([string](Get-UlanziPanelProperty -Object $runtimeStatus -Name "displayUnits" -DefaultValue "mgdl") -eq "mmol") { "mmol/L" } else { "mg/dL" }
            if ($kind -notin @("replace-sensor", "unavailable")) { $readingValue = "$readingValue $readingUnits" }
            & $state.SetCard $statusCards.reading $readingValue ((Get-UlanziText -Key 'Recebida ') + (Format-UlanziPanelAge $readingTimestamp) + ".") $readingLevel

            $clock = Get-UlanziPanelProperty -Object $runtimeStatus -Name "clock"
            $clockState = [string](Get-UlanziPanelProperty -Object $clock -Name "state" -DefaultValue "unknown")
            $clockValue = if ($clockState -eq "ok") { (Get-UlanziText -Key 'Coerente') } elseif ($clockState -in @("warning", "error")) { (Get-UlanziText -Key 'Diferenca detectada') } else { (Get-UlanziText -Key 'Aguardando') }
            $clockLevel = if ($clockState -eq "ok") { "ok" } elseif ($clockState -in @("warning", "error")) { "error" } else { "warning" }
            $clockDetail = [string](Get-UlanziPanelProperty -Object $clock -Name "message" -DefaultValue (Get-UlanziText -Key 'Comparacao disponivel depois de uma leitura valida.'))
            if ([string]::IsNullOrWhiteSpace($clockDetail)) { $clockDetail = (Get-UlanziText -Key 'Comparacao disponivel depois de uma leitura valida.') }
            & $state.SetCard $connectionClock $clockValue $clockDetail $clockLevel

            $tc001 = Get-UlanziPanelProperty -Object $runtimeStatus -Name "tc001"
            $tc001State = [string](Get-UlanziPanelProperty -Object $tc001 -Name "state" -DefaultValue "waiting")
            $currentReadingAt = ConvertTo-UlanziPanelDate $readingTimestamp
            $confirmedReadingAt = ConvertTo-UlanziPanelDate (Get-UlanziPanelProperty -Object $tc001 -Name "lastConfirmedReadingTimestamp")
            $tc001AwaitingCurrentReading = (
                $tc001State -eq "confirmed" -and
                $null -ne $currentReadingAt -and
                ($null -eq $confirmedReadingAt -or $confirmedReadingAt -ne $currentReadingAt)
            )
            $tc001LastConfirmedAt = Get-UlanziPanelProperty -Object $tc001 -Name "lastConfirmedAt"
            $tc001HasConfirmation = $null -ne (ConvertTo-UlanziPanelDate $tc001LastConfirmedAt)
            $tc001LastConfirmedText = if ($tc001HasConfirmation) { (Get-UlanziText -Key 'Ultimo envio confirmado {0}.' -Arguments @(($(Format-UlanziPanelAge $tc001LastConfirmedAt)))) } else { (Get-UlanziText -Key 'Nenhum envio foi confirmado nesta execucao.') }
            $tc001Value = if ($tc001AwaitingCurrentReading) {
                (Get-UlanziText -Key 'Aguardando leitura atual')
            } else {
                switch ($tc001State) { "confirmed" { (Get-UlanziText -Key 'Atualizado') }; "sending" { (Get-UlanziText -Key 'Enviando...') }; "error" { (Get-UlanziText -Key 'Falha') }; default { (Get-UlanziText -Key 'Aguardando') } }
            }
            $tc001Level = if ($tc001AwaitingCurrentReading) { "warning" } elseif ($tc001State -eq "confirmed") { "ok" } elseif ($tc001State -eq "error") { "error" } else { "warning" }
            $tc001Detail = if ($tc001AwaitingCurrentReading) {
                (Get-UlanziText -Key '{0} A leitura atual ainda aguarda envio.' -Arguments @(($tc001LastConfirmedText)))
            } elseif ($tc001State -eq "confirmed") {
                $tc001LastConfirmedText
            } else {
                $tc001Error = [string](Get-UlanziPanelProperty -Object $tc001 -Name "lastError" -DefaultValue "")
                $tc001CurrentText = switch ($tc001State) {
                    "sending" { (Get-UlanziText -Key 'Enviando a leitura atual.') }
                    "error" { if ([string]::IsNullOrWhiteSpace($tc001Error)) { (Get-UlanziText -Key 'O ultimo envio falhou.') } else { $tc001Error } }
                    default { (Get-UlanziText -Key 'Aguardando confirmacao do relogio.') }
                }
                "$tc001CurrentText $tc001LastConfirmedText"
            }
            & $state.SetCard $statusCards.tc001 $tc001Value $tc001Detail $tc001Level
            & $state.SetCard $connectionTc001 $tc001Value $tc001Detail $tc001Level

            $sound = Get-UlanziPanelProperty -Object $runtimeStatus -Name "sound"
            $soundEnabled = (Get-UlanziPanelProperty -Object $sound -Name "enabled" -DefaultValue $false) -eq $true
            $soundState = [string](Get-UlanziPanelProperty -Object $sound -Name "state" -DefaultValue "idle")
            $soundValue = if (-not $soundEnabled) { (Get-UlanziText -Key 'Desligados') } elseif ($soundState -eq "error") { (Get-UlanziText -Key 'Falha no ultimo envio') } elseif ($soundState -eq "pending") { (Get-UlanziText -Key 'Aguardando confirmacao') } else { (Get-UlanziText -Key 'Ligados') }
            $soundLevel = if (-not $soundEnabled) { "warning" } elseif ($soundState -eq "error") { "error" } elseif ($soundState -eq "pending") { "warning" } else { "ok" }
            $lastSoundOrigin = [string](Get-UlanziPanelProperty -Object $sound -Name "lastOrigin" -DefaultValue "")
            $lastSoundKind = if ($lastSoundOrigin -eq "test") {
                (Get-UlanziText -Key 'teste de som')
            } else {
                switch ([string](Get-UlanziPanelProperty -Object $sound -Name "lastKind" -DefaultValue "")) {
                    "low" { (Get-UlanziText -Key 'glicemia baixa') }
                    "high" { (Get-UlanziText -Key 'glicemia alta') }
                    "up" { (Get-UlanziText -Key 'subida') }
                    "down" { (Get-UlanziText -Key 'queda') }
                    "double-up" { (Get-UlanziText -Key 'subida rapida') }
                    "no-data" { (Get-UlanziText -Key 'sem dado') }
                    "unavailable" { (Get-UlanziText -Key 'sem dado') }
                    default { (Get-UlanziText -Key 'alerta') }
                }
            }
            $lastSoundAt = Get-UlanziPanelProperty -Object $sound -Name "lastConfirmedAt"
            $lastSoundConfirmed = $null -ne (ConvertTo-UlanziPanelDate $lastSoundAt)
            $lastSoundText = if ($lastSoundConfirmed) { (Get-UlanziText -Key 'Ultimo som confirmado: {0}, {1}.' -Arguments @(($lastSoundKind), ($(Format-UlanziPanelAge $lastSoundAt)))) } else { (Get-UlanziText -Key 'Nenhum som foi confirmado nesta execucao.') }
            $soundDetail = if (-not $soundEnabled) {
                (Get-UlanziText -Key 'Alertas desligados. {0}' -Arguments @(($lastSoundText)))
            } elseif ($soundState -eq "error") {
                $soundError = [string](Get-UlanziPanelProperty -Object $sound -Name "lastError" -DefaultValue "")
                $soundErrorText = if ([string]::IsNullOrWhiteSpace($soundError)) { (Get-UlanziText -Key 'O TC001 nao confirmou o ultimo comando de som.') } else { $soundError }
                "$soundErrorText $lastSoundText"
            } elseif ($soundState -eq "pending") {
                (Get-UlanziText -Key 'Um alerta aguarda confirmacao do TC001. {0}' -Arguments @(($lastSoundText)))
            } else {
                $lastSoundText
            }
            & $state.SetCard $statusCards.alarms $soundValue $soundDetail $soundLevel
            if ($soundState -eq "pending" -and $overallState -eq "active") {
                $overallLabel.Text = (Get-UlanziText -Key 'Som aguardando confirmacao')
                $overallLabel.Tag = "Warning"
            }

            $deviceSound = Get-UlanziPanelProperty -Object $runtimeStatus -Name "deviceSound"
            $deviceState = [string](Get-UlanziPanelProperty -Object $deviceSound -Name "state" -DefaultValue "unknown")
            $volumeValue = switch ($deviceState) {
                "confirmed" { (Get-UlanziText -Key 'Ligado') }
                "muted" { (Get-UlanziText -Key 'Som desligado') }
                "silent" { (Get-UlanziText -Key 'Sem som') }
                "unsupported" { (Get-UlanziText -Key 'Controle no firmware') }
                "error" { (Get-UlanziText -Key 'Nao confirmado') }
                "reading" { (Get-UlanziText -Key 'Consultando...') }
                "writing" { (Get-UlanziText -Key 'Aplicando...') }
                default { (Get-UlanziText -Key 'Ainda nao consultado') }
            }
            $volumeLevel = if ($deviceState -in @("muted", "silent", "error")) { "error" } elseif ($deviceState -eq "confirmed") { "ok" } else { "warning" }
            $deviceObservedAt = Get-UlanziPanelProperty -Object $deviceSound -Name "observedAt"
            $volumeDetail = if ($deviceState -in @("confirmed", "muted", "silent") -and $null -ne (ConvertTo-UlanziPanelDate $deviceObservedAt)) {
                (Get-UlanziText -Key 'Estado confirmado {0}.' -Arguments @(($(Format-UlanziPanelAge $deviceObservedAt))))
            } elseif ($deviceState -eq "unsupported") {
                [string](Get-UlanziPanelProperty -Object $deviceSound -Name "reason" -DefaultValue (Get-UlanziText -Key 'O firmware nao oferece controle seguro pelo aplicativo.'))
            } elseif ($deviceState -eq "error") {
                $deviceError = [string](Get-UlanziPanelProperty -Object $deviceSound -Name "lastRequestError" -DefaultValue "")
                if ([string]::IsNullOrWhiteSpace($deviceError)) { (Get-UlanziText -Key 'Nao foi possivel confirmar o estado do buzzer no TC001.') } else { $deviceError }
            } elseif ($deviceState -eq "reading") {
                (Get-UlanziText -Key 'Consultando o buzzer do TC001.')
            } elseif ($deviceState -eq "writing") {
                (Get-UlanziText -Key 'Aguardando o TC001 confirmar o novo estado do buzzer.')
            } else {
                (Get-UlanziText -Key 'Abra Alertas e use Configurar som para consultar o estado real.')
            }
            & $state.SetCard $statusCards.volume $volumeValue $volumeDetail $volumeLevel
        } catch {
            $overallLabel.Text = (Get-UlanziText -Key 'Nao foi possivel atualizar o painel')
            $overallLabel.Tag = "Error"
        } finally {
            if ($null -ne $state.Palette) {
                $overallColor = switch ([string]$overallLabel.Tag) {
                    "Success" { $state.Palette.Success }
                    "Error" { $state.Palette.Error }
                    default { $state.Palette.Warning }
                }
                if ($overallLabel.ForeColor.ToArgb() -ne $overallColor.ToArgb()) {
                    $overallLabel.ForeColor = $overallColor
                }
            }
            if ($state.SetupState -cne "ready" -and $state.BusyDepth -eq 0) {
                $setupFooterMessage = switch ($state.SetupState) {
                    "checking" { (Get-UlanziText -Key 'Verificando a configuracao inicial...') }
                    "configuring" { (Get-UlanziText -Key 'O assistente de configuracao esta aberto.') }
                    default { (Get-UlanziText -Key 'Use Configurar agora para comecar.') }
                }
                if ($footerStatus.Text -cne $setupFooterMessage) { $footerStatus.Text = $setupFooterMessage }
            } elseif (-not $state.RuntimeBusy -and $state.BusyDepth -eq 0 -and $state.ActivePage -in @("overview", "connections")) {
                $liveMessage = (Get-UlanziText -Key 'Status atualizado agora; atualizacao automatica ativa.')
                if ($footerStatus.Text -cne $liveMessage) { $footerStatus.Text = $liveMessage }
            }
            $state.TickBusy = $false
        }
    }).GetNewClosure()

    $state.SelectPage = ({
        param([string]$PageName)
        if (-not $pages.ContainsKey($PageName)) { return }
        $content.SuspendLayout()
        try {
            foreach ($name in $pages.Keys) {
                $isActive = ($name -eq $PageName)
                if ($pages[$name].Visible -ne $isActive) { $pages[$name].Visible = $isActive }
                $role = if ($isActive) { "Accent" } else { "Surface" }
                if ([string]$navButtons[$name].Tag -cne $role) { $navButtons[$name].Tag = $role }
                if ($null -ne $state.Palette) {
                    Set-UlanziUiControlRole -Control $navButtons[$name] -Palette $state.Palette -Role $role
                }
            }
            $pages[$PageName].BringToFront()
        } finally {
            $content.ResumeLayout($false)
        }
        $state.ActivePage = $PageName
        if ($PageName -in @("alerts", "display")) { & $state.RefreshConfiguration }
        if ($PageName -in @("overview", "connections")) {
            & $state.RefreshStatus
        } elseif ($state.BusyDepth -eq 0) {
            $pausedMessage = (Get-UlanziText -Key 'Pronto.')
            if ($footerStatus.Text -cne $pausedMessage) { $footerStatus.Text = $pausedMessage }
        }
    }).GetNewClosure()

    foreach ($item in $navigationItems) {
        $pageName = [string]$item[0]
        $navButtons[$pageName].add_Click(({ & $state.SelectPage $pageName }).GetNewClosure())
    }

    $connectionsVerify.add_Click(({ & $state.InvokeAction $OpenDiagnostics @() (Get-UlanziText -Key 'Preparando o diagnostico...') }).GetNewClosure())
    $connectionsNightscout.add_Click(({ & $state.InvokeAction $OpenNightscout }).GetNewClosure())
    $connectionsReconfigure.add_Click(({
        if ($null -ne $StartSetup) {
            & $state.InvokeAction $StartSetup @() (Get-UlanziText -Key 'Abrindo o assistente unificado...')
        }
    }).GetNewClosure())
    $startSetupButton.add_Click(({
        if ($null -ne $StartSetup) {
            & $state.InvokeAction $StartSetup @() (Get-UlanziText -Key 'Abrindo o assistente de configuracao...')
        }
    }).GetNewClosure())
    $closeButton.add_Click(({ $form.Close() }).GetNewClosure())

    try { $state.Theme = Get-UlanziUiThemePreference -PreferenceRoot $PreferenceRoot } catch { $state.Theme = "system" }
    $themeCombo.SelectedIndex = switch ($state.Theme) { "light" { 1 }; "dark" { 2 }; default { 0 } }
    $themeCombo.add_SelectedIndexChanged(({
        if ($state.Closing) { return }
        $selectedTheme = switch ($themeCombo.SelectedIndex) { 1 { "light" }; 2 { "dark" }; default { "system" } }
        if ($selectedTheme -eq $state.Theme) { return }
        try {
            [void](Set-UlanziUiThemePreference -Theme $selectedTheme -PreferenceRoot $PreferenceRoot)
            $state.Theme = $selectedTheme
            Apply-UlanziUiTheme -Control $form -Theme $state.Theme -PreferenceRoot $PreferenceRoot
            & $state.RefreshPalette
            & $state.RefreshStatus
            $footerStatus.Text = (Get-UlanziText -Key 'Preferencia de aparencia salva; a conexao nao foi reiniciada.')
        } catch {
            if (-not $state.Closing -and -not $form.IsDisposed -and -not $form.Disposing -and $form.IsHandleCreated) {
                [void](Show-UlanziOwnedMessageBox `
                    -Owner $form `
                    -Text $_.Exception.Message `
                    -Caption (Get-UlanziText -Key 'Tema') `
                    -Buttons ([Windows.Forms.MessageBoxButtons]::OK) `
                    -Icon ([Windows.Forms.MessageBoxIcon]::Error))
            }
        }
    }).GetNewClosure())

    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 1000
    $timer.add_Tick(({
        if (
            $state.Closing -or
            $form.IsDisposed -or
            $form.Disposing -or
            -not $form.Visible -or
            $form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized -or
            $state.ActionBusy
        ) { return }
        $shouldRefreshStatus = ($state.RuntimeBusy -or $state.ActivePage -in @("overview", "connections"))
        if (-not $shouldRefreshStatus) {
            try {
                $backgroundHealth = & $BridgeHealth $state.LastStatus
                $shouldRefreshStatus = ((Get-UlanziPanelProperty -Object $backgroundHealth -Name "Busy" -DefaultValue $false) -eq $true)
            } catch {
                $shouldRefreshStatus = $false
            }
        }
        if ($shouldRefreshStatus) { & $state.RefreshStatus }
        $now = [DateTime]::UtcNow
        if ($now -ge $state.NextThemeCheckAt) {
            $state.NextThemeCheckAt = $now.AddSeconds(7)
            $resolved = Resolve-UlanziUiTheme -Theme $state.Theme
            $resolvedName = [string](Get-UlanziPanelProperty -Object $resolved -Name "EffectiveMode" -DefaultValue (Get-UlanziPanelProperty -Object $resolved -Name "Theme" -DefaultValue $resolved))
            if ($resolvedName -cne $state.ResolvedTheme) {
                Apply-UlanziUiTheme -Control $form -Theme $state.Theme -PreferenceRoot $PreferenceRoot
                & $state.RefreshPalette
                if ($state.ActivePage -in @("overview", "connections")) { & $state.RefreshStatus }
            }
        }
    }).GetNewClosure())

    $form.add_Shown(({
        & $state.BeginBusy (Get-UlanziText -Key 'Carregando painel e configuracao...')
        try {
            & $state.RefreshConfiguration $true
            & $state.RefreshWidgetText
            & $state.SelectPage "overview"
            $timer.Start()
        } finally {
            & $state.EndBusy (Get-UlanziText -Key 'Status atualizado agora; atualizacao automatica ativa.')
        }
    }).GetNewClosure())
    $form.add_Resize(({
        if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
            $state.LiveUpdatesSuspended = $true
            return
        }
        if ($state.LiveUpdatesSuspended -and $form.Visible) {
            $state.LiveUpdatesSuspended = $false
            $state.NextThemeCheckAt = [DateTime]::MinValue
            if ($state.ActivePage -in @("overview", "connections")) { & $state.RefreshStatus }
        }
    }).GetNewClosure())
    $form.add_FormClosing(({
        $state.Closing = $true
        $timer.Stop()
        $configurationTimer.Stop()
    }).GetNewClosure())
    $form.add_FormClosed(({
        $state.Closing = $true
        $timer.Stop()
        $configurationTimer.Stop()
        if ($null -ne $state.ConfigurationOperation) {
            Stop-UlanziConfigEditorOperation -Operation $state.ConfigurationOperation
            $state.ConfigurationOperation = $null
        }
        $timer.Dispose()
        $configurationTimer.Dispose()
        if ($null -ne $OnClosed) { & $OnClosed }
    }).GetNewClosure())
    $form.add_KeyDown(({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Escape) { $form.Close() }
    }).GetNewClosure())

    Apply-UlanziUiTheme -Control $form -Theme $state.Theme -PreferenceRoot $PreferenceRoot
    & $state.RefreshPalette
    return [pscustomobject]@{
        Form = $form
        Refresh = ({
            if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
            & $state.RefreshConfiguration
            & $state.RefreshStatus
        }).GetNewClosure()
        Activate = ({
            if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
            if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = [Windows.Forms.FormWindowState]::Normal }
            if (-not $form.Visible) { $form.Show() }
            $form.Activate()
            $form.BringToFront()
        }).GetNewClosure()
        Dispose = ({
            if (-not $form.IsDisposed) {
                $state.Closing = $true
                $timer.Stop()
                $configurationTimer.Stop()
                $form.Close()
                if (-not $form.IsDisposed) { $form.Dispose() }
            }
        }).GetNewClosure()
    }
}
