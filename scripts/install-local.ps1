[CmdletBinding()]
param(
    [string]$PackagePath = (Split-Path -Parent $PSScriptRoot),
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedPackageSha256,
    [string]$InstallPath,
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
$mutexes = [Collections.Generic.List[Threading.Mutex]]::new()
$ownedMutexes = [Collections.Generic.List[Threading.Mutex]]::new()
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
            throw "Links and junctions are not allowed during installation: $($cursor.FullName)"
        }
        if ($cursor.FullName -ieq $StopAt) { return }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    throw "Unable to verify the directories in this path: $Path"
}

function ConvertTo-SafeRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Invalid path in the manifest: '$RelativePath'."
    }
    $normalized = $RelativePath.Replace('/', '\').Trim()
    if ($normalized.Contains(':') -or $normalized -match '(^|\\)\.\.(\\|$)') {
        throw "Directory traversal rejected in the manifest: '$RelativePath'."
    }
    $segments = @($normalized -split '\\')
    foreach ($segment in $segments) {
        if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw "The manifest contains a reserved Windows name: '$RelativePath'."
        }
        if ($forbiddenSegments -icontains $segment) {
            throw "The package tried to install forbidden local data: '$RelativePath'."
        }
    }
    $leaf = $segments[$segments.Count - 1]
    if ($leaf -like ".env*" -and $normalized -ine ".env.example") {
        throw "The package tried to install local configuration: '$RelativePath'."
    }
    if ([IO.Path]::GetExtension($leaf) -match '(?i)^\.(bak|backup|bin|dmp|log|tmp|zip)$') {
        throw "The package tried to install a local artifact or data file: '$RelativePath'."
    }
    if (
        [IO.Path]::GetExtension($leaf) -ieq ".json" -and
        $normalized -inotmatch '^runtime\\node\\' -and
        $normalized -inotmatch '^((package|build-info)\.json|locales\\(en|pt-BR)\.json)$'
    ) {
        throw "The package tried to install an unrecognized local JSON file: '$RelativePath'."
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
                throw "The ZIP contains an unsafe path: $($entry.FullName)"
            }
            foreach ($segment in @($entryName -split '\\')) {
                if ($segment -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
                    throw "The ZIP contains a reserved Windows name: $($entry.FullName)"
                }
            }
            $entryDestination = [IO.Path]::GetFullPath((Join-Path $Destination $entryName))
            if (-not (Test-PathInside -Candidate $entryDestination -Parent $Destination)) {
                throw "The ZIP tried to write outside the temporary folder: $($entry.FullName)"
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
        throw "The ZIP created a forbidden link: $($reparsePoint.FullName)"
    }
}

function Get-PackageRoot {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $resolved = [IO.Path]::GetFullPath($InputPath)
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        if ([IO.Path]::GetExtension($resolved) -ine ".zip") {
            throw "PackagePath must point to a folder or a ZIP file."
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256)) {
            $actualPackageHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
            if ($actualPackageHash -ine $ExpectedPackageSha256) {
                throw "The ZIP SHA-256 does not match the expected value. Installation was blocked."
            }
        }
        $script:temporaryExtractionDirectory = Join-Path ([IO.Path]::GetTempPath()) ("ulanzi-glucose-install-" + [Guid]::NewGuid().ToString("N"))
        [void](New-Item -ItemType Directory -Path $script:temporaryExtractionDirectory)
        Expand-VerifiedStructureZip -ArchivePath $resolved -Destination $script:temporaryExtractionDirectory
        $resolved = $script:temporaryExtractionDirectory
    } elseif (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Package not found: $resolved"
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256)) {
        throw "ExpectedPackageSha256 can only be used when PackagePath is a ZIP."
    }

    if (Test-Path -LiteralPath (Join-Path $resolved "checksums.sha256") -PathType Leaf) {
        return $resolved
    }
    $children = @(Get-ChildItem -LiteralPath $resolved -Directory)
    if ($children.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $children[0].FullName "checksums.sha256") -PathType Leaf)) {
        return $children[0].FullName
    }
    throw "The package does not contain checksums.sha256 at its root. Use a prepared release package, not a source ZIP."
}

function Read-ChecksumManifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $entries = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64}) \*(.+)$') {
            throw "Invalid line in checksums.sha256: $line"
        }
        $relativePath = ConvertTo-SafeRelativePath -RelativePath $Matches[2]
        if ($seen.ContainsKey($relativePath)) { throw "Duplicate file in the manifest: $relativePath" }
        $seen[$relativePath] = $true
        $entries.Add([pscustomobject]@{
            Path = $relativePath
            Sha256 = $Matches[1].ToLowerInvariant()
        })
    }
    if ($entries.Count -eq 0) { throw "The checksum manifest is empty." }
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
        "assets\ulanzi-glucose.ico",
        "installer\iniciar-instalado.vbs",
        "installer\iniciar-instalado.ps1",
        "installer\configurar-instalado.ps1",
        "installer\configurar-instalado.vbs"
    )
    $manifestPaths = @($Entries | ForEach-Object { $_.Path })
    foreach ($requiredPath in $requiredPaths) {
        if ($manifestPaths -inotcontains $requiredPath) {
            throw "The package is incomplete; missing manifest entry: $requiredPath"
        }
    }

    foreach ($entry in $Entries) {
        $filePath = [IO.Path]::GetFullPath((Join-Path $Root $entry.Path))
        if (-not (Test-PathInside -Candidate $filePath -Parent $Root)) {
            throw "File outside the package root: $($entry.Path)"
        }
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "File missing from the package: $($entry.Path)"
        }
        $item = Get-Item -LiteralPath $filePath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Links are not allowed in the package: $($entry.Path)"
        }
        Assert-NoReparsePath -Path $filePath -StopAt $Root
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        if ($actualHash -ine $entry.Sha256) {
            throw "Integrity check failed for '$($entry.Path)'."
        }
    }
}

function New-RollbackSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentInstallPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$CurrentEntries
    )

    if ($Repair -or $CurrentEntries.Count -eq 0) { return $null }
    $rollbackRoot = Join-Path $env:LOCALAPPDATA "Ulanzi Glucose Bridge\rollback"
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
            throw "The empty rollback folder failed path validation."
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
        [string]$Description = "Ulanzi Glucose Bridge",
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
# Keep the original registry identity and install folder on upgrades: credentials,
# configuration and vault files are deliberately never moved or overwritten.
$uninstallRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UlanziLibreBridge"
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    if (-not $NoShellIntegration -and (Test-Path -LiteralPath $uninstallRegistryPath)) {
        $registeredLocation = [string](Get-ItemPropertyValue -LiteralPath $uninstallRegistryPath -Name "InstallLocation" -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($registeredLocation) -and
            (Test-PathInside -Candidate $registeredLocation -Parent $programsRoot) -and
            (Test-Path -LiteralPath (Join-Path $registeredLocation "checksums.sha256") -PathType Leaf)) {
            $InstallPath = $registeredLocation
        }
    }
    if ([string]::IsNullOrWhiteSpace($InstallPath)) {
        $legacyInstallPath = Join-Path $programsRoot "Ulanzi Libre Bridge"
        $currentInstallPath = Join-Path $programsRoot "Ulanzi Glucose Bridge"
        $InstallPath = if (Test-Path -LiteralPath (Join-Path $currentInstallPath "checksums.sha256") -PathType Leaf) {
            $currentInstallPath
        } elseif (Test-Path -LiteralPath (Join-Path $legacyInstallPath "checksums.sha256") -PathType Leaf) {
            $legacyInstallPath
        } else { $currentInstallPath }
    }
}
$resolvedInstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not (Test-PathInside -Candidate $resolvedInstallPath -Parent $programsRoot)) {
    throw "Local installation must be inside '$programsRoot'."
}

try {
    $packageRoot = Get-PackageRoot -InputPath $PackagePath
    $manifestPath = Join-Path $packageRoot "checksums.sha256"
    $entries = Read-ChecksumManifest -ManifestPath $manifestPath
    Assert-PackageIntegrity -Root $packageRoot -Entries $entries

    # An Inno-owned installation must keep one authoritative uninstall manifest.
    # Switching to the local ZIP installer would leave a second registration.
    if ((Test-Path -LiteralPath $resolvedInstallPath -PathType Container) -and
        @(Get-ChildItem -LiteralPath $resolvedInstallPath -Filter "unins*.exe" -File -Force).Count -gt 0) {
        throw "This installation is managed by the Windows setup installer. Use its setup executable to update or repair it. No application files were changed."
    }

    # These legacy mutex names are shared by every release to prevent an old and
    # a renamed application from running while owned files are replaced.
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($name in @("Local\UlanziLibreTray-$currentSid", "Local\UlanziLibreBridge-$currentSid")) {
        $mutex = [Threading.Mutex]::new($false, $name)
        $mutexes.Add($mutex)
        $ownsMutex = $false
        try { $ownsMutex = $mutex.WaitOne(0, $false) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw "Ulanzi Glucose Bridge is still running. Select 'Exit' in its tray menu and try again." }
        $ownedMutexes.Add($mutex)
    }

    $oldEntries = [Collections.Generic.List[object]]::new()
    $oldManifestPath = Join-Path $resolvedInstallPath "checksums.sha256"
    if (Test-Path -LiteralPath $resolvedInstallPath -PathType Container) {
        Assert-NoReparsePath -Path $resolvedInstallPath -StopAt $programsRoot
    }
    if (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
        try {
            $oldEntries = Read-ChecksumManifest -ManifestPath $oldManifestPath
        } catch {
            throw "The existing installation has an invalid manifest. Repair it using the official installer, or back up your data before manually removing it: $($_.Exception.Message)"
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
            throw "The installed copy failed verification: $($entry.Path)"
        }
    }
    Copy-Item -LiteralPath $manifestPath -Destination $oldManifestPath -Force

    $buildInformationPath = Join-Path $resolvedInstallPath "build-info.json"
    $displayVersion = "unknown"
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
    $appIconPath = Join-Path $resolvedInstallPath "assets\ulanzi-glucose.ico"
    $launchArguments = '"' + $launcherPath + '" /OpenPanel'
    $launchInBackgroundArguments = '"' + $launcherPath + '"'
    $uninstallArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $uninstallPath + '" -InstallPath "' + $resolvedInstallPath + '"'

    if (-not $NoShellIntegration) {
        $startMenuDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Ulanzi Glucose Bridge"
        $legacyMenuDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Ulanzi Libre Bridge"
        # Preserve optional shortcuts selected before the product rename.
        $legacyStartupPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Ulanzi Libre Bridge.lnk"
        $legacyDesktopPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Ulanzi Libre Bridge.lnk"
        if ($Startup -eq "Keep" -and (Test-Path -LiteralPath $legacyStartupPath -PathType Leaf)) { $Startup = "Enable" }
        if ($DesktopShortcut -eq "Keep" -and (Test-Path -LiteralPath $legacyDesktopPath -PathType Leaf)) { $DesktopShortcut = "Enable" }
        $legacyShortcuts = @($legacyStartupPath, $legacyDesktopPath)
        foreach ($name in @("Ulanzi Libre Bridge.lnk", "Configurar Ulanzi Libre Bridge.lnk", "Desinstalar Ulanzi Libre Bridge.lnk", "Uninstall Ulanzi Libre Bridge.lnk")) {
            $legacyShortcuts += Join-Path $legacyMenuDirectory $name
        }
        foreach ($legacyShortcut in $legacyShortcuts) {
            if (Test-Path -LiteralPath $legacyShortcut -PathType Leaf) { Remove-Item -LiteralPath $legacyShortcut -Force }
        }
        if ((Test-Path -LiteralPath $legacyMenuDirectory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $legacyMenuDirectory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $legacyMenuDirectory
        }
        New-ShellShortcut -ShortcutPath (Join-Path $startMenuDirectory "Ulanzi Glucose Bridge.lnk") -TargetPath $windowsScriptHost -Arguments $launchArguments -WorkingDirectory $resolvedInstallPath -IconLocation $appIconPath
        New-ShellShortcut -ShortcutPath (Join-Path $startMenuDirectory "Uninstall Ulanzi Glucose Bridge.lnk") -TargetPath $windowsPowerShell -Arguments $uninstallArguments -WorkingDirectory $resolvedInstallPath -Description "Uninstall Ulanzi Glucose Bridge" -IconLocation $appIconPath

        $startupShortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Ulanzi Glucose Bridge.lnk"
        Set-OptionalShortcut -Mode $Startup -ShortcutPath $startupShortcutPath -TargetPath $windowsScriptHost -Arguments $launchInBackgroundArguments -WorkingDirectory $resolvedInstallPath -Description "Start Ulanzi Glucose Bridge with Windows" -IconLocation $appIconPath
        $desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Ulanzi Glucose Bridge.lnk"
        Set-OptionalShortcut -Mode $DesktopShortcut -ShortcutPath $desktopShortcutPath -TargetPath $windowsScriptHost -Arguments $launchArguments -WorkingDirectory $resolvedInstallPath -Description "Ulanzi Glucose Bridge" -IconLocation $appIconPath

        [void](New-Item -Path $uninstallRegistryPath -Force)
        $estimatedSizeKb = [Math]::Ceiling((($entries | ForEach-Object { (Get-Item -LiteralPath (Join-Path $resolvedInstallPath $_.Path)).Length } | Measure-Object -Sum).Sum) / 1KB)
        $registryValues = [ordered]@{
            DisplayName = "Ulanzi Glucose Bridge"
            DisplayVersion = $displayVersion
            Publisher = "Ulanzi Glucose Bridge contributors"
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

    Write-Host "Ulanzi Glucose Bridge $displayVersion installed in: $resolvedInstallPath"
    if ($null -ne $rollbackSnapshot) {
        Write-Host "Rollback copy created in: $rollbackSnapshot"
    }
    Write-Host "To repair, run this script again from the original package with -Repair."

    if ($LaunchAfterInstall) {
        foreach ($mutex in $ownedMutexes) { $mutex.ReleaseMutex() }
        $ownedMutexes.Clear()
        Start-Process -FilePath $windowsScriptHost -ArgumentList $launchArguments -WorkingDirectory $resolvedInstallPath -WindowStyle Hidden
    }
} finally {
    foreach ($mutex in $ownedMutexes) { try { $mutex.ReleaseMutex() } catch { } }
    foreach ($mutex in $mutexes) { $mutex.Dispose() }
    if ($null -ne $temporaryExtractionDirectory -and (Test-Path -LiteralPath $temporaryExtractionDirectory)) {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not (Test-PathInside -Candidate $temporaryExtractionDirectory -Parent $tempRoot)) {
            throw "The temporary folder failed path validation and was not removed."
        }
        Remove-Item -LiteralPath $temporaryExtractionDirectory -Recurse -Force
    }
}
