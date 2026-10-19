[CmdletBinding()]
param(
    [switch]$Console
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot ".env"
$secretsPath = Join-Path $projectRoot ".secrets"
$vaultPath = Join-Path $secretsPath "vault.json"

function Read-WithDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Default
    )
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-YesNoBoolean {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Default
    )
    $answer = (Read-WithDefault -Prompt $Prompt -Default $Default).ToLowerInvariant()
    if ($answer -notin @("sim", "nao")) { throw "Resposta invalida. Use sim ou nao." }
    if ($answer -eq "sim") { return "true" }
    return "false"
}

function ConvertTo-EnvLiteral {
    param([AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    return '"' + $escaped + '"'
}

function ConvertTo-ProtectedValue {
    param([Security.SecureString]$Secret)
    if ($null -eq $Secret -or $Secret.Length -eq 0) { return $null }
    return ($Secret | ConvertFrom-SecureString)
}

function Commit-StagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    if (Test-Path -LiteralPath $TargetPath) {
        if (Test-Path -LiteralPath $BackupPath) { Remove-Item -LiteralPath $BackupPath -Force }
        [IO.File]::Replace($StagedPath, $TargetPath, $BackupPath, $true)
    } else {
        [IO.File]::Move($StagedPath, $TargetPath)
    }
}

function Restore-PreviousFile {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][bool]$HadOriginal,
        [Parameter(Mandatory = $true)][bool]$CommitStarted
    )
    if (-not $CommitStarted) { return }
    if ($HadOriginal -and (Test-Path -LiteralPath $BackupPath)) {
        if (Test-Path -LiteralPath $TargetPath) { Remove-Item -LiteralPath $TargetPath -Force }
        Move-Item -LiteralPath $BackupPath -Destination $TargetPath
    } elseif (-not $HadOriginal -and (Test-Path -LiteralPath $TargetPath)) {
        Remove-Item -LiteralPath $TargetPath -Force
    }
}

function Acquire-ConfigWriteFileLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][ValidateRange(1, 3600)][int]$StaleAfterSeconds = 120
    )

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $stream = $null
        $created = $false
        try {
            $stream = [IO.File]::Open(
                $Path,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            $created = $true
            $token = [Guid]::NewGuid().ToString("D")
            $metadata = [ordered]@{
                pid = $PID
                createdAt = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
                token = $token
            } | ConvertTo-Json -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($metadata)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            $stream.Dispose()
            $stream = $null
            return [pscustomobject]@{ Path = $Path; Token = $token }
        } catch {
            if ($null -ne $stream) { $stream.Dispose() }
            if ($created) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                throw
            }

            if (-not (Test-Path -LiteralPath $Path)) { throw }
            $stale = $false
            try {
                $lockItem = Get-Item -LiteralPath $Path -Force
                $stale = ([DateTime]::UtcNow - $lockItem.LastWriteTimeUtc).TotalSeconds -gt $StaleAfterSeconds
            } catch {
                throw "Nao foi possivel verificar a trava compartilhada da configuracao."
            }
            if ($attempt -eq 0 -and $stale) {
                Remove-Item -LiteralPath $Path -Force
                continue
            }
            throw "Outro salvamento ou restauracao de configuracao esta em andamento; tente novamente em alguns segundos."
        }
    }

    throw "Nao foi possivel reservar o arquivo de configuracao."
}

function Release-ConfigWriteFileLock {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Lock)

    if ($null -eq $Lock) { return }
    $lockPath = [string]$Lock.Path
    try {
        if (-not (Test-Path -LiteralPath $lockPath)) { return }
        $metadata = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
        if ([string]$metadata.token -ceq [string]$Lock.Token) {
            Remove-Item -LiteralPath $lockPath -Force
        }
    } catch {
        Write-Warning "A trava temporaria da configuracao sera removida automaticamente se ficar obsoleta."
    }
}

$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$configMutex = [Threading.Mutex]::new($false, "Local\UlanziLibreConfig-$currentSid")
$ownsConfigMutex = $false
try {
    $ownsConfigMutex = $configMutex.WaitOne(0, $false)
} catch [Threading.AbandonedMutexException] {
    $ownsConfigMutex = $true
}
if (-not $ownsConfigMutex) {
    throw "Outra janela ou assistente de configuracao ja esta em uso."
}

$useGraphicalWizard = -not $Console
$wizardSettings = $null
if ($useGraphicalWizard) {
    if (-not [Environment]::UserInteractive) {
        if ($ownsConfigMutex) { $configMutex.ReleaseMutex() }
        $configMutex.Dispose()
        throw "O assistente visual precisa de uma sessao interativa do Windows. Use -Console somente se quiser configurar pelo terminal."
    }

    try {
        . (Join-Path $PSScriptRoot "ui-theme.ps1")
        [void](Initialize-UlanziWindowsIdentity -ApplicationId "UlanziLibre.Bridge")
        . (Join-Path $PSScriptRoot "primeira-configuracao-ui.ps1")
        $wizardSettings = Show-UlanziFirstRunWizard -HasExistingConfiguration:(Test-Path -LiteralPath $envPath)
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [void][Windows.Forms.MessageBox]::Show(
                "Nao foi possivel abrir o assistente de configuracao.`r`n`r`nFeche e abra o Ulanzi Libre novamente. Se o problema continuar, use Ajuda e manutencao no painel.",
                "Ulanzi Libre",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            )
        } catch {
            # A falha original sera devolvida ao iniciador; nunca aguardamos
            # perguntas de console numa janela iniciada de forma oculta.
        }
        if ($ownsConfigMutex) { $configMutex.ReleaseMutex() }
        $configMutex.Dispose()
        throw "Nao foi possivel abrir o assistente visual de configuracao."
    }
}

if ($useGraphicalWizard) {
    if ($null -eq $wizardSettings) {
        Write-Host "Configuracao preservada; nenhuma alteracao foi feita."
        if ($ownsConfigMutex) { $configMutex.ReleaseMutex() }
        $configMutex.Dispose()
        exit 0
    }
    $awtrixHost = $wizardSettings.AwtrixHost
    $awtrixUser = $wizardSettings.AwtrixUser
    $awtrixPassword = $wizardSettings.AwtrixPassword
    $source = $wizardSettings.Source
    $nightscoutUrl = $wizardSettings.NightscoutUrl
    $nightscoutToken = $wizardSettings.NightscoutToken
    $nightscoutApiSecret = $wizardSettings.NightscoutApiSecret
    $jsonSourceUrl = $wizardSettings.JsonSourceUrl
    $jsonToken = $wizardSettings.JsonToken
    $lowThreshold = $wizardSettings.LowThreshold
    $highThreshold = $wizardSettings.HighThreshold
    $staleMinutes = $wizardSettings.StaleMinutes
    $sensorLifetimeDays = $wizardSettings.SensorLifetimeDays
    $alarmEnabled = $wizardSettings.AlarmEnabled
    $upSlightThreshold = $wizardSettings.UpSlightThreshold
    $downThreshold = $wizardSettings.DownThreshold
    $doubleUpEnabled = $wizardSettings.DoubleUpEnabled
    $noDataEnabled = $wizardSettings.NoDataEnabled
    $alarmHysteresis = $wizardSettings.AlarmHysteresis
    $alarmCooldown = $wizardSettings.AlarmCooldown
    $alarmOnStartupExtreme = $wizardSettings.AlarmOnStartupExtreme
    $alarmOnRecoveryExtreme = $wizardSettings.AlarmOnRecoveryExtreme
    $alarmMaxDeliveryAttempts = $wizardSettings.AlarmMaxDeliveryAttempts
    $alarmDeliveryRetrySeconds = $wizardSettings.AlarmDeliveryRetrySeconds
} else {
    if (Test-Path -LiteralPath $envPath) {
        $replace = Read-Host "Ja existe um arquivo .env. Substituir? (digite SIM para confirmar)"
        if ($replace -cne "SIM") {
            Write-Host "Configuracao preservada; nenhuma alteracao foi feita."
            exit 0
        }
    }

    Write-Host ""
    Write-Host "Configuracao do Ulanzi Libre Bridge"
    Write-Host "As senhas serao protegidas pelo DPAPI do Windows e so este usuario podera abri-las."
    Write-Host ""

    $awtrixHost = Read-WithDefault -Prompt "IP ou hostname do TC001 com AWTRIX" -Default "http://awtrix-ng.local"
    $awtrixUser = Read-Host "Usuario HTTP do AWTRIX (Enter se a autenticacao estiver desativada)"
    $awtrixPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($awtrixUser)) {
        $awtrixPassword = Read-Host "Senha HTTP do AWTRIX" -AsSecureString
    }

    Write-Host ""
    Write-Host "Fontes disponiveis:"
    Write-Host "  nightscout - uma instancia Nightscout que voce ja controla"
    Write-Host "  json        - um endpoint local/autorizado no formato documentado"
    Write-Host "  mock        - leitura simulada para testar o display"
    $source = (Read-WithDefault -Prompt "Fonte" -Default "nightscout").ToLowerInvariant()
    if ($source -notin @("nightscout", "json", "mock")) {
        throw "Fonte invalida. Use nightscout, json ou mock."
    }

    $nightscoutUrl = ""
    $jsonSourceUrl = ""
    $nightscoutToken = $null
    $nightscoutApiSecret = $null
    $jsonToken = $null
    if ($source -eq "nightscout") {
        $nightscoutUrl = Read-Host "URL HTTPS final do Nightscout (ex.: https://meu-nightscout.example)"
        if ([string]::IsNullOrWhiteSpace($nightscoutUrl)) { throw "A URL do Nightscout e obrigatoria." }
        $nightscoutAuth = (Read-WithDefault -Prompt "Autenticacao Nightscout (token, api-secret ou public)" -Default "token").ToLowerInvariant()
        if ($nightscoutAuth -eq "token") {
            $nightscoutToken = Read-Host "Access token criado no Nightscout Admin Tools" -AsSecureString
            if ($nightscoutToken.Length -eq 0) { throw "O access token e obrigatorio para este modo." }
        } elseif ($nightscoutAuth -eq "api-secret") {
            $nightscoutApiSecret = Read-Host "API_SECRET do Nightscout" -AsSecureString
            if ($nightscoutApiSecret.Length -eq 0) { throw "O API_SECRET e obrigatorio para este modo." }
        } elseif ($nightscoutAuth -ne "public") {
            throw "Autenticacao invalida. Use token, api-secret ou public."
        }
    } elseif ($source -eq "json") {
        $jsonSourceUrl = Read-Host "URL HTTPS final do endpoint JSON autorizado (http somente em localhost)"
        if ([string]::IsNullOrWhiteSpace($jsonSourceUrl)) { throw "A URL JSON e obrigatoria." }
        $jsonToken = Read-Host "Bearer token do endpoint JSON (Enter se nao houver)" -AsSecureString
    }

    Write-Host ""
    Write-Host "Os proximos limites controlam as cores do visor; nao sao recomendacoes de tratamento."
    Write-Host "Os limites sonoros comecam iguais e poderao ser ajustados separadamente depois."
    $lowThreshold = Read-WithDefault -Prompt "Abaixo de qual valor usar a cor de glicemia baixa (mg/dL)" -Default "70"
    $highThreshold = Read-WithDefault -Prompt "Acima de qual valor usar a cor de glicemia alta (mg/dL)" -Default "180"
    $staleMinutes = Read-WithDefault -Prompt "Depois de quantos minutos considerar o dado antigo" -Default "15"
    $sensorLifetimeDays = Read-WithDefault -Prompt "Duracao nominal do sensor Libre em dias (varia conforme o modelo)" -Default "15"
    $alarmEnabled = Read-YesNoBoolean -Prompt "Ativar alarmes sonoros (sim/nao)" -Default "nao"
    Write-Host "As regras sonoras a seguir ficam pre-selecionadas, mas so terao efeito depois de ativar o alarme geral."
    $upSlightThreshold = Read-WithDefault -Prompt "Acima de qual valor alertar seta diagonal para cima (mg/dL)" -Default "140"
    $downThreshold = Read-WithDefault -Prompt "Abaixo de qual valor alertar seta para baixo ou diagonal para baixo (mg/dL)" -Default "90"
    $doubleUpEnabled = Read-YesNoBoolean -Prompt "Alertar seta dupla para cima (sim/nao)" -Default "sim"
    $noDataEnabled = Read-YesNoBoolean -Prompt "Alertar quando a leitura ficar SEM DADO (sim/nao)" -Default "sim"
    $alarmHysteresis = Read-WithDefault -Prompt "Histerese para rearmar alarmes por valor (mg/dL)" -Default "5"
    $alarmCooldown = Read-WithDefault -Prompt "Intervalo minimo para rearmar o mesmo alarme (minutos)" -Default "5"
    $alarmOnStartupExtreme = Read-YesNoBoolean -Prompt "Alertar baixa ou alta ja na primeira leitura (sim/nao)" -Default "sim"
    $alarmOnRecoveryExtreme = Read-YesNoBoolean -Prompt "Alertar baixa ou alta ao recuperar de SEM DADO (sim/nao)" -Default "sim"
    $alarmMaxDeliveryAttempts = Read-WithDefault -Prompt "Maximo de tentativas para entregar cada alarme" -Default "3"
    $alarmDeliveryRetrySeconds = Read-WithDefault -Prompt "Segundos entre tentativas de entrega do alarme" -Default "30"
}

$generation = [Guid]::NewGuid().ToString("D")
$lines = @(
    "# Gerado por configurar.cmd em $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))",
    "CONFIG_SCHEMA_VERSION=1",
    "CONFIG_GENERATION=$generation",
    "GLUCOSE_SOURCE=$source",
    "AWTRIX_HOST=$(ConvertTo-EnvLiteral $awtrixHost)",
    "AWTRIX_API=auto",
    "AWTRIX_APP_NAME=glicemia",
    "AWTRIX_USERNAME=$(ConvertTo-EnvLiteral $awtrixUser)",
    "AWTRIX_ACTIVATE_ON_UPDATE=true",
    "DISPLAY_DURATION_SECONDS=10",
    "POLL_INTERVAL_SECONDS=60",
    "STALE_AFTER_MINUTES=$staleMinutes",
    "LIBRE_SENSOR_LIFETIME_DAYS=$sensorLifetimeDays",
    "LOW_THRESHOLD_MGDL=$lowThreshold",
    "HIGH_THRESHOLD_MGDL=$highThreshold",
    "DISPLAY_UNITS=mgdl",
    "GLUCOSE_ALARM_ENABLED=$alarmEnabled",
    "GLUCOSE_ALARM_SOUND_PROFILE=normal",
    "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL=$lowThreshold",
    "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL=$highThreshold",
    "GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL=$upSlightThreshold",
    "GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL=$downThreshold",
    "GLUCOSE_ALARM_DOUBLE_UP_ENABLED=$doubleUpEnabled",
    "GLUCOSE_ALARM_NO_DATA_ENABLED=$noDataEnabled",
    "GLUCOSE_ALARM_HYSTERESIS_MGDL=$alarmHysteresis",
    "GLUCOSE_ALARM_COOLDOWN_MINUTES=$alarmCooldown",
    "GLUCOSE_ALARM_ON_STARTUP_EXTREME=$alarmOnStartupExtreme",
    "GLUCOSE_ALARM_ON_RECOVERY_EXTREME=$alarmOnRecoveryExtreme",
    "GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS=$alarmMaxDeliveryAttempts",
    "GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS=$alarmDeliveryRetrySeconds",
    "WINDOWS_FALLBACK_ALERT_ENABLED=false",
    "WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES=2",
    "NIGHTSCOUT_URL=$(ConvertTo-EnvLiteral $nightscoutUrl)",
    "JSON_SOURCE_URL=$(ConvertTo-EnvLiteral $jsonSourceUrl)",
    "MOCK_GLUCOSE_MGDL=112",
    "MOCK_TREND=flat",
    "MOCK_AGE_MINUTES=0",
    "REQUEST_TIMEOUT_SECONDS=10",
    "LOG_LEVEL=info",
    "UPDATE_MANIFEST_URL=",
    "UPDATE_CHANNEL=stable",
    "UPDATE_EXPECTED_PUBLISHER="
)

if (-not (Test-Path -LiteralPath $secretsPath)) {
    New-Item -ItemType Directory -Path $secretsPath | Out-Null
}
$envStagedPath = Join-Path $projectRoot ".env.new"
$vaultStagedPath = Join-Path $secretsPath "vault.json.new"
$envBackupPath = Join-Path $projectRoot ".env.backup"
$vaultBackupPath = Join-Path $secretsPath "vault.json.backup"
$envHadOriginal = Test-Path -LiteralPath $envPath
$vaultHadOriginal = Test-Path -LiteralPath $vaultPath
$envCommitStarted = $false
$vaultCommitStarted = $false
$configWriteLock = $null
$configWriteLockPath = Join-Path $projectRoot ".env.ui-write.lock"

try {
    # O editor visual e a restauracao de snapshots usam esta mesma trava.
    # Ela e adquirida somente durante a validacao e o commit, nunca enquanto
    # o usuario ainda esta preenchendo o assistente.
    $configWriteLock = Acquire-ConfigWriteFileLock -Path $configWriteLockPath -StaleAfterSeconds 120
    [IO.File]::WriteAllLines($envStagedPath, $lines, [Text.UTF8Encoding]::new($false))

    # Validate every non-secret option before touching the active config or vault.
    $node = Get-Command node -ErrorAction Stop
    & $node.Source (Join-Path $projectRoot "src\validate-config.mjs") $envStagedPath
    if ($LASTEXITCODE -ne 0) {
        throw "A configuracao informada e invalida; os arquivos anteriores foram preservados."
    }

    $protectedSecrets = [ordered]@{}
    $protectedAwtrixPassword = ConvertTo-ProtectedValue $awtrixPassword
    $protectedNightscoutToken = ConvertTo-ProtectedValue $nightscoutToken
    $protectedNightscoutApiSecret = ConvertTo-ProtectedValue $nightscoutApiSecret
    $protectedJsonToken = ConvertTo-ProtectedValue $jsonToken
    if ($null -ne $protectedAwtrixPassword) { $protectedSecrets.AWTRIX_PASSWORD = $protectedAwtrixPassword }
    if ($null -ne $protectedNightscoutToken) { $protectedSecrets.NIGHTSCOUT_TOKEN = $protectedNightscoutToken }
    if ($null -ne $protectedNightscoutApiSecret) { $protectedSecrets.NIGHTSCOUT_API_SECRET = $protectedNightscoutApiSecret }
    if ($null -ne $protectedJsonToken) { $protectedSecrets.JSON_SOURCE_TOKEN = $protectedJsonToken }

    $vault = [ordered]@{
        generation = $generation
        secrets = $protectedSecrets
    }
    $vaultJson = $vault | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($vaultStagedPath, $vaultJson, [Text.UTF8Encoding]::new($false))

    # Commit complete staged files. The shared generation makes a partial commit
    # fail closed in iniciar.ps1 instead of mixing old and new credentials.
    $vaultCommitStarted = $true
    Commit-StagedFile -StagedPath $vaultStagedPath -TargetPath $vaultPath -BackupPath $vaultBackupPath
    $envCommitStarted = $true
    Commit-StagedFile -StagedPath $envStagedPath -TargetPath $envPath -BackupPath $envBackupPath

    foreach ($legacySecret in @("awtrix-password.dpapi", "nightscout-token.dpapi", "nightscout-api-secret.dpapi", "json-token.dpapi")) {
        $legacyPath = Join-Path $secretsPath $legacySecret
        if (Test-Path -LiteralPath $legacyPath) { Remove-Item -LiteralPath $legacyPath -Force }
    }
} catch {
    Restore-PreviousFile -TargetPath $envPath -BackupPath $envBackupPath -HadOriginal $envHadOriginal -CommitStarted $envCommitStarted
    Restore-PreviousFile -TargetPath $vaultPath -BackupPath $vaultBackupPath -HadOriginal $vaultHadOriginal -CommitStarted $vaultCommitStarted
    throw
} finally {
    if (Test-Path -LiteralPath $envStagedPath) { Remove-Item -LiteralPath $envStagedPath -Force }
    if (Test-Path -LiteralPath $vaultStagedPath) { Remove-Item -LiteralPath $vaultStagedPath -Force }
    if (Test-Path -LiteralPath $envBackupPath) { Remove-Item -LiteralPath $envBackupPath -Force }
    if (Test-Path -LiteralPath $vaultBackupPath) { Remove-Item -LiteralPath $vaultBackupPath -Force }
    Release-ConfigWriteFileLock -Lock $configWriteLock
}

Write-Host ""
Write-Host "Configuracao salva em $envPath"
Write-Host "Teste sem enviar ao relogio: iniciar.cmd --once --dry-run"
Write-Host "Teste do display com 112 mg/dL simulado: iniciar.cmd --source=mock --once"

if ($ownsConfigMutex) { $configMutex.ReleaseMutex() }
$configMutex.Dispose()
