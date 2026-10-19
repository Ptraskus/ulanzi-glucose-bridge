[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA "Programs\Ulanzi Libre Bridge"),
    [switch]$NoShellIntegration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$programsRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs"))
$resolvedInstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexes = [Collections.Generic.List[Threading.Mutex]]::new()
$ownedMutexes = [Collections.Generic.List[Threading.Mutex]]::new()

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $fullCandidate = [IO.Path]::GetFullPath($Candidate)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $fullCandidate.StartsWith($fullParent, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StopAt
    )

    $cursor = Get-Item -LiteralPath $Path -Force
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Links e junctions não são aceitos durante a desinstalação: $($cursor.FullName)"
        }
        if ($cursor.FullName -ieq $StopAt) { return }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    throw "Não foi possível confirmar os diretórios do caminho: $Path"
}

function ConvertTo-SafeInstalledPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Caminho inválido no manifesto instalado: '$RelativePath'."
    }
    $normalized = $RelativePath.Replace('/', '\').Trim()
    if ($normalized.Contains(':') -or $normalized -match '(^|\\)\.\.(\\|$)') {
        throw "Travessia de diretório recusada: '$RelativePath'."
    }
    $segments = @($normalized -split '\\')
    $protectedSegments = @(
        ".runtime", ".secrets", ".install", ".config-history", ".updates",
        "backups", "firmware", "diagnostics", "diagnosticos", "logs",
        "data", "dados", "exports", "rollback"
    )
    foreach ($segment in $segments) {
        if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "O manifesto instalado contém um nome reservado do Windows: '$RelativePath'."
        }
        if ($protectedSegments -icontains $segment) {
            throw "O manifesto instalado tentou remover dados do usuário: '$RelativePath'."
        }
    }
    $leaf = $segments[$segments.Count - 1]
    if ($leaf -like ".env*" -and $normalized -ine ".env.example") {
        throw "O manifesto instalado tentou remover uma configuração do usuário: '$RelativePath'."
    }

    $fullPath = [IO.Path]::GetFullPath((Join-Path $resolvedInstallPath $normalized))
    if (-not (Test-PathInside -Candidate $fullPath -Parent $resolvedInstallPath)) {
        throw "O manifesto tentou remover um arquivo fora da instalação: '$RelativePath'."
    }
    return $fullPath
}

function Assert-ApplicationStopped {
    foreach ($name in @("Local\UlanziLibreTray-$currentSid", "Local\UlanziLibreBridge-$currentSid")) {
        $mutex = [Threading.Mutex]::new($false, $name)
        $mutexes.Add($mutex)
        $ownsMutex = $false
        try {
            $ownsMutex = $mutex.WaitOne(0, $false)
        } catch [Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }
        if (-not $ownsMutex) {
            throw "O Ulanzi Libre Bridge ainda está aberto. Use 'Sair' no ícone da bandeja e tente novamente."
        }
        $ownedMutexes.Add($mutex)
    }
}

if (-not (Test-PathInside -Candidate $resolvedInstallPath -Parent $programsRoot)) {
    throw "A desinstalação local só pode operar dentro de '$programsRoot'."
}
if (-not (Test-Path -LiteralPath $resolvedInstallPath -PathType Container)) {
    Write-Host "A pasta de instalação já não existe: $resolvedInstallPath"
    exit 0
}
Assert-NoReparsePath -Path $resolvedInstallPath -StopAt $programsRoot

try {
    Assert-ApplicationStopped

    $installationMetadataPath = Join-Path $resolvedInstallPath ".install\installation.json"
    if (-not $NoShellIntegration -and (Test-Path -LiteralPath $installationMetadataPath -PathType Leaf)) {
        try {
            $installationMetadata = Get-Content -Raw -LiteralPath $installationMetadataPath | ConvertFrom-Json
            if ($installationMetadata.shellIntegration -eq $false) { $NoShellIntegration = $true }
        } catch {
            # Metadados auxiliares inválidos nunca ampliam o que será removido.
        }
    }

    $uninstallRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UlanziLibreBridge"
    if (-not $NoShellIntegration -and (Test-Path -LiteralPath $uninstallRegistryPath)) {
        $registeredLocation = [string](Get-ItemPropertyValue -LiteralPath $uninstallRegistryPath -Name "InstallLocation" -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($registeredLocation)) {
            $registeredFullPath = [IO.Path]::GetFullPath($registeredLocation).TrimEnd([IO.Path]::DirectorySeparatorChar)
            if ($registeredFullPath -ine $resolvedInstallPath) {
                throw "O caminho informado não corresponde à instalação registrada."
            }
        }
    }

    $checksumPath = Join-Path $resolvedInstallPath "checksums.sha256"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw "O manifesto da instalação não foi encontrado. Nenhum arquivo foi removido; reinstale para reparar antes de desinstalar."
    }

    $ownedFiles = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $checksumPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^[0-9A-Fa-f]{64} \*(.+)$') {
            throw "O manifesto instalado está inválido. Nenhum arquivo foi removido."
        }
        $ownedPath = ConvertTo-SafeInstalledPath -RelativePath $Matches[1]
        if (Test-Path -LiteralPath $ownedPath) {
            Assert-NoReparsePath -Path $ownedPath -StopAt $resolvedInstallPath
        }
        $ownedFiles.Add($ownedPath)
    }
    if ($ownedFiles.Count -eq 0) { throw "O manifesto instalado está vazio. Nenhum arquivo foi removido." }

    # Um atalho inicia o PowerShell com a pasta do aplicativo como diretório
    # atual. Saia dela antes de tentar remover os últimos diretórios vazios.
    Set-Location -LiteralPath ([IO.Path]::GetTempPath())

    if (-not $NoShellIntegration) {
        $startMenuDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Ulanzi Libre Bridge"
        $shortcutPaths = @(
            (Join-Path $startMenuDirectory "Ulanzi Libre Bridge.lnk"),
            (Join-Path $startMenuDirectory "Configurar Ulanzi Libre Bridge.lnk"),
            (Join-Path $startMenuDirectory "Desinstalar Ulanzi Libre Bridge.lnk"),
            (Join-Path ([Environment]::GetFolderPath("Startup")) "Ulanzi Libre Bridge.lnk"),
            (Join-Path ([Environment]::GetFolderPath("Desktop")) "Ulanzi Libre Bridge.lnk")
        )
        foreach ($shortcutPath in $shortcutPaths) {
            if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
                Remove-Item -LiteralPath $shortcutPath -Force
            }
        }
        if ((Test-Path -LiteralPath $startMenuDirectory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $startMenuDirectory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $startMenuDirectory
        }
        if (Test-Path -LiteralPath $uninstallRegistryPath) {
            Remove-Item -LiteralPath $uninstallRegistryPath -Force
        }
    }

    # Remove somente arquivos que constavam no manifesto assinado/verificado.
    # O próprio desinstalador fica por último para que esta execução possa terminar.
    $thisScriptPath = [IO.Path]::GetFullPath($PSCommandPath)
    $orderedOwnedFiles = @($ownedFiles | Sort-Object { if ($_ -ieq $thisScriptPath) { 1 } else { 0 } })
    foreach ($ownedFile in $orderedOwnedFiles) {
        if (Test-Path -LiteralPath $ownedFile -PathType Leaf) {
            Remove-Item -LiteralPath $ownedFile -Force
        }
    }
    if (Test-Path -LiteralPath $checksumPath -PathType Leaf) {
        Remove-Item -LiteralPath $checksumPath -Force
    }
    if (Test-Path -LiteralPath $installationMetadataPath -PathType Leaf) {
        Remove-Item -LiteralPath $installationMetadataPath -Force
    }

    # Só remove diretórios comprovadamente vazios; dados locais nunca são
    # apagados recursivamente pela desinstalação padrão.
    $directories = @(Get-ChildItem -LiteralPath $resolvedInstallPath -Directory -Recurse -Force |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        if (-not (Test-PathInside -Candidate $directory.FullName -Parent $resolvedInstallPath)) { continue }
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory.FullName
        }
    }
    if (@(Get-ChildItem -LiteralPath $resolvedInstallPath -Force).Count -eq 0) {
        Remove-Item -LiteralPath $resolvedInstallPath
        Write-Host "Ulanzi Libre Bridge desinstalado."
    } else {
        Write-Host "Ulanzi Libre Bridge desinstalado; configuração ou dados locais foram preservados em: $resolvedInstallPath"
    }
} finally {
    foreach ($mutex in $ownedMutexes) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    foreach ($mutex in $mutexes) { $mutex.Dispose() }
}
