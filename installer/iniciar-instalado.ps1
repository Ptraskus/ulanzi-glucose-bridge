[CmdletBinding()]
param([switch]$OpenPanel)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$portableNode = Join-Path $projectRoot "runtime\node\node.exe"

if (Test-Path -LiteralPath $portableNode -PathType Leaf) {
    $portableNodeDirectory = Split-Path -Parent $portableNode
    $env:PATH = "$portableNodeDirectory;$env:PATH"
} elseif ($null -eq (Get-Command node.exe -ErrorAction SilentlyContinue)) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show(
        "O Node.js 22 ou mais recente não foi encontrado. Reinstale usando o pacote que inclui o runtime portátil.",
        "Ulanzi Libre Bridge",
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    )
    exit 2
}

$trayScript = Join-Path $projectRoot "scripts\iniciar-bandeja.ps1"
& $trayScript -OpenPanel:$OpenPanel
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
