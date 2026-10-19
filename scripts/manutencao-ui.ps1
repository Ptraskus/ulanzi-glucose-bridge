Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ui-language.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function ConvertTo-UlanziProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.IndexOf('"') -ge 0 -or $Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
        throw (Get-UlanziText -Key 'Um caminho local contem caracteres que nao podem ser usados com seguranca.')
    }
    return '"' + $Value + '"'
}

function Start-UlanziMaintenanceCli {
    param(
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Value = ""
    )

    foreach ($path in @($NodePath, $ScriptPath, $ProjectRoot)) {
        if ($path.IndexOf('"') -ge 0 -or $path.IndexOf("`r") -ge 0 -or $path.IndexOf("`n") -ge 0) {
            throw (Get-UlanziText -Key 'Um caminho local contem caracteres que nao podem ser usados com seguranca.')
        }
    }
    if ($Command -notin @("check", "download", "list", "restore")) {
        throw (Get-UlanziText -Key 'A operacao de manutencao solicitada nao e permitida.')
    }
    if ($Command -eq "restore" -and $Value -notmatch '^\d{8}T\d{9}Z-[0-9a-f-]{36}$') {
        throw (Get-UlanziText -Key 'O identificador da copia de seguranca e invalido.')
    }

    $arguments = @(
        (ConvertTo-UlanziProcessArgument $ScriptPath),
        (ConvertTo-UlanziProcessArgument $Command),
        (ConvertTo-UlanziProcessArgument $ProjectRoot)
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $arguments += ConvertTo-UlanziProcessArgument $Value
    }

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

function Start-UlanziInstallerValidationCli {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Download
    )

    foreach ($path in @($PowerShellPath, $ProjectRoot)) {
        if ($path.IndexOf('"') -ge 0 -or $path.IndexOf("`r") -ge 0 -or $path.IndexOf("`n") -ge 0) {
            throw (Get-UlanziText -Key 'Um caminho local contem caracteres que nao podem ser usados com seguranca.')
        }
    }

    $updatesDirectory = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ".updates"))
    $installerFileName = [string]$Manifest.installer.fileName
    if ($installerFileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.exe$') {
        throw (Get-UlanziText -Key 'O nome do instalador no manifesto e invalido.')
    }
    $expectedHash = [string]$Manifest.installer.sha256
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw (Get-UlanziText -Key 'O manifesto nao contem um SHA-256 valido.')
    }
    $expectedPublisher = ([string]$Manifest.installer.publisher).Trim()
    if ([string]::IsNullOrWhiteSpace($expectedPublisher) -or $expectedPublisher.Length -gt 200 -or $expectedPublisher -match '[\x00-\x1f\x7f]') {
        throw (Get-UlanziText -Key 'O manifesto nao informa um publicador valido.')
    }
    if ([bool]$Manifest.installer.requireAuthenticode -ne $true) {
        throw (Get-UlanziText -Key 'O manifesto precisa exigir assinatura Authenticode.')
    }
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $updatesDirectory $installerFileName))
    $updatesPrefix = $updatesDirectory + [IO.Path]::DirectorySeparatorChar
    if (-not $expectedPath.StartsWith($updatesPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-UlanziText -Key 'O instalador baixado esta fora da pasta de atualizacoes permitida.')
    }
    $downloadedPath = [IO.Path]::GetFullPath([string]$Download.path)
    if (-not [string]::Equals($expectedPath, $downloadedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-UlanziText -Key 'O instalador baixado esta fora da pasta de atualizacoes permitida.')
    }
    if (-not (Test-Path -LiteralPath $downloadedPath -PathType Leaf)) {
        throw (Get-UlanziText -Key 'O instalador baixado nao foi encontrado.')
    }

    # A verificacao pode ler um instalador grande e consultar a cadeia Authenticode.
    # Ela roda em outro processo para nunca bloquear a thread de interface do WinForms.
    $validationScript = @'
$ErrorActionPreference = "Stop"
try {
    . ([Environment]::GetEnvironmentVariable("ULANZI_VALIDATION_LANGUAGE_HELPER"))
    $installerPath = [Environment]::GetEnvironmentVariable("ULANZI_VALIDATION_PATH")
    $expectedHash = [Environment]::GetEnvironmentVariable("ULANZI_VALIDATION_SHA256")
    $expectedPublisher = [Environment]::GetEnvironmentVariable("ULANZI_VALIDATION_PUBLISHER")
    $requireAuthenticode = [Environment]::GetEnvironmentVariable("ULANZI_VALIDATION_REQUIRE_AUTHENTICODE") -eq "true"
    if ([string]::IsNullOrWhiteSpace($installerPath) -or -not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw (Get-UlanziText -Key 'O instalador baixado nao foi encontrado.')
    }
    $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualHash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-UlanziText -Key 'O instalador mudou depois do download. A instalacao foi bloqueada.')
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath -ErrorAction Stop
    if ($requireAuthenticode -and [string]$signature.Status -ne "Valid") {
        throw (Get-UlanziText -Key 'A assinatura digital do instalador nao e valida. A instalacao foi bloqueada.')
    }
    if (-not [string]::IsNullOrWhiteSpace($expectedPublisher)) {
        if ($null -eq $signature.SignerCertificate) {
            throw (Get-UlanziText -Key 'Nao foi possivel confirmar o publicador do instalador. A instalacao foi bloqueada.')
        }
        $simpleName = $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
        $subject = [string]$signature.SignerCertificate.Subject
        $matchesSimpleName = [string]::Equals($simpleName, $expectedPublisher, [StringComparison]::OrdinalIgnoreCase)
        $matchesSubject = [string]::Equals($subject, $expectedPublisher, [StringComparison]::OrdinalIgnoreCase)
        if (-not $matchesSimpleName -and -not $matchesSubject) {
            throw (Get-UlanziText -Key 'O publicador da assinatura digital nao corresponde ao canal de atualizacao. A instalacao foi bloqueada.')
        }
    }
    [Console]::Out.WriteLine(([ordered]@{ ok = $true; path = $installerPath } | ConvertTo-Json -Compress))
} catch {
    [Console]::Error.WriteLine(([ordered]@{ ok = $false; message = $_.Exception.Message } | ConvertTo-Json -Compress))
    exit 1
}
'@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($validationScript))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PowerShellPath
    $startInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startInfo.WorkingDirectory = $ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["ULANZI_VALIDATION_PATH"] = $downloadedPath
    $startInfo.EnvironmentVariables["ULANZI_VALIDATION_SHA256"] = $expectedHash
    $startInfo.EnvironmentVariables["ULANZI_VALIDATION_PUBLISHER"] = $expectedPublisher
    $startInfo.EnvironmentVariables["ULANZI_VALIDATION_REQUIRE_AUTHENTICODE"] = "true"
    $startInfo.EnvironmentVariables["ULANZI_VALIDATION_LANGUAGE_HELPER"] = Join-Path $PSScriptRoot "ui-language.ps1"
    $startInfo.EnvironmentVariables["ULANZI_UI_LANGUAGE"] = Get-UlanziLanguage
    $process = [Diagnostics.Process]::Start($startInfo)
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $process | Add-Member -MemberType NoteProperty -Name UlanziStandardOutputTask -Value $standardOutputTask
    $process | Add-Member -MemberType NoteProperty -Name UlanziStandardErrorTask -Value $standardErrorTask
    return $process
}

function Complete-UlanziMaintenanceCli {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    if (-not $Process.HasExited) { throw (Get-UlanziText -Key 'A operacao de manutencao ainda nao terminou.') }
    $Process.WaitForExit()
    $standardOutput = $Process.UlanziStandardOutputTask.GetAwaiter().GetResult()
    $standardError = $Process.UlanziStandardErrorTask.GetAwaiter().GetResult()
    $exitCode = $Process.ExitCode
    $payload = $null
    foreach ($candidate in @($standardOutput, $standardError)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $payload = $candidate.Trim() | ConvertFrom-Json -ErrorAction Stop
            break
        } catch { }
    }
    if ($exitCode -ne 0 -or $null -eq $payload -or $payload.ok -ne $true) {
        $safeMessage = if ($null -ne $payload -and -not [string]::IsNullOrWhiteSpace([string]$payload.message)) {
            [string]$payload.message
        } else {
            (Get-UlanziText -Key 'A operacao local nao foi concluida.')
        }
        throw $safeMessage
    }
    return $payload
}

function Invoke-UlanziMaintenanceCli {
    param(
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Value = ""
    )

    $process = Start-UlanziMaintenanceCli -NodePath $NodePath -ScriptPath $ScriptPath -Command $Command -ProjectRoot $ProjectRoot -Value $Value
    try {
        $process.WaitForExit()
        return Complete-UlanziMaintenanceCli -Process $process
    } finally {
        $process.Dispose()
    }
}

function Test-UlanziInstallerAuthenticode {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][bool]$RequireAuthenticode,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ExpectedPublisher = ""
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath -ErrorAction Stop
    if ($RequireAuthenticode -and [string]$signature.Status -ne "Valid") {
        throw (Get-UlanziText -Key 'A assinatura digital do instalador nao e valida. A instalacao foi bloqueada.')
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPublisher)) {
        if ($null -eq $signature.SignerCertificate) {
            throw (Get-UlanziText -Key 'Nao foi possivel confirmar o publicador do instalador. A instalacao foi bloqueada.')
        }
        $simpleName = $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
        $subject = [string]$signature.SignerCertificate.Subject
        $expected = $ExpectedPublisher.Trim()
        $matchesSimpleName = [string]::Equals($simpleName, $expected, [StringComparison]::OrdinalIgnoreCase)
        $matchesSubject = [string]::Equals($subject, $expected, [StringComparison]::OrdinalIgnoreCase)
        if (-not $matchesSimpleName -and -not $matchesSubject) {
            throw (Get-UlanziText -Key 'O publicador da assinatura digital nao corresponde ao canal de atualizacao. A instalacao foi bloqueada.')
        }
    }
    return $true
}

function Confirm-UlanziDownloadedInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Download
    )

    $updatesDirectory = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ".updates"))
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $updatesDirectory ([string]$Manifest.installer.fileName)))
    $downloadedPath = [IO.Path]::GetFullPath([string]$Download.path)
    if (-not [string]::Equals($expectedPath, $downloadedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-UlanziText -Key 'O instalador baixado esta fora da pasta de atualizacoes permitida.')
    }
    if (-not (Test-Path -LiteralPath $downloadedPath -PathType Leaf)) {
        throw (Get-UlanziText -Key 'O instalador baixado nao foi encontrado.')
    }
    $actualHash = (Get-FileHash -LiteralPath $downloadedPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualHash, [string]$Manifest.installer.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-UlanziText -Key 'O instalador mudou depois do download. A instalacao foi bloqueada.')
    }
    [void](Test-UlanziInstallerAuthenticode `
        -InstallerPath $downloadedPath `
        -RequireAuthenticode ([bool]$Manifest.installer.requireAuthenticode) `
        -ExpectedPublisher ([string]$Manifest.installer.publisher))
    return $downloadedPath
}

function Show-UlanziMaintenanceDialog {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $Owner = Get-UlanziUsableDialogOwner -Owner $Owner

    $resolvedProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    $nodeCommand = Get-Command node -ErrorAction Stop
    $nodePath = if (-not [string]::IsNullOrWhiteSpace([string]$nodeCommand.Source)) { [string]$nodeCommand.Source } else { [string]$nodeCommand.Path }
    $powerShellCommand = Get-Command powershell.exe -ErrorAction Stop
    $powerShellPath = if (-not [string]::IsNullOrWhiteSpace([string]$powerShellCommand.Source)) { [string]$powerShellCommand.Source } else { [string]$powerShellCommand.Path }
    $updateCli = Join-Path $resolvedProjectRoot "src\update-cli.mjs"
    $historyCli = Join-Path $resolvedProjectRoot "src\config-history-cli.mjs"
    foreach ($requiredFile in @($updateCli, $historyCli)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw (Get-UlanziText -Key 'Um componente local de manutencao nao foi encontrado.')
        }
    }

    $result = [pscustomobject]@{
        ConfigurationRestored = $false
        RestoredSnapshot = $null
        InstallerStarted = $false
        UpdateVersion = $null
    }
    $state = [pscustomobject]@{
        Closing = $false
        PendingProcess = $null
        PendingOperation = $null
        PendingDeadline = [DateTime]::MinValue
        UpdateManifest = $null
        Download = $null
        CandidateDownload = $null
        QueueUpdateCheck = $false
    }

    $form = [Windows.Forms.Form]::new()
    $form.Text = (Get-UlanziText -Key 'Atualizacoes e recuperacao - Ulanzi Libre')
    $form.ClientSize = [Drawing.Size]::new(690, 510)
    $form.MinimumSize = [Drawing.Size]::new(690, 510)
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
        [void](& $setIconCommand -Form $form -ProjectRoot $resolvedProjectRoot)
    }

    $header = [Windows.Forms.Panel]::new()
    $header.Dock = [Windows.Forms.DockStyle]::Top
    $header.Height = 78
    $header.BackColor = [Drawing.ColorTranslator]::FromHtml("#173A4D")
    $header.Tag = "Header"
    $title = [Windows.Forms.Label]::new()
    $title.Text = (Get-UlanziText -Key 'Atualizacoes e recuperacao')
    $title.AutoSize = $true
    $title.Location = [Drawing.Point]::new(20, 12)
    $title.Font = [Drawing.Font]::new("Segoe UI", 17, [Drawing.FontStyle]::Bold)
    $title.ForeColor = [Drawing.Color]::White
    $title.Tag = "Text"
    $subtitle = [Windows.Forms.Label]::new()
    $subtitle.Text = (Get-UlanziText -Key 'Atualize com verificacao de seguranca ou recupere uma configuracao anterior.')
    $subtitle.AutoSize = $true
    $subtitle.Location = [Drawing.Point]::new(22, 48)
    $subtitle.ForeColor = [Drawing.ColorTranslator]::FromHtml("#D4E7EF")
    $subtitle.Tag = "HeaderMuted"
    $header.Controls.Add($title)
    $header.Controls.Add($subtitle)

    $tabs = [Windows.Forms.TabControl]::new()
    $tabs.Location = [Drawing.Point]::new(18, 92)
    $tabs.Size = [Drawing.Size]::new(654, 352)
    $tabs.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Bottom -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $updatesTab = [Windows.Forms.TabPage]::new((Get-UlanziText -Key 'Atualizacoes'))
    $recoveryTab = [Windows.Forms.TabPage]::new((Get-UlanziText -Key 'Recuperacao'))
    $updatesTab.BackColor = [Drawing.Color]::White
    $recoveryTab.BackColor = [Drawing.Color]::White
    $updatesTab.Tag = "Surface"
    $recoveryTab.Tag = "Surface"
    $tabs.Tag = "Surface"
    [void]$tabs.TabPages.Add($updatesTab)
    [void]$tabs.TabPages.Add($recoveryTab)

    $updateHeading = [Windows.Forms.Label]::new()
    $updateHeading.Text = (Get-UlanziText -Key 'Versao do aplicativo')
    $updateHeading.Location = [Drawing.Point]::new(18, 20)
    $updateHeading.AutoSize = $true
    $updateHeading.Font = [Drawing.Font]::new("Segoe UI", 11, [Drawing.FontStyle]::Bold)
    $updateHeading.Tag = "Text"
    $updateStatus = [Windows.Forms.Label]::new()
    $updateStatus.Text = (Get-UlanziText -Key 'Verificando o canal de atualizacoes...')
    $updateStatus.Location = [Drawing.Point]::new(20, 54)
    $updateStatus.Size = [Drawing.Size]::new(590, 48)
    $updateStatus.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $updateStatus.Tag = "Muted"
    $releaseNotes = [Windows.Forms.TextBox]::new()
    $releaseNotes.Location = [Drawing.Point]::new(20, 110)
    $releaseNotes.Size = [Drawing.Size]::new(590, 120)
    $releaseNotes.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $releaseNotes.Multiline = $true
    $releaseNotes.ReadOnly = $true
    $releaseNotes.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    $releaseNotes.BackColor = [Drawing.ColorTranslator]::FromHtml("#F7F9FA")
    $releaseNotes.Tag = "Input"
    $releaseNotes.Text = (Get-UlanziText -Key 'As notas da versao aparecerao aqui quando houver uma atualizacao.')
    $checkButton = [Windows.Forms.Button]::new()
    $checkButton.Text = (Get-UlanziText -Key 'Verificar novamente')
    $checkButton.Location = [Drawing.Point]::new(20, 248)
    $checkButton.Size = [Drawing.Size]::new(132, 34)
    $downloadButton = [Windows.Forms.Button]::new()
    $downloadButton.Text = (Get-UlanziText -Key 'Baixar atualizacao')
    $downloadButton.Location = [Drawing.Point]::new(162, 248)
    $downloadButton.Size = [Drawing.Size]::new(132, 34)
    $downloadButton.Enabled = $false
    $installButton = [Windows.Forms.Button]::new()
    $installButton.Text = (Get-UlanziText -Key 'Instalar agora')
    $installButton.Location = [Drawing.Point]::new(304, 248)
    $installButton.Size = [Drawing.Size]::new(112, 34)
    $installButton.Enabled = $false
    $installButton.BackColor = [Drawing.ColorTranslator]::FromHtml("#167A91")
    $installButton.ForeColor = [Drawing.Color]::White
    $installButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $installButton.FlatAppearance.BorderSize = 0
    $installButton.Tag = "Accent"
    $updatesTab.Controls.Add($updateHeading)
    $updatesTab.Controls.Add($updateStatus)
    $updatesTab.Controls.Add($releaseNotes)
    $updatesTab.Controls.Add($checkButton)
    $updatesTab.Controls.Add($downloadButton)
    $updatesTab.Controls.Add($installButton)

    $recoveryHeading = [Windows.Forms.Label]::new()
    $recoveryHeading.Text = (Get-UlanziText -Key 'Copias automaticas da configuracao')
    $recoveryHeading.Location = [Drawing.Point]::new(18, 18)
    $recoveryHeading.AutoSize = $true
    $recoveryHeading.Font = [Drawing.Font]::new("Segoe UI", 11, [Drawing.FontStyle]::Bold)
    $recoveryHeading.Tag = "Text"
    $recoveryHelp = [Windows.Forms.Label]::new()
    $recoveryHelp.Text = (Get-UlanziText -Key 'Mostramos apenas copias validas. Senhas e tokens nunca aparecem nesta tela.')
    $recoveryHelp.Location = [Drawing.Point]::new(20, 48)
    $recoveryHelp.Size = [Drawing.Size]::new(590, 36)
    $recoveryHelp.Tag = "Muted"
    $snapshotList = [Windows.Forms.ListView]::new()
    $snapshotList.Location = [Drawing.Point]::new(20, 86)
    $snapshotList.Size = [Drawing.Size]::new(590, 142)
    $snapshotList.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
    $snapshotList.View = [Windows.Forms.View]::Details
    $snapshotList.FullRowSelect = $true
    $snapshotList.HideSelection = $false
    $snapshotList.MultiSelect = $false
    $snapshotList.Tag = "Input"
    [void]$snapshotList.Columns.Add((Get-UlanziText -Key 'Data e hora'), 180)
    [void]$snapshotList.Columns.Add((Get-UlanziText -Key 'Origem'), 380)
    $refreshSnapshotsButton = [Windows.Forms.Button]::new()
    $refreshSnapshotsButton.Text = (Get-UlanziText -Key 'Atualizar lista')
    $refreshSnapshotsButton.Location = [Drawing.Point]::new(20, 246)
    $refreshSnapshotsButton.Size = [Drawing.Size]::new(112, 34)
    $restoreButton = [Windows.Forms.Button]::new()
    $restoreButton.Text = (Get-UlanziText -Key 'Restaurar selecionada')
    $restoreButton.Location = [Drawing.Point]::new(142, 246)
    $restoreButton.Size = [Drawing.Size]::new(148, 34)
    $restoreButton.Enabled = $false
    $recoveryStatus = [Windows.Forms.Label]::new()
    $recoveryStatus.Text = (Get-UlanziText -Key 'Selecione uma copia para habilitar a restauracao.')
    $recoveryStatus.Location = [Drawing.Point]::new(306, 244)
    $recoveryStatus.Size = [Drawing.Size]::new(304, 44)
    $recoveryStatus.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $recoveryStatus.Tag = "Muted"
    $recoveryTab.Controls.Add($recoveryHeading)
    $recoveryTab.Controls.Add($recoveryHelp)
    $recoveryTab.Controls.Add($snapshotList)
    $recoveryTab.Controls.Add($refreshSnapshotsButton)
    $recoveryTab.Controls.Add($restoreButton)
    $recoveryTab.Controls.Add($recoveryStatus)

    $footer = [Windows.Forms.Panel]::new()
    $footer.Dock = [Windows.Forms.DockStyle]::Bottom
    # A largura precisa existir antes dos controles ancorados a direita.
    $footer.Size = [Drawing.Size]::new($form.ClientSize.Width, 64)
    $footer.BackColor = [Drawing.Color]::White
    $footer.Tag = "Surface"
    $operationStatus = [Windows.Forms.Label]::new()
    $operationStatus.Text = (Get-UlanziText -Key 'Pronto.')
    $operationStatus.Location = [Drawing.Point]::new(18, 15)
    $operationStatus.Size = [Drawing.Size]::new(540, 32)
    $operationStatus.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
    $operationStatus.ForeColor = [Drawing.ColorTranslator]::FromHtml("#1D5D7A")
    $operationStatus.Tag = "Muted"
    $operationStatus.AutoEllipsis = $true
    $closeButton = [Windows.Forms.Button]::new()
    $closeButton.Text = (Get-UlanziText -Key 'Fechar')
    $closeButton.Size = [Drawing.Size]::new(88, 32)
    $closeButton.Location = [Drawing.Point]::new(584, 10)
    $closeButton.Anchor = [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
    $checkButton.Tag = "Surface"
    $downloadButton.Tag = "Surface"
    $refreshSnapshotsButton.Tag = "Surface"
    $restoreButton.Tag = "Surface"
    $closeButton.Tag = "Surface"
    $progressBar = [Windows.Forms.ProgressBar]::new()
    $progressBar.Dock = [Windows.Forms.DockStyle]::Bottom
    $progressBar.Height = 6
    $progressBar.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 24
    $progressBar.Visible = $false
    $progressBar.AccessibleName = (Get-UlanziText -Key 'Progresso da manutencao')
    $progressBar.AccessibleDescription = (Get-UlanziText -Key 'Nenhuma operacao de manutencao em andamento.')
    $footer.Controls.Add($operationStatus)
    $footer.Controls.Add($closeButton)
    $footer.Controls.Add($progressBar)

    $form.Controls.Add($tabs)
    $form.Controls.Add($footer)
    $form.Controls.Add($header)
    $form.CancelButton = $closeButton

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

    $setBusy = {
        param([bool]$Busy, [string]$Phase = "")
        $checkButton.Enabled = -not $Busy
        $downloadButton.Enabled = (-not $Busy -and $null -ne $state.UpdateManifest -and $state.Download -eq $null)
        $installButton.Enabled = (-not $Busy -and $null -ne $state.Download)
        $refreshSnapshotsButton.Enabled = -not $Busy
        $restoreButton.Enabled = (-not $Busy -and $snapshotList.SelectedItems.Count -eq 1)
        $closeButton.Enabled = -not $Busy
        $form.UseWaitCursor = $Busy
        if ($Busy) {
            $progressBar.MarqueeAnimationSpeed = 24
            $progressBar.AccessibleDescription = if ([string]::IsNullOrWhiteSpace($Phase)) { (Get-UlanziText -Key 'Operacao de manutencao em andamento.') } else { $Phase }
            $progressBar.Visible = $true
            $operationStatus.Text = if ([string]::IsNullOrWhiteSpace($Phase)) { (Get-UlanziText -Key 'Processando...') } else { $Phase }
        } else {
            $progressBar.Visible = $false
            $progressBar.MarqueeAnimationSpeed = 0
            $progressBar.AccessibleDescription = (Get-UlanziText -Key 'Nenhuma operacao de manutencao em andamento.')
            $operationStatus.Text = if ([string]::IsNullOrWhiteSpace($Phase)) { (Get-UlanziText -Key 'Pronto.') } else { $Phase }
        }
        & $setSemanticRole $operationStatus "Muted"
    }

    $startCliOperation = {
        param(
            [ValidateSet("check", "download", "list", "restore")][string]$Operation,
            [AllowEmptyString()][string]$Value = ""
        )
        if ($null -ne $state.PendingProcess) { return $false }
        $scriptPath = if ($Operation -in @("check", "download")) { $updateCli } else { $historyCli }
        $timeoutSeconds = switch ($Operation) {
            "download" { 150 }
            "restore" { 45 }
            default { 30 }
        }
        $phase = switch ($Operation) {
            "check" { (Get-UlanziText -Key 'Consultando o canal de atualizacoes...') }
            "download" { (Get-UlanziText -Key 'Baixando o instalador e verificando o SHA-256...') }
            "list" { (Get-UlanziText -Key 'Carregando copias validas da configuracao...') }
            "restore" { (Get-UlanziText -Key 'Validando a copia e restaurando a configuracao...') }
        }
        $process = Start-UlanziMaintenanceCli `
            -NodePath $nodePath `
            -ScriptPath $scriptPath `
            -Command $Operation `
            -ProjectRoot $resolvedProjectRoot `
            -Value $Value
        $state.PendingOperation = $Operation
        $state.PendingDeadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
        $state.PendingProcess = $process
        & $setBusy $true $phase
        if ($Operation -in @("check", "download")) {
            $updateStatus.Text = $phase
            & $setSemanticRole $updateStatus "Muted"
        } else {
            if ($Operation -eq "list") {
                $snapshotList.Items.Clear()
                $restoreButton.Enabled = $false
            }
            $recoveryStatus.Text = $phase
            & $setSemanticRole $recoveryStatus "Muted"
        }
        return $true
    }

    $startInstallerValidationOperation = {
        param([ValidateSet("validate-download", "validate-install")][string]$Operation)
        if ($null -ne $state.PendingProcess) { return $false }
        if ($null -eq $state.UpdateManifest -or $null -eq $state.CandidateDownload) {
            throw (Get-UlanziText -Key 'Nao ha um instalador para validar.')
        }
        $phase = if ($Operation -eq "validate-install") {
            (Get-UlanziText -Key 'Revalidando o instalador antes de abrir...')
        } else {
            (Get-UlanziText -Key 'Confirmando assinatura digital e publicador...')
        }
        $process = Start-UlanziInstallerValidationCli `
            -PowerShellPath $powerShellPath `
            -ProjectRoot $resolvedProjectRoot `
            -Manifest $state.UpdateManifest `
            -Download $state.CandidateDownload
        $state.PendingOperation = $Operation
        $state.PendingDeadline = [DateTime]::UtcNow.AddSeconds(45)
        $state.PendingProcess = $process
        $updateStatus.Text = $phase
        & $setSemanticRole $updateStatus "Muted"
        & $setBusy $true $phase
        return $true
    }

    $friendlyUpdateError = {
        param([string]$Message)
        if ($Message -match 'canal de atualizacao.+nao foi configurado') {
            return (Get-UlanziText -Key 'O canal de atualizacoes ainda nao foi configurado pelo distribuidor. O aplicativo pode continuar sendo usado normalmente.')
        }
        if ($Message -match 'identidade do publicador.+nao foi configurada') {
            return (Get-UlanziText -Key 'A identidade do publicador ainda nao foi configurada pelo distribuidor. A verificacao foi mantida desativada por seguranca.')
        }
        return (Get-UlanziText -Key 'Nao foi possivel concluir a verificacao: {0}' -Arguments @(($Message)))
    }

    $renderSnapshots = {
        param([object]$Response)
        $snapshotList.BeginUpdate()
        try {
            $snapshotList.Items.Clear()
            $snapshots = @($Response.snapshots | Select-Object -First 3)
            foreach ($snapshot in $snapshots) {
                $createdAt = [DateTime]::Parse([string]$snapshot.createdAt).ToLocalTime().ToString("dd/MM/yyyy HH:mm")
                $reason = [string]$snapshot.reason
                $reasonLabel = if ($reason -eq "before-ui-change") {
                    (Get-UlanziText -Key 'Antes de salvar configuracoes')
                } elseif ($reason -like "before-restore-*") {
                    (Get-UlanziText -Key 'Antes de uma restauracao')
                } elseif ($reason -eq "manual") {
                    (Get-UlanziText -Key 'Copia criada manualmente')
                } else {
                    (Get-UlanziText -Key 'Alteracao anterior da configuracao')
                }
                $item = [Windows.Forms.ListViewItem]::new($createdAt)
                [void]$item.SubItems.Add($reasonLabel)
                $item.Tag = [string]$snapshot.name
                [void]$snapshotList.Items.Add($item)
            }
            if ($snapshots.Count -eq 0) {
                $recoveryStatus.Text = (Get-UlanziText -Key 'Ainda nao ha copias de configuracao disponiveis.')
            } else {
                $recoveryStatus.Text = (Get-UlanziText -Key 'Selecione uma copia para habilitar a restauracao.')
            }
            & $setSemanticRole $recoveryStatus "Muted"
        } finally {
            $snapshotList.EndUpdate()
        }
    }

    $removeCandidateDownload = {
        param([AllowNull()][object]$Download)
        if ($null -eq $Download) { return }
        $candidatePath = [string]$Download.path
        $expectedDirectory = [IO.Path]::GetFullPath((Join-Path $resolvedProjectRoot ".updates")) + [IO.Path]::DirectorySeparatorChar
        try {
            $candidateFullPath = [IO.Path]::GetFullPath($candidatePath)
            if ($candidateFullPath.StartsWith($expectedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $candidateFullPath -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    $checkButton.add_Click({
        try {
            $state.UpdateManifest = $null
            $state.Download = $null
            $state.CandidateDownload = $null
            $result.UpdateVersion = $null
            $releaseNotes.Text = (Get-UlanziText -Key 'Consultando o canal de atualizacoes...')
            [void](& $startCliOperation "check")
        } catch {
            $updateStatus.Text = & $friendlyUpdateError $_.Exception.Message
            & $setSemanticRole $updateStatus "Error"
            & $setBusy $false (Get-UlanziText -Key 'Verificacao interrompida.')
        }
    })

    $downloadButton.add_Click({
        try {
            $state.Download = $null
            $state.CandidateDownload = $null
            [void](& $startCliOperation "download")
        } catch {
            $updateStatus.Text = & $friendlyUpdateError $_.Exception.Message
            & $setSemanticRole $updateStatus "Error"
            & $setBusy $false (Get-UlanziText -Key 'Download interrompido.')
        }
    })

    $installButton.add_Click({
        try {
            $state.CandidateDownload = $state.Download
            [void](& $startInstallerValidationOperation "validate-install")
        } catch {
            & $removeCandidateDownload $state.CandidateDownload
            $state.CandidateDownload = $null
            $state.Download = $null
            $installButton.Enabled = $false
            $updateStatus.Text = (Get-UlanziText -Key 'A instalacao foi bloqueada: {0}' -Arguments @(($($_.Exception.Message))))
            & $setSemanticRole $updateStatus "Error"
            & $setBusy $false (Get-UlanziText -Key 'Validacao interrompida.')
        }
    })

    $snapshotList.add_SelectedIndexChanged({
        $restoreButton.Enabled = ($null -eq $state.PendingProcess -and $snapshotList.SelectedItems.Count -eq 1)
    })

    $refreshSnapshotsButton.add_Click({
        try {
            [void](& $startCliOperation "list")
        } catch {
            $recoveryStatus.Text = (Get-UlanziText -Key 'Nao foi possivel listar as copias validas.')
            & $setSemanticRole $recoveryStatus "Error"
            & $setBusy $false (Get-UlanziText -Key 'Leitura interrompida.')
        }
    })
    $restoreButton.add_Click({
        if ($snapshotList.SelectedItems.Count -ne 1) { return }
        $selected = $snapshotList.SelectedItems[0]
        $snapshotName = [string]$selected.Tag
        if ($snapshotName -notmatch '^\d{8}T\d{9}Z-[0-9a-f-]{36}$') {
            $recoveryStatus.Text = (Get-UlanziText -Key 'A copia selecionada nao possui um identificador valido.')
            & $setSemanticRole $recoveryStatus "Error"
            return
        }
        $answer = Show-UlanziOwnedMessageBox `
            -Owner $form `
            -Text (Get-UlanziText -Key 'Maintenance.RestoreConfirm' -Arguments @($($selected.Text))) `
            -Caption (Get-UlanziText -Key 'Confirmar restauracao') `
            -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
            -Icon ([Windows.Forms.MessageBoxIcon]::Warning)
        if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        try {
            [void](& $startCliOperation "restore" $snapshotName)
        } catch {
            $recoveryStatus.Text = (Get-UlanziText -Key 'Nao foi possivel restaurar: {0}' -Arguments @(($($_.Exception.Message))))
            & $setSemanticRole $recoveryStatus "Error"
            & $setBusy $false (Get-UlanziText -Key 'Restauracao interrompida.')
        }
    })

    $closeButton.add_Click({ $form.Close() })
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 250
    $timer.add_Tick({
        if ($state.Closing -or $null -eq $state.PendingProcess) { return }
        if (-not $state.PendingProcess.HasExited) {
            if ([DateTime]::UtcNow -ge $state.PendingDeadline) {
                $expiredOperation = [string]$state.PendingOperation
                $expiredProcess = $state.PendingProcess
                try { $expiredProcess.Kill() } catch { }
                $state.PendingProcess = $null
                $state.PendingOperation = $null
                $state.PendingDeadline = [DateTime]::MinValue
                $expiredProcess.Dispose()
                if ($expiredOperation -in @("list", "restore")) {
                    $recoveryStatus.Text = (Get-UlanziText -Key 'A operacao excedeu o tempo limite de seguranca. Tente novamente mais tarde.')
                    & $setSemanticRole $recoveryStatus "Error"
                } else {
                    if ($expiredOperation -in @("download", "validate-download", "validate-install")) {
                        & $removeCandidateDownload $state.CandidateDownload
                        $state.CandidateDownload = $null
                        $state.Download = $null
                    }
                    $updateStatus.Text = (Get-UlanziText -Key 'A operacao excedeu o tempo limite de seguranca. Tente novamente mais tarde.')
                    & $setSemanticRole $updateStatus "Error"
                }
                $continueWithCheck = ($expiredOperation -eq "list" -and $state.QueueUpdateCheck)
                $state.QueueUpdateCheck = $false
                if ($continueWithCheck -and -not $state.Closing) {
                    try {
                        [void](& $startCliOperation "check")
                    } catch {
                        $updateStatus.Text = & $friendlyUpdateError $_.Exception.Message
                        & $setSemanticRole $updateStatus "Error"
                        & $setBusy $false (Get-UlanziText -Key 'Verificacao interrompida.')
                    }
                } else {
                    & $setBusy $false (Get-UlanziText -Key 'Tempo limite excedido.')
                }
            }
            return
        }
        $operation = [string]$state.PendingOperation
        $process = $state.PendingProcess
        $state.PendingOperation = $null
        $state.PendingProcess = $null
        $state.PendingDeadline = [DateTime]::MinValue
        $nextOperation = $null
        $restorationCompleted = $false
        $installerPathToOffer = $null
        $operationFailed = $false
        try {
            $response = Complete-UlanziMaintenanceCli -Process $process
            switch ($operation) {
                "check" {
                    if ($response.updateAvailable -eq $true) {
                        $state.UpdateManifest = $response.manifest
                        $result.UpdateVersion = [string]$response.manifest.version
                        $releaseNotes.Text = if ([string]::IsNullOrWhiteSpace([string]$response.manifest.notes)) { (Get-UlanziText -Key 'Esta versao nao possui notas adicionais.') } else { [string]$response.manifest.notes }
                        $updateStatus.Text = (Get-UlanziText -Key 'Nova versao {0} disponivel. Confira as notas e clique em Baixar atualizacao.' -Arguments @(($($response.manifest.version))))
                    } else {
                        $state.UpdateManifest = $null
                        $releaseNotes.Text = (Get-UlanziText -Key 'Nenhuma atualizacao nova foi encontrada.')
                        $updateStatus.Text = (Get-UlanziText -Key 'Voce ja esta usando a versao mais recente ({0}).' -Arguments @(($($response.currentVersion))))
                    }
                    & $setSemanticRole $updateStatus "Success"
                }
                "download" {
                    if ($response.updateAvailable -ne $true -or $null -eq $response.download) {
                        $state.UpdateManifest = $null
                        $state.CandidateDownload = $null
                        $state.Download = $null
                        $updateStatus.Text = (Get-UlanziText -Key 'A atualizacao nao esta mais disponivel. Verifique novamente.')
                    } else {
                        $state.UpdateManifest = $response.manifest
                        $state.CandidateDownload = $response.download
                        $nextOperation = "validate-download"
                    }
                }
                "list" {
                    & $renderSnapshots $response
                }
                "restore" {
                    if ($response.restored -ne $true) { throw (Get-UlanziText -Key 'A restauracao nao foi confirmada.') }
                    $result.ConfigurationRestored = $true
                    $result.RestoredSnapshot = [string]$response.name
                    $recoveryStatus.Text = (Get-UlanziText -Key 'Configuracao restaurada com seguranca.')
                    & $setSemanticRole $recoveryStatus "Success"
                    $restorationCompleted = $true
                }
                "validate-download" {
                    if (-not [string]::Equals([string]$response.path, [string]$state.CandidateDownload.path, [StringComparison]::OrdinalIgnoreCase)) {
                        throw (Get-UlanziText -Key 'A validacao retornou um instalador inesperado.')
                    }
                    $state.Download = $state.CandidateDownload
                    $updateStatus.Text = (Get-UlanziText -Key 'Download concluido. Assinatura digital, publicador e SHA-256 confirmados; o instalador esta pronto.')
                    & $setSemanticRole $updateStatus "Success"
                }
                "validate-install" {
                    if (-not [string]::Equals([string]$response.path, [string]$state.CandidateDownload.path, [StringComparison]::OrdinalIgnoreCase)) {
                        throw (Get-UlanziText -Key 'A validacao retornou um instalador inesperado.')
                    }
                    $state.Download = $state.CandidateDownload
                    $installerPathToOffer = [string]$response.path
                }
                default { throw (Get-UlanziText -Key 'A operacao de manutencao concluida nao e reconhecida.') }
            }
        } catch {
            $operationFailed = $true
            if ($operation -eq "list") {
                $recoveryStatus.Text = (Get-UlanziText -Key 'Nao foi possivel listar as copias validas.')
                & $setSemanticRole $recoveryStatus "Error"
            } elseif ($operation -eq "restore") {
                $recoveryStatus.Text = (Get-UlanziText -Key 'Nao foi possivel restaurar: {0}' -Arguments @(($($_.Exception.Message))))
                & $setSemanticRole $recoveryStatus "Error"
            } else {
                if ($operation -in @("download", "validate-download", "validate-install")) {
                    & $removeCandidateDownload $state.CandidateDownload
                    $state.CandidateDownload = $null
                }
                $state.Download = $null
                $updateStatus.Text = if ($operation -eq "validate-install") {
                    (Get-UlanziText -Key 'A instalacao foi bloqueada: {0}' -Arguments @(($($_.Exception.Message))))
                } else {
                    & $friendlyUpdateError $_.Exception.Message
                }
                & $setSemanticRole $updateStatus "Error"
            }
        } finally {
            $process.Dispose()
        }

        if ($state.Closing) { return }
        if ($null -ne $nextOperation) {
            try {
                [void](& $startInstallerValidationOperation $nextOperation)
            } catch {
                & $removeCandidateDownload $state.CandidateDownload
                $state.CandidateDownload = $null
                $state.Download = $null
                $updateStatus.Text = (Get-UlanziText -Key 'Nao foi possivel validar o instalador: {0}' -Arguments @(($($_.Exception.Message))))
                & $setSemanticRole $updateStatus "Error"
                & $setBusy $false (Get-UlanziText -Key 'Validacao interrompida.')
            }
            return
        }

        $continueWithCheck = ($operation -eq "list" -and $state.QueueUpdateCheck)
        $state.QueueUpdateCheck = $false
        if ($continueWithCheck) {
            try {
                [void](& $startCliOperation "check")
            } catch {
                $updateStatus.Text = & $friendlyUpdateError $_.Exception.Message
                & $setSemanticRole $updateStatus "Error"
                & $setBusy $false (Get-UlanziText -Key 'Verificacao interrompida.')
            }
            return
        }

        & $setBusy $false $(if ($operationFailed) { (Get-UlanziText -Key 'Operacao interrompida.') } else { (Get-UlanziText -Key 'Operacao concluida.') })
        if ($restorationCompleted) {
            try {
                [void](Show-UlanziOwnedMessageBox `
                    -Owner $form `
                    -Text (Get-UlanziText -Key 'Configuracao restaurada com seguranca. Clique em OK para reiniciar o aplicativo e aplicar as mudancas.') `
                    -Caption (Get-UlanziText -Key 'Restauracao concluida') `
                    -Buttons ([Windows.Forms.MessageBoxButtons]::OK) `
                    -Icon ([Windows.Forms.MessageBoxIcon]::Information))
                if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
                $form.Close()
            } catch {
                $recoveryStatus.Text = (Get-UlanziText -Key 'A configuracao foi restaurada, mas a janela nao conseguiu concluir: {0}' -Arguments @(($($_.Exception.Message))))
                & $setSemanticRole $recoveryStatus "Error"
            }
            return
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$installerPathToOffer)) {
            try {
                $answer = Show-UlanziOwnedMessageBox `
                    -Owner $form `
                    -Text (Get-UlanziText -Key 'Maintenance.InstallConfirm') `
                    -Caption (Get-UlanziText -Key 'Instalar atualizacao') `
                    -Buttons ([Windows.Forms.MessageBoxButtons]::YesNo) `
                    -Icon ([Windows.Forms.MessageBoxIcon]::Question)
                if ($state.Closing -or $form.IsDisposed -or $form.Disposing) { return }
                if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
                [void](Start-Process -FilePath $installerPathToOffer -PassThru -ErrorAction Stop)
                $result.InstallerStarted = $true
                $form.Close()
            } catch {
                $state.Download = $null
                $installButton.Enabled = $false
                $updateStatus.Text = (Get-UlanziText -Key 'A instalacao foi bloqueada: {0}' -Arguments @(($($_.Exception.Message))))
                & $setSemanticRole $updateStatus "Error"
            }
        }
    })

    $form.add_Shown({
        $timer.Start()
        $state.QueueUpdateCheck = $true
        try {
            [void](& $startCliOperation "list")
        } catch {
            $state.QueueUpdateCheck = $false
            $recoveryStatus.Text = (Get-UlanziText -Key 'Nao foi possivel listar as copias validas.')
            & $setSemanticRole $recoveryStatus "Error"
            try {
                [void](& $startCliOperation "check")
            } catch {
                $updateStatus.Text = & $friendlyUpdateError $_.Exception.Message
                & $setSemanticRole $updateStatus "Error"
                & $setBusy $false (Get-UlanziText -Key 'Inicializacao interrompida.')
            }
        }
    })
    $form.add_FormClosing({
        param($sender, $eventArgs)
        if ($eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing -and $null -ne $state.PendingProcess) {
            $eventArgs.Cancel = $true
            $operationStatus.Text = (Get-UlanziText -Key 'Aguarde a etapa atual terminar antes de fechar.')
            & $setSemanticRole $operationStatus "Warning"
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
        if ($null -ne $state.PendingProcess) {
            try {
                if (-not $state.PendingProcess.HasExited) { $state.PendingProcess.Kill() }
            } catch { }
            $state.PendingProcess.Dispose()
        }
        $timer.Dispose()
        $form.Dispose()
    }
    return $result
}
