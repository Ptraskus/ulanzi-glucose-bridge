[CmdletBinding()]
param(
    [string]$PackagePath = (Split-Path -Parent $PSScriptRoot),
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedPackageSha256,
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA "Programs\Ulanzi Libre Bridge"),
    [ValidateSet("Keep", "Enable", "Disable")]
    [string]$Startup = "Keep",
    [ValidateSet("Keep", "Enable", "Disable")]
    [string]$DesktopShortcut = "Keep",
    [switch]$Repair,
    [switch]$NoShellIntegration,
    [switch]$LaunchAfterInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$temporaryExtractionDirectory = $null
$forbiddenSegments = @(
    ".git", ".runtime", ".secrets", ".tools", "backups", "firmware",
    "node_modules", "coverage", ".install", ".config-history", ".updates",
    "diagnostics", "diagnosticos", "logs", "data", "dados", "exports",
    "rollback"
)

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
            throw "Links e junctions não são aceitos durante a instalação: $($cursor.FullName)"
        }
        if ($cursor.FullName -ieq $StopAt) { return }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    throw "Não foi possível confirmar os diretórios do caminho: $Path"
}

function ConvertTo-SafeRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Caminho inválido no manifesto: '$RelativePath'."
    }
    $normalized = $RelativePath.Replace('/', '\').Trim()
    if ($normalized.Contains(':') -or $normalized -match '(^|\\)\.\.(\\|$)') {
        throw "Travessia de diretório recusada no manifesto: '$RelativePath'."
    }
    $segments = @($normalized -split '\\')
    foreach ($segment in $segments) {
        if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "O manifesto contém um nome reservado do Windows: '$RelativePath'."
        }
        if ($forbiddenSegments -icontains $segment) {
            throw "O pacote tentou instalar dados locais proibidos: '$RelativePath'."
        }
    }
    $leaf = $segments[$segments.Count - 1]
    if ($leaf -like ".env*" -and $normalized -ine ".env.example") {
        throw "O pacote tentou instalar uma configuração local: '$RelativePath'."
    }
    if ([IO.Path]::GetExtension($leaf) -match '(?i)^\.(bak|backup|bin|dmp|log|tmp|zip)$') {
        throw "O pacote tentou instalar um artefato ou dado local: '$RelativePath'."
    }
    if (
        [IO.Path]::GetExtension($leaf) -ieq ".json" -and
        $normalized -inotmatch '^runtime\\node\\' -and
        $normalized -inotmatch '^(package|build-info)\.json$'
    ) {
        throw "O pacote tentou instalar um JSON local não reconhecido: '$RelativePath'."
    }
    return $normalized
}

function Expand-VerifiedStructureZip {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
            $entryName = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($entryName) -or $entryName.Contains(':') -or $entryName -match '(^|\\)\.\.(\\|$)') {
                throw "O ZIP contém um caminho inseguro: $($entry.FullName)"
            }
            foreach ($segment in @($entryName -split '\\')) {
                if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
                    throw "O ZIP contém um nome reservado do Windows: $($entry.FullName)"
                }
            }
            $entryDestination = [IO.Path]::GetFullPath((Join-Path $Destination $entryName))
            if (-not (Test-PathInside -Candidate $entryDestination -Parent $Destination)) {
                throw "O ZIP tentou gravar fora da pasta temporária: $($entry.FullName)"
            }
        }
    } finally {
        $archive.Dispose()
    }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination
    $reparsePoint = Get-ChildItem -LiteralPath $Destination -Recurse -Force |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) {
        throw "O ZIP criou um link não permitido: $($reparsePoint.FullName)"
    }
}

function Get-PackageRoot {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $resolved = [IO.Path]::GetFullPath($InputPath)
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        if ([IO.Path]::GetExtension($resolved) -ine ".zip") {
            throw "PackagePath deve apontar para uma pasta ou um arquivo ZIP."
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256)) {
            $actualPackageHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
            if ($actualPackageHash -ine $ExpectedPackageSha256) {
                throw "O SHA-256 do ZIP não corresponde ao valor esperado. A instalação foi bloqueada."
            }
        }
        $script:temporaryExtractionDirectory = Join-Path ([IO.Path]::GetTempPath()) ("ulanzi-libre-install-" + [Guid]::NewGuid().ToString("N"))
        [void](New-Item -ItemType Directory -Path $script:temporaryExtractionDirectory)
        Expand-VerifiedStructureZip -ArchivePath $resolved -Destination $script:temporaryExtractionDirectory
        $resolved = $script:temporaryExtractionDirectory
    } elseif (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Pacote não encontrado: $resolved"
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256)) {
        throw "ExpectedPackageSha256 só pode ser usado quando PackagePath é um ZIP."
    }

    if (Test-Path -LiteralPath (Join-Path $resolved "checksums.sha256") -PathType Leaf) {
        return $resolved
    }
    $children = @(Get-ChildItem -LiteralPath $resolved -Directory)
    if ($children.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $children[0].FullName "checksums.sha256") -PathType Leaf)) {
        return $children[0].FullName
    }
    throw "O pacote não contém checksums.sha256 na raiz."
}

function Read-ChecksumManifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $entries = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64}) \*(.+)$') {
            throw "Linha inválida em checksums.sha256: $line"
        }
        $relativePath = ConvertTo-SafeRelativePath -RelativePath $Matches[2]
        if ($seen.ContainsKey($relativePath)) { throw "Arquivo repetido no manifesto: $relativePath" }
        $seen[$relativePath] = $true
        $entries.Add([pscustomobject]@{
            Path = $relativePath
            Sha256 = $Matches[1].ToLowerInvariant()
        })
    }
    if ($entries.Count -eq 0) { throw "O manifesto de checksums está vazio." }
    return $entries
}

function Assert-PackageIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][Collections.Generic.List[object]]$Entries
    )

    $requiredPaths = @(
        "src\index.mjs",
        "scripts\iniciar-bandeja.ps1",
        "scripts\install-local.ps1",
        "scripts\uninstall-local.ps1",
        "assets\ulanzi-libre.ico",
        "installer\iniciar-instalado.vbs",
        "installer\iniciar-instalado.ps1",
        "installer\configurar-instalado.ps1",
        "installer\configurar-instalado.vbs"
    )
    $manifestPaths = @($Entries | ForEach-Object { $_.Path })
    foreach ($requiredPath in $requiredPaths) {
        if ($manifestPaths -inotcontains $requiredPath) {
            throw "O pacote está incompleto; falta no manifesto: $requiredPath"
        }
    }

    foreach ($entry in $Entries) {
        $filePath = [IO.Path]::GetFullPath((Join-Path $Root $entry.Path))
        if (-not (Test-PathInside -Candidate $filePath -Parent $Root)) {
            throw "Arquivo fora da raiz do pacote: $($entry.Path)"
        }
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Arquivo ausente do pacote: $($entry.Path)"
        }
        $item = Get-Item -LiteralPath $filePath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Links não são aceitos no pacote: $($entry.Path)"
        }
        Assert-NoReparsePath -Path $filePath -StopAt $Root
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        if ($actualHash -ine $entry.Sha256) {
            throw "Integridade inválida em '$($entry.Path)'."
        }
    }
}

function New-RollbackSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentInstallPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$CurrentEntries
    )

    if ($Repair -or $CurrentEntries.Count -eq 0) { return $null }
    $rollbackRoot = Join-Path $env:LOCALAPPDATA "Ulanzi Libre Bridge\rollback"
    $localApplicationDataRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
    $snapshotName = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $snapshotPath = Join-Path $rollbackRoot $snapshotName
    [void](New-Item -ItemType Directory -Force -Path $snapshotPath)
    Assert-NoReparsePath -Path $snapshotPath -StopAt $localApplicationDataRoot
    $snapshotChecksums = [Collections.Generic.List[string]]::new()

    foreach ($entry in $CurrentEntries) {
        $relativePath = ConvertTo-SafeRelativePath -RelativePath $entry.Path
        $sourcePath = Join-Path $CurrentInstallPath $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
        Assert-NoReparsePath -Path $sourcePath -StopAt $CurrentInstallPath
        $destinationPath = Join-Path $snapshotPath $relativePath
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath))
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
        $hash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $snapshotChecksums.Add("$hash *$($relativePath.Replace('\', '/'))")
    }
    if ($snapshotChecksums.Count -eq 0) {
        if (-not (Test-PathInside -Candidate $snapshotPath -Parent $rollbackRoot)) {
            throw "A pasta vazia do rollback não passou pela validação de segurança."
        }
        Remove-Item -LiteralPath $snapshotPath -Recurse -Force
        return $null
    }
    [IO.File]::WriteAllLines(
        (Join-Path $snapshotPath "checksums.sha256"),
        $snapshotChecksums,
        [Text.UTF8Encoding]::new($false)
    )
    return $snapshotPath
}

function New-ShellShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$Description = "Ulanzi Libre Bridge",
        [string]$IconLocation = ""
    )

    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ShortcutPath))
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = $Description
    if (-not [string]::IsNullOrWhiteSpace($IconLocation)) {
        $shortcut.IconLocation = "$IconLocation,0"
    }
    $shortcut.Save()
}

function Set-OptionalShortcut {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Keep", "Enable", "Disable")][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$IconLocation
    )

    if ($Mode -eq "Enable") {
        New-ShellShortcut -ShortcutPath $ShortcutPath -TargetPath $TargetPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Description $Description -IconLocation $IconLocation
    } elseif ($Mode -eq "Disable" -and (Test-Path -LiteralPath $ShortcutPath)) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
}

$programsRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs"))
$resolvedInstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not (Test-PathInside -Candidate $resolvedInstallPath -Parent $programsRoot)) {
    throw "A instalação local deve ficar dentro de '$programsRoot'."
}

try {
    $packageRoot = Get-PackageRoot -InputPath $PackagePath
    $manifestPath = Join-Path $packageRoot "checksums.sha256"
    $entries = Read-ChecksumManifest -ManifestPath $manifestPath
    Assert-PackageIntegrity -Root $packageRoot -Entries $entries

    $oldEntries = [Collections.Generic.List[object]]::new()
    $oldManifestPath = Join-Path $resolvedInstallPath "checksums.sha256"
    if (Test-Path -LiteralPath $resolvedInstallPath -PathType Container) {
        Assert-NoReparsePath -Path $resolvedInstallPath -StopAt $programsRoot
    }
    if (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
        try {
            $oldEntries = Read-ChecksumManifest -ManifestPath $oldManifestPath
        } catch {
            throw "A instalação existente possui um manifesto inválido. Reinstale pelo instalador oficial ou remova-a manualmente após fazer backup: $($_.Exception.Message)"
        }
    }
    $rollbackSnapshot = New-RollbackSnapshot -CurrentInstallPath $resolvedInstallPath -CurrentEntries $oldEntries

    [void](New-Item -ItemType Directory -Force -Path $resolvedInstallPath)
    Assert-NoReparsePath -Path $resolvedInstallPath -StopAt $programsRoot
    $newPathSet = @{}
    foreach ($entry in $entries) { $newPathSet[$entry.Path] = $true }
    foreach ($oldEntry in $oldEntries) {
        $oldRelativePath = ConvertTo-SafeRelativePath -RelativePath $oldEntry.Path
        if ($newPathSet.ContainsKey($oldRelativePath)) { continue }
        $obsoletePath = [IO.Path]::GetFullPath((Join-Path $resolvedInstallPath $oldRelativePath))
        if ((Test-PathInside -Candidate $obsoletePath -Parent $resolvedInstallPath) -and (Test-Path -LiteralPath $obsoletePath -PathType Leaf)) {
            Assert-NoReparsePath -Path $obsoletePath -StopAt $resolvedInstallPath
            Remove-Item -LiteralPath $obsoletePath -Force
        }
    }

    foreach ($entry in $entries) {
        $sourcePath = Join-Path $packageRoot $entry.Path
        $destinationPath = Join-Path $resolvedInstallPath $entry.Path
        $destinationParent = Split-Path -Parent $destinationPath
        [void](New-Item -ItemType Directory -Force -Path $destinationParent)
        Assert-NoReparsePath -Path $destinationParent -StopAt $resolvedInstallPath
        if (Test-Path -LiteralPath $destinationPath) {
            Assert-NoReparsePath -Path $destinationPath -StopAt $resolvedInstallPath
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $installedHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        if ($installedHash -ine $entry.Sha256) {
            throw "A cópia instalada não passou pela verificação: $($entry.Path)"
        }
    }
    Copy-Item -LiteralPath $manifestPath -Destination $oldManifestPath -Force

    $buildInformationPath = Join-Path $resolvedInstallPath "build-info.json"
    $displayVersion = "desconhecida"
    if (Test-Path -LiteralPath $buildInformationPath -PathType Leaf) {
        $buildInformation = Get-Content -Raw -LiteralPath $buildInformationPath | ConvertFrom-Json
        $displayVersion = [string]$buildInformation.version
    }

    $installMetadataDirectory = Join-Path $resolvedInstallPath ".install"
    [void](New-Item -ItemType Directory -Force -Path $installMetadataDirectory)
    $installMetadata = [ordered]@{
        formatVersion = 1
        version = $displayVersion
        installedAt = (Get-Date).ToUniversalTime().ToString("o")
        installPath = $resolvedInstallPath
        rollbackSnapshot = $rollbackSnapshot
        shellIntegration = (-not $NoShellIntegration)
    }
    [IO.File]::WriteAllText(
        (Join-Path $installMetadataDirectory "installation.json"),
        (($installMetadata | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $windowsScriptHost = Join-Path $env:SystemRoot "System32\wscript.exe"
    $launcherPath = Join-Path $resolvedInstallPath "installer\iniciar-instalado.vbs"
    $uninstallPath = Join-Path $resolvedInstallPath "scripts\uninstall-local.ps1"
    $appIconPath = Join-Path $resolvedInstallPath "assets\ulanzi-libre.ico"
    $launchArguments = '"' + $launcherPath + '" /OpenPanel'
    $launchInBackgroundArguments = '"' + $launcherPath + '"'
    $uninstallArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $uninstallPath + '" -InstallPath "' + $resolvedInstallPath + '"'

    if (-not $NoShellIntegration) {
        $startMenuDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Ulanzi Libre Bridge"
        $legacyConfigureShortcut = Join-Path $startMenuDirectory "Configurar Ulanzi Libre Bridge.lnk"
        if (Test-Path -LiteralPath $legacyConfigureShortcut) { Remove-Item -LiteralPath $legacyConfigureShortcut -Force }
        New-ShellShortcut -ShortcutPath (Join-Path $startMenuDirectory "Ulanzi Libre Bridge.lnk") -TargetPath $windowsScriptHost -Arguments $launchArguments -WorkingDirectory $resolvedInstallPath -IconLocation $appIconPath
        New-ShellShortcut -ShortcutPath (Join-Path $startMenuDirectory "Desinstalar Ulanzi Libre Bridge.lnk") -TargetPath $windowsPowerShell -Arguments $uninstallArguments -WorkingDirectory $resolvedInstallPath -Description "Desinstalar Ulanzi Libre Bridge" -IconLocation $appIconPath

        $startupShortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Ulanzi Libre Bridge.lnk"
        Set-OptionalShortcut -Mode $Startup -ShortcutPath $startupShortcutPath -TargetPath $windowsScriptHost -Arguments $launchInBackgroundArguments -WorkingDirectory $resolvedInstallPath -Description "Iniciar Ulanzi Libre Bridge com o Windows" -IconLocation $appIconPath
        $desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Ulanzi Libre Bridge.lnk"
        Set-OptionalShortcut -Mode $DesktopShortcut -ShortcutPath $desktopShortcutPath -TargetPath $windowsScriptHost -Arguments $launchArguments -WorkingDirectory $resolvedInstallPath -Description "Ulanzi Libre Bridge" -IconLocation $appIconPath

        $uninstallRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UlanziLibreBridge"
        [void](New-Item -Path $uninstallRegistryPath -Force)
        $estimatedSizeKb = [Math]::Ceiling((($entries | ForEach-Object { (Get-Item -LiteralPath (Join-Path $resolvedInstallPath $_.Path)).Length } | Measure-Object -Sum).Sum) / 1KB)
        $registryValues = [ordered]@{
            DisplayName = "Ulanzi Libre Bridge"
            DisplayVersion = $displayVersion
            Publisher = "Ulanzi Libre Bridge contributors"
            InstallLocation = $resolvedInstallPath
            DisplayIcon = "$appIconPath,0"
            UninstallString = '"' + $windowsPowerShell + '" ' + $uninstallArguments
            QuietUninstallString = '"' + $windowsPowerShell + '" ' + $uninstallArguments
            EstimatedSize = [int]$estimatedSizeKb
            NoModify = 1
            NoRepair = 1
        }
        foreach ($name in $registryValues.Keys) {
            Set-ItemProperty -Path $uninstallRegistryPath -Name $name -Value $registryValues[$name]
        }
    }

    Write-Host "Ulanzi Libre Bridge $displayVersion instalado em: $resolvedInstallPath"
    if ($null -ne $rollbackSnapshot) {
        Write-Host "Cópia para rollback criada em: $rollbackSnapshot"
    }
    Write-Host "Para reparar, execute novamente este script a partir do pacote original com -Repair."

    if ($LaunchAfterInstall) {
        Start-Process -FilePath $windowsScriptHost -ArgumentList $launchArguments -WorkingDirectory $resolvedInstallPath -WindowStyle Hidden
    }
} finally {
    if ($null -ne $temporaryExtractionDirectory -and (Test-Path -LiteralPath $temporaryExtractionDirectory)) {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not (Test-PathInside -Candidate $temporaryExtractionDirectory -Parent $tempRoot)) {
            throw "A pasta temporária não passou pela validação de segurança e não foi removida."
        }
        Remove-Item -LiteralPath $temporaryExtractionDirectory -Recurse -Force
    }
}
