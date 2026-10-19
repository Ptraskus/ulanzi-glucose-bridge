[CmdletBinding()]
param(
    [switch]$OpenPanel,
    [switch]$Setup,
    [switch]$Console,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$language = "en"

try {
    . (Join-Path $PSScriptRoot "ui-language.ps1")
    [void](Initialize-UlanziLanguage -EnvPath (Join-Path $projectRoot ".env"))
    $language = Get-UlanziLanguage

    $portableNode = Join-Path $projectRoot "runtime\node\node.exe"
    if (Test-Path -LiteralPath $portableNode -PathType Leaf) {
        $nodePath = $portableNode
    } else {
        $nodeCommand = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $nodePath = if ($null -ne $nodeCommand) { $nodeCommand.Source } else { $null }
    }
    $nodeHelp = if ($language -eq "pt-BR") {
        "Instale o Node.js LTS (22 ou mais recente) para Windows em https://nodejs.org/en/download e abra Start.cmd novamente. Se usa um pacote com runtime incluido, extraia todos os arquivos antes de iniciar. Nao e necessario executar npm install."
    } else {
        "Install Node.js LTS (22 or newer) for Windows from https://nodejs.org/en/download, then open Start.cmd again. If using a package with the runtime included, extract all files before starting. You do not need to run npm install."
    }
    if ([string]::IsNullOrWhiteSpace($nodePath)) { throw $nodeHelp }
    $nodeVersion = (& $nodePath --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v([0-9]+)\.' -or [int]$Matches[1] -lt 22) {
        $detectedLabel = if ($language -eq "pt-BR") { "Detectado" } else { "Detected" }
        throw "$nodeHelp`n`n${detectedLabel}: $nodeVersion"
    }
    $env:PATH = (Split-Path -Parent $nodePath) + ";" + $env:PATH

    foreach ($required in @("src\index.mjs", "scripts\iniciar-bandeja.ps1", "scripts\configurar.ps1", "locales\en.json", "locales\pt-BR.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $required) -PathType Leaf)) {
            $message = if ($language -eq "pt-BR") { "Arquivo ausente: $required. Extraia o ZIP completo antes de abrir Start.cmd." } else { "Missing file: $required. Extract the entire ZIP before opening Start.cmd." }
            throw $message
        }
    }
    $probePath = Join-Path $projectRoot (".ulanzi-write-check-" + [Guid]::NewGuid().ToString("N"))
    try {
        $probe = [IO.FileStream]::new($probePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
        $probe.Dispose()
    } catch {
        if ($language -eq "pt-BR") { throw "Esta pasta nao permite salvar suas configuracoes. Extraia o ZIP em uma pasta sua, como Documentos, e abra Start.cmd novamente." }
        throw "This folder does not allow saving your settings. Extract the ZIP into a writable folder, such as Documents, then open Start.cmd again."
    }
    if ($Check) {
        Write-Output "Ready: Node.js $nodeVersion; language=$language"
        exit 0
    }
    if ($Setup) {
        & (Join-Path $PSScriptRoot "configurar.ps1") -Console:$Console
    } else {
        & (Join-Path $PSScriptRoot "iniciar-bandeja.ps1") -OpenPanel:$OpenPanel
    }
} catch {
    $message = $_.Exception.Message
    if ($Check -or $Console) {
        [Console]::Error.WriteLine($message)
    } else {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($message, "Ulanzi Glucose Bridge", [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
    }
    exit 2
}
