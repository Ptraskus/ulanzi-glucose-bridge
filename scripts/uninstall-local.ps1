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
            throw "Links and junctions are not allowed during uninstallation: $($cursor.FullName)"
        }
        if ($cursor.FullName -ieq $StopAt) { return }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    throw "Unable to verify the directories in this path: $Path"
}

function ConvertTo-SafeInstalledPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Invalid path in the installed manifest: '$RelativePath'."
    }
    $normalized = $RelativePath.Replace('/', '\').Trim()
    if ($normalized.Contains(':') -or $normalized -match '(^|\\)\.\.(\\|$)') {
        throw "Directory traversal rejected: '$RelativePath'."
    }
    $segments = @($normalized -split '\\')
    $protectedSegments = @(
        ".runtime", ".secrets", ".install", ".config-history", ".updates",
        "backups", "firmware", "diagnostics", "diagnosticos", "logs",
        "data", "dados", "exports", "rollback"
    )
    foreach ($segment in $segments) {
        if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "The installed manifest contains a reserved Windows name: '$RelativePath'."
        }
        if ($protectedSegments -icontains $segment) {
            throw "The installed manifest tried to remove user data: '$RelativePath'."
        }
    }
    $leaf = $segments[$segments.Count - 1]
    if ($leaf -like ".env*" -and $normalized -ine ".env.example") {
        throw "The installed manifest tried to remove user configuration: '$RelativePath'."
    }

    $fullPath = [IO.Path]::GetFullPath((Join-Path $resolvedInstallPath $normalized))
    if (-not (Test-PathInside -Candidate $fullPath -Parent $resolvedInstallPath)) {
        throw "The manifest tried to remove a file outside the installation: '$RelativePath'."
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
            throw "Ulanzi Libre Bridge is still running. Select 'Exit' in its tray menu and try again."
        }
        $ownedMutexes.Add($mutex)
    }
}

if (-not (Test-PathInside -Candidate $resolvedInstallPath -Parent $programsRoot)) {
    throw "Local uninstallation can only operate inside '$programsRoot'."
}
if (-not (Test-Path -LiteralPath $resolvedInstallPath -PathType Container)) {
    Write-Host "The installation folder no longer exists: $resolvedInstallPath"
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
                throw "The specified path does not match the registered installation."
            }
        }
    }

    $checksumPath = Join-Path $resolvedInstallPath "checksums.sha256"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw "The installation manifest is missing. No files were removed; reinstall to repair before uninstalling."
    }

    $ownedFiles = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $checksumPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^[0-9A-Fa-f]{64} \*(.+)$') {
            throw "The installed manifest is invalid. No files were removed."
        }
        $ownedPath = ConvertTo-SafeInstalledPath -RelativePath $Matches[1]
        if (Test-Path -LiteralPath $ownedPath) {
            Assert-NoReparsePath -Path $ownedPath -StopAt $resolvedInstallPath
        }
        $ownedFiles.Add($ownedPath)
    }
    if ($ownedFiles.Count -eq 0) { throw "The installed manifest is empty. No files were removed." }

    # Um atalho inicia o PowerShell com a pasta do aplicativo como diretório
    # atual. Saia dela antes de tentar remover os últimos diretórios vazios.
    Set-Location -LiteralPath ([IO.Path]::GetTempPath())

    if (-not $NoShellIntegration) {
        $startMenuDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Ulanzi Libre Bridge"
        $shortcutPaths = @(
            (Join-Path $startMenuDirectory "Ulanzi Libre Bridge.lnk"),
            (Join-Path $startMenuDirectory "Configurar Ulanzi Libre Bridge.lnk"),
            (Join-Path $startMenuDirectory "Desinstalar Ulanzi Libre Bridge.lnk"),
            (Join-Path $startMenuDirectory "Uninstall Ulanzi Libre Bridge.lnk"),
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
        Write-Host "Ulanzi Libre Bridge uninstalled."
    } else {
        Write-Host "Ulanzi Libre Bridge uninstalled; configuration or local data was preserved in: $resolvedInstallPath"
    }
} finally {
    foreach ($mutex in $ownedMutexes) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    foreach ($mutex in $mutexes) { $mutex.Dispose() }
}
