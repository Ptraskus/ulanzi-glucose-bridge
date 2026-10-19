[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$BridgeArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot ".env"
. (Join-Path $PSScriptRoot "ui-language.ps1")
[void](Initialize-UlanziLanguage -EnvPath $envPath)
$secretsPath = Join-Path $projectRoot ".secrets"
$vaultPath = Join-Path $secretsPath "vault.json"
$allowedSecretVariables = @{
    AWTRIX_PASSWORD = $true
    NIGHTSCOUT_TOKEN = $true
    NIGHTSCOUT_API_SECRET = $true
    JSON_SOURCE_TOKEN = $true
}
$assignedVariables = [Collections.Generic.List[string]]::new()
$instanceMutex = $null
$ownsInstanceMutex = $false

# Only a bridge that can run continuously and deliver data is single-instance.
# Diagnostic runs such as --once, --dry-run and --help remain available.
$isDiagnosticRun = @($BridgeArgs | Where-Object {
    $_ -eq "--once" -or $_ -eq "--dry-run" -or $_ -eq "--help" -or $_ -eq "-h"
}).Count -gt 0
if (-not $isDiagnosticRun) {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # Historical mutex prevents the renamed app from running beside an older version.
    $instanceMutex = [Threading.Mutex]::new($false, "Local\UlanziLibreBridge-$currentSid")
    try {
        $ownsInstanceMutex = $instanceMutex.WaitOne(0, $false)
    } catch [Threading.AbandonedMutexException] {
        $ownsInstanceMutex = $true
    }
    if (-not $ownsInstanceMutex) {
        Write-Host (Get-UlanziText -Key 'O Ulanzi Glucose Bridge ja esta em execucao.')
        $instanceMutex.Dispose()
        exit 0
    }
}

function Set-EnvironmentFromProtectedValue {
    param(
        [Parameter(Mandatory = $true)][string]$ProtectedValue,
        [Parameter(Mandatory = $true)][string]$Variable
    )
    $secure = $ProtectedValue | ConvertTo-SecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = $null
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        [Environment]::SetEnvironmentVariable($Variable, $plain, "Process")
        $assignedVariables.Add($Variable)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $plain = $null
    }
}

function Get-ConfigGeneration {
    if (-not (Test-Path -LiteralPath $envPath)) { return $null }
    foreach ($line in Get-Content -LiteralPath $envPath) {
        if ($line -match '^CONFIG_GENERATION=([0-9a-fA-F-]{36})$') { return $Matches[1] }
    }
    return $null
}

try {
    $configGeneration = Get-ConfigGeneration
    $vaultExists = Test-Path -LiteralPath $vaultPath
    if (-not [string]::IsNullOrWhiteSpace($configGeneration) -and -not $vaultExists) {
        throw (Get-UlanziText -Key 'A configuracao exige um cofre que nao foi encontrado. Execute configurar.cmd novamente.')
    }
    if ([string]::IsNullOrWhiteSpace($configGeneration) -and $vaultExists) {
        throw (Get-UlanziText -Key 'O cofre nao corresponde a configuracao atual. Execute configurar.cmd novamente.')
    }
    if ($vaultExists) {
        # A geracao protegida isola o processo de segredos herdados por acaso.
        foreach ($variable in $allowedSecretVariables.Keys) {
            [Environment]::SetEnvironmentVariable($variable, $null, "Process")
        }
        $vault = Get-Content -Raw -LiteralPath $vaultPath | ConvertFrom-Json
        if (
            [string]::IsNullOrWhiteSpace([string]$vault.generation) -or
            $configGeneration -cne [string]$vault.generation
        ) {
            throw (Get-UlanziText -Key 'Configuracao e cofre pertencem a geracoes diferentes. Execute configurar.cmd novamente.')
        }
        foreach ($property in $vault.secrets.PSObject.Properties) {
            $variable = $property.Name
            if (-not $allowedSecretVariables.ContainsKey($variable)) {
                throw (Get-UlanziText -Key 'O cofre contem uma variavel nao permitida. Execute configurar.cmd novamente.')
            }
            Set-EnvironmentFromProtectedValue -ProtectedValue ([string]$property.Value) -Variable $variable
        }
    }

    $node = Get-Command node -ErrorAction Stop
    Push-Location $projectRoot
    try {
        & $node.Source (Join-Path $projectRoot "src\index.mjs") @BridgeArgs
        $bridgeExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    exit $bridgeExitCode
} finally {
    foreach ($variable in $assignedVariables) {
        [Environment]::SetEnvironmentVariable($variable, $null, "Process")
    }
    if ($ownsInstanceMutex) {
        $instanceMutex.ReleaseMutex()
    }
    if ($null -ne $instanceMutex) {
        $instanceMutex.Dispose()
    }
}
