[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$portableNode = Join-Path $projectRoot "runtime\node\node.exe"

if (Test-Path -LiteralPath $portableNode -PathType Leaf) {
    $portableNodeDirectory = Split-Path -Parent $portableNode
    $env:PATH = "$portableNodeDirectory;$env:PATH"
} elseif ($null -eq (Get-Command node.exe -ErrorAction SilentlyContinue)) {
    throw "O Node.js 22 ou mais recente não foi encontrado. Reinstale usando o pacote que inclui o runtime portátil."
}

& (Join-Path $projectRoot "scripts\configurar.ps1")
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
